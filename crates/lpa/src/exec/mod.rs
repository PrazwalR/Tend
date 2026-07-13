pub mod cost;

use alloy::network::EthereumWallet;
use alloy::primitives::aliases::I24;
use alloy::primitives::{Address, B256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use anyhow::{anyhow, bail, Context, Result};
use std::time::Duration;

sol! {
    #[sol(rpc)]
    interface IAutopilotHook {
        function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper, uint128 minLiquidity) external returns (uint128);
        function isRebalancer(address who) external view returns (bool);
    }
}

/// Solidity `int24` bounds (Uniswap tick domain).
const I24_MIN: i32 = -8_388_608;
const I24_MAX: i32 = 8_388_607;
/// Basis-point denominator for the slippage floor.
const BPS_DENOMINATOR: u128 = 10_000;
/// Seconds to wait for a rebalance receipt before reporting it unconfirmed.
const DEFAULT_TX_TIMEOUT_SECS: u64 = 120;

/// Defaults for a rebalance / auto-execute when not set via config or env.
pub const DEFAULT_SLIPPAGE_BPS: u32 = 100;
pub const DEFAULT_MAX_GAS_USD: f64 = 50.0;
pub const DEFAULT_ETH_PRICE_USD: f64 = 3000.0;
pub const DEFAULT_AUTO_INTERVAL_SECS: u64 = 300;
/// Buffered rebalance intents between the watch loop and the executor task.
pub const AUTO_INTENT_CHANNEL_CAP: usize = 64;

pub struct SimOutcome {
    pub ok: bool,
    pub revert: Option<String>,
    pub gas_estimate: u64,
    pub quoted_liquidity: u128,
}

pub struct ExecReport {
    pub tx_hash: String,
    pub gas_used: u64,
    pub success: bool,
}

pub struct Executor {
    provider: DynProvider,
    submit: DynProvider,
    signer: Address,
    hook: Address,
    tx_timeout: Duration,
}

impl Executor {
    pub async fn connect(
        rpc_url: &str,
        pk: &str,
        hook: Address,
        private_rpc: Option<String>,
    ) -> Result<Self> {
        let signer: PrivateKeySigner = pk.parse().context("invalid REBALANCER_PRIVATE_KEY")?;
        let addr = signer.address();
        let wallet = EthereumWallet::from(signer);

        let provider = ProviderBuilder::new()
            .wallet(wallet.clone())
            .connect_http(rpc_url.parse().context("invalid rpc url")?)
            .erased();

        let submit = match private_rpc {
            Some(url) => ProviderBuilder::new()
                .wallet(wallet)
                .connect_http(url.parse().context("invalid private rpc url")?)
                .erased(),
            None => provider.clone(),
        };

        let tx_timeout = Duration::from_secs(
            std::env::var("LPA_TX_TIMEOUT_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(DEFAULT_TX_TIMEOUT_SECS),
        );

        Ok(Self {
            provider,
            submit,
            signer: addr,
            hook,
            tx_timeout,
        })
    }

    pub fn signer(&self) -> Address {
        self.signer
    }

    pub async fn simulate(&self, position_id: B256, lower: i32, upper: i32) -> Result<SimOutcome> {
        let (l, u) = (to_i24(lower)?, to_i24(upper)?);
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        match hook
            .rebalance(position_id, l, u, 0)
            .from(self.signer)
            .call()
            .await
        {
            Ok(quoted) => {
                let gas = hook
                    .rebalance(position_id, l, u, 0)
                    .from(self.signer)
                    .estimate_gas()
                    .await
                    .unwrap_or(0);
                Ok(SimOutcome {
                    ok: true,
                    revert: None,
                    gas_estimate: gas,
                    quoted_liquidity: quoted,
                })
            }
            Err(e) => Ok(SimOutcome {
                ok: false,
                revert: Some(e.to_string()),
                gas_estimate: 0,
                quoted_liquidity: 0,
            }),
        }
    }

    pub async fn execute(
        &self,
        position_id: B256,
        lower: i32,
        upper: i32,
        slippage_bps: u32,
        max_gas_usd: f64,
        eth_price_usd: f64,
    ) -> Result<ExecReport> {
        let sim = self.simulate(position_id, lower, upper).await?;
        if !sim.ok {
            bail!(
                "preflight simulation reverted: {}",
                sim.revert.unwrap_or_default()
            );
        }
        let bps = u128::from(slippage_bps).min(BPS_DENOMINATOR);
        let floor = sim.quoted_liquidity.saturating_mul(BPS_DENOMINATOR - bps) / BPS_DENOMINATOR;

        let (l, u) = (to_i24(lower)?, to_i24(upper)?);
        let read = IAutopilotHook::new(self.hook, &self.provider);
        let gas = read
            .rebalance(position_id, l, u, floor)
            .from(self.signer)
            .estimate_gas()
            .await
            .context("gas estimation failed")?;
        let gas_price = self.provider.get_gas_price().await?;
        let est = cost::rebalance_cost_usd(gas, gas_price, eth_price_usd);
        if !cost::within_spend_cap(est, max_gas_usd) {
            bail!("spend cap exceeded: ${est:.2} > ${max_gas_usd:.2}");
        }

        let hook = IAutopilotHook::new(self.hook, &self.submit);
        let pending = hook.rebalance(position_id, l, u, floor).send().await?;
        let tx_hash = *pending.tx_hash();
        let receipt = pending
            .with_timeout(Some(self.tx_timeout))
            .get_receipt()
            .await
            .map_err(|e| {
                anyhow!(
                    "tx {tx_hash:#x} unconfirmed after {}s ({e})",
                    self.tx_timeout.as_secs()
                )
            })?;
        Ok(ExecReport {
            tx_hash: format!("{:#x}", receipt.transaction_hash),
            gas_used: receipt.gas_used,
            success: receipt.status(),
        })
    }
}

fn to_i24(v: i32) -> Result<I24> {
    if !(I24_MIN..=I24_MAX).contains(&v) {
        bail!("tick out of int24 range: {v}");
    }
    Ok(I24::unchecked_from(v))
}

pub struct RebalanceIntent {
    pub position_id: String,
    pub new_lower: i32,
    pub new_upper: i32,
}

pub struct AutoExec {
    pub slippage_bps: u32,
    pub max_gas_usd: f64,
    pub eth_price_usd: f64,
    pub min_interval: Duration,
}

pub async fn run_executor_loop(
    mut rx: tokio::sync::mpsc::Receiver<RebalanceIntent>,
    executor: Executor,
    cfg: AutoExec,
) {
    use std::collections::HashMap;
    use std::time::Instant;

    tracing::warn!(
        signer = %executor.signer(),
        max_gas_usd = cfg.max_gas_usd,
        "AUTO-EXECUTE enabled — the daemon will send real rebalance transactions"
    );
    let mut last: HashMap<String, Instant> = HashMap::new();
    while let Some(intent) = rx.recv().await {
        if last
            .get(&intent.position_id)
            .is_some_and(|t| t.elapsed() < cfg.min_interval)
        {
            continue;
        }
        last.insert(intent.position_id.clone(), Instant::now());

        let pid = match intent.position_id.parse::<B256>() {
            Ok(p) => p,
            Err(_) => continue,
        };
        match executor
            .execute(
                pid,
                intent.new_lower,
                intent.new_upper,
                cfg.slippage_bps,
                cfg.max_gas_usd,
                cfg.eth_price_usd,
            )
            .await
        {
            Ok(r) => tracing::info!(
                tx = %r.tx_hash,
                gas_used = r.gas_used,
                position = %intent.position_id,
                "auto-rebalanced on-chain"
            ),
            Err(e) => tracing::warn!(
                error = %e,
                position = %intent.position_id,
                "auto-rebalance skipped (preflight/cap/cooldown)"
            ),
        }
    }
}

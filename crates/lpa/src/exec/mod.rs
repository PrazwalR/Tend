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
    struct HookPoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    #[sol(rpc)]
    interface IAutopilotHook {
        function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper, uint128 minLiquidity) external returns (uint128);
        function isRebalancer(address who) external view returns (bool);
        function pokePriceRef(HookPoolKey key) external;
        function positions(bytes32 positionId) external view returns (
            address owner,
            HookPoolKey key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            bool active,
            uint64 lastRebalanceAt
        );

        error PriceDeviation(int24 spotTick, int24 referenceTick);
    }
}

/// Why a rebalance preflight was refused. Only one of these has a remedy the
/// daemon can apply itself; the rest resolve with time or not at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreflightBlock {
    /// Spot is further from the hook's price reference than it tolerates. On a
    /// pool with no further swaps the reference never catches up on its own, so
    /// the daemon pokes it one step per block.
    PriceDeviation,
    Other,
}

pub fn classify_preflight(revert: &str) -> PreflightBlock {
    use alloy::sol_types::SolError;
    let selector = alloy::primitives::hex::encode(IAutopilotHook::PriceDeviation::SELECTOR);
    if revert.to_lowercase().contains(&selector) {
        PreflightBlock::PriceDeviation
    } else {
        PreflightBlock::Other
    }
}

/// What makes two preflight refusals "the same" for logging: the custom-error
/// selector when there is one. The full reason embeds the error's arguments —
/// spot and reference ticks, a ready-at timestamp — which change on every retry,
/// so keying on it logged every single refusal.
pub fn refusal_key(revert: &str) -> String {
    let lower = revert.to_lowercase();
    if let Some(i) = lower.find("custom error 0x") {
        let start = i + "custom error ".len();
        if let Some(sel) = lower.get(start..start + 10) {
            return sel.to_string();
        }
    }
    revert.to_string()
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
        eth_price: &crate::chain::oracle::EthPrice,
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
        // Refuse rather than fall back: the cap is meaningless priced against a
        // seed constant, and an unpriced transaction is not an emergency.
        let eth_price_usd = eth_price
            .get_fresh()
            .ok_or_else(|| anyhow!("no fresh ETH/USD price; refusing to price the spend cap"))?;
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

impl Executor {
    /// The pool a position lives in: its key, and the v4 pool id derived from it.
    pub async fn pool_of(&self, position_id: B256) -> Result<(HookPoolKey, B256)> {
        use alloy::sol_types::SolValue;
        let read = IAutopilotHook::new(self.hook, &self.provider);
        let key = read.positions(position_id).call().await?.key;
        let pool_id = alloy::primitives::keccak256(key.abi_encode());
        Ok((key, pool_id))
    }

    /// Advances a pool's price reference one capped step toward spot. Subject to
    /// the same fresh-price spend cap as a rebalance, since the daemon pays for it.
    pub async fn poke(
        &self,
        key: HookPoolKey,
        max_gas_usd: f64,
        eth_price: &crate::chain::oracle::EthPrice,
    ) -> Result<String> {
        let read = IAutopilotHook::new(self.hook, &self.provider);
        let gas = read
            .pokePriceRef(key.clone())
            .from(self.signer)
            .estimate_gas()
            .await
            .context("poke gas estimation failed")?;
        let eth_price_usd = eth_price
            .get_fresh()
            .ok_or_else(|| anyhow!("no fresh ETH/USD price; refusing to price a poke"))?;
        let gas_price = self.provider.get_gas_price().await?;
        let est = cost::rebalance_cost_usd(gas, gas_price, eth_price_usd);
        if !cost::within_spend_cap(est, max_gas_usd) {
            bail!("spend cap exceeded for poke: ${est:.2} > ${max_gas_usd:.2}");
        }

        let hook = IAutopilotHook::new(self.hook, &self.submit);
        let receipt = hook
            .pokePriceRef(key)
            .send()
            .await?
            .with_timeout(Some(self.tx_timeout))
            .get_receipt()
            .await
            .map_err(|e| anyhow!("poke unconfirmed: {e}"))?;
        Ok(format!("{:#x}", receipt.transaction_hash))
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
    /// Live handle, not a snapshot: the spend cap is only as honest as the ETH
    /// price it is denominated in.
    pub eth_price: crate::chain::oracle::EthPrice,
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
    let mut last_poke: HashMap<B256, Instant> = HashMap::new();
    let mut last_block: HashMap<String, String> = HashMap::new();
    while let Some(intent) = rx.recv().await {
        if last
            .get(&intent.position_id)
            .is_some_and(|t| t.elapsed() < cfg.min_interval)
        {
            continue;
        }
        let pid = match intent.position_id.parse::<B256>() {
            Ok(p) => p,
            Err(_) => continue,
        };

        // Preflight first. A refused eth_call costs nothing, so it must not burn
        // the per-position interval — that is reserved for transactions actually
        // sent. Otherwise one blocked attempt would suppress retries for minutes.
        let sim = match executor
            .simulate(pid, intent.new_lower, intent.new_upper)
            .await
        {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = %e, position = %intent.position_id, "preflight call failed");
                continue;
            }
        };
        if !sim.ok {
            let reason = sim.revert.unwrap_or_default();
            let block = classify_preflight(&reason);
            // Warn once per kind of refusal, then stay quiet: the sweep retries
            // every pass and would otherwise repeat the same line forever.
            let key = refusal_key(&reason);
            if last_block.get(&intent.position_id) != Some(&key) {
                tracing::warn!(position = %intent.position_id, ?block, reason = %reason, "rebalance blocked at preflight");
                last_block.insert(intent.position_id.clone(), key);
            } else {
                tracing::debug!(position = %intent.position_id, ?block, "rebalance still blocked at preflight");
            }
            if block == PreflightBlock::PriceDeviation {
                poke_once(&executor, &cfg, pid, &intent.position_id, &mut last_poke).await;
            }
            continue;
        }
        last_block.remove(&intent.position_id);

        last.insert(intent.position_id.clone(), Instant::now());
        match executor
            .execute(
                pid,
                intent.new_lower,
                intent.new_upper,
                cfg.slippage_bps,
                cfg.max_gas_usd,
                &cfg.eth_price,
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

/// Minimum spacing between pokes of one pool. The reference moves at most one
/// step per block, so poking faster than blocks arrive only spends gas.
const POKE_MIN_INTERVAL: Duration = Duration::from_secs(12);

async fn poke_once(
    executor: &Executor,
    cfg: &AutoExec,
    pid: B256,
    position_id: &str,
    last_poke: &mut std::collections::HashMap<B256, std::time::Instant>,
) {
    let (key, pool_id) = match executor.pool_of(pid).await {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!(error = %e, position = %position_id, "could not resolve pool to poke");
            return;
        }
    };
    // Several positions can share a pool, and the sweep proposes each of them
    // every heartbeat; throttle on the pool before spending anything.
    if !poke_due(last_poke.get(&pool_id).copied(), std::time::Instant::now()) {
        return;
    }
    last_poke.insert(pool_id, std::time::Instant::now());
    match executor.poke(key, cfg.max_gas_usd, &cfg.eth_price).await {
        Ok(tx) => {
            tracing::info!(tx = %tx, position = %position_id, "poked price reference toward spot")
        }
        Err(e) => {
            tracing::warn!(error = %e, position = %position_id, "price-reference poke failed")
        }
    }
}

fn poke_due(last: Option<std::time::Instant>, now: std::time::Instant) -> bool {
    last.is_none_or(|t| now.duration_since(t) >= POKE_MIN_INTERVAL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn classifies_price_deviation_from_revert_text() {
        use alloy::sol_types::SolError;
        let sel = alloy::primitives::hex::encode(IAutopilotHook::PriceDeviation::SELECTOR);
        let text = format!(
            "server returned an error response: error code 3: execution reverted, data: \"0x{sel}00000000\""
        );
        assert_eq!(classify_preflight(&text), PreflightBlock::PriceDeviation);
        assert_eq!(
            classify_preflight(&text.to_uppercase()),
            PreflightBlock::PriceDeviation
        );
    }

    #[test]
    fn other_reverts_are_not_poked() {
        // RebalanceTooSoon — resolves with time, not with a poke.
        assert_eq!(
            classify_preflight("execution reverted, data: \"0x2ddcae9c0000\""),
            PreflightBlock::Other
        );
        assert_eq!(classify_preflight(""), PreflightBlock::Other);
    }

    #[test]
    fn poke_selector_matches_the_contract_error() {
        use alloy::sol_types::SolError;
        // cast sig "PriceDeviation(int24,int24)"
        assert_eq!(
            alloy::primitives::hex::encode(IAutopilotHook::PriceDeviation::SELECTOR),
            "1782bd94"
        );
    }

    #[test]
    fn poke_throttle() {
        let now = Instant::now();
        assert!(poke_due(None, now), "first poke of a pool is always due");
        assert!(!poke_due(Some(now), now), "not twice in one interval");
        assert!(poke_due(Some(now), now + POKE_MIN_INTERVAL));
    }

    #[test]
    fn refusals_dedupe_on_selector_not_arguments() {
        let a = "server returned an error response: error code 3: execution reverted: custom error 0x1782bd94: fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff9e4";
        let b = "server returned an error response: error code 3: execution reverted: custom error 0x1782bd94: fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbd8";
        let c = "server returned an error response: error code 3: execution reverted: custom error 0x2ddcae9c: 000000000000000000000000000000000000000000000000000000006ab8a0df";
        assert_eq!(refusal_key(a), "0x1782bd94");
        assert_eq!(refusal_key(a), refusal_key(b));
        assert_ne!(refusal_key(a), refusal_key(c));
        assert_eq!(refusal_key("connection refused"), "connection refused");
    }
}

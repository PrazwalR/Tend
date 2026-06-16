pub mod cost;

use alloy::network::EthereumWallet;
use alloy::primitives::aliases::I24;
use alloy::primitives::{Address, B256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use anyhow::{bail, Context, Result};

sol! {
    #[sol(rpc)]
    interface IAutopilotHook {
        function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper) external;
        function isRebalancer(address who) external view returns (bool);
    }
}

pub struct SimOutcome {
    pub ok: bool,
    pub revert: Option<String>,
    pub gas_estimate: u64,
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
}

impl Executor {
    pub async fn connect(rpc_url: &str, pk: &str, hook: Address, private_rpc: Option<String>) -> Result<Self> {
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

        Ok(Self { provider, submit, signer: addr, hook })
    }

    pub fn signer(&self) -> Address {
        self.signer
    }

    pub async fn simulate(&self, position_id: B256, lower: i32, upper: i32) -> Result<SimOutcome> {
        let (l, u) = (to_i24(lower)?, to_i24(upper)?);
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        match hook.rebalance(position_id, l, u).from(self.signer).call().await {
            Ok(_) => {
                let gas = hook
                    .rebalance(position_id, l, u)
                    .from(self.signer)
                    .estimate_gas()
                    .await
                    .unwrap_or(0);
                Ok(SimOutcome { ok: true, revert: None, gas_estimate: gas })
            }
            Err(e) => Ok(SimOutcome { ok: false, revert: Some(e.to_string()), gas_estimate: 0 }),
        }
    }

    pub async fn execute(
        &self,
        position_id: B256,
        lower: i32,
        upper: i32,
        max_gas_usd: f64,
        eth_price_usd: f64,
    ) -> Result<ExecReport> {
        let sim = self.simulate(position_id, lower, upper).await?;
        if !sim.ok {
            bail!("preflight simulation reverted: {}", sim.revert.unwrap_or_default());
        }

        let (l, u) = (to_i24(lower)?, to_i24(upper)?);
        let read = IAutopilotHook::new(self.hook, &self.provider);
        let gas = read
            .rebalance(position_id, l, u)
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
        let pending = hook.rebalance(position_id, l, u).send().await?;
        let receipt = pending.get_receipt().await?;
        Ok(ExecReport {
            tx_hash: format!("{:#x}", receipt.transaction_hash),
            gas_used: receipt.gas_used,
            success: receipt.status(),
        })
    }
}

fn to_i24(v: i32) -> Result<I24> {
    if !(-8_388_608..=8_388_607).contains(&v) {
        bail!("tick out of int24 range: {v}");
    }
    Ok(I24::unchecked_from(v))
}

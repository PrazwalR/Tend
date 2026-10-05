pub mod automation;
pub mod cost;

use alloy::network::{EthereumWallet, TransactionBuilder};
use alloy::primitives::aliases::I24;
use alloy::primitives::{Address, B256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::rpc::types::TransactionRequest;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol;
use anyhow::{anyhow, bail, Context, Result};
use std::time::Duration;

use automation::{automation, RefusalAction, SpendBudget};

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

        function boundLower(bytes32 positionId) external view returns (int24);
        function boundUpper(bytes32 positionId) external view returns (int24);
        function priceRef(bytes32 poolId) external view returns (
            int24 tick, int24 anchor, uint64 atBlock, bool seeded, bool clamped, uint8 stable, int24 base
        );

        error PriceDeviation(int24 spotTick, int24 referenceTick);
        error PriceUnsettled(uint8 stableBlocks);
        error AutomationDisabled();
        error NotRebalancer();
        error OutOfBounds();
        error PositionNotActive();
        error RebalanceTooSoon(uint64 readyAt);
    }
}

/// The custom-error selector a revert carries: the first four bytes of its data.
/// Searching the whole text for a selector also matched one that happened to
/// appear inside another error's arguments (full audit LV-12).
pub fn revert_selector(revert: &str) -> Option<String> {
    let r = revert.to_lowercase();
    for marker in ["custom error 0x", "data: \"0x", "data:\"0x"] {
        if let Some(i) = r.find(marker) {
            let start = i + marker.len();
            if let Some(sel) = r.get(start..start + 8) {
                if sel.chars().all(|c| c.is_ascii_hexdigit()) {
                    return Some(sel.to_string());
                }
            }
        }
    }
    None
}

/// What the daemon does about a refused preflight, from the hook's error.
pub fn classify_preflight(revert: &str) -> RefusalAction {
    use alloy::sol_types::SolError;
    use IAutopilotHook as H;
    let Some(sel) = revert_selector(revert) else {
        return RefusalAction::Retry;
    };
    let is = |s: [u8; 4]| sel == alloy::primitives::hex::encode(s);
    // The reference lags spot, or has not yet sat on spot for long enough: a
    // poke is what moves it on a pool nobody else is trading.
    if is(H::PriceDeviation::SELECTOR) || is(H::PriceUnsettled::SELECTOR) {
        RefusalAction::Poke
    } else if is(H::AutomationDisabled::SELECTOR)
        || is(H::NotRebalancer::SELECTOR)
        || is(H::PositionNotActive::SELECTOR)
    {
        RefusalAction::Terminal
    } else if is(H::RebalanceTooSoon::SELECTOR) {
        RefusalAction::Cooldown
    } else {
        // OutOfBounds included: whether a range crosses the owner's bounds depends
        // on where price is, so it is transient, not terminal. Proposals are
        // clipped to the bounds anyway (full audit LV-3).
        RefusalAction::Retry
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
    budget: SpendBudget,
    chain_id: u64,
    max_priority_fee_wei: u128,
    /// Nonce and fees of the last transaction sent, so a replacement at the same
    /// nonce outbids it.
    last_sent: std::sync::Mutex<Option<(u64, u128, u128)>>,
}

/// Default ceiling on the priority fee the daemon will ever sign. Base needs a
/// fraction of a gwei; mainnet a gwei or two.
pub const DEFAULT_MAX_PRIORITY_FEE_GWEI: f64 = 5.0;

/// The fee fields of one transaction, fixed by the daemon rather than filled
/// by whichever RPC it is sent to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FeePlan {
    pub nonce: u64,
    pub gas_limit: u64,
    pub max_fee_per_gas: u128,
    pub max_priority_fee_per_gas: u128,
}

/// Pure, so the bounds are testable:
/// - priority fee: the node's suggestion, capped at `cap`;
/// - max fee: twice the latest base fee plus the priority fee;
/// - gas limit: the estimate plus 25%;
/// - replacing our own transaction stuck at the same nonce: both fees at least
///   12.5% above it, the minimum nodes accept for a replacement, priority still
///   capped.
pub fn plan_fees(
    nonce: u64,
    gas_estimate: u64,
    base_fee: u128,
    suggested_priority: u128,
    cap: u128,
    stuck: Option<(u64, u128, u128)>,
) -> FeePlan {
    let mut prio = suggested_priority.min(cap);
    let mut max_fee = base_fee.saturating_mul(2).saturating_add(prio);
    if let Some((n, old_max, old_prio)) = stuck {
        if n == nonce {
            prio = prio.max(old_prio.saturating_mul(9) / 8 + 1).min(cap);
            max_fee = max_fee.max(old_max.saturating_mul(9) / 8 + 1);
        }
    }
    FeePlan {
        nonce,
        gas_limit: gas_estimate.saturating_add(gas_estimate / 4),
        max_fee_per_gas: max_fee,
        max_priority_fee_per_gas: prio,
    }
}

/// Why `execute` did not produce a receipt. The split matters to the caller:
/// only a transaction that was actually sent starts the per-position interval.
#[derive(Debug)]
pub enum ExecFailure {
    NotSent(anyhow::Error),
    Unconfirmed { tx_hash: String, error: String },
}

impl std::fmt::Display for ExecFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExecFailure::NotSent(e) => write!(f, "not sent: {e:#}"),
            ExecFailure::Unconfirmed { tx_hash, error } => {
                write!(f, "tx {tx_hash} unconfirmed: {error}")
            }
        }
    }
}

impl std::error::Error for ExecFailure {}

impl Executor {
    /// Every field of every transaction is set by the daemon, not by alloy's
    /// fillers on whichever RPC the transaction goes to. With the default fillers
    /// the submit RPC chose the priority fee (a lying relay got $7,047 signed past
    /// a $50 cap) and the chain id (full audit DM-1), and the cached nonce manager
    /// advanced on sends that never happened, stalling every later transaction
    /// until restart (DM-2 / LV-7).
    pub async fn connect(
        rpc_url: &str,
        pk: &str,
        hook: Address,
        private_rpc: Option<String>,
        chain_id: u64,
    ) -> Result<Self> {
        let signer: PrivateKeySigner = pk.parse().context("invalid REBALANCER_PRIVATE_KEY")?;
        let addr = signer.address();
        let wallet = EthereumWallet::from(signer);

        let provider = ProviderBuilder::new()
            .disable_recommended_fillers()
            .wallet(wallet.clone())
            .connect_http(rpc_url.parse().context("invalid rpc url")?)
            .erased();
        let rpc_chain = provider
            .get_chain_id()
            .await
            .context("eth_chainId on the RPC")?;
        if rpc_chain != chain_id {
            bail!("RPC reports chain {rpc_chain}, expected {chain_id}; refusing to sign");
        }

        let submit = match private_rpc {
            Some(url) => {
                let p = ProviderBuilder::new()
                    .disable_recommended_fillers()
                    .wallet(wallet)
                    .connect_http(url.parse().context("invalid private rpc url")?)
                    .erased();
                // A relay that answers eth_chainId must agree. The chain id is
                // fixed in the signed transaction either way.
                if let Ok(c) = p.get_chain_id().await {
                    if c != chain_id {
                        bail!(
                            "private RPC reports chain {c}, expected {chain_id}; refusing to sign"
                        );
                    }
                }
                p
            }
            None => provider.clone(),
        };
        let max_priority_fee_wei = (std::env::var("LPA_MAX_PRIORITY_FEE_GWEI")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v >= 0.0)
            .unwrap_or(DEFAULT_MAX_PRIORITY_FEE_GWEI)
            * 1e9) as u128;

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
            budget: SpendBudget::from_env(),
            chain_id,
            max_priority_fee_wei,
            last_sent: std::sync::Mutex::new(None),
        })
    }

    pub fn signer(&self) -> Address {
        self.signer
    }

    pub async fn simulate(&self, position_id: B256, lower: i32, upper: i32) -> Result<SimOutcome> {
        let (l, u) = (to_i24(lower)?, to_i24(upper)?);
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        // At `pending`, not `latest`: the transaction lands in the next block,
        // where the hook compares against the reference as it stands then. At
        // `latest` the preflight saw the current block's anchor and refused
        // rebalances that would have passed (re-audit DS-9).
        match hook
            .rebalance(position_id, l, u, 0)
            .from(self.signer)
            .call()
            .block(alloy::eips::BlockId::pending())
            .await
        {
            Ok(quoted) => {
                let gas = hook
                    .rebalance(position_id, l, u, 0)
                    .from(self.signer)
                    .block(alloy::eips::BlockId::pending())
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
        slippage_bps: Option<u32>,
        max_gas_usd: f64,
        eth_price: &crate::chain::oracle::EthPrice,
    ) -> std::result::Result<ExecReport, ExecFailure> {
        let floor = self
            .prepare(position_id, lower, upper, slippage_bps)
            .await
            .map_err(ExecFailure::NotSent)?;
        let (l, u) = (
            to_i24(lower).map_err(ExecFailure::NotSent)?,
            to_i24(upper).map_err(ExecFailure::NotSent)?,
        );
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        let call = hook.rebalance(position_id, l, u, floor);
        let tx = TransactionRequest::default()
            .with_from(self.signer)
            .with_to(self.hook)
            .with_input(call.calldata().clone());
        self.send_capped(tx, max_gas_usd, eth_price).await
    }

    /// Plans every field, prices the worst case the signature allows against both
    /// caps, signs locally and sends. The receipt wait is bounded by `tx_timeout`.
    async fn send_capped(
        &self,
        tx: TransactionRequest,
        max_gas_usd: f64,
        eth_price: &crate::chain::oracle::EthPrice,
    ) -> std::result::Result<ExecReport, ExecFailure> {
        let plan = self.plan(&tx).await.map_err(ExecFailure::NotSent)?;
        self.check_spend(plan.gas_limit, plan.max_fee_per_gas, max_gas_usd, eth_price)
            .await
            .map_err(ExecFailure::NotSent)?;
        let tx = tx
            .with_nonce(plan.nonce)
            .with_gas_limit(plan.gas_limit)
            .with_max_fee_per_gas(plan.max_fee_per_gas)
            .with_max_priority_fee_per_gas(plan.max_priority_fee_per_gas)
            .with_chain_id(self.chain_id);
        let pending = self
            .submit
            .send_transaction(tx)
            .await
            .map_err(|e| ExecFailure::NotSent(e.into()))?;
        *self.last_sent.lock().unwrap() = Some((
            plan.nonce,
            plan.max_fee_per_gas,
            plan.max_priority_fee_per_gas,
        ));
        let tx_hash = *pending.tx_hash();
        let receipt = pending
            .with_timeout(Some(self.tx_timeout))
            .get_receipt()
            .await
            .map_err(|e| ExecFailure::Unconfirmed {
                tx_hash: format!("{tx_hash:#x}"),
                error: format!("after {}s: {e}", self.tx_timeout.as_secs()),
            })?;
        Ok(ExecReport {
            tx_hash: format!("{:#x}", receipt.transaction_hash),
            gas_used: receipt.gas_used,
            success: receipt.status(),
        })
    }

    /// The nonce comes from the confirmed count on the primary RPC every time. A
    /// send that never landed leaves no gap, and a transaction stuck at that
    /// nonce is replaced (outbid) rather than queued behind. Gas is estimated at
    /// `pending`, like the preflight.
    async fn plan(&self, tx: &TransactionRequest) -> Result<FeePlan> {
        let nonce = self
            .provider
            .get_transaction_count(self.signer)
            .latest()
            .await?;
        let gas = self
            .provider
            .estimate_gas(tx.clone())
            .block(alloy::eips::BlockId::pending())
            .await
            .context("gas estimation failed")?;
        let base = self
            .provider
            .get_block_by_number(alloy::eips::BlockNumberOrTag::Latest)
            .await?
            .and_then(|b| b.header.base_fee_per_gas)
            .ok_or_else(|| anyhow!("latest block has no base fee"))? as u128;
        let suggested = self
            .provider
            .get_max_priority_fee_per_gas()
            .await
            .unwrap_or(0);
        let stuck = *self.last_sent.lock().unwrap();
        Ok(plan_fees(
            nonce,
            gas,
            base,
            suggested,
            self.max_priority_fee_wei,
            stuck,
        ))
    }

    /// Preflight and the `minLiquidity` floor. `None` sends a floor of 0, which is
    /// what automation uses: a floor taken from a preflight quote turns any depth
    /// change between preflight and inclusion into a reverted transaction the
    /// daemon pays for, and undoes the hook's own handling of a thin pool, which
    /// is to place what it can and hold the rest idle (re-audit DS-2). The hook's
    /// value, impact and deviation guards bound the fill regardless.
    async fn prepare(
        &self,
        position_id: B256,
        lower: i32,
        upper: i32,
        slippage_bps: Option<u32>,
    ) -> Result<u128> {
        let sim = self.simulate(position_id, lower, upper).await?;
        if !sim.ok {
            bail!(
                "preflight simulation reverted: {}",
                sim.revert.unwrap_or_default()
            );
        }
        Ok(match slippage_bps {
            None => 0,
            Some(bps) => {
                let bps = u128::from(bps).min(BPS_DENOMINATOR);
                sim.quoted_liquidity.saturating_mul(BPS_DENOMINATOR - bps) / BPS_DENOMINATOR
            }
        })
    }

    /// Per-transaction cap, then the rolling hourly budget. Refuses rather than
    /// falls back: a cap priced against a seed constant means nothing, and an
    /// unpriced transaction is not an emergency.
    async fn check_spend(
        &self,
        gas_limit: u64,
        max_fee_per_gas: u128,
        max_gas_usd: f64,
        eth_price: &crate::chain::oracle::EthPrice,
    ) -> Result<()> {
        let eth_price_usd = eth_price
            .get_fresh()
            .ok_or_else(|| anyhow!("no fresh ETH/USD price; refusing to price the spend cap"))?;
        // The worst case the signed fields allow, not an estimate at today's price.
        let est = cost::rebalance_cost_usd(gas_limit, max_fee_per_gas, eth_price_usd);
        if !cost::within_spend_cap(est, max_gas_usd) {
            bail!("spend cap exceeded: ${est:.2} > ${max_gas_usd:.2}");
        }
        if !self.budget.try_spend(est, std::time::Instant::now()) {
            bail!("hourly spend budget exhausted (LPA_MAX_SPEND_USD_PER_HOUR)");
        }
        Ok(())
    }
}

impl Executor {
    /// The proposed range clipped to the owner's bounds; `None` when nothing of
    /// it is left.
    pub async fn clip_to_bounds(
        &self,
        position_id: B256,
        lower: i32,
        upper: i32,
    ) -> Result<Option<(i32, i32)>> {
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        let lo_b = hook.boundLower(position_id).call().await?.as_i32();
        let hi_b = hook.boundUpper(position_id).call().await?.as_i32();
        Ok(clip_range(lower, upper, lo_b, hi_b))
    }

    /// A `PriceDeviation` always warrants a poke. A `PriceUnsettled` only when the
    /// reference is clamped short of spot: a reference already on spot settles
    /// by itself as quiet blocks pass, and a poke would change nothing (full
    /// audit LV-9).
    pub async fn poke_would_help(&self, position_id: B256, reason: &str) -> bool {
        use alloy::sol_types::SolError;
        let unsettled = revert_selector(reason)
            == Some(alloy::primitives::hex::encode(
                IAutopilotHook::PriceUnsettled::SELECTOR,
            ));
        if !unsettled {
            return true;
        }
        let Ok((_, pool_id)) = self.pool_of(position_id).await else {
            return true;
        };
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        hook.priceRef(pool_id)
            .call()
            .await
            .map(|r| r.clamped)
            .unwrap_or(true)
    }

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
        let hook = IAutopilotHook::new(self.hook, &self.provider);
        let call = hook.pokePriceRef(key);
        let tx = TransactionRequest::default()
            .with_from(self.signer)
            .with_to(self.hook)
            .with_input(call.calldata().clone());
        let r = self
            .send_capped(tx, max_gas_usd, eth_price)
            .await
            .map_err(|e| anyhow!("poke {e}"))?;
        if !r.success {
            bail!("poke tx {} reverted", r.tx_hash);
        }
        Ok(r.tx_hash)
    }
}

/// `[lower, upper]` clipped to `[min, max]`. The hook aligns bounds to the
/// pool's spacing, so the clipped ends stay aligned.
pub fn clip_range(lower: i32, upper: i32, min: i32, max: i32) -> Option<(i32, i32)> {
    let (lo, hi) = (lower.max(min), upper.min(max));
    (lo < hi).then_some((lo, hi))
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
    /// The position's own spend cap, from its stored config. The executor uses
    /// the lower of this and the global cap.
    pub max_gas_usd: Option<f64>,
}

pub struct AutoExec {
    pub max_gas_usd: f64,
    /// Live handle, not a snapshot: the spend cap is only as honest as the ETH
    /// price it is denominated in.
    pub eth_price: crate::chain::oracle::EthPrice,
    pub min_interval: Duration,
}

/// Bound on one iteration of the executor: a preflight, gas estimate, send and
/// receipt wait. Without it one hung RPC wedges the only executor for good, the
/// queue fills, and every intent after it is dropped (re-audit DS-7).
const ITERATION_SLACK: Duration = Duration::from_secs(60);
/// Pokes in one pool, without a rebalance landing there, before the daemon says
/// so: a reference that never catches up means someone is holding the price.
const POKE_ALERT_AFTER: u32 = 50;

pub async fn run_executor_loop(
    mut rx: tokio::sync::mpsc::Receiver<RebalanceIntent>,
    executor: Executor,
    cfg: AutoExec,
) {
    use futures_util::FutureExt;
    use std::collections::HashMap;
    use std::time::Instant;

    tracing::warn!(
        signer = %executor.signer(),
        max_gas_usd = cfg.max_gas_usd,
        "AUTO-EXECUTE enabled — the daemon will send real rebalance transactions"
    );
    let auto = automation();
    let iteration_limit = executor.tx_timeout + ITERATION_SLACK;
    let mut last: HashMap<String, Instant> = HashMap::new();
    let mut pokes = PokeState::default();
    let mut last_block: HashMap<String, (String, Instant)> = HashMap::new();
    let mut handled = 0u64;
    while let Some(intent) = rx.recv().await {
        auto.mark_dequeued(&intent.position_id);
        handled += 1;
        if handled.is_multiple_of(256) {
            let now = Instant::now();
            let day = Duration::from_secs(86_400);
            last.retain(|_, t| now.duration_since(*t) < day);
            last_block.retain(|_, (_, t)| now.duration_since(*t) < day);
            pokes.prune(now);
            auto.prune(now);
        }
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
        // A panic in one intent must not take the only executor down with it:
        // the queue would fill and every later intent be dropped, logged as
        // "queue full" (full audit, daemon Info).
        let work = std::panic::AssertUnwindSafe(handle_intent(
            &executor,
            &cfg,
            &intent,
            pid,
            &mut last,
            &mut last_block,
            &mut pokes,
        ))
        .catch_unwind();
        match tokio::time::timeout(iteration_limit, work).await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => {
                tracing::error!(position = %intent.position_id, "executor iteration panicked; continuing");
                auto.strike(&intent.position_id, Instant::now());
            }
            Err(_) => {
                tracing::warn!(position = %intent.position_id, limit_secs = iteration_limit.as_secs(), "executor iteration timed out; abandoned");
                // A send may already be out; treat the position as just acted on so
                // a second transaction is not raced against it (full audit LV-11).
                last.insert(intent.position_id.clone(), Instant::now());
                auto.strike(&intent.position_id, Instant::now());
            }
        }
    }
    tracing::error!(
        "intent channel closed; the executor has stopped and nothing will be rebalanced"
    );
}

async fn handle_intent(
    executor: &Executor,
    cfg: &AutoExec,
    intent: &RebalanceIntent,
    pid: B256,
    last: &mut std::collections::HashMap<String, std::time::Instant>,
    last_block: &mut std::collections::HashMap<String, (String, std::time::Instant)>,
    pokes: &mut PokeState,
) {
    use std::time::Instant;
    let auto = automation();
    let cap = intent
        .max_gas_usd
        .filter(|c| c.is_finite() && *c > 0.0)
        .map_or(cfg.max_gas_usd, |c| c.min(cfg.max_gas_usd));
    // The strategy centres on spot without knowing the owner's bounds; clip to
    // them here, so a position near a bound is not refused for crossing it.
    let (lower, upper) = match executor
        .clip_to_bounds(pid, intent.new_lower, intent.new_upper)
        .await
    {
        Ok(Some(r)) => r,
        Ok(None) => {
            tracing::debug!(position = %intent.position_id, "proposed range lies outside the owner's bounds");
            auto.strike(&intent.position_id, Instant::now());
            return;
        }
        Err(e) => {
            tracing::warn!(error = %crate::redact(&e), position = %intent.position_id, "could not read bounds");
            auto.strike(&intent.position_id, Instant::now());
            return;
        }
    };
    // Preflight first. A refused eth_call costs nothing, so it must not burn the
    // per-position interval — that is reserved for transactions actually sent.
    let sim = match executor.simulate(pid, lower, upper).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(error = %crate::redact(&e), position = %intent.position_id, "preflight call failed");
            auto.strike(&intent.position_id, Instant::now());
            return;
        }
    };
    if !sim.ok {
        let reason = sim.revert.unwrap_or_default();
        let action = classify_preflight(&reason);
        // Warn once per kind of refusal, then stay quiet: the sweep retries
        // every pass and would otherwise repeat the same line forever.
        let key = refusal_key(&reason);
        if last_block.get(&intent.position_id).map(|(k, _)| k) != Some(&key) {
            tracing::warn!(position = %intent.position_id, ?action, reason = %reason, "rebalance blocked at preflight");
        } else {
            tracing::debug!(position = %intent.position_id, ?action, "rebalance still blocked at preflight");
        }
        last_block.insert(intent.position_id.clone(), (key, Instant::now()));
        let wait = auto.on_refusal(&intent.position_id, action, Instant::now());
        if action == RefusalAction::Terminal {
            tracing::info!(position = %intent.position_id, suppress_secs = wait.as_secs(), "position will not be proposed again for a while");
        }
        if action == RefusalAction::Poke && executor.poke_would_help(pid, &reason).await {
            poke_once(executor, cfg, pid, &intent.position_id, pokes).await;
        }
        return;
    }
    last_block.remove(&intent.position_id);

    match executor
        .execute(pid, lower, upper, None, cap, &cfg.eth_price)
        .await
    {
        Ok(r) if r.success => {
            last.insert(intent.position_id.clone(), Instant::now());
            auto.on_success(&intent.position_id);
            if let Ok((_, pool_id)) = executor.pool_of(pid).await {
                pokes.settled(pool_id);
            }
            tracing::info!(tx = %r.tx_hash, gas_used = r.gas_used, position = %intent.position_id, "auto-rebalanced on-chain")
        }
        Ok(r) => {
            // Sent and mined, but reverted: something changed between preflight
            // and inclusion. Back off so a position whose transactions keep
            // reverting does not burn one every interval (re-audit DS-6).
            last.insert(intent.position_id.clone(), Instant::now());
            let wait = auto.strike(&intent.position_id, Instant::now());
            tracing::warn!(tx = %r.tx_hash, gas_used = r.gas_used, position = %intent.position_id, backoff_secs = wait.as_secs(), "rebalance tx REVERTED on-chain")
        }
        Err(ExecFailure::Unconfirmed { tx_hash, error }) => {
            last.insert(intent.position_id.clone(), Instant::now());
            tracing::warn!(tx = %tx_hash, error = %crate::redact(&error), position = %intent.position_id, "rebalance tx unconfirmed")
        }
        Err(ExecFailure::NotSent(e)) => {
            let wait = auto.strike(&intent.position_id, Instant::now());
            tracing::warn!(error = %crate::redact(&e), position = %intent.position_id, backoff_secs = wait.as_secs(), "auto-rebalance not sent (preflight/cap/budget)")
        }
    }
}

/// Per-pool poke throttle, and a count of pokes since a rebalance last landed
/// in the pool.
#[derive(Default)]
struct PokeState {
    last: std::collections::HashMap<B256, std::time::Instant>,
    since_settled: std::collections::HashMap<B256, u32>,
}

impl PokeState {
    fn settled(&mut self, pool_id: B256) {
        self.since_settled.remove(&pool_id);
    }

    fn prune(&mut self, now: std::time::Instant) {
        let hour = Duration::from_secs(3600);
        self.last.retain(|_, t| now.duration_since(*t) < hour);
        let live: std::collections::HashSet<B256> = self.last.keys().copied().collect();
        self.since_settled.retain(|k, _| live.contains(k));
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
    pokes: &mut PokeState,
) {
    let (key, pool_id) = match executor.pool_of(pid).await {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!(error = %crate::redact(&e), position = %position_id, "could not resolve pool to poke");
            return;
        }
    };
    // Several positions can share a pool, and the sweep proposes each of them
    // every pass; throttle on the pool before spending anything.
    if !poke_due(pokes.last.get(&pool_id).copied(), std::time::Instant::now()) {
        return;
    }
    pokes.last.insert(pool_id, std::time::Instant::now());
    match executor.poke(key, cfg.max_gas_usd, &cfg.eth_price).await {
        Ok(tx) => {
            tracing::info!(tx = %tx, position = %position_id, "poked price reference toward spot");
            let n = pokes.since_settled.entry(pool_id).or_insert(0);
            *n += 1;
            if *n == POKE_ALERT_AFTER {
                // A reference that never settles means spot is not sitting still:
                // genuine turbulence, or someone holding the price. Either way an
                // operator should look (re-audit PR-3).
                tracing::warn!(pool = %pool_id, pokes = *n, "price reference is not settling despite repeated pokes; rebalances in this pool are on hold");
            }
        }
        Err(e) => {
            tracing::warn!(error = %crate::redact(&e), position = %position_id, "price-reference poke failed")
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
        assert_eq!(classify_preflight(&text), RefusalAction::Poke);
        assert_eq!(
            classify_preflight(&text.to_uppercase()),
            RefusalAction::Poke
        );
    }

    #[test]
    fn other_reverts_are_not_poked() {
        // RebalanceTooSoon — resolves with time, not with a poke.
        assert_eq!(
            classify_preflight("execution reverted, data: \"0x2ddcae9c0000\""),
            RefusalAction::Cooldown
        );
        assert_eq!(classify_preflight(""), RefusalAction::Retry);
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

    #[test]
    fn every_refusal_maps_to_its_action() {
        use alloy::sol_types::SolError;
        use IAutopilotHook as H;
        let text = |sel: [u8; 4]| {
            format!(
                "execution reverted: custom error 0x{}: 00",
                alloy::primitives::hex::encode(sel)
            )
        };
        assert_eq!(
            classify_preflight(&text(H::PriceUnsettled::SELECTOR)),
            RefusalAction::Poke
        );
        assert_eq!(
            classify_preflight(&text(H::OutOfBounds::SELECTOR)),
            RefusalAction::Retry
        );
        for sel in [
            H::AutomationDisabled::SELECTOR,
            H::NotRebalancer::SELECTOR,
            H::PositionNotActive::SELECTOR,
        ] {
            assert_eq!(classify_preflight(&text(sel)), RefusalAction::Terminal);
        }
        assert_eq!(
            classify_preflight(&text(H::RebalanceTooSoon::SELECTOR)),
            RefusalAction::Cooldown
        );
        // ValueLossExceeded and anything unknown: retried with backoff.
        assert_eq!(
            classify_preflight("custom error 0x79ae6f69: 00"),
            RefusalAction::Retry
        );
    }

    #[test]
    fn hook_error_selectors_match_the_contract() {
        use alloy::sol_types::SolError;
        use IAutopilotHook as H;
        let hex = |s: [u8; 4]| alloy::primitives::hex::encode(s);
        // cast sig "<error>"
        assert_eq!(
            hex(H::PriceUnsettled::SELECTOR),
            hex(alloy::primitives::keccak256("PriceUnsettled(uint8)")[..4]
                .try_into()
                .unwrap())
        );
        assert_eq!(
            hex(H::AutomationDisabled::SELECTOR),
            hex(alloy::primitives::keccak256("AutomationDisabled()")[..4]
                .try_into()
                .unwrap())
        );
        assert_eq!(hex(H::RebalanceTooSoon::SELECTOR), "2ddcae9c");
    }

    #[test]
    fn fee_plan_caps_the_priority_fee_and_outbids_a_stuck_nonce() {
        let gwei = 1_000_000_000u128;
        // A node or relay suggesting 100,000 gwei is capped.
        let p = plan_fees(7, 200_000, 10 * gwei, 100_000 * gwei, 5 * gwei, None);
        assert_eq!(p.max_priority_fee_per_gas, 5 * gwei);
        assert_eq!(p.max_fee_per_gas, 25 * gwei);
        assert_eq!(p.gas_limit, 250_000);
        assert_eq!(p.nonce, 7);
        // Replacing our own stuck transaction at the same nonce outbids it.
        let r = plan_fees(
            7,
            200_000,
            10 * gwei,
            gwei,
            5 * gwei,
            Some((7, 40 * gwei, 2 * gwei)),
        );
        assert!(r.max_fee_per_gas > 40 * gwei * 9 / 8);
        assert!(r.max_priority_fee_per_gas > 2 * gwei * 9 / 8);
        assert!(r.max_priority_fee_per_gas <= 5 * gwei, "still capped");
        // A stuck transaction at an older nonce does not affect the next one.
        let next = plan_fees(
            8,
            200_000,
            10 * gwei,
            gwei,
            5 * gwei,
            Some((7, 40 * gwei, 2 * gwei)),
        );
        assert_eq!(next.max_fee_per_gas, 21 * gwei);
    }

    #[test]
    fn selector_is_read_from_the_leading_bytes_only() {
        // PriceDeviation's selector inside another error's argument must not
        // reclassify it (full audit LV-12).
        let t = "execution reverted: custom error 0x2ddcae9c: 000000000000000000000000000000000000000000000000000000001782bd94";
        assert_eq!(revert_selector(t).as_deref(), Some("2ddcae9c"));
        assert_eq!(classify_preflight(t), RefusalAction::Cooldown);
        assert_eq!(
            revert_selector(
                "server returned an error response: execution reverted, data: \"0x1782bd94000000\""
            ),
            Some("1782bd94".to_string())
        );
        assert_eq!(revert_selector("connection refused"), None);
    }

    #[test]
    fn proposals_are_clipped_to_the_owner_bounds() {
        assert_eq!(clip_range(780, 1260, -1200, 1200), Some((780, 1200)));
        assert_eq!(clip_range(-1500, -300, -1200, 1200), Some((-1200, -300)));
        assert_eq!(clip_range(1260, 1500, -1200, 1200), None);
        assert_eq!(clip_range(-600, 600, -1200, 1200), Some((-600, 600)));
    }
}

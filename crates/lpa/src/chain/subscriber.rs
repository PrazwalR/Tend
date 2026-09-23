use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy::primitives::{Address, B256};
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::types::{Filter, Log};
use alloy::sol;
use alloy::sol_types::SolEvent;
use anyhow::Result;
use dashmap::DashMap;
use futures_util::StreamExt;
use tokio::time::{sleep, timeout};
use tracing::{debug, error, info, warn};

use tokio::sync::mpsc;

use crate::chain::config::ChainConfig;
use crate::chain::oracle::EthPrice;
use crate::chain::reader::ChainReader;
use crate::exec::RebalanceIntent;
use crate::position::tracker::{PositionRow, Tracker};
use crate::proto::PositionConfig;
use crate::strategy::{
    default_config, CostModel, DecideInput, LiveCostModel, StrategyEngine, DEFAULT_FEE_PIPS,
    DEFAULT_TICK_SPACING,
};

sol! {
    event Swap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed owner,
        bytes32 indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint24 fee,
        int24 tickSpacing
    );

    event PositionClosed(bytes32 indexed positionId, address indexed owner, uint128 liquidity);

    event Rebalanced(
        bytes32 indexed positionId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 oldLiquidity,
        uint128 newLiquidity
    );
}

/// Ticks kept per pool in `tick_history` (older rows pruned).
const TICK_RETENTION: usize = 2000;
/// Prune `tick_history` every N processed logs.
const PRUNE_EVERY: u32 = 500;
/// Gas price assumed until the first live fetch lands (5 gwei).
const INITIAL_GAS_PRICE_WEI: u64 = 5_000_000_000;
/// Default seconds of silence before the WS heartbeat health-check runs.
const DEFAULT_HEARTBEAT_SECS: u64 = 30;
/// Timeout for the heartbeat block-number probe.
const HEALTH_PROBE_TIMEOUT_SECS: u64 = 5;
/// A connection alive this long resets the reconnect backoff.
const CONNECTION_STABLE_SECS: u64 = 60;
/// Tick-history lookback fed to the strategy on an OOR event.
const STRATEGY_TICK_WINDOW: usize = 200;
/// Blocks per `eth_getLogs` request while catching up; providers cap the span.
const BACKFILL_CHUNK_BLOCKS: u64 = 500;
/// Refuse to backfill further than this behind head — beyond it the tick
/// history is stale anyway and a full scan would hammer the RPC.
const BACKFILL_MAX_BLOCKS: u64 = 100_000;

enum WatchEnd {
    Shutdown,
    StreamEnded,
}

/// Everything the log handlers need, so the hot path passes one reference
/// instead of eight positional arguments.
struct Ctx<'a> {
    tracker: &'a Arc<Tracker>,
    engine: &'a StrategyEngine,
    cost: &'a dyn CostModel,
    config: &'a PositionConfig,
    chain_id: u64,
    reader: Option<&'a ChainReader>,
    intent_tx: Option<&'a mpsc::Sender<RebalanceIntent>>,
    last_block: DashMap<B256, u64>,
}

impl<'a> Ctx<'a> {
    fn chain_key(&self) -> String {
        self.chain_id.to_string()
    }
}

fn store_gas_price(slot: &AtomicU64, wei: u128) {
    slot.store(wei.min(u128::from(u64::MAX)) as u64, Ordering::Relaxed);
}

pub async fn run_watch(
    cfg: ChainConfig,
    tracker: Arc<Tracker>,
    hook: Option<Address>,
    intent_tx: Option<mpsc::Sender<RebalanceIntent>>,
    eth_price: EthPrice,
) -> Result<()> {
    let engine = StrategyEngine::default();
    let gas_price = Arc::new(AtomicU64::new(INITIAL_GAS_PRICE_WEI));

    let cost = LiveCostModel::new(gas_price.clone(), eth_price);
    let config = default_config();

    let reader = match hook {
        Some(h) => match cfg.http_url() {
            Ok(url) => match ChainReader::connect(&url, h, cfg.addrs.state_view).await {
                Ok(r) => Some(r),
                Err(e) => {
                    warn!(error = %e, "HTTP reader unavailable; reorg resync disabled");
                    None
                }
            },
            Err(e) => {
                warn!(error = %e, "no HTTP RPC configured; reorg resync disabled");
                None
            }
        },
        None => None,
    };

    let mut attempt = 0u32;
    loop {
        let started = Instant::now();
        let ctx = Ctx {
            tracker: &tracker,
            engine: &engine,
            cost: &cost,
            config: &config,
            chain_id: cfg.chain_id,
            reader: reader.as_ref(),
            intent_tx: intent_tx.as_ref(),
            last_block: DashMap::new(),
        };
        match watch_once(&cfg, &ctx, hook, &gas_price).await {
            Ok(WatchEnd::Shutdown) => {
                info!("shutdown signal received");
                return Ok(());
            }
            Ok(WatchEnd::StreamEnded) => warn!("WS log stream ended"),
            Err(e) => error!(error = %e, "WS watch connection error"),
        }

        if started.elapsed() >= Duration::from_secs(CONNECTION_STABLE_SECS) {
            attempt = 0;
        }
        let backoff = next_backoff(attempt);
        attempt = attempt.saturating_add(1);
        warn!(secs = backoff.as_secs(), "reconnecting after backoff");
        tokio::select! {
            _ = sleep(backoff) => {}
            _ = tokio::signal::ctrl_c() => {
                info!("shutdown during backoff");
                return Ok(());
            }
        }
    }
}

async fn watch_once(
    cfg: &ChainConfig,
    ctx: &Ctx<'_>,
    hook: Option<Address>,
    gas_price: &AtomicU64,
) -> Result<WatchEnd> {
    let ws_url = cfg.ws_url()?;
    let provider = ProviderBuilder::new()
        .connect_ws(WsConnect::new(ws_url))
        .await?;
    info!(
        chain = cfg.name,
        chain_id = cfg.chain_id,
        "connected to WS RPC"
    );
    if let Ok(gp) = provider.get_gas_price().await {
        store_gas_price(gas_price, gp);
    }

    let swap_filter = Filter::new()
        .address(cfg.addrs.pool_manager)
        .event_signature(Swap::SIGNATURE_HASH);
    let swap_stream = provider.subscribe_logs(&swap_filter).await?.into_stream();
    info!(pool_manager = %cfg.addrs.pool_manager, "subscribed to v4 Swap events");

    let mut stream = match hook {
        Some(h) => {
            let hook_filter = Filter::new().address(h).event_signature(vec![
                PositionOpened::SIGNATURE_HASH,
                PositionClosed::SIGNATURE_HASH,
                Rebalanced::SIGNATURE_HASH,
            ]);
            let hook_stream = provider.subscribe_logs(&hook_filter).await?.into_stream();
            info!(hook = %h, "indexing AutopilotHook position events");
            futures_util::stream::select(swap_stream, hook_stream).boxed()
        }
        None => swap_stream.boxed(),
    };

    // Subscriptions only deliver logs from now on. Anything that happened while
    // the daemon was down is replayed here before the live stream is served.
    if let Err(e) = backfill(&provider, cfg, ctx, hook).await {
        warn!(error = %e, "backfill failed; continuing on live stream only");
    }

    let heartbeat = Duration::from_secs(
        std::env::var("LPA_WS_HEARTBEAT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_HEARTBEAT_SECS),
    );
    let mut since_prune = 0u32;
    loop {
        tokio::select! {
            maybe_log = stream.next() => match maybe_log {
                Some(log) => {
                    let block = log.block_number;
                    if let Err(e) = handle(ctx, log).await {
                        error!(error = %e, "log handling error");
                    }
                    if let Some(b) = block {
                        if let Err(e) = ctx.tracker.set_last_indexed_block(&ctx.chain_key(), b) {
                            warn!(error = %e, "watermark update failed");
                        }
                    }
                    since_prune += 1;
                    if since_prune >= PRUNE_EVERY {
                        since_prune = 0;
                        if let Err(e) = ctx.tracker.prune_all_ticks(TICK_RETENTION) {
                            warn!(error = %e, "tick prune failed");
                        }
                    }
                }
                None => return Ok(WatchEnd::StreamEnded),
            },
            _ = sleep(heartbeat) => {
                match timeout(Duration::from_secs(HEALTH_PROBE_TIMEOUT_SECS), provider.get_block_number()).await {
                    Ok(Ok(head)) => {
                        if let Ok(gp) = provider.get_gas_price().await {
                            store_gas_price(gas_price, gp);
                        }
                        // A quiet pool is still indexed ground; record it so a
                        // restart does not re-scan blocks that held no logs.
                        if let Err(e) = ctx.tracker.set_last_indexed_block(&ctx.chain_key(), head) {
                            warn!(error = %e, "watermark update failed");
                        }
                    }
                    _ => {
                        warn!("WS heartbeat health-check failed; forcing reconnect");
                        return Ok(WatchEnd::StreamEnded);
                    }
                }
            }
            _ = tokio::signal::ctrl_c() => return Ok(WatchEnd::Shutdown),
        }
    }
}

/// Replays logs between the stored watermark and current head. Hook events are
/// fetched across all pools; `Swap` events only for pools we actually track,
/// because an unfiltered v4 `Swap` scan would return every swap on the chain.
async fn backfill<P: Provider>(
    provider: &P,
    cfg: &ChainConfig,
    ctx: &Ctx<'_>,
    hook: Option<Address>,
) -> Result<()> {
    let head = provider.get_block_number().await?;
    let Some(watermark) = ctx.tracker.last_indexed_block(&ctx.chain_key())? else {
        ctx.tracker.set_last_indexed_block(&ctx.chain_key(), head)?;
        info!(head, "no watermark stored; indexing from current head");
        return Ok(());
    };
    if watermark >= head {
        return Ok(());
    }

    let span = head - watermark;
    let from = if span > BACKFILL_MAX_BLOCKS {
        warn!(
            span,
            max = BACKFILL_MAX_BLOCKS,
            "watermark too far behind; truncating backfill"
        );
        head - BACKFILL_MAX_BLOCKS
    } else {
        watermark + 1
    };

    let pools = ctx.tracker.distinct_pool_ids()?;
    let pool_topics: Vec<B256> = pools
        .iter()
        .filter_map(|p| p.parse::<B256>().ok())
        .collect();
    info!(
        from,
        to = head,
        pools = pool_topics.len(),
        "backfilling missed logs"
    );

    let mut start = from;
    let mut replayed = 0usize;
    while start <= head {
        let end = (start + BACKFILL_CHUNK_BLOCKS - 1).min(head);

        if let Some(h) = hook {
            let f = Filter::new()
                .address(h)
                .event_signature(vec![
                    PositionOpened::SIGNATURE_HASH,
                    PositionClosed::SIGNATURE_HASH,
                    Rebalanced::SIGNATURE_HASH,
                ])
                .from_block(start)
                .to_block(end);
            for log in provider.get_logs(&f).await? {
                handle(ctx, log).await?;
                replayed += 1;
            }
        }

        if !pool_topics.is_empty() {
            let f = Filter::new()
                .address(cfg.addrs.pool_manager)
                .event_signature(Swap::SIGNATURE_HASH)
                .topic1(pool_topics.clone())
                .from_block(start)
                .to_block(end);
            for log in provider.get_logs(&f).await? {
                handle(ctx, log).await?;
                replayed += 1;
            }
        }

        ctx.tracker.set_last_indexed_block(&ctx.chain_key(), end)?;
        start = end + 1;
    }
    info!(replayed, "backfill complete");
    Ok(())
}

fn next_backoff(attempt: u32) -> Duration {
    let secs = (1u64 << attempt.min(5)).min(30);
    Duration::from_secs(secs)
}

async fn handle(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let topic = log.topic0().copied();
    if log.removed {
        return handle_removed(ctx, topic, log).await;
    }
    match topic {
        Some(t) if t == Swap::SIGNATURE_HASH => handle_swap(ctx, log).await,
        Some(t) if t == PositionOpened::SIGNATURE_HASH => handle_opened(ctx, log),
        Some(t) if t == PositionClosed::SIGNATURE_HASH => handle_closed(ctx, log),
        Some(t) if t == Rebalanced::SIGNATURE_HASH => handle_rebalanced(ctx, log),
        _ => Ok(()),
    }
}

/// A reorg dropped a log we may already have acted on. Swap logs need no
/// undo — the next swap overwrites the tick. Position lifecycle logs do, and
/// rather than invert them (which cannot restore a deleted row) we re-read the
/// hook's storage, which is authoritative for the canonical chain.
async fn handle_removed(ctx: &Ctx<'_>, topic: Option<B256>, log: Log) -> Result<()> {
    let is_position_event = matches!(topic,
        Some(t) if t == PositionOpened::SIGNATURE_HASH
            || t == PositionClosed::SIGNATURE_HASH
            || t == Rebalanced::SIGNATURE_HASH
    );
    if !is_position_event {
        warn!(block = ?log.block_number, "reorg: removed swap log skipped");
        return Ok(());
    }
    let Some(position_id) = log.topics().get(1).copied() else {
        return Ok(());
    };
    warn!(position_id = %format!("{:#x}", position_id), block = ?log.block_number, "reorg: resyncing position from chain");
    resync_position(ctx, position_id).await
}

async fn resync_position(ctx: &Ctx<'_>, position_id: B256) -> Result<()> {
    let id_hex = format!("{:#x}", position_id);
    let Some(reader) = ctx.reader else {
        warn!(position_id = %id_hex, "no HTTP reader; cannot resync after reorg");
        return Ok(());
    };
    match reader.hook_position(position_id).await {
        Ok(Some(p)) if p.active => {
            let stored = ctx.tracker.get_position(&id_hex)?;
            ctx.tracker.register(&PositionRow {
                position_id: id_hex.clone(),
                owner: format!("{:#x}", p.owner),
                pool_id: format!("{:#x}", p.pool_id),
                chain_id: ctx.chain_key(),
                tick_lower: p.tick_lower,
                tick_upper: p.tick_upper,
                current_tick: stored.as_ref().and_then(|s| s.current_tick),
                in_range: stored.as_ref().is_some_and(|s| s.in_range),
                entry_tick: stored
                    .as_ref()
                    .and_then(|s| s.entry_tick)
                    .or(Some((p.tick_lower + p.tick_upper) / 2)),
                fee: Some(p.fee),
                tick_spacing: Some(p.tick_spacing),
            })?;
            info!(position_id = %id_hex, tick_lower = p.tick_lower, tick_upper = p.tick_upper, "resynced position from hook storage");
        }
        Ok(_) => {
            ctx.tracker.delete_position(&id_hex)?;
            info!(position_id = %id_hex, "position absent on canonical chain; dropped");
        }
        Err(e) => warn!(error = %e, position_id = %id_hex, "resync read failed"),
    }
    Ok(())
}

async fn handle_swap(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match Swap::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %e, "event decode failed; skipping log");
            return Ok(());
        }
    };
    let pool_id = ev.id;
    let pool_hex = format!("{:#x}", pool_id);
    let tick = ev.tick.as_i32();
    let block = log.block_number.unwrap_or(0);

    let crosses = ctx.tracker.update_pool_tick(&pool_hex, tick)?;
    for cx in &crosses {
        if cx.was_in_range && !cx.now_in_range {
            warn!(position_id = %cx.position_id, tick, "position EXITED range");
            propose_rebalance(ctx, &pool_hex, tick, &cx.position_id).await;
        } else if !cx.was_in_range && cx.now_in_range {
            info!(position_id = %cx.position_id, tick, "position re-entered range");
        }
    }

    if !crosses.is_empty() {
        let new_block = ctx
            .last_block
            .get(&pool_id)
            .map(|v| *v != block)
            .unwrap_or(true);
        if new_block {
            ctx.last_block.insert(pool_id, block);
            ctx.tracker.record_tick(&pool_hex, tick, block)?;
        }
    }

    debug!(pool = %pool_hex, tick, block, "swap");
    Ok(())
}

fn handle_opened(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match PositionOpened::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %e, "event decode failed; skipping log");
            return Ok(());
        }
    };
    let position_id = format!("{:#x}", ev.positionId);
    let tick_lower = ev.tickLower.as_i32();
    let tick_upper = ev.tickUpper.as_i32();
    ctx.tracker.register(&PositionRow {
        position_id: position_id.clone(),
        owner: format!("{:#x}", ev.owner),
        pool_id: format!("{:#x}", ev.poolId),
        chain_id: ctx.chain_key(),
        tick_lower,
        tick_upper,
        current_tick: None,
        in_range: false,
        entry_tick: Some((tick_lower + tick_upper) / 2),
        fee: Some(ev.fee.to::<u32>()),
        tick_spacing: Some(ev.tickSpacing.as_i32()),
    })?;
    info!(position_id = %position_id, tick_lower, tick_upper, "indexed PositionOpened");
    Ok(())
}

fn handle_closed(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match PositionClosed::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %e, "event decode failed; skipping log");
            return Ok(());
        }
    };
    let position_id = format!("{:#x}", ev.positionId);
    ctx.tracker.delete_position(&position_id)?;
    info!(position_id = %position_id, "indexed PositionClosed");
    Ok(())
}

fn handle_rebalanced(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match Rebalanced::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %e, "event decode failed; skipping log");
            return Ok(());
        }
    };
    let position_id = format!("{:#x}", ev.positionId);
    let lower = ev.newTickLower.as_i32();
    let upper = ev.newTickUpper.as_i32();
    ctx.tracker.update_range(&position_id, lower, upper)?;
    info!(position_id = %position_id, new_lower = lower, new_upper = upper, "indexed Rebalanced");
    Ok(())
}

/// Values the position in USD so the EV gate can price IL and friction. Needs
/// both a chain read and an operator-supplied USD price for token1 (there is no
/// general way to price an arbitrary pair); returns 0 — meaning unknown — if
/// either is missing, which leaves the gate fee-and-gas only.
async fn position_value_usd(ctx: &Ctx<'_>, p: &PositionRow) -> f64 {
    let Some(reader) = ctx.reader else { return 0.0 };
    let token1_usd = std::env::var("LPA_TOKEN1_USD")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0);
    if token1_usd <= 0.0 {
        return 0.0;
    }
    let (Ok(pool_id), Ok(position_id)) = (p.pool_id.parse::<B256>(), p.position_id.parse::<B256>())
    else {
        return 0.0;
    };
    let Ok(snap) = reader
        .position_snapshot(pool_id, position_id, p.tick_lower, p.tick_upper)
        .await
    else {
        return 0.0;
    };
    let price = 1.0001f64.powi(snap.current_tick);
    let to_f64 = |v: alloy::primitives::U256| -> f64 { format!("{v}").parse().unwrap_or(0.0) };
    let value_token1 = to_f64(snap.amount0) * price + to_f64(snap.amount1);
    if !value_token1.is_finite() {
        return 0.0;
    }
    value_token1 * token1_usd
}

async fn propose_rebalance(ctx: &Ctx<'_>, pool_hex: &str, tick: i32, position_id: &str) {
    let Ok(Some(pos)) = ctx.tracker.get_position(position_id) else {
        return;
    };
    let ticks = ctx
        .tracker
        .recent_ticks(pool_hex, STRATEGY_TICK_WINDOW)
        .unwrap_or_default();
    let weighted = ctx
        .tracker
        .recent_ticks_weighted(pool_hex, STRATEGY_TICK_WINDOW)
        .unwrap_or_default();
    let entry_tick = pos
        .entry_tick
        .unwrap_or((pos.tick_lower + pos.tick_upper) / 2);
    let input = DecideInput {
        pool_id: pool_hex,
        chain_id: &pos.chain_id,
        current_tick: tick,
        entry_tick,
        cur_lower: pos.tick_lower,
        cur_upper: pos.tick_upper,
        tick_spacing: pos.tick_spacing.unwrap_or(DEFAULT_TICK_SPACING),
        fee_pips: pos.fee.unwrap_or(DEFAULT_FEE_PIPS),
        ticks: &ticks,
        weighted: &weighted,
        config: ctx.config,
        position_value_usd: position_value_usd(ctx, &pos).await,
    };
    let Some(d) = ctx.engine.decide(&input, ctx.cost) else {
        return;
    };
    match ctx.intent_tx {
        Some(tx) => {
            let intent = RebalanceIntent {
                position_id: pos.position_id.clone(),
                new_lower: d.new_lower,
                new_upper: d.new_upper,
            };
            match tx.try_send(intent) {
                Ok(()) => {
                    info!(position_id = %pos.position_id, new_lower = d.new_lower, new_upper = d.new_upper, "auto-execute intent queued")
                }
                Err(_) => {
                    warn!(position_id = %pos.position_id, "auto-execute queue full; dropped intent")
                }
            }
        }
        None => warn!(
            position_id = %pos.position_id,
            new_lower = d.new_lower,
            new_upper = d.new_upper,
            est_cost_usd = d.est_cost_usd,
            reason = %d.reason,
            "rebalance proposed (run `lpa rebalance` with this position id)"
        ),
    }
}
#[cfg(test)]
mod tests {
    use super::{handle, next_backoff, Ctx, PositionClosed, PositionOpened, Rebalanced, Swap};
    use crate::position::tracker::{PositionRow, Tracker};
    use crate::strategy::{default_config, EstimateCostModel, StrategyEngine};
    use alloy::primitives::aliases::{I24, U160, U24};
    use alloy::primitives::{address, b256, Log as PrimLog, B256};
    use alloy::rpc::types::Log as RpcLog;
    use alloy::sol_types::SolEvent;
    use dashmap::DashMap;
    use std::sync::Arc;

    #[test]
    fn event_signatures_match_hook() {
        assert_eq!(
            Swap::SIGNATURE_HASH,
            b256!("0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f")
        );
        assert_eq!(
            PositionOpened::SIGNATURE_HASH,
            b256!("0x01752da74706270d395215d4fcfe2c2b8d96be1d03425d74c6a3344378b06f19")
        );
        assert_eq!(
            PositionClosed::SIGNATURE_HASH,
            b256!("0xd5a6e70d8c0a0d3ee72a24b6e020f66494e0e9caeabecc6d3185ffadcdeacb89")
        );
        assert_eq!(
            Rebalanced::SIGNATURE_HASH,
            b256!("0xb8e792201f7f1a3050cf6ccd3b36c71d64e15d197bbbcd6dfcbcd25ee9c7983a")
        );
    }

    #[test]
    fn backoff_grows_then_caps() {
        assert_eq!(next_backoff(0).as_secs(), 1);
        assert_eq!(next_backoff(1).as_secs(), 2);
        assert_eq!(next_backoff(4).as_secs(), 16);
        assert_eq!(next_backoff(5).as_secs(), 30);
        assert_eq!(next_backoff(100).as_secs(), 30);
    }

    struct Env {
        engine: StrategyEngine,
        cost: EstimateCostModel,
        config: crate::proto::PositionConfig,
    }

    fn env() -> Env {
        Env {
            engine: StrategyEngine::default(),
            cost: EstimateCostModel,
            config: default_config(),
        }
    }

    fn ctx<'a>(tracker: &'a Arc<Tracker>, e: &'a Env) -> Ctx<'a> {
        Ctx {
            tracker,
            engine: &e.engine,
            cost: &e.cost,
            config: &e.config,
            chain_id: 8453,
            reader: None,
            intent_tx: None,
            last_block: DashMap::new(),
        }
    }

    fn swap_log(pool: B256, tick: i32, removed: bool) -> RpcLog {
        let ev = Swap {
            id: pool,
            sender: address!("0x0000000000000000000000000000000000000001"),
            amount0: 0i128,
            amount1: 0i128,
            sqrtPriceX96: U160::ZERO,
            liquidity: 0u128,
            tick: I24::try_from(tick).unwrap(),
            fee: U24::from(3000u32),
        };
        let inner = PrimLog {
            address: address!("0x498581ff718922c3f8e6a244956af099b2652b2b"),
            data: ev.encode_log_data(),
        };
        RpcLog {
            inner,
            block_number: Some(1),
            removed,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn removed_log_skipped_but_valid_recorded() {
        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        let pool = b256!("0x2222222222222222222222222222222222222222222222222222222222222222");
        let pool_hex = format!("{:#x}", pool);
        tracker
            .register(&PositionRow {
                position_id: "0xpos".into(),
                owner: "0x1111111111111111111111111111111111111111".into(),
                pool_id: pool_hex.clone(),
                chain_id: "8453".into(),
                tick_lower: 100,
                tick_upper: 200,
                current_tick: None,
                in_range: false,
                entry_tick: Some(150),
                fee: None,
                tick_spacing: None,
            })
            .unwrap();
        let e = env();
        let c = ctx(&tracker, &e);

        handle(&c, swap_log(pool, 150, false)).await.unwrap();
        assert_eq!(tracker.recent_ticks(&pool_hex, 10).unwrap(), vec![150]);

        handle(&c, swap_log(pool, 160, true)).await.unwrap();
        assert_eq!(
            tracker.recent_ticks(&pool_hex, 10).unwrap(),
            vec![150],
            "removed log must not record"
        );
    }

    #[tokio::test]
    async fn indexes_position_opened_and_closed() {
        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        let e = env();
        let c = ctx(&tracker, &e);
        let pos_id = b256!("0x00000000000000000000000000000000000000000000000000000000000000aa");
        let pool = b256!("0x00000000000000000000000000000000000000000000000000000000000000bb");
        let hook = address!("0x00000000000000000000000000000000000000ff");

        let opened = PositionOpened {
            positionId: pos_id,
            owner: address!("0x1111111111111111111111111111111111111111"),
            poolId: pool,
            tickLower: I24::try_from(-600).unwrap(),
            tickUpper: I24::try_from(600).unwrap(),
            liquidity: 1_000_000u128,
            fee: U24::from(3000u32),
            tickSpacing: I24::try_from(60).unwrap(),
        };
        let log = RpcLog {
            inner: PrimLog {
                address: hook,
                data: opened.encode_log_data(),
            },
            block_number: Some(2),
            removed: false,
            ..Default::default()
        };
        handle(&c, log).await.unwrap();
        let id_hex = format!("{:#x}", pos_id);
        let p = tracker.get_position(&id_hex).unwrap().expect("indexed");
        assert_eq!((p.tick_lower, p.tick_upper), (-600, 600));
        assert_eq!(p.pool_id, format!("{:#x}", pool));
        assert_eq!(p.fee, Some(3000), "fee indexed from event");
        assert_eq!(p.tick_spacing, Some(60), "tick_spacing indexed from event");

        let closed = PositionClosed {
            positionId: pos_id,
            owner: address!("0x1111111111111111111111111111111111111111"),
            liquidity: 1_000_000u128,
        };
        let clog = RpcLog {
            inner: PrimLog {
                address: hook,
                data: closed.encode_log_data(),
            },
            block_number: Some(3),
            removed: false,
            ..Default::default()
        };
        handle(&c, clog).await.unwrap();
        assert!(
            tracker.get_position(&id_hex).unwrap().is_none(),
            "closed position removed"
        );
    }

    fn hook_log(topic0: B256, position_id: B256, removed: bool) -> RpcLog {
        let inner = PrimLog {
            address: address!("0x00000000000000000000000000000000000000ff"),
            data: alloy::primitives::LogData::new_unchecked(
                vec![topic0, position_id],
                Default::default(),
            ),
        };
        RpcLog {
            inner,
            block_number: Some(9),
            removed,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn removed_position_log_without_reader_leaves_state_intact() {
        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        tracker
            .register(&PositionRow {
                position_id: "0x00000000000000000000000000000000000000000000000000000000000000aa"
                    .into(),
                owner: "0x1111111111111111111111111111111111111111".into(),
                pool_id: "0xpool".into(),
                chain_id: "8453".into(),
                tick_lower: -600,
                tick_upper: 600,
                current_tick: Some(0),
                in_range: true,
                entry_tick: Some(0),
                fee: Some(3000),
                tick_spacing: Some(60),
            })
            .unwrap();
        let e = env();
        let c = ctx(&tracker, &e);
        let pid = b256!("0x00000000000000000000000000000000000000000000000000000000000000aa");

        handle(&c, hook_log(PositionOpened::SIGNATURE_HASH, pid, true))
            .await
            .unwrap();

        let id_hex = format!("{:#x}", pid);
        assert!(
            tracker.get_position(&id_hex).unwrap().is_some(),
            "no reader configured must not silently drop the position"
        );
    }

    #[test]
    fn watermark_advances_and_never_rewinds() {
        let tracker = Tracker::open_in_memory().unwrap();
        assert_eq!(tracker.last_indexed_block("8453").unwrap(), None);
        tracker.set_last_indexed_block("8453", 100).unwrap();
        assert_eq!(tracker.last_indexed_block("8453").unwrap(), Some(100));
        tracker.set_last_indexed_block("8453", 50).unwrap();
        assert_eq!(
            tracker.last_indexed_block("8453").unwrap(),
            Some(100),
            "a late log must not rewind the watermark"
        );
        tracker.set_last_indexed_block("8453", 150).unwrap();
        assert_eq!(tracker.last_indexed_block("8453").unwrap(), Some(150));
        assert_eq!(
            tracker.last_indexed_block("1").unwrap(),
            None,
            "watermark is per chain"
        );
    }

    #[test]
    fn distinct_pool_ids_dedupes() {
        let tracker = Tracker::open_in_memory().unwrap();
        for (i, pool) in ["0xaaa", "0xaaa", "0xbbb"].iter().enumerate() {
            tracker
                .register(&PositionRow {
                    position_id: format!("0xpos{i}"),
                    owner: "0x1111111111111111111111111111111111111111".into(),
                    pool_id: (*pool).into(),
                    chain_id: "8453".into(),
                    tick_lower: -600,
                    tick_upper: 600,
                    current_tick: None,
                    in_range: false,
                    entry_tick: None,
                    fee: None,
                    tick_spacing: None,
                })
                .unwrap();
        }
        let mut pools = tracker.distinct_pool_ids().unwrap();
        pools.sort();
        assert_eq!(pools, vec!["0xaaa".to_string(), "0xbbb".to_string()]);
    }
}

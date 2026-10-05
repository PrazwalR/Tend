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
use tokio::time::{interval, sleep, timeout, MissedTickBehavior};
use tracing::{debug, error, info, warn};

use tokio::sync::mpsc;

use crate::chain::config::ChainConfig;
use crate::chain::oracle::EthPrice;
use crate::chain::reader::ChainReader;
use crate::exec::automation::automation;
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
/// Default seconds between sweeps for stuck or under-deployed positions.
const DEFAULT_SWEEP_SECS: u64 = 30;
/// Items buffered per log subscription before alloy starts skipping them.
const SUBSCRIPTION_BUFFER: usize = 4096;
/// Upper bound on one sweep pass; see the watch loop.
const SWEEP_TIMEOUT: Duration = Duration::from_secs(20);
/// Idle share of a position, in bps, worth a transaction to place. Below it the
/// idle balance waits for the next rebalance, which folds it in for free.
const DEFAULT_IDLE_REDEPLOY_BPS: f64 = 100.0;
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
                    warn!(error = %crate::redact(&e), "HTTP reader unavailable; reorg resync disabled");
                    None
                }
            },
            Err(e) => {
                warn!(error = %crate::redact(&e), "no HTTP RPC configured; reorg resync disabled");
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
            Err(e) => error!(error = %crate::redact(&e), "WS watch connection error"),
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
    // alloy buffers 16 items per subscription by default and silently skips what
    // overflows. A larger buffer makes that rarer; the per-sweep backfill below
    // is what makes it harmless.
    let swap_stream = provider
        .subscribe_logs(&swap_filter)
        .channel_size(SUBSCRIPTION_BUFFER)
        .await?
        .into_stream();
    info!(pool_manager = %cfg.addrs.pool_manager, "subscribed to v4 Swap events");

    let mut stream = match hook {
        Some(h) => {
            let hook_filter = Filter::new().address(h).event_signature(vec![
                PositionOpened::SIGNATURE_HASH,
                PositionClosed::SIGNATURE_HASH,
                Rebalanced::SIGNATURE_HASH,
            ]);
            let hook_stream = provider
                .subscribe_logs(&hook_filter)
                .channel_size(SUBSCRIPTION_BUFFER)
                .await?
                .into_stream();
            info!(hook = %h, "indexing AutopilotHook position events");
            futures_util::stream::select(swap_stream, hook_stream).boxed()
        }
        None => swap_stream.boxed(),
    };

    // Subscriptions only deliver logs from now on. Anything that happened while
    // the daemon was down is replayed here before the live stream is served.
    if let Err(e) = backfill(&provider, cfg, ctx, hook, true).await {
        warn!(error = %crate::redact(&e), "backfill failed; continuing on live stream only");
    }

    let heartbeat = Duration::from_secs(
        std::env::var("LPA_WS_HEARTBEAT_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_HEARTBEAT_SECS),
    );
    // A fixed cadence, unlike the heartbeat: the heartbeat only fires after
    // silence, so on a pool with a swap every few seconds it never fires at all
    // and anything hung off it would never run where it matters most.
    let mut sweep = interval(Duration::from_secs(
        std::env::var("LPA_SWEEP_SECS")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|&s: &u64| s > 0)
            .unwrap_or(DEFAULT_SWEEP_SECS),
    ));
    sweep.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut since_prune = 0u32;
    // The sweep runs beside the log stream, not instead of it: while a sweep
    // awaited its RPCs the stream went unread, its buffer overflowed, and logs
    // were silently lost (re-audit DS-5).
    let mut sweeping: Option<std::pin::Pin<Box<dyn std::future::Future<Output = ()> + '_>>> = None;
    loop {
        tokio::select! {
            _ = sweep.tick(), if sweeping.is_none() => {
                let provider = &provider;
                sweeping = Some(Box::pin(async move {
                    let started = Instant::now();
                    let pass = async {
                        // Catch up from the watermark first. The live stream is
                        // a latency optimisation; this is what guarantees that a
                        // log the stream dropped is still processed, and it is
                        // the only thing that advances the watermark.
                        if let Err(e) = backfill(provider, cfg, ctx, hook, false).await {
                            warn!(error = %crate::redact(&e), "catch-up backfill failed");
                        }
                        sweep_out_of_range(ctx).await;
                        sweep_idle(ctx).await;
                    };
                    match timeout(SWEEP_TIMEOUT, pass).await {
                        Ok(()) => debug!(elapsed_ms = started.elapsed().as_millis() as u64, "sweep pass done"),
                        Err(_) => warn!(timeout_secs = SWEEP_TIMEOUT.as_secs(), "sweep pass timed out; resumes next tick"),
                    }
                }));
            }
            _ = async { sweeping.as_mut().expect("guarded").await }, if sweeping.is_some() => {
                sweeping = None;
            }
            maybe_log = stream.next() => match maybe_log {
                Some(log) => {
                    if let Err(e) = handle(ctx, log).await {
                        error!(error = %crate::redact(&e), "log handling error");
                    }
                    since_prune += 1;
                    if since_prune >= PRUNE_EVERY {
                        since_prune = 0;
                        if let Err(e) = ctx.tracker.prune_all_ticks(TICK_RETENTION) {
                            warn!(error = %crate::redact(&e), "tick prune failed");
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
                        debug!(head, "WS heartbeat ok");
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
    on_connect: bool,
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
    // Every sweep catches up a few blocks; only the catch-up on (re)connect, or a
    // real gap, is worth an info line.
    if on_connect || head - from > 50 {
        info!(
            from,
            to = head,
            pools = pool_topics.len(),
            "backfilling missed logs"
        );
    } else {
        debug!(from, to = head, "catching up from watermark");
    }

    // Ranges still to fetch, last on top. A range the provider refuses (a result
    // cap, a frame-size limit, a range limit) is split in half until it fits, and
    // a single block that still fails is skipped with a loud error. Before, one
    // refused chunk stopped the watermark for good, and every sweep replayed the
    // same chunk (full audit LV-4).
    let mut ranges: Vec<(u64, u64)> = Vec::new();
    let mut s0 = from;
    let mut chunks = Vec::new();
    while s0 <= head {
        let e0 = (s0 + BACKFILL_CHUNK_BLOCKS - 1).min(head);
        chunks.push((s0, e0));
        s0 = e0 + 1;
    }
    ranges.extend(chunks.into_iter().rev());
    let mut replayed = 0usize;
    while let Some((start, end)) = ranges.pop() {
        match fetch_logs(provider, cfg, hook, &pool_topics, start, end).await {
            Ok(logs) => {
                for log in logs {
                    handle(ctx, log).await?;
                    replayed += 1;
                }
            }
            Err(e) if end > start => {
                let mid = start + (end - start) / 2;
                debug!(start, end, error = %crate::redact(&e), "log range refused; splitting");
                ranges.push((mid + 1, end));
                ranges.push((start, mid));
                continue;
            }
            Err(e) => {
                error!(block = start, error = %crate::redact(&e), "logs for this block could not be fetched; skipping it — positions it touched may need a resync");
            }
        }
        ctx.tracker.set_last_indexed_block(&ctx.chain_key(), end)?;
    }
    debug!(replayed, "backfill complete");
    Ok(())
}

/// Hook and Swap logs for `[start, end]`, merged and in chain order. Fetched
/// separately, replaying all hook events before all swaps judged early swaps
/// against later ranges (full audit LV-8).
async fn fetch_logs<P: Provider>(
    provider: &P,
    cfg: &ChainConfig,
    hook: Option<Address>,
    pool_topics: &[B256],
    start: u64,
    end: u64,
) -> Result<Vec<Log>> {
    let mut logs = Vec::new();
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
        logs.extend(provider.get_logs(&f).await?);
    }
    if !pool_topics.is_empty() {
        let f = Filter::new()
            .address(cfg.addrs.pool_manager)
            .event_signature(Swap::SIGNATURE_HASH)
            .topic1(pool_topics.to_vec())
            .from_block(start)
            .to_block(end);
        logs.extend(provider.get_logs(&f).await?);
    }
    logs.sort_by_key(|l| (l.block_number, l.log_index));
    Ok(logs)
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
        Err(e) => warn!(error = %crate::redact(&e), position_id = %id_hex, "resync read failed"),
    }
    Ok(())
}

async fn handle_swap(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match Swap::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %crate::redact(&e), "event decode failed; skipping log");
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
            // In auto-execute mode the sweep proposes it within one pass. Doing it
            // here put up to four RPCs per position on the log path, inside the
            // swap handler (full audit DM-6).
            if ctx.intent_tx.is_none() {
                propose_rebalance(ctx, &pool_hex, tick, &cx.position_id).await;
            }
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
            debug!(error = %crate::redact(&e), "event decode failed; skipping log");
            return Ok(());
        }
    };
    let position_id = format!("{:#x}", ev.positionId);
    let tick_lower = ev.tickLower.as_i32();
    let tick_upper = ev.tickUpper.as_i32();
    // A position is opened once. A replayed `PositionOpened` for a row that
    // exists would reset its range to the opening one, undoing every rebalance
    // since (full audit LV-4).
    if ctx.tracker.get_position(&position_id)?.is_some() {
        debug!(position_id = %position_id, "PositionOpened replayed for a known position; ignored");
        return Ok(());
    }
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
            debug!(error = %crate::redact(&e), "event decode failed; skipping log");
            return Ok(());
        }
    };
    let position_id = format!("{:#x}", ev.positionId);
    ctx.tracker.delete_position(&position_id)?;
    automation().forget(&position_id);
    idle_gate().lock().unwrap().forget(&position_id);
    info!(position_id = %position_id, "indexed PositionClosed");
    Ok(())
}

fn handle_rebalanced(ctx: &Ctx<'_>, log: Log) -> Result<()> {
    let ev = match Rebalanced::decode_log(&log.inner) {
        Ok(e) => e,
        Err(e) => {
            debug!(error = %crate::redact(&e), "event decode failed; skipping log");
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
    // Everything the position owns: deployed liquidity, uncollected fees, and
    // whatever a bounded swap left idle — which can be most of the position
    // after a thin-pool rebalance (re-audit TK-2).
    let (idle0, idle1) = reader.idle_balance(position_id).await.unwrap_or((0, 0));
    let price = 1.0001f64.powi(snap.current_tick);
    let to_f64 = |v: alloy::primitives::U256| -> f64 { format!("{v}").parse().unwrap_or(0.0) };
    let amount0 = to_f64(snap.amount0) + to_f64(snap.fees0) + idle0 as f64;
    let amount1 = to_f64(snap.amount1) + to_f64(snap.fees1) + idle1 as f64;
    let value_token1 = amount0 * price + amount1;
    if !value_token1.is_finite() {
        return 0.0;
    }
    value_token1 * token1_usd
}

/// Re-proposes every position still out of range. Only in auto-execute mode:
/// without an executor the proposal is just a log line, and repeating it every
/// heartbeat would be noise. The strategy still gates each proposal, and the
/// executor throttles sent transactions per position.
async fn sweep_out_of_range(ctx: &Ctx<'_>) {
    if ctx.intent_tx.is_none() {
        return;
    }
    let positions = match ctx.tracker.out_of_range_positions() {
        Ok(p) => p,
        Err(e) => {
            warn!(error = %crate::redact(&e), "out-of-range sweep query failed");
            return;
        }
    };
    // A bounded batch per pass, carried on by a cursor, like the idle sweep: an
    // unbatched pass over a few hundred dust positions, each costing RPCs before
    // the strategy decides, ran past the sweep timeout every time and starved
    // the idle sweep after it (full audit LV-6).
    let n = positions.len();
    let start = if n == 0 {
        0
    } else {
        OOR_CURSOR.fetch_add(SWEEP_BATCH, Ordering::Relaxed) % n
    };
    for p in positions
        .iter()
        .cycle()
        .skip(start)
        .take(n.min(SWEEP_BATCH))
    {
        if ctx.intent_tx.is_some_and(|tx| tx.capacity() == 0) {
            debug!("auto-execute queue full; out-of-range sweep stops for this pass");
            break;
        }
        if let Some(tick) = p.current_tick {
            propose_rebalance(ctx, &p.pool_id, tick, &p.position_id).await;
        }
    }
}

static OOR_CURSOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static IDLE_CURSOR: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Positions examined per idle-sweep pass. Each costs up to two RPCs, so an
/// uncapped pass over a few hundred positions ran into the sweep timeout and the
/// next pass started from the top again: the tail was never examined (re-audit
/// DS-5). The cursor carries on where the last pass stopped.
const IDLE_SWEEP_BATCH: usize = 40;
/// Positions examined per out-of-range sweep pass.
const SWEEP_BATCH: usize = 40;

/// Queues a same-range rebalance for any in-range position holding a material
/// idle balance: what an earlier rebalance's bounded swap could not place. The
/// hook accepts an otherwise no-op range precisely when something is idle.
async fn sweep_idle(ctx: &Ctx<'_>) {
    let (Some(tx), Some(reader)) = (ctx.intent_tx, ctx.reader) else {
        return;
    };
    let threshold_bps = std::env::var("LPA_IDLE_REDEPLOY_BPS")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(DEFAULT_IDLE_REDEPLOY_BPS);
    let positions = match ctx.tracker.in_range_positions() {
        Ok(p) => p,
        Err(e) => {
            warn!(error = %crate::redact(&e), "idle sweep query failed");
            return;
        }
    };
    let n = positions.len();
    let start = if n == 0 {
        0
    } else {
        IDLE_CURSOR.fetch_add(IDLE_SWEEP_BATCH, Ordering::Relaxed) % n
    };
    for p in positions
        .iter()
        .cycle()
        .skip(start)
        .take(n.min(IDLE_SWEEP_BATCH))
    {
        if automation().is_blocked(&p.position_id, Instant::now()) {
            continue;
        }
        let (Ok(pool_id), Ok(position_id)) =
            (p.pool_id.parse::<B256>(), p.position_id.parse::<B256>())
        else {
            continue;
        };
        let (idle0, idle1) = match reader.idle_balance(position_id).await {
            Ok(v) => v,
            Err(e) => {
                debug!(position_id = %p.position_id, error = %crate::redact(&e), "idle balance read failed");
                continue;
            }
        };
        if idle0 == 0 && idle1 == 0 {
            idle_gate().lock().unwrap().forget(&p.position_id);
            continue;
        }
        let Ok(snap) = reader
            .position_snapshot(pool_id, position_id, p.tick_lower, p.tick_upper)
            .await
        else {
            continue;
        };
        let to_f64 = |v: alloy::primitives::U256| -> f64 { format!("{v}").parse().unwrap_or(0.0) };
        let share = idle_share_bps(
            (idle0 as f64, idle1 as f64),
            (to_f64(snap.amount0), to_f64(snap.amount1)),
            snap.current_tick,
        );
        if share < threshold_bps {
            idle_gate().lock().unwrap().forget(&p.position_id);
            continue;
        }
        // Check for room first: an intent dropped on a full queue would still
        // have counted as a no-progress attempt in the gate (re-audit DS-4).
        if tx.capacity() == 0 {
            debug!("auto-execute queue full; idle sweep stops for this pass");
            break;
        }
        let allowed = idle_gate().lock().unwrap().allow(
            &p.position_id,
            share,
            Instant::now(),
            redeploy_wait(),
        );
        if !allowed {
            continue;
        }
        let intent = RebalanceIntent {
            position_id: p.position_id.clone(),
            new_lower: p.tick_lower,
            new_upper: p.tick_upper,
        };
        // Mark first, then send: marking after the send raced a fast executor
        // that had already dequeued the intent, and the leaked marker blocked
        // the position for good (full audit LV-5).
        if !automation().mark_queued(&p.position_id) {
            continue;
        }
        match tx.try_send(intent) {
            Ok(()) => {
                info!(position_id = %p.position_id, idle_bps = share, "idle balance redeploy queued")
            }
            Err(_) => {
                automation().mark_dequeued(&p.position_id);
                warn!(position_id = %p.position_id, "auto-execute queue full; dropped idle redeploy")
            }
        }
    }
}

/// Wait after first seeing an idle balance, and after each redeploy that made
/// progress. It must outlast the hook's cooldown: idle balances appear only as
/// the result of a rebalance, so an immediate attempt would always be refused.
const IDLE_REDEPLOY_BASE: Duration = Duration::from_secs(600);
const IDLE_REDEPLOY_MAX: Duration = Duration::from_secs(86_400);

fn redeploy_wait() -> Duration {
    std::env::var("LPA_IDLE_REDEPLOY_WAIT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .map(Duration::from_secs)
        .unwrap_or(IDLE_REDEPLOY_BASE)
}

fn idle_gate() -> &'static std::sync::Mutex<RedeployGate> {
    static GATE: std::sync::OnceLock<std::sync::Mutex<RedeployGate>> = std::sync::OnceLock::new();
    GATE.get_or_init(Default::default)
}

/// Rate-limits idle redeploys per position. In a pool with no other depth the
/// bounded swap fills nothing, the idle share never falls, and an unconditional
/// retry would pay for a no-progress rebalance on every sweep forever. So each
/// retry that finds the share not at least 10% lower than at the previous
/// attempt doubles the wait. The first sighting only starts the clock.
#[derive(Default)]
pub(crate) struct RedeployGate {
    /// Share at the last attempt (`None` before any), earliest next attempt,
    /// consecutive attempts without progress.
    entries: std::collections::HashMap<String, (Option<f64>, Instant, u32)>,
}

impl RedeployGate {
    pub(crate) fn allow(
        &mut self,
        position_id: &str,
        share_bps: f64,
        now: Instant,
        base: Duration,
    ) -> bool {
        let strikes = match self.entries.get(position_id) {
            None => {
                self.entries
                    .insert(position_id.to_string(), (None, now + base, 0));
                return false;
            }
            Some(&(_, not_before, _)) if now < not_before => return false,
            Some(&(Some(prev), _, strikes)) if share_bps > prev * 0.9 => strikes + 1,
            Some(_) => 0,
        };
        let wait = base
            .saturating_mul(1u32 << strikes.min(16))
            .min(IDLE_REDEPLOY_MAX);
        self.entries.insert(
            position_id.to_string(),
            (Some(share_bps), now + wait, strikes),
        );
        true
    }

    /// Nothing material is idle any more; a later balance starts a fresh clock.
    pub(crate) fn forget(&mut self, position_id: &str) {
        self.entries.remove(position_id);
    }
}

/// Idle value as a share of everything the position owns, in bps, both sides
/// valued in token1 at the current tick.
pub(crate) fn idle_share_bps(idle: (f64, f64), deployed: (f64, f64), tick: i32) -> f64 {
    let price = 1.0001f64.powi(tick);
    let idle_value = idle.0 * price + idle.1;
    let total = idle_value + deployed.0 * price + deployed.1;
    if !(total.is_finite() && total > 0.0) {
        return 0.0;
    }
    idle_value / total * 10_000.0
}

async fn propose_rebalance(ctx: &Ctx<'_>, pool_hex: &str, tick: i32, position_id: &str) {
    // Queued already, or refused recently in a way that will not change by
    // itself: proposing again would only take a queue slot from a position the
    // executor can act on (re-audit DS-4).
    if ctx.intent_tx.is_some() && automation().is_blocked(position_id, Instant::now()) {
        return;
    }
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
            // Mark first (LV-5). A false return means another path already
            // queued this position while we awaited the strategy (LV-10).
            if !automation().mark_queued(&pos.position_id) {
                return;
            }
            match tx.try_send(intent) {
                Ok(()) => {
                    info!(position_id = %pos.position_id, new_lower = d.new_lower, new_upper = d.new_upper, "auto-execute intent queued")
                }
                Err(_) => {
                    automation().mark_dequeued(&pos.position_id);
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
    use super::{idle_share_bps, RedeployGate, IDLE_REDEPLOY_BASE, IDLE_REDEPLOY_MAX};
    use std::time::Instant;

    #[test]
    fn idle_share_values_both_sides_at_the_current_tick() {
        // tick 0: price 1, so the share is a plain ratio of token counts.
        assert!((idle_share_bps((50.0, 50.0), (450.0, 450.0), 0) - 1000.0).abs() < 1e-6);
        assert_eq!(idle_share_bps((0.0, 0.0), (1.0, 1.0), 0), 0.0);
        assert_eq!(idle_share_bps((0.0, 0.0), (0.0, 0.0), 0), 0.0);
        // At a higher price token0 is worth more, so idle token0 weighs more.
        assert!(
            idle_share_bps((10.0, 0.0), (0.0, 100.0), 6932)
                > idle_share_bps((10.0, 0.0), (0.0, 100.0), 0)
        );
    }

    #[test]
    fn redeploy_gate_backs_off_while_no_progress_is_made() {
        let base = IDLE_REDEPLOY_BASE;
        let mut g = RedeployGate::default();
        let t0 = Instant::now();
        assert!(
            !g.allow("p", 5000.0, t0, base),
            "first sighting only starts the clock"
        );
        assert!(
            !g.allow("p", 5000.0, t0 + base / 2, base),
            "still inside the cooldown-covering wait"
        );
        let t1 = t0 + base;
        assert!(
            g.allow("p", 5000.0, t1, base),
            "first attempt once the wait is over"
        );

        // No progress since that attempt: the next wait doubles.
        let t2 = t1 + base;
        assert!(g.allow("p", 5000.0, t2, base));
        assert!(!g.allow(
            "p",
            5000.0,
            t2 + base * 2 - std::time::Duration::from_secs(1),
            base
        ));
        let t3 = t2 + base * 2;
        assert!(g.allow("p", 5000.0, t3, base));

        // Progress resets the wait to the base.
        let t4 = t3 + base * 4;
        assert!(g.allow("p", 1000.0, t4, base));
        assert!(g.allow("p", 100.0, t4 + base, base));

        // Forgetting restarts the clock rather than allowing at once.
        g.forget("p");
        assert!(!g.allow("p", 5000.0, t4 + base * 10, base));

        // The wait is capped.
        let mut g = RedeployGate::default();
        let mut t = Instant::now();
        assert!(!g.allow("q", 5000.0, t, base));
        for _ in 0..40 {
            t += IDLE_REDEPLOY_MAX;
            assert!(g.allow("q", 5000.0, t, base));
        }
    }
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

/// Full-audit liveness PoCs (LV-*). Test-only.
#[cfg(test)]
pub(crate) mod liveness_poc;

/// Audit 2026-10-03 DoS PoCs (audits/tend-2026-10-03/findings-dos.md). Test-only.
#[cfg(test)]
mod dos_poc {
    use super::*;
    use crate::position::tracker::{PositionRow, Tracker};
    use crate::strategy::{default_config, EstimateCostModel, StrategyEngine};
    use std::sync::Mutex;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn row(id: &str, pool: &str, lower: i32, upper: i32, tick: i32) -> PositionRow {
        PositionRow {
            position_id: id.into(),
            owner: "0x1111111111111111111111111111111111111111".into(),
            pool_id: pool.into(),
            chain_id: "8453".into(),
            tick_lower: lower,
            tick_upper: upper,
            current_tick: Some(tick),
            in_range: tick >= lower && tick <= upper,
            entry_tick: Some((lower + upper) / 2),
            fee: Some(3000),
            tick_spacing: Some(60),
        }
    }

    fn feed(t: &Tracker, pool: &str) {
        for block in 1000u64..1200 {
            let tick = ((block as i32 * 7) % 11) - 5;
            t.update_pool_tick(pool, tick).unwrap();
            t.record_tick(pool, tick, block).unwrap();
        }
    }

    fn hex_id(i: usize) -> String {
        format!("{:#066x}", i)
    }

    /// DS-4: dust positions opened by anyone fill the 64-slot intent queue on
    /// every sweep; `try_send` then drops the intents of every position indexed
    /// after them.
    #[tokio::test]
    async fn ds4_attacker_positions_starve_later_honest_positions() {
        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        let attacker_pool = "0xa77ac4e7";
        let honest_pool = "0x40e57";
        for i in 0..crate::exec::AUTO_INTENT_CHANNEL_CAP {
            tracker
                .register(&row(&format!("0xa{i:04}"), attacker_pool, 5000, 6000, 0))
                .unwrap();
        }
        tracker
            .register(&row("0xhonest", honest_pool, 5000, 6000, 0))
            .unwrap();
        feed(&tracker, attacker_pool);
        feed(&tracker, honest_pool);

        let (tx, mut rx) = mpsc::channel(crate::exec::AUTO_INTENT_CHANNEL_CAP);
        let engine = StrategyEngine::default();
        let cfg = default_config();
        let ctx = Ctx {
            tracker: &tracker,
            engine: &engine,
            cost: &EstimateCostModel,
            config: &cfg,
            chain_id: 8453,
            reader: None,
            intent_tx: Some(&tx),
            last_block: DashMap::new(),
        };

        // The executor, as it now behaves: take each intent off the queue, and for
        // the attacker's positions record the hook's terminal refusal (they opted
        // out of automation, so the hook answers AutomationDisabled).
        let mut honest_served_on = None;
        let mut refused = std::collections::HashSet::new();
        for pass in 0..3 {
            sweep_out_of_range(&ctx).await;
            let mut queued = Vec::new();
            while let Ok(i) = rx.try_recv() {
                automation().mark_dequeued(&i.position_id);
                if i.position_id.starts_with("0xa") {
                    automation().on_refusal(
                        &i.position_id,
                        crate::exec::automation::RefusalAction::Terminal,
                        Instant::now(),
                    );
                }
                queued.push(i.position_id);
            }
            let honest = queued.iter().any(|p| p == "0xhonest");
            println!(
                "pass {pass}: executor saw {} intents, honest among them: {honest}",
                queued.len()
            );
            if honest && honest_served_on.is_none() {
                honest_served_on = Some(pass);
            }
            for p in &queued {
                assert!(
                    refused.insert(p.clone()) || !p.starts_with("0xa"),
                    "a terminally refused position was proposed again: {p}"
                );
            }
        }
        assert_eq!(
            honest_served_on,
            Some(1),
            "honest position served on the pass after the spam is refused"
        );
        automation().forget("0xhonest");
    }

    /// Minimal JSON-RPC over HTTP: answers every request with 64 zero bytes
    /// after `delay`, and records each request body.
    async fn mock_rpc(delay: Duration, seen: Arc<Mutex<Vec<String>>>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let seen = seen.clone();
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut tmp = [0u8; 8192];
                    loop {
                        let (head_end, len) = loop {
                            if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                                let head = String::from_utf8_lossy(&buf[..p]).to_lowercase();
                                let len = head
                                    .lines()
                                    .find_map(|l| l.strip_prefix("content-length:"))
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                                    .unwrap_or(0);
                                break (p + 4, len);
                            }
                            match sock.read(&mut tmp).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                            }
                        };
                        while buf.len() < head_end + len {
                            match sock.read(&mut tmp).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                            }
                        }
                        let body =
                            String::from_utf8_lossy(&buf[head_end..head_end + len]).to_string();
                        buf.drain(..head_end + len);
                        let id = body
                            .split("\"id\":")
                            .nth(1)
                            .map(|s| {
                                s.chars()
                                    .take_while(|c| c.is_ascii_digit())
                                    .collect::<String>()
                            })
                            .unwrap_or_else(|| "0".into());
                        seen.lock().unwrap().push(body);
                        tokio::time::sleep(delay).await;
                        let resp = format!(
                            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":\"0x{}\"}}",
                            "0".repeat(128)
                        );
                        let out = format!(
                            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                            resp.len(),
                            resp
                        );
                        if sock.write_all(out.as_bytes()).await.is_err() {
                            return;
                        }
                    }
                });
            }
        });
        format!("http://{addr}")
    }

    /// DS-5: `sweep_idle` makes one-to-two sequential RPCs per in-range
    /// position. With enough (dust) positions ahead of it, every pass hits
    /// SWEEP_TIMEOUT and restarts from the top, so a position later in the
    /// table is never examined — and for those 20 s the watch loop reads no logs.
    #[tokio::test]
    async fn ds5_sweep_timeout_never_reaches_tail_positions() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let url = mock_rpc(Duration::from_millis(20), seen.clone()).await;
        let reader =
            ChainReader::connect(&url, Address::repeat_byte(0x11), Address::repeat_byte(0x22))
                .await
                .unwrap();

        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        let n_attacker = 250;
        for i in 1..=n_attacker {
            tracker
                .register(&row(&hex_id(i), &hex_id(0xa77ac4e7), -600, 600, 0))
                .unwrap();
        }
        let honest = hex_id(0xdead_beef);
        tracker
            .register(&row(&honest, &hex_id(0x40e57), -600, 600, 0))
            .unwrap();

        let (tx, _rx) = mpsc::channel(crate::exec::AUTO_INTENT_CHANNEL_CAP);
        let engine = StrategyEngine::default();
        let cfg = default_config();
        let ctx = Ctx {
            tracker: &tracker,
            engine: &engine,
            cost: &EstimateCostModel,
            config: &cfg,
            chain_id: 8453,
            reader: Some(&reader),
            intent_tx: Some(&tx),
            last_block: DashMap::new(),
        };

        // Each pass examines a bounded batch and the cursor carries on, so every
        // position is reached within ceil(n / batch) passes and no pass needs
        // anywhere near the sweep timeout.
        let needle = honest.trim_start_matches("0x").to_string();
        let passes = (n_attacker + 1).div_ceil(IDLE_SWEEP_BATCH);
        let mut reached = None;
        for pass in 0..passes {
            let before = seen.lock().unwrap().len();
            let r = timeout(SWEEP_TIMEOUT, sweep_idle(&ctx)).await;
            let calls = seen.lock().unwrap().clone();
            assert!(r.is_ok(), "pass {pass} hit the sweep timeout");
            assert!(
                calls.len() - before <= 2 * IDLE_SWEEP_BATCH,
                "a pass is bounded"
            );
            if reached.is_none() && calls[before..].iter().any(|b| b.contains(&needle)) {
                reached = Some(pass);
            }
        }
        println!("honest position examined on pass {reached:?} of {passes}");
        assert!(
            reached.is_some(),
            "the honest position at the tail is examined"
        );
    }

    /// DS-5 (second half), kept as a record of the library behaviour the fix works
    /// around: alloy skips lagged items silently, so the live stream can lose
    /// logs. The daemon no longer relies on it: every sweep backfills from the
    /// watermark, and only the backfill advances it.
    /// alloy-pubsub 1.8.3 delivers subscription items through a tokio broadcast
    /// channel of 16, and `SubAnyStream::poll_next` skips `Lagged` with only a
    /// debug log (sub.rs:348). Modelled here with the same primitives.
    #[tokio::test]
    async fn ds5_logs_arriving_during_a_sweep_beyond_16_are_lost() {
        use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};
        let (txb, rxb) = tokio::sync::broadcast::channel::<u64>(16);
        let mut stream = BroadcastStream::new(rxb);
        for i in 0..40u64 {
            txb.send(i).unwrap();
        }
        drop(txb);
        let mut got = Vec::new();
        while let Some(item) = stream.next().await {
            match item {
                Ok(v) => got.push(v),
                Err(BroadcastStreamRecvError::Lagged(_)) => continue,
            }
        }
        println!(
            "delivered {} of 40; first delivered = {:?}",
            got.len(),
            got.first()
        );
        assert_eq!(got.len(), 16);
        assert_eq!(got[0], 24, "the 24 oldest logs are gone");
    }
}

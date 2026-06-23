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

use crate::chain::config::ChainConfig;
use crate::position::tracker::{PositionRow, Tracker};
use crate::proto::PositionConfig;
use crate::strategy::{default_config, CostModel, DecideInput, StrategyEngine, StubCostModel};

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
        uint128 liquidity
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

const TICK_RETENTION: usize = 2000;
const PRUNE_EVERY: u32 = 500;

enum WatchEnd {
    Shutdown,
    StreamEnded,
}

pub async fn run_watch(cfg: ChainConfig, tracker: Arc<Tracker>, hook: Option<Address>) -> Result<()> {
    let engine = StrategyEngine::default();
    let cost = StubCostModel;
    let config = default_config();
    let mut attempt = 0u32;

    loop {
        let started = Instant::now();
        match watch_once(&cfg, &tracker, &engine, &cost, &config, hook).await {
            Ok(WatchEnd::Shutdown) => {
                info!("shutdown signal received");
                return Ok(());
            }
            Ok(WatchEnd::StreamEnded) => warn!("WS log stream ended"),
            Err(e) => error!(error = %e, "WS watch connection error"),
        }

        if started.elapsed() >= Duration::from_secs(60) {
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
    tracker: &Arc<Tracker>,
    engine: &StrategyEngine,
    cost: &dyn CostModel,
    config: &PositionConfig,
    hook: Option<Address>,
) -> Result<WatchEnd> {
    let ws_url = cfg.ws_url()?;
    let provider = ProviderBuilder::new().connect_ws(WsConnect::new(ws_url)).await?;
    info!(chain = cfg.name, chain_id = cfg.chain_id, "connected to WS RPC");

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

    let heartbeat = Duration::from_secs(
        std::env::var("LPA_WS_HEARTBEAT_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(30),
    );
    let last_block: DashMap<B256, u64> = DashMap::new();
    let mut since_prune = 0u32;
    loop {
        tokio::select! {
            maybe_log = stream.next() => match maybe_log {
                Some(log) => {
                    if let Err(e) = handle(tracker, engine, cost, config, cfg.chain_id, &last_block, log) {
                        error!(error = %e, "log handling error");
                    }
                    since_prune += 1;
                    if since_prune >= PRUNE_EVERY {
                        since_prune = 0;
                        if let Err(e) = tracker.prune_all_ticks(TICK_RETENTION) {
                            warn!(error = %e, "tick prune failed");
                        }
                    }
                }
                None => return Ok(WatchEnd::StreamEnded),
            },
            _ = sleep(heartbeat) => {
                match timeout(Duration::from_secs(5), provider.get_block_number()).await {
                    Ok(Ok(_)) => {}
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

fn next_backoff(attempt: u32) -> Duration {
    let secs = (1u64 << attempt.min(5)).min(30);
    Duration::from_secs(secs)
}

fn handle(
    tracker: &Arc<Tracker>,
    engine: &StrategyEngine,
    cost: &dyn CostModel,
    config: &PositionConfig,
    chain_id: u64,
    last_block: &DashMap<B256, u64>,
    log: Log,
) -> Result<()> {
    if log.removed {
        warn!(block = ?log.block_number, "reorg: removed log skipped");
        return Ok(());
    }
    match log.topic0().copied() {
        Some(t) if t == Swap::SIGNATURE_HASH => handle_swap(tracker, engine, cost, config, last_block, log),
        Some(t) if t == PositionOpened::SIGNATURE_HASH => handle_opened(tracker, chain_id, log),
        Some(t) if t == PositionClosed::SIGNATURE_HASH => handle_closed(tracker, log),
        Some(t) if t == Rebalanced::SIGNATURE_HASH => handle_rebalanced(tracker, log),
        _ => Ok(()),
    }
}

fn handle_swap(
    tracker: &Arc<Tracker>,
    engine: &StrategyEngine,
    cost: &dyn CostModel,
    config: &PositionConfig,
    last_block: &DashMap<B256, u64>,
    log: Log,
) -> Result<()> {
    let ev = match Swap::decode_log(&log.inner) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let pool_id = ev.id;
    let pool_hex = format!("{:#x}", pool_id);
    let tick = ev.tick.as_i32();
    let block = log.block_number.unwrap_or(0);

    let crosses = tracker.update_pool_tick(&pool_hex, tick)?;
    for cx in &crosses {
        if cx.was_in_range && !cx.now_in_range {
            warn!(position_id = %cx.position_id, tick, "position EXITED range");
            propose_rebalance(tracker, engine, cost, config, &pool_hex, tick, &cx.position_id);
        } else if !cx.was_in_range && cx.now_in_range {
            info!(position_id = %cx.position_id, tick, "position re-entered range");
        }
    }

    if !crosses.is_empty() {
        let new_block = last_block.get(&pool_id).map(|v| *v != block).unwrap_or(true);
        if new_block {
            last_block.insert(pool_id, block);
            tracker.record_tick(&pool_hex, tick, block)?;
        }
    }

    debug!(pool = %pool_hex, tick, block, "swap");
    Ok(())
}

fn handle_opened(tracker: &Arc<Tracker>, chain_id: u64, log: Log) -> Result<()> {
    let ev = match PositionOpened::decode_log(&log.inner) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let position_id = format!("{:#x}", ev.positionId);
    let tick_lower = ev.tickLower.as_i32();
    let tick_upper = ev.tickUpper.as_i32();
    tracker.register(&PositionRow {
        position_id: position_id.clone(),
        owner: format!("{:#x}", ev.owner),
        pool_id: format!("{:#x}", ev.poolId),
        chain_id: chain_id.to_string(),
        tick_lower,
        tick_upper,
        current_tick: None,
        in_range: false,
        entry_tick: Some((tick_lower + tick_upper) / 2),
    })?;
    info!(position_id = %position_id, tick_lower, tick_upper, "indexed PositionOpened");
    Ok(())
}

fn handle_closed(tracker: &Arc<Tracker>, log: Log) -> Result<()> {
    let ev = match PositionClosed::decode_log(&log.inner) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let position_id = format!("{:#x}", ev.positionId);
    tracker.delete_position(&position_id)?;
    info!(position_id = %position_id, "indexed PositionClosed");
    Ok(())
}

fn handle_rebalanced(tracker: &Arc<Tracker>, log: Log) -> Result<()> {
    let ev = match Rebalanced::decode_log(&log.inner) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let position_id = format!("{:#x}", ev.positionId);
    let lower = ev.newTickLower.as_i32();
    let upper = ev.newTickUpper.as_i32();
    tracker.update_range(&position_id, lower, upper)?;
    info!(position_id = %position_id, new_lower = lower, new_upper = upper, "indexed Rebalanced");
    Ok(())
}

fn propose_rebalance(
    tracker: &Arc<Tracker>,
    engine: &StrategyEngine,
    cost: &dyn CostModel,
    config: &PositionConfig,
    pool_hex: &str,
    tick: i32,
    position_id: &str,
) {
    let Ok(Some(pos)) = tracker.get_position(position_id) else { return };
    let ticks = tracker.recent_ticks(pool_hex, 200).unwrap_or_default();
    let entry_tick = pos.entry_tick.unwrap_or((pos.tick_lower + pos.tick_upper) / 2);
    let input = DecideInput {
        pool_id: pool_hex,
        chain_id: &pos.chain_id,
        current_tick: tick,
        entry_tick,
        cur_lower: pos.tick_lower,
        cur_upper: pos.tick_upper,
        tick_spacing: 60,
        fee_pips: 3000,
        ticks: &ticks,
        config,
    };
    if let Some(d) = engine.decide(&input, cost) {
        warn!(
            position_id = %pos.position_id,
            new_lower = d.new_lower,
            new_upper = d.new_upper,
            est_cost_usd = d.est_cost_usd,
            reason = %d.reason,
            "rebalance proposed (run `lpa rebalance` with this position id)"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{handle, next_backoff, PositionClosed, PositionOpened, Rebalanced, Swap};
    use crate::position::tracker::{PositionRow, Tracker};
    use crate::strategy::{default_config, StrategyEngine, StubCostModel};
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
            b256!("0x4b1141c4873ddadcb77b54d629ba596ebd2e41d649b97e3e5a66e87d6e6b8469")
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

    fn engine_set() -> (StrategyEngine, StubCostModel, crate::proto::PositionConfig) {
        (StrategyEngine::default(), StubCostModel, default_config())
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
        RpcLog { inner, block_number: Some(1), removed, ..Default::default() }
    }

    #[test]
    fn removed_log_skipped_but_valid_recorded() {
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
            })
            .unwrap();
        let (engine, cost, config) = engine_set();
        let last_block: DashMap<B256, u64> = DashMap::new();

        handle(&tracker, &engine, &cost, &config, 8453, &last_block, swap_log(pool, 150, false)).unwrap();
        assert_eq!(tracker.recent_ticks(&pool_hex, 10).unwrap(), vec![150]);

        handle(&tracker, &engine, &cost, &config, 8453, &last_block, swap_log(pool, 160, true)).unwrap();
        assert_eq!(tracker.recent_ticks(&pool_hex, 10).unwrap(), vec![150], "removed log must not record");
    }

    #[test]
    fn indexes_position_opened_and_closed() {
        let tracker = Arc::new(Tracker::open_in_memory().unwrap());
        let (engine, cost, config) = engine_set();
        let last_block: DashMap<B256, u64> = DashMap::new();
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
        };
        let log = RpcLog {
            inner: PrimLog { address: hook, data: opened.encode_log_data() },
            block_number: Some(2),
            removed: false,
            ..Default::default()
        };
        handle(&tracker, &engine, &cost, &config, 8453, &last_block, log).unwrap();
        let id_hex = format!("{:#x}", pos_id);
        let p = tracker.get_position(&id_hex).unwrap().expect("indexed");
        assert_eq!((p.tick_lower, p.tick_upper), (-600, 600));
        assert_eq!(p.pool_id, format!("{:#x}", pool));

        let closed = PositionClosed {
            positionId: pos_id,
            owner: address!("0x1111111111111111111111111111111111111111"),
            liquidity: 1_000_000u128,
        };
        let clog = RpcLog {
            inner: PrimLog { address: hook, data: closed.encode_log_data() },
            block_number: Some(3),
            removed: false,
            ..Default::default()
        };
        handle(&tracker, &engine, &cost, &config, 8453, &last_block, clog).unwrap();
        assert!(tracker.get_position(&id_hex).unwrap().is_none(), "closed position removed");
    }
}

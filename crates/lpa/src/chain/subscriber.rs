use std::sync::Arc;

use alloy::primitives::B256;
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::rpc::types::{Filter, Log};
use alloy::sol;
use alloy::sol_types::SolEvent;
use anyhow::Result;
use dashmap::DashMap;
use futures_util::StreamExt;
use tracing::{debug, error, info, warn};

use crate::chain::config::ChainConfig;
use crate::position::tracker::Tracker;
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
}

pub async fn run_watch(cfg: ChainConfig, tracker: Arc<Tracker>) -> Result<()> {
    let ws_url = cfg.ws_url()?;
    let provider = ProviderBuilder::new().connect_ws(WsConnect::new(ws_url)).await?;
    info!(chain = cfg.name, chain_id = cfg.chain_id, "connected to WS RPC");

    let filter = Filter::new()
        .address(cfg.addrs.pool_manager)
        .event_signature(Swap::SIGNATURE_HASH);
    let sub = provider.subscribe_logs(&filter).await?;
    let mut stream = sub.into_stream();
    info!(pool_manager = %cfg.addrs.pool_manager, "subscribed to v4 Swap events");

    let engine = StrategyEngine::default();
    let cost = StubCostModel;
    let config = default_config();
    let last_block: DashMap<B256, u64> = DashMap::new();
    loop {
        tokio::select! {
            maybe_log = stream.next() => {
                match maybe_log {
                    Some(log) => {
                        if let Err(e) = handle(&tracker, &engine, &cost, &config, &last_block, log) {
                            error!(error = %e, "swap handling error");
                        }
                    }
                    None => {
                        warn!("log stream ended");
                        break;
                    }
                }
            }
            _ = tokio::signal::ctrl_c() => {
                info!("shutdown signal received");
                break;
            }
        }
    }
    Ok(())
}

fn handle(
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
            "rebalance proposed (execution lands P5)"
        );
    }
}

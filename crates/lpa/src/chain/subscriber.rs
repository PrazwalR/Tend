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

    let last_block: DashMap<B256, u64> = DashMap::new();
    loop {
        tokio::select! {
            maybe_log = stream.next() => {
                match maybe_log {
                    Some(log) => {
                        if let Err(e) = handle(&tracker, &last_block, log) {
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

fn handle(tracker: &Arc<Tracker>, last_block: &DashMap<B256, u64>, log: Log) -> Result<()> {
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

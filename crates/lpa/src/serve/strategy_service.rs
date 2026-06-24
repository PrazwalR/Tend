use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use alloy::primitives::aliases::{I24, U24};
use alloy::primitives::{keccak256, Address};
use alloy::sol;
use alloy::sol_types::SolValue;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use crate::position::tracker::{ConfigRow, PositionRow, Tracker};
use crate::position::tracker::compute_position_id;
use crate::proto::autopilot_strategy_server::AutopilotStrategy;
use crate::proto::{
    DeregisterPositionRequest, DeregisterPositionResponse, GetPositionConfigRequest, PingRequest,
    PingResponse, PoolKey, PositionConfig, PositionState, RegisterPositionRequest,
    RegisterPositionResponse, StreamPositionsRequest, TickRange, UpdateConfigRequest,
    UpdateConfigResponse,
};
use crate::strategy::concentrated_il;

sol! {
    struct PoolKeyAbi {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
}

pub struct StrategyService {
    tracker: Arc<Tracker>,
}

impl StrategyService {
    pub fn new(tracker: Arc<Tracker>) -> Self {
        Self { tracker }
    }
}

#[tonic::async_trait]
impl AutopilotStrategy for StrategyService {
    async fn ping(&self, _req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        Ok(Response::new(PingResponse { timestamp: now_secs() }))
    }

    async fn register_position(
        &self,
        req: Request<RegisterPositionRequest>,
    ) -> Result<Response<RegisterPositionResponse>, Status> {
        let req = req.into_inner();
        let pool_key = req.pool_key.ok_or_else(|| Status::invalid_argument("pool_key required"))?;
        let range = req.tick_range.ok_or_else(|| Status::invalid_argument("tick_range required"))?;
        if range.tick_lower >= range.tick_upper {
            return Err(Status::invalid_argument("tick_lower must be < tick_upper"));
        }
        let pool_id = pool_id_from_key(&pool_key)?;
        let position_id = compute_position_id(&req.owner, &pool_id, range.tick_lower, range.tick_upper)
            .map_err(|e| Status::invalid_argument(e.to_string()))?;
        let chain_id = if req.chain_id.is_empty() { "8453".to_string() } else { req.chain_id };

        self.tracker
            .register(&PositionRow {
                position_id: position_id.clone(),
                owner: req.owner,
                pool_id,
                chain_id,
                tick_lower: range.tick_lower,
                tick_upper: range.tick_upper,
                current_tick: None,
                in_range: false,
                entry_tick: Some((range.tick_lower + range.tick_upper) / 2),
                fee: Some(pool_key.fee),
                tick_spacing: Some(pool_key.tick_spacing),
            })
            .map_err(|e| Status::internal(e.to_string()))?;

        if let Some(cfg) = req.config {
            self.tracker
                .set_config(&position_id, &config_to_row(&cfg))
                .map_err(|e| Status::internal(e.to_string()))?;
        }

        Ok(Response::new(RegisterPositionResponse { position_id, success: true }))
    }

    async fn deregister_position(
        &self,
        req: Request<DeregisterPositionRequest>,
    ) -> Result<Response<DeregisterPositionResponse>, Status> {
        let id = req.into_inner().position_id;
        let success = self
            .tracker
            .delete_position(&id)
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(DeregisterPositionResponse { success }))
    }

    async fn get_position_config(
        &self,
        req: Request<GetPositionConfigRequest>,
    ) -> Result<Response<PositionConfig>, Status> {
        let id = req.into_inner().position_id;
        match self.tracker.get_config(&id).map_err(|e| Status::internal(e.to_string()))? {
            Some(row) => Ok(Response::new(row_to_config(&id, &row))),
            None => Err(Status::not_found("config not found")),
        }
    }

    async fn update_config(
        &self,
        req: Request<UpdateConfigRequest>,
    ) -> Result<Response<UpdateConfigResponse>, Status> {
        let req = req.into_inner();
        let cfg = req.config.ok_or_else(|| Status::invalid_argument("config required"))?;
        if self
            .tracker
            .get_position(&req.position_id)
            .map_err(|e| Status::internal(e.to_string()))?
            .is_none()
        {
            return Err(Status::not_found("position not registered"));
        }
        self.tracker
            .set_config(&req.position_id, &config_to_row(&cfg))
            .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(UpdateConfigResponse { success: true }))
    }

    type StreamPositionsStream = ReceiverStream<Result<PositionState, Status>>;

    async fn stream_positions(
        &self,
        req: Request<StreamPositionsRequest>,
    ) -> Result<Response<Self::StreamPositionsStream>, Status> {
        let ids = req.into_inner().position_ids;
        let tracker = Arc::clone(&self.tracker);
        let (tx, rx) = mpsc::channel(16);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(2));
            loop {
                ticker.tick().await;
                let targets = if ids.is_empty() {
                    tracker.all_position_ids().unwrap_or_default()
                } else {
                    ids.clone()
                };
                for id in &targets {
                    if let Ok(Some(p)) = tracker.get_position(id) {
                        if tx.send(Ok(position_state(&p))).await.is_err() {
                            return;
                        }
                    }
                }
            }
        });
        Ok(Response::new(ReceiverStream::new(rx)))
    }
}

fn pool_id_from_key(k: &PoolKey) -> Result<String, Status> {
    let currency0: Address = k.currency0.parse().map_err(|_| Status::invalid_argument("bad currency0"))?;
    let currency1: Address = k.currency1.parse().map_err(|_| Status::invalid_argument("bad currency1"))?;
    let hooks: Address = k.hooks.parse().map_err(|_| Status::invalid_argument("bad hooks"))?;
    let tick_spacing = I24::try_from(k.tick_spacing).map_err(|_| Status::invalid_argument("bad tick_spacing"))?;
    let abi = PoolKeyAbi {
        currency0,
        currency1,
        fee: U24::from(k.fee),
        tickSpacing: tick_spacing,
        hooks,
    };
    Ok(format!("{:#x}", keccak256(abi.abi_encode())))
}

fn position_state(p: &PositionRow) -> PositionState {
    let il_percent = match p.current_tick {
        Some(t) => concentrated_il(
            p.entry_tick.unwrap_or((p.tick_lower + p.tick_upper) / 2),
            t,
            p.tick_lower,
            p.tick_upper,
        ),
        None => 0.0,
    };
    PositionState {
        position_id: p.position_id.clone(),
        owner: p.owner.clone(),
        pool_key: None,
        current_range: Some(TickRange { tick_lower: p.tick_lower, tick_upper: p.tick_upper }),
        current_tick: p.current_tick.unwrap_or(0),
        liquidity: String::new(),
        token0_amount: String::new(),
        token1_amount: String::new(),
        fees_earned_0: String::new(),
        fees_earned_1: String::new(),
        il_percent,
        fee_apr: 0.0,
        in_range: p.in_range,
        last_updated_at: now_secs(),
        chain_id: p.chain_id.clone(),
    }
}

fn config_to_row(c: &PositionConfig) -> ConfigRow {
    ConfigRow {
        strategy: c.strategy,
        il_threshold_pct: c.il_threshold_pct,
        fee_capture_ratio: c.fee_capture_ratio,
        bollinger_period: c.bollinger_period,
        bollinger_stddev: c.bollinger_stddev,
        max_gas_usd: c.max_gas_usd,
        auto_compound_fees: c.auto_compound_fees,
        use_flashbots: c.use_flashbots,
    }
}

fn row_to_config(position_id: &str, c: &ConfigRow) -> PositionConfig {
    PositionConfig {
        position_id: position_id.to_string(),
        strategy: c.strategy,
        il_threshold_pct: c.il_threshold_pct,
        fee_capture_ratio: c.fee_capture_ratio,
        bollinger_period: c.bollinger_period,
        bollinger_stddev: c.bollinger_stddev,
        max_gas_usd: c.max_gas_usd,
        auto_compound_fees: c.auto_compound_fees,
        use_flashbots: c.use_flashbots,
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_id_matches_v4_abi_encoding() {
        let k = PoolKey {
            currency0: "0x0000000000000000000000000000000000000001".to_string(),
            currency1: "0x0000000000000000000000000000000000000002".to_string(),
            fee: 3000,
            tick_spacing: 60,
            hooks: "0x0000000000000000000000000000000000000000".to_string(),
        };
        assert_eq!(
            pool_id_from_key(&k).unwrap(),
            "0xf6a117501d7c06f988e5cb96441dff2b3bc20bc7c52bc943e66da6e63b93c97c"
        );
    }
}

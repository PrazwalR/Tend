use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use alloy::primitives::aliases::{I24, U24};
use alloy::primitives::{Address, B256};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use crate::chain::reader::{pool_id_of, ChainReader, PoolKeyAbi};
use crate::position::tracker::compute_position_id;
use crate::position::tracker::{ConfigRow, PositionRow, Tracker};
use crate::proto::autopilot_strategy_server::AutopilotStrategy;
use crate::proto::{
    DeregisterPositionRequest, DeregisterPositionResponse, GetPositionConfigRequest, PingRequest,
    PingResponse, PoolKey, PositionConfig, PositionState, RegisterPositionRequest,
    RegisterPositionResponse, StreamPositionsRequest, TickRange, UpdateConfigRequest,
    UpdateConfigResponse,
};
use crate::strategy::concentrated_il;

/// Buffered position-state updates per streaming client.
const STREAM_CHANNEL_CAP: usize = 16;
/// How often the position stream re-reads the tracker and pushes an update.
const STREAM_POLL_SECS: u64 = 2;

pub struct StrategyService {
    tracker: Arc<Tracker>,
    reader: Option<Arc<ChainReader>>,
}

impl StrategyService {
    pub fn new(tracker: Arc<Tracker>, reader: Option<Arc<ChainReader>>) -> Self {
        Self { tracker, reader }
    }
}

#[tonic::async_trait]
impl AutopilotStrategy for StrategyService {
    async fn ping(&self, _req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        Ok(Response::new(PingResponse {
            timestamp: now_secs(),
        }))
    }

    async fn register_position(
        &self,
        req: Request<RegisterPositionRequest>,
    ) -> Result<Response<RegisterPositionResponse>, Status> {
        let req = req.into_inner();
        let pool_key = req
            .pool_key
            .ok_or_else(|| Status::invalid_argument("pool_key required"))?;
        let range = req
            .tick_range
            .ok_or_else(|| Status::invalid_argument("tick_range required"))?;
        if range.tick_lower >= range.tick_upper {
            return Err(Status::invalid_argument("tick_lower must be < tick_upper"));
        }
        if !crate::strategy::ticks_in_domain(&[range.tick_lower, range.tick_upper]) {
            return Err(Status::invalid_argument(
                "ticks outside the int24 tick domain",
            ));
        }
        let pool_id = pool_id_from_key(&pool_key)?;
        let position_id =
            compute_position_id(&req.owner, &pool_id, range.tick_lower, range.tick_upper)
                .map_err(|e| Status::invalid_argument(e.to_string()))?;
        let chain_id = if req.chain_id.is_empty() {
            "8453".to_string()
        } else {
            req.chain_id
        };

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

        Ok(Response::new(RegisterPositionResponse {
            position_id,
            success: true,
        }))
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
        match self
            .tracker
            .get_config(&id)
            .map_err(|e| Status::internal(e.to_string()))?
        {
            Some(row) => Ok(Response::new(row_to_config(&id, &row))),
            None => Err(Status::not_found("config not found")),
        }
    }

    async fn update_config(
        &self,
        req: Request<UpdateConfigRequest>,
    ) -> Result<Response<UpdateConfigResponse>, Status> {
        let req = req.into_inner();
        let cfg = req
            .config
            .ok_or_else(|| Status::invalid_argument("config required"))?;
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
        let reader = self.reader.clone();
        let (tx, rx) = mpsc::channel(STREAM_CHANNEL_CAP);
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(STREAM_POLL_SECS));
            loop {
                // Exit as soon as the client goes away. Waiting for a failed send
                // never ended a stream whose ids matched nothing (full audit DM-5).
                tokio::select! {
                    _ = ticker.tick() => {}
                    _ = tx.closed() => return,
                }
                let targets = if ids.is_empty() {
                    tracker.all_position_ids().unwrap_or_default()
                } else {
                    ids.clone()
                };
                for id in &targets {
                    if let Ok(Some(p)) = tracker.get_position(id) {
                        let mut state = position_state(&p);
                        let opened_at = tracker.opened_at(id).unwrap_or(None);
                        enrich(&mut state, &p, opened_at, reader.as_deref()).await;
                        if tx.send(Ok(state)).await.is_err() {
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
    let currency0: Address = k
        .currency0
        .parse()
        .map_err(|_| Status::invalid_argument("bad currency0"))?;
    let currency1: Address = k
        .currency1
        .parse()
        .map_err(|_| Status::invalid_argument("bad currency1"))?;
    let hooks: Address = k
        .hooks
        .parse()
        .map_err(|_| Status::invalid_argument("bad hooks"))?;
    let tick_spacing =
        I24::try_from(k.tick_spacing).map_err(|_| Status::invalid_argument("bad tick_spacing"))?;
    let abi = PoolKeyAbi {
        currency0,
        currency1,
        fee: U24::from(k.fee),
        tickSpacing: tick_spacing,
        hooks,
    };
    Ok(format!("{:#x}", pool_id_of(&abi)))
}

/// Fills the on-chain half of a position view: liquidity, the token amounts
/// backing it, and uncollected fees, plus a fee APR annualised from fees
/// accrued against position value. Without a reader these stay empty rather
/// than guessed, and a failed read degrades to the same empty view.
async fn enrich(
    state: &mut PositionState,
    p: &PositionRow,
    opened_at: Option<i64>,
    reader: Option<&ChainReader>,
) {
    let Some(reader) = reader else { return };
    let (Ok(pool_id), Ok(position_id)) = (p.pool_id.parse::<B256>(), p.position_id.parse::<B256>())
    else {
        return;
    };
    let snap = match reader
        .position_snapshot(pool_id, position_id, p.tick_lower, p.tick_upper)
        .await
    {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!(error = %crate::redact(&e), position_id = %p.position_id, "position enrichment read failed");
            return;
        }
    };
    state.liquidity = snap.liquidity.to_string();
    state.token0_amount = snap.amount0.to_string();
    state.token1_amount = snap.amount1.to_string();
    state.fees_earned_0 = snap.fees0.to_string();
    state.fees_earned_1 = snap.fees1.to_string();
    state.current_tick = snap.current_tick;
    state.in_range = snap.current_tick >= p.tick_lower && snap.current_tick <= p.tick_upper;
    state.fee_apr = fee_apr(&snap, opened_at);
}

/// Annualised fee yield: fees accrued over the position's life, as a fraction
/// of the value backing it, scaled to a year. Both sides are summed in token1
/// terms via the current tick, so the ratio is unit-consistent. Returns 0 when
/// the position is too young to annualise without wild extrapolation.
fn fee_apr(snap: &crate::chain::reader::PositionSnapshot, opened_at: Option<i64>) -> f64 {
    const MIN_AGE_SECS: f64 = 3600.0;
    const YEAR_SECS: f64 = 365.0 * 24.0 * 3600.0;
    let Some(opened) = opened_at else { return 0.0 };
    let age = now_secs() as f64 - opened as f64;
    if age < MIN_AGE_SECS {
        return 0.0;
    }
    let price = 1.0001f64.powi(snap.current_tick);
    let u256_f = |v: alloy::primitives::U256| -> f64 { format!("{v}").parse().unwrap_or(0.0) };
    let value = u256_f(snap.amount0) * price + u256_f(snap.amount1);
    let fees = u256_f(snap.fees0) * price + u256_f(snap.fees1);
    if value <= 0.0 || !fees.is_finite() || !value.is_finite() {
        return 0.0;
    }
    (fees / value) * (YEAR_SECS / age) * 100.0
}

/// Builds the health view the stream serves. Populated from indexed state:
/// range, current tick, in-range flag, and concentrated-LP IL. Token balances,
/// uncollected fees, and fee APR are left empty/zero because they require
/// per-position on-chain (StateView) reads the daemon does not yet perform;
/// they are `unknown`, not fabricated. See README.
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
        current_range: Some(TickRange {
            tick_lower: p.tick_lower,
            tick_upper: p.tick_upper,
        }),
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
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::chain::reader::PositionSnapshot;
    use alloy::primitives::U256;

    fn snap(amount1: u128, fees1: u128) -> PositionSnapshot {
        PositionSnapshot {
            liquidity: 1_000_000,
            amount0: U256::ZERO,
            amount1: U256::from(amount1),
            fees0: U256::ZERO,
            fees1: U256::from(fees1),
            current_tick: 0,
        }
    }

    #[test]
    fn fee_apr_needs_an_open_timestamp() {
        assert_eq!(fee_apr(&snap(1_000, 10), None), 0.0);
    }

    #[test]
    fn fee_apr_suppressed_for_young_positions() {
        let recent = now_secs() as i64 - 60;
        assert_eq!(
            fee_apr(&snap(1_000, 10), Some(recent)),
            0.0,
            "a minute-old position must not be annualised"
        );
    }

    #[test]
    fn fee_apr_annualises_from_position_age() {
        // 1% of value earned in 1/4 of a year annualises to ~4%.
        let quarter = (365.0 * 24.0 * 3600.0 / 4.0) as i64;
        let opened = now_secs() as i64 - quarter;
        let apr = fee_apr(&snap(100_000, 1_000), Some(opened));
        assert!((apr - 4.0).abs() < 0.1, "apr {apr}");
    }

    #[test]
    fn fee_apr_zero_when_position_has_no_value() {
        let old = now_secs() as i64 - 86_400 * 30;
        assert_eq!(fee_apr(&snap(0, 0), Some(old)), 0.0);
    }

    #[tokio::test]
    async fn enrich_without_reader_leaves_state_untouched() {
        let p = PositionRow {
            position_id: "0x00000000000000000000000000000000000000000000000000000000000000aa"
                .into(),
            owner: "0x1111111111111111111111111111111111111111".into(),
            pool_id: "0x00000000000000000000000000000000000000000000000000000000000000bb".into(),
            chain_id: "8453".into(),
            tick_lower: -600,
            tick_upper: 600,
            current_tick: Some(0),
            in_range: true,
            entry_tick: Some(0),
            fee: Some(3000),
            tick_spacing: Some(60),
        };
        let mut state = position_state(&p);
        enrich(&mut state, &p, Some(0), None).await;
        assert!(
            state.liquidity.is_empty(),
            "must stay unknown, not fabricated"
        );
        assert_eq!(state.fee_apr, 0.0);
    }

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

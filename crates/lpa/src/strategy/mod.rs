mod ev;
mod il;
mod math;

use crate::proto::{PositionConfig, Strategy};

pub use il::concentrated_il;

pub struct DecideInput<'a> {
    pub pool_id: &'a str,
    pub chain_id: &'a str,
    pub current_tick: i32,
    pub entry_tick: i32,
    pub cur_lower: i32,
    pub cur_upper: i32,
    pub tick_spacing: i32,
    pub fee_pips: u32,
    pub ticks: &'a [i32],
    pub config: &'a PositionConfig,
}

pub struct Decision {
    pub new_lower: i32,
    pub new_upper: i32,
    pub reason: String,
    pub strategy: Strategy,
    pub est_cost_usd: f64,
}

pub trait CostModel {
    fn rebalance_cost_usd(&self, chain_id: &str) -> f64;
    fn volume_usd_per_block(&self, pool_id: &str) -> f64;
}

pub struct StubCostModel;

impl StubCostModel {
    fn env_f64(key: &str, default: f64) -> f64 {
        std::env::var(key)
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(default)
    }
}

impl CostModel for StubCostModel {
    fn rebalance_cost_usd(&self, _chain_id: &str) -> f64 {
        Self::env_f64("LPA_DEMO_GAS_USD", 5.0)
    }
    fn volume_usd_per_block(&self, _pool_id: &str) -> f64 {
        Self::env_f64("LPA_DEMO_VOLUME_USD_PER_BLOCK", 50_000.0)
    }
}

pub fn config_from(
    il_threshold_pct: Option<f64>,
    bollinger_period: Option<u32>,
    bollinger_stddev: Option<f64>,
) -> PositionConfig {
    let mut c = default_config();
    if let Some(v) = il_threshold_pct {
        c.il_threshold_pct = v;
    }
    if let Some(v) = bollinger_period {
        c.bollinger_period = v;
    }
    if let Some(v) = bollinger_stddev {
        c.bollinger_stddev = v;
    }
    c
}

pub fn default_config() -> PositionConfig {
    PositionConfig {
        position_id: String::new(),
        strategy: Strategy::Bollinger as i32,
        il_threshold_pct: 5.0,
        fee_capture_ratio: 0.5,
        bollinger_period: 200,
        bollinger_stddev: 2.0,
        max_gas_usd: 50.0,
        auto_compound_fees: true,
        use_flashbots: true,
    }
}

pub struct StrategyEngine {
    pub horizon_blocks: f64,
    pub min_ticks: usize,
}

impl Default for StrategyEngine {
    fn default() -> Self {
        Self {
            horizon_blocks: 300.0,
            min_ticks: 8,
        }
    }
}

impl StrategyEngine {
    pub fn decide(&self, input: &DecideInput, cost: &dyn CostModel) -> Option<Decision> {
        if input.ticks.len() < self.min_ticks {
            return None;
        }
        let strategy = Strategy::try_from(input.config.strategy).unwrap_or(Strategy::Bollinger);
        if matches!(strategy, Strategy::Manual | Strategy::Unspecified) {
            return None;
        }

        let k = if input.config.bollinger_stddev > 0.0 {
            input.config.bollinger_stddev
        } else {
            2.0
        };
        let bands = math::bollinger(input.ticks, k);
        let spacing = input.tick_spacing.max(1);
        let half = self.half_width(strategy, &bands, input);
        let new_lower =
            math::clamp_tick(math::round_down_to_spacing(input.current_tick - half, spacing), spacing);
        let new_upper =
            math::clamp_tick(math::round_up_to_spacing(input.current_tick + half, spacing), spacing);
        if new_upper <= new_lower {
            return None;
        }

        let tick = input.current_tick;
        let in_range = tick >= input.cur_lower && tick <= input.cur_upper;
        let range_width = (input.cur_upper - input.cur_lower).max(1);
        let buffer = range_width / 10;
        let near_boundary = tick <= input.cur_lower + buffer || tick >= input.cur_upper - buffer;
        let out_of_bb = (tick as f64) < bands.lower || (tick as f64) > bands.upper;
        let target_width = new_upper - new_lower;
        let over_ranged = range_width > target_width * 3 / 2;
        let il = concentrated_il(input.entry_tick, tick, input.cur_lower, input.cur_upper);
        let il_breach = il.abs() > input.config.il_threshold_pct;

        if in_range && !near_boundary && !over_ranged && !il_breach && !out_of_bb {
            return None;
        }

        let est_cost = cost.rebalance_cost_usd(input.chain_id);
        if est_cost > input.config.max_gas_usd {
            return None;
        }

        let ev = ev::EvInputs {
            current_tick: tick,
            step_sigma: math::step_sigma(input.ticks),
            horizon_blocks: self.horizon_blocks,
            cur_lower: input.cur_lower,
            cur_upper: input.cur_upper,
            new_lower,
            new_upper,
            volume_usd_per_block: cost.volume_usd_per_block(input.pool_id),
            fee_tier_pips: input.fee_pips as f64,
            cost_usd: est_cost,
        };
        if !ev::should_rebalance(&ev) {
            return None;
        }

        let reason = if !in_range {
            format!("out of range: tick {tick} not in [{},{}]", input.cur_lower, input.cur_upper)
        } else if il_breach {
            format!("IL {il:.2}% exceeds {:.2}% limit", input.config.il_threshold_pct)
        } else if over_ranged {
            format!("over-ranged: width {range_width} vs target {target_width}")
        } else if out_of_bb {
            format!("tick {tick} outside Bollinger [{:.0},{:.0}]", bands.lower, bands.upper)
        } else {
            format!("near boundary of [{},{}]", input.cur_lower, input.cur_upper)
        };

        Some(Decision {
            new_lower,
            new_upper,
            reason,
            strategy,
            est_cost_usd: est_cost,
        })
    }

    fn half_width(&self, strategy: Strategy, bands: &math::Bands, input: &DecideInput) -> i32 {
        let sigma = bands.sigma.max(1.0);
        let raw = match strategy {
            Strategy::FeeCapture => {
                let r = if input.config.fee_capture_ratio > 0.0 {
                    input.config.fee_capture_ratio
                } else {
                    0.5
                };
                r * sigma * self.horizon_blocks.sqrt()
            }
            Strategy::IlThreshold => (sigma * 2.0).max(input.tick_spacing as f64 * 10.0),
            _ => {
                let k = if input.config.bollinger_stddev > 0.0 {
                    input.config.bollinger_stddev
                } else {
                    2.0
                };
                k * sigma
            }
        };
        (raw.round() as i32).max(input.tick_spacing.max(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FixedCost;
    impl CostModel for FixedCost {
        fn rebalance_cost_usd(&self, _c: &str) -> f64 {
            5.0
        }
        fn volume_usd_per_block(&self, _p: &str) -> f64 {
            50_000.0
        }
    }

    fn noisy_ticks(center: i32, n: usize) -> Vec<i32> {
        (0..n)
            .map(|i| center + ((i as i32 * 7) % 11) - 5)
            .collect()
    }

    fn input<'a>(ticks: &'a [i32], cur: i32, lo: i32, hi: i32, cfg: &'a PositionConfig) -> DecideInput<'a> {
        DecideInput {
            pool_id: "0xpool",
            chain_id: "8453",
            current_tick: cur,
            entry_tick: (lo + hi) / 2,
            cur_lower: lo,
            cur_upper: hi,
            tick_spacing: 60,
            fee_pips: 3000,
            ticks,
            config: cfg,
        }
    }

    #[test]
    fn out_of_range_triggers_rebalance() {
        let cfg = default_config();
        let ticks = noisy_ticks(0, 200);
        let d = StrategyEngine::default()
            .decide(&input(&ticks, 0, 5000, 6000, &cfg), &FixedCost)
            .expect("should rebalance");
        assert!(d.new_lower < 0 && d.new_upper > 0);
        assert_eq!(d.new_lower % 60, 0);
        assert_eq!(d.new_upper % 60, 0);
        assert!(d.reason.contains("out of range"));
    }

    #[test]
    fn comfortably_in_range_no_rebalance() {
        let cfg = default_config();
        let ticks = noisy_ticks(0, 200);
        let d = StrategyEngine::default().decide(&input(&ticks, 0, -90, 90, &cfg), &FixedCost);
        assert!(d.is_none());
    }

    #[test]
    fn insufficient_history_no_rebalance() {
        let cfg = default_config();
        let ticks = noisy_ticks(0, 4);
        let d = StrategyEngine::default().decide(&input(&ticks, 0, 5000, 6000, &cfg), &FixedCost);
        assert!(d.is_none());
    }

    #[test]
    fn manual_strategy_never_acts() {
        let mut cfg = default_config();
        cfg.strategy = Strategy::Manual as i32;
        let ticks = noisy_ticks(0, 200);
        let d = StrategyEngine::default().decide(&input(&ticks, 0, 5000, 6000, &cfg), &FixedCost);
        assert!(d.is_none());
    }

    #[test]
    fn gas_over_cap_blocks_rebalance() {
        let mut cfg = default_config();
        cfg.max_gas_usd = 1.0;
        let ticks = noisy_ticks(0, 200);
        let d = StrategyEngine::default().decide(&input(&ticks, 0, 5000, 6000, &cfg), &FixedCost);
        assert!(d.is_none());
    }
}

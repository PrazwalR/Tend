use super::il::concentrated_il;
use super::math::normal_cdf;

pub struct EvInputs {
    pub current_tick: i32,
    pub entry_tick: i32,
    pub step_sigma: f64,
    pub horizon_blocks: f64,
    pub cur_lower: i32,
    pub cur_upper: i32,
    pub new_lower: i32,
    pub new_upper: i32,
    pub volume_usd_per_block: f64,
    pub fee_tier_pips: f64,
    pub cost_usd: f64,
    /// Value backing the position. Zero means unknown, which collapses the
    /// IL, slippage and MEV terms to nothing rather than inventing them.
    pub position_value_usd: f64,
    pub slippage_bps: f64,
    pub mev_bps: f64,
}

pub fn in_range_prob(center: i32, lower: i32, upper: i32, step_sigma: f64, horizon: f64) -> f64 {
    if upper <= lower {
        return 0.0;
    }
    let s = step_sigma * horizon.max(0.0).sqrt();
    let c = center as f64;
    (normal_cdf(upper as f64, c, s) - normal_cdf(lower as f64, c, s)).clamp(0.0, 1.0)
}

fn fee_value(inp: &EvInputs, lower: i32, upper: i32) -> f64 {
    let width = (upper - lower).max(1) as f64;
    let p_in = in_range_prob(
        inp.current_tick,
        lower,
        upper,
        inp.step_sigma,
        inp.horizon_blocks,
    );
    let fee_frac = inp.fee_tier_pips / 1_000_000.0;
    inp.volume_usd_per_block * inp.horizon_blocks * fee_frac * p_in / width
}

/// Quadrature nodes for the expected-IL integral over the horizon's terminal
/// tick distribution. Odd so the centre point is sampled exactly.
const IL_NODES: usize = 21;
/// Standard deviations spanned each way by the quadrature.
const IL_SPAN_SIGMA: f64 = 3.0;

/// Expected impermanent loss (percent, non-positive) at the horizon, averaging
/// concentrated-LP IL over a normal distribution of terminal ticks. A point
/// estimate at the current tick would understate IL badly for a narrow range,
/// because IL is convex in price.
pub fn expected_il(entry_tick: i32, center: i32, sigma_h: f64, lower: i32, upper: i32) -> f64 {
    if sigma_h <= 0.0 {
        return concentrated_il(entry_tick, center, lower, upper);
    }
    let mut acc = 0.0;
    let mut weight_sum = 0.0;
    for i in 0..IL_NODES {
        let z = -IL_SPAN_SIGMA + 2.0 * IL_SPAN_SIGMA * (i as f64) / ((IL_NODES - 1) as f64);
        let w = (-0.5 * z * z).exp();
        let tick = (center as f64 + z * sigma_h).round();
        let tick = tick.clamp(i32::MIN as f64, i32::MAX as f64) as i32;
        acc += w * concentrated_il(entry_tick, tick, lower, upper);
        weight_sum += w;
    }
    acc / weight_sum
}

/// Expected IL the move avoids, in USD. The rebalanced range is re-entered at
/// the current tick, so its IL clock restarts; the held range keeps accruing
/// from its original entry. Positive when moving loses less than staying.
fn il_avoided_usd(inp: &EvInputs) -> f64 {
    if inp.position_value_usd <= 0.0 {
        return 0.0;
    }
    let sigma_h = inp.step_sigma * inp.horizon_blocks.max(0.0).sqrt();
    let stay = expected_il(
        inp.entry_tick,
        inp.current_tick,
        sigma_h,
        inp.cur_lower,
        inp.cur_upper,
    );
    let moved = expected_il(
        inp.current_tick,
        inp.current_tick,
        sigma_h,
        inp.new_lower,
        inp.new_upper,
    );
    (moved - stay) / 100.0 * inp.position_value_usd
}

/// Cost of crossing the spread to re-ratio the position, plus an allowance for
/// value lost to searchers on a public rebalance.
fn friction_usd(inp: &EvInputs) -> f64 {
    if inp.position_value_usd <= 0.0 {
        return 0.0;
    }
    inp.position_value_usd * (inp.slippage_bps + inp.mev_bps) / 10_000.0
}

/// `E[fee gain] + E[IL avoided] − gas − slippage − MEV`.
pub fn ev_delta(inp: &EvInputs) -> f64 {
    let new = fee_value(inp, inp.new_lower, inp.new_upper);
    let cur = fee_value(inp, inp.cur_lower, inp.cur_upper);
    new - cur + il_avoided_usd(inp) - inp.cost_usd - friction_usd(inp)
}

#[cfg(test)]
impl EvInputs {
    fn clone_for_test(&self) -> EvInputs {
        EvInputs {
            current_tick: self.current_tick,
            entry_tick: self.entry_tick,
            step_sigma: self.step_sigma,
            horizon_blocks: self.horizon_blocks,
            cur_lower: self.cur_lower,
            cur_upper: self.cur_upper,
            new_lower: self.new_lower,
            new_upper: self.new_upper,
            volume_usd_per_block: self.volume_usd_per_block,
            fee_tier_pips: self.fee_tier_pips,
            cost_usd: self.cost_usd,
            position_value_usd: self.position_value_usd,
            slippage_bps: self.slippage_bps,
            mev_bps: self.mev_bps,
        }
    }
}

pub fn should_rebalance(inp: &EvInputs) -> bool {
    inp.new_upper > inp.new_lower && ev_delta(inp) > 0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn base() -> EvInputs {
        EvInputs {
            current_tick: 0,
            entry_tick: 2500,
            step_sigma: 5.0,
            horizon_blocks: 300.0,
            cur_lower: 2000,
            cur_upper: 3000,
            new_lower: -500,
            new_upper: 500,
            volume_usd_per_block: 50_000.0,
            fee_tier_pips: 3000.0,
            cost_usd: 5.0,
            position_value_usd: 0.0,
            slippage_bps: 0.0,
            mev_bps: 0.0,
        }
    }

    #[test]
    fn recenter_onto_price_is_positive() {
        assert!(should_rebalance(&base()));
    }

    #[test]
    fn same_range_loses_cost() {
        let mut inp = base();
        inp.new_lower = inp.cur_lower;
        inp.new_upper = inp.cur_upper;
        assert!((ev_delta(&inp) + inp.cost_usd).abs() < 1e-6);
        assert!(!should_rebalance(&inp));
    }

    #[test]
    fn unknown_position_value_disables_il_and_friction() {
        let mut inp = base();
        inp.slippage_bps = 100.0;
        inp.mev_bps = 50.0;
        inp.position_value_usd = 0.0;
        let fee_only = fee_value(&inp, inp.new_lower, inp.new_upper)
            - fee_value(&inp, inp.cur_lower, inp.cur_upper)
            - inp.cost_usd;
        assert!(
            (ev_delta(&inp) - fee_only).abs() < 1e-9,
            "without a position value the gate must not invent IL or friction"
        );
    }

    #[test]
    fn friction_grows_with_slippage_at_fixed_value() {
        let mut cheap = base();
        cheap.position_value_usd = 100_000.0;
        cheap.slippage_bps = 10.0;
        let mut dear = cheap.clone_for_test();
        dear.slippage_bps = 200.0;
        assert!(
            ev_delta(&dear) < ev_delta(&cheap),
            "a wider spread must make the same move less attractive"
        );
    }

    #[test]
    fn friction_scales_with_position_value() {
        let mut small = base();
        small.position_value_usd = 1_000.0;
        small.slippage_bps = 100.0;
        let mut large = small.clone_for_test();
        large.position_value_usd = 1_000_000.0;
        assert!(
            friction_usd(&large) > friction_usd(&small),
            "a larger position pays more slippage for the same move"
        );
        assert!((friction_usd(&large) / friction_usd(&small) - 1000.0).abs() < 1e-6);
    }

    #[test]
    fn mev_allowance_only_subtracts() {
        let mut without = base();
        without.position_value_usd = 100_000.0;
        let mut with = without.clone_for_test();
        with.mev_bps = 25.0;
        assert!(ev_delta(&with) < ev_delta(&without));
    }

    #[test]
    fn expected_il_is_non_positive_and_convex_aware() {
        // Averaging over the terminal distribution must be at least as bad as
        // the point estimate at the centre, because IL is convex in price.
        let point = expected_il(0, 0, 0.0, -600, 600);
        let averaged = expected_il(0, 0, 200.0, -600, 600);
        assert!(point <= 1e-9);
        assert!(averaged <= 1e-9);
        assert!(
            averaged <= point + 1e-9,
            "point {point} averaged {averaged}"
        );
    }

    #[test]
    fn expected_il_degenerates_to_point_estimate_without_volatility() {
        let a = expected_il(0, 300, 0.0, -600, 600);
        let b = concentrated_il(0, 300, -600, 600);
        assert!((a - b).abs() < 1e-9);
    }

    #[test]
    fn recentering_a_drifted_position_avoids_il() {
        // Held range is far from price and deep in loss; recentring on price
        // restarts the IL clock, so the avoided-IL term must be positive.
        let mut inp = base();
        inp.position_value_usd = 100_000.0;
        inp.entry_tick = 2500;
        inp.current_tick = 0;
        assert!(il_avoided_usd(&inp) > 0.0);
    }

    #[test]
    fn in_range_prob_monotonic_in_width() {
        let narrow = in_range_prob(0, -100, 100, 5.0, 300.0);
        let wide = in_range_prob(0, -1000, 1000, 5.0, 300.0);
        assert!(wide >= narrow);
    }
}

#[cfg(test)]
mod props {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn ev_strictly_decreasing_in_cost(extra in 1.0f64..1000.0) {
            let mut a = super::tests::base();
            let lo = ev_delta(&a);
            a.cost_usd += extra;
            let hi = ev_delta(&a);
            prop_assert!(hi < lo);
        }

        #[test]
        fn centered_beats_offset(offset in 600i32..5000) {
            let mut centered = super::tests::base();
            centered.cur_lower = -50_000;
            centered.cur_upper = -49_000;
            let mut offcenter = EvInputs { ..super::tests::base() };
            offcenter.cur_lower = -50_000;
            offcenter.cur_upper = -49_000;
            offcenter.new_lower = centered.new_lower + offset;
            offcenter.new_upper = centered.new_upper + offset;
            prop_assert!(ev_delta(&centered) >= ev_delta(&offcenter));
        }
    }
}

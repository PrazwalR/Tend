use super::math::normal_cdf;

pub struct EvInputs {
    pub current_tick: i32,
    pub step_sigma: f64,
    pub horizon_blocks: f64,
    pub cur_lower: i32,
    pub cur_upper: i32,
    pub new_lower: i32,
    pub new_upper: i32,
    pub volume_usd_per_block: f64,
    pub fee_tier_pips: f64,
    pub cost_usd: f64,
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
    let p_in = in_range_prob(inp.current_tick, lower, upper, inp.step_sigma, inp.horizon_blocks);
    let fee_frac = inp.fee_tier_pips / 1_000_000.0;
    inp.volume_usd_per_block * inp.horizon_blocks * fee_frac * p_in / width
}

pub fn ev_delta(inp: &EvInputs) -> f64 {
    let new = fee_value(inp, inp.new_lower, inp.new_upper);
    let cur = fee_value(inp, inp.cur_lower, inp.cur_upper);
    new - cur - inp.cost_usd
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
            step_sigma: 5.0,
            horizon_blocks: 300.0,
            cur_lower: 2000,
            cur_upper: 3000,
            new_lower: -500,
            new_upper: 500,
            volume_usd_per_block: 50_000.0,
            fee_tier_pips: 3000.0,
            cost_usd: 5.0,
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

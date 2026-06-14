pub const MIN_TICK: i32 = -887272;
pub const MAX_TICK: i32 = 887272;

pub fn tick_to_price(tick: i32) -> f64 {
    1.0001f64.powi(tick)
}

pub fn round_down_to_spacing(tick: i32, spacing: i32) -> i32 {
    tick.div_euclid(spacing) * spacing
}

pub fn round_up_to_spacing(tick: i32, spacing: i32) -> i32 {
    -((-tick).div_euclid(spacing)) * spacing
}

pub fn clamp_tick(tick: i32, spacing: i32) -> i32 {
    let lo = round_up_to_spacing(MIN_TICK, spacing);
    let hi = round_down_to_spacing(MAX_TICK, spacing);
    tick.clamp(lo, hi)
}

pub fn mean(xs: &[f64]) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    xs.iter().sum::<f64>() / xs.len() as f64
}

pub fn stddev(xs: &[f64]) -> f64 {
    if xs.len() < 2 {
        return 0.0;
    }
    let m = mean(xs);
    let var = xs.iter().map(|x| (x - m).powi(2)).sum::<f64>() / xs.len() as f64;
    var.sqrt()
}

pub fn step_sigma(ticks: &[i32]) -> f64 {
    if ticks.len() < 2 {
        return 0.0;
    }
    let diffs: Vec<f64> = ticks.windows(2).map(|w| (w[1] - w[0]) as f64).collect();
    stddev(&diffs)
}

pub struct Bands {
    pub sigma: f64,
    pub lower: f64,
    pub upper: f64,
}

pub fn bollinger(ticks: &[i32], k: f64) -> Bands {
    let xs: Vec<f64> = ticks.iter().map(|&t| t as f64).collect();
    let sma = mean(&xs);
    let sigma = stddev(&xs);
    Bands {
        sigma,
        lower: sma - k * sigma,
        upper: sma + k * sigma,
    }
}

pub fn erf(x: f64) -> f64 {
    let t = 1.0 / (1.0 + 0.3275911 * x.abs());
    let y = 1.0
        - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
            + 0.254829592)
            * t
            * (-x * x).exp();
    if x < 0.0 {
        -y
    } else {
        y
    }
}

pub fn normal_cdf(x: f64, mean: f64, sigma: f64) -> f64 {
    if sigma <= 0.0 {
        return if x >= mean { 1.0 } else { 0.0 };
    }
    0.5 * (1.0 + erf((x - mean) / (sigma * std::f64::consts::SQRT_2)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounding_handles_negatives() {
        assert_eq!(round_down_to_spacing(-5, 10), -10);
        assert_eq!(round_up_to_spacing(-5, 10), 0);
        assert_eq!(round_down_to_spacing(5, 10), 0);
        assert_eq!(round_up_to_spacing(5, 10), 10);
        assert_eq!(round_down_to_spacing(-10, 10), -10);
        assert_eq!(round_up_to_spacing(-10, 10), -10);
    }

    #[test]
    fn stddev_known() {
        let v = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
        assert!((stddev(&v) - 2.0).abs() < 1e-9);
    }

    #[test]
    fn step_sigma_constant_walk_is_zero() {
        assert!(step_sigma(&[10, 20, 30, 40]) < 1e-9);
    }

    #[test]
    fn normal_cdf_symmetry() {
        assert!((normal_cdf(0.0, 0.0, 1.0) - 0.5).abs() < 1e-6);
        let p = normal_cdf(1.0, 0.0, 1.0);
        assert!((p - 0.8413).abs() < 1e-3);
    }
}

#[cfg(test)]
mod props {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn round_brackets_tick(tick in MIN_TICK..=MAX_TICK, spacing in 1i32..1000) {
            let down = round_down_to_spacing(tick, spacing);
            let up = round_up_to_spacing(tick, spacing);
            prop_assert!(down <= tick);
            prop_assert!(up >= tick);
            prop_assert_eq!(down % spacing, 0);
            prop_assert_eq!(up % spacing, 0);
            prop_assert!(up - down <= spacing);
        }
    }
}

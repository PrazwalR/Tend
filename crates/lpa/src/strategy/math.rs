pub use crate::chain::tickmath::{MAX_TICK, MIN_TICK};

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

/// Fraction trimmed from each tail before averaging. A handful of extreme
/// samples — the shape a partial poisoning attempt leaves — should not drag the
/// centre of the band.
const TRIM_FRACTION: f64 = 0.1;

/// Mean of the middle of the distribution, discarding `TRIM_FRACTION` from each
/// tail. Falls back to the plain mean when the window is too short to trim.
pub fn trimmed_mean(xs: &[f64]) -> f64 {
    let n = xs.len();
    if n < 5 {
        return mean(xs);
    }
    let mut sorted = xs.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let cut = ((n as f64) * TRIM_FRACTION).floor() as usize;
    let slice = &sorted[cut..n - cut];
    mean(slice)
}

pub fn bollinger(ticks: &[i32], k: f64) -> Bands {
    let xs: Vec<f64> = ticks.iter().map(|&t| t as f64).collect();
    // Trimmed rather than arithmetic: the arithmetic mean is exactly what a few
    // extreme samples move, and moving it is how an attacker steers both the
    // rebalance trigger and the width of the range it targets.
    let sma = trimmed_mean(&xs);
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
    fn trimmed_mean_ignores_tail_outliers() {
        let mut xs: Vec<f64> = (0..20).map(|i| 100.0 + i as f64).collect();
        let clean = trimmed_mean(&xs);
        // Replace both tails with absurd values, as a poisoning attempt would.
        xs[0] = -900_000.0;
        xs[1] = -900_000.0;
        xs[18] = 900_000.0;
        xs[19] = 900_000.0;
        let poisoned = trimmed_mean(&xs);
        assert!(
            (clean - poisoned).abs() < 5.0,
            "clean {clean} poisoned {poisoned}"
        );
    }

    #[test]
    fn trimmed_mean_falls_back_on_short_windows() {
        let xs = [1.0, 2.0, 3.0];
        assert!((trimmed_mean(&xs) - mean(&xs)).abs() < 1e-12);
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

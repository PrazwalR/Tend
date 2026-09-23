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

/// Weighted trimmed mean: samples are sorted by value, then the lightest 10% of
/// total weight is discarded from each tail before averaging what remains. This
/// is the time-weighted counterpart of `trimmed_mean` — a tick that stood for one
/// block carries a tenth the influence of one that stood for ten.
pub fn weighted_trimmed_mean(samples: &[(i32, u64)]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sorted: Vec<(i32, u64)> = samples.to_vec();
    sorted.sort_by_key(|&(tick, _)| tick);

    let total: u64 = sorted.iter().map(|&(_, w)| w).sum();
    if total == 0 {
        return mean(&sorted.iter().map(|&(t, _)| t as f64).collect::<Vec<_>>());
    }
    let cut = (total as f64 * TRIM_FRACTION) as u64;
    let keep_from = cut;
    let keep_to = total.saturating_sub(cut);

    let mut seen = 0u64;
    let mut acc = 0.0;
    let mut kept = 0u64;
    for &(tick, w) in &sorted {
        let start = seen;
        let end = seen + w;
        seen = end;
        // Overlap of this sample's weight span with the retained middle.
        let lo = start.max(keep_from);
        let hi = end.min(keep_to);
        if hi > lo {
            let used = hi - lo;
            acc += tick as f64 * used as f64;
            kept += used;
        }
    }
    if kept == 0 {
        // Trimming removed everything (one dominant sample); fall back to it.
        return weighted_mean(&sorted);
    }
    acc / kept as f64
}

pub fn weighted_mean(samples: &[(i32, u64)]) -> f64 {
    let total: u64 = samples.iter().map(|&(_, w)| w).sum();
    if total == 0 {
        return 0.0;
    }
    samples
        .iter()
        .map(|&(t, w)| t as f64 * w as f64)
        .sum::<f64>()
        / total as f64
}

pub fn weighted_stddev(samples: &[(i32, u64)], m: f64) -> f64 {
    let total: u64 = samples.iter().map(|&(_, w)| w).sum();
    if total < 2 {
        return 0.0;
    }
    let var = samples
        .iter()
        .map(|&(t, w)| (t as f64 - m).powi(2) * w as f64)
        .sum::<f64>()
        / total as f64;
    var.sqrt()
}

/// Time-weighted bands. Prefer this over [`bollinger`] wherever block spans are
/// available; the unweighted form remains for synthetic series in tests.
pub fn bollinger_weighted(samples: &[(i32, u64)], k: f64) -> Bands {
    let sma = weighted_trimmed_mean(samples);
    let sigma = weighted_stddev(samples, weighted_mean(samples));
    Bands {
        sigma,
        lower: sma - k * sigma,
        upper: sma + k * sigma,
    }
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
    fn weighting_favours_the_tick_that_stood_longest() {
        // 100 stood for 90 blocks; 200 was flickered through in 10 single blocks.
        let mut samples = vec![(100i32, 90u64)];
        samples.extend((0..10).map(|_| (200i32, 1u64)));
        let w = weighted_mean(&samples);
        let unweighted = mean(&samples.iter().map(|&(t, _)| t as f64).collect::<Vec<_>>());
        assert!(
            w < 120.0,
            "weighted mean {w} should sit near the durable tick"
        );
        assert!(
            unweighted > w,
            "counting samples equally over-weights the flickered tick"
        );
    }

    #[test]
    fn weighted_trimmed_mean_discards_light_tails() {
        let mut samples = vec![(100i32, 100u64)];
        samples.push((-50_000, 1));
        samples.push((50_000, 1));
        let trimmed = weighted_trimmed_mean(&samples);
        assert!(
            (trimmed - 100.0).abs() < 1.0,
            "light extremes should not move the centre: {trimmed}"
        );
    }

    #[test]
    fn weighted_stddev_zero_for_a_constant_series() {
        let samples = [(42i32, 5u64), (42, 9)];
        assert!(weighted_stddev(&samples, weighted_mean(&samples)) < 1e-12);
    }

    #[test]
    fn weighted_helpers_tolerate_empty_input() {
        assert_eq!(weighted_mean(&[]), 0.0);
        assert_eq!(weighted_trimmed_mean(&[]), 0.0);
        assert_eq!(weighted_stddev(&[], 0.0), 0.0);
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

use super::math::tick_to_price;

fn amounts(sp: f64, spa: f64, spb: f64) -> (f64, f64) {
    if sp <= spa {
        (1.0 / spa - 1.0 / spb, 0.0)
    } else if sp >= spb {
        (0.0, spb - spa)
    } else {
        (1.0 / sp - 1.0 / spb, sp - spa)
    }
}

pub fn concentrated_il(entry_tick: i32, current_tick: i32, tick_lower: i32, tick_upper: i32) -> f64 {
    if tick_lower >= tick_upper {
        return 0.0;
    }
    let p0 = tick_to_price(entry_tick);
    let p = tick_to_price(current_tick);
    let spa = tick_to_price(tick_lower).sqrt();
    let spb = tick_to_price(tick_upper).sqrt();
    let (x0, y0) = amounts(p0.sqrt(), spa, spb);
    let (x, y) = amounts(p.sqrt(), spa, spb);
    let hodl = x0 * p + y0;
    if hodl <= 0.0 {
        return 0.0;
    }
    let pos = x * p + y;
    (pos / hodl - 1.0) * 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_at_entry() {
        assert!(concentrated_il(0, 0, -1000, 1000).abs() < 1e-9);
    }

    #[test]
    fn always_non_positive() {
        for cur in (-2000..=2000).step_by(50) {
            let il = concentrated_il(0, cur, -1000, 1000);
            assert!(il <= 1e-6, "il {il} at tick {cur}");
        }
    }

    #[test]
    fn reduces_to_v2_at_full_range() {
        let two_x = (2.0f64.ln() / 1.0001f64.ln()).round() as i32;
        let il = concentrated_il(0, two_x, MIN_TICK_TEST, MAX_TICK_TEST) / 100.0;
        let r = 2.0f64;
        let v2 = 2.0 * r.sqrt() / (1.0 + r) - 1.0;
        assert!((il - v2).abs() < 1e-3, "il {il} v2 {v2}");
    }

    #[test]
    fn tighter_range_amplifies_il() {
        let cur = (1.2f64.ln() / 1.0001f64.ln()).round() as i32;
        let wide = concentrated_il(0, cur, -5000, 5000).abs();
        let tight = concentrated_il(0, cur, -500, 500).abs();
        assert!(tight > wide, "tight {tight} wide {wide}");
    }

    const MIN_TICK_TEST: i32 = -887000;
    const MAX_TICK_TEST: i32 = 887000;
}

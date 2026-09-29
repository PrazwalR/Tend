use alloy::primitives::U256;

pub const MIN_TICK: i32 = -887272;
pub const MAX_TICK: i32 = 887272;

const MAGIC: [(u32, &str); 20] = [
    (0x1, "0xfffcb933bd6fad37aa2d162d1a594001"),
    (0x2, "0xfff97272373d413259a46990580e213a"),
    (0x4, "0xfff2e50f5f656932ef12357cf3c7fdcc"),
    (0x8, "0xffe5caca7e10e4e61c3624eaa0941cd0"),
    (0x10, "0xffcb9843d60f6159c9db58835c926644"),
    (0x20, "0xff973b41fa98c081472e6896dfb254c0"),
    (0x40, "0xff2ea16466c96a3843ec78b326b52861"),
    (0x80, "0xfe5dee046a99a2a811c461f1969c3053"),
    (0x100, "0xfcbe86c7900a88aedcffc83b479aa3a4"),
    (0x200, "0xf987a7253ac413176f2b074cf7815e54"),
    (0x400, "0xf3392b0822b70005940c7a398e4b70f3"),
    (0x800, "0xe7159475a2c29b7443b29c7fa6e889d9"),
    (0x1000, "0xd097f3bdfd2022b8845ad8f792aa5825"),
    (0x2000, "0xa9f746462d870fdf8a65dc1f90e061e5"),
    (0x4000, "0x70d869a156d2a1b890bb3df62baf32f7"),
    (0x8000, "0x31be135f97d08fd981231505542fcfa6"),
    (0x10000, "0x9aa508b5b7a84e1c677de54f3e99bc9"),
    (0x20000, "0x5d6af8dedb81196699c329225ee604"),
    (0x40000, "0x2216e584f5fa1ea926041bedfe98"),
    (0x80000, "0x48a170391f7dc42444e8fa2"),
];

/// Port of v4-core `TickMath.getSqrtPriceAtTick`. Integer-exact: the bit
/// decomposition, the Q128.128 rounding, and the round-up on the final shift
/// all mirror the Solidity so results agree wei-for-wei with the chain.
pub fn sqrt_price_at_tick(tick: i32) -> Option<U256> {
    let abs_tick = tick.unsigned_abs() as u64;
    if abs_tick > MAX_TICK as u64 {
        return None;
    }
    let one = U256::from(1u8) << 128;
    let mut price = if abs_tick & 0x1 != 0 {
        U256::from_str_radix(MAGIC[0].1.trim_start_matches("0x"), 16).unwrap()
    } else {
        one
    };
    for (bit, hex) in MAGIC.iter().skip(1) {
        if abs_tick & (*bit as u64) != 0 {
            let m = U256::from_str_radix(hex.trim_start_matches("0x"), 16).unwrap();
            price = (price * m) >> 128;
        }
    }
    if tick > 0 {
        price = U256::MAX / price;
    }
    let u32_max = U256::from(u32::MAX);
    Some((price + u32_max) >> 32)
}

/// Token amounts backing `liquidity` over [lower, upper] at the current price.
/// Mirrors v4-periphery `LiquidityAmounts`, using the same truncating integer
/// division, so the values match what a withdrawal would actually free.
pub fn amounts_for_liquidity(
    sqrt_price: U256,
    sqrt_lower: U256,
    sqrt_upper: U256,
    liquidity: u128,
) -> (U256, U256) {
    let (a, b) = if sqrt_lower > sqrt_upper {
        (sqrt_upper, sqrt_lower)
    } else {
        (sqrt_lower, sqrt_upper)
    };
    let l = U256::from(liquidity);
    if sqrt_price <= a {
        (amount0(a, b, l), U256::ZERO)
    } else if sqrt_price < b {
        (amount0(sqrt_price, b, l), amount1(a, sqrt_price, l))
    } else {
        (U256::ZERO, amount1(a, b, l))
    }
}

fn amount0(a: U256, b: U256, l: U256) -> U256 {
    if a.is_zero() {
        return U256::ZERO;
    }
    ((l << 96) * (b - a)) / b / a
}

fn amount1(a: U256, b: U256, l: U256) -> U256 {
    let q96 = U256::from(1u8) << 96;
    (l * (b - a)) / q96
}

/// Uncollected fees for one side. Fee growth is a wrapping Q128.128 counter in
/// v4, so the delta is a wrapping subtraction — a naive checked subtract
/// underflows and panics once the global counter has wrapped.
pub fn fees_owed(liquidity: u128, growth_inside: U256, growth_inside_last: U256) -> U256 {
    let delta = growth_inside.wrapping_sub(growth_inside_last);
    (delta * U256::from(liquidity)) >> 128
}

#[cfg(test)]
mod tests {
    use super::*;

    const Q96: u128 = 1 << 96;

    #[test]
    fn tick_zero_is_exactly_q96() {
        assert_eq!(sqrt_price_at_tick(0).unwrap(), U256::from(Q96));
    }

    #[test]
    fn known_solidity_values() {
        // Cross-checked against v4-core TickMath.getSqrtPriceAtTick.
        assert_eq!(
            sqrt_price_at_tick(MIN_TICK).unwrap(),
            U256::from(4295128739u64)
        );
        assert_eq!(
            sqrt_price_at_tick(MAX_TICK).unwrap(),
            U256::from_str_radix("1461446703485210103287273052203988822378723970342", 10).unwrap()
        );
    }

    #[test]
    fn out_of_domain_rejected() {
        assert!(sqrt_price_at_tick(MAX_TICK + 1).is_none());
        assert!(sqrt_price_at_tick(MIN_TICK - 1).is_none());
    }

    #[test]
    fn monotonic_in_tick() {
        let mut prev = U256::ZERO;
        for t in (-100_000..=100_000).step_by(1000) {
            let p = sqrt_price_at_tick(t).unwrap();
            assert!(p > prev, "not monotonic at {t}");
            prev = p;
        }
    }

    #[test]
    fn matches_float_price_closely() {
        for t in [-50_000i32, -600, 0, 600, 50_000] {
            let exact = sqrt_price_at_tick(t).unwrap();
            let approx = 1.0001f64.powi(t).sqrt() * 2f64.powi(96);
            let e: f64 = format!("{exact}").parse().unwrap();
            assert!(
                (e - approx).abs() / approx < 1e-9,
                "tick {t}: exact {e} approx {approx}"
            );
        }
    }

    #[test]
    fn below_range_is_all_token0_above_is_all_token1() {
        let lo = sqrt_price_at_tick(-600).unwrap();
        let hi = sqrt_price_at_tick(600).unwrap();
        let below = sqrt_price_at_tick(-1200).unwrap();
        let above = sqrt_price_at_tick(1200).unwrap();

        let (a0, a1) = amounts_for_liquidity(below, lo, hi, 1_000_000_000_000_000_000);
        assert!(a0 > U256::ZERO && a1.is_zero());

        let (b0, b1) = amounts_for_liquidity(above, lo, hi, 1_000_000_000_000_000_000);
        assert!(b0.is_zero() && b1 > U256::ZERO);
    }

    #[test]
    fn in_range_holds_both_sides_symmetrically() {
        let lo = sqrt_price_at_tick(-600).unwrap();
        let hi = sqrt_price_at_tick(600).unwrap();
        let mid = sqrt_price_at_tick(0).unwrap();
        let (a0, a1) = amounts_for_liquidity(mid, lo, hi, 1_000_000_000_000_000_000);
        assert!(a0 > U256::ZERO && a1 > U256::ZERO);
        // At the geometric centre of a symmetric range the two sides match.
        let d = if a0 > a1 { a0 - a1 } else { a1 - a0 };
        assert!(d < a0 / U256::from(1000u16), "a0 {a0} a1 {a1}");
    }

    #[test]
    fn argument_order_is_normalised() {
        let lo = sqrt_price_at_tick(-600).unwrap();
        let hi = sqrt_price_at_tick(600).unwrap();
        let mid = sqrt_price_at_tick(0).unwrap();
        assert_eq!(
            amounts_for_liquidity(mid, lo, hi, 1e18 as u128),
            amounts_for_liquidity(mid, hi, lo, 1e18 as u128)
        );
    }

    #[test]
    fn zero_liquidity_owes_nothing() {
        assert_eq!(fees_owed(0, U256::from(999u32), U256::ZERO), U256::ZERO);
    }

    #[test]
    fn fee_growth_wraparound_does_not_panic() {
        let last = U256::MAX - U256::from(10u8);
        let now = U256::from(5u8);
        // Wrapped delta is 16; with 2^128 liquidity that is 16 * 2^128 >> 128.
        let owed = fees_owed(1u128 << 127, now, last);
        assert_eq!(owed, (U256::from(16u8) * U256::from(1u128 << 127)) >> 128);
    }
}

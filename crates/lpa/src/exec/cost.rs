pub fn rebalance_cost_usd(gas_units: u64, gas_price_wei: u128, eth_price_usd: f64) -> f64 {
    let wei = gas_units as f64 * gas_price_wei as f64;
    (wei / 1e18) * eth_price_usd
}

pub fn within_spend_cap(cost_usd: f64, max_gas_usd: f64) -> bool {
    cost_usd <= max_gas_usd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cost_matches_manual() {
        let usd = rebalance_cost_usd(270_000, 10_000_000_000, 3000.0);
        assert!((usd - 8.1).abs() < 1e-9, "got {usd}");
    }

    #[test]
    fn cost_scales_with_gas_price() {
        let lo = rebalance_cost_usd(270_000, 5_000_000_000, 3000.0);
        let hi = rebalance_cost_usd(270_000, 50_000_000_000, 3000.0);
        assert!(hi > lo);
        assert!((hi / lo - 10.0).abs() < 1e-9);
    }

    #[test]
    fn cap_gate() {
        assert!(within_spend_cap(8.1, 50.0));
        assert!(within_spend_cap(50.0, 50.0));
        assert!(!within_spend_cap(50.01, 50.0));
    }
}

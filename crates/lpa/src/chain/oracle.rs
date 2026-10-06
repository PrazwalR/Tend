use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use alloy::primitives::Address;
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::sol;
use anyhow::{anyhow, bail, Context, Result};
use tracing::{debug, error, info, warn};

sol! {
    #[sol(rpc)]
    interface IAggregatorV3 {
        function decimals() external view returns (uint8);
        function description() external view returns (string);
        function latestRoundData() external view returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        );
    }
}

/// Reject a quote older than this — a stalled feed is worse than a stale
/// constant, because it looks live.
const MAX_ANSWER_AGE_SECS: u64 = 3600;
/// How often the refresher re-reads the feed.
const REFRESH_SECS: u64 = 60;
/// Price is shared as micro-dollars so it fits an atomic without a lock.
const USD_SCALE: f64 = 1e6;
/// ETH/USD answers outside this band are rejected as implausible.
const MIN_PLAUSIBLE_USD: f64 = 1.0;
const MAX_PLAUSIBLE_USD: f64 = 1_000_000.0;
/// A cached price older than this is not fresh enough to gate spending. Two
/// refresh intervals, so one missed poll is tolerated and a dead feed is not.
const MAX_CACHE_AGE_SECS: u64 = REFRESH_SECS * 2;

pub struct EthPriceOracle {
    provider: DynProvider,
    feed: Address,
    decimals: u8,
    /// Oldest answer accepted, from the feed's heartbeat plus a margin.
    max_age_secs: u64,
}

/// Answer age accepted per known feed: its heartbeat plus five minutes. One flat
/// hour accepted a Base answer three heartbeats old (full audit OR-4).
pub fn max_answer_age_secs(feed: Address) -> u64 {
    use alloy::primitives::address;
    if feed == address!("0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70") {
        1_200 + 300 // Base ETH/USD, 20 min heartbeat
    } else if feed == address!("0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419") {
        3_600 + 300 // Ethereum ETH/USD, 1 h heartbeat
    } else {
        MAX_ANSWER_AGE_SECS
    }
}

impl EthPriceOracle {
    /// Connects and verifies the feed really is ETH/USD. A misconfigured
    /// address that happens to be some other Chainlink pair would otherwise
    /// price gas against the wrong asset with no visible error.
    pub async fn connect(rpc_url: &str, feed: Address) -> Result<Self> {
        let provider = ProviderBuilder::new()
            .connect_http(rpc_url.parse().context("invalid rpc url")?)
            .erased();
        let agg = IAggregatorV3::new(feed, &provider);

        let description = agg
            .description()
            .call()
            .await
            .context("price feed does not answer description()")?;
        let normalized = description.to_uppercase().replace(' ', "");
        if !normalized.contains("ETH") || !normalized.contains("USD") {
            bail!("feed {feed} is '{description}', not an ETH/USD pair");
        }
        let decimals = agg.decimals().call().await.context("feed decimals()")?;

        info!(%feed, feed_description = %description, decimals, "ETH/USD oracle connected");
        Ok(Self {
            provider,
            feed,
            decimals,
            max_age_secs: max_answer_age_secs(feed),
        })
    }

    pub async fn price_usd(&self) -> Result<f64> {
        let agg = IAggregatorV3::new(self.feed, &self.provider);
        let round = agg.latestRoundData().call().await?;
        if round.answer.is_negative() || round.answer.is_zero() {
            bail!("feed returned non-positive answer");
        }
        let updated_at: u64 = round.updatedAt.try_into().unwrap_or(0);
        let age = now_secs().saturating_sub(updated_at);
        if age > self.max_age_secs {
            bail!("feed answer is {age}s old (max {}s)", self.max_age_secs);
        }
        let raw: f64 = round
            .answer
            .to_string()
            .parse()
            .map_err(|_| anyhow!("unparsable feed answer"))?;
        Ok(raw / 10f64.powi(self.decimals as i32))
    }
}

/// Live ETH/USD, refreshed in the background. Holds the last good value so a
/// transient RPC failure does not wipe the price out from under the gas cap;
/// the seed is the operator's configured fallback.
///
/// `updated_at` is what distinguishes "priced a minute ago" from "the feed never
/// connected and this is the seed constant". Without it a dead feed serves the
/// seed forever behind a single warning, which is fine for an advisory estimate
/// and not fine for anything that authorises spending.
#[derive(Clone)]
pub struct EthPrice {
    micro_usd: Arc<AtomicU64>,
    updated_at: Arc<AtomicU64>,
}

impl EthPrice {
    pub fn new(seed_usd: f64) -> Self {
        Self {
            micro_usd: Arc::new(AtomicU64::new((seed_usd * USD_SCALE) as u64)),
            updated_at: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Last known price, fresh or not. For advisory use (EV estimates) only.
    pub fn get(&self) -> f64 {
        self.micro_usd.load(Ordering::Relaxed) as f64 / USD_SCALE
    }

    /// `None` when the price is seed-only or stale. Anything that gates real
    /// spending must use this and refuse to act on `None`.
    pub fn get_fresh(&self) -> Option<f64> {
        let ts = self.updated_at.load(Ordering::Relaxed);
        if ts == 0 || now_secs().saturating_sub(ts) > MAX_CACHE_AGE_SECS {
            return None;
        }
        Some(self.get())
    }

    fn set(&self, usd: f64) {
        // A plausible band, not just > 0: an answer of $0.00000001 used to store
        // as 0 *and* stamp fresh, pricing every transaction at $0 against both
        // spend caps (full audit DM-4).
        if usd.is_finite() && (MIN_PLAUSIBLE_USD..=MAX_PLAUSIBLE_USD).contains(&usd) {
            self.micro_usd
                .store((usd * USD_SCALE) as u64, Ordering::Relaxed);
            self.updated_at.store(now_secs(), Ordering::Relaxed);
        }
    }

    /// One synchronous read, for the one-shot CLI path where there is no time for
    /// a background refresher to land before the transaction is priced.
    pub async fn refresh_now(&self, oracle: &EthPriceOracle) -> Result<f64> {
        let p = oracle.price_usd().await?;
        self.set(p);
        Ok(p)
    }

    /// Spawns a refresher; the handle keeps serving the seed until the first
    /// successful read lands.
    pub fn spawn_refresher(&self, oracle: EthPriceOracle) {
        let price = self.clone();
        tokio::spawn(async move {
            let mut consecutive_failures = 0u32;
            loop {
                match oracle.price_usd().await {
                    Ok(p) => {
                        debug!(eth_usd = p, "refreshed ETH price");
                        consecutive_failures = 0;
                        price.set(p);
                    }
                    Err(e) => {
                        consecutive_failures += 1;
                        // A price that never arrives stops being a blip and starts
                        // being a config error; say so loudly rather than warning
                        // on a loop forever.
                        if consecutive_failures >= 3 {
                            error!(error = %crate::redact(&e), consecutive_failures, "ETH price feed is not answering; spending is gated off until it does");
                        } else {
                            warn!(error = %crate::redact(&e), last_known = price.get(), "ETH price refresh failed");
                        }
                    }
                }
                tokio::time::sleep(Duration::from_secs(REFRESH_SECS)).await;
            }
        });
    }
}

/// Builds a live ETH/USD handle for a chain: seeded with the operator's figure,
/// then corrected by the on-chain feed. A feed that cannot be reached leaves the
/// handle un-fresh, which gates spending off rather than pricing it wrongly.
pub async fn connect_eth_price(http_url: Option<String>, feed: Address, seed_usd: f64) -> EthPrice {
    let price = EthPrice::new(seed_usd);
    let Some(url) = http_url else {
        warn!(
            seed = seed_usd,
            "no HTTP RPC; ETH price is seed-only and spending stays gated off"
        );
        return price;
    };
    match EthPriceOracle::connect(&url, feed).await {
        Ok(o) => {
            if let Err(e) = price.refresh_now(&o).await {
                warn!(error = %crate::redact(&e), "first ETH price read failed");
            }
            price.spawn_refresher(o);
        }
        Err(e) => {
            warn!(error = %crate::redact(&e), seed = seed_usd, "ETH/USD oracle unavailable; spending stays gated off")
        }
    }
    price
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_is_served_before_any_refresh() {
        let p = EthPrice::new(3000.0);
        assert!((p.get() - 3000.0).abs() < 1e-6);
    }

    #[test]
    fn set_updates_and_survives_clone() {
        let p = EthPrice::new(3000.0);
        let q = p.clone();
        p.set(4321.5);
        assert!((q.get() - 4321.5).abs() < 1e-3, "clones share one cell");
    }

    #[test]
    fn seed_alone_is_not_fresh() {
        let p = EthPrice::new(3000.0);
        assert_eq!(
            p.get_fresh(),
            None,
            "a seed the feed never confirmed must not gate spending"
        );
        assert!((p.get() - 3000.0).abs() < 1e-6, "but it is still readable");
    }

    #[test]
    fn a_real_read_becomes_fresh() {
        let p = EthPrice::new(3000.0);
        p.set(4200.0);
        assert!((p.get_fresh().expect("fresh after a successful read") - 4200.0).abs() < 1e-3);
    }

    #[test]
    fn a_rejected_read_does_not_make_the_seed_look_fresh() {
        let p = EthPrice::new(3000.0);
        p.set(f64::NAN);
        p.set(-1.0);
        assert_eq!(p.get_fresh(), None, "a bad read must not stamp freshness");
    }

    #[test]
    fn nonsense_updates_are_ignored() {
        let p = EthPrice::new(3000.0);
        p.set(0.0);
        p.set(-5.0);
        p.set(f64::NAN);
        p.set(f64::INFINITY);
        assert!(
            (p.get() - 3000.0).abs() < 1e-6,
            "a bad read must not clobber the last good price"
        );
    }

    #[test]
    fn answer_age_follows_each_feeds_heartbeat() {
        use alloy::primitives::address;
        let base = address!("0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70");
        let eth = address!("0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419");
        assert_eq!(super::max_answer_age_secs(base), 1_500);
        assert_eq!(super::max_answer_age_secs(eth), 3_900);
        assert_eq!(
            super::max_answer_age_secs(Address::ZERO),
            super::MAX_ANSWER_AGE_SECS
        );
    }
}

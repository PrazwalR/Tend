use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use alloy::primitives::Address;
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::sol;
use anyhow::{anyhow, bail, Context, Result};
use tracing::{debug, info, warn};

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

pub struct EthPriceOracle {
    provider: DynProvider,
    feed: Address,
    decimals: u8,
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
        if age > MAX_ANSWER_AGE_SECS {
            bail!("feed answer is {age}s old (max {MAX_ANSWER_AGE_SECS}s)");
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
#[derive(Clone)]
pub struct EthPrice {
    micro_usd: Arc<AtomicU64>,
}

impl EthPrice {
    pub fn new(seed_usd: f64) -> Self {
        Self {
            micro_usd: Arc::new(AtomicU64::new((seed_usd * USD_SCALE) as u64)),
        }
    }

    pub fn get(&self) -> f64 {
        self.micro_usd.load(Ordering::Relaxed) as f64 / USD_SCALE
    }

    fn set(&self, usd: f64) {
        if usd.is_finite() && usd > 0.0 {
            self.micro_usd
                .store((usd * USD_SCALE) as u64, Ordering::Relaxed);
        }
    }

    /// Spawns a refresher; the handle keeps serving the seed until the first
    /// successful read lands.
    pub fn spawn_refresher(&self, oracle: EthPriceOracle) {
        let price = self.clone();
        tokio::spawn(async move {
            loop {
                match oracle.price_usd().await {
                    Ok(p) => {
                        debug!(eth_usd = p, "refreshed ETH price");
                        price.set(p);
                    }
                    Err(e) => {
                        warn!(error = %e, last_known = price.get(), "ETH price refresh failed")
                    }
                }
                tokio::time::sleep(Duration::from_secs(REFRESH_SECS)).await;
            }
        });
    }
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
}

use alloy::primitives::{address, Address};
use anyhow::{anyhow, bail, Result};

#[derive(Clone, Copy)]
pub struct ChainAddrs {
    pub pool_manager: Address,
    pub state_view: Address,
    /// Chainlink ETH/USD aggregator proxy. Verified by `description()` at
    /// connect time, so an override that points elsewhere is rejected loudly.
    pub eth_usd_feed: Address,
}

#[derive(Clone)]
pub struct ChainConfig {
    pub chain_id: u64,
    pub name: &'static str,
    pub addrs: ChainAddrs,
}

impl ChainConfig {
    pub fn from_name(name: &str) -> Result<Self> {
        match name.to_lowercase().as_str() {
            "base" => Ok(Self {
                chain_id: 8453,
                name: "base",
                addrs: ChainAddrs {
                    pool_manager: address!("0x498581ff718922c3f8e6a244956af099b2652b2b"),
                    state_view: address!("0xa3c0c9b65bad0b08107aa264b0f3db444b867a71"),
                    eth_usd_feed: address!("0x71041dddad3595f9ced3dccfbe3d1f4b0a16bb70"),
                },
            }),
            "ethereum" | "eth" | "mainnet" => Ok(Self {
                chain_id: 1,
                name: "ethereum",
                addrs: ChainAddrs {
                    pool_manager: address!("0x000000000004444c5dc75cb358380d2e3de08a90"),
                    state_view: address!("0x7ffe42c4a5deea5b0fec41c94c136cf115597227"),
                    eth_usd_feed: address!("0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419"),
                },
            }),
            other => bail!("unknown chain: {other}"),
        }
    }

    pub fn ws_url(&self) -> Result<String> {
        let key = if self.name == "base" {
            "RPC_WS_BASE"
        } else {
            "RPC_WS_ETHEREUM"
        };
        std::env::var(key).map_err(|_| anyhow!("{key} not set in env"))
    }

    pub fn http_url(&self) -> Result<String> {
        let key = if self.name == "base" {
            "RPC_BASE"
        } else {
            "RPC_ETHEREUM"
        };
        std::env::var(key).map_err(|_| anyhow!("{key} not set in env"))
    }
}

#[cfg(test)]
mod tests {
    use super::ChainConfig;

    #[test]
    fn known_chains_resolve() {
        assert_eq!(ChainConfig::from_name("base").unwrap().chain_id, 8453);
        assert_eq!(ChainConfig::from_name("eth").unwrap().chain_id, 1);
        assert_eq!(ChainConfig::from_name("MAINNET").unwrap().chain_id, 1);
        assert!(ChainConfig::from_name("solana").is_err());
    }

    #[test]
    fn eth_usd_feed_differs_per_chain() {
        let base = ChainConfig::from_name("base").unwrap().addrs.eth_usd_feed;
        let eth = ChainConfig::from_name("ethereum")
            .unwrap()
            .addrs
            .eth_usd_feed;
        assert_ne!(base, eth);
    }

    #[test]
    fn state_view_differs_per_chain() {
        let base = ChainConfig::from_name("base").unwrap().addrs.state_view;
        let eth = ChainConfig::from_name("ethereum").unwrap().addrs.state_view;
        assert_ne!(base, eth);
    }

    #[test]
    fn pool_manager_differs_per_chain() {
        let base = ChainConfig::from_name("base").unwrap().addrs.pool_manager;
        let eth = ChainConfig::from_name("ethereum")
            .unwrap()
            .addrs
            .pool_manager;
        assert_ne!(base, eth);
    }
}

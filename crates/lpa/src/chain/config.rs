use alloy::primitives::{address, Address};
use anyhow::{anyhow, bail, Result};

#[derive(Clone, Copy)]
#[allow(dead_code)]
pub struct ChainAddrs {
    pub pool_manager: Address,
    pub state_view: Address,
    pub position_manager: Address,
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
                    position_manager: address!("0x7c5f5a4bbd8fd63184577525326123b519429bdc"),
                },
            }),
            "ethereum" | "eth" | "mainnet" => Ok(Self {
                chain_id: 1,
                name: "ethereum",
                addrs: ChainAddrs {
                    pool_manager: address!("0x000000000004444c5dc75cb358380d2e3de08a90"),
                    state_view: address!("0x7ffe42c4a5deea5b0fec41c94c136cf115597ea0"),
                    position_manager: address!("0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e"),
                },
            }),
            other => bail!("unknown chain: {other}"),
        }
    }

    pub fn ws_url(&self) -> Result<String> {
        let key = if self.name == "base" { "RPC_WS_BASE" } else { "RPC_WS_ETHEREUM" };
        std::env::var(key).map_err(|_| anyhow!("{key} not set in env"))
    }

    #[allow(dead_code)]
    pub fn http_url(&self) -> Result<String> {
        let key = if self.name == "base" { "RPC_BASE" } else { "RPC_ETHEREUM" };
        std::env::var(key).map_err(|_| anyhow!("{key} not set in env"))
    }
}

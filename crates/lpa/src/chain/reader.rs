use alloy::primitives::{keccak256, Address, B256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::sol;
use alloy::sol_types::SolValue;
use anyhow::{Context, Result};

sol! {
    #[derive(Debug)]
    struct PoolKeyAbi {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    #[sol(rpc)]
    interface IAutopilotHookRead {
        function positions(bytes32 positionId) external view returns (
            address owner,
            PoolKeyAbi key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            bool active,
            uint64 lastRebalanceAt
        );
    }
}

/// v4 `PoolId` is `keccak256(abi.encode(poolKey))`.
pub fn pool_id_of(key: &PoolKeyAbi) -> B256 {
    keccak256(key.abi_encode())
}

#[derive(Debug, Clone, PartialEq)]
pub struct HookPosition {
    pub owner: Address,
    pub pool_id: B256,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub fee: u32,
    pub tick_spacing: i32,
    pub liquidity: u128,
    pub active: bool,
}

/// Read-only HTTP view of on-chain state. The WS subscription drives the
/// daemon; this is the authoritative source consulted when a reorg invalidates
/// an already-applied log, and when a position needs enriching beyond what the
/// events carry.
pub struct ChainReader {
    provider: DynProvider,
    hook: Address,
}

impl ChainReader {
    pub async fn connect(rpc_url: &str, hook: Address) -> Result<Self> {
        let provider = ProviderBuilder::new()
            .connect_http(rpc_url.parse().context("invalid rpc url")?)
            .erased();
        Ok(Self { provider, hook })
    }

    /// Authoritative position state straight from the hook's storage. `None`
    /// when the hook has no record of the id at all.
    pub async fn hook_position(&self, position_id: B256) -> Result<Option<HookPosition>> {
        let hook = IAutopilotHookRead::new(self.hook, &self.provider);
        let p = hook.positions(position_id).call().await?;
        if p.owner == Address::ZERO {
            return Ok(None);
        }
        Ok(Some(HookPosition {
            owner: p.owner,
            pool_id: pool_id_of(&p.key),
            tick_lower: p.tickLower.as_i32(),
            tick_upper: p.tickUpper.as_i32(),
            fee: p.key.fee.to::<u32>(),
            tick_spacing: p.key.tickSpacing.as_i32(),
            liquidity: p.liquidity,
            active: p.active,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;
    use alloy::primitives::aliases::{I24, U24};

    #[test]
    fn pool_id_matches_v4_abi_encoding() {
        let k = PoolKeyAbi {
            currency0: address!("0x0000000000000000000000000000000000000001"),
            currency1: address!("0x0000000000000000000000000000000000000002"),
            fee: U24::from(3000u32),
            tickSpacing: I24::try_from(60).unwrap(),
            hooks: Address::ZERO,
        };
        assert_eq!(
            format!("{:#x}", pool_id_of(&k)),
            "0xf6a117501d7c06f988e5cb96441dff2b3bc20bc7c52bc943e66da6e63b93c97c"
        );
    }
}

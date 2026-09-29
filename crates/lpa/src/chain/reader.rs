use alloy::primitives::aliases::I24;
use alloy::primitives::{keccak256, Address, B256, U256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::sol;
use alloy::sol_types::SolValue;
use anyhow::{anyhow, Context, Result};

use crate::chain::tickmath;

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
    interface IStateView {
        function getSlot0(bytes32 poolId) external view returns (
            uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee
        );
        function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
            external view returns (
                uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128
            );
        function getFeeGrowthInside(bytes32 poolId, int24 tickLower, int24 tickUpper)
            external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
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
        function idle(bytes32 positionId) external view returns (uint128 amount0, uint128 amount1);
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
    state_view: Address,
}

/// On-chain truth for one position at a point in time. `amount0`/`amount1` are
/// what the liquidity would free if withdrawn now; `fees0`/`fees1` are accrued
/// but uncollected.
#[derive(Debug, Clone, PartialEq)]
pub struct PositionSnapshot {
    pub liquidity: u128,
    pub amount0: U256,
    pub amount1: U256,
    pub fees0: U256,
    pub fees1: U256,
    pub current_tick: i32,
}

impl ChainReader {
    pub async fn connect(rpc_url: &str, hook: Address, state_view: Address) -> Result<Self> {
        let provider = ProviderBuilder::new()
            .connect_http(rpc_url.parse().context("invalid rpc url")?)
            .erased();
        Ok(Self {
            provider,
            hook,
            state_view,
        })
    }

    /// Liquidity, token amounts and uncollected fees for a hook-custodied
    /// position. The hook is the PoolManager-side owner and the position id is
    /// its salt, which is how `AutopilotHook` keys every `modifyLiquidity`.
    pub async fn position_snapshot(
        &self,
        pool_id: B256,
        position_id: B256,
        tick_lower: i32,
        tick_upper: i32,
    ) -> Result<PositionSnapshot> {
        let sv = IStateView::new(self.state_view, &self.provider);
        let lower = I24::try_from(tick_lower).map_err(|_| anyhow!("tick_lower out of range"))?;
        let upper = I24::try_from(tick_upper).map_err(|_| anyhow!("tick_upper out of range"))?;

        let slot0 = sv.getSlot0(pool_id).call().await?;
        let info = sv
            .getPositionInfo(pool_id, self.hook, lower, upper, position_id)
            .call()
            .await?;
        let growth = sv.getFeeGrowthInside(pool_id, lower, upper).call().await?;

        let sqrt_price = U256::from(slot0.sqrtPriceX96);
        let sqrt_lower = tickmath::sqrt_price_at_tick(tick_lower)
            .ok_or_else(|| anyhow!("tick_lower outside tick domain"))?;
        let sqrt_upper = tickmath::sqrt_price_at_tick(tick_upper)
            .ok_or_else(|| anyhow!("tick_upper outside tick domain"))?;
        let (amount0, amount1) =
            tickmath::amounts_for_liquidity(sqrt_price, sqrt_lower, sqrt_upper, info.liquidity);

        Ok(PositionSnapshot {
            liquidity: info.liquidity,
            amount0,
            amount1,
            fees0: tickmath::fees_owed(
                info.liquidity,
                growth.feeGrowthInside0X128,
                info.feeGrowthInside0LastX128,
            ),
            fees1: tickmath::fees_owed(
                info.liquidity,
                growth.feeGrowthInside1X128,
                info.feeGrowthInside1LastX128,
            ),
            current_tick: slot0.tick.as_i32(),
        })
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

    /// Tokens a rebalance could not place, held by the hook for the position
    /// until the next rebalance or withdraw.
    pub async fn idle_balance(&self, position_id: B256) -> Result<(u128, u128)> {
        let hook = IAutopilotHookRead::new(self.hook, &self.provider);
        let r = hook.idle(position_id).call().await?;
        Ok((r.amount0, r.amount1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;
    use alloy::primitives::aliases::U24;

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

use alloy::primitives::{Address, B256};
use alloy::providers::Provider;
use alloy::sol;
use anyhow::Result;

sol! {
    #[sol(rpc)]
    contract IStateView {
        function getSlot0(bytes32 poolId)
            external view
            returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    }
}

#[allow(dead_code)]
pub async fn current_tick<P: Provider>(provider: P, state_view: Address, pool_id: B256) -> Result<i32> {
    let sv = IStateView::new(state_view, provider);
    let slot0 = sv.getSlot0(pool_id).call().await?;
    Ok(slot0.tick.as_i32())
}

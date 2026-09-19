// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

/// Stage 3: one swap per broadcast, so each lands in its own block and the
/// daemon samples one tick per block the way the strategy expects.
contract E2ESwap is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        PoolSwapTest sw = PoolSwapTest(vm.envAddress("SWAPPER"));
        MockERC20 t0 = MockERC20(vm.envAddress("TOKEN0"));
        MockERC20 t1 = MockERC20(vm.envAddress("TOKEN1"));
        address hook = vm.envAddress("HOOK");
        int256 amount = vm.envOr("SWAP_AMOUNT", int256(-1e15));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));

        vm.startBroadcast();
        t0.approve(address(sw), type(uint256).max);
        t1.approve(address(sw), type(uint256).max);
        sw.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        (, int24 tick,,) = manager.getSlot0(key.toId());
        console2.log("TICK=%s", vm.toString(int256(tick)));
    }
}

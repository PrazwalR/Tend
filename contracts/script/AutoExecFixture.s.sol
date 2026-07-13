// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract AutoExecFixture is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        address hookAddr = vm.envAddress("HOOK");
        address manager = vm.envAddress("POOL_MANAGER");
        AutopilotHook hook = AutopilotHook(hookAddr);

        vm.startBroadcast();
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(msg.sender, 1e27);
        t1.mint(msg.sender, 1e27);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        IPoolManager(manager).initialize(key, SQRT_PRICE_1_1);

        bytes32 pid = hook.deposit(key, -600, 600, 1e18, -120000, 120000);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(manager));
        t0.approve(address(lp), type(uint256).max);
        t1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e19, salt: 0}), ""
        );

        PoolSwapTest sw = new PoolSwapTest(IPoolManager(manager));
        t0.approve(address(sw), type(uint256).max);
        t1.approve(address(sw), type(uint256).max);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        for (uint256 i = 0; i < 3; i++) {
            sw.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ts,
                ""
            );
            sw.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
                ts,
                ""
            );
        }
        sw.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );

        vm.stopBroadcast();
        console2.log("POSITION");
        console2.logBytes32(pid);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract AutopilotHookForkTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint64 constant COOLDOWN = 3600;

    AutopilotHook hook;
    PoolKey key;
    PoolSwapTest swapRouter;
    address rebalancer = address(0xBEEF);
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x5555) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(MANAGER, rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(address(this), 1e24);
        t1.mint(address(this), 1e24);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        swapRouter = new PoolSwapTest(MANAGER);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(hook));
        MANAGER.initialize(key, SQRT_PRICE_1_1);
    }

    function test_fork_full_lifecycle_against_real_manager() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        bytes32 pid = hook.deposit(key, -600, 600, 1e18);
        (, , , , uint128 liq, bool active,) = hook.positions(pid);
        assertEq(liq, 1e18);
        assertTrue(active);

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(key, sp, ts, "");

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200);
        (, , int24 lo, int24 hi, uint128 newLiq,,) = hook.positions(pid);
        assertEq(lo, -1200);
        assertEq(hi, 1200);
        assertGt(newLiq, 0);

        hook.withdraw(pid);
        (, , , , , bool stillActive,) = hook.positions(pid);
        assertFalse(stillActive);
    }
}

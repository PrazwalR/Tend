// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {AutopilotHook} from "../src/AutopilotHook.sol";

contract AutopilotHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    address attacker = address(0xBAD);
    uint64 constant COOLDOWN = 3600;

    event AutopilotCheck(PoolId indexed poolId, int24 tick, uint256 positionCount);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _deposit(int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        return hook.deposit(key, lo, hi, liq);
    }

    function _swap() internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(key, sp, ts, "");
    }

    function test_deposit_then_withdraw_roundtrip() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        bytes32 pid = _deposit(-600, 600, 1e18);
        (address owner,,,, uint128 liq, bool active,) = hook.positions(pid);
        assertEq(owner, address(this));
        assertEq(liq, 1e18);
        assertTrue(active);
        assertEq(hook.poolPositionCount(id), 1);
        assertLt(t0.balanceOf(address(this)), b0);

        hook.withdraw(pid);
        (,,,,, bool activeAfter,) = hook.positions(pid);
        assertFalse(activeAfter);
        assertEq(hook.poolPositionCount(id), 0);
        assertApproxEqAbs(t0.balanceOf(address(this)), b0, 2);
        assertApproxEqAbs(t1.balanceOf(address(this)), b1, 2);
    }

    function test_afterSwap_emits_check_when_positions_exist() public {
        _deposit(-600, 600, 1e18);
        vm.expectEmit(true, false, false, false, address(hook));
        emit AutopilotCheck(id, 0, 0);
        _swap();
    }

    function test_afterSwap_silent_without_positions() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}), ""
        );
        vm.recordLogs();
        _swap();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = AutopilotCheck.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                assertTrue(false, "AutopilotCheck emitted without positions");
            }
        }
        assertEq(hook.poolPositionCount(id), 0);
    }

    function test_rebalance_moves_range() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200);

        (, , int24 lo, int24 hi, uint128 liq,, uint64 last) = hook.positions(pid);
        assertEq(lo, -1200);
        assertEq(hi, 1200);
        assertGt(liq, 0);
        assertEq(last, uint64(block.timestamp));
    }

    function test_rebalance_only_rebalancer() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotRebalancer.selector);
        hook.rebalance(pid, -1200, 1200);
    }

    function test_rebalance_cooldown_enforced() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(AutopilotHook.RebalanceTooSoon.selector, COOLDOWN));
        hook.rebalance(pid, -1200, 1200);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200);
    }

    function test_rebalance_rejects_unaligned_ticks() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.rebalance(pid, -601, 1200);
    }

    function test_rebalance_rejects_inverted_range() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.InvalidTickRange.selector);
        hook.rebalance(pid, 1200, -1200);
    }

    function test_withdraw_only_owner() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotPositionOwner.selector);
        hook.withdraw(pid);
    }

    function test_withdraw_works_while_paused() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.deposit(key, -600, 600, 1e18);

        hook.withdraw(pid);
        (,,,,, bool active,) = hook.positions(pid);
        assertFalse(active);
    }

    function test_rebalance_blocked_while_paused() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        hook.pause();
        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.rebalance(pid, -1200, 1200);
    }

    function test_unlockCallback_only_pool_manager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_admin_only_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setRebalancer(attacker, true);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.pause();
    }

    function test_owner_can_manage_rebalancers() public {
        assertFalse(hook.isRebalancer(attacker));
        hook.setRebalancer(attacker, true);
        assertTrue(hook.isRebalancer(attacker));
        hook.setRebalancer(rebalancer, false);
        assertFalse(hook.isRebalancer(rebalancer));
    }

    function test_deposit_zero_liquidity_reverts() public {
        vm.expectRevert(AutopilotHook.ZeroLiquidity.selector);
        hook.deposit(key, -600, 600, 0);
    }

    function test_deposit_unaligned_ticks_reverts() public {
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.deposit(key, -601, 600, 1e18);
    }

    function test_double_withdraw_reverts() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.withdraw(pid);
        vm.expectRevert(AutopilotHook.PositionNotActive.selector);
        hook.withdraw(pid);
    }

    function test_cannot_rebalance_inactive_position() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.withdraw(pid);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.PositionNotActive.selector);
        hook.rebalance(pid, -1200, 1200);
    }

    function test_two_positions_independent() public {
        bytes32 a = _deposit(-600, 600, 1e18);
        bytes32 b = _deposit(-1200, 1200, 2e18);
        assertTrue(a != b);
        assertEq(hook.poolPositionCount(id), 2);

        hook.withdraw(a);
        assertEq(hook.poolPositionCount(id), 1);
        (,,,,, bool bActive,) = hook.positions(b);
        assertTrue(bActive);
    }

    function test_rebalance_to_one_sided_range() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200);
        (,, int24 lo, int24 hi, uint128 liq,,) = hook.positions(pid);
        assertEq(lo, 600);
        assertEq(hi, 1200);
        assertGt(liq, 0);
    }
}

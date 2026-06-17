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
        return hook.deposit(key, lo, hi, liq, TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
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
        hook.rebalance(pid, -1200, 1200, 0);

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
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_cooldown_enforced() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(AutopilotHook.RebalanceTooSoon.selector, COOLDOWN));
        hook.rebalance(pid, -1200, 1200, 0);

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_rejects_unaligned_ticks() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.rebalance(pid, -601, 1200, 0);
    }

    function test_rebalance_rejects_inverted_range() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.InvalidTickRange.selector);
        hook.rebalance(pid, 1200, -1200, 0);
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
        hook.deposit(key, -600, 600, 1e18, -600, 600);

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
        hook.rebalance(pid, -1200, 1200, 0);
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
        hook.deposit(key, -600, 600, 0, -600, 600);
    }

    function test_deposit_unaligned_ticks_reverts() public {
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.deposit(key, -601, 600, 1e18, -660, 660);
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
        hook.rebalance(pid, -1200, 1200, 0);
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
        hook.rebalance(pid, 600, 1200, 0);
        (,, int24 lo, int24 hi, uint128 liq,,) = hook.positions(pid);
        assertEq(lo, 600);
        assertEq(hi, 1200);
        assertGt(liq, 0);
    }

    function test_deposit_rejects_foreign_hook() public {
        PoolKey memory foreign = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0xDEAD)));
        vm.expectRevert(AutopilotHook.HookMismatch.selector);
        hook.deposit(foreign, -600, 600, 1e18, -600, 600);
    }

    function test_rebalance_slippage_floor_reverts() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.SlippageExceeded.selector);
        hook.rebalance(pid, -1200, 1200, type(uint128).max);
    }

    function test_rebalance_returns_liquidity() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, -1200, 1200, 1);
        assertGt(newLiq, 0);
    }

    function test_set_interval_too_long_reverts() public {
        vm.expectRevert(AutopilotHook.IntervalTooLong.selector);
        hook.setMinRebalanceInterval(366 days);
    }

    function test_deposit_zero_spacing_reverts() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 0, IHooks(hook));
        vm.expectRevert(AutopilotHook.InvalidTickRange.selector);
        hook.deposit(bad, 0, 60, 1e18, -600, 600);
    }

    function testFuzz_deposit_withdraw_conserves(uint128 liq) public {
        liq = uint128(bound(liq, 1e6, 1e23));
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        bytes32 pid = _deposit(-600, 600, liq);
        hook.withdraw(pid);

        assertApproxEqAbs(t0.balanceOf(address(this)), b0, 10);
        assertApproxEqAbs(t1.balanceOf(address(this)), b1, 10);
        (,,,,, bool active,) = hook.positions(pid);
        assertFalse(active);
    }

    function test_deposit_native_currency_reverts() public {
        PoolKey memory nativeKey = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(hook));
        vm.expectRevert(AutopilotHook.NativeNotSupported.selector);
        hook.deposit(nativeKey, -600, 600, 1e18, -600, 600);
    }

    function test_deposit_range_outside_bounds_reverts() public {
        vm.expectRevert(AutopilotHook.OutOfBounds.selector);
        hook.deposit(key, -600, 600, 1e18, -300, 300);
    }

    function test_rebalance_respects_owner_bounds() public {
        bytes32 pid = hook.deposit(key, -600, 600, 1e18, -600, 600);
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.OutOfBounds.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        vm.prank(rebalancer);
        hook.rebalance(pid, -540, 540, 0);
        (,, int24 lo, int24 hi,,,) = hook.positions(pid);
        assertEq(lo, -540);
        assertEq(hi, 540);
    }

    function test_renounce_ownership_disabled() public {
        vm.expectRevert(AutopilotHook.RenounceDisabled.selector);
        hook.renounceOwnership();
    }

    function test_two_step_ownership_transfer() public {
        hook.transferOwnership(attacker);
        assertEq(hook.owner(), address(this));
        vm.prank(attacker);
        hook.acceptOwnership();
        assertEq(hook.owner(), attacker);
    }
}

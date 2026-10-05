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
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";

contract AutopilotHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    address attacker = address(0xBAD);
    uint64 constant COOLDOWN = 3600;

    event AutopilotCheck(PoolId indexed poolId, int24 tick, uint256 positionCount);

    function setUp() public {
        // A realistic clock. At Foundry's default block.timestamp of 1 the cooldown
        // assertions pass for the wrong reason: readyAt is an absolute timestamp of
        // at most 365 days, which is below any live chain's clock.
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _deposit(int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        return hook.deposit(
            key,
            lo,
            hi,
            liq,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
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
        _afterCooldown();

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);

        (,, int24 lo, int24 hi, uint128 liq,, uint64 last) = hook.positions(pid);
        assertEq(lo, -1200);
        assertEq(hi, 1200);
        assertGt(liq, 0);
        assertEq(last, uint64(block.timestamp));
    }

    function test_rebalance_only_rebalancer() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotRebalancer.selector);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_cooldown_enforced() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(rebalancer);
        // readyAt is measured from the deposit, not from 0.
        vm.expectRevert(
            abi.encodeWithSelector(AutopilotHook.RebalanceTooSoon.selector, uint64(block.timestamp) + COOLDOWN)
        );
        hook.rebalance(pid, -1200, 1200, 0);

        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_rejects_unaligned_ticks() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.rebalance(pid, -601, 1200, 0);
    }

    function test_rebalance_rejects_inverted_range() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
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
        hook.deposit(
            key, -600, 600, 1e18, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );

        hook.withdraw(pid);
        (,,,,, bool active,) = hook.positions(pid);
        assertFalse(active);
    }

    function test_rebalance_blocked_while_paused() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
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
        _queued(abi.encodeCall(hook.setRebalancer, (attacker, true)));
        assertTrue(hook.isRebalancer(attacker));
        hook.setRebalancer(rebalancer, false);
        assertFalse(hook.isRebalancer(rebalancer));
    }

    function test_deposit_zero_liquidity_reverts() public {
        vm.expectRevert(AutopilotHook.ZeroLiquidity.selector);
        hook.deposit(key, -600, 600, 0, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max);
    }

    function test_deposit_unaligned_ticks_reverts() public {
        vm.expectRevert(AutopilotHook.TicksNotAligned.selector);
        hook.deposit(
            key, -601, 600, 1e18, -660, 660, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
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
        _afterCooldown();
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
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        (,, int24 lo, int24 hi, uint128 liq,,) = hook.positions(pid);
        assertEq(lo, 600);
        assertEq(hi, 1200);
        assertGt(liq, 0);
    }

    // REG-2. A one-sided target in a pool with no other depth: the bounded swap
    // cannot fill, so half the position cannot be placed. It used to be paid out
    // to the owner as loose tokens while the rebalance reported success.
    function test_undeployable_remainder_stays_with_position() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        bytes32 pid = _deposit(-600, 600, 1e18);
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);

        assertEq(t0.balanceOf(address(this)), b0, "nothing paid out mid-rebalance");
        assertEq(t1.balanceOf(address(this)), b1, "nothing paid out mid-rebalance");

        (uint128 held0, uint128 held1) = hook.idle(pid);
        assertGt(uint256(held0) + held1, 0, "the undeployable part is recorded");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), held0, "backed 1:1 by claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), held1, "backed 1:1 by claims");
    }

    function test_withdraw_pays_out_idle_balance() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        (uint128 held0, uint128 held1) = hook.idle(pid);

        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        hook.withdraw(pid);

        // The rebuilt range sits above spot, so its liquidity comes back as token0
        // alone; every token1 the owner receives is the idle balance.
        assertEq(t1.balanceOf(address(this)) - b1, held1, "idle token1 returned in full");
        assertGe(t0.balanceOf(address(this)) - b0, held0, "idle token0 returned with the liquidity");
        (uint128 after0, uint128 after1) = hook.idle(pid);
        assertEq(uint256(after0) + after1, 0, "idle record cleared");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "no claims left behind");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "no claims left behind");
    }

    function test_idle_balance_redeployed_when_depth_returns() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        (,,,, uint128 liqBefore,,) = hook.positions(pid);
        (uint160 sqrtP,,,) = manager.getSlot0(id);
        uint256 idleBefore = _value(h0, h1, sqrtP);

        // Depth arrives; the same range is now a valid target, because there is
        // something idle to place in it.
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e20, salt: 0}), ""
        );
        _nextBlock();
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);

        (,,,, uint128 liqAfter,,) = hook.positions(pid);
        (h0, h1) = hook.idle(pid);
        (sqrtP,,,) = manager.getSlot0(id);
        assertGt(liqAfter, liqBefore, "idle capital is back in the position");
        assertLt(_value(h0, h1, sqrtP) * 20, idleBefore, "at most 5% of it still idle");
    }

    function test_same_range_rebalance_is_still_a_noop_without_idle() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.NoOpRebalance.selector);
        hook.rebalance(pid, -600, 600, 0);
    }

    function _value(uint256 a0, uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        uint256 p = uint256(sqrtP) * sqrtP >> 96;
        return (a0 * p >> 96) + a1;
    }

    function test_deposit_rejects_foreign_hook() public {
        PoolKey memory foreign = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0xDEAD)));
        vm.expectRevert(AutopilotHook.HookMismatch.selector);
        hook.deposit(
            foreign, -600, 600, 1e18, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
    }

    function test_rebalance_slippage_floor_reverts() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.SlippageExceeded.selector);
        hook.rebalance(pid, -1200, 1200, type(uint128).max);
    }

    function test_rebalance_returns_liquidity() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
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
        hook.deposit(bad, 0, 60, 1e18, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max);
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

    function test_position_opened_emits_fee_and_spacing() public {
        vm.recordLogs();
        _deposit(-600, 600, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("PositionOpened(bytes32,address,bytes32,int24,int24,uint128,uint24,int24)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                (,, uint128 liq, uint24 fee, int24 spacing) =
                    abi.decode(logs[i].data, (int24, int24, uint128, uint24, int24));
                assertEq(fee, 3000);
                assertEq(spacing, 60);
                assertEq(liq, 1e18);
                found = true;
            }
        }
        assertTrue(found, "PositionOpened with fee+spacing emitted");
    }

    function test_deposit_native_currency_reverts() public {
        PoolKey memory nativeKey = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(hook));
        vm.expectRevert(AutopilotHook.NativeNotSupported.selector);
        hook.deposit(
            nativeKey, -600, 600, 1e18, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
    }

    function test_deposit_range_outside_bounds_reverts() public {
        vm.expectRevert(AutopilotHook.OutOfBounds.selector);
        hook.deposit(
            key, -600, 600, 1e18, -300, 300, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
    }

    function test_rebalance_respects_owner_bounds() public {
        bytes32 pid = hook.deposit(
            key, -600, 600, 1e18, -600, 600, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
        _afterCooldown();

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.OutOfBounds.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        vm.prank(rebalancer);
        hook.rebalance(pid, -540, 540, 0);
        (,, int24 lo, int24 hi,,,) = hook.positions(pid);
        assertEq(lo, -540);
        assertEq(hi, 540);
    }

    /// Regression: before the re-ratio swap, a position that had genuinely
    /// drifted out of range held one token only, so recentring computed zero
    /// liquidity and reverted — the exact case the product exists to handle.
    function test_rebalance_after_price_exits_range() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -4e19, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );

        (, int24 tick,,) = manager.getSlot0(id);
        assertLt(tick, int24(-600), "price should have exited the range below");

        _afterCooldown();
        _catchUpRef();
        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, -1800, -600, 0);

        assertGt(newLiq, 0, "rebalance must fund the new range");
        (,, int24 lo, int24 hi, uint128 stored,,) = hook.positions(pid);
        assertEq(lo, -1800);
        assertEq(hi, -600);
        assertEq(stored, newLiq);
    }

    /// The same drift, but recentring onto a range that straddles spot — this
    /// needs both tokens while the position holds only one.
    function test_rebalance_out_of_range_onto_straddling_range() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -4e19, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        (, int24 tick,,) = manager.getSlot0(id);
        int24 lower = ((tick - 600) / 60) * 60;
        int24 upper = ((tick + 600) / 60) * 60;

        _afterCooldown();
        _catchUpRef();
        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, lower, upper, 0);
        assertGt(newLiq, 0, "straddling range must be funded from one-sided holdings");
    }

    /// The re-ratio swap must not become a way to drain a position: the
    /// caller-supplied floor still has to bind.
    function test_rebalance_out_of_range_respects_slippage_floor() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -4e19, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        _afterCooldown();
        _catchUpRef();
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.SlippageExceeded.selector);
        hook.rebalance(pid, -1800, -600, type(uint128).max);
    }

    // --- CRIT-1 regression: the re-ratio swap must not destroy the pool price ---

    /// The swap runs after this position's liquidity is burned. Unbounded, it walks
    /// the price to the tick extreme and the call still succeeds.
    function test_rebalance_does_not_destroy_pool_price() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        (uint160 beforePrice,,,) = manager.getSlot0(id);
        _afterCooldown();

        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);

        (uint160 afterPrice, int24 tick,,) = manager.getSlot0(id);
        assertLt(uint256(afterPrice), uint256(TickMath.MAX_SQRT_PRICE - 1), "price walked to the sentinel");
        assertLt(tick, int24(887000), "price walked to the tick extreme");
        assertLe(tick, int24(1200), "price pushed beyond the target range");
        assertGt(uint256(afterPrice), uint256(beforePrice) / 100, "price collapsed");
    }

    /// Same guarantee on the opposite side.
    function test_rebalance_below_spot_does_not_destroy_pool_price() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, -600, 0);

        (, int24 tick,,) = manager.getSlot0(id);
        assertGt(tick, int24(-887000), "price walked to the tick extreme");
        assertGe(tick, int24(-1200), "price pushed beyond the target range");
    }

    /// The dominant-LP case: with no external liquidity the unbounded swap has
    /// nothing to trade against and runs to the sentinel.
    function test_rebalance_with_no_external_liquidity_keeps_price_sane() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();

        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);

        (, int24 tick,,) = manager.getSlot0(id);
        assertLt(tick, int24(887000), "dominant-LP rebalance walked the price to the extreme");
    }

    // --- CRIT-2 regression: ownership must survive the real deploy path ---

    function test_owner_is_explicit_not_msg_sender() public view {
        assertEq(hook.owner(), address(this), "owner must be the configured address");
    }

    // --- C-3 regression: the first rebalance is subject to the cooldown ---

    function test_first_rebalance_respects_cooldown() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(AutopilotHook.RebalanceTooSoon.selector, uint64(block.timestamp) + COOLDOWN)
        );
        hook.rebalance(pid, -1200, 1200, 0);
    }

    // --- HIGH-1 regression: the value floor is protocol-enforced ---

    /// The rebalancer supplies `minLiquidity`, so it cannot be the real bound.
    /// A zero owner tolerance must stop a rebalance the rebalancer would allow.
    /// The rebalancer supplies `minLiquidity`, so it cannot be the real bound.
    /// A 1% fee tier makes the re-ratio swap cost more than the tightest
    /// permitted tolerance, and the protocol-side guard must reject it even
    /// though the rebalancer waived its own.
    function test_value_floor_binds_even_when_rebalancer_waives_slippage() public {
        PoolKey memory fat = PoolKey(currency0, currency1, 10000, 200, IHooks(hook));
        manager.initialize(fat, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            fat, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );

        bytes32 pid = hook.deposit(
            fat,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(200),
            TickMath.maxUsableTick(200),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        hook.setMaxRebalanceLossBps(hook.MIN_LOSS_TOLERANCE_BPS()); // 25 bps, tightest permitted
        _afterCooldown();

        // minLiquidity = 0 waives the rebalancer-side guard entirely; the
        // protocol-side floor must still bind.
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.ValueLossExceeded.selector);
        hook.rebalance(pid, 600, 1200, 0);
    }

    /// The same move under a tolerance that accommodates the fee must succeed —
    /// otherwise the test above would pass for the wrong reason.
    function test_value_floor_permits_the_same_move_at_a_realistic_tolerance() public {
        PoolKey memory fat = PoolKey(currency0, currency1, 10000, 200, IHooks(hook));
        manager.initialize(fat, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            fat, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );

        bytes32 pid = hook.deposit(
            fat,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(200),
            TickMath.maxUsableTick(200),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        _queued(abi.encodeCall(hook.setMaxRebalanceLossBps, (hook.MAX_LOSS_TOLERANCE_BPS())));
        _afterCooldown();

        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, 600, 1200, 0);
        assertGt(newLiq, 0);
    }

    function test_value_floor_allows_a_normal_rebalance() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, -1200, 1200, 0);
        assertGt(newLiq, 0);
    }

    /// A tolerance below the pool fee makes every rebalance revert — an
    /// off-switch wearing the costume of a safety parameter.
    /// Re-audit R-1: an LP holding most of a pool's depth could pull it for one
    /// block, which made the re-ratio swap's price impact exceed the value
    /// tolerance and reverted the rebalance — pinning the position out of range
    /// at no cost to the griefer. Bounding the swap's impact up front means a
    /// thin pool yields a smaller partial fill instead of a revert.
    function test_liquidity_pull_does_not_brick_an_out_of_range_rebalance() public {
        // Griefer supplies the bulk of the pool's depth.
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60000, tickUpper: 60000, liquidityDelta: 4e18, salt: bytes32(uint256(1))
            }),
            ""
        );

        bytes32 pid = _deposit(-600, 600, 1e18);

        // Push the position out of range, downward.
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -3e17, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        (, int24 drifted,,) = manager.getSlot0(id);
        assertLt(drifted, int24(-600), "position should be out of range");

        _afterCooldown();
        _catchUpRef(); // the daemon pokes before it retries

        // The grief: withdraw the dominant depth in the same block as the rebalance.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60000, tickUpper: 60000, liquidityDelta: -4e18, salt: bytes32(uint256(1))
            }),
            ""
        );

        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, -2400, -1200, 0);
        assertGt(newLiq, 0, "pulling pool depth must not make a position un-rebalanceable");
    }

    function test_swap_impact_bound_is_owner_only_and_bounded() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setMaxSwapImpactBps(100);

        uint16 cap = hook.MAX_SWAP_IMPACT_BPS();
        vm.expectRevert(AutopilotHook.SwapImpactTooHigh.selector);
        hook.setMaxSwapImpactBps(cap + 1);

        vm.expectRevert(AutopilotHook.SwapImpactTooHigh.selector);
        hook.setMaxSwapImpactBps(0);

        _queued(abi.encodeCall(hook.setMaxSwapImpactBps, (250)));
        assertEq(hook.maxSwapImpactBps(), 250);
    }

    function test_loss_tolerance_has_a_floor() public {
        uint16 floorBps = hook.MIN_LOSS_TOLERANCE_BPS();
        vm.expectRevert(AutopilotHook.LossToleranceTooHigh.selector);
        hook.setMaxRebalanceLossBps(0);

        vm.expectRevert(AutopilotHook.LossToleranceTooHigh.selector);
        hook.setMaxRebalanceLossBps(floorBps - 1);

        hook.setMaxRebalanceLossBps(floorBps);
        assertEq(hook.maxRebalanceLossBps(), floorBps);
    }

    function test_loss_tolerance_is_owner_only_and_capped() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setMaxRebalanceLossBps(10);

        // Read first: vm.expectRevert applies to the next call, which would
        // otherwise be the constant getter rather than the setter.
        uint16 cap = hook.MAX_LOSS_TOLERANCE_BPS();
        vm.expectRevert(AutopilotHook.LossToleranceTooHigh.selector);
        hook.setMaxRebalanceLossBps(cap + 1);

        hook.setMaxRebalanceLossBps(25);
        assertEq(hook.maxRebalanceLossBps(), 25);
    }

    // --- HIGH-2 regression: free churn inside the envelope ---

    /// A same-range rebalance moved nothing but still paid the pool fee, so it
    /// was a pure value leak the tick envelope could not prevent.
    function test_no_op_rebalance_reverts() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.NoOpRebalance.selector);
        hook.rebalance(pid, -600, 600, 0);
    }

    /// A zero cooldown let a rebalancer loop rebalance() within one transaction.
    function test_interval_floor_enforced() public {
        vm.expectRevert(AutopilotHook.IntervalTooShort.selector);
        hook.setMinRebalanceInterval(0);

        uint64 floorSecs = hook.MIN_REBALANCE_INTERVAL();
        vm.expectRevert(AutopilotHook.IntervalTooShort.selector);
        hook.setMinRebalanceInterval(floorSecs - 1);

        _queued(abi.encodeCall(hook.setMinRebalanceInterval, (floorSecs)));
        assertEq(hook.minRebalanceInterval(), floorSecs);
    }

    function test_constructor_rejects_zero_cooldown() public {
        address flags2 = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x7777) << 144));
        vm.expectRevert(AutopilotHook.IntervalTooShort.selector);
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, 0), flags2);
    }

    // --- HIGH-3 regression: a frozen owner must not strand the paired token ---

    /// `withdraw` paid only to `pos.owner` and only in the underlying, so a
    /// blacklist on one currency reverted the whole unlock and locked the other
    /// token too. Exiting to a different recipient must work.
    function test_withdraw_to_alternate_recipient() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        address rescue = address(0xBEEF1);
        bytes32 pid = _deposit(-600, 600, 1e18);

        hook.withdraw(pid, rescue, false);

        assertGt(t0.balanceOf(rescue), 0, "recipient received the freed token0");
        (,,,,, bool active,) = hook.positions(pid);
        assertFalse(active);
    }

    /// Taking ERC-6909 claims never calls the token, so it is the censorship-proof
    /// exit: the claim is minted inside the PoolManager regardless of transfer
    /// restrictions on the underlying.
    function test_withdraw_as_claims_does_not_touch_the_token() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        bytes32 pid = _deposit(-600, 600, 1e18);
        uint256 afterDeposit = t0.balanceOf(address(this));

        hook.withdraw(pid, address(this), true);

        assertEq(t0.balanceOf(address(this)), afterDeposit, "underlying must not move on a claims exit");
        assertGt(manager.balanceOf(address(this), currency0.toId()), 0, "claim minted for token0");
        assertGt(manager.balanceOf(address(this), currency1.toId()), 0, "claim minted for token1");
    }

    function test_withdraw_rejects_zero_recipient() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.expectRevert(AutopilotHook.ZeroRecipient.selector);
        hook.withdraw(pid, address(0), false);
    }

    function test_withdraw_alternate_recipient_still_owner_only() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotPositionOwner.selector);
        hook.withdraw(pid, attacker, false);
    }

    // --- HIGH-4 regression: spot must be corroborated before a rebalance ---

    /// A large single-transaction price move cannot drag the reference with it,
    /// so the rebalance refuses to trade at a price the hook cannot corroborate.
    function test_rebalance_reverts_when_spot_is_far_from_reference() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);
        _swap(); // seed the reference near the honest tick

        // One transaction, a very large move: the reference may advance by at most
        // maxTickMovePerBlock, so spot ends up far outside the tolerated band.
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -6e20, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );

        // However many quiet blocks pass, a reference left clamped short of spot
        // is not settled: only a write that reaches spot can settle it.
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, -3000, -1800, 0);
    }

    function test_price_guard_is_owner_only_and_bounded() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setPriceGuard(100, 150);

        int24 maxMove = hook.MAX_TICK_MOVE_PER_BLOCK();
        vm.expectRevert(AutopilotHook.DeviationBoundTooHigh.selector);
        hook.setPriceGuard(maxMove + 1, 150);

        vm.expectRevert(AutopilotHook.DeviationBoundTooHigh.selector);
        hook.setPriceGuard(0, 150);

        // Narrowing the deviation window is instant.
        hook.setPriceGuard(maxMove, 150);
        assertEq(hook.maxDeviationTicks(), int24(150));

        // The per-block cap is two-sided (TL-1): lowering it freezes the
        // reference, so it waits like a loosening does.
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(100, 150);
        _queued(abi.encodeCall(hook.setPriceGuard, (int24(100), int24(150))));
        assertEq(hook.maxTickMovePerBlock(), int24(100));
    }

    // --- O-4 regression: an L2 restart must not execute queued rebalances ---

    function test_rebalance_blocked_while_sequencer_down() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        MockSequencerFeed feed = new MockSequencerFeed(1, block.timestamp - 10_000); // 1 == down
        hook.setSequencerUptimeFeed(address(feed));
        _afterCooldown();

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.SequencerDown.selector);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_blocked_during_grace_period_after_restart() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        // Up, but only just: the backlog is still draining and spot is gapping.
        MockSequencerFeed feed = new MockSequencerFeed(0, block.timestamp);
        hook.setSequencerUptimeFeed(address(feed));

        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.SequencerGracePeriod.selector);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_allowed_once_grace_period_elapsed() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        MockSequencerFeed feed = new MockSequencerFeed(0, block.timestamp);
        hook.setSequencerUptimeFeed(address(feed));
        vm.warp(block.timestamp + hook.SEQUENCER_GRACE_PERIOD() + 1);
        vm.roll(vm.getBlockNumber() + hook.MIN_STABLE_BLOCKS());

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
        (,, int24 lo,,,,) = hook.positions(pid);
        assertEq(lo, -1200);
    }

    /// A zero feed is the L1 configuration and must not gate anything.
    function test_zero_sequencer_feed_disables_the_check() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        assertEq(hook.sequencerUptimeFeed(), address(0));
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_sequencer_feed_is_owner_only() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setSequencerUptimeFeed(address(0xFEED));
    }

    // --- T-4 regression: token restrictions must be enforced, not assumed ---

    function test_allowlist_off_by_default() public {
        assertFalse(hook.allowlistEnforced());
        _deposit(-600, 600, 1e18); // unaffected
    }

    function test_allowlist_blocks_unlisted_pair_when_enforced() public {
        hook.setAllowlistEnforced(true);
        vm.expectRevert(AutopilotHook.PoolNotAllowed.selector);
        hook.deposit(
            key, -600, 600, 1e18, -1200, 1200, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );

        hook.setAllowedPool(key, true);
        bytes32 pid = hook.deposit(
            key, -600, 600, 1e18, -1200, 1200, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
        (,,,,, bool active,) = hook.positions(pid);
        assertTrue(active);
    }

    /// De-listing must never strand an open position, so the check is on the way
    /// in only.
    function test_delisting_a_pool_still_allows_exit_and_rebalance() public {
        hook.setAllowlistEnforced(true);
        hook.setAllowedPool(key, true);
        bytes32 pid = hook.deposit(
            key, -600, 600, 1e18, -1800, 1800, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );

        hook.setAllowedPool(key, false); // de-list

        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0); // still rebalanceable

        hook.withdraw(pid); // still exitable
        (,,,,, bool active,) = hook.positions(pid);
        assertFalse(active);
    }

    function test_allowlist_admin_is_owner_only() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setAllowlistEnforced(true);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setAllowedPool(key, true);
    }

    // --- C-5 regression: owners can scope or revoke their rebalancer ---

    function test_owner_can_scope_rebalancer_to_one_address() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _queued(abi.encodeCall(hook.setRebalancer, (attacker, true)));
        hook.setPositionRebalancer(pid, rebalancer);
        _afterCooldown();

        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotRebalancer.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_owner_can_disable_automation_entirely() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.setPositionRebalancer(pid, hook.AUTOMATION_OFF());
        _afterCooldown();

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.AutomationDisabled.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        hook.withdraw(pid); // opting out must not trap the position
    }

    function test_unscoped_position_accepts_any_allowlisted_rebalancer() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        assertEq(hook.positionRebalancer(pid), address(0));
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_only_position_owner_can_scope_it() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotPositionOwner.selector);
        hook.setPositionRebalancer(pid, attacker);
    }

    // --- T-2 regression: a fee-on-transfer deposit must say what went wrong ---

    /// Without the settle check this surfaces as v4's `CurrencyNotSettled` from
    /// deep inside `unlock` — accurate, and useless for diagnosis.
    function test_fee_on_transfer_deposit_reverts_legibly() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        MockERC20 other = MockERC20(Currency.unwrap(currency1));
        fot.mint(address(this), 1e24);
        fot.approve(address(hook), type(uint256).max);

        (Currency c0, Currency c1) = address(fot) < address(other)
            ? (Currency.wrap(address(fot)), currency1)
            : (currency1, Currency.wrap(address(fot)));
        PoolKey memory fotKey = PoolKey(c0, c1, 3000, 60, IHooks(hook));
        manager.initialize(fotKey, SQRT_PRICE_1_1);

        vm.expectPartialRevert(AutopilotHook.FeeOnTransferNotSupported.selector);
        hook.deposit(
            fotKey, -600, 600, 1e18, -1200, 1200, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
    }

    /// The guard must not fire for a well-behaved token.
    function test_settle_guard_does_not_affect_normal_tokens() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        (,,,,, bool active,) = hook.positions(pid);
        assertTrue(active);
    }

    // --- G-5: hunt for the rounding shortfall the audit derived analytically ---

    /// The audit reasoned that round-down in `getLiquidityForAmounts` against
    /// round-up in `getAmount0Delta` could leave a <=2 wei debt and revert the
    /// whole rebalance with `CurrencyNotSettled`, but produced no concrete input.
    /// Fuzzing the rebalance across liquidity sizes and target ranges is the
    /// cheapest way to find one if it exists.
    function testFuzz_rebalance_settles_across_sizes_and_ranges(uint128 liq, int24 shift) public {
        liq = uint128(bound(liq, 1e12, 1e22));
        shift = int24(bound(shift, -5000, 5000));
        int24 lower = (shift / 60) * 60;
        int24 upper = lower + 1200;
        if (lower <= TickMath.minUsableTick(60) || upper >= TickMath.maxUsableTick(60)) return;

        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e22, salt: 0}), ""
        );
        bytes32 pid = hook.deposit(
            key,
            -600,
            600,
            liq,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        _afterCooldown();

        vm.prank(rebalancer);
        // Any revert here should be a named hook error, never a settlement
        // failure leaking out of v4.
        try hook.rebalance(pid, lower, upper, 0) returns (uint128 newLiq) {
            assertGt(newLiq, 0);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == AutopilotHook.ZeroLiquidity.selector || sel == AutopilotHook.NothingFreed.selector
                    || sel == AutopilotHook.ValueLossExceeded.selector || sel == AutopilotHook.PriceDeviation.selector
                    || sel == AutopilotHook.SlippageExceeded.selector || sel == AutopilotHook.InvalidTickRange.selector
                    || sel == AutopilotHook.TicksNotAligned.selector || sel == AutopilotHook.NoOpRebalance.selector
                    || sel == AutopilotHook.OutOfBounds.selector,
                "unexpected revert - possible settlement shortfall"
            );
        }
    }

    // --- Re-audit M-1 regression: the price limit must stay inside v4's bounds ---

    /// tickSpacing 1/2/4/8 make min/maxUsableTick equal MIN/MAX_TICK, whose sqrt
    /// prices are exactly the closed bounds v4 rejects. The limit introduced to
    /// fix CRIT-1 landed on them and reverted a rebalance that worked before it.
    function test_rebalance_to_full_range_on_spacing_one() public {
        PoolKey memory k1 = PoolKey(currency0, currency1, 100, 1, IHooks(hook));
        manager.initialize(k1, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            k1, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        int24 lo = TickMath.minUsableTick(1);
        int24 hi = TickMath.maxUsableTick(1);

        bytes32 pid = hook.deposit(
            k1, 100, 200, 1e18, lo, hi, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
        _afterCooldown();

        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, lo, hi, 0);
        assertGt(newLiq, 0, "full-range rebalance must not revert on the price bound");
    }

    // --- Re-audit A-2: consent must be expressible atomically at deposit ---

    /// Scoping via a follow-up transaction leaves a window in which a rebalancer
    /// added later has authority the owner never chose. The overload closes it.
    function test_deposit_can_scope_rebalancer_atomically() public {
        bytes32 pid = hook.deposit(
            key,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            rebalancer,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        assertEq(hook.positionRebalancer(pid), rebalancer);

        _queued(abi.encodeCall(hook.setRebalancer, (attacker, true))); // added AFTER the position existed
        _afterCooldown();

        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotRebalancer.selector);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_deposit_can_disable_automation_atomically() public {
        bytes32 pid = hook.deposit(
            key,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            hook.AUTOMATION_OFF(),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        _afterCooldown();
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.AutomationDisabled.selector);
        hook.rebalance(pid, -1200, 1200, 0);
        hook.withdraw(pid); // still exitable
    }

    /// The six-argument form must keep its previous meaning.
    function test_deposit_without_scope_accepts_any_allowlisted_rebalancer() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        assertEq(hook.positionRebalancer(pid), address(0));
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    // --- Re-audit R-2 / R-3: price-reference lifecycle ---

    // R-6. Spot exactly on the target's lower edge: the straddle branch must not
    // treat the whole range as room to travel. Measured on a deep pool (where an
    // overshooting fill is cheap to execute) and as sole LP (where it is not).
    function test_r6_spot_on_lower_edge_deep_pool() public {
        _deepPool();
        _r6(0, 600);
    }

    function test_r6_spot_on_upper_edge_deep_pool() public {
        _deepPool();
        _r6(-600, 0);
    }

    function test_r6_spot_on_lower_edge_sole_lp() public {
        _r6(0, 600);
    }

    function test_r6_spot_on_upper_edge_sole_lp() public {
        _r6(-600, 0);
    }

    // The cost of an empty-book walk is not paid in the rebalance, where the value
    // guard looks, but afterwards: arbitrage pulls price back to fair through the
    // freshly placed position. Measured end to end, at the fair price.
    function test_r6_empty_book_walk_cost_is_bounded() public {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));
        bytes32 pid = _deposit(-600, 600, 1e18);
        uint256 valueIn = (a0 - t0.balanceOf(address(this))) + (a1 - t1.balanceOf(address(this)));

        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 0, 600, 0);
        _nextBlock();
        _swapTo(0); // arbitrage restores the fair price of 1

        // Only the withdrawal is counted: this contract is also the arbitrageur,
        // so its total balance would net the arbitrage gain against the loss.
        a0 = t0.balanceOf(address(this));
        a1 = t1.balanceOf(address(this));
        hook.withdraw(pid);
        uint256 valueOut = (t0.balanceOf(address(this)) - a0) + (t1.balanceOf(address(this)) - a1);

        uint256 lost = valueIn > valueOut ? valueIn - valueOut : 0;
        emit log_named_uint("position value in", valueIn);
        emit log_named_uint("lost to the walk (bps)", lost * 10_000 / valueIn);
        assertLe(lost * 10_000, valueIn * hook.maxRebalanceLossBps(), "within the rebalance loss tolerance");
    }

    // A-9. An attacker pushes spot just inside the deviation bound, the rebalance
    // lands at that price (the daemon centres its new range on the tick it sees),
    // and the attacker swaps back. The value guard measures both sides at the
    // manipulated price, so it sees a fair trade. Measured against a control that
    // takes the same push and swap-back without the rebalance.
    function test_a9_rebalance_at_manipulated_price() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        _nextBlock();

        // The push the old 2000-tick bound admitted, at a 1428 bps loss, is refused.
        _swapTo(1990);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
        hook.rebalance(pid, 780, 3180, 0);
        _swapTo(0);
        _nextBlock();

        // The largest push the bound admits stays inside the loss tolerance. The
        // default is also the cap, so this covers anything the owner can set.
        uint256 lost = _a9Loss(pid, hook.MAX_DEVIATION_TICKS() - 10);
        emit log_named_uint("loss at the bound (bps)", lost);
        assertLe(lost, hook.maxRebalanceLossBps(), "within the rebalance loss tolerance");
    }

    function _a9Loss(bytes32 pid, int24 push) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        uint256 control = _a9Run(pid, push, false);
        vm.revertToState(snap);
        uint256 attacked = _a9Run(pid, push, true);
        vm.revertToState(snap);
        return control > attacked ? (control - attacked) * 10_000 / control : 0;
    }

    function _a9Run(bytes32 pid, int24 push, bool rebalance) internal returns (uint256 valueOut) {
        _swapTo(push);
        if (rebalance) {
            // The daemon centres the new range on the tick it observes. One tick
            // spacing either side is the narrowest it picks, and the worst case.
            int24 c = (push / 60) * 60;
            vm.prank(rebalancer);
            hook.rebalance(pid, c - 60, c + 60, 0);
        }
        _swapTo(0);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));
        hook.withdraw(pid);
        valueOut = (t0.balanceOf(address(this)) - a0) + (t1.balanceOf(address(this)) - a1);
    }

    function _r6(int24 lo, int24 hi) internal {
        bytes32 pid = _deposit(-600, 600, 1e18);
        (uint160 sqrt0, int24 t0,,) = manager.getSlot0(id);
        assertEq(t0, int24(0));
        assertEq(sqrt0, TickMath.getSqrtPriceAtTick(0), "spot sits exactly on the edge");
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, lo, hi, 0);

        (, int24 t1,,) = manager.getSlot0(id);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        (,,,, uint128 liq,,) = hook.positions(pid);
        emit log_named_int("tick after", t1);
        emit log_named_uint("idle0", h0);
        emit log_named_uint("idle1", h1);
        emit log_named_uint("liquidity", liq);
        assertGt(liq, 0);
        // The swap may enter the range it is funding but must not cross it.
        assertGe(t1, lo, "price left the target range below");
        assertLe(t1, hi, "price left the target range above");
    }

    function _deepPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
    }

    /// Swap until spot sits exactly on `target`.
    function _swapTo(int24 target) internal {
        (, int24 now_,,) = manager.getSlot0(id);
        if (now_ == target) return;
        bool down = target < now_;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: down, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Past the rebalance cooldown, as a chain would get there: time AND blocks.
    /// An hour-long cooldown spans hundreds of blocks, and with no swaps in them
    /// they are stable block ends for the price reference.
    function _afterCooldown() internal {
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
    }

    /// `vm.roll(block.number + 1)` is unsafe under via_ir: repeated reads of
    /// `block.number` in one test function get folded, so a loop keeps rolling to
    /// the same block. Read the real value from the cheatcode instead.
    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// What the daemon does after a fast move: poke once a block until the price
    /// reference has caught up with spot (500 ticks a block, so 10 covers 5000).
    function _catchUpRef() internal {
        for (uint256 i; i < 10; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        _nextBlock();
    }

    // --- re-audit 2026-10-03: small contract fixes ---

    /// TK-3: paying a withdrawal to the hook or the PoolManager strands it.
    function test_withdraw_rejects_hook_and_pool_manager_as_recipient() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.expectRevert(AutopilotHook.InvalidRecipient.selector);
        hook.withdraw(pid, address(hook), true);
        vm.expectRevert(AutopilotHook.InvalidRecipient.selector);
        hook.withdraw(pid, address(manager), false);
        hook.withdraw(pid, address(this), false);
    }

    /// TK-5: an event-following indexer can track the idle balance to zero.
    function test_idle_release_and_zero_residual_are_evented() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0); // sole LP: leaves an idle balance
        (uint128 h0, uint128 h1) = hook.idle(pid);
        assertGt(uint256(h0) + h1, 0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit AutopilotHook.IdleReleased(pid, h0, h1);
        hook.withdraw(pid);
    }

    function test_deep_rebalance_reports_zero_residual() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        vm.recordLogs();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == AutopilotHook.RebalanceResidual.selector) seen = true;
        }
        assertTrue(seen, "RebalanceResidual is emitted on every rebalance, zeros included");
    }

    /// DS-3: the allowlist is keyed by full pool key, and only for this hook.
    function test_pool_allowlist_is_per_pool_key() public {
        PoolKey memory foreign = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0xDEAD)));
        vm.expectRevert(AutopilotHook.HookMismatch.selector);
        hook.setAllowedPool(foreign, true);

        hook.setAllowedPool(key, true);
        hook.setAllowlistEnforced(true);
        (PoolKey memory other,) = initPool(currency0, currency1, IHooks(hook), 500, SQRT_PRICE_1_1);
        vm.expectRevert(AutopilotHook.PoolNotAllowed.selector);
        hook.deposit(
            other,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(10),
            TickMath.maxUsableTick(10),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        hook.deposit(
            key, -600, 600, 1e18, -1200, 1200, address(0), type(uint256).max, type(uint256).max, type(uint256).max
        );
    }

    /// An owner change that loosens a protection: queue, wait out the delay, run.
    function _queued(bytes memory call) internal {
        hook.queueChange(call);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        hook.executeChange(call);
    }

    // --- A-1 / A-5: loosening owner changes wait out a timelock ---

    function test_loosening_change_must_be_queued() public {
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMaxRebalanceLossBps(500);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setRebalancer(attacker, true);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMaxSwapImpactBps(1000);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMinRebalanceInterval(60);
    }

    function test_tightening_change_is_instant() public {
        hook.setMaxRebalanceLossBps(50);
        hook.setMaxSwapImpactBps(10);
        hook.setPriceGuard(hook.maxTickMovePerBlock(), 100);
        hook.setMinRebalanceInterval(2 * COOLDOWN);
        hook.setRebalancer(rebalancer, false);
        assertEq(hook.maxRebalanceLossBps(), 50);
        assertFalse(hook.isRebalancer(rebalancer));
    }

    function test_queued_change_runs_only_inside_its_window() public {
        bytes memory call = abi.encodeCall(hook.setMaxRebalanceLossBps, (500));
        hook.queueChange(call);
        (, uint64 eta,) = hook.pendingChange(hook.setMaxRebalanceLossBps.selector);
        assertEq(eta, vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());

        vm.expectRevert(abi.encodeWithSelector(AutopilotHook.ChangeNotReady.selector, eta));
        hook.executeChange(call);

        vm.warp(uint256(eta) + hook.TIMELOCK_GRACE() + 1);
        vm.expectRevert(abi.encodeWithSelector(AutopilotHook.ChangeExpired.selector, eta + hook.TIMELOCK_GRACE()));
        hook.executeChange(call);

        hook.queueChange(call);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        hook.executeChange(call);
        assertEq(hook.maxRebalanceLossBps(), 500);

        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(call);
    }

    function test_cancelled_change_cannot_run() public {
        bytes memory call = abi.encodeCall(hook.setRebalancer, (attacker, true));
        hook.queueChange(call);
        hook.cancelChange(hook.changeKey(call));
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(call);
        assertFalse(hook.isRebalancer(attacker));
    }

    function test_queue_is_owner_only_and_setter_only() public {
        bytes memory call = abi.encodeCall(hook.setRebalancer, (attacker, true));
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.queueChange(call);
        vm.stopPrank();

        // The self-call runs as the hook; nothing that moves funds may be queued.
        bytes memory drain = abi.encodeWithSignature("withdraw(bytes32)", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(AutopilotHook.NotTimelockable.selector, bytes4(drain)));
        hook.queueChange(drain);
    }

    function test_queued_call_still_validates_its_arguments() public {
        bytes memory call = abi.encodeCall(hook.setMaxRebalanceLossBps, (5000));
        hook.queueChange(call);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.expectRevert(AutopilotHook.LossToleranceTooHigh.selector);
        hook.executeChange(call);
    }

    function test_sequencer_feed_add_is_instant_but_replace_is_queued() public {
        MockSequencerFeed a = new MockSequencerFeed(0, 1);
        MockSequencerFeed b = new MockSequencerFeed(0, 1);
        hook.setSequencerUptimeFeed(address(a));
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setSequencerUptimeFeed(address(b));
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setSequencerUptimeFeed(address(0));
        _queued(abi.encodeCall(hook.setSequencerUptimeFeed, (address(b))));
        assertEq(hook.sequencerUptimeFeed(), address(b));
    }

    function _ref() internal view returns (int24 tick, int24 anchor) {
        (tick, anchor,,,,,) = hook.priceRef(id);
    }

    /// R-2(a): the anchor must come from the depositor's own transaction, not
    /// from whichever swap happens to land first afterwards.
    function test_deposit_seeds_reference_at_spot() public {
        _deepPool();
        _swapTo(-1200);
        _deposit(-1800, -600, 1e18);
        (int24 t, int24 a) = _ref();
        assertEq(t, int24(-1200));
        assertEq(a, int24(-1200));
    }

    /// The reference moves at most one capped step per block, whatever the swaps.
    function test_reference_moves_at_most_one_step_per_block() public {
        _deepPool();
        _deposit(-600, 600, 1e18);
        int24 cap = hook.maxTickMovePerBlock();
        for (uint256 i = 1; i <= 3; i++) {
            _nextBlock();
            _swapTo(-20000 - int24(int256(i)) * 60);
            (int24 t,) = _ref();
            assertEq(t, -cap * int24(int256(i)), "one capped step per block");
        }
    }

    /// R-3: displacing spot and restoring it inside one block used to drag the
    /// reference a full step for free. Last-writer-wins returns it home.
    function test_same_block_round_trip_does_not_drag_reference() public {
        _deepPool();
        _deposit(-600, 600, 1e18);
        _nextBlock();

        _swapTo(-5000); // displace
        _swapTo(0); // restore, same block

        (int24 t,) = _ref();
        assertEq(t, int24(0), "a restored price must leave the reference where it was");
    }

    /// R-3: the deviation check reads the block-start anchor, so a front-run
    /// earlier in the same block cannot move the yardstick it is measured by.
    function test_rebalance_measures_against_block_start_anchor() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();
        _nextBlock();

        // 2400 ticks: past the 2000 bound from the anchor, but only 1900 from the
        // intra-block value the front-run itself produced.
        _swapTo(-2400);

        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
        hook.rebalance(pid, -3000, -1800, 0);
    }

    /// R-2(b): a pool that lost all its positions stops updating the reference.
    /// The next depositor must get a fresh seed, not a fossil.
    function test_reference_reseeded_when_pool_regains_a_position() public {
        _deepPool();
        bytes32 first = _deposit(-600, 600, 1e18);
        hook.withdraw(first);

        for (uint256 i = 0; i < 5; i++) {
            _nextBlock();
            _swapTo(-5000 - int24(int256(i)) * 60);
        }
        (, int24 spot,,) = manager.getSlot0(id);

        bytes32 second = hook.deposit(
            key,
            -5400,
            -4800,
            1e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        (int24 t,) = _ref();
        assertEq(t, spot, "reseeded at current spot");

        _afterCooldown();
        _nextBlock();
        vm.prank(rebalancer);
        hook.rebalance(second, -6000, -4800, 0); // a fossil would revert PriceDeviation here
    }

    /// R-2(c): after one large move on a pool that then goes quiet, nothing but
    /// a swap moved the reference, so rebalancing stayed blocked indefinitely.
    /// Poking gives it a bounded deadline.
    function test_quiet_pool_unblocked_by_poke() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 600, 1e18);
        _afterCooldown();

        _nextBlock();
        _swapTo(-3000); // reference follows only to -500
        _nextBlock();

        // The reference was clamped short of spot, so it is not settled.
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, -3600, -2400, 0);

        // No swaps from here on. Poke once per block until the reference reaches
        // spot: (3000 - 500) / 500 = 5. Quiet blocks after that count as stable
        // on their own; no more pokes are needed.
        for (uint256 i = 0; i < 5; i++) {
            hook.pokePriceRef(key);
            _nextBlock();
        }
        vm.roll(vm.getBlockNumber() + hook.MIN_STABLE_BLOCKS());

        vm.prank(rebalancer);
        hook.rebalance(pid, -3600, -2400, 0);
    }

    /// Poking is no faster than a swap: many pokes in one block, one step.
    function test_poke_is_rate_limited_per_block() public {
        _deepPool();
        _deposit(-600, 600, 1e18);
        _nextBlock();
        _swapTo(-10000);
        _nextBlock();

        for (uint256 i = 0; i < 10; i++) {
            hook.pokePriceRef(key);
        }
        (int24 t,) = _ref();
        assertEq(t, -2 * hook.maxTickMovePerBlock(), "ten pokes in one block move one step");
    }

    function test_poke_is_a_noop_on_a_pool_without_positions() public {
        hook.pokePriceRef(key);
        (,,, bool seeded,,,) = hook.priceRef(id);
        assertFalse(seeded);
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

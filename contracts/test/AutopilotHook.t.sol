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

        (,, int24 lo, int24 hi, uint128 liq,, uint64 last) = hook.positions(pid);
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
        // readyAt is measured from the deposit, not from 0.
        vm.expectRevert(
            abi.encodeWithSelector(AutopilotHook.RebalanceTooSoon.selector, uint64(block.timestamp) + COOLDOWN)
        );
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

        vm.warp(block.timestamp + COOLDOWN);
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

        vm.warp(block.timestamp + COOLDOWN);
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
        vm.warp(block.timestamp + COOLDOWN);
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
        vm.warp(block.timestamp + COOLDOWN);

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
        vm.warp(block.timestamp + COOLDOWN);

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
        vm.warp(block.timestamp + COOLDOWN);

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
    function test_value_floor_binds_even_when_rebalancer_waives_slippage() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.setMaxRebalanceLossBps(0); // tolerate no value loss at all
        vm.warp(block.timestamp + COOLDOWN);

        // minLiquidity = 0 waives the rebalancer-side guard entirely.
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.ValueLossExceeded.selector);
        hook.rebalance(pid, 600, 1200, 0);
    }

    function test_value_floor_allows_a_normal_rebalance() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        uint128 newLiq = hook.rebalance(pid, -1200, 1200, 0);
        assertGt(newLiq, 0);
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
        vm.warp(block.timestamp + COOLDOWN);
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

        hook.setMinRebalanceInterval(floorSecs);
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

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
        hook.rebalance(pid, -3000, -1800, 0);
    }

    /// The reference only moves one capped step per block, so a manipulator has to
    /// hold the price across many blocks rather than one transaction.
    function test_price_reference_moves_at_most_one_step_per_block() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        _deposit(-600, 600, 1e18);
        _swap();
        (int24 seeded,,) = hook.priceRef(id);

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 12);
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -2e17, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ts,
                ""
            );
        }

        (int24 moved,,) = hook.priceRef(id);
        int24 cap = hook.maxTickMovePerBlock();
        assertGe(seeded - moved, int24(0), "reference should track downward");
        assertLe(seeded - moved, cap * 3, "reference moved faster than the per-block cap");
    }

    /// Several swaps inside one block must advance the reference at most once.
    function test_price_reference_updates_once_per_block() public {
        _deposit(-600, 600, 1e18);
        _swap();
        (int24 first, uint32 at,) = hook.priceRef(id);

        _swap();
        _swap();
        (int24 second, uint32 at2,) = hook.priceRef(id);

        assertEq(at, at2, "same block must not re-stamp the reference");
        assertEq(first, second, "same block must not move the reference");
    }

    function test_price_guard_is_owner_only_and_bounded() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.setPriceGuard(100, 500);

        int24 maxMove = hook.MAX_TICK_MOVE_PER_BLOCK();
        vm.expectRevert(AutopilotHook.DeviationBoundTooHigh.selector);
        hook.setPriceGuard(maxMove + 1, 500);

        vm.expectRevert(AutopilotHook.DeviationBoundTooHigh.selector);
        hook.setPriceGuard(0, 500);

        hook.setPriceGuard(100, 500);
        assertEq(hook.maxTickMovePerBlock(), int24(100));
        assertEq(hook.maxDeviationTicks(), int24(500));
    }

    // --- O-4 regression: an L2 restart must not execute queued rebalances ---

    function test_rebalance_blocked_while_sequencer_down() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        MockSequencerFeed feed = new MockSequencerFeed(1, block.timestamp - 10_000); // 1 == down
        hook.setSequencerUptimeFeed(address(feed));
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.SequencerDown.selector);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_rebalance_blocked_during_grace_period_after_restart() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(block.timestamp + COOLDOWN);
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

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
        (,, int24 lo,,,,) = hook.positions(pid);
        assertEq(lo, -1200);
    }

    /// A zero feed is the L1 configuration and must not gate anything.
    function test_zero_sequencer_feed_disables_the_check() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        assertEq(hook.sequencerUptimeFeed(), address(0));
        vm.warp(block.timestamp + COOLDOWN);
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
        vm.expectRevert(AutopilotHook.PairNotAllowed.selector);
        hook.deposit(key, -600, 600, 1e18, -1200, 1200);

        hook.setAllowedPair(currency0, currency1, true);
        bytes32 pid = hook.deposit(key, -600, 600, 1e18, -1200, 1200);
        (,,,,, bool active,) = hook.positions(pid);
        assertTrue(active);
    }

    /// De-listing must never strand an open position, so the check is on the way
    /// in only.
    function test_delisting_a_pair_still_allows_exit_and_rebalance() public {
        hook.setAllowlistEnforced(true);
        hook.setAllowedPair(currency0, currency1, true);
        bytes32 pid = hook.deposit(key, -600, 600, 1e18, -1800, 1800);

        hook.setAllowedPair(currency0, currency1, false); // de-list

        vm.warp(block.timestamp + COOLDOWN);
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
        hook.setAllowedPair(currency0, currency1, true);
    }

    // --- C-5 regression: owners can scope or revoke their rebalancer ---

    function test_owner_can_scope_rebalancer_to_one_address() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.setRebalancer(attacker, true);
        hook.setPositionRebalancer(pid, rebalancer);
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotRebalancer.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_owner_can_disable_automation_entirely() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.setPositionRebalancer(pid, hook.AUTOMATION_OFF());
        vm.warp(block.timestamp + COOLDOWN);

        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.AutomationDisabled.selector);
        hook.rebalance(pid, -1200, 1200, 0);

        hook.withdraw(pid); // opting out must not trap the position
    }

    function test_unscoped_position_accepts_any_allowlisted_rebalancer() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        assertEq(hook.positionRebalancer(pid), address(0));
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, 1200, 0);
    }

    function test_only_position_owner_can_scope_it() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.prank(attacker);
        vm.expectRevert(AutopilotHook.NotPositionOwner.selector);
        hook.setPositionRebalancer(pid, attacker);
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

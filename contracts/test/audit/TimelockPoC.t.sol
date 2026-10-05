// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {AutopilotHook} from "../../src/AutopilotHook.sol";

/// Audit PoCs for the owner timelock (tend-2026-10-03, governance/access control).
contract TimelockPoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    address attacker = address(0xBAD);
    address newOwner = address(0x5AFE);
    uint64 constant COOLDOWN = 3600;
    int24 constant FAIR = 1200;

    function setUp() public {
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

    // ------------------------------------------------------------------ helpers

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

    function _deepPool() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
    }

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

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _refTick() internal view returns (int24 t) {
        (t,,,,,,) = hook.priceRef(id);
    }

    /// Value of a withdrawal in token1, at the FAIR price.
    function _withdrawValue(bytes32 pid) internal returns (uint256) {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));
        hook.withdraw(pid);
        uint256 d0 = t0.balanceOf(address(this)) - a0;
        uint256 d1 = t1.balanceOf(address(this)) - a1;
        uint160 s = TickMath.getSqrtPriceAtTick(FAIR);
        return FullMath.mulDiv(FullMath.mulDiv(d0, s, 1 << 96), s, 1 << 96) + d1;
    }

    /// One block: push spot to `push`, optionally rebalance one spacing either
    /// side of it (the daemon's narrowest pick), swap back to FAIR, withdraw.
    function _run(bytes32 pid, int24 push, bool doRebalance) internal returns (uint256) {
        _swapTo(push);
        if (doRebalance) {
            int24 c = (push / 60) * 60;
            vm.prank(rebalancer);
            hook.rebalance(pid, c - 60, c + 60, 0);
        }
        _swapTo(FAIR);
        return _withdrawValue(pid);
    }

    /// Market moves 0 -> FAIR and stays there for `blocks` blocks (pokes each block,
    /// as the daemon does).
    function _drift(uint256 blocks) internal {
        _nextBlock();
        _swapTo(FAIR);
        for (uint256 i; i < blocks; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        _nextBlock();
    }

    // ------------------------------------------------- TL-1: frozen reference

    /// An instant "tightening" of maxTickMovePerBlock freezes the price reference.
    /// After the market drifts, the deviation guard measures a pushed price against
    /// the stale reference, so the rebalancer can land a rebalance ~1000 ticks off
    /// fair -- far beyond the 200-tick A-9 cap and the 100 bps loss tolerance.
    function test_TL1_centred_range_measurement() public {
        // Lowering the per-block cap is no longer instant (TL-1 fix).
        int24 dev = hook.MAX_DEVIATION_TICKS(); // outside expectRevert's next-call scope
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(1, dev);
    }

    function _runOneSided(bytes32 pid, int24 push, bool doRebalance) internal returns (uint256) {
        _swapTo(push);
        if (doRebalance) {
            int24 hi = (push / 60) * 60 - 60;
            vm.prank(rebalancer);
            hook.rebalance(pid, -600, hi, 0);
        }
        _swapTo(FAIR);
        return _withdrawValue(pid);
    }

    function _lossOneSided(bytes32 pid, int24 push) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        uint256 control = _runOneSided(pid, push, false);
        vm.revertToState(snap);
        uint256 attacked = _runOneSided(pid, push, true);
        vm.revertToState(snap);
        emit log_named_uint("  control value (token1 @ fair)", control);
        emit log_named_uint("  attacked value (token1 @ fair)", attacked);
        return control > attacked ? (control - attacked) * 10_000 / control : 0;
    }

    /// Frozen reference vs default guard, same position, same malicious range
    /// choice. The only difference is one instant owner call.
    function test_TL1_frozen_reference_one_sided_loss() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 3000, 1e18);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too

        // Even with the freeze queued and executed after the warning period, a
        // reference creeping one tick a block behind a moved market is clamped on
        // every write, so it never settles and the stale-window push is refused.
        bytes memory freeze = abi.encodeCall(hook.setPriceGuard, (int24(1), hook.MAX_DEVIATION_TICKS()));
        hook.queueChange(freeze);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        hook.executeChange(freeze);
        _drift(20);
        int24 push = _refTick() + hook.maxDeviationTicks() - 10;
        _swapTo(push);
        int24 hi = (push / 60) * 60 - 60;
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, -600, hi, 0);
    }

    function test_X1_one_sided_range_at_default_bound_exceeds_tolerance() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 3000, 1e18);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _drift(20);
        // Was 117 bps. The guard now values the position at the reference, so
        // the one-sided placement at the pushed price is counted and refused.
        int24 push = FAIR - hook.maxDeviationTicks() + 10;
        _swapTo(push);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.ValueLossExceeded.selector);
        hook.rebalance(pid, -600, (push / 60) * 60 - 60, 0);
    }

    function test_TL1_control_default_guard_refuses_same_push() public {
        _deepPool();
        bytes32 pid = _deposit(-600, 600, 1e18);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too

        _drift(20);
        int24 ref = _refTick();
        emit log_named_int("reference tick after drift (default guard)", ref);
        assertEq(ref, FAIR);

        _swapTo(200);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
        hook.rebalance(pid, 120, 240, 0);
    }

    // ------------------------------------- TL-2: calldata malleability / cancel

    /// Trailing bytes are no longer a second encoding: the exact ABI length is
    /// required, so the variant cannot even be queued.
    function test_TL2_trailing_bytes_variant_survives_cancel() public {
        bytes memory canonical = abi.encodeCall(hook.setMaxRebalanceLossBps, (500));
        bytes memory variant = bytes.concat(canonical, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(AutopilotHook.NotTimelockable.selector, hook.setMaxRebalanceLossBps.selector)
        );
        hook.queueChange(variant);

        hook.queueChange(canonical);
        hook.cancelChange(hook.setMaxRebalanceLossBps.selector);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(canonical);
        assertEq(hook.maxRebalanceLossBps(), 100, "cancelled change must not take effect");
    }

    /// One pending change per setter, and queuing replaces it with a fresh eta:
    /// there is never a matured change that has not just waited out the delay.
    function test_TL2_change_can_be_kept_armed_indefinitely() public {
        bytes memory c = abi.encodeCall(hook.setRebalancer, (attacker, true));
        for (uint256 i; i < 10; i++) {
            hook.queueChange(c);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            // Each re-queue restarts the wait; it is never ready early.
            vm.expectPartialRevert(AutopilotHook.ChangeNotReady.selector);
            hook.executeChange(c);
        }
        (, uint64 eta,) = hook.pendingChange(hook.changeKey(c));
        assertEq(eta, vm.getBlockTimestamp() - 1 days + hook.TIMELOCK_DELAY(), "only the latest queue counts");
        assertFalse(hook.isRebalancer(attacker));
    }

    /// An instant change voids the pending change for the same setter, so a
    /// "no-op" queued beforehand cannot later restore the looser value.
    function test_TL3_noop_queued_becomes_loosening_after_tightening() public {
        bytes memory noop = abi.encodeCall(hook.setMaxRebalanceLossBps, (100)); // == current
        hook.queueChange(noop);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());

        hook.setMaxRebalanceLossBps(25);
        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(noop);
        assertEq(hook.maxRebalanceLossBps(), 25);
    }

    /// Re-queuing resets the eta; it never shortens it.
    function test_TL3_requeue_resets_eta() public {
        bytes memory c = abi.encodeCall(hook.setMaxSwapImpactBps, (1000));
        hook.queueChange(c);
        (, uint64 eta1,) = hook.pendingChange(hook.setMaxSwapImpactBps.selector);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        hook.queueChange(c);
        (, uint64 eta2,) = hook.pendingChange(hook.setMaxSwapImpactBps.selector);
        assertEq(eta2, eta1 + 1 days);
    }

    /// A transfer voids everything the previous owner queued.
    function test_TL4_queue_survives_ownership_transfer() public {
        bytes memory c = abi.encodeCall(hook.setRebalancer, (attacker, true));
        hook.queueChange(c);
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();

        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.prank(newOwner);
        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(c);
        assertFalse(hook.isRebalancer(attacker));

        // The new owner can queue it afresh, with a fresh warning period.
        vm.prank(newOwner);
        hook.queueChange(c);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.prank(newOwner);
        hook.executeChange(c);
        assertTrue(hook.isRebalancer(attacker));
    }

    // ----------------------------------------------- TL-5: one-way emergency lever

    /// An instant tightening (accidental or emergency) cannot be undone for 2 days.
    function test_TL5_tightening_cannot_be_reverted_without_delay() public {
        hook.setMinRebalanceInterval(hook.MAX_REBALANCE_INTERVAL());
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMinRebalanceInterval(COOLDOWN);
        hook.setPriceGuard(500, 1);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(500, 200);
    }

    // --------------------------------------------------------- verified correct

    function test_VC_mixed_priceguard_raise_one_lower_other_needs_queue() public {
        hook.setPriceGuard(500, 100);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(500, 150);
        // Either direction of the per-block cap waits (TL-1).
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(100, 100);
        hook.setRebalancer(rebalancer, false);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setRebalancer(rebalancer, true);
    }

    function test_VC_direct_self_flag_unreachable() public {
        // Outside executeChange, a call as the hook itself still needs the owner.
        vm.prank(address(hook));
        vm.expectRevert();
        hook.setMaxRebalanceLossBps(50);
    }

    function test_VC_flag_reset_after_failed_execution() public {
        bytes memory bad = abi.encodeCall(hook.setMaxRebalanceLossBps, (5000));
        hook.queueChange(bad);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.expectRevert(AutopilotHook.LossToleranceTooHigh.selector);
        hook.executeChange(bad);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMaxRebalanceLossBps(500);
        // and the entry is still queued (the delete was rolled back)
        (, uint64 eta,) = hook.pendingChange(hook.setMaxRebalanceLossBps.selector);
        assertGt(eta, 0);
    }

    function test_VC_withdraw_ungated_by_instant_levers() public {
        bytes32 pid = _deposit(-600, 600, 1e18);
        hook.pause();
        hook.setAllowlistEnforced(true);
        hook.setMinRebalanceInterval(hook.MAX_REBALANCE_INTERVAL());
        hook.setPriceGuard(500, 1);
        hook.setMaxSwapImpactBps(1);
        hook.setMaxRebalanceLossBps(25);
        hook.setRebalancer(rebalancer, false);
        hook.withdraw(pid);
    }
}

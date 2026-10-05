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

/// Full-audit liveness PoCs (LV-*). Test-only.
contract LivenessPoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
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
    }

    // ------------------------------------------------------------------ helpers

    function _depositB(int24 lo, int24 hi, uint128 liq, int24 minB, int24 maxB) internal returns (bytes32) {
        return
            hook.deposit(
                key, lo, hi, liq, minB, maxB, address(0), type(uint256).max, type(uint256).max, type(uint256).max
            );
    }

    function _deposit(int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        return _depositB(lo, hi, liq, TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
    }

    function _lp(int24 lo, int24 hi, int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: delta, salt: salt}), ""
        );
    }

    function _swapTo(bool zeroForOne, int256 amountIn, int24 limitTick) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            ts,
            ""
        );
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 2);
    }

    function _settle() internal {
        for (uint256 i; i < 10; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        _nextBlock();
    }

    function _spot() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    /// DS-1b state: a hook-only pool whose single position was traded through and
    /// now sits out of range, holding token0 only. No liquidity is active at spot.
    function _hookOnlyOutOfRange() internal returns (bytes32 pid) {
        pid = _deposit(-600, 600, 1e18);
        _swapTo(true, 1e30, -900);
        assertEq(_spot(), -900);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
        _settle();
    }

    // ------------------------------------------------------------------ LV-1

    /// The DS-1 fix narrows a straddling target to the held token's side only
    /// when the straddle computes to *zero* liquidity. One dust LP position in
    /// the swap's path makes the re-ratio swap return a few wei of the other
    /// token, the straddle computes to a few hundred thousand units of liquidity,
    /// the fallback is skipped, and ~100% of the position is parked idle.
    function test_LV1_dust_depth_defeats_one_sided_fallback() public {
        bytes32 pid = _hookOnlyOutOfRange();
        int24 lower = -1500;
        int24 upper = -300; // straddles spot -900

        // Control (the DS-1 fix): placed one-sided, nothing material idle.
        uint256 snap = vm.snapshotState();
        vm.prank(rebalancer);
        uint128 ctrl = hook.rebalance(pid, lower, upper, 0);
        (uint128 ci0, uint128 ci1) = hook.idle(pid);
        console2.log("control: placed liquidity", ctrl);
        console2.log("control: idle0", ci0);
        console2.log("control: idle1", ci1);
        vm.revertToState(snap);

        // Attacker: one dust LP position covering the band below spot.
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        uint256 g0 = gasleft();
        _lp(-60000, 60000, 1e6, bytes32(uint256(0xD057)));
        console2.log("attacker dust LP gas", g0 - gasleft());
        console2.log("attacker dust token0 (wei)", b0 - t0.balanceOf(address(this)));
        console2.log("attacker dust token1 (wei)", b1 - t1.balanceOf(address(this)));

        vm.prank(rebalancer);
        uint128 placed = hook.rebalance(pid, lower, upper, 0);
        (uint128 i0, uint128 i1) = hook.idle(pid);
        (,, int24 lo, int24 hi,,,) = hook.positions(pid);
        console2.log("attack: placed liquidity", placed);
        console2.log("attack: idle0", i0);
        console2.log("attack: idle1", i1);

        // Fixed (AM2-2 / LV-1): the one-sided placement deploys more value than the
        // dust straddle, so it is taken.
        assertGt(ctrl, 1e17, "control places the position");
        assertGt(placed * 2, ctrl, "dust in the path no longer defeats the fallback");
        assertLt(i0, ctrl / 1e3, "nothing material idle");
        assertGt(lo, lower, "placed on the held side of spot");
        assertEq(hi, upper);

        // The daemon's idle redeploy (same range) hits the same wall.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
        _settle();
        vm.prank(rebalancer);
        uint128 again = hook.rebalance(pid, lower, upper, 0);
        (uint128 j0,) = hook.idle(pid);
        console2.log("redeploy: placed liquidity", again);
        console2.log("redeploy: idle0", j0);
        again;
    }

    // ------------------------------------------------------------------ LV-2

    /// With no liquidity active at spot (the DS-1b state), moving spot costs gas
    /// only. Ending every block more than maxTickMovePerBlock from the anchor
    /// keeps `stable` at 0, so every rebalance of the position is refused
    /// `PriceUnsettled` for as long as the attacker keeps swapping.
    function test_LV2_free_swaps_hold_price_unsettled_forever() public {
        bytes32 pid = _hookOnlyOutOfRange();
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        uint256 refusals;
        uint256 gasSpent;
        // The attacker starts while the position is still in its cooldown (or
        // any time before the daemon's attempt): one free swap, last in a block.
        _swapTo(true, 1e18, -1700);
        for (uint256 i; i < 100; i++) {
            _nextBlock();
            // The daemon tries (and would poke on PriceUnsettled).
            vm.prank(rebalancer);
            try hook.rebalance(pid, -1500, -300, 0) {
                revert("rebalance went through");
            } catch (bytes memory err) {
                assertEq(bytes4(err), AutopilotHook.PriceUnsettled.selector);
                refusals++;
            }
            hook.pokePriceRef(key);
            // Attacker: last swap of the block, alternating across an empty band.
            uint256 g = gasleft();
            if (i % 2 == 0) _swapTo(false, 1e18, -700);
            else _swapTo(true, 1e18, -1700);
            gasSpent += g - gasleft();
        }
        console2.log("blocks refused PriceUnsettled", refusals);
        console2.log("attacker token0 spent", b0 - t0.balanceOf(address(this)));
        console2.log("attacker token1 spent", b1 - t1.balanceOf(address(this)));
        console2.log("attacker gas per block", gasSpent / 100);
        assertEq(refusals, 100);
        assertEq(t0.balanceOf(address(this)), b0, "no tokens spent");
        assertEq(t1.balanceOf(address(this)), b1, "no tokens spent");
    }

    // ------------------------------------------------------------------ LV-3

    /// `OutOfBounds` depends on the requested range and the price, not on any
    /// setting an owner can change (bounds are fixed at deposit; no setter). The
    /// daemon does not know the bounds, proposes a range centred on spot, and
    /// classifies the refusal as Terminal (6 h suppression). The same position
    /// accepts a range clipped to its bounds at the same price, and the centred
    /// range once price moves back.
    function test_LV3_outOfBounds_is_transient_and_price_dependent() public {
        _lp(-60000, 60000, 1e21, bytes32(0)); // depth so swaps behave
        bytes32 pid = _depositB(-120, 120, 1e18, -1200, 1200);
        _swapTo(false, 1e30, 1000); // honest drift to tick 1000: position out of range
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
        _settle();

        // Daemon-style range centred on spot: [780, 1260] crosses maxBound 1200.
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.OutOfBounds.selector);
        hook.rebalance(pid, 780, 1260, 0);

        // Clipped to the bounds at the same price: accepted.
        uint256 snap = vm.snapshotState();
        vm.prank(rebalancer);
        assertGt(hook.rebalance(pid, 780, 1200, 0), 0);
        vm.revertToState(snap);

        // Ten minutes later price is back mid-bounds; the centred range is fine.
        _swapTo(true, 1e30, 0);
        vm.warp(vm.getBlockTimestamp() + 600);
        _settle();
        vm.prank(rebalancer);
        assertGt(hook.rebalance(pid, -240, 240, 0), 0, "valid 10 min later; daemon waits 6 h");
    }
}

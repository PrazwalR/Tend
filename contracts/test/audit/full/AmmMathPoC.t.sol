// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {AutopilotHook} from "../../../src/AutopilotHook.sol";

/// Full audit 2026-10-03, AMM mechanics / precision-math domain (AM2).
/// Roles: `victim` owns the autopilot position, `lp` the background depth, this
/// contract is the attacker / third-party swapper.
contract AmmMathPoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    address victim = address(0x71C7);
    address lp = address(0x1111);
    uint64 constant COOLDOWN = 3600;

    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        t0 = MockERC20(Currency.unwrap(currency0));
        t1 = MockERC20(Currency.unwrap(currency1));

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? victim : lp;
            t0.mint(who, 1e40);
            t1.mint(who, 1e40);
            vm.startPrank(who);
            t0.approve(address(hook), type(uint256).max);
            t1.approve(address(hook), type(uint256).max);
            t0.approve(address(modifyLiquidityRouter), type(uint256).max);
            t1.approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    function _usePool(int24 spacing, uint160 sqrtP) internal {
        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, spacing, sqrtP);
    }

    function _depth(int24 lo, int24 hi, uint256 liq) internal {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(liq), salt: 0}), ""
        );
    }

    function _victimDeposit(int24 lo, int24 hi, uint128 liq) internal returns (bytes32 pid) {
        int24 s = key.tickSpacing;
        vm.prank(victim);
        pid = hook.deposit(
            key,
            lo,
            hi,
            liq,
            TickMath.minUsableTick(s),
            TickMath.maxUsableTick(s),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
    }

    function _swapTo(int24 target) internal {
        (, int24 now_,,) = manager.getSlot0(id);
        if (now_ == target) return;
        bool down = target < now_;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: down, amountSpecified: -1e36, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _ready() internal {
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
        _nextBlock();
    }

    /// Poke the reference up to spot and let it settle for MIN_STABLE_BLOCKS.
    function _catchUpRef() internal {
        for (uint256 i; i < 25; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        _nextBlock();
    }

    function _spot() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _floorTo(int24 t, int24 s) internal pure returns (int24) {
        int24 r = (t / s) * s;
        return (t < 0 && r != t) ? r - s : r;
    }

    function _ceilTo(int24 t, int24 s) internal pure returns (int24) {
        int24 r = (t / s) * s;
        return (t > 0 && r != t) ? r + s : r;
    }

    /// The daemon's narrowest pick: one spacing either side of the observed tick.
    function _daemonRange(int24 t) internal view returns (int24 lo, int24 hi) {
        int24 s = key.tickSpacing;
        lo = _floorTo(t - s, s);
        hi = _ceilTo(t + s, s);
    }

    function _d(uint256 b, uint256 a) internal pure returns (int256) {
        return b >= a ? int256(b - a) : -int256(a - b);
    }

    function _bal(address who) internal view returns (uint256) {
        return t0.balanceOf(who) + t1.balanceOf(who); // value at price 1 (tick 0)
    }

    // =====================================================================
    // AM2-1. PR-1 fix bypass: a push no larger than maxTickMovePerBlock moves
    // the reference without ever being clamped, so the stability counter keeps
    // counting and the 200-tick window opens around the dragged reference after
    // ONE held block end — the exact PR-1 shape (700 ticks), just split 500+200.
    // =====================================================================

    struct Out {
        uint256 victimOut;
        int256 attackerPnl;
    }

    /// holds = number of 500-tick held block ends before the rebalance block.
    function _attack(bytes32 pid, uint256 holds, int24 extra, bool doRebalance) internal returns (Out memory o) {
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));
        int24 step = hook.maxTickMovePerBlock();
        for (uint256 i; i < holds; i++) {
            _swapTo(step * int24(int256(i + 1))); // last swap of block N+i: exactly one step
            _nextBlock();
        }
        // Rebalance block: push the remaining deviation window, the daemon then
        // centres on what it sees.
        _swapTo(step * int24(int256(holds)) + extra);
        if (doRebalance) {
            (int24 lo, int24 hi) = _daemonRange(_spot());
            vm.prank(rebalancer);
            hook.rebalance(pid, lo, hi, 0);
        }
        _swapTo(0); // back-run to fair
        uint256 v = _bal(victim);
        vm.prank(victim);
        hook.withdraw(pid);
        o.victimOut = _bal(victim) - v;
        o.attackerPnl = _d(t0.balanceOf(address(this)), a0) + _d(t1.balanceOf(address(this)), a1);
    }

    function _pr1Setup(int24 half) internal returns (bytes32 pid) {
        _usePool(60, SQRT_PRICE_1_1);
        _depth(-60000, 60000, 1e21);
        pid = _victimDeposit(-half, half, 1e18);
        _ready();
    }

    function _pr1Bypass(bytes32 pid, uint256 holds, int24 extra) internal returns (uint256 lossBps, int256 gain) {
        uint256 snap = vm.snapshotState();
        Out memory ctl = _attack(pid, holds, extra, false);
        vm.revertToState(snap);
        Out memory atk = _attack(pid, holds, extra, true); // does NOT revert
        lossBps = (ctl.victimOut - atk.victimOut) * 10_000 / ctl.victimOut;
        gain = atk.attackerPnl - ctl.attackerPnl;
        emit log_named_uint("holds (500-tick block ends)", holds);
        emit log_named_int("total push at rebalance (ticks)", int24(int256(holds)) * 500 + extra);
        emit log_named_uint("victim value, no rebalance (wei)", ctl.victimOut);
        emit log_named_uint("victim value, attacked rebalance (wei)", atk.victimOut);
        emit log_named_uint("victim loss (bps)", lossBps);
        emit log_named_int("attacker gain vs control (wei)", gain);
        emit log_named_int("attacker absolute P&L incl. fees paid (wei)", atk.attackerPnl);
    }

    function test_AM2_1_pr1_bypass_one_held_boundary_at_the_cap() public {
        // Control from the regression suite: 700 in one block end is refused.
        bytes32 pid = _pr1Setup(420);
        uint256 snap = vm.snapshotState();
        _swapTo(700);
        _nextBlock();
        (int24 lo, int24 hi) = _daemonRange(_spot());
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, lo, hi, 0);
        vm.revertToState(snap);

        // A push of exactly one step (500), held one block end, is never clamped:
        // the stability count keeps running and the reference lands on the push.
        // The position is out of range at 500, so the daemon proposes a recentre.
        // Fixed (OR-1): the step left the run's band, so it restarts.
        _swapTo(500);
        _nextBlock();
        (lo, hi) = _daemonRange(_spot());
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, lo, hi, 0);
    }

    /// Exploration: which extra same-block push on top of the dragged reference
    /// still passes the guard (logged; reverts are caught).
    function test_AM2_1_explore() public {
        bytes32 pid = _pr1Setup(600);
        int24[4] memory ex = [int24(0), 60, 120, 200];
        for (uint256 h = 1; h <= 2; h++) {
            for (uint256 i; i < 4; i++) {
                uint256 snap = vm.snapshotState();
                try this.runBypass(pid, h, ex[i]) {}
                catch {
                    emit log_string("  -> refused");
                }
                vm.revertToState(snap);
            }
        }
    }

    function runBypass(bytes32 pid, uint256 h, int24 extra) external {
        require(msg.sender == address(this));
        _pr1Bypass(pid, h, extra);
    }

    function test_AM2_1_pr1_bypass_two_held_boundaries() public {
        bytes32 pid = _pr1Setup(600);
        _swapTo(500);
        _nextBlock();
        _swapTo(1000);
        _nextBlock();
        (int24 lo, int24 hi) = _daemonRange(_spot());
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, lo, hi, 0);
    }

    // =====================================================================
    // AM2-2. DS-1 one-sided fallback is skipped whenever the "other" token is
    // non-zero by any amount (e.g. fees earned while the position was in range):
    // `getLiquidityForAmounts` then returns min(L0, L1) > 0 from the dust, the
    // early return fires, and almost the whole position is parked idle.
    // =====================================================================

    function _ds1Scenario(bool earnToken1Fees) internal returns (uint128 placed, uint256 idle0, uint256 total0) {
        _usePool(60, SQRT_PRICE_1_1);
        bytes32 pid = _victimDeposit(-600, 600, 1e18); // hook-only pool
        if (earnToken1Fees) {
            // One small oneForZero trade while in range: the position earns a few
            // token1 in fees. Then price returns.
            _swapTo(30);
        }
        _swapTo(-900); // drifts out of range below: principal is all token0
        _ready();
        _catchUpRef();

        vm.prank(rebalancer);
        placed = hook.rebalance(pid, -1500, -300, 0); // straddling target
        (uint128 h0,) = hook.idle(pid);
        idle0 = h0;
        (,, int24 lo, int24 hi, uint128 liq,,) = hook.positions(pid);
        (uint160 sp,,,) = manager.getSlot0(id);
        // token0 actually deployed in the new range
        uint256 dep0 = lo > _spot()
            ? _amt0(TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq)
            : _amt0(sp, TickMath.getSqrtPriceAtTick(hi), liq);
        total0 = dep0 + idle0;
        emit log_named_int("placed lower", lo);
        emit log_named_int("placed upper", hi);
        emit log_named_uint("placed liquidity", liq);
        emit log_named_uint("token0 deployed", dep0);
        emit log_named_uint("token0 idle", idle0);
        emit log_named_uint("idle share of token0 (bps)", idle0 * 10_000 / total0);
    }

    function _amt0(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        return uint256(l) * (b - a) / b * (1 << 96) / a;
    }

    function test_AM2_2_fallback_defeated_by_token1_fee_dust() public {
        uint256 snap = vm.snapshotState();
        (uint128 cleanLiq, uint256 cleanIdle, uint256 cleanTot) = _ds1Scenario(false);
        assertLt(cleanIdle * 10_000 / cleanTot, 100, "control: fallback deploys ~all token0");
        vm.revertToState(snap);

        (uint128 dustLiq, uint256 dustIdle, uint256 dustTot) = _ds1Scenario(true);
        emit log_named_uint("liquidity, no token1 fees", cleanLiq);
        emit log_named_uint("liquidity, with token1 fee dust", dustLiq);
        // Fixed: the fallback is taken whenever it puts more value to work, so
        // fee dust no longer parks the position (was 9998 bps idle).
        assertLt(dustIdle * 10_000 / dustTot, 100, "with fee dust the position is still deployed");
        assertGt(dustLiq * 2, cleanLiq, "placed liquidity comparable to the clean case");
    }

    // =====================================================================
    // Fuzz: settlement / accounting across spacings, depths, ranges, prices,
    // including the one-sided fallback. Only the hook's documented refusals may
    // revert; never CurrencyNotSettled, a panic, or a v4 tick error.
    // =====================================================================

    function testFuzz_AM2_rebalance_settles_or_refuses_cleanly(uint256 seed) public {
        _settleCase(seed);
    }

    /// Coverage tally for the fuzz body: how many cases succeeded, took the
    /// one-sided fallback, or were refused.
    function test_AM2_settle_coverage() public {
        uint256[4] memory n; // ok, narrowed, refused, skipped
        for (uint256 i; i < 120; i++) {
            uint256 snap = vm.snapshotState();
            uint256 seed = uint256(keccak256(abi.encode(i)));
            try this.settleCaseExt(seed) returns (uint8 r) {
                n[r]++;
            } catch {
                revert("unexpected");
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("ok", n[0]);
        emit log_named_uint("ok via one-sided fallback (narrowed)", n[1]);
        emit log_named_uint("refused (documented selectors)", n[2]);
        emit log_named_uint("skipped", n[3]);
        assertGt(n[0] + n[1], 40);
        assertGt(n[1], 0);
    }

    function settleCaseExt(uint256 seed) external returns (uint8) {
        require(msg.sender == address(this));
        return _settleCase(seed);
    }

    function _settleCase(uint256 seed) internal returns (uint8 outcome) {
        int24[4] memory sps = [int24(1), 10, 60, 200];
        int24 s = sps[seed % 4];
        _usePool(s, SQRT_PRICE_1_1);
        uint256 dsel = (seed >> 4) % 4;
        if (dsel == 1) _depth(_floorTo(-60000, s), _floorTo(60000, s), 1e15);
        if (dsel == 2) _depth(_floorTo(-60000, s), _floorTo(60000, s), 1e18);
        if (dsel == 3) _depth(_floorTo(-60000, s), _floorTo(60000, s), 1e21);

        int24 oLo = int24(int256((seed >> 8) % 40)) * s - 20 * s;
        int24 oHi = oLo + int24(int256((seed >> 16) % 30 + 1)) * s;
        uint128 liq = uint128(10 ** ((seed >> 24) % 22 + 1)); // 10 .. 1e22
        bytes32 pid = _victimDeposit(oLo, oHi, liq);

        int24 move = int24(int256((seed >> 32) % 4001)) - 2000;
        _swapTo(move);
        _ready();
        _catchUpRef();

        int24 c = _floorTo(_spot(), s);
        int24 nLo = c - int24(int256((seed >> 48) % 25)) * s;
        int24 nHi = c + int24(int256((seed >> 56) % 25 + 1)) * s;
        if ((seed >> 64) % 3 == 0) {
            // one-sided targets on either side
            if ((seed >> 66) % 2 == 0) (nLo, nHi) = (c + s, c + s * int24(int256((seed >> 70) % 10 + 2)));
            else (nLo, nHi) = (c - s * int24(int256((seed >> 70) % 10 + 2)), c - s);
        }
        if (nLo == oLo && nHi == oHi) return 3;

        uint256 c0Before = manager.balanceOf(address(hook), currency0.toId());
        uint256 c1Before = manager.balanceOf(address(hook), currency1.toId());
        vm.prank(rebalancer);
        try hook.rebalance(pid, nLo, nHi, 0) returns (uint128 placed) {
            (,, int24 lo, int24 hi, uint128 l,,) = hook.positions(pid);
            assertEq(l, placed);
            assertGe(lo, nLo, "placed within request");
            assertLe(hi, nHi, "placed within request");
            assertLt(lo, hi, "valid range");
            assertEq(lo % s, 0);
            assertEq(hi % s, 0);
            (uint128 i0, uint128 i1) = hook.idle(pid);
            assertEq(manager.balanceOf(address(hook), currency0.toId()) - c0Before, i0, "claims back idle0");
            assertEq(manager.balanceOf(address(hook), currency1.toId()) - c1Before, i1, "claims back idle1");
            outcome = (lo != nLo || hi != nHi) ? 1 : 0;
            // and it can always exit
            vm.prank(victim);
            hook.withdraw(pid);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == AutopilotHook.ZeroLiquidity.selector || sel == AutopilotHook.ValueLossExceeded.selector
                    || sel == AutopilotHook.NothingFreed.selector,
                "unexpected revert"
            );
            outcome = 2;
        }
    }

    /// Extreme prices: pools initialised near MIN/MAX tick, spacing 1, with the
    /// hook's own liquidity only and with depth. No overflow in `_inToken1`,
    /// `_inToken0`, `_amountsAt`, or the impact-limit arithmetic.
    function testFuzz_AM2_extreme_prices(uint256 seed) public {
        _extremeCase(seed);
    }

    function extremeCaseExt(uint256 seed) external returns (bool) {
        require(msg.sender == address(this));
        return _extremeCase(seed);
    }

    function test_AM2_extreme_coverage() public {
        uint256 ok;
        for (uint256 i; i < 60; i++) {
            uint256 snap = vm.snapshotState();
            if (this.extremeCaseExt(uint256(keccak256(abi.encode("x", i))))) ok++;
            vm.revertToState(snap);
        }
        emit log_named_uint("extreme-price rebalances that succeeded (of 60)", ok);
        assertGt(ok, 15);
    }

    function _extremeCase(uint256 seed) internal returns (bool ok) {
        bool high = seed % 2 == 0;
        int24 base = high ? TickMath.MAX_TICK - 3000 : TickMath.MIN_TICK + 3000;
        base += int24(int256((seed >> 8) % 2000)) - 1000;
        _usePool(1, TickMath.getSqrtPriceAtTick(base));
        if ((seed >> 20) % 2 == 0) _depth(base - 2000, base + 2000, 1e17);
        int24 oLo = base - int24(int256((seed >> 24) % 500 + 1));
        int24 oHi = base + int24(int256((seed >> 32) % 500 + 1));
        bytes32 pid = _victimDeposit(oLo, oHi, uint128(10 ** ((seed >> 40) % 8 + 10)));
        _swapTo(base + int24(int256((seed >> 48) % 1200)) - 600);
        _ready();
        _catchUpRef();
        int24 c = _spot();
        int24 nLo = c - int24(int256((seed >> 56) % 300 + 1));
        int24 nHi = c + int24(int256((seed >> 64) % 300 + 1));
        if (nHi > TickMath.MAX_TICK) nHi = TickMath.MAX_TICK;
        if (nLo < TickMath.MIN_TICK) nLo = TickMath.MIN_TICK;
        vm.prank(rebalancer);
        try hook.rebalance(pid, nLo, nHi, 0) {
            ok = true;
            vm.prank(victim);
            hook.withdraw(pid);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == AutopilotHook.ZeroLiquidity.selector || sel == AutopilotHook.ValueLossExceeded.selector
                    || sel == AutopilotHook.NothingFreed.selector,
                "unexpected revert at extreme price"
            );
            emit log_named_bytes32(high ? "refused (high price)" : "refused (low price)", bytes32(sel));
        }
    }

    // =====================================================================
    // AM2-3 (Info). `_swapPriceLimit`'s upward impact bound is computed as
    // uint160(spot * (BPS + bps) / BPS); near MAX_SQRT_PRICE the product
    // exceeds 2^160 and the cast wraps to a value below spot, so the swap is
    // silently skipped. Reproduces the expression.
    // =====================================================================
    function test_AM2_3_impactUp_wraps_near_max_price() public pure {
        uint256 bps = 50;
        uint160 spot = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 50);
        uint160 impactUp = uint160((uint256(spot) * (10_000 + bps)) / 10_000);
        assertLt(impactUp, spot, "wrapped below spot: oneForZero leg skipped");
        spot = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 150);
        impactUp = uint160((uint256(spot) * (10_000 + bps)) / 10_000);
        assertGt(impactUp, spot, "fine further from the edge");
    }

    // =====================================================================
    // AM2-4 (Info). Below sqrtPrice 2^48 (tick ~ -665,000) LiquidityAmounts'
    // intermediate mulDiv(sqrtA, sqrtB, Q96) floors to 0, so any token0-funded
    // range computes zero liquidity in `_placeableLiquidity` (incl. fallback).
    // =====================================================================
    function test_AM2_4_liquidity_for_amount0_zero_at_extreme_low_price() public pure {
        uint160 a = TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 3000);
        uint160 b = TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 3300);
        assertEq(LiquidityAmounts.getLiquidityForAmount0(a, b, 1e38), 0, "1e38 token0 funds no liquidity");
    }
}

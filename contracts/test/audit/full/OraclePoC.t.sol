// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PriceRefPoC} from "../PriceRefPoC.t.sol";
import {AutopilotHook} from "../../../src/AutopilotHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// Full audit 2026-10-03, oracle / manipulation-resistance domain.
/// Reuses the PriceRefPoC harness (victim / lp / attacker roles, control runs).
contract OraclePoC is PriceRefPoC {
    // ----------------------------------------------------------- OR-1 harness

    /// Attacker walks spot through `steps`, one step per block end, each step no
    /// further than `maxTickMovePerBlock` from the last. The reference follows
    /// every step unclamped, so `stable` never resets. The rebalance lands in the
    /// block after the last step (the daemon centres on the spot it sees at
    /// `latest`), optionally after a same-block front-run of `extra` ticks.
    function _runSteps(bytes32 pid, int24[] memory steps, int24 extra, bool doRebalance)
        internal
        returns (uint256 victimOut, int256 attackerPnl)
    {
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));
        for (uint256 i; i < steps.length; i++) {
            if (i > 0) _nextBlock();
            _swapTo(steps[i]);
        }
        _nextBlock();
        if (extra != 0) _swapTo(steps[steps.length - 1] + extra);
        if (doRebalance) {
            (int24 lo, int24 hi) = _daemonRange(_spot());
            vm.prank(rebalancer);
            hook.rebalance(pid, lo, hi, 0);
        }
        _swapTo(0);
        uint256 v0 = t0.balanceOf(victim);
        uint256 v1 = t1.balanceOf(victim);
        vm.prank(victim);
        hook.withdraw(pid);
        victimOut = (t0.balanceOf(victim) - v0) + (t1.balanceOf(victim) - v1);
        attackerPnl = _d(t0.balanceOf(address(this)), a0) + _d(t1.balanceOf(address(this)), a1);
    }

    function stepRun(bytes32 pid, int24[] memory steps, int24 extra) external returns (uint256, int256) {
        require(msg.sender == address(this));
        return _runSteps(pid, steps, extra, true);
    }

    function _measureSteps(bytes32 pid, int24[] memory steps, int24 extra) internal returns (Result memory out) {
        uint256 snap = vm.snapshotState();
        (uint256 control, int256 pnlCtl) = _runSteps(pid, steps, extra, false);
        vm.revertToState(snap);
        out.victimValue = control;
        try this.stepRun(pid, steps, extra) returns (uint256 attacked, int256 pnlAtk) {
            out.lossVsNoReb = control > attacked ? (control - attacked) * 10_000 / control : 0;
            out.attackerGain = pnlAtk - pnlCtl;
            out.attackerAbs = pnlAtk;
        } catch {
            out.refused = true;
        }
        vm.revertToState(snap);
    }

    function _one(int24 a) internal pure returns (int24[] memory s) {
        s = new int24[](1);
        s[0] = a;
    }

    function _two(int24 a, int24 b) internal pure returns (int24[] memory s) {
        s = new int24[](2);
        s[0] = a;
        s[1] = b;
    }

    // ------------------------------------------------------------------ OR-1

    /// PR-1's fix counts block ends that end *unclamped*, not block ends where the
    /// reference stood still. A push of at most `maxTickMovePerBlock` (500) is
    /// never clamped, so it moves the reference 500 ticks in one block end without
    /// touching `stable`. The fix's own regression test only pushes 700 at once
    /// (which clamps). This is the original PR-1.
    function test_OR1_step_at_cap_bypasses_stability() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();

        // Contrast: the fix's own case is still refused.
        Result memory ref700 = _measure(pid, Run(700, 1, true, true, 0, 0, false));
        _log("[fixed case] holds=1 push=700 at once", ref700);
        assertTrue(ref700.refused);

        // (a) One held block end at 500, daemon rebalances at the spot it sees.
        Result memory a = _measureSteps(pid, _one(500), 0);
        _log("(a) one block end at +500, rebalance next block", a);
        // (b) Same, plus a same-block front-run of +200: the value guard (valued
        //     at the anchor, now 500) sees the extra 200 and refuses. The 500 the
        //     reference itself moved is invisible to it.
        Result memory b = _measureSteps(pid, _one(500), 200);
        _log("(b) one block end at +500, front-run to +700", b);
        // (c) Two held block ends, 500 per block: 1000 from fair.
        Result memory c = _measureSteps(pid, _two(500, 1000), 0);
        _log("(c) two block ends 500/1000, rebalance next block", c);

        // Fixed: a new level must be held MIN_STABLE_BLOCKS block ends (OR-1).
        assertTrue(a.refused, "one block end at the cap is refused");
        assertTrue(b.refused, "front-run beyond the anchor is refused");
        assertTrue(c.refused, "two block ends at the cap are refused");
    }

    function test_OR1_step_at_cap_downward() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        Result memory b = _measureSteps(pid, _one(-500), 0);
        _log("one block end at -500, rebalance next block", b);
        assertTrue(b.refused);
    }

    /// Attacker profitability on the fee-500 pool that PR-1 measured +5.5% on.
    function test_OR1_step_at_cap_profit_fee500() public {
        (key, id) = initPool(currency0, currency1, IHooks(hook), 500, 10, SQRT_PRICE_1_1);
        _deepPool(1e19);
        bytes32 pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        Result memory r1 = _measure(pid, Run(700, 1, true, true, 0, 0, false));
        _log("[fixed case] fee500 holds=1 push=700 at once", r1);
        assertTrue(r1.refused);
        Result memory r = _measureSteps(pid, _one(500), 0);
        _log("fee500 s=10 bg=1e19 old[-1200,-600] one block end at +500", r);
        Result memory r2 = _measureSteps(pid, _two(500, 1000), 0);
        _log("fee500 s=10 bg=1e19 old[-1200,-600] two block ends 500/1000", r2);
        assertTrue(r.refused, "the profitable one-step attack is refused");
        assertTrue(r2.refused, "the profitable two-step attack is refused");
    }

    // ------------------------------------------------------------------ OR-2

    /// v4 skips a hook's own callbacks on calls the hook itself makes
    /// (`noSelfCall`), so the re-ratio swap inside a rebalance moves spot without
    /// `afterSwap` writing the reference. "Spot only moves through swaps and every
    /// swap writes" (the premise of `_stableAfter`) is false for these swaps.
    function test_OR2_rebalance_swap_moves_spot_without_ref_write() public {
        _deepPool(2e18);
        bytes32 pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        _swapTo(1);
        _swapTo(0);
        _nextBlock();
        (int24 tBefore,,,,,,) = hook.priceRef(id);
        int24 spotBefore = _spot();
        vm.prank(rebalancer);
        hook.rebalance(pid, -60, 60, 0);
        (int24 tAfter,, uint64 atBlock,, bool clamped, uint8 stable,) = hook.priceRef(id);
        emit log_named_int("spot before rebalance", spotBefore);
        emit log_named_int("spot after rebalance", _spot());
        emit log_named_int("ref.tick before", tBefore);
        emit log_named_int("ref.tick after", tAfter);
        emit log_named_uint("ref.atBlock", atBlock);
        emit log_named_uint("block", vm.getBlockNumber());
        assertTrue(_spot() != spotBefore, "the rebalance swap moved spot");
        assertEq(tAfter, _spot(), "and the reference followed it (OR-2 fix)");
        assertFalse(clamped);
        // Quiet blocks now count as 'ended on spot' though spot is elsewhere.
        vm.roll(vm.getBlockNumber() + 6);
        hook.pokePriceRef(key);
        (,,,,, stable,) = hook.priceRef(id);
        emit log_named_uint("stable after 6 quiet blocks", stable);
    }

    /// State-level view: after a 500-tick step the reference is unclamped and
    /// `stable` still saturated; nothing records that it just moved 500 ticks.
    function test_OR1_state_after_step() public {
        _deepPool(1e21);
        _victimDeposit(-600, 600, 1e18);
        _ready();
        _swapTo(1);
        (,,,,, uint8 s0,) = hook.priceRef(id);
        _nextBlock();
        _swapTo(500 + 1);
        _nextBlock();
        hook.pokePriceRef(key);
        (int24 tick, int24 anchor,,, bool clamped, uint8 stable,) = hook.priceRef(id);
        emit log_named_uint("stable before the step", s0);
        emit log_named_int("anchor after the step", anchor);
        emit log_named_int("tick after the step", tick);
        emit log_named_uint("stable after the step", stable);
        assertEq(anchor, 501);
        assertFalse(clamped);
        // The step left the band of the run's base: the count restarts.
        assertLt(stable, hook.MIN_STABLE_BLOCKS());
    }

    // ------------------------------------------------- OR-1 fix: regressions

    function _steps(int24 step, uint256 n) internal pure returns (int24[] memory s) {
        s = new int24[](n);
        for (uint256 i; i < n; i++) {
            s[i] = step * int24(int256(i + 1));
        }
    }

    function _held(int24 level, uint256 ends) internal pure returns (int24[] memory s) {
        s = new int24[](ends);
        for (uint256 i; i < ends; i++) {
            s[i] = level;
        }
    }

    /// Walking the reference in steps that each stay inside the deviation
    /// window still leaves the run's band, so the count restarts.
    function test_OR1_fix_walk_in_window_sized_steps_is_refused() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        for (uint256 n = 2; n <= 6; n++) {
            Result memory r = _measureSteps(pid, _steps(200, n), 0);
            _log("200-tick steps", r);
            assertTrue(r.refused, "a walk of 200-tick steps is refused");
        }
    }

    /// Alternating directions never let a run reach MIN_STABLE_BLOCKS at a
    /// pushed level either.
    function test_OR1_fix_alternating_steps_refused() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        int24[] memory alt = new int24[](6);
        (alt[0], alt[1], alt[2], alt[3], alt[4], alt[5]) = (500, 100, 500, 100, 500, 500);
        Result memory r = _measureSteps(pid, alt, 0);
        _log("alternating 500/100", r);
        assertTrue(r.refused);
    }

    /// What remains, measured: a pushed level held for MIN_STABLE_BLOCKS block
    /// ends (each exposed to arbitrage, which the harness does not model) is
    /// trusted. Fewer ends are refused.
    function test_OR1_fix_residual_requires_holding_a_level() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        uint256 k = hook.MIN_STABLE_BLOCKS();
        // The step's own block end is the first of the run.
        Result memory shortHold = _measureSteps(pid, _held(500, k - 1), 0);
        _log("level 500 held MIN_STABLE_BLOCKS-1 ends", shortHold);
        assertTrue(shortHold.refused, "one end short of MIN_STABLE_BLOCKS is refused");
        Result memory longHold = _measureSteps(pid, _held(500, k), 0);
        _log("level 500 held MIN_STABLE_BLOCKS ends (residual: a sustained hold)", longHold);
        assertFalse(longHold.refused, "documented residual: a level held MIN_STABLE_BLOCKS ends is trusted");
    }
}

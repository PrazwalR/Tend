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
import {AutopilotHook} from "../../src/AutopilotHook.sol";

/// Audit 2026-10-03, price-reference domain. Roles are separated so every
/// figure is attributable:
///   - `victim`   owns the autopilot position (deposits, withdraws);
///   - `lp`       owns the deep background liquidity (earns the swap fees);
///   - this test  is the attacker (every swap is its own, at its own cost).
/// All values are taken at the fair price (tick 0, price 1), where every
/// scenario ends.
contract PriceRefPoC is Test, Deployers {
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
            t0.mint(who, 1e30);
            t1.mint(who, 1e30);
            vm.startPrank(who);
            t0.approve(address(hook), type(uint256).max);
            t1.approve(address(hook), type(uint256).max);
            t0.approve(address(modifyLiquidityRouter), type(uint256).max);
            t1.approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
        }
        _usePool(60);
    }

    // ------------------------------------------------------------------ helpers

    function _usePool(int24 spacing) internal {
        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, spacing, SQRT_PRICE_1_1);
    }

    function _deepPool(uint256 liq) internal {
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: int256(liq), salt: 0}), ""
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
                zeroForOne: down, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _d(uint256 b, uint256 a) internal pure returns (int256) {
        return b >= a ? int256(b - a) : -int256(a - b);
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

    /// The daemon's narrowest choice (crates/lpa/src/strategy/mod.rs): half-width
    /// = one tick spacing, rounded outward around the tick it observes.
    function _daemonRange(int24 t) internal view returns (int24 lo, int24 hi) {
        int24 s = key.tickSpacing;
        lo = _floorTo(t - s, s);
        hi = _ceilTo(t + s, s);
    }

    function _pos(bytes32 pid)
        internal
        view
        returns (address, PoolKey memory, bool, int24 lo, int24 hi, uint128, bool, uint64)
    {
        (address o, PoolKey memory k, int24 l, int24 h, uint128 liq, bool a, uint64 t) = hook.positions(pid);
        return (o, k, a, l, h, liq, a, t);
    }

    struct Run {
        int24 push; // where the attacker puts spot
        uint256 holds; // block boundaries the displaced price is carried across
        bool rebalance;
        bool daemonRange; // centre on the observed spot (else use lo/hi as given)
        int24 lo;
        int24 hi;
        bool honest; // rebalance at the fair price instead of the pushed one
    }

    /// Returns the victim's withdrawal value and the attacker's net token P&L,
    /// both at the fair price of 1.
    function _run(bytes32 pid, Run memory r) internal returns (uint256 victimOut, int256 attackerPnl) {
        uint256 a0 = t0.balanceOf(address(this));
        uint256 a1 = t1.balanceOf(address(this));

        if (r.honest) {
            int24 sp = key.tickSpacing;
            (int24 lo, int24 hi) =
                r.daemonRange ? _daemonRange(0) : (_floorTo(r.lo - r.push, sp), _floorTo(r.hi - r.push, sp));
            (,,, int24 curLo, int24 curHi,,,) = _pos(pid);
            if (lo != curLo || hi != curHi) {
                vm.prank(rebalancer);
                hook.rebalance(pid, lo, hi, 0);
            }
        } else {
            _swapTo(r.push);
            for (uint256 i; i < r.holds; i++) {
                _nextBlock();
                // Intermediate boundaries: carry the reference one more step. A poke
                // is used for clarity; a dust swap does the same.
                if (i + 1 < r.holds) hook.pokePriceRef(key);
            }
            if (r.rebalance) {
                (int24 lo, int24 hi) = r.daemonRange ? _daemonRange(_spot()) : (r.lo, r.hi);
                vm.prank(rebalancer);
                hook.rebalance(pid, lo, hi, 0);
            }
            _swapTo(0); // attacker's back-run
        }

        uint256 v0 = t0.balanceOf(victim);
        uint256 v1 = t1.balanceOf(victim);
        vm.prank(victim);
        hook.withdraw(pid);
        victimOut = (t0.balanceOf(victim) - v0) + (t1.balanceOf(victim) - v1);
        attackerPnl = _d(t0.balanceOf(address(this)), a0) + _d(t1.balanceOf(address(this)), a1);
    }

    struct Result {
        uint256 lossVsNoReb; // bps, vs same price path without the rebalance (A-9 method)
        uint256 lossVsHonest; // bps, vs the same rebalance done at the fair price
        int256 attackerGain; // attacker P&L (attacked) minus attacker P&L (control)
        int256 attackerAbs; // attacker P&L in the attacked run (swap fees included)
        uint256 victimValue; // victim withdrawal in the control run
        bool refused; // the attacked rebalance reverted
    }

    /// External so the attacked run can be caught when the hook refuses it.
    function attackedRun(bytes32 pid, Run memory r) external returns (uint256, int256) {
        require(msg.sender == address(this));
        return _run(pid, r);
    }

    function honestRun(bytes32 pid, Run memory r) external returns (uint256) {
        require(msg.sender == address(this));
        (uint256 out,) = _run(pid, r);
        return out;
    }

    /// The re-audit fix is judged here: a manipulated rebalance must be refused,
    /// or cost the victim no more than the protocol's loss tolerance.
    function _assertRefusedOrBounded(Result memory r, string memory label) internal view {
        assertTrue(r.refused || r.lossVsNoReb <= hook.maxRebalanceLossBps(), label);
    }

    function _measure(bytes32 pid, Run memory r) internal returns (Result memory out) {
        uint256 snap = vm.snapshotState();
        Run memory ctl = Run(r.push, r.holds, false, r.daemonRange, r.lo, r.hi, false);
        (uint256 control, int256 pnlCtl) = _run(pid, ctl);
        vm.revertToState(snap);

        Run memory hon = Run(r.push, r.holds, true, r.daemonRange, r.lo, r.hi, true);
        uint256 honestOut;
        try this.honestRun(pid, hon) returns (uint256 v) {
            honestOut = v;
        } catch {}
        vm.revertToState(snap);

        out.victimValue = control;
        try this.attackedRun(pid, r) returns (uint256 attacked, int256 pnlAtk) {
            out.lossVsNoReb = control > attacked ? (control - attacked) * 10_000 / control : 0;
            out.lossVsHonest = honestOut > attacked ? (honestOut - attacked) * 10_000 / honestOut : 0;
            out.attackerGain = pnlAtk - pnlCtl;
            out.attackerAbs = pnlAtk;
        } catch {
            out.refused = true;
        }
        vm.revertToState(snap);
    }

    function _log(string memory label, Result memory r) internal {
        emit log_string(label);
        if (r.refused) {
            emit log_string("  REFUSED by the hook");
            return;
        }
        emit log_named_uint("  victim loss vs no-rebalance control (bps)", r.lossVsNoReb);
        emit log_named_uint("  victim loss vs honest rebalance at fair (bps)", r.lossVsHonest);
        emit log_named_int("  attacker gain vs control (wei, at fair)", r.attackerGain);
        emit log_named_int("  attacker absolute P&L incl. fees (wei, at fair)", r.attackerAbs);
        emit log_named_uint("  victim position value (wei, at fair)", r.victimValue);
    }

    function _shape(string memory label, bytes32 pid, Run memory r) internal {
        Result memory res = _measure(pid, r);
        _log(label, res);
        _assertRefusedOrBounded(res, label);
    }

    function _ready() internal {
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _nextBlock();
    }

    // ------------------------------------------------------------------ PR-1

    /// One block boundary moves the reference a full `maxTickMovePerBlock` (500),
    /// and the deviation window then opens around the moved reference, so the
    /// admissible push is 500 * holds + 200, not 200. The 78 bps "worst case"
    /// only covers holds = 0.
    function test_PR1_single_boundary_hold_admits_700_ticks() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();

        // Same block: 690 is refused, as designed.
        uint256 snap = vm.snapshotState();
        _swapTo(690);
        (int24 lo, int24 hi) = _daemonRange(690);
        vm.prank(rebalancer);
        vm.expectRevert();
        hook.rebalance(pid, lo, hi, 0);
        vm.revertToState(snap);

        Result memory r0 = _measure(pid, Run(200, 0, true, true, 0, 0, false));
        _log("holds=0 push=200", r0);
        _assertRefusedOrBounded(r0, "same-block push at the bound");

        // One boundary: last swap of block N leaves spot at 700. Was 519 bps.
        Result memory r1 = _measure(pid, Run(700, 1, true, true, 0, 0, false));
        _log("holds=1 push=700", r1);
        assertTrue(r1.refused, "one held boundary must not move the window");

        Result memory r2 = _measure(pid, Run(1200, 2, true, true, 0, 0, false));
        _log("holds=2 push=1200", r2);
        assertTrue(r2.refused, "two held boundaries must not move the window");
    }

    function test_PR1_single_boundary_hold_downward() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        Result memory r1 = _measure(pid, Run(-700, 1, true, true, 0, 0, false));
        _log("holds=1 push=-700", r1);
        assertTrue(r1.refused);
    }

    /// After one displaced block end the reference is unsettled: a re-push in the
    /// next block is refused. So is an honest rebalance at fair, for
    /// MIN_STABLE_BLOCKS blocks — the price of the fix, recorded as a residual grief.
    function test_PR1_reference_window_after_one_displaced_block_end() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _swapTo(700); // last swap of block N
        _nextBlock();
        _swapTo(0); // arbitrage restores fair at the top of N+1

        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pid, 600, 780, 0);

        // The restore landed one tick past the clamp, so the reference is still
        // clamped and quiet blocks cannot settle it: only a write that reaches
        // spot can. One poke (the daemon pokes on PriceUnsettled) and then
        // MIN_STABLE_BLOCKS quiet blocks settle it.
        _nextBlock();
        hook.pokePriceRef(key);
        vm.roll(vm.getBlockNumber() + hook.MIN_STABLE_BLOCKS() + 1);
        vm.prank(rebalancer);
        hook.rebalance(pid, -60, 60, 0);
    }

    /// What is left: an attacker who holds the pushed price across enough block
    /// ends for the reference to settle there has moved the reference itself, and
    /// every guard measures from it. The fix turns a one-boundary hold into one of
    /// more than MIN_STABLE_BLOCKS boundaries, each exposed to arbitrage, which
    /// this harness does not model. Logged, not asserted.
    function test_PR1_residual_requires_holding_past_stability() public {
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        uint256 k = hook.MIN_STABLE_BLOCKS();
        Result memory shortHold = _measure(pid, Run(700, k, true, true, 0, 0, false));
        _log("holds=MIN_STABLE_BLOCKS push=700", shortHold);
        assertTrue(shortHold.refused, "a hold of exactly MIN_STABLE_BLOCKS is not enough");
        Result memory longHold = _measure(pid, Run(700, k + 2, true, true, 0, 0, false));
        _log("holds=MIN_STABLE_BLOCKS+2 push=700 (residual: needs a sustained hold)", longHold);
    }

    // ------------------------------------------------------------------ PR-2

    /// Same-block (no hold) shapes at exactly the 200-tick bound. Several exceed
    /// the 78 bps quoted as worst case, and some exceed the 1% loss budget.
    function test_PR2_shapes_at_the_bound_spacing60() public {
        _deepPool(1e21);
        bytes32 pid;

        // (a) A-9 baseline: ±600 position, daemon-narrow range, push exactly 200.
        pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(a) s=60 old[-600,600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
        vm.prank(victim);
        hook.withdraw(pid);

        // (b) Old position out of range on the other side (all token1).
        pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        _shape("(b) s=60 old[-1200,-600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
        vm.prank(victim);
        hook.withdraw(pid);

        // (c) Old narrow position that the push walks straight through.
        pid = _victimDeposit(-60, 60, 1e18);
        _ready();
        _shape("(c) s=60 old[-60,60] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
        vm.prank(victim);
        hook.withdraw(pid);

        // (d) Rebalancer picks a range just above the pushed spot (token0 only):
        //     the whole position is converted at the pushed price.
        pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(d) s=60 old[-600,600] push=200 range[240,360]", pid, Run(200, 0, true, false, 240, 360, false));
        vm.prank(victim);
        hook.withdraw(pid);

        // (e) Wide re-centred range.
        pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(e) s=60 old[-600,600] push=200 range[-420,780]", pid, Run(200, 0, true, false, -420, 780, false));
    }

    function test_PR2_shapes_at_the_bound_spacing1() public {
        _usePool(1);
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(f) s=1 old[-600,600] push=200 daemon-narrow [199,201]", pid, Run(200, 0, true, true, 0, 0, false));
        vm.prank(victim);
        hook.withdraw(pid);

        pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        _shape("(g) s=1 old[-1200,-600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
    }

    function test_PR2_shapes_at_the_bound_spacing10_200() public {
        _usePool(10);
        _deepPool(1e21);
        bytes32 pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(h) s=10 old[-600,600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));

        _usePool(200);
        _deepPool(1e21);
        pid = _victimDeposit(-600, 600, 1e18);
        _ready();
        _shape("(i) s=200 old[-600,600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
        vm.prank(victim);
        hook.withdraw(pid);
        pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        _shape("(j) s=200 old[-1200,-600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
    }

    /// Thin book: the victim is most of the in-range liquidity, so the bounded
    /// re-ratio swap adds its own impact (seen by the value guard, up to the 1%
    /// budget) on top of the push (not seen).
    function test_PR2_thin_book_push_plus_impact() public {
        _deepPool(2e18);
        bytes32 pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        _shape("(k) s=60 thin(2e18) old[-1200,-600] push=200 daemon-narrow", pid, Run(200, 0, true, true, 0, 0, false));
    }

    /// Net profitability: same-block (flash-loanable) sandwich at the bound and the
    /// one-boundary hold, on a 5 bps pool where the victim is a meaningful but
    /// minority share of active liquidity. Attacker P&L is absolute: it includes
    /// every fee paid to the background LP and to the victim.
    function test_PR_net_profit_fee500() public {
        (key, id) = initPool(currency0, currency1, IHooks(hook), 500, 10, SQRT_PRICE_1_1);
        _deepPool(1e19);
        bytes32 pid = _victimDeposit(-1200, -600, 1e18);
        _ready();
        Result memory r0 = _measure(pid, Run(200, 0, true, true, 0, 0, false));
        _log("fee500 s=10 bg=1e19 old[-1200,-600] holds=0 push=200", r0);
        Result memory r1 = _measure(pid, Run(700, 1, true, true, 0, 0, false));
        _log("fee500 s=10 bg=1e19 old[-1200,-600] holds=1 push=700", r1);
        _assertRefusedOrBounded(r0, "same-block sandwich at the bound");
        assertTrue(r0.refused || r0.attackerAbs <= 0, "same-block sandwich must not profit");
        assertTrue(r1.refused, "one-boundary hold must be refused");
    }

    /// Mitigation sizing with existing knobs (tightening is instant, no timelock):
    /// the admissible push is move * holds + deviation.
    function test_PR1_mitigation_tighter_guard() public {
        (key, id) = initPool(currency0, currency1, IHooks(hook), 500, 10, SQRT_PRICE_1_1);
        _deepPool(1e19);
        bytes32 pid = _victimDeposit(-1200, -600, 1e18);
        // Lowering the per-block cap is now timelocked (TL-1).
        bytes memory c = abi.encodeCall(hook.setPriceGuard, (int24(50), int24(50)));
        hook.queueChange(c);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        hook.executeChange(c);
        _ready();
        _shape("guard(50,50) holds=1 push=100", pid, Run(100, 1, true, true, 0, 0, false));
        _shape("guard(50,50) holds=0 push=50", pid, Run(50, 0, true, true, 0, 0, false));
    }

    // ------------------------------------------------------------------ PR-3

    /// Same-block grief: front-run the rebalance with a 201-tick push, back-run
    /// to restore. Measures what one refusal costs the attacker.
    function test_PR3_grief_cost_per_refusal() public {
        uint256[3] memory depths = [uint256(1e21), 1e19, 1e18];
        for (uint256 k; k < 3; k++) {
            uint256 snap = vm.snapshotState();
            _deepPool(depths[k]);
            bytes32 pid = _victimDeposit(-600, 600, 1e18);
            _ready();
            uint256 a0 = t0.balanceOf(address(this));
            uint256 a1 = t1.balanceOf(address(this));
            _swapTo(201);
            vm.prank(rebalancer);
            vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
            hook.rebalance(pid, -60, 60, 0);
            _swapTo(0);
            int256 pnl = _d(t0.balanceOf(address(this)), a0) + _d(t1.balanceOf(address(this)), a1);
            emit log_named_uint("background liquidity", depths[k]);
            emit log_named_int("  attacker cost per refused rebalance (wei)", pnl);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ edges

    /// Clamping near MAX_TICK / MIN_TICK: no int24 overflow, reference stays in range.
    function test_edges_reference_near_tick_extremes() public {
        int24 s = 60;
        int24 top = TickMath.maxUsableTick(s);
        (key, id) = initPool(currency0, currency1, IHooks(hook), 500, s, TickMath.getSqrtPriceAtTick(top - 600));
        vm.prank(lp);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: top - 1200, tickUpper: top, liquidityDelta: 1e9, salt: 0}), ""
        );
        _victimDeposit(top - 1200, top, 1e8);
        _nextBlock();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e24, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        for (uint256 i; i < 4; i++) {
            _nextBlock();
            hook.pokePriceRef(key);
        }
        (int24 tick,,,,,,) = hook.priceRef(id);
        emit log_named_int("spot", _spot());
        emit log_named_int("ref.tick", tick);
        assertLe(tick, TickMath.MAX_TICK);
        assertEq(tick, _spot(), "reference converged onto spot at the extreme");
    }

    /// Seeding by the first depositor at a manipulated spot only delays the
    /// pool (reference converges 500 ticks per block); a later honest depositor
    /// does not reseed because the count never returns to zero.
    function test_seed_by_first_depositor_at_pushed_price_converges() public {
        _deepPool(1e21);
        _swapTo(3000);
        bytes32 seedPid = _victimDeposit(2400, 3600, 1e15); // "attacker" dust seed
        seedPid;
        _swapTo(0);
        (int24 tick, int24 anchor,,,,,) = hook.priceRef(id);
        emit log_named_int("seed block ref.tick", tick);
        emit log_named_int("seed block ref.anchor", anchor);
        uint256 blocks;
        while (tick != 0 && blocks < 20) {
            _nextBlock();
            hook.pokePriceRef(key);
            (tick,,,,,,) = hook.priceRef(id);
            blocks++;
        }
        emit log_named_uint("blocks to converge", blocks);
        assertEq(tick, int24(0));
    }
}

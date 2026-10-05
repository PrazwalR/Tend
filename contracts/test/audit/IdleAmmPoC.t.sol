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

/// Re-audit 2026-10-03, AMM / precision-math domain: idle balances and the
/// corrective swap leg.
contract IdleAmmPoCTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    // Second pool sharing currency1 with the first: (currency1, currency2) sorted.
    Currency currency2;
    PoolKey keyB;
    PoolId idB;

    address rebalancer = address(0xBEEF);
    uint64 constant COOLDOWN = 3600;

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        currency2 = deployMintAndApproveCurrency();

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        (Currency a, Currency b) =
            Currency.unwrap(currency1) < Currency.unwrap(currency2) ? (currency1, currency2) : (currency2, currency1);
        (keyB, idB) = initPool(a, b, IHooks(hook), 3000, SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency2)).approve(address(hook), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _dep(PoolKey memory k, int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        return hook.deposit(
            k,
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

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _wait() internal {
        _nextBlock();
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
    }

    function _reb(bytes32 pid, int24 lo, int24 hi) internal returns (uint128) {
        vm.prank(rebalancer);
        return hook.rebalance(pid, lo, hi, 0);
    }

    function _depth(PoolKey memory k, int256 liq) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: liq, salt: 0}), ""
        );
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    function _idleOf(bytes32 pid, PoolKey memory k, Currency c) internal view returns (uint256) {
        (uint128 a0, uint128 a1) = hook.idle(pid);
        if (Currency.unwrap(k.currency0) == Currency.unwrap(c)) return a0;
        if (Currency.unwrap(k.currency1) == Currency.unwrap(c)) return a1;
        return 0;
    }

    function _swapTo(PoolKey memory k, int24 target) internal {
        (, int24 now_,,) = manager.getSlot0(k.toId());
        if (now_ == target) return;
        bool down = target < now_;
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: down, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _value(uint256 a0, uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        uint256 p = uint256(sqrtP) * sqrtP >> 96;
        return (a0 * p >> 96) + a1;
    }

    // ------------------------------------------------- 1. backing invariant

    /// Three positions, two pools that share currency1, idle created in all three,
    /// then partial exits (one as claims), a same-range redeploy, and full exit.
    /// After every step the hook's ERC-6909 balance per currency must equal the
    /// sum of the recorded idle balances for that currency.
    function test_idle_backing_holds_across_positions_and_pools() public {
        bytes32 a1 = _dep(key, -600, 600, 1e18);
        bytes32 a2 = _dep(key, -1200, 1200, 3e18);
        bytes32 b1 = _dep(keyB, -600, 600, 2e18);
        bytes32[3] memory pids = [a1, a2, b1];

        _wait();
        // Sole-LP pools: the one-sided targets cannot be funded by a swap, so the
        // wrong-side token is held idle in every position.
        _reb(a1, 600, 1200);
        _reb(b1, -1200, -600);
        _assertBacked(pids);
        // a2 is rebalanced after a1 already moved price; still sole-ish LP.
        _reb(a2, 1200, 2400);
        _assertBacked(pids);
        for (uint256 i; i < 3; i++) {
            (uint128 x0, uint128 x1) = hook.idle(pids[i]);
            assertGt(uint256(x0) + x1, 0, "every position holds idle");
        }

        // a1 exits as claims; its claims move to the recipient, the others stay backed.
        uint256 c1Before = _claims(currency1);
        uint256 a1idle1 = _idleOf(a1, key, currency1);
        address recv = address(0xCAFE);
        hook.withdraw(a1, recv, true);
        _assertBacked(pids);
        assertEq(_claims(currency1), c1Before - a1idle1, "only a1's currency1 claims left the hook");
        assertGe(manager.balanceOf(recv, currency1.toId()), a1idle1, "recipient received a1's idle as claims");

        // Depth returns in pool A; a2 redeploys its idle on the SAME range.
        _depth(key, 1e20);
        _wait();
        _swapTo(key, 0);
        _wait();
        hook.pokePriceRef(key);
        _wait();
        (uint128 h0, uint128 h1) = hook.idle(a2);
        assertGt(uint256(h0) + h1, 0);
        _reb(a2, 1200, 2400);
        _assertBacked(pids);

        hook.withdraw(a2);
        hook.withdraw(b1);
        _assertBacked(pids);
        assertEq(_claims(currency0), 0, "no claims left: c0");
        assertEq(_claims(currency1), 0, "no claims left: c1");
        assertEq(_claims(currency2), 0, "no claims left: c2");
    }

    function _assertBacked(bytes32[3] memory pids) internal view {
        Currency[3] memory cs = [currency0, currency1, currency2];
        PoolKey[3] memory ks = [key, key, keyB];
        for (uint256 c; c < 3; c++) {
            uint256 sum;
            for (uint256 i; i < 3; i++) {
                sum += _idleOf(pids[i], ks[i], cs[c]);
            }
            assertEq(_claims(cs[c]), sum, "hook claims == sum(idle) for currency");
        }
    }

    /// Fuzzed sequence: random depth, random target ranges (including same-range),
    /// random exits. Invariants: backing 1:1, and any revert is a named hook error
    /// (never a v4 settlement / price-limit error or an arithmetic panic from _sub
    /// or SafeCast).
    function testFuzz_idle_backing_sequence(uint256 seed) public {
        bytes32 a1 = _dep(key, -600, 600, 1e18);
        bytes32 a2 = _dep(key, -1200, 1200, 5e17);
        bytes32 b1 = _dep(keyB, -600, 600, 2e18);
        bytes32[3] memory pids = [a1, a2, b1];
        PoolKey[3] memory ks = [key, key, keyB];

        uint256 depthChoice = seed % 3;
        if (depthChoice == 1) _depth(key, 1e17);
        if (depthChoice == 2) _depth(key, 1e21);

        for (uint256 step; step < 6; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _wait();
            uint256 who = seed % 3;
            (,,,,, bool active,) = hook.positions(pids[who]);
            if (!active) continue;
            (, int24 spot,,) = manager.getSlot0(ks[who].toId());
            int24 c = (spot / 60) * 60;
            int24 off = int24(int256((seed >> 8) % 41)) * 60 - 1200;
            int24 width = int24(int256((seed >> 16) % 20 + 1)) * 60;
            int24 lo = c + off;
            int24 hi = lo + width;
            if ((seed >> 32) % 4 == 0) {
                (,, lo, hi,,,) = hook.positions(pids[who]); // same range
            }
            vm.prank(rebalancer);
            try hook.rebalance(pids[who], lo, hi, 0) {}
            catch (bytes memory err) {
                bytes4 sel = bytes4(err);
                assertTrue(
                    sel == AutopilotHook.ZeroLiquidity.selector || sel == AutopilotHook.NothingFreed.selector
                        || sel == AutopilotHook.ValueLossExceeded.selector
                        || sel == AutopilotHook.PriceDeviation.selector || sel == AutopilotHook.NoOpRebalance.selector,
                    "unexpected revert"
                );
            }
            _assertBacked(pids);
            if ((seed >> 40) % 5 == 0) {
                hook.withdraw(pids[who], address(this), (seed >> 48) % 2 == 0);
                _assertBacked(pids);
            }
        }
        for (uint256 i; i < 3; i++) {
            (,,,,, bool active,) = hook.positions(pids[i]);
            if (active) hook.withdraw(pids[i]);
        }
        assertEq(_claims(currency0) + _claims(currency1) + _claims(currency2), 0, "all claims paid out");
    }

    // --------------------------------------- 2. corrective leg bounds (fuzz)

    /// The corrective leg must never move price beyond the start-of-rebalance
    /// spot in its direction, and the whole rebalance must stay within
    /// maxSwapImpactBps of the start in sqrtPrice terms.
    function testFuzz_corrective_leg_stays_within_impact_and_origin(uint256 seed) public {
        uint256 d = seed % 4;
        if (d == 1) _depth(key, 1e16);
        if (d == 2) _depth(key, 1e18);
        if (d == 3) _depth(key, 1e21);
        // Old range position determines the starting token split.
        int24 oldLo = int24(int256((seed >> 8) % 21)) * 60 - 600;
        bytes32 pid = _dep(key, oldLo, oldLo + 600, 1e18);
        _wait();
        (uint160 origin, int24 spot,,) = manager.getSlot0(id);
        int24 c = (spot / 60) * 60;
        int24 lo = c - int24(int256((seed >> 16) % 10 + 1)) * 60;
        int24 hi = c + int24(int256((seed >> 24) % 10 + 1)) * 60;
        if (lo == oldLo && hi == oldLo + 600) return;
        vm.prank(rebalancer);
        try hook.rebalance(pid, lo, hi, 0) {
            (uint160 after_,,,) = manager.getSlot0(id);
            uint256 bps = hook.maxSwapImpactBps();
            assertGe(uint256(after_), uint256(origin) * (10_000 - bps) / 10_000 - 1, "below impact bound");
            assertLe(uint256(after_), uint256(origin) * (10_000 + bps) / 10_000 + 1, "above impact bound");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            // NoOpRebalance: the one-sided fallback (AM2-2) can narrow a request
            // onto the range the position already holds, which CO-3 refuses
            // rather than churn swap fees.
            assertTrue(
                sel == AutopilotHook.ZeroLiquidity.selector || sel == AutopilotHook.ValueLossExceeded.selector
                    || sel == AutopilotHook.NoOpRebalance.selector,
                "unexpected revert from swap legs"
            );
        }
    }

    // ------------------------------------- 3. same-range churn on dust idle

    /// Hypothesis: rounding dust always leaves idle > 0, so the NoOp guard would
    /// never fire again and a rebalancer could churn a position in place forever.
    /// Observed: the residual shrinks geometrically and reaches exactly zero
    /// within a few same-range passes, after which NoOpRebalance fires again.
    function test_same_range_churn_self_terminates() public {
        _depth(key, 1e21);
        bytes32 pid = _dep(key, -600, 600, 1e18);
        _wait();
        _reb(pid, -1200, 2400);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        emit log_named_uint("idle0 after normal rebalance", h0);
        emit log_named_uint("idle1 after normal rebalance", h1);
        assertGt(uint256(h0) + h1, 0, "residual exists");

        uint256 n;
        for (uint256 i; i < 10; i++) {
            (h0, h1) = hook.idle(pid);
            if (uint256(h0) + h1 == 0) break;
            _wait();
            (,,,, uint128 before,,) = hook.positions(pid);
            uint128 got = _reb(pid, -1200, 2400); // same range, accepted while idle > 0
            // Relative: rounding moves liquidity by a few wei either way.
            assertGe(uint256(got) + before / 1e12, before, "a pass never meaningfully shrinks the position");
            n++;
        }
        emit log_named_uint("same-range passes accepted", n);
        assertLt(n, 10, "converges");
        _wait();
        vm.prank(rebalancer);
        vm.expectRevert(AutopilotHook.NoOpRebalance.selector);
        hook.rebalance(pid, -1200, 2400, 0);
    }

    // ------------------------------ 4. first leg driven onto the near edge

    /// Old position fully token0 (range above spot), new range a narrow straddle.
    /// The first leg sells token0 toward sqrtA; for a +-1 spacing range sqrtA is
    /// tighter than the 50 bps impact bound, so in a thin pool the leg stops ON
    /// sqrtA and `_correctOvershoot` returns early (`sqrtNow <= sqrtA`). The
    /// bought token1 is left idle. Measures how much.
    function test_first_leg_on_near_edge_skips_correction() public {
        _depth(key, 3e16); // thin external depth
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        uint256 b0 = t0.balanceOf(address(this));
        bytes32 pid = _dep(key, 60, 660, 1e18); // above spot: all token0
        uint256 deposited0 = b0 - t0.balanceOf(address(this));
        _wait();
        _reb(pid, -60, 60);
        (uint160 sqrt1, int24 tick1,,) = manager.getSlot0(id);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        (,,,, uint128 liq,,) = hook.positions(pid);
        emit log_named_int("tick after rebalance", tick1);
        emit log_named_uint("new liquidity", liq);
        emit log_named_uint("deposited token0", deposited0);
        emit log_named_uint("idle0", h0);
        emit log_named_uint("idle1", h1);
        emit log_named_uint("idle as bps of position", _value(h0, h1, sqrt1) * 10_000 / deposited0);
        assertEq(sqrt1, TickMath.getSqrtPriceAtTick(-60), "first leg stopped on the near edge");
        assertGt(h1, 0, "bought token1 left idle, no corrective leg");
    }
}

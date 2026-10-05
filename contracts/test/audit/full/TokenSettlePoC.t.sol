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
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutopilotHook} from "../../../src/AutopilotHook.sol";
import {WeirdERC20} from "../../mocks/WeirdERC20.sol";

// ------------------------------------------------------------------- token mocks

interface ISendHook {
    function onTokenSend(address to, uint256 amount, bool pre) external;
}

/// Token with an ERC777 `tokensToSend`-style callback to the PAYER (pre or post
/// the balance move), plus a switchable fee (charged on both transfer and
/// transferFrom, recipient receives less) and an optional revert on zero-value
/// transfers (LEND/BNB-style).
contract HookedFeeToken is MockERC20 {
    mapping(address => bool) public senderHooked;
    bool public preHook;
    uint256 public feeBps;
    bool public revertOnZero;

    constructor(string memory n) MockERC20(n, n, 18) {}

    function setSenderHooked(address w, bool b, bool pre) external {
        senderHooked[w] = b;
        preHook = pre;
    }

    function setFeeBps(uint256 b) external {
        feeBps = b;
    }

    function setRevertOnZero(bool b) external {
        revertOnZero = b;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(!(revertOnZero && amount == 0), "zero transfer");
        if (senderHooked[from] && preHook) ISendHook(from).onTokenSend(to, amount, true);
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            balanceOf[address(0xdead)] += fee;
        }
        if (senderHooked[from] && !preHook) ISendHook(from).onTokenSend(to, amount, false);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }
}

/// Depositor that re-enters from the payer-side token callback, i.e. while the
/// hook is inside `unlock`, between `sync` and `settle`.
contract PayerReenterer is ISendHook {
    AutopilotHook immutable hook;
    IPoolManager immutable pm;
    PoolKey public key;
    bytes32 public firstPid;
    uint8 public mode; // 0 = probe hook entry points, 1 = steal the sync via settle(), 2 = re-sync other currency
    bool fired;

    bytes public errDeposit;
    bytes public errWithdraw;
    bytes public errRebalance;
    bytes public errQueue;
    bytes public errExecute;
    bool public pokeOk;
    bool public scopeOk;

    constructor(AutopilotHook h, IPoolManager m, PoolKey memory k) {
        hook = h;
        pm = m;
        key = k;
        MockERC20(Currency.unwrap(k.currency0)).approve(address(h), type(uint256).max);
        MockERC20(Currency.unwrap(k.currency1)).approve(address(h), type(uint256).max);
    }

    function setMode(uint8 m) external {
        mode = m;
        fired = false;
    }

    function open(int24 lo, int24 hi) public returns (bytes32 pid) {
        pid = hook.deposit(
            key,
            lo,
            hi,
            1e18,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        if (firstPid == bytes32(0)) firstPid = pid;
    }

    function onTokenSend(address, uint256, bool) external {
        if (fired) return;
        fired = true;
        if (mode == 1) {
            // Claim the credit for the transfer the hook just made on our behalf.
            pm.settle();
            return;
        }
        if (mode == 2) {
            pm.sync(key.currency0);
            return;
        }
        try hook.deposit(
            key,
            -600,
            600,
            1e15,
            TickMath.minUsableTick(60),
            TickMath.maxUsableTick(60),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        ) {}
        catch (bytes memory e) {
            errDeposit = e;
        }
        try hook.withdraw(firstPid) {}
        catch (bytes memory e) {
            errWithdraw = e;
        }
        try hook.rebalance(firstPid, 600, 1200, 0) {}
        catch (bytes memory e) {
            errRebalance = e;
        }
        try hook.queueChange(abi.encodeCall(AutopilotHook.setMaxSwapImpactBps, (2000))) {}
        catch (bytes memory e) {
            errQueue = e;
        }
        try hook.executeChange(abi.encodeCall(AutopilotHook.setMaxSwapImpactBps, (2000))) {}
        catch (bytes memory e) {
            errExecute = e;
        }
        try hook.pokePriceRef(key) {
            pokeOk = true;
        } catch {}
        try hook.setPositionRebalancer(firstPid, address(1)) {
            scopeOk = true;
        } catch {}
    }
}

// ------------------------------------------------------------------------ tests

contract TokenSettlePoCTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;
    HookedFeeToken tA;
    HookedFeeToken tB;
    address rebalancer = address(0xBEEF);
    address bob = address(0xB0B);
    uint64 constant COOLDOWN = 3600;
    uint256 public okRebalances;
    uint256 public narrowed;
    uint256 public idleCreated;

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        HookedFeeToken a = new HookedFeeToken("A");
        HookedFeeToken b = new HookedFeeToken("B");
        (tA, tB) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(tA));
        currency1 = Currency.wrap(address(tB));

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        address[3] memory spenders = [address(hook), address(modifyLiquidityRouter), address(swapRouter)];
        for (uint256 i; i < 3; i++) {
            tA.approve(spenders[i], type(uint256).max);
            tB.approve(spenders[i], type(uint256).max);
        }
        tA.mint(address(this), 1e30);
        tB.mint(address(this), 1e30);
        tA.mint(bob, 1e30);
        tB.mint(bob, 1e30);
        vm.startPrank(bob);
        tA.approve(address(hook), type(uint256).max);
        tB.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        (key, id) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- helpers

    function _dep(address who, int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        vm.prank(who);
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

    function _wait() internal {
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12);
    }

    /// Daemon behaviour after a move: poke once per block until the reference
    /// sits on spot, then let it settle for MIN_STABLE_BLOCKS.
    function _catchUp() internal {
        for (uint256 i; i < 60; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            hook.pokePriceRef(key);
            (,,,, bool clamped,,) = hook.priceRef(id);
            if (!clamped) break;
        }
        vm.roll(vm.getBlockNumber() + 8);
    }

    function _swap(bool zeroForOne, uint256 amt, int24 limitTick) internal {
        (, int24 spot,,) = manager.getSlot0(id);
        if (zeroForOne ? limitTick >= spot : limitTick <= spot) return;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    /// Exactly what v4 would return for removing the whole position now:
    /// principal at the current price (rounded down) plus accrued fees, plus idle.
    function _expectedPayout(bytes32 pid) internal view returns (uint256 e0, uint256 e1) {
        (,, int24 lo, int24 hi, uint128 liq,,) = hook.positions(pid);
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(id);
        uint160 sA = TickMath.getSqrtPriceAtTick(lo);
        uint160 sB = TickMath.getSqrtPriceAtTick(hi);
        if (tick < lo) {
            e0 = SqrtPriceMath.getAmount0Delta(sA, sB, liq, false);
        } else if (tick >= hi) {
            e1 = SqrtPriceMath.getAmount1Delta(sA, sB, liq, false);
        } else {
            e0 = SqrtPriceMath.getAmount0Delta(sqrtP, sB, liq, false);
            e1 = SqrtPriceMath.getAmount1Delta(sA, sqrtP, liq, false);
        }
        (uint128 pl, uint256 last0, uint256 last1) = manager.getPositionInfo(id, address(hook), lo, hi, pid);
        assertEq(pl, liq, "recorded liquidity == PM position liquidity");
        (uint256 in0, uint256 in1) = manager.getFeeGrowthInside(id, lo, hi);
        unchecked {
            e0 += FullMath.mulDiv(in0 - last0, pl, FixedPoint128.Q128);
            e1 += FullMath.mulDiv(in1 - last1, pl, FixedPoint128.Q128);
        }
        (uint128 i0, uint128 i1) = hook.idle(pid);
        e0 += i0;
        e1 += i1;
    }

    function _assertBacked(bytes32[3] memory pids) internal view {
        uint256 s0;
        uint256 s1;
        for (uint256 i; i < 3; i++) {
            (uint128 a, uint128 b) = hook.idle(pids[i]);
            s0 += a;
            s1 += b;
        }
        assertEq(_claims(currency0), s0, "claims0 == sum idle0");
        assertEq(_claims(currency1), s1, "claims1 == sum idle1");
    }

    function _isNamed(bytes memory err) internal pure returns (bool) {
        bytes4 s = bytes4(err);
        return s == AutopilotHook.ZeroLiquidity.selector || s == AutopilotHook.NothingFreed.selector
            || s == AutopilotHook.ValueLossExceeded.selector || s == AutopilotHook.PriceDeviation.selector
            || s == AutopilotHook.NoOpRebalance.selector || s == AutopilotHook.PriceUnsettled.selector
            || s == AutopilotHook.RebalanceTooSoon.selector;
    }

    // ===================================================== 1. invariant fuzzing

    /// Three positions, two owners, one pool; random third-party depth (often none,
    /// which forces the one-sided fallback), random external swaps that accrue
    /// fees, random rebalances (including same-range idle redeploys). Checks:
    ///  - claims == sum(idle) per currency after every step;
    ///  - every rebalance revert is a named hook error (never CurrencyNotSettled,
    ///    a v4 price-limit error, or an arithmetic panic);
    ///  - every withdraw pays EXACTLY principal + fees + idle to its own owner,
    ///    whether as tokens or as claims, and nothing else.
    function testFuzz_settlement_and_exact_payout(uint256 seed) public {
        uint256 depth = seed % 4;
        if (depth == 1) {
            modifyLiquidityRouter.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e17, salt: 0}), ""
            );
        } else if (depth == 2) {
            modifyLiquidityRouter.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
            );
        }
        bytes32[3] memory pids =
            [_dep(address(this), -600, 600, 1e18), _dep(bob, -1200, 1200, 7e17), _dep(bob, 600, 1800, 3e17)];
        address[3] memory owners = [address(this), bob, bob];

        for (uint256 step; step < 8; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            // External flow: accrues fees, moves price.
            if (seed % 2 == 0) {
                (, int24 spot,,) = manager.getSlot0(id);
                bool z = (seed >> 4) % 2 == 0;
                int24 move = int24(int256((seed >> 8) % 1500)) + 1;
                _swap(z, (seed >> 24) % 1e17 + 1e12, z ? spot - move : spot + move);
                _catchUp();
            }
            _wait();
            uint256 who = (seed >> 64) % 3;
            (,,,,, bool active,) = hook.positions(pids[who]);
            if (!active) continue;
            (, int24 s,,) = manager.getSlot0(id);
            int24 c = (s / 60) * 60;
            int24 lo = c + int24(int256((seed >> 72) % 41)) * 60 - 1200;
            int24 hi = lo + int24(int256((seed >> 80) % 20 + 1)) * 60;
            if ((seed >> 96) % 4 == 0) (,, lo, hi,,,) = hook.positions(pids[who]);
            vm.prank(rebalancer);
            try hook.rebalance(pids[who], lo, hi, 0) {
                okRebalances++;
                (,, int24 plo, int24 phi,,,) = hook.positions(pids[who]);
                if (plo != lo || phi != hi) narrowed++;
                (uint128 x0, uint128 x1) = hook.idle(pids[who]);
                if (x0 + uint256(x1) > 0) idleCreated++;
            } catch (bytes memory err) {
                assertTrue(_isNamed(err), "unexpected rebalance revert");
            }
            _assertBacked(pids);

            if ((seed >> 104) % 4 == 0) {
                _withdrawExact(pids[who], owners[who], (seed >> 112) % 2 == 0);
                _assertBacked(pids);
            }
        }
        for (uint256 i; i < 3; i++) {
            (,,,,, bool active,) = hook.positions(pids[i]);
            if (active) _withdrawExact(pids[i], owners[i], i == 1);
        }
        assertEq(_claims(currency0) + _claims(currency1), 0, "no claims left behind");
    }

    /// The one-sided fallback, targeted: the position is the pool's only (or
    /// near-only) depth, one-sided, and the target straddles spot, so the bounded
    /// swap cannot convert and `_placeableLiquidity` narrows the range. A second,
    /// unrelated position (bob) shares the currencies. Settlement must balance,
    /// claims must back idle, and both owners must be paid exactly.
    function testFuzz_one_sided_fallback_settles(uint256 seed, bool above, uint8 w, uint8 o, uint8 d) public {
        int24 width = int24(uint24(w % 10) + 1) * 60;
        int24 off = int24(uint24(o % 10)) * 60;
        bytes32 a = above
            ? _dep(address(this), 60 + off, 60 + off + width, 1e18)
            : _dep(address(this), -60 - off - width, -60 - off, 1e18);
        // Bob's position sits far away so it adds no depth near spot.
        bytes32 b = _dep(bob, 30000, 31200, 5e17);
        if (d % 3 == 1) {
            modifyLiquidityRouter.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e12, salt: 0}), ""
            );
        }
        _wait();
        int24 lo = -int24(uint24(seed % 20) + 1) * 60;
        int24 hi = int24(uint24((seed >> 8) % 20) + 1) * 60;
        vm.prank(rebalancer);
        try hook.rebalance(a, lo, hi, 0) {
            (,, int24 plo, int24 phi,,,) = hook.positions(a);
            if (plo != lo || phi != hi) narrowed++;
        } catch (bytes memory err) {
            assertTrue(_isNamed(err), "unexpected rebalance revert");
        }
        bytes32[3] memory pids = [a, b, bytes32(0)];
        _assertBacked(pids);
        // Same-range redeploy of whatever was left idle.
        (uint128 i0, uint128 i1) = hook.idle(a);
        if (i0 + uint256(i1) > 0) {
            _wait();
            (,, int24 clo, int24 chi,,,) = hook.positions(a);
            vm.prank(rebalancer);
            try hook.rebalance(a, clo, chi, 0) {}
            catch (bytes memory err) {
                assertTrue(_isNamed(err), "unexpected same-range revert");
            }
            _assertBacked(pids);
        }
        _withdrawExact(a, address(this), seed % 2 == 0);
        _withdrawExact(b, bob, false);
        assertEq(_claims(currency0) + _claims(currency1), 0);
    }

    function test_fallback_coverage() public {
        uint256 snap = vm.snapshotState();
        uint256 nar;
        for (uint256 i; i < 30; i++) {
            uint256 s = uint256(keccak256(abi.encode("fb", i)));
            this.testFuzz_one_sided_fallback_settles(s, i % 2 == 0, uint8(s >> 16), uint8(s >> 24), uint8(s >> 32));
            nar += narrowed;
            vm.revertToState(snap);
        }
        emit log_named_uint("narrowed", nar);
        assertGt(nar, 0);
    }

    /// Extreme decimals / prices: a pool initialised anywhere in +-800k ticks
    /// (a 6-vs-24-decimal pair sits around +-414k). Deposit, external flow,
    /// rebalance (incl. one-sided fallback when there is no depth), then an exact
    /// payout check. No overflow in the value guard or swap sizing.
    function testFuzz_extreme_price_settles(int24 t, uint256 seed, bool depth) public {
        t = int24(bound(int256(t), -800000, 800000));
        t = (t / 10) * 10;
        tA.mint(address(this), 1e60);
        tB.mint(address(this), 1e60);
        (key, id) = initPool(currency0, currency1, IHooks(hook), 500, TickMath.getSqrtPriceAtTick(t));
        if (depth) {
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: t - 20000, tickUpper: t + 20000, liquidityDelta: 1e15, salt: 0}),
                ""
            );
        }
        bytes32 pid = hook.deposit(
            key,
            t - 600,
            t + 600,
            1e12,
            TickMath.minUsableTick(10),
            TickMath.maxUsableTick(10),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        _wait();
        int24 lo = t + int24(int256(seed % 41)) * 60 - 1200;
        int24 hi = lo + int24(int256((seed >> 8) % 20 + 1)) * 60;
        vm.prank(rebalancer);
        try hook.rebalance(pid, lo, hi, 0) {}
        catch (bytes memory err) {
            assertTrue(_isNamed(err), "unexpected rebalance revert");
        }
        bytes32[3] memory pids = [pid, bytes32(0), bytes32(0)];
        _assertBacked(pids);
        _withdrawExact(pid, address(this), seed % 2 == 0);
        assertEq(_claims(currency0) + _claims(currency1), 0);
    }

    /// Coverage check for the fuzz above: over 40 seeds the sequence must hit
    /// successful rebalances, the one-sided narrowing fallback, and idle balances.
    function test_fuzz_sequence_coverage() public {
        uint256 snap = vm.snapshotState();
        uint256 ok;
        uint256 nar;
        uint256 idl;
        for (uint256 i; i < 40; i++) {
            this.testFuzz_settlement_and_exact_payout(uint256(keccak256(abi.encode("cov", i))));
            ok += okRebalances;
            nar += narrowed;
            idl += idleCreated;
            vm.revertToState(snap);
        }
        emit log_named_uint("successful rebalances", ok);
        emit log_named_uint("one-sided narrowed", nar);
        emit log_named_uint("left idle", idl);
        assertGt(ok, 40);
        assertGt(idl, 0);
    }

    function _withdrawExact(bytes32 pid, address owner, bool asClaims) internal {
        (uint256 e0, uint256 e1) = _expectedPayout(pid);
        address recv = address(uint160(uint256(keccak256(abi.encode(pid, "recv")))));
        vm.prank(owner);
        hook.withdraw(pid, recv, asClaims);
        if (asClaims) {
            assertEq(manager.balanceOf(recv, currency0.toId()), e0, "claims0 exact");
            assertEq(manager.balanceOf(recv, currency1.toId()), e1, "claims1 exact");
        } else {
            assertEq(tA.balanceOf(recv), e0, "token0 exact");
            assertEq(tB.balanceOf(recv), e1, "token1 exact");
        }
    }

    // ================================================= 2. payer-side reentrancy

    /// Token gives the depositor a callback mid-`_settleExact` (between sync and
    /// settle, inside the hook's unlock). Every hook entry point is either locked
    /// or harmless; the owner-only timelock entry points reject a non-owner.
    function test_payer_callback_reentry_into_every_entry_point() public {
        PayerReenterer r = new PayerReenterer(hook, manager, key);
        tA.mint(address(r), 1e24);
        tB.mint(address(r), 1e24);
        bytes32 first = r.open(-600, 600);
        tA.setSenderHooked(address(r), true, false); // post-transfer callback
        bytes32 second = r.open(-1200, 1200);
        assertTrue(second != first);

        bytes4 lock = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        assertEq(bytes4(r.errDeposit()), lock, "deposit locked");
        assertEq(bytes4(r.errWithdraw()), lock, "withdraw locked");
        assertEq(bytes4(r.errRebalance()), lock, "rebalance locked");
        assertEq(bytes4(r.errQueue()), Ownable.OwnableUnauthorizedAccount.selector, "queue owner-only");
        assertEq(bytes4(r.errExecute()), Ownable.OwnableUnauthorizedAccount.selector, "execute owner-only");
        assertTrue(r.pokeOk(), "poke unguarded, rate-limited");
        assertTrue(r.scopeOk(), "own-position scope change unguarded, owner-only");
        assertEq(hook.positionRebalancer(first), address(1));
        (,,,, uint128 liq,,) = hook.positions(second);
        assertEq(liq, 1e18, "second deposit completed normally");
    }

    /// The payer hijacks the sync by calling `settle()` itself after the hook's
    /// transfer landed (or re-syncs another currency). The hook's own settle then
    /// sees 0 paid and the whole deposit reverts: no credit can be redirected.
    function test_payer_cannot_redirect_the_settle_credit() public {
        PayerReenterer r = new PayerReenterer(hook, manager, key);
        tA.mint(address(r), 1e24);
        tB.mint(address(r), 1e24);
        tA.setSenderHooked(address(r), true, false);
        r.setMode(1);
        uint256 pmBefore = tA.balanceOf(address(manager));
        vm.expectRevert(); // WrappedError(FeeOnTransferNotSupported(currency0, amt, 0))
        r.open(-600, 600);
        assertEq(tA.balanceOf(address(manager)), pmBefore);

        tA.setSenderHooked(address(r), true, true); // pre-transfer: re-sync the other currency
        r.setMode(2);
        tB.setSenderHooked(address(r), true, true);
        tA.setSenderHooked(address(r), false, true);
        vm.expectRevert();
        r.open(-600, 600);
    }

    // ===================================================== 3. weird-token edges

    /// FoT detection only inspects the legs actually paid. A deposit funded with
    /// token0 alone (range above spot) admits a fee-on-transfer token1 unnoticed;
    /// the position later converts into it and pays the fee on exit. The pool's
    /// settlement stays intact; the owner absorbs the token's fee.
    function test_fot_on_unpaid_leg_is_not_detected() public {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        tB.setFeeBps(100); // 1% fee on token1, already on at deposit
        // Straddling range: token1 leg paid -> FoT detected.
        vm.expectRevert();
        _dep(address(this), -600, 600, 1e18);
        // Range above spot: only token0 paid -> accepted.
        bytes32 pid = _dep(address(this), 600, 1200, 1e18);
        // Rebalance below spot: converts entirely into the FoT token, no transfer.
        _wait();
        vm.prank(rebalancer);
        hook.rebalance(pid, -1200, -600, 0);
        (uint256 e0, uint256 e1) = _expectedPayout(pid);
        assertGt(e1, 0);
        address recv = address(0xCAFE);
        hook.withdraw(pid, recv, false);
        assertEq(tA.balanceOf(recv), e0);
        assertEq(tB.balanceOf(recv), e1 - e1 / 100, "owner pays the token's fee on exit");
    }

    /// Fee switched on after deposit: rebalance moves no tokens (unaffected),
    /// a token exit delivers amount - fee, a claims exit delivers in full. The
    /// PoolManager's reserves are never short: it sends exactly `amount`.
    function test_fee_switched_on_after_deposit() public {
        bytes32 pid = _dep(address(this), -600, 600, 1e18);
        bytes32 pid2 = _dep(address(this), -600, 600, 1e18);
        tA.setFeeBps(50);
        tB.setFeeBps(50);
        _wait();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        (uint256 e0, uint256 e1) = _expectedPayout(pid);
        uint256 pmA = tA.balanceOf(address(manager));
        hook.withdraw(pid, address(0xC1), false);
        assertEq(tA.balanceOf(address(0xC1)), e0 - e0 * 50 / 10_000);
        assertEq(tB.balanceOf(address(0xC1)), e1 - e1 * 50 / 10_000);
        assertEq(pmA - tA.balanceOf(address(manager)), e0, "PM debited exactly the take");
        (e0, e1) = _expectedPayout(pid2);
        hook.withdraw(pid2, address(0xC2), true);
        assertEq(manager.balanceOf(address(0xC2), currency0.toId()), e0);
        assertEq(manager.balanceOf(address(0xC2), currency1.toId()), e1);
        // A FoT deposit is now refused.
        vm.expectRevert();
        _dep(address(this), -600, 600, 1e18);
    }

    /// Tokens that revert on zero-value transfers: one-sided deposits, rebalances
    /// and exits never issue a zero transfer.
    function test_zero_transfer_reverting_tokens() public {
        tA.setRevertOnZero(true);
        tB.setRevertOnZero(true);
        bytes32 pid = _dep(address(this), 600, 1200, 1e18); // token0 only
        bytes32 pid2 = _dep(address(this), -1200, -600, 1e18); // token1 only
        _wait();
        vm.prank(rebalancer);
        hook.rebalance(pid, 1200, 2400, 0); // one-sided -> one-sided, nothing idle
        hook.withdraw(pid);
        hook.withdraw(pid2);
        assertEq(_claims(currency0) + _claims(currency1), 0);
    }

    /// InvalidRecipient for the hook and the PoolManager, in both payout modes.
    function test_invalid_recipients_rejected() public {
        bytes32 pid = _dep(address(this), -600, 600, 1e18);
        for (uint256 i; i < 2; i++) {
            bool claims = i == 1;
            vm.expectRevert(AutopilotHook.InvalidRecipient.selector);
            hook.withdraw(pid, address(hook), claims);
            vm.expectRevert(AutopilotHook.InvalidRecipient.selector);
            hook.withdraw(pid, address(manager), claims);
        }
        vm.expectRevert(AutopilotHook.ZeroRecipient.selector);
        hook.withdraw(pid, address(0), false);
    }
}

/// Blacklisting the hook / the PoolManager, on the existing WeirdERC20 mock
/// (which blacklists `from`, `to` and `msg.sender`).
contract TokenSettleBlacklistTest is Test, Deployers {
    AutopilotHook hook;
    WeirdERC20 t0;
    WeirdERC20 t1;
    address rebalancer = address(0xBEEF);

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        WeirdERC20 a = new WeirdERC20("A");
        WeirdERC20 b = new WeirdERC20("B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));
        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, 3600), flags);
        hook = AutopilotHook(flags);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        (key,) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
    }

    function _dep() internal returns (bytes32) {
        return hook.deposit(
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
    }

    function _wait() internal {
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.roll(vm.getBlockNumber() + 300);
    }

    /// Hook blacklisted: only new deposits stop (the hook is the transferFrom
    /// spender). Rebalance and both exit modes keep working.
    function test_hook_blacklisted_blocks_only_deposits() public {
        bytes32 pid = _dep();
        t1.setBlacklisted(address(hook), true);
        vm.expectRevert();
        _dep();
        _wait();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        hook.withdraw(pid);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    /// PoolManager blacklisted: token exits revert, the claims exit pays in full
    /// (idle included) and rebalancing still works.
    function test_pm_blacklisted_claims_exit_works() public {
        bytes32 pid = _dep();
        t1.setBlacklisted(address(manager), true);
        _wait();
        vm.prank(rebalancer);
        hook.rebalance(pid, 600, 1200, 0);
        (, uint128 h1) = hook.idle(pid);
        assertGt(h1, 0);
        vm.expectRevert();
        hook.withdraw(pid);
        hook.withdraw(pid, address(0xCAFE), true);
        assertEq(manager.balanceOf(address(0xCAFE), currency1.toId()), h1);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }
}

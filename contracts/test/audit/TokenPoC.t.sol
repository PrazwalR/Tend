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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AutopilotHook} from "../../src/AutopilotHook.sol";
import {WeirdERC20, ITokenReceiverHook} from "../mocks/WeirdERC20.sol";

/// Position owner that re-enters the hook from an ERC777-style receive callback.
contract Reenterer is ITokenReceiverHook {
    AutopilotHook immutable hook;
    PoolKey public key;
    bytes32 public pid;
    bool fired;

    bytes public errWithdraw;
    bytes public errRebalance;
    bytes public errDeposit;
    bool public pokeOk;
    bool public sawActive;
    uint256 public sawIdle;

    constructor(AutopilotHook h, PoolKey memory k) {
        hook = h;
        key = k;
        WeirdERC20(Currency.unwrap(k.currency0)).approve(address(h), type(uint256).max);
        WeirdERC20(Currency.unwrap(k.currency1)).approve(address(h), type(uint256).max);
    }

    function open() external returns (bytes32) {
        pid = hook.deposit(
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
        return pid;
    }

    function close() external {
        hook.withdraw(pid);
    }

    function onTokenTransfer(address, uint256) external {
        if (fired) return;
        fired = true;
        // Read-only view of hook state mid-payout.
        (,,,,, bool active,) = hook.positions(pid);
        sawActive = active;
        (uint128 i0, uint128 i1) = hook.idle(pid);
        sawIdle = uint256(i0) + i1;
        try hook.withdraw(pid) {}
        catch (bytes memory e) {
            errWithdraw = e;
        }
        try hook.rebalance(pid, 600, 1200, 0) {}
        catch (bytes memory e) {
            errRebalance = e;
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
        try hook.pokePriceRef(key) {
            pokeOk = true;
        } catch {}
    }
}

contract TokenPoCTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    WeirdERC20 t0;
    WeirdERC20 t1;
    PoolKey key2;
    address rebalancer = address(0xBEEF);
    uint64 constant COOLDOWN = 3600;

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();

        WeirdERC20 a = new WeirdERC20("A");
        WeirdERC20 b = new WeirdERC20("B");
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));

        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);

        address[3] memory spenders = [address(hook), address(modifyLiquidityRouter), address(swapRouter)];
        for (uint256 i; i < 3; i++) {
            t0.approve(spenders[i], type(uint256).max);
            t1.approve(spenders[i], type(uint256).max);
        }
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);

        (key,) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        (key2,) = initPool(currency0, currency1, IHooks(hook), 500, SQRT_PRICE_1_1);
    }

    function _deposit(PoolKey memory k, int24 lo, int24 hi) internal returns (bytes32) {
        int24 s = k.tickSpacing;
        return hook.deposit(
            k,
            lo,
            hi,
            1e18,
            TickMath.minUsableTick(s),
            TickMath.maxUsableTick(s),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
    }

    function _rebalance(bytes32 pid, int24 lo, int24 hi) internal {
        vm.prank(rebalancer);
        hook.rebalance(pid, lo, hi, 0);
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    function _sumIdle(bytes32[2] memory pids) internal view returns (uint256 s0, uint256 s1) {
        for (uint256 i; i < 2; i++) {
            (uint128 a, uint128 b) = hook.idle(pids[i]);
            s0 += a;
            s1 += b;
        }
    }

    /// Two pools sharing both currencies, so both positions' idle balances live
    /// under the same ERC-6909 ids. A third party donates claims to the hook.
    /// Claims == sum(idle) + donation at every step; the donation strands harmlessly.
    function test_claims_back_idle_across_pools_and_donation_is_inert() public {
        bytes32 p1 = _deposit(key, -600, 600);
        bytes32 p2 = _deposit(key2, -600, 600);
        // Third position to source claims for the donation.
        bytes32 p3 = _deposit(key2, -600, 600);
        hook.withdraw(p3, address(this), true);
        uint256 donation = manager.balanceOf(address(this), currency1.toId()) / 2;
        assertGt(donation, 0);

        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _rebalance(p1, 600, 1200);
        _rebalance(p2, 600, 1200);
        bytes32[2] memory pids = [p1, p2];
        (uint256 s0, uint256 s1) = _sumIdle(pids);
        assertGt(s0 + s1, 0, "idle exists");
        assertEq(_claims(currency0), s0);
        assertEq(_claims(currency1), s1);

        manager.transfer(address(hook), currency1.toId(), donation);
        assertEq(_claims(currency1), s1 + donation, "donation lands");

        // The hook never grants operator status or allowance on its claims.
        assertFalse(manager.isOperator(address(hook), address(this)));
        assertFalse(manager.isOperator(address(hook), rebalancer));
        assertEq(manager.allowance(address(hook), address(this), currency1.toId()), 0);
        vm.expectRevert();
        manager.transferFrom(address(hook), address(this), currency1.toId(), 1);

        hook.withdraw(p1);
        (s0, s1) = _sumIdle(pids);
        assertEq(_claims(currency0), s0);
        assertEq(_claims(currency1), s1 + donation);
        hook.withdraw(p2, address(this), true);
        assertEq(_claims(currency0), 0);
        assertEq(_claims(currency1), donation, "donated claims are stranded, nothing else");
    }

    /// Issuer pauses token1 while the position holds idle token1. The underlying
    /// exit reverts as a whole; the claims exit still pays the idle balance in full.
    function test_paused_token_exit_as_claims_includes_idle() public {
        bytes32 pid = _deposit(key, -600, 600);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _rebalance(pid, 600, 1200);
        (, uint128 held1) = hook.idle(pid);
        assertGt(held1, 0);

        t1.setPaused(true);
        vm.expectRevert(); // WrappedError around the token's "paused" revert
        hook.withdraw(pid);

        uint256 before = manager.balanceOf(address(this), currency1.toId());
        hook.withdraw(pid, address(this), true);
        // Range sits above spot, so every token1 out is the idle balance.
        assertEq(manager.balanceOf(address(this), currency1.toId()) - before, held1);
        assertEq(_claims(currency1), 0);
    }

    /// An owner blacklisted on token1 no longer blocks rebalancing: the residual is
    /// held as claims, so a rebalance makes no token transfer at all. (Before the
    /// idle change the residual `take` to the owner reverted the whole rebalance.)
    function test_blacklisted_owner_does_not_block_rebalance() public {
        bytes32 pid = _deposit(key, -600, 600);
        t1.setBlacklisted(address(this), true);
        t0.setBlacklisted(address(this), true);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _rebalance(pid, 600, 1200);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        assertGt(uint256(h0) + h1, 0);
        // Exit to a clean address still works.
        hook.withdraw(pid, address(0xCAFE), false);
        assertGe(t1.balanceOf(address(0xCAFE)), h1);
    }

    /// ERC777-style recipient callback during the withdraw payout (which now
    /// includes the released idle balance). Every state-changing entry point is
    /// locked; state seen mid-payout is already final.
    function test_reentrancy_from_withdraw_payout_is_blocked() public {
        Reenterer r = new Reenterer(hook, key);
        t0.mint(address(r), 1e24);
        t1.mint(address(r), 1e24);
        bytes32 pid = r.open();
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _rebalance(pid, 600, 1200);
        (uint128 h0, uint128 h1) = hook.idle(pid);
        assertGt(uint256(h0) + h1, 0);

        t0.setHooked(address(r), true);
        r.close();

        bytes4 lock = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        assertEq(bytes4(r.errWithdraw()), lock);
        assertEq(bytes4(r.errRebalance()), lock);
        assertEq(bytes4(r.errDeposit()), lock);
        assertTrue(r.pokeOk(), "pokePriceRef is unguarded but only nudges the reference");
        assertFalse(r.sawActive(), "position already closed when tokens move");
        assertEq(r.sawIdle(), 0, "idle already cleared when tokens move");
        assertEq(_claims(currency0) + _claims(currency1), 0);
    }

    /// T-3 with idle: a negative rebase of the PoolManager's balance leaves the
    /// position's underlying exit reverting, while the claims exit succeeds and
    /// hands the owner claims the PoolManager cannot fully redeem. Same exposure
    /// as an LP position; idle neither worsens nor improves it.
    function test_negative_rebase_leaves_claims_exit_underbacked() public {
        bytes32 pid = _deposit(key, -600, 600);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _rebalance(pid, 600, 1200);
        (, uint128 held1) = hook.idle(pid);
        uint256 pmBal = t1.balanceOf(address(manager));
        t1.slash(address(manager), pmBal - held1 / 2);

        vm.expectRevert();
        hook.withdraw(pid);

        hook.withdraw(pid, address(this), true);
        assertEq(manager.balanceOf(address(this), currency1.toId()), held1);
        assertLt(t1.balanceOf(address(manager)), held1, "claims exceed the backing");
    }
}

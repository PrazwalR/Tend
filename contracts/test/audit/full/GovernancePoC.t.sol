// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutopilotHook} from "../../../src/AutopilotHook.sol";
import {IAggregatorV3} from "../../../src/interfaces/IAggregatorV3.sol";

/// A contract anyone can deploy that passes the deploy script's only feed check
/// (`description()`), while reporting whatever its owner wants.
contract FakeSequencerFeed is IAggregatorV3 {
    string public description;
    int256 public answer;
    uint256 public startedAt;

    constructor(string memory d) {
        description = d;
        startedAt = 1;
    }

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// Full-audit governance PoCs and regression checks (tend full audit, governance domain).
contract GovernancePoC is Test, Deployers {
    using StateLibrary for IPoolManager;
    AutopilotHook hook;
    address rebalancer = address(0xBEEF);
    address other = address(0xCAFE);
    address newOwner = address(0x5AFE);
    uint64 constant COOLDOWN = 3600;

    function setUp() public {
        vm.warp(1_758_300_000);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        address flags = address(uint160(Hooks.AFTER_SWAP_FLAG) | (uint160(0x4444) << 144));
        deployCodeTo("AutopilotHook.sol:AutopilotHook", abi.encode(manager, address(this), rebalancer, COOLDOWN), flags);
        hook = AutopilotHook(flags);
        (key,) = initPool(currency0, currency1, IHooks(hook), 3000, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _eta(bytes4 sel) internal view returns (uint64 eta) {
        (, eta,) = hook.pendingChange(sel);
    }

    // ------------------------------------------------------------------ GV-1 (Info)

    /// The selector-keyed queue means any instant change to a setter drops the
    /// pending change for it, even one about a different subject. An emergency
    /// removal of a compromised rebalancer silently restarts the 2-day wait of a
    /// queued replacement rebalancer.
    function test_GV1_emergency_removal_cancels_unrelated_queued_addition() public {
        hook.queueChange(abi.encodeCall(hook.setRebalancer, (other, true)));
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY() - 1);
        hook.setRebalancer(rebalancer, false); // emergency: old key compromised
        // Fixed: the queue is keyed per rebalancer, so the addition survives.
        vm.warp(vm.getBlockTimestamp() + 1);
        hook.executeChange(abi.encodeCall(hook.setRebalancer, (other, true)));
        assertTrue(hook.isRebalancer(other), "the queued replacement still lands on time");
        // Same for the price guard: tightening the deviation drops a queued step change.
        hook.queueChange(abi.encodeCall(hook.setPriceGuard, (400, 200)));
        hook.setPriceGuard(500, 150);
        assertEq(_eta(hook.setPriceGuard.selector), 0);
    }

    // ------------------------------------------------------------- verified correct

    /// msg.sig in `_requireQueuedIf` is the setter's own selector on every direct
    /// call: an instant change to each of the six setters clears exactly its entry.
    function test_VC_instant_change_clears_only_its_own_setter() public {
        address feed = address(new FakeSequencerFeed("x"));
        bytes[6] memory q = [
            abi.encodeCall(hook.setRebalancer, (other, true)),
            abi.encodeCall(hook.setMaxSwapImpactBps, (100)),
            abi.encodeCall(hook.setMaxRebalanceLossBps, (200)),
            abi.encodeCall(hook.setSequencerUptimeFeed, (feed)),
            abi.encodeCall(hook.setPriceGuard, (400, 200)),
            abi.encodeCall(hook.setMinRebalanceInterval, (60))
        ];
        for (uint256 i; i < 6; i++) {
            hook.queueChange(q[i]);
        }
        bytes4[6] memory sels = [
            hook.setRebalancer.selector,
            hook.setMaxSwapImpactBps.selector,
            hook.setMaxRebalanceLossBps.selector,
            hook.setSequencerUptimeFeed.selector,
            hook.setPriceGuard.selector,
            hook.setMinRebalanceInterval.selector
        ];
        // Instant, non-loosening calls, one per setter, in order; after each, only
        // that setter's entry is gone.
        for (uint256 i; i < 6; i++) {
            if (i == 0) hook.setRebalancer(rebalancer, false);
            if (i == 1) hook.setMaxSwapImpactBps(40);
            if (i == 2) hook.setMaxRebalanceLossBps(90);
            if (i == 3) hook.setSequencerUptimeFeed(address(0)); // 0 -> 0: no-op, instant
            if (i == 4) hook.setPriceGuard(500, 190);
            if (i == 5) hook.setMinRebalanceInterval(7200);
            for (uint256 j; j < 6; j++) {
                assertEq(_eta(sels[j]) == 0, j <= i, "only the touched setter's entry is cleared");
            }
        }
    }

    /// Inside executeChange the self-call skips the cancel branch, so executing
    /// one change never drops another setter's pending change.
    function test_VC_execute_leaves_other_pending_changes() public {
        bytes memory a = abi.encodeCall(hook.setMaxRebalanceLossBps, (200));
        bytes memory b = abi.encodeCall(hook.setMaxSwapImpactBps, (100));
        hook.queueChange(a);
        hook.queueChange(b);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        hook.executeChange(a);
        assertGt(_eta(hook.setMaxSwapImpactBps.selector), 0);
        hook.executeChange(b);
        assertEq(hook.maxRebalanceLossBps(), 200);
        assertEq(hook.maxSwapImpactBps(), 100);
    }

    /// Constructor runs the override (epoch 1); step one of the handover does not
    /// bump it, the pending owner has no powers, acceptance bumps it and voids the
    /// old owner's queue, and the old owner loses everything.
    function test_VC_two_step_handover_and_epoch() public {
        assertEq(hook.ownerEpoch(), 1, "constructor goes through the override");
        bytes memory c = abi.encodeCall(hook.setMaxRebalanceLossBps, (500));
        hook.queueChange(c);
        hook.transferOwnership(newOwner);
        assertEq(hook.ownerEpoch(), 1, "pending handover does not bump");

        vm.startPrank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        hook.queueChange(c);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        hook.cancelChange(hook.setMaxRebalanceLossBps.selector);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        hook.setMaxRebalanceLossBps(25);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        hook.pause();
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.prank(newOwner);
        hook.acceptOwnership();
        assertEq(hook.ownerEpoch(), 2);
        assertEq(hook.pendingOwner(), address(0));

        vm.prank(newOwner);
        vm.expectRevert(AutopilotHook.ChangeNotQueued.selector);
        hook.executeChange(c);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.executeChange(c);
        assertEq(hook.maxRebalanceLossBps(), 100);
    }

    /// A non-canonical exact-length encoding (dirty high bits) can be queued but
    /// never executes: the ABI decoder of the setter rejects it.
    function test_VC_dirty_bits_encoding_never_executes() public {
        bytes memory dirty = abi.encodeWithSelector(hook.setMaxRebalanceLossBps.selector, uint256(1 << 16) | 200);
        hook.queueChange(dirty);
        vm.warp(vm.getBlockTimestamp() + hook.TIMELOCK_DELAY());
        vm.expectRevert();
        hook.executeChange(dirty);
        assertEq(hook.maxRebalanceLossBps(), 100);
    }

    /// Instant paths into a looser state, exhaustively per setter: each loosening
    /// direction reverts outside the queue, from the default state.
    function test_VC_no_instant_loosening_from_defaults() public {
        address feed = address(new FakeSequencerFeed("x"));
        hook.setSequencerUptimeFeed(feed); // 0 -> feed: adds a check, instant
        address feed2 = address(new FakeSequencerFeed("y"));

        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setRebalancer(other, true);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMaxSwapImpactBps(51);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMaxRebalanceLossBps(101);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setSequencerUptimeFeed(address(0));
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setSequencerUptimeFeed(feed2);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(499, 200);
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setPriceGuard(1, 100); // slowing the step waits even with a tighter window
        vm.expectRevert(AutopilotHook.ChangeMustBeQueued.selector);
        hook.setMinRebalanceInterval(COOLDOWN - 1);
        hook.setPriceGuard(500, 200); // equal: instant, harmless
    }

    // ------------------------------------------------------------------ GV-3 support

    /// `setAllowedPool` accepts a key no pool can ever have (fee 0 / spacing 0 as
    /// the deploy script builds when ALLOWED_POOL_FEE / _TICK_SPACING are unset),
    /// and the script's own post-check reads back the same key, so it passes.
    function test_GV3_allowlist_accepts_uninitialisable_key() public {
        // Fixed: a key with zero tick spacing cannot be listed.
        PoolKey memory bad = PoolKey(key.currency0, key.currency1, 0, 0, IHooks(hook));
        vm.expectRevert(AutopilotHook.InvalidTickRange.selector);
        hook.setAllowedPool(bad, true);
        hook.setAllowlistEnforced(true);
        vm.expectRevert(AutopilotHook.PoolNotAllowed.selector);
        hook.deposit(
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

    // ------------------------------------------------------------------ GV-4 (Info)

    function _swapTo(PoolId pid, int24 target) internal {
        (, int24 now_,,) = manager.getSlot0(pid);
        if (now_ == target) return;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: target < now_,
                amountSpecified: -1e30,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The daemon preflights at `pending` so the call sees block N+1, where the
    /// hook measures against the reference as of N's end (DS-9). An OP-stack node
    /// that does not compute a pending block (op-geth / op-reth default without
    /// `--rollup.compute(-)pending(-)block`) answers `pending` with the latest
    /// block, i.e. block N semantics. Same state, same call: block N refuses an
    /// honest 300-tick move that block N+1 accepts.
    function test_GV4_latest_vs_next_block_preflight_diverge() public {
        PoolId pid = key.toId();
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e21, salt: 0}), ""
        );
        bytes32 pos = hook.deposit(
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
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + 10); // reference settled
        _swapTo(pid, 300); // honest move within the per-block cap, in block N
        uint256 snap = vm.snapshotState();

        // "pending" answered as latest: still block N.
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceDeviation.selector);
        hook.rebalance(pos, 120, 480, 0);

        // Since the OR-1 fix a 300-tick move leaves the stable run's band, so the
        // new level must be held MIN_STABLE_BLOCKS block ends — block N+1 is
        // refused too, whatever `pending` means on the node.
        vm.revertToState(snap);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(rebalancer);
        vm.expectPartialRevert(AutopilotHook.PriceUnsettled.selector);
        hook.rebalance(pos, 120, 480, 0);
        vm.roll(vm.getBlockNumber() + hook.MIN_STABLE_BLOCKS());
        vm.prank(rebalancer);
        hook.rebalance(pos, 120, 480, 0);
    }
}

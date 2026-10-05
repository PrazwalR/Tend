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
import {AutopilotHook} from "../../src/AutopilotHook.sol";

/// DoS / griefing PoCs for the 2026-10-03 re-audit (findings-dos.md).
contract DosPoC is Test, Deployers {
    using StateLibrary for IPoolManager;

    AutopilotHook hook;
    PoolId id;

    address rebalancer = address(0xBEEF);
    uint64 constant COOLDOWN = 3600;
    bytes32 constant GRIEFER_SALT = bytes32(uint256(0xBAD));

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

    function _deposit(PoolKey memory k, int24 lo, int24 hi, uint128 liq) internal returns (bytes32) {
        return hook.deposit(
            k,
            lo,
            hi,
            liq,
            TickMath.minUsableTick(k.tickSpacing),
            TickMath.maxUsableTick(k.tickSpacing),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
    }

    function _lp(PoolKey memory k, int24 lo, int24 hi, int256 delta, bytes32 salt) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: delta, salt: salt}), ""
        );
    }

    /// Exact-in swap that stops at `limitTick` (or when `amountIn` runs out).
    function _swapTo(PoolKey memory k, bool zeroForOne, int256 amountIn, int24 limitTick) internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(
            k,
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
    }

    function _catchUpRef(PoolKey memory k) internal {
        for (uint256 i; i < 10; i++) {
            _nextBlock();
            hook.pokePriceRef(k);
        }
        _nextBlock();
    }

    function _spot(PoolId pid) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(pid);
    }

    /// Victim position [-600,600] pushed out of range below, so it holds only
    /// token0. Depth below spot is provided solely by the griefer (`grieferLiq`)
    /// plus an optional honest LP (`honestLiq`).
    function _victimOutOfRange(uint128 grieferLiq, uint128 honestLiq) internal returns (bytes32 pid) {
        _lp(key, -60000, 60000, int256(uint256(grieferLiq)), GRIEFER_SALT);
        if (honestLiq > 0) _lp(key, -60000, 60000, int256(uint256(honestLiq)), bytes32(0));
        pid = _deposit(key, -600, 600, 1e18);
        _swapTo(key, true, 1e30, -900); // ends exactly at tick -900
        assertEq(_spot(id), -900);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _catchUpRef(key);
    }

    /// The narrowed range starts at the first spacing strictly above spot as the
    /// swap left it (it may have walked the empty book by up to the impact bound),
    /// and keeps the requested upper edge: token0 only.
    function _assertPlacedJustAboveSpot(bytes32 pid, int24 upper) internal view {
        (,, int24 lo, int24 hi,,,) = hook.positions(pid);
        int24 spot = _spot(id);
        assertGt(lo, spot, "placed strictly above spot: funded by token0 alone");
        assertLe(lo - key.tickSpacing, spot, "the first spacing above spot");
        assertEq(hi, upper, "upper edge as requested");
    }

    // ------------------------------------------------------------------ DS-1

    /// An LP who is the only depth below spot pulls it; an out-of-range position
    /// can then not be recentred onto a straddling range at all — even with the
    /// rebalancer's floor waived (minLiquidity = 0). The idle mechanism does not
    /// help: the re-ratio swap fills nothing, so the range gets zero liquidity.
    function test_DS1_depthPull_bricks_straddle_rebalance_with_zero_floor() public {
        bytes32 pid = _victimOutOfRange(1e20, 0);
        int24 lower = -1500;
        int24 upper = -300; // straddles spot -900

        // Control: with the griefer's depth present the rebalance works.
        uint256 snap = vm.snapshotState();
        vm.prank(rebalancer);
        uint128 ok = hook.rebalance(pid, lower, upper, 0);
        assertGt(ok, 0, "control: straddle rebalance succeeds with depth");
        console2.log("control newLiquidity", ok);
        vm.revertToState(snap);

        // Grief: remove the depth (costs one modifyLiquidity; the LP keeps its tokens).
        uint256 g0 = gasleft();
        _lp(key, -60000, 60000, -1e20, GRIEFER_SALT);
        console2.log("griefer gas for the pull", g0 - gasleft());

        // Fixed: instead of reverting, the position is placed on the part of the
        // requested range its token0 funds alone — strictly above spot.
        vm.prank(rebalancer);
        uint128 placed = hook.rebalance(pid, lower, upper, 0);
        assertGt(placed, 0, "the depth pull no longer bricks the rebalance");
        _assertPlacedJustAboveSpot(pid, upper);
    }

    /// No attacker at all: in a pool where the hook's own positions are the only
    /// liquidity (every hooked pool is a separate v4 pool, so this is the default
    /// state of a new deployment), a position that drifts out of range can never
    /// be recentred onto a straddling range.
    function test_DS1b_hook_only_pool_cannot_recentre_out_of_range_position() public {
        bytes32 pid = _deposit(key, -600, 600, 1e18);
        // Someone trades through the position and leaves price below it.
        _swapTo(key, true, 1e30, -900);
        assertEq(_spot(id), -900);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _catchUpRef(key);

        // Fixed: the straddling request is narrowed to what the held token funds.
        vm.prank(rebalancer);
        uint128 l = hook.rebalance(pid, -1500, -300, 0);
        assertGt(l, 0);
        _assertPlacedJustAboveSpot(pid, -300);
    }

    // ------------------------------------------------------------------ DS-2

    /// The daemon's floor is 99% of the liquidity its preflight eth_call quoted
    /// (exec/mod.rs: floor = quoted * (10000 - 100) / 10000). A depth pull between
    /// the preflight and inclusion therefore turns the hook's "park the rest as
    /// idle" path back into a revert, and the daemon pays for the failed tx.
    function test_DS2_daemon_floor_turns_depth_pull_into_onchain_revert() public {
        bytes32 pid = _victimOutOfRange(1e20, 1e18);
        int24 lower = -1500;
        int24 upper = -300;

        // Daemon preflight (eth_call, minLiquidity = 0) at the thick state.
        uint256 snap = vm.snapshotState();
        vm.prank(rebalancer);
        uint128 quoted = hook.rebalance(pid, lower, upper, 0);
        vm.revertToState(snap);
        uint128 floor = uint128(uint256(quoted) * 9_900 / 10_000);
        console2.log("preflight quoted", quoted);
        console2.log("daemon floor (99%)", floor);

        // Griefer pulls its depth before the tx lands (honest 1e18 remains).
        _lp(key, -60000, 60000, -1e20, GRIEFER_SALT);

        // Since the full audit's AM2-2 fix the fallback places the position on
        // its held side when that deploys more value, so even the old 99% floor
        // no longer turns the depth pull into a revert. (The daemon now sends 0.)
        snap = vm.snapshotState();
        vm.prank(rebalancer);
        uint128 withOldFloor = hook.rebalance(pid, lower, upper, floor);
        assertGe(withOldFloor, floor);

        // The contract itself would have handled it: with no floor the
        // rebalance lands and the unplaced part is held as idle.
        vm.revertToState(snap);
        vm.prank(rebalancer);
        uint128 got = hook.rebalance(pid, lower, upper, 0);
        (uint128 i0, uint128 i1) = hook.idle(pid);
        console2.log("with floor 0: newLiquidity", got);
        console2.log("idle0", i0);
        console2.log("idle1", i1);
        assertGt(got, 0);
    }

    // ------------------------------------------------------------------ DS-3

    /// Anyone can open a hooked pool for any pair (allowlist is per pair, not per
    /// pool key), deposit dust, and then move that pool's price for free through
    /// empty ticks. The reference trails by 500 ticks per block, so one swap buys
    /// ~|move|/500 blocks of PriceDeviation — and the daemon answers every
    /// PriceDeviation refusal with a poke it pays for (exec/mod.rs poke_once).
    function test_DS3_one_free_swap_forces_many_daemon_pokes() public {
        // Attacker's own hooked pool for the same pair, different fee/spacing.
        (PoolKey memory k, PoolId pid_) = initPool(currency0, currency1, IHooks(hook), 10_000, SQRT_PRICE_1_1);
        assertEq(k.tickSpacing, 200);

        // Fixed in the contract: with the allowlist enforced (the deploy script
        // enforces it), only listed pool keys accept deposits, so an attacker
        // cannot open a hooked pool of their own for a listed pair.
        hook.setAllowedPool(key, true);
        hook.setAllowlistEnforced(true);
        vm.expectRevert(AutopilotHook.PoolNotAllowed.selector);
        hook.deposit(
            k,
            -200,
            200,
            1e9,
            TickMath.minUsableTick(200),
            TickMath.maxUsableTick(200),
            address(0),
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        hook.setAllowlistEnforced(false);

        // Measured with enforcement off, as a record of why the daemon also caps
        // its own spend.
        bytes32 dust = _deposit(k, -200, 200, 1e9); // ~1e7 wei of each token
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.roll(vm.getBlockNumber() + COOLDOWN / 12); // a chain advances blocks too
        _nextBlock();

        // Attacker swap: crosses only its own dust, then runs through empty ticks.
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        uint256 bal0 = t0.balanceOf(address(this));
        uint256 g0 = gasleft();
        _swapTo(k, true, 1e18, -800_000);
        uint256 attackerGas = g0 - gasleft();
        uint256 attackerTokens = bal0 - t0.balanceOf(address(this));
        assertEq(_spot(pid_), -800_000);
        console2.log("attacker swap gas", attackerGas);
        console2.log("attacker token0 spent (wei)", attackerTokens);

        // Daemon loop: preflight refuses with PriceDeviation -> poke -> next block.
        uint256 pokes;
        uint256 pokeGas;
        while (true) {
            _nextBlock();
            vm.prank(rebalancer);
            try hook.rebalance(dust, -800_200, -799_800, 0) {
                break;
            } catch (bytes memory err) {
                if (
                    bytes4(err) != AutopilotHook.PriceDeviation.selector
                        && bytes4(err) != AutopilotHook.PriceUnsettled.selector
                ) {
                    // Caught up: the next refusal is something else (no poke).
                    console2.log("refusal after catch-up is not PriceDeviation");
                    break;
                }
            }
            uint256 p0 = gasleft();
            vm.prank(rebalancer);
            hook.pokePriceRef(k);
            pokeGas += p0 - gasleft();
            pokes++;
            require(pokes < 5000, "runaway");
        }
        // Each poke is its own transaction: add the 21k intrinsic gas to both
        // sides. (In-test execution gas is warm, so this understates the daemon.)
        uint256 daemonTxGas = pokeGas + 21_000 * pokes;
        uint256 attackerTxGas = attackerGas + 21_000;
        console2.log("daemon pokes (txs) forced by one attacker swap", pokes);
        console2.log("daemon gas incl. intrinsic", daemonTxGas);
        console2.log("attacker gas incl. intrinsic", attackerTxGas);
        console2.log("amplification x", daemonTxGas / attackerTxGas);
        assertGt(pokes, 1500);
        assertGt(daemonTxGas, 50 * attackerTxGas, "at least 50x gas amplification");
        assertLt(attackerTokens, 1e8, "the swap cost the attacker only dust");
    }
}

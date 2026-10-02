// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AutopilotHook is BaseHook, Ownable2Step, Pausable, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    struct Position {
        address owner;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool active;
        uint64 lastRebalanceAt;
    }

    /// @dev Tokens a rebalance freed but could not redeploy, held for the
    ///      position as ERC-6909 claims on the PoolManager. They are folded into
    ///      the next rebalance and paid out on withdraw.
    struct Idle {
        uint128 amount0;
        uint128 amount1;
    }

    /// @dev `tick` follows spot but is clamped to `anchor ± maxTickMovePerBlock`,
    ///      where `anchor` is the reference as it stood when the block began. The
    ///      LAST write in a block wins: a same-block displace-and-restore ends the
    ///      block with the reference back where it started, so dragging it takes a
    ///      price held across block boundaries against arbitrage, not a free
    ///      round trip. One slot: 3 + 3 + 8 + 1 bytes.
    struct PriceRef {
        int24 tick;
        int24 anchor;
        uint64 atBlock;
        bool seeded;
    }

    enum Op {
        Deposit,
        Withdraw,
        Rebalance
    }

    struct Callback {
        Op op;
        bytes32 positionId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int24 newTickLower;
        int24 newTickUpper;
        uint128 liquidity;
        uint128 minLiquidity;
        address owner;
        address recipient;
        bool asClaims;
    }

    uint64 public constant MAX_REBALANCE_INTERVAL = 365 days;
    /// @dev A cooldown of 0 let a rebalancer loop `rebalance()` within one
    ///      transaction; an audit measured 59% of a position destroyed that way.
    uint64 public constant MIN_REBALANCE_INTERVAL = 60;
    /// @dev Ceiling on the owner-set per-rebalance value tolerance.
    uint16 public constant MAX_LOSS_TOLERANCE_BPS = 500;
    uint16 public constant MIN_LOSS_TOLERANCE_BPS = 25;
    uint16 public constant BPS = 10_000;
    /// @dev Sentinel for `positionRebalancer`: automation disabled for a position.
    address public constant AUTOMATION_OFF = address(1);
    /// @dev Ceiling on how far the reference tick may be dragged in one block,
    ///      and on the spot-vs-reference gap a rebalance will tolerate.
    int24 public constant MAX_TICK_MOVE_PER_BLOCK = 500;
    /// @dev A rebalance landing on a pushed price buys at that price, and the value
    ///      guard cannot see it: it measures both sides at the same pushed price.
    ///      So this bound, not the value guard, is the real limit on manipulation
    ///      loss. Measured worst case, onto the narrowest range the daemon picks
    ///      (one tick spacing either side of spot): 78 bps at 200 ticks, over the 1%
    ///      tolerance at anything looser (113-159 bps at 250-350); 1428 bps at the
    ///      2000 this used to be. Hence it is both the default and the cap — the owner
    ///      may only tighten it. Honest rebalances pay only a delay: after a fast move
    ///      the daemon pokes the reference up to spot, 500 ticks a block.
    int24 public constant MAX_DEVIATION_TICKS = 200;
    /// @dev Ceiling on how far the re-ratio swap may move sqrtPrice from spot.
    uint16 public constant MAX_SWAP_IMPACT_BPS = 2000;
    /// @dev Time an L2 must have been back up before rebalancing resumes. On
    ///      resumption the backlog lands at once and spot gaps to fair value in
    ///      the first blocks, which is exactly when a queued rebalance executes
    ///      against a price its simulation never saw.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;
    /// @dev Gas ceiling for the uptime-feed staticcall, so a hostile feed cannot
    ///      consume the whole block.
    uint256 public constant SEQUENCER_CALL_GAS = 100_000;
    /// @dev A price reference older than this carries no information and must not
    ///      be allowed to veto a rebalance.
    uint256 public constant PRICE_REF_STALE_AFTER = 1 hours;

    mapping(bytes32 => Position) public positions;
    /// @dev Optional per-position scope on top of the global allowlist. Zero means
    ///      "any allowlisted rebalancer"; `AUTOMATION_OFF` means none, so an owner
    ///      can opt out entirely. Adding a rebalancer globally no longer silently
    ///      grants authority over positions that predate it.
    mapping(bytes32 => address) public positionRebalancer;
    mapping(bytes32 => int24) public boundLower;
    mapping(bytes32 => int24) public boundUpper;
    mapping(PoolId => uint256) public poolPositionCount;
    /// @dev The swap inside a rebalance is bounded, so it can stop short and
    ///      leave part of the position undeployable at the new range. Paying that
    ///      part out to the owner rebuilt the position with a fraction of its
    ///      capital while every guard passed. Reverting instead would hand any LP
    ///      able to thin the pool a free way to block rebalances. So the remainder
    ///      stays with the position here until a later rebalance can place it.
    mapping(bytes32 => Idle) public idle;
    mapping(address => bool) public isRebalancer;
    /// @dev Manipulation-resistant price reference, one per pool. v4 ships no
    ///      oracle, so the hook keeps its own: the tick follows spot but may only
    ///      move `maxTickMovePerBlock` per block, which makes dragging it cost
    ///      sustained blocks rather than one flash-loaned transaction.
    mapping(PoolId => PriceRef) public priceRef;
    /// @dev Chainlink L2 uptime feed. Zero disables the check, which is correct
    ///      on L1 and wrong on Base — set it after deploying there.
    /// @dev Curated pairs. The contract cannot detect a fee-on-transfer or
    ///      rebasing token by inspection, so the restriction has to be a list
    ///      rather than a check — and an unenforced list is just a comment.
    mapping(bytes32 => bool) public allowedPair;
    /// @dev Off by default so existing deployments keep working; turn it on once
    ///      the list is populated.
    bool public allowlistEnforced;
    address public sequencerUptimeFeed;
    int24 public maxTickMovePerBlock;
    int24 public maxDeviationTicks;
    /// @dev Bounds the re-ratio swap's price impact directly, in bps of
    ///      sqrtPrice. Without it the only backstop is the after-the-fact value
    ///      guard, whose input — pool depth at execution time — any LP in the
    ///      pool controls, making a revert cheap to force and the position
    ///      un-rebalanceable.
    uint16 public maxSwapImpactBps;
    uint64 public minRebalanceInterval;
    /// @dev Share of a position's value a single rebalance may consume, in bps.
    ///      Protocol-enforced: unlike `minLiquidity` this is not chosen by the
    ///      rebalancer, so the constrained party cannot waive its own constraint.
    uint16 public maxRebalanceLossBps;
    uint256 private depositNonce;

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint24 fee,
        int24 tickSpacing
    );
    event PositionClosed(bytes32 indexed positionId, address indexed owner, uint128 liquidity);
    event Rebalanced(
        bytes32 indexed positionId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 oldLiquidity,
        uint128 newLiquidity
    );
    event AutopilotCheck(PoolId indexed poolId, int24 tick, uint256 positionCount);
    event RebalancerSet(address indexed rebalancer, bool allowed);
    event MinRebalanceIntervalSet(uint64 interval);
    event MaxRebalanceLossBpsSet(uint16 bps);
    event PriceGuardSet(int24 maxTickMovePerBlock, int24 maxDeviationTicks);
    event MaxSwapImpactBpsSet(uint16 bps);
    /// @dev Freed value the re-ratio swap could not deploy, returned to the owner
    ///      as loose tokens. A bounded swap makes a partial fill the normal
    ///      outcome in a thin pool, and silence about it is how half a position
    ///      ends up sitting outside the position.
    /// @dev The position's idle balance after a rebalance: what could not be
    ///      redeployed at the new range and is held for the next one.
    event RebalanceResidual(bytes32 indexed positionId, uint256 amount0, uint256 amount1);
    event SequencerUptimeFeedSet(address feed);
    event PairAllowed(Currency indexed currency0, Currency indexed currency1, bool allowed);
    event AllowlistEnforcedSet(bool enforced);
    event PositionRebalancerSet(bytes32 indexed positionId, address rebalancer);

    error NotPositionOwner();
    error NotRebalancer();
    error PositionNotActive();
    error InvalidTickRange();
    error TicksNotAligned();
    error RebalanceTooSoon(uint64 readyAt);
    error ZeroLiquidity();
    error NothingFreed();
    error HookMismatch();
    error SlippageExceeded(uint128 got, uint128 min);
    error IntervalTooLong();
    error OutOfBounds();
    error RenounceDisabled();
    error NativeNotSupported();
    error IntervalTooShort();
    error NoOpRebalance();
    error LossToleranceTooHigh();
    error ValueLossExceeded(uint256 valueAfter, uint256 valueBefore);
    error ZeroRecipient();
    error PriceDeviation(int24 spotTick, int24 referenceTick);
    error PriceReferenceUnseeded();
    error DeviationBoundTooHigh();
    error SequencerDown();
    error SequencerGracePeriod(uint256 readyAt);
    error PairNotAllowed();
    error AutomationDisabled();
    error FeeOnTransferNotSupported(Currency currency, uint256 expected, uint256 received);
    error FeedHasNoCode();
    error SwapImpactTooHigh();

    /// @dev `initialOwner` is explicit rather than `msg.sender`: the hook must be
    ///      deployed through the CREATE2 factory for its address to carry the
    ///      permission bits, which would otherwise make the factory the owner and
    ///      leave `pause()` and `setRebalancer()` permanently unreachable.
    constructor(IPoolManager pm, address initialOwner, address initialRebalancer, uint64 cooldown)
        BaseHook(pm)
        Ownable(initialOwner)
    {
        if (initialRebalancer != address(0)) {
            isRebalancer[initialRebalancer] = true;
            emit RebalancerSet(initialRebalancer, true);
        }
        if (cooldown > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
        if (cooldown < MIN_REBALANCE_INTERVAL) revert IntervalTooShort();
        minRebalanceInterval = cooldown;
        emit MinRebalanceIntervalSet(cooldown);

        maxRebalanceLossBps = 100; // 1%
        emit MaxRebalanceLossBpsSet(100);

        maxSwapImpactBps = 50; // 0.5% of sqrtPrice, ~1% of price
        maxTickMovePerBlock = MAX_TICK_MOVE_PER_BLOCK;
        maxDeviationTicks = MAX_DEVIATION_TICKS;
        emit PriceGuardSet(MAX_TICK_MOVE_PER_BLOCK, MAX_DEVIATION_TICKS);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        uint256 count = poolPositionCount[id];
        if (count > 0) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            _updatePriceRef(id, tick);
            emit AutopilotCheck(id, tick, count);
        }
        return (BaseHook.afterSwap.selector, int128(0));
    }

    /// @notice Open a position, leaving automation open to any allowlisted
    ///         rebalancer. Scoping it afterwards takes a second transaction; use
    ///         the overload below to express the choice atomically instead.
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 minBound,
        int24 maxBound
    ) external returns (bytes32) {
        return _deposit(key, tickLower, tickUpper, liquidity, minBound, maxBound, address(0));
    }

    /// @param rebalancer Scope for this position: `address(0)` accepts any
    ///        allowlisted rebalancer, `AUTOMATION_OFF` accepts none, any other
    ///        address accepts only that one. Setting it here rather than in a
    ///        follow-up call means a rebalancer added to the global allowlist
    ///        later never gains authority the owner did not choose.
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 minBound,
        int24 maxBound,
        address rebalancer
    ) external returns (bytes32) {
        return _deposit(key, tickLower, tickUpper, liquidity, minBound, maxBound, rebalancer);
    }

    function _deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 minBound,
        int24 maxBound,
        address rebalancer
    ) internal whenNotPaused nonReentrant returns (bytes32 positionId) {
        if (liquidity == 0) revert ZeroLiquidity();
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();
        // Checked on the way in only. Gating withdraw or rebalance would turn a
        // de-listing into a fund trap for positions already open.
        if (allowlistEnforced && !allowedPair[_pairKey(key.currency0, key.currency1)]) {
            revert PairNotAllowed();
        }
        _validateTicks(key, tickLower, tickUpper);
        _validateTicks(key, minBound, maxBound);
        if (tickLower < minBound || tickUpper > maxBound) revert OutOfBounds();

        PoolId id = key.toId();
        positionId = keccak256(abi.encode(msg.sender, id, depositNonce++));
        boundLower[positionId] = minBound;
        boundUpper[positionId] = maxBound;
        if (rebalancer != address(0)) {
            positionRebalancer[positionId] = rebalancer;
            emit PositionRebalancerSet(positionId, rebalancer);
        }

        poolManager.unlock(
            abi.encode(
                Callback({
                    op: Op.Deposit,
                    positionId: positionId,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    newTickLower: int24(0),
                    newTickUpper: int24(0),
                    liquidity: liquidity,
                    minLiquidity: 0,
                    owner: msg.sender,
                    recipient: msg.sender,
                    asClaims: false
                })
            )
        );

        positions[positionId] = Position({
            owner: msg.sender,
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            active: true,
            // Not 0: `readyAt` would then be `minRebalanceInterval`, an absolute
            // timestamp below any live chain's clock, so the first rebalance of
            // every position would bypass the cooldown entirely.
            lastRebalanceAt: uint64(block.timestamp)
        });
        if (poolPositionCount[id] == 0) {
            (, int24 spot,,) = poolManager.getSlot0(id);
            _seedPriceRef(id, spot);
        }
        poolPositionCount[id] += 1;
        emit PositionOpened(positionId, msg.sender, id, tickLower, tickUpper, liquidity, key.fee, key.tickSpacing);
    }

    /// @notice Exit to the caller, taking the underlying tokens.
    function withdraw(bytes32 positionId) external {
        _withdraw(positionId, msg.sender, false);
    }

    /// @param recipient Where the freed tokens go. A position owner frozen by a
    ///        token-level blacklist can still exit to another address.
    /// @param asClaims Take ERC-6909 claim tokens from the PoolManager instead of
    ///        the underlying. Minting a claim never calls the token, so a blacklist
    ///        or token pause on one currency cannot strand the other.
    function withdraw(bytes32 positionId, address recipient, bool asClaims) external {
        _withdraw(positionId, recipient, asClaims);
    }

    function _withdraw(bytes32 positionId, address recipient, bool asClaims) internal nonReentrant {
        if (recipient == address(0)) revert ZeroRecipient();
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.owner != msg.sender) revert NotPositionOwner();

        uint128 liquidity = pos.liquidity;
        PoolKey memory key = pos.key;
        int24 tickLower = pos.tickLower;
        int24 tickUpper = pos.tickUpper;
        PoolId id = key.toId();

        pos.active = false;
        pos.liquidity = 0;
        poolPositionCount[id] -= 1;

        poolManager.unlock(
            abi.encode(
                Callback({
                    op: Op.Withdraw,
                    positionId: positionId,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    newTickLower: int24(0),
                    newTickUpper: int24(0),
                    liquidity: liquidity,
                    minLiquidity: 0,
                    owner: msg.sender,
                    recipient: recipient,
                    asClaims: asClaims
                })
            )
        );
        emit PositionClosed(positionId, msg.sender, liquidity);
    }

    function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper, uint128 minLiquidity)
        external
        whenNotPaused
        nonReentrant
        returns (uint128 newLiquidity)
    {
        _requireRebalancerFor(positionId);
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();

        uint64 readyAt = pos.lastRebalanceAt + minRebalanceInterval;
        if (block.timestamp < readyAt) revert RebalanceTooSoon(readyAt);

        // Rebalancing onto the current range is how an idle balance gets placed,
        // so it is only a no-op when there is nothing idle to place.
        if (newTickLower == pos.tickLower && newTickUpper == pos.tickUpper) {
            Idle memory held = idle[positionId];
            if (held.amount0 == 0 && held.amount1 == 0) revert NoOpRebalance();
        }

        _requireSequencerUp();

        PoolKey memory key = pos.key;
        _requirePriceNotManipulated(key.toId());
        _validateTicks(key, newTickLower, newTickUpper);
        if (newTickLower < boundLower[positionId] || newTickUpper > boundUpper[positionId]) revert OutOfBounds();

        int24 oldLower = pos.tickLower;
        int24 oldUpper = pos.tickUpper;
        uint128 oldLiquidity = pos.liquidity;

        bytes memory ret = poolManager.unlock(
            abi.encode(
                Callback({
                    op: Op.Rebalance,
                    positionId: positionId,
                    key: key,
                    tickLower: oldLower,
                    tickUpper: oldUpper,
                    newTickLower: newTickLower,
                    newTickUpper: newTickUpper,
                    liquidity: oldLiquidity,
                    minLiquidity: minLiquidity,
                    owner: pos.owner,
                    recipient: pos.owner,
                    asClaims: false
                })
            )
        );
        newLiquidity = abi.decode(ret, (uint128));

        pos.tickLower = newTickLower;
        pos.tickUpper = newTickUpper;
        pos.liquidity = newLiquidity;
        pos.lastRebalanceAt = uint64(block.timestamp);
        emit Rebalanced(positionId, oldLower, oldUpper, newTickLower, newTickUpper, oldLiquidity, newLiquidity);
    }

    function unlockCallback(bytes calldata raw) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Callback memory cb = abi.decode(raw, (Callback));
        if (cb.op == Op.Deposit) {
            _doDeposit(cb);
            return "";
        }
        if (cb.op == Op.Withdraw) {
            _doWithdraw(cb);
            return "";
        }
        return abi.encode(_doRebalance(cb));
    }

    function _doDeposit(Callback memory cb) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: int256(uint256(cb.liquidity)),
                salt: cb.positionId
            }),
            ""
        );
        if (delta.amount0() < 0) {
            _settleExact(cb.key.currency0, cb.owner, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleExact(cb.key.currency1, cb.owner, uint256(uint128(-delta.amount1())));
        }
    }

    /// @dev Settles and checks the PoolManager actually received the full amount.
    ///      A fee-on-transfer token delivers less, which v4 would surface much
    ///      later as an opaque `CurrencyNotSettled` from inside `unlock` — true,
    ///      but useless to whoever is trying to work out why their deposit failed.
    function _settleExact(Currency currency, address payer, uint256 amount) private {
        // The credited figure comes from `settle()` itself rather than a
        // before/after balanceOf diff: the PoolManager's global balance can move
        // for reasons unrelated to this payer, and a decrease would underflow into
        // a bare Panic(0x11) — worse diagnostics than the error it replaces.
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid < amount) revert FeeOnTransferNotSupported(currency, amount, paid);
    }

    function _doWithdraw(Callback memory cb) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: -int256(uint256(cb.liquidity)),
                salt: cb.positionId
            }),
            ""
        );
        (uint256 held0, uint256 held1) = _releaseIdle(cb);
        uint256 out0 = (delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0) + held0;
        uint256 out1 = (delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0) + held1;
        if (out0 > 0) cb.key.currency0.take(poolManager, cb.recipient, out0, cb.asClaims);
        if (out1 > 0) cb.key.currency1.take(poolManager, cb.recipient, out1, cb.asClaims);
    }

    /// @dev Burns the position's held claims, crediting this unlock with them,
    ///      and clears the record. The caller must spend or re-hold the credit.
    function _releaseIdle(Callback memory cb) private returns (uint256 held0, uint256 held1) {
        Idle memory held = idle[cb.positionId];
        held0 = held.amount0;
        held1 = held.amount1;
        if (held0 == 0 && held1 == 0) return (0, 0);
        delete idle[cb.positionId];
        if (held0 > 0) poolManager.burn(address(this), cb.key.currency0.toId(), held0);
        if (held1 > 0) poolManager.burn(address(this), cb.key.currency1.toId(), held1);
    }

    function _doRebalance(Callback memory cb) internal returns (uint128 newLiquidity) {
        (BalanceDelta removed,) = poolManager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: -int256(uint256(cb.liquidity)),
                salt: cb.positionId
            }),
            ""
        );
        (uint256 held0, uint256 held1) = _releaseIdle(cb);
        uint256 freed0 = (removed.amount0() > 0 ? uint256(uint128(removed.amount0())) : 0) + held0;
        uint256 freed1 = (removed.amount1() > 0 ? uint256(uint128(removed.amount1())) : 0) + held1;
        if (freed0 == 0 && freed1 == 0) revert NothingFreed();

        // Value the holdings BEFORE the swap, at the price before the swap moves
        // it. Measuring both sides against the same untouched price is what makes
        // this a bound on the cost of the rebalance itself rather than a number
        // the swap can move underneath the check.
        (uint160 sqrtBefore,,,) = poolManager.getSlot0(cb.key.toId());
        uint256 valueBefore = _inToken1(freed0, sqrtBefore) + freed1;

        // A position that has drifted out of range is entirely one token, but
        // a range straddling the current price needs both. Without this swap
        // the redeposit below would compute zero liquidity and revert — which
        // is precisely the case a rebalance exists to handle.
        BalanceDelta swapped = _swapToRatio(cb, sqrtBefore, freed0, freed1);
        freed0 = _add(freed0, swapped.amount0());
        freed1 = _add(freed1, swapped.amount1());

        // Everything between the two measurements is the swap: its fee and its
        // price impact. Cap that at an owner-set tolerance the rebalancer cannot
        // raise, so a manipulated or adversarial fill reverts instead of settling.
        _guardValueLoss(valueBefore, _inToken1(freed0, sqrtBefore) + freed1);

        {
            (uint160 sqrtNow,,,) = poolManager.getSlot0(cb.key.toId());
            newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtNow,
                TickMath.getSqrtPriceAtTick(cb.newTickLower),
                TickMath.getSqrtPriceAtTick(cb.newTickUpper),
                freed0,
                freed1
            );
        }
        if (newLiquidity == 0) revert ZeroLiquidity();
        if (newLiquidity < cb.minLiquidity) revert SlippageExceeded(newLiquidity, cb.minLiquidity);

        (BalanceDelta added,) = poolManager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.newTickLower,
                tickUpper: cb.newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity)),
                salt: cb.positionId
            }),
            ""
        );

        // Whatever could not be placed stays with the position as claims. `freed`
        // already counts the released idle balance and the swap, so subtracting
        // what the new range consumed is the whole remainder.
        _holdIdle(cb, _sub(freed0, added.amount0()), _sub(freed1, added.amount1()));
    }

    function _holdIdle(Callback memory cb, uint256 left0, uint256 left1) private {
        if (left0 > 0) poolManager.mint(address(this), cb.key.currency0.toId(), left0);
        if (left1 > 0) poolManager.mint(address(this), cb.key.currency1.toId(), left1);
        if (left0 > 0 || left1 > 0) {
            idle[cb.positionId] = Idle(SafeCast.toUint128(left0), SafeCast.toUint128(left1));
            emit RebalanceResidual(cb.positionId, left0, left1);
        }
    }

    /// @dev `base` less what an add-liquidity delta consumed (a negative delta).
    function _sub(uint256 base, int128 consumed) private pure returns (uint256) {
        if (consumed >= 0) return base + uint256(uint128(consumed));
        return base - uint256(uint128(-consumed));
    }

    /// @dev Swaps the surplus side so the freed tokens roughly match the ratio
    ///      the new range wants. Sizing is a first-order estimate at the
    ///      current price: exactness is not required because any residual is
    ///      returned to the owner, and the caller's `minLiquidity` floor is
    ///      what actually bounds an adverse fill.
    function _swapToRatio(Callback memory cb, uint160 sqrtPriceX96, uint256 have0, uint256 have1)
        internal
        returns (BalanceDelta)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(cb.newTickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(cb.newTickUpper);

        bool zeroForOne;
        uint256 amountIn;

        // Strict: at spot == sqrtA or spot == sqrtB the one-sided branches would
        // dump a whole side and then aim the price limit at the *far* boundary,
        // traversing the entire range and landing on newLiquidity == 0. The
        // straddle branch handles equality correctly.
        if (sqrtPriceX96 < sqrtA) {
            // Range sits entirely above spot: it is funded with token0 only.
            if (have1 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
            (zeroForOne, amountIn) = (false, have1);
        } else if (sqrtPriceX96 > sqrtB) {
            // Range sits entirely below spot: token1 only.
            if (have0 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
            (zeroForOne, amountIn) = (true, have0);
        } else {
            (zeroForOne, amountIn) = _straddleSwap(sqrtPriceX96, sqrtA, sqrtB, cb.liquidity, have0, have1);
        }

        if (amountIn == 0) return BalanceDeltaLibrary.ZERO_DELTA;

        // Bound the fill at the first boundary of the target range lying in the
        // direction of travel. Without a limit the swap runs after this position's
        // own liquidity has already been burned, so in a pool this hook dominates it
        // walks the price to the tick extreme and hands the position to the first
        // arbitrageur. Stopping at the boundary caps impact at the range width and
        // leaves the price inside the range being funded; a partial fill is fine,
        // because leftover dust is returned to the owner below.
        uint160 limit = _swapPriceLimit(sqrtPriceX96, sqrtA, sqrtB, zeroForOne);
        if (limit == 0) return BalanceDeltaLibrary.ZERO_DELTA;

        BalanceDelta first = poolManager.swap(
            cb.key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            ""
        );
        return first
            + _correctOvershoot(
            cb, [sqrtPriceX96, sqrtA, sqrtB], _add(have0, first.amount0()), _add(have1, first.amount1()), zeroForOne
        );
    }

    /// @dev The first leg is sized at the pre-swap price, and its own impact moves
    ///      price the way that makes the range want more of what was just sold, so
    ///      it tends to overshoot (the fee pulls the other way). From a range edge
    ///      it sells everything and leaves nothing for the side the range needs
    ///      once price is inside, which computes to zero liquidity. One corrective
    ///      leg, re-sized at the post-swap price, fixes an overshoot. It only runs
    ///      in the reverse direction: it moves price back toward where it started,
    ///      so it cannot widen the impact the first leg was bounded to. An
    ///      undershoot is left alone and ends up in the idle balance.
    /// @param prices [spot before the first leg, range lower, range upper].
    function _correctOvershoot(
        Callback memory cb,
        uint160[3] memory prices,
        uint256 have0,
        uint256 have1,
        bool firstZeroForOne
    ) private returns (BalanceDelta) {
        (uint160 origin, uint160 sqrtA, uint160 sqrtB) = (prices[0], prices[1], prices[2]);
        (uint160 sqrtNow,,,) = poolManager.getSlot0(cb.key.toId());
        if (sqrtNow <= sqrtA || sqrtNow >= sqrtB) return BalanceDeltaLibrary.ZERO_DELTA;

        (bool zeroForOne, uint256 amountIn) = _straddleSwap(sqrtNow, sqrtA, sqrtB, cb.liquidity, have0, have1);
        if (amountIn == 0 || zeroForOne == firstZeroForOne) return BalanceDeltaLibrary.ZERO_DELTA;

        uint160 limit = _swapPriceLimit(sqrtNow, sqrtA, sqrtB, zeroForOne);
        if (limit == 0) return BalanceDeltaLibrary.ZERO_DELTA;
        // Never back past where the rebalance started.
        if (zeroForOne ? limit < origin : limit > origin) limit = origin;
        if (zeroForOne ? limit >= sqrtNow : limit <= sqrtNow) return BalanceDeltaLibrary.ZERO_DELTA;
        return poolManager.swap(
            cb.key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            ""
        );
    }

    /// @dev Sizes the swap when the target range straddles spot: values both the
    ///      holdings and the range's required split in token1 terms at the current
    ///      price, then trades the difference. A first-order estimate is enough —
    ///      residual dust returns to the owner and the value guard bounds the fill.
    function _straddleSwap(uint160 spot, uint160 sqrtA, uint160 sqrtB, uint128 liquidity, uint256 have0, uint256 have1)
        private
        pure
        returns (bool zeroForOne, uint256 amountIn)
    {
        uint256 want0 = SqrtPriceMath.getAmount0Delta(spot, sqrtB, liquidity, false);
        uint256 want1 = SqrtPriceMath.getAmount1Delta(sqrtA, spot, liquidity, false);

        uint256 haveValue = _inToken1(have0, spot) + have1;
        uint256 wantValue = _inToken1(want0, spot) + want1;
        if (haveValue == 0 || wantValue == 0) return (false, 0);

        uint256 target1 = FullMath.mulDiv(haveValue, want1, wantValue);
        if (target1 > have1) {
            uint256 sell0 = _inToken0(target1 - have1, spot);
            if (sell0 > have0) sell0 = have0;
            return (true, sell0);
        }
        return (false, have1 - target1);
    }

    /// @dev First boundary of [sqrtA, sqrtB] strictly beyond `spot` in the swap's
    ///      direction. Returns 0 when no such boundary exists, meaning the swap
    ///      would move price away from the target range and must be skipped.
    ///      v4 reverts `PriceLimitAlreadyExceeded` unless the limit is strictly on
    ///      the correct side of spot, hence the strict comparisons.
    function _swapPriceLimit(uint160 spot, uint160 sqrtA, uint160 sqrtB, bool zeroForOne)
        internal
        view
        returns (uint160)
    {
        uint160 edge = zeroForOne
            ? (sqrtB < spot ? sqrtB : sqrtA)  // highest boundary below spot
            : (sqrtA > spot ? sqrtA : sqrtB); // lowest boundary above spot

        // v4 rejects a limit sitting exactly on MIN/MAX_SQRT_PRICE, and
        // `_validateTicks` permits min/maxUsableTick — which equal MIN/MAX_TICK
        // for tick spacings 1, 2, 4 and 8. Nudge inside the open interval rather
        // than reverting a rebalance that worked before this limit existed.
        // Take whichever bound is tighter: the range boundary, or a fixed
        // deviation from spot. The range boundary alone is not a bound on impact
        // — in a pool thin enough, reaching it IS a large move — and an LP can
        // make the pool that thin for one block at no cost.
        uint256 bps = maxSwapImpactBps;
        if (zeroForOne) {
            uint160 impact = uint160((uint256(spot) * (BPS - bps)) / BPS);
            uint160 limit = edge > impact ? edge : impact;
            if (limit >= spot) return 0;
            return limit <= TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE + 1 : limit;
        }
        uint160 impactUp = uint160((uint256(spot) * (BPS + bps)) / BPS);
        uint160 limitUp = edge < impactUp ? edge : impactUp;
        if (limitUp <= spot) return 0;
        return limitUp >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : limitUp;
    }

    /// @dev Reverts when a rebalance consumed more of the position's value than
    ///      the owner-set tolerance allows. Both figures must be measured at the
    ///      same price for the comparison to mean anything.
    function _guardValueLoss(uint256 valueBefore, uint256 valueAfter) private view {
        // mulDiv rather than two multiplications: `valueBefore` scales with the
        // square of sqrtPriceX96, so `valueBefore * BPS` can overflow at extreme
        // prices and revert a rebalance the guard was meant to merely measure.
        if (valueAfter < FullMath.mulDiv(valueBefore, BPS - maxRebalanceLossBps, BPS)) {
            revert ValueLossExceeded(valueAfter, valueBefore);
        }
    }

    function _inToken1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 half = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(half, sqrtPriceX96, FixedPoint96.Q96);
    }

    function _inToken0(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 half = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(half, FixedPoint96.Q96, sqrtPriceX96);
    }

    function _add(uint256 base, int128 delta) private pure returns (uint256) {
        if (delta >= 0) return base + uint256(uint128(delta));
        uint256 sub = uint256(uint128(-delta));
        return base > sub ? base - sub : 0;
    }

    /// @dev Advances the pool's reference tick toward spot, at most once per block
    ///      and by at most `maxTickMovePerBlock`. Clamping is the whole point: an
    ///      attacker who moves spot arbitrarily far in one transaction moves the
    ///      reference by one capped step, so the deviation guard still fires.
    function _updatePriceRef(PoolId id, int24 spot) internal {
        PriceRef memory ref = priceRef[id];
        if (!ref.seeded) {
            _seedPriceRef(id, spot);
            return;
        }
        bool newBlock = ref.atBlock != block.number;
        if (newBlock) {
            // Last block's final value becomes this block's anchor.
            ref.anchor = ref.tick;
            ref.atBlock = uint64(block.number);
        }
        int24 cap = maxTickMovePerBlock;
        int24 next = spot;
        if (next > ref.anchor + cap) next = ref.anchor + cap;
        else if (next < ref.anchor - cap) next = ref.anchor - cap;
        // Every swapper in the pool pays for this write, so skip it when it would
        // change nothing — common once spot sits beyond the cap for the block.
        if (!newBlock && next == ref.tick) return;
        ref.tick = next;
        priceRef[id] = ref;
    }

    /// @dev Called when a pool gains its first position. Reseeding here — not on
    ///      the first swap — means no third party chooses the anchor, and a
    ///      reference left frozen while the pool had no positions is replaced
    ///      rather than trusted.
    function _seedPriceRef(PoolId id, int24 spot) internal {
        priceRef[id] = PriceRef({tick: spot, anchor: spot, atBlock: uint64(block.number), seeded: true});
    }

    /// @notice Advance a pool's reference one capped step toward spot. Anyone may
    ///         call it; it is rate-limited to one step per block, so it gives an
    ///         attacker nothing a dust swap would not. Its purpose is liveness: on
    ///         a pool that went quiet after a large move, nothing else would ever
    ///         pull the reference back toward spot, and every rebalance there would
    ///         stay blocked with no deadline.
    function pokePriceRef(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (poolPositionCount[id] == 0) return;
        (, int24 spot,,) = poolManager.getSlot0(id);
        _updatePriceRef(id, spot);
    }

    /// @dev On an L2, refuses to act while the sequencer is down or has only just
    ///      come back. A zero feed disables the check for L1 deployments.
    /// @dev The feed address is owner-set, so this call is only as well-behaved
    ///      as whatever is deployed there. A bare high-level call would let a
    ///      reverting, retired or returndata-bombing feed halt every rebalance —
    ///      a measured 4.1M gas for a 1MB response. Bound the gas, bound the
    ///      returndata, and treat any malformed answer as "check unavailable"
    ///      rather than propagating it.
    function _requireSequencerUp() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;

        (bool ok, bytes memory data) =
            feed.staticcall{gas: SEQUENCER_CALL_GAS}(abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector));
        // A feed that cannot answer tells us nothing about the sequencer. Failing
        // open here is deliberate: the alternative hands whoever controls that
        // address a protocol-wide kill switch.
        if (!ok || data.length != 160) return;

        (, int256 answer, uint256 startedAt,,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        // 0 == up, 1 == down. startedAt == 0 means the round has not started.
        if (answer != 0 || startedAt == 0) revert SequencerDown();
        uint256 readyAt = startedAt + SEQUENCER_GRACE_PERIOD;
        if (block.timestamp < readyAt) revert SequencerGracePeriod(readyAt);
    }

    /// @dev Refuses to act while spot is far from the reference. A rebalance moves
    ///      real value at whatever price it finds, so a price the hook cannot
    ///      corroborate is a reason to wait, not to trade.
    function _requirePriceNotManipulated(PoolId id) internal view {
        PriceRef memory ref = priceRef[id];
        // Seeding at the first deposit makes this unreachable for any pool with a
        // position, so reaching it means an invariant broke: fail closed.
        if (!ref.seeded) revert PriceReferenceUnseeded();
        // Compare against where the reference stood when this block began, not
        // its intra-block value, which a swap earlier in this block may have moved.
        int24 anchor = ref.atBlock == block.number ? ref.anchor : ref.tick;
        (, int24 spotTick,,) = poolManager.getSlot0(id);
        int24 diff = spotTick > anchor ? spotTick - anchor : anchor - spotTick;
        if (diff > maxDeviationTicks) revert PriceDeviation(spotTick, anchor);
    }

    function _validateTicks(PoolKey memory key, int24 tickLower, int24 tickUpper) internal pure {
        int24 spacing = key.tickSpacing;
        if (spacing <= 0) revert InvalidTickRange();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert TicksNotAligned();
        if (tickLower < TickMath.minUsableTick(spacing) || tickUpper > TickMath.maxUsableTick(spacing)) {
            revert InvalidTickRange();
        }
    }

    /// @dev Global allowlist plus the position owner's optional scope.
    function _requireRebalancerFor(bytes32 positionId) internal view {
        if (!isRebalancer[msg.sender]) revert NotRebalancer();
        address scoped = positionRebalancer[positionId];
        if (scoped == AUTOMATION_OFF) revert AutomationDisabled();
        if (scoped != address(0) && scoped != msg.sender) revert NotRebalancer();
    }

    /// @notice Restrict which rebalancer may act on a position, or disable
    ///         automation for it entirely with `AUTOMATION_OFF`.
    function setPositionRebalancer(bytes32 positionId, address rebalancer) external {
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        positionRebalancer[positionId] = rebalancer;
        emit PositionRebalancerSet(positionId, rebalancer);
    }

    function setRebalancer(address rebalancer, bool allowed) external onlyOwner {
        isRebalancer[rebalancer] = allowed;
        emit RebalancerSet(rebalancer, allowed);
    }

    function setMaxSwapImpactBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_SWAP_IMPACT_BPS) revert SwapImpactTooHigh();
        maxSwapImpactBps = bps;
        emit MaxSwapImpactBpsSet(bps);
    }

    function setMaxRebalanceLossBps(uint16 bps) external onlyOwner {
        // Floored as well as capped: a tolerance below the pool fee makes every
        // rebalance revert, which is a protocol-wide off-switch wearing the
        // costume of a safety parameter.
        if (bps < MIN_LOSS_TOLERANCE_BPS || bps > MAX_LOSS_TOLERANCE_BPS) revert LossToleranceTooHigh();
        maxRebalanceLossBps = bps;
        emit MaxRebalanceLossBpsSet(bps);
    }

    function setAllowedPair(Currency currency0, Currency currency1, bool allowed) external onlyOwner {
        allowedPair[_pairKey(currency0, currency1)] = allowed;
        emit PairAllowed(currency0, currency1, allowed);
    }

    function setAllowlistEnforced(bool enforced) external onlyOwner {
        allowlistEnforced = enforced;
        emit AllowlistEnforcedSet(enforced);
    }

    /// @dev Order-independent. v4 guarantees `currency0 < currency1` at the
    ///      deposit lookup, but the setter accepts either order, and hashing them
    ///      as given would write a key nothing ever reads while still emitting a
    ///      success event — a mitigation that looks deployed and is not.
    function _pairKey(Currency currency0, Currency currency1) private pure returns (bytes32) {
        (Currency a, Currency b) =
            Currency.unwrap(currency0) < Currency.unwrap(currency1) ? (currency0, currency1) : (currency1, currency0);
        return keccak256(abi.encode(a, b));
    }

    function setSequencerUptimeFeed(address feed) external onlyOwner {
        if (feed != address(0) && feed.code.length == 0) revert FeedHasNoCode();
        sequencerUptimeFeed = feed;
        emit SequencerUptimeFeedSet(feed);
    }

    function setPriceGuard(int24 movePerBlock, int24 deviation) external onlyOwner {
        if (movePerBlock <= 0 || deviation <= 0) revert DeviationBoundTooHigh();
        if (movePerBlock > MAX_TICK_MOVE_PER_BLOCK || deviation > MAX_DEVIATION_TICKS) {
            revert DeviationBoundTooHigh();
        }
        maxTickMovePerBlock = movePerBlock;
        maxDeviationTicks = deviation;
        emit PriceGuardSet(movePerBlock, deviation);
    }

    function setMinRebalanceInterval(uint64 interval) external onlyOwner {
        if (interval > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
        if (interval < MIN_REBALANCE_INTERVAL) revert IntervalTooShort();
        minRebalanceInterval = interval;
        emit MinRebalanceIntervalSet(interval);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

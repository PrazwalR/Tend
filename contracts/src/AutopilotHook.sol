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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AutopilotHook is BaseHook, Ownable2Step, Pausable, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    struct Position {
        address owner;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool active;
        uint64 lastRebalanceAt;
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
    uint16 public constant BPS = 10_000;

    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => int24) public boundLower;
    mapping(bytes32 => int24) public boundUpper;
    mapping(PoolId => uint256) public poolPositionCount;
    mapping(address => bool) public isRebalancer;
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
            emit AutopilotCheck(id, tick, count);
        }
        return (BaseHook.afterSwap.selector, int128(0));
    }

    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 minBound,
        int24 maxBound
    ) external whenNotPaused nonReentrant returns (bytes32 positionId) {
        if (liquidity == 0) revert ZeroLiquidity();
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();
        _validateTicks(key, tickLower, tickUpper);
        _validateTicks(key, minBound, maxBound);
        if (tickLower < minBound || tickUpper > maxBound) revert OutOfBounds();

        PoolId id = key.toId();
        positionId = keccak256(abi.encode(msg.sender, id, depositNonce++));
        boundLower[positionId] = minBound;
        boundUpper[positionId] = maxBound;

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
        if (!isRebalancer[msg.sender]) revert NotRebalancer();
        Position storage pos = positions[positionId];
        if (!pos.active) revert PositionNotActive();

        uint64 readyAt = pos.lastRebalanceAt + minRebalanceInterval;
        if (block.timestamp < readyAt) revert RebalanceTooSoon(readyAt);

        if (newTickLower == pos.tickLower && newTickUpper == pos.tickUpper) revert NoOpRebalance();

        PoolKey memory key = pos.key;
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
            cb.key.currency0.settle(poolManager, cb.owner, uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            cb.key.currency1.settle(poolManager, cb.owner, uint256(uint128(-delta.amount1())), false);
        }
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
        if (delta.amount0() > 0) {
            cb.key.currency0.take(poolManager, cb.recipient, uint256(uint128(delta.amount0())), cb.asClaims);
        }
        if (delta.amount1() > 0) {
            cb.key.currency1.take(poolManager, cb.recipient, uint256(uint128(delta.amount1())), cb.asClaims);
        }
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
        uint256 freed0 = removed.amount0() > 0 ? uint256(uint128(removed.amount0())) : 0;
        uint256 freed1 = removed.amount1() > 0 ? uint256(uint128(removed.amount1())) : 0;
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

        // Whatever the ratio maths left over is dust; it goes back to the owner
        // rather than accumulating in the hook.
        BalanceDelta net = removed + swapped + added;
        if (net.amount0() > 0) {
            cb.key.currency0.take(poolManager, cb.owner, uint256(uint128(net.amount0())), false);
        }
        if (net.amount1() > 0) {
            cb.key.currency1.take(poolManager, cb.owner, uint256(uint128(net.amount1())), false);
        }
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

        if (sqrtPriceX96 <= sqrtA) {
            // Range sits entirely above spot: it is funded with token0 only.
            if (have1 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
            (zeroForOne, amountIn) = (false, have1);
        } else if (sqrtPriceX96 >= sqrtB) {
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
        pure
        returns (uint160)
    {
        uint160 edge = zeroForOne
            ? (sqrtB < spot ? sqrtB : sqrtA)  // highest boundary below spot
            : (sqrtA > spot ? sqrtA : sqrtB); // lowest boundary above spot
        if (zeroForOne) return edge < spot ? edge : 0;
        return edge > spot ? edge : 0;
    }

    /// @dev Reverts when a rebalance consumed more of the position's value than
    ///      the owner-set tolerance allows. Both figures must be measured at the
    ///      same price for the comparison to mean anything.
    function _guardValueLoss(uint256 valueBefore, uint256 valueAfter) private view {
        if (valueAfter * BPS < valueBefore * (BPS - maxRebalanceLossBps)) {
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

    function _validateTicks(PoolKey memory key, int24 tickLower, int24 tickUpper) internal pure {
        int24 spacing = key.tickSpacing;
        if (spacing <= 0) revert InvalidTickRange();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert TicksNotAligned();
        if (tickLower < TickMath.minUsableTick(spacing) || tickUpper > TickMath.maxUsableTick(spacing)) {
            revert InvalidTickRange();
        }
    }

    function setRebalancer(address rebalancer, bool allowed) external onlyOwner {
        isRebalancer[rebalancer] = allowed;
        emit RebalancerSet(rebalancer, allowed);
    }

    function setMaxRebalanceLossBps(uint16 bps) external onlyOwner {
        if (bps > MAX_LOSS_TOLERANCE_BPS) revert LossToleranceTooHigh();
        maxRebalanceLossBps = bps;
        emit MaxRebalanceLossBpsSet(bps);
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

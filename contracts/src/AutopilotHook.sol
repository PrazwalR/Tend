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
    }

    uint64 public constant MAX_REBALANCE_INTERVAL = 365 days;

    mapping(bytes32 => Position) public positions;
    mapping(bytes32 => int24) public boundLower;
    mapping(bytes32 => int24) public boundUpper;
    mapping(PoolId => uint256) public poolPositionCount;
    mapping(address => bool) public isRebalancer;
    uint64 public minRebalanceInterval;
    uint256 private depositNonce;

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
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

    constructor(IPoolManager pm, address initialRebalancer, uint64 cooldown)
        BaseHook(pm)
        Ownable(msg.sender)
    {
        if (initialRebalancer != address(0)) {
            isRebalancer[initialRebalancer] = true;
            emit RebalancerSet(initialRebalancer, true);
        }
        if (cooldown > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
        minRebalanceInterval = cooldown;
        emit MinRebalanceIntervalSet(cooldown);
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
                    owner: msg.sender
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
            lastRebalanceAt: 0
        });
        poolPositionCount[id] += 1;
        emit PositionOpened(positionId, msg.sender, id, tickLower, tickUpper, liquidity);
    }

    function withdraw(bytes32 positionId) external nonReentrant {
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
                    owner: msg.sender
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
                    owner: pos.owner
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
            cb.key.currency0.take(poolManager, cb.owner, uint256(uint128(delta.amount0())), false);
        }
        if (delta.amount1() > 0) {
            cb.key.currency1.take(poolManager, cb.owner, uint256(uint128(delta.amount1())), false);
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

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cb.key.toId());
        newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(cb.newTickLower),
            TickMath.getSqrtPriceAtTick(cb.newTickUpper),
            freed0,
            freed1
        );
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

        BalanceDelta net = removed + added;
        if (net.amount0() > 0) {
            cb.key.currency0.take(poolManager, cb.owner, uint256(uint128(net.amount0())), false);
        }
        if (net.amount1() > 0) {
            cb.key.currency1.take(poolManager, cb.owner, uint256(uint128(net.amount1())), false);
        }
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

    function setMinRebalanceInterval(uint64 interval) external onlyOwner {
        if (interval > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
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

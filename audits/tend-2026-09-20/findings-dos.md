# AutopilotHook — DoS & Griefing Findings

**Scope**: `/Users/prazw/Desktop/Web3/Tend/contracts/src/AutopilotHook.sol` (484 lines), audited against the `evm-audit-dos` checklist (gas griefing, unbounded loops, revert-based DoS, block stuffing / time-based DoS, economic griefing, pause DoS, oracle DoS). Supporting reads: `/Users/prazw/Desktop/Web3/Tend/contracts/test/AutopilotHook.t.sol` and the vendored dependencies under `/Users/prazw/Desktop/Web3/Tend/contracts/lib/uniswap-hooks/`.

**Summary**: The shared-cost surface is clean. I verified from the vendored source that `_afterSwap` (lines 127-139) is genuinely O(1) and cannot revert: `poolManager.getSlot0` resolves to `Extsload.extsload`, a bare `sload` + `return` that has no revert path, and the `AutopilotCheck` event is fixed-width. There are no arrays and no loops anywhere in the contract — that claim holds. `poolPositionCount[id] -= 1` in `withdraw()` cannot underflow, because the decrement is gated behind the one-shot `pos.active` flag under `nonReentrant`, and the `PoolId` used to decrement is derived from the same stored `pos.key` that was used to increment. `withdraw()` is correctly *not* `whenNotPaused`, so the owner cannot pause users out of their funds. The real DoS surface is concentrated in `rebalance()` / `_swapToRatio()`: the internal swap runs with `sqrtPriceLimitX96` pinned to the absolute tick bounds (lines 430) *after* the position's own liquidity has been removed from the pool, so a third party can reliably force `ZeroLiquidity` or `SlippageExceeded` and pin a position out of range, and in a thin pool the rebalance path can be structurally unusable. Separately, `withdraw()` and `_doRebalance()` deliver tokens only to `pos.owner` with no alternate recipient and no ERC-6909 escape hatch, so a token-level freeze on that owner strands the *other* token of the pair too. No Critical or High issues were found: every DoS identified is either recoverable by retry, self-inflicted, reversible by an external issuer, or reachable only by the privileged owner/rebalancer.

## Findings by severity

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 4 | D-1, D-2, D-3, D-4 |
| Low | 4 | D-5, D-6, D-7, D-8 |
| Info | 4 | D-9, D-10, D-11, D-12 |
| **Total** | **12** | |

---

## [D-1] Front-running `rebalance()` reliably forces `ZeroLiquidity` / `SlippageExceeded`, pinning a position out of range
**Severity**: Medium
**Category**: dos
**Location**: `_swapToRatio()` — `contracts/src/AutopilotHook.sol:425-433`, consumed by `_doRebalance()` at lines 342-355
**Description**: `_swapToRatio` issues `poolManager.swap` with `sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1` — i.e. no price bound at all. That swap executes *after* `_doRebalance` has already removed 100% of the position's own liquidity (lines 324-333), so it trades against a pool that the hook itself has just made thinner. The post-swap price is then re-read at line 346 and fed straight into `LiquidityAmounts.getLiquidityForAmounts`, whose result must clear two reverts: `if (newLiquidity == 0) revert ZeroLiquidity()` (line 354) and `if (newLiquidity < cb.minLiquidity) revert SlippageExceeded(...)` (line 355). Because the swap has no limit, an attacker who moves spot price in the same block fully controls where the post-swap price lands relative to `cb.newTickLower` / `cb.newTickUpper`, and therefore controls whether either revert fires. There is an additional self-inflicted variant with no attacker at all: in the `sqrtPriceX96 <= sqrtA` branch (lines 392-395) the hook converts the *entire* `have1` balance into token0 via a `zeroForOne = false` swap, which pushes price **up** — potentially past `sqrtA` and into the new range. Once price is inside the range, `getLiquidityForAmounts` takes `min(liquidity0, liquidity1)`, and `liquidity1` is computed from a `freed1` that the swap just drained to ~0, so `newLiquidity` collapses toward 0 and line 354 reverts. The symmetric overshoot exists in the `sqrtPriceX96 >= sqrtB` branch (lines 396-399).
**Proof of Concept**:
1. Bot submits `rebalance(positionId, newLower, newUpper, minLiquidity)` for a position that has drifted out of range.
2. Attacker front-runs with a swap in the same pool that shifts spot price so that, after the hook's own unlimited `_swapToRatio` swap, the resulting `sqrtPriceX96` sits on the far side of `newLower`/`newUpper` from where the bot sized `minLiquidity`.
3. `_doRebalance` reverts at line 354 (`ZeroLiquidity`) or line 355 (`SlippageExceeded`). The entire `unlock` reverts, so `pos.lastRebalanceAt` is **not** updated (it is only written at line 267, after a successful `unlock`).
4. Attacker back-runs to restore their own price exposure, paying only the round-trip swap fee.
**Unavailability**: the position stays at its old, out-of-range ticks for as long as the attacker keeps paying to repeat step 2 — earning zero fees the whole time. This is **temporary, not permanent**: the cooldown is not consumed by a reverted attempt, so the bot can retry immediately, with different ticks, or in a private mempool/bundle. Deposits and withdrawals are unaffected. Rated Medium, not High, for exactly that reason.
**Recommendation**: Bound the internal swap and stop trading through the whole book. Pass an explicit price limit derived from the caller's intent rather than the tick extremes, and let the caller supply it alongside `minLiquidity`:
```solidity
// in Callback, add: uint160 sqrtPriceLimitX96;
return poolManager.swap(
    cb.key,
    SwapParams({
        zeroForOne: zeroForOne,
        amountSpecified: -int256(amountIn),
        sqrtPriceLimitX96: cb.sqrtPriceLimitX96 // rebalancer-supplied, validated non-zero
    }),
    ""
);
```
Additionally, cap `amountIn` in the one-sided branches (lines 392-399) so a single rebalance cannot move price across its own target boundary, and submit rebalances through a private relay / Flashbots-style bundle on mainnet.

## [D-2] `rebalance()` is structurally unusable when the hook's position is the pool's dominant liquidity
**Severity**: Medium
**Category**: dos
**Location**: `_doRebalance()` / `_swapToRatio()` — `contracts/src/AutopilotHook.sol:324-355`
**Description**: `_doRebalance` removes the position's full liquidity first, then relies on `_swapToRatio` finding counterparty depth in the *same* pool to convert the one-sided proceeds. If this position is the only (or overwhelmingly dominant) liquidity in that pool, the post-removal pool has nothing to swap against: `poolManager.swap` walks the price to the `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` limit, fills approximately nothing, and returns a near-zero `BalanceDelta`. `freed0`/`freed1` therefore stay one-sided, and at line 347 `getLiquidityForAmounts` for a target range on the wrong side of spot returns 0 via `getLiquidityForAmount0(_, _, 0)` or `getLiquidityForAmount1(_, _, 0)`, tripping `revert ZeroLiquidity()` at line 354. Note this is a *partial* confirmation: I verified the code path and the `LiquidityAmounts` rounding/branching from the vendored source, but I did not execute a Foundry PoC against a zero-liquidity `Pool.swap` to confirm the exact returned delta when the limit is reached with nothing filled. The severity is set conservatively for that reason.
**Proof of Concept**:
1. A user deposits into a freshly-initialised pool where this hook's position is effectively the only liquidity — a common state for a new pair on Base.
2. Price drifts out of the position's range; the position is now 100% one token.
3. Rebalancer calls `rebalance(...)`. Liquidity is removed, `_swapToRatio` cannot fill, `newLiquidity` computes to 0, and the call reverts with `ZeroLiquidity`.
**Unavailability**: `rebalance()` for that position is unavailable for as long as the pool lacks independent counterparty depth — potentially indefinitely, and with no attacker involvement. It is **not** a permanent lock of funds: `withdraw()` is on a completely separate path (`_doWithdraw`, lines 304-321) that performs no swap and no liquidity re-add, so the owner can always exit. Rated Medium: degraded behaviour and an unusable core feature, not fund loss.
**Recommendation**: Do not force the conversion through the same pool inside the same unlock. Either (a) allow a rebalance that skips `_swapToRatio` entirely and re-adds one-sided liquidity into a range wholly on the correct side of spot, or (b) detect the failed conversion and surface it as a distinct, non-reverting outcome:
```solidity
BalanceDelta swapped = _swapToRatio(cb, freed0, freed1);
freed0 = _add(freed0, swapped.amount0());
freed1 = _add(freed1, swapped.amount1());
...
if (newLiquidity == 0) revert InsufficientPoolDepth(); // distinct, diagnosable error
```
At minimum, emit or return a dedicated error so the bot can distinguish "pool too thin" from "adverse price" and stop burning gas retrying.

## [D-3] A token-level freeze on `pos.owner` permanently strands the *other* token of the pair
**Severity**: Medium
**Category**: dos
**Location**: `_doWithdraw()` — `contracts/src/AutopilotHook.sol:315-320`; same pattern in `_doRebalance()` lines 371-376
**Description**: `_doWithdraw` delivers both currencies to a single hard-coded recipient, `cb.owner`, via `CurrencySettler.take(..., claims = false)`, which routes to `poolManager.take` → `Currency.transfer` → a raw ERC-20 `transfer`. There is no recipient parameter on `withdraw(bytes32 positionId)` (line 191), no partial-withdraw option, and no `claims = true` path to mint ERC-6909 claim tokens instead. If either token in the pair freezes `pos.owner` — USDC/USDT blocklists are the canonical case, and USDC is the flagship pair asset on both Base and Ethereum — the `transfer` fails, `Currency.transfer` reverts with `ERC20TransferFailed`, and the whole `unlock` reverts atomically. The material harm is not the frozen token (which the owner could not move anyway) but the **non-frozen** counterpart token: because both `take` calls happen inside one atomic `unlock`, a freeze on currency0 also locks the owner's currency1 in the pool. The same applies to a token that self-pauses.
**Proof of Concept**:
1. Owner holds a WETH/USDC position through the hook.
2. The USDC issuer blocklists the owner's address (or pauses the token).
3. Owner calls `withdraw(positionId)`. `modifyLiquidity` succeeds, `currency0.take` (USDC) reverts inside `poolManager.take`, and the transaction reverts.
4. Both the USDC *and* the WETH remain in the PoolManager, attributable to the position but unreachable.
**Unavailability**: the owner's entire position — both tokens — for the full duration of the freeze. Rated Medium rather than High because it requires an action by an external third party (the token issuer), affects only the sanctioned owner, and is reversible if the issuer unfreezes; it is not a permanent, protocol-caused lock.
**Recommendation**: Add a recipient parameter and an ERC-6909 escape hatch so a frozen owner can still rescue the unfrozen leg:
```solidity
function withdraw(bytes32 positionId, address recipient, bool asClaims) external nonReentrant {
    ...
    // in _doWithdraw:
    if (delta.amount0() > 0) cb.key.currency0.take(poolManager, cb.recipient, uint256(uint128(delta.amount0())), cb.asClaims);
    if (delta.amount1() > 0) cb.key.currency1.take(poolManager, cb.recipient, uint256(uint128(delta.amount1())), cb.asClaims);
}
```
Setting `asClaims = true` mints ERC-6909 to the recipient and performs no ERC-20 transfer at all, sidestepping blocklists entirely.

## [D-4] Owner and rebalancer can indefinitely suspend rebalancing for every position
**Severity**: Medium
**Category**: dos
**Location**: `pause()` line 477, `setMinRebalanceInterval()` lines 467-471, `setRebalancer()` lines 462-465, cooldown check line 235-236
**Description**: This is a **privileged-only** DoS and is therefore capped at Medium by the audit rubric — stated explicitly. Three owner/rebalancer levers each suspend the protocol's core function:
1. `pause()` gates `deposit()` (line 148) and `rebalance()` (line 227). There is no timelock and no automatic expiry; an owner that is compromised or loses its key leaves every position frozen at its current range forever. `renounceOwnership()` is correctly disabled (line 473), and `Ownable2Step` prevents a transfer to a typo'd address, so the contract cannot become ownerless — but it also cannot escape a hostile owner.
2. `setMinRebalanceInterval(uint64 interval)` accepts anything up to `MAX_REBALANCE_INTERVAL = 365 days` (line 64) and applies **retroactively and globally** — the check at line 235 reads the current `minRebalanceInterval`, not a value snapshotted per position. Setting 365 days instantly freezes every existing position's next rebalance for up to a year.
3. `setRebalancer(addr, false)` for every whitelisted address leaves `rebalance()` permanently unreachable, since only `isRebalancer[msg.sender]` may call it (line 231).
   Separately, a whitelisted rebalancer can grief the cooldown window (checklist item: *timelock-based griefing at no cost*): calling `rebalance` with `minLiquidity = 0` and near-identical ticks succeeds, writes `pos.lastRebalanceAt = uint64(block.timestamp)` at line 267, and burns the entire `minRebalanceInterval` window on a no-op — while also taking an unbounded sandwich loss because `minLiquidity = 0` disables the only slippage floor.
**Proof of Concept**: Owner (or an attacker holding the owner key) calls `pause()`, or `setMinRebalanceInterval(365 days)`, or revokes all rebalancers. Every position stops being rebalanced immediately. A whitelisted rebalancer instead front-runs the honest bot each cooldown expiry with a `minLiquidity = 0` no-op rebalance, consuming the window every time.
**Unavailability**: `deposit()` and `rebalance()` for all users, for as long as the owner chooses (or up to 365 days for lever 2). **`withdraw()` is deliberately not `whenNotPaused` (line 191) and is not gated by `isRebalancer`, so user funds always remain exitable** — this materially limits the blast radius and is the right design.
**Recommendation**: Cap `MAX_REBALANCE_INTERVAL` far lower (hours, not a year), make the interval per-position and snapshotted at deposit so changes are not retroactive, put `setMinRebalanceInterval` and `pause` behind a timelock or multisig, and add a bounded auto-expiry to the pause:
```solidity
uint64 public constant MAX_REBALANCE_INTERVAL = 7 days;
uint64 public pausedUntil;
function pause() external onlyOwner { pausedUntil = uint64(block.timestamp) + 7 days; _pause(); }
```
Also consider requiring a non-zero `minLiquidity` in `rebalance()` so a no-op/sandwichable rebalance cannot consume the window.

## [D-5] `NothingFreed` permanently blocks rebalancing for dust positions, and dust positions are free to create
**Severity**: Low
**Category**: dos
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:334-336`; `deposit()` line 149
**Description**: `deposit()` only requires `liquidity != 0` (line 149). It never checks that the resulting token amounts are non-zero. `_doDeposit` settles via `CurrencySettler.settle`, which early-returns on `amount == 0`, so a `liquidity = 1` position in a narrow range at an extreme price can be opened for **zero tokens**. Removing such a position later yields `getAmount0Delta`/`getAmount1Delta` results that round down to 0 on both sides, so `freed0 == 0 && freed1 == 0` and line 336 fires `revert NothingFreed()`. That revert is deterministic and unconditional for that position: `rebalance()` on it can never succeed.
**Proof of Concept**: Call `deposit(key, tickLower, tickLower + tickSpacing, 1, minBound, maxBound)` on a pool whose price makes both delta computations round to zero. The position is created (`positions[id].active = true`, `poolPositionCount[id] += 1`) at no token cost. Every subsequent `rebalance(positionId, ...)` reverts with `NothingFreed`.
**Unavailability**: `rebalance()` for that specific position, permanently. Impact is negligible because the position is worth zero by construction and `withdraw()` still succeeds — `_doWithdraw`'s `take` calls are guarded by `delta.amount0() > 0` / `> 0` (lines 315, 318) and `CurrencySettler.take` early-returns on zero, so closing a dust position is a clean no-op. Rated Low: self-inflicted, no fund risk, and it wastes only the griefer's own gas.
**Recommendation**: Reject economically meaningless deposits up front, and make `NothingFreed` non-fatal by closing the position instead:
```solidity
// in deposit(), after computing amounts or via a minimum-liquidity constant:
uint128 public constant MIN_POSITION_LIQUIDITY = 1e6;
if (liquidity < MIN_POSITION_LIQUIDITY) revert ZeroLiquidity();
```

## [D-6] `boundLower` / `boundUpper` are immutable after deposit, so a permanent price move out of bounds permanently un-rebalances a position
**Severity**: Low
**Category**: dos
**Location**: `deposit()` lines 158-159, `rebalance()` line 240
**Description**: `boundLower[positionId]` and `boundUpper[positionId]` are written once in `deposit()` and never modified — there is no `setBounds` function anywhere in the contract. `rebalance()` enforces `if (newTickLower < boundLower[positionId] || newTickUpper > boundUpper[positionId]) revert OutOfBounds();` (line 240). If spot price moves outside `[boundLower, boundUpper]` and stays there, no admissible `newTickLower`/`newTickUpper` can contain spot, so the position is stuck one-sided forever and every rebalance attempt either lands out of range or reverts. A third party cannot force this cheaply — sustaining an out-of-bounds price costs real capital — so this is a design/usability gap rather than an attack.
**Proof of Concept**: Owner deposits with narrow `minBound`/`maxBound`. Market price moves durably beyond `maxBound`. Every `rebalance` the bot can legally submit places the range entirely below spot; the position earns no fees and cannot be restored to range.
**Unavailability**: useful rebalancing for that position, permanently, until the owner manually `withdraw()`s and re-`deposit()`s with new bounds — which is always possible, so no funds are at risk.
**Recommendation**: Let the position owner widen or move their own bounds without a full exit:
```solidity
function setBounds(bytes32 positionId, int24 minBound, int24 maxBound) external {
    Position storage pos = positions[positionId];
    if (!pos.active) revert PositionNotActive();
    if (pos.owner != msg.sender) revert NotPositionOwner();
    _validateTicks(pos.key, minBound, maxBound);
    if (pos.tickLower < minBound || pos.tickUpper > maxBound) revert OutOfBounds();
    boundLower[positionId] = minBound;
    boundUpper[positionId] = maxBound;
}
```

## [D-7] Position storage is never cleared on withdraw, and zero-cost deposits allow unbounded state growth
**Severity**: Low
**Category**: dos
**Location**: `withdraw()` — `contracts/src/AutopilotHook.sol:202-204`; `positions` / `boundLower` / `boundUpper` mappings lines 66-68
**Description**: `withdraw()` sets `pos.active = false` and `pos.liquidity = 0` but never `delete positions[positionId]`, and never clears `boundLower[positionId]` / `boundUpper[positionId]`. Each deposit writes roughly 7 storage slots (one for `owner`, three for the embedded `PoolKey`, one packed slot for `tickLower`/`tickUpper`/`liquidity`/`active`/`lastRebalanceAt`, plus the two bound slots) that are never reclaimed. Combined with D-5 — deposits that cost zero tokens — anyone can mint unlimited permanent state for the price of gas alone, which the checklist flags as specifically viable on L2s where *"what costs $10K on mainnet might cost $10 on Arbitrum"*; Base is a target chain. Crucially, this is **not** a DoS of any function: I confirmed there is no array and no loop over positions anywhere in the contract, `poolPositionCount` is only ever read as a scalar in `_afterSwap` (line 133), and every per-position operation is O(1) keyed by `positionId`. So the cost falls on chain state, not on other users.
**Proof of Concept**: Script `deposit()` with `liquidity = 1` in a loop on Base. Each call costs ~150k gas and permanently adds ~7 slots plus one increment to `poolPositionCount[id]`. Nothing breaks; `_afterSwap` stays O(1); the count in the `AutopilotCheck` event becomes meaningless as an off-chain signal.
**Unavailability**: nothing. The concrete damage is (a) no gas refund for honest users on withdraw, and (b) an off-chain indexer that trusts `poolPositionCount` or `AutopilotCheck.positionCount` can be fed arbitrary noise.
**Recommendation**: Clear the slots on exit to earn the refund and bound state growth, and pair it with the D-5 minimum-liquidity check so spam is not free:
```solidity
// at the end of withdraw(), after the unlock returns:
delete positions[positionId];
delete boundLower[positionId];
delete boundUpper[positionId];
```
Note the refund is capped at 20% of the transaction's gas post-EIP-3529, so this is a modest saving, not a large one.

## [D-8] `TickLiquidityOverflow` on the re-add leg can block a rebalance at a chosen tick
**Severity**: Low
**Category**: dos
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:357-366`
**Description**: The re-add `poolManager.modifyLiquidity` at line 357 passes through `Pool.modifyLiquidity`, which reverts with `TickLiquidityOverflow(tick)` when `liquidityGrossAfter > tickSpacingToMaxLiquidityPerTick(tickSpacing)` (verified at `lib/uniswap-hooks/lib/v4-core/src/libraries/Pool.sol:166-171`). An attacker who saturates `newTickLower` or `newTickUpper` to just under that cap makes the hook's re-add revert, failing the whole rebalance. I am flagging this at Low and stating plainly that I did **not** confirm it is economically reachable: the per-tick cap is `type(uint128).max / numTicks`, an enormous amount of liquidity that would require a correspondingly enormous token commitment on any real pair. It is plausible only in a pool whose tokens are freely mintable by the attacker, where they already control the pool outright.
**Proof of Concept**: Attacker with mint authority over both pool tokens adds liquidity at the exact `newTickLower` the bot is known to target until `liquidityGross` approaches the cap. The bot's `rebalance` reverts inside `modifyLiquidity`.
**Unavailability**: rebalancing at those specific ticks. Temporary and trivially sidestepped — the rebalancer picks adjacent ticks — and `withdraw()` is unaffected because `_doWithdraw` only ever *removes* liquidity, which cannot overflow a tick.
**Recommendation**: No code change warranted. If desired, have the off-chain bot catch `TickLiquidityOverflow` and retry at the next tick-spacing increment.

## [D-9] `_afterSwap` verified O(1) and revert-free — the pool-wide shared cost is sound
**Severity**: Info
**Category**: dos
**Location**: `_afterSwap()` — `contracts/src/AutopilotHook.sol:127-139`
**Description**: This is the single most important thing to get right, since `_afterSwap` runs for every swap by every user in any pool using this hook, and a reverting hook bricks all swaps. I traced every operation and confirmed it is safe:
- `key.toId()` is a pure `keccak256` over the `PoolKey`. No revert path.
- `poolPositionCount[id]` is a single `SLOAD` of a `uint256`. No revert path.
- `poolManager.getSlot0(id)` resolves to `StateLibrary.getSlot0` (`lib/uniswap-hooks/lib/v4-core/src/libraries/StateLibrary.sol:40-63`), which calls `manager.extsload(stateSlot)`. `Extsload.extsload` (`lib/uniswap-hooks/lib/v4-core/src/Extsload.sol:10-16`) is `mstore(0, sload(slot)); return(0, 0x20)` in assembly — **no revert path exists**, not even for an uninitialised pool, which simply returns zero. The subsequent unpacking is pure assembly masking.
- `emit AutopilotCheck(id, tick, count)` has a fixed 3-field, fixed-width payload. Its cost does not scale with anything user-controlled.
- The return `(BaseHook.afterSwap.selector, int128(0))` produces exactly 64 bytes. `Hooks.callHookWithReturnDelta` (`libraries/Hooks.sol:159-168`) sees `AFTER_SWAP_RETURNS_DELTA_FLAG == false` — correct, since `getHookPermissions()` sets only `p.afterSwap = true` — and returns 0 without even parsing the delta, so the `length != 64` check is not reached and the zero delta is inert.

There is no array, no loop, and no external call other than the `extsload` staticcall. The claim that nothing iterates over positions holds for the whole contract.
**Proof of Concept**: N/A — this is a negative result. There is no input, from any caller, that makes `_afterSwap` revert or makes its gas cost grow.
**Recommendation**: No change required. The only residual is a fixed overhead of roughly 5-7k gas per swap (two cold `SLOAD`s plus the event) charged to every swapper in the pool even when they have no relationship to the hook. If that overhead matters for pool competitiveness, consider caching `poolPositionCount` in transient storage or dropping the event, but there is no security reason to.

## [D-10] `poolPositionCount` underflow verified impossible
**Severity**: Info
**Category**: dos
**Location**: `deposit()` line 187, `withdraw()` line 204
**Description**: I checked whether `poolPositionCount[id] -= 1` (line 204) can be driven below zero or desynced, which under Solidity 0.8.x would revert and block `withdraw()`. It cannot:
- The decrement is reachable only past `if (!pos.active) revert PositionNotActive();` (line 193), and `pos.active = false` is written at line 202 *before* the `unlock`, so each position can pass the gate exactly once. `nonReentrant` closes the re-entry window, and the only re-entry surface — a token callback during `CurrencySettler.settle`'s `safeTransferFrom` — cannot reach `deposit`/`withdraw`/`rebalance` (all `nonReentrant`) nor `unlockCallback` (guarded by `msg.sender != address(poolManager)` at line 272) nor a nested `poolManager.unlock` (PoolManager reverts `AlreadyUnlocked`).
- The `PoolId` used for the decrement is derived from `pos.key` (lines 197, 200), the exact `PoolKey` stored at deposit, so it always matches the id that was incremented at line 187.
- `positionId = keccak256(abi.encode(msg.sender, id, depositNonce++))` (line 157) is collision-free via the monotonic global nonce, so two deposits can never share a slot and double-count.
- `rebalance()` never touches `poolPositionCount`, which is correct — a rebalance does not change how many positions exist.
- No path makes a position inactive while skipping the decrement: `pos.active` is written in exactly two places, `true` at line 184 and `false` at line 202, and the latter is immediately adjacent to the decrement in the same non-reentrant frame.
**Proof of Concept**: N/A — negative result.
**Recommendation**: No change required. The invariant `poolPositionCount[id] == |{p : p.active && p.key.toId() == id}|` holds.

## [D-11] Returndata-bomb surface is capped on the `take` path but uncapped on the `settle` path
**Severity**: Info
**Category**: dos
**Location**: `_doDeposit()` line 297-300 via `CurrencySettler.settle`; `_doWithdraw()` / `_doRebalance()` via `CurrencySettler.take`
**Description**: Checklist item *"returndata bombing via external calls"*. I checked both directions against the vendored source:
- **`take` (safe)**: `poolManager.take` → `CurrencyLibrary.transfer` (`lib/uniswap-hooks/lib/v4-core/src/types/Currency.sol:39-88`) performs `call(gas(), currency, 0, fmp, 68, 0, 32)` — it copies at most **32 bytes** of return data into scratch space. A malicious token cannot bomb this path.
- **`settle` (uncapped)**: `CurrencySettler.settle` uses OpenZeppelin `SafeERC20.safeTransferFrom`, which goes through `Address.functionCall` and `returndatacopy`s the full return payload. A token that returns megabytes would burn the depositor's gas.
The `settle` exposure is not exploitable against third parties: the tokens are fixed by the `PoolKey`, the payer is the depositor themselves (`cb.owner`, line 297/300), and a pool built on a hostile token harms only people who opt into it. `_afterSwap` — the genuinely shared path — makes no token calls at all.
**Proof of Concept**: N/A — requires a malicious token that the victim deliberately chose to deposit.
**Recommendation**: No change required. If belt-and-braces is wanted, replace `SafeERC20` with a fixed-32-byte-buffer transfer helper matching v4's own `CurrencyLibrary.transfer`.

## [D-12] Extreme-magnitude reverts in `BalanceDelta.add` and `LiquidityAmounts.toUint128`
**Severity**: Info
**Category**: dos
**Location**: `_doRebalance()` line 370 (`removed + swapped + added`), line 347 (`getLiquidityForAmounts`)
**Description**: Two arithmetic revert paths exist that are unreachable at realistic magnitudes but worth recording:
- `BalanceDelta`'s `+` operator (`lib/uniswap-hooks/lib/v4-core/src/types/BalanceDelta.sol:20-32`) sums the two halves as `int256` and then calls `SafeCast.toInt128`, which reverts with `SafeCastOverflow` if the sum does not fit in `int128`. `net = removed + swapped + added` at line 370 could therefore revert if the intermediate components were each near `int128` bounds.
- `LiquidityAmounts.getLiquidityForAmount0` / `getLiquidityForAmount1` end in `.toUint128()`, which reverts on overflow, so an absurdly large `freed0`/`freed1` at line 347 reverts rather than truncating.
Both require token amounts at the `2^127` scale, which no real pair reaches. Also noted as correct-by-construction: `_add` (lines 446-450) clamps to 0 instead of underflowing, and since `_swapToRatio` always uses exact-input (`amountSpecified: -int256(amountIn)` with `amountIn <= have0`/`have1`), the clamp is defensive only and never actually triggers. I separately worked through whether the round-down in `getLiquidityForAmounts` versus the round-up in v4's `getAmount0Delta`/`getAmount1Delta` on the re-add could leave a 1-wei settlement shortfall and trip `CurrencyNotSettled` at `PoolManager.sol:112`; because `L = min(L0, L1)` is derived by rounding *down* from the available amounts, the re-add's rounded-up requirement stays within what was freed, so I do **not** believe this is reachable — but I did not prove it with a fuzz test, so it is recorded here rather than raised as a finding.
**Proof of Concept**: N/A — not reachable at realistic token magnitudes.
**Recommendation**: No change required. If a fuzz campaign is run before deployment, add an invariant that `_doRebalance` never reverts with `CurrencyNotSettled` or `SafeCastOverflow` across the full `uint128` liquidity range.

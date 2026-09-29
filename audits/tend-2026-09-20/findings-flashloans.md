# AutopilotHook — Flash Loan / Third-Party Atomicity Findings

**Scope of this specialist pass**: flash-loan and third-party attack surface around `rebalance()` in
`/Users/prazw/Desktop/Web3/Tend/contracts/src/AutopilotHook.sol`. This pass deliberately covers only what an
attacker **without** the rebalancer key can do. Attacks that require the allowlisted rebalancer key are routed to
the access-control/privileged-role workstream and are explicitly marked as out of lane below.

**Summary.** The remove→swap→add sequence inside `poolManager.unlock()` is genuinely atomic and genuinely
uninterruptible: v4's global `Lock` makes `unlock()` non-nestable (`AlreadyUnlocked`), `unlockCallback()` is
reachable only via the hook's own `unlock()`, OpenZeppelin's `nonReentrant` is entered *before* `unlock()` so it
covers the whole callback chain, and `_doRebalance()` performs no ERC-20 transfer between the liquidity removal
and the liquidity re-add — so there is no token-callback window inside the critical section. That is the good
news, and it is a real negative result. The bad news is that atomicity protects the *sequence*, not the
*outcome*: because `_doRebalance()` burns the position's own liquidity **before** `_swapToRatio()` trades, and
because that swap is unbounded (`sqrtPriceLimitX96` pinned to the tick extremes, 100% of the surplus side), the
transaction **ends** with the pool at a grossly dislocated price and the position re-minted against that fake
price. Every wei of value the swap destroys is sitting in the pool, unguarded, for the very next transaction in
the block. A third party with no privileges, no key, and — via v4's own `unlock`+`take` — no capital, can
backrun the rebalance and take it. A flash loan makes this strictly better for the attacker: it is used not to
worsen the execution price directly but to *select the branch* of `_swapToRatio()` that dumps 100% of one side,
maximising the payload. The off-chain bot's trigger is also attacker-controlled (it reacts to swap events, and
the hook helpfully emits `AutopilotCheck` from `_afterSwap`), so the attacker chooses the moment. Notably, the
naive frontrun-sandwich is *not* the profitable shape here — `_swapToRatio()`'s branch selection is
anti-correlated with it — and we say so explicitly rather than inflate it.

| Severity | Count | IDs |
|---|---|---|
| Critical | 1 | F-1 |
| High | 2 | F-2, F-3 |
| Medium | 2 | F-4, F-5 |
| Low | 2 | F-6, F-7 |
| Info | 3 | F-8, F-9, F-10 |

---

## [F-1] Any third party can backrun `rebalance()` and capture the value destroyed by the unbounded swap; v4's own `unlock`+`take` makes it zero-capital
**Severity**: Critical
**Category**: flashloans
**Location**: `_doRebalance()` / `_swapToRatio()` — `src/AutopilotHook.sol:324-377`, `:425-433`
**Description**: `_doRebalance()` burns the position's entire liquidity at line 324-333 **before** calling
`_swapToRatio()` at line 342. In a pool where the hook-managed position is a material share of the active
liquidity — the designed deployment state for this hook — the removal itself hollows out the book at spot. The
swap that follows is issued with `sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1` / `TickMath.MAX_SQRT_PRICE - 1`
(line 430), i.e. no price bound at all, for `amountIn` equal to 100% of the surplus side (lines 394-421). A
sibling agent reproduced the consequence empirically: a rebalance drove `sqrtP` to `MAX_SQRT_PRICE - 1`. The hook
therefore sells the position's tokens into a near-empty book at a catastrophic average price.

The critical point for this lane is **where that value goes and who can reach it**. It goes into the pool, to
whoever holds the traversed liquidity, and it leaves the pool sitting at an absurd price at the moment
`rebalance()` returns. Nothing in the contract re-arms the pool: the re-add at line 357-366 places liquidity in
`[newTickLower, newTickUpper]`, which after the dislocation is entirely out of range and therefore contributes no
depth at spot; the surplus is `take`n out to the owner (lines 371-376). The transaction ends. The next
transaction in the block — written by anyone, with no allowlist, no position, and no prior interaction with the
hook — restores the price and pockets the difference. `minLiquidity` does not intervene: it is a *liquidity*
floor, and liquidity denominated in the wrong token at a destroyed price is numerically large, so even a
non-zero value passes (and the test suite passes `0` throughout, e.g. `test/AutopilotHook.t.sol:110`).

This is a direct transfer from the position owner (and, on the way back, from the freshly minted position) to an
arbitrary third party. It requires no flash loan at all, but a flash loan removes the last barrier — the
attacker's inventory.

**Proof of Concept**:
Setup: pool token0/token1, fee 0.3%, the hook's managed position is the dominant liquidity at spot (the state
this hook is built to create). Honest price `p0`. Attacker `E` is an ordinary EOA/contract, not allowlisted.

1. `E` waits for (or induces, see F-4) a `rebalance()` transaction. No mempool access is required — a plain
   backrun works on inclusion, and on a single-sequencer L2 `E` can simply watch the ordered stream.
2. The bot's `rebalance(positionId, newTickLower, newTickUpper, minLiquidity)` executes:
   - line 324: `modifyLiquidity(-L)` burns the position. The book at spot is now thin.
   - line 342: `_swapToRatio()` selects a branch and swaps 100% of the surplus side with no price bound. Say it
     is the `sqrtPriceX96 <= sqrtA` branch (line 392-395): `zeroForOne = false`, `amountIn = have1`, limit
     `MAX_SQRT_PRICE - 1`. The full token1 balance of the position is sold for token0 while the price walks up to
     the extreme (reproduced empirically). The hook receives whatever token0 the thin book had.
   - lines 346-366: `newLiquidity` is sized from `getSlot0()` **after** the walk, so the re-add is priced against
     the fake price and lands entirely outside the range; lines 371-376 return the residue to the owner.
   - `unlock()` returns. Deltas net to zero, the tx succeeds, the pool is left at `sqrtP ≈ MAX_SQRT_PRICE - 1`.
3. `E` backruns in the same block. `E` calls `poolManager.unlock()` in its own transaction (legal: the hook's
   lock was released when its `unlock()` returned — see F-9), then inside its callback:
   - `poolManager.take(currency0, E, X)` — a flash loan from the PoolManager's own reserves, **zero capital in**.
   - `poolManager.swap(key, {zeroForOne: true, amountSpecified: -X, sqrtPriceLimitX96: <p0>})` — sells token0
     into a pool that is pricing token0 astronomically, receiving back essentially all the token1 the hook just
     dumped, and walking the price back toward `p0`. On the way it also sweeps the hook's newly minted position
     in `[newTickLower, newTickUpper]`, taking the other side of that too.
   - `currency0.settle(...)` repays `X`; `E` withdraws the token1 profit.
4. Economics: **capital in = 0** (flash-taken from the PoolManager and repaid in the same unlock) **+ gas**.
   **Value out ≈ the entire surplus side of the rebalanced position**, minus the 0.3% LP fee `E` pays on its own
   swap and minus whatever other LPs absorbed on the outward leg. With the hook as the dominant LP, "other LPs"
   is small by construction, so `E` recovers most of it. The loss is borne by the position owner: their position
   is re-minted with a fraction of its prior value and the residue `take`n to them is the debris.
   There is no price at which this is unprofitable for `E`: it is a pure arbitrage against a dislocation someone
   else created, with atomic revert-on-failure.

What does *not* block it: the `nonReentrant` guard (F-8), the v4 lock (F-9), `whenNotPaused`, the rebalancer
allowlist (`E` never calls `rebalance()`), the cooldown (F-6), or a private RPC (F-7).

**Recommendation**: The swap must not be allowed to move the price beyond a bound derived from a price the
attacker cannot set in the same transaction. Two changes, both needed:

```solidity
// 1. Bound the swap. Derive the limit from a pre-removal reference price, not from the tick extremes.
//    Capture spot BEFORE the liquidity burn so the hook's own removal cannot widen the allowed band.
function _doRebalance(Callback memory cb) internal returns (uint128 newLiquidity) {
    (uint160 sqrtRefX96,,,) = poolManager.getSlot0(cb.key.toId()); // BEFORE modifyLiquidity(-L)
    // ... existing removal ...
    BalanceDelta swapped = _swapToRatio(cb, freed0, freed1, sqrtRefX96);
    // ... and re-check after:
    (uint160 sqrtAfterX96,,,) = poolManager.getSlot0(cb.key.toId());
    if (_deviationBps(sqrtRefX96, sqrtAfterX96) > maxSwapDeviationBps) revert PriceMovedTooFar();
    ...
}

// in _swapToRatio, replace the extreme limits:
uint160 limit = zeroForOne
    ? uint160(FullMath.mulDiv(sqrtRefX96, maxMoveNumerator, maxMoveDenominator))   // e.g. 99%  of ref
    : uint160(FullMath.mulDiv(sqrtRefX96, maxMoveDenominator, maxMoveNumerator));  // e.g. 101% of ref
return poolManager.swap(cb.key, SwapParams({
    zeroForOne: zeroForOne,
    amountSpecified: -int256(amountIn),
    sqrtPriceLimitX96: limit
}), "");
// NOTE: with a real limit the swap may return unspent input; `freed0/freed1` already account for the
// actual delta, and the leftover is returned to the owner, so this is safe — but add a
// `minAmountOut`-style check on `swapped` as well.
```

```solidity
// 2. Replace the liquidity floor with a VALUE floor, and validate it against a manipulation-resistant
//    reference rather than the post-swap spot. minLiquidity is not a slippage bound.
//    e.g. require that (freed0 + freed1 valued at sqrtRefX96) after the swap is >= minValueOut,
//    with minValueOut computed by the caller from the pre-tx price.
```
Additionally, size the re-add from `sqrtRefX96` (or from a short TWAP), not from the post-swap `getSlot0()` at
line 346, and consider swapping *before* burning the position's liquidity, or splitting the removal so the
position's own depth still backs the swap.

---

## [F-2] Flash loan used to force the "dump 100% of one side" branch of `_swapToRatio()`, maximising the payload for F-1
**Severity**: High
**Category**: flashloans
**Location**: `_swapToRatio()` — `src/AutopilotHook.sol:392-399`
**Description**: `_swapToRatio()` chooses between three behaviours purely from the *instantaneous* `getSlot0()`
price read at line 385, compared against the new range boundaries `sqrtA`/`sqrtB`:

- `sqrtPriceX96 <= sqrtA` (line 392): `amountIn = have1` — **100% of the token1 balance**.
- `sqrtPriceX96 >= sqrtB` (line 396): `amountIn = have0` — **100% of the token0 balance**.
- otherwise (line 400): the straddle branch, which trades only the *difference* between the held and target
  composition — typically a small fraction.

In normal operation the bot centres the new range on the live price, so spot lands inside `[sqrtA, sqrtB]` and the
straddle branch runs, keeping the unbounded swap small. An attacker who can move spot outside the new range
before the rebalance lands therefore does not merely worsen the price — they **change the swap from a small
rebalancing trade into a full liquidation of one side of the position**, with no price bound (F-1). Both
`newTickLower` and `newTickUpper` are plaintext calldata of the pending `rebalance()` transaction, so the attacker
knows exactly which side of which boundary to push to.

Crucially, this is the branch-selection lever, not a price lever, which is why it survives the observation in
F-3 that the classic frontrun direction is anti-correlated. The attacker does not need the manipulation to leave
the hook trading at a bad *starting* price; they only need spot to sit on the far side of `sqrtA` or `sqrtB` when
line 385 is read.

**Proof of Concept**:
1. `E` observes `rebalance(pid, newTickLower = -600, newTickUpper = 600, minLiquidity = 0)` in the public
   mempool (see F-7; or induces it per F-4, in which case `E` knows the range the bot will pick from the same
   policy the bot publishes).
2. `E` flash-borrows token1 (Aave/Balancer/Morpho, or `poolManager.take` inside its own `unlock`) and swaps
   token1→token0 in the same pool, pushing spot from inside `[-600, 600]` to just above tick `600`. Cost: the
   0.3% LP fee on the frontrun size plus the price impact `E` will partially recover on the unwind. Because the
   move only has to clear a range boundary — typically a few percent, not an order of magnitude — the frontrun
   size is modest relative to the position.
3. `rebalance()` executes. Line 324 burns the position's liquidity (thinning the book). Line 385 reads spot,
   sees `sqrtPriceX96 >= sqrtB`, and line 396-399 sets `zeroForOne = true, amountIn = have0` — the position's
   **entire** token0 balance — with limit `MIN_SQRT_PRICE + 1`. Against the hollowed book this walks the price
   to the floor. `minLiquidity = 0` (or any liquidity-denominated floor) does not stop it.
4. `E` backruns exactly as in F-1 step 3, repaying the flash loan and keeping the difference.
5. Economics: **capital in = flash-loan principal (returned in the same tx) + ~0.6% round-trip LP fee on the
   frontrun size + gas.** **Value out ≈ the destroyed value of 100% of the position's token0 side**, which is
   unbounded above by anything in the contract. Since the frontrun only has to move price by the distance from
   spot to a range boundary (single-digit percent for a typical range) while the payload is the full position,
   the ratio of value out to fee paid is large and the trade is comfortably profitable whenever the position is a
   meaningful share of pool depth. If the attacker instead uses the JIT route (F-3) they also collect the fill
   directly rather than via arbitrage.

**Recommendation**: The fix in F-1 (bounded `sqrtPriceLimitX96` + a value-denominated floor) is the primary
mitigation. In addition, refuse to rebalance when spot is not where the rebalancer expected it:

```solidity
function rebalance(
    bytes32 positionId,
    int24 newTickLower,
    int24 newTickUpper,
    uint128 minLiquidity,
    int24 expectedTick,          // NEW: tick the bot decided against, off-chain
    int24 maxTickDeviation       // NEW
) external { ... }

// inside _doRebalance, before any modifyLiquidity:
(, int24 tickNow,,) = poolManager.getSlot0(cb.key.toId());
int24 d = tickNow > cb.expectedTick ? tickNow - cb.expectedTick : cb.expectedTick - tickNow;
if (d > cb.maxTickDeviation) revert PriceMoved(tickNow, cb.expectedTick);
```
This single check neutralises branch forcing: the attacker can no longer relocate spot relative to the new range
without reverting the rebalance. Cap the swap size independently as well (e.g. never swap more than the amount
the straddle formula asks for, even in the single-sided branches).

---

## [F-3] Public-mempool capture of the rebalance: JIT liquidity is the profitable shape; the classic frontrun-sandwich is not
**Severity**: High
**Category**: flashloans
**Location**: `rebalance()` / `_swapToRatio()` — `src/AutopilotHook.sol:225-269`, `:384-434`
**Description**: Two distinct mempool attacks must be separated, because conflating them overstates one and
misses the other.

**(a) The classic frontrun-sandwich is anti-correlated and we could not make it profitable on its own.** A
sandwicher profits by frontrunning *in the same direction* as the victim's swap. But `_swapToRatio()` always
trades *toward* the current price: when spot is pushed below the new range (`sqrtPriceX96 <= sqrtA`, line 392)
the hook **buys** token0 — i.e. it buys the token the attacker just made cheap; when spot is pushed above the
range (line 396) the hook **sells** token0 — the token the attacker just made expensive. In the straddle branch
the same holds: pushing spot up raises `want1` (line 404) and makes the hook a token0 *seller* into the elevated
price. In every branch, the manipulation required to set the hook's direction is the opposite of the
manipulation a sandwicher needs. Equally, the liquidity re-added at lines 357-366 is always placed on the side
the attacker must trade back through, so the unwind leg trades against it at unfavourable prices. We worked
through the up-move and down-move cases for both a drifted (single-sided) and a straddling old range and found
the attacker's round trip to be a loss equal to roughly 2× the LP fee on the frontrun size, before any gain.
**We therefore do not report a classic sandwich finding, and we note this explicitly so it is not re-raised.**
The residual value from a pure price-displacement attack is the one-shot impermanent loss on the re-minted
position as the price reverts, bounded by roughly `L · (√P_B − √P_0)² / √P_B` — tens of basis points for a
typical range, and smaller than the fees the attacker pays to displace the price. Not profitable.

**(b) JIT liquidity provision is profitable, and it is the real mempool risk.** The attacker does not need to
move the price at all. They need only to be the *counterparty* to the unbounded swap. Because line 324 removes
the position's own liquidity immediately before the swap, the attacker can cheaply become the dominant LP in the
price region the swap will traverse.

**Proof of Concept** (for (b)):
1. `E` sees `rebalance(pid, lo, hi, minLiquidity)` in the public mempool and reads `lo`/`hi` from the calldata.
   `E` can compute which branch will fire and in which direction the price will walk.
2. `E` frontruns with a single `modifyLiquidity` (via any v4 router — `E` needs no relationship with the hook)
   adding a band of liquidity positioned in the traversal path, on the far side of the current price from the
   new range. Capital in: the tokens that band must pay out, which at prices far below (or above) spot is a small
   fraction of what the band will absorb — an LP band placed at price `p` buys token0 at `p`, so placing it deep
   makes each unit of inventory buy a large quantity.
3. `rebalance()` runs: the position's own liquidity is burned, and the unbounded swap walks straight through
   `E`'s band, filling `E` at prices far from fair value. `E` is now holding the position's tokens, having paid a
   fraction of their worth.
4. `E` backruns: removes the band and closes out (or simply arbs the price back, as in F-1). Both legs are in
   `E`'s control and the whole thing reverts atomically if the rebalance does not land, so `E` carries no
   inventory risk.
5. Economics: **capital in = the band's token inventory (deliberately small because the band sits at bad prices)
   + 2 gas-heavy txs.** **Value out = the spread between the fill prices `E` obtained and fair value, on the full
   surplus side of the position.** `E` also earns the 0.3% LP fee on the hook's swap for the portion that crosses
   their band — the hook pays its victim's fee to its attacker. This is profitable at any position size large
   enough to cover gas.

**Recommendation**: The bounded-swap fix in F-1 is the mitigation — a JIT band placed outside the allowed price
band simply never gets traversed. Independently: do not remove the position's own liquidity before swapping (swap
first against the position's own depth, or remove only the portion not needed to back the swap), and consider
routing `_swapToRatio()` through a separate, deeper pool or an external router with a real `minAmountOut` rather
than through the very pool whose depth the hook just removed.

---

## [F-4] The rebalance trigger is attacker-controlled: any third party can schedule the victim transaction
**Severity**: Medium
**Category**: flashloans
**Location**: `_afterSwap()` — `src/AutopilotHook.sol:127-139`; `rebalance()` — `:225-236`
**Description**: `rebalance()` is correctly gated on `isRebalancer[msg.sender]` (line 231), so an attacker
cannot call it. But the *decision* to call it is made off-chain by a bot that reacts to swap activity, and the
hook broadcasts precisely the signal that bot consumes: `_afterSwap()` reads `getSlot0()` and emits
`AutopilotCheck(id, tick, count)` (lines 134-137) on **every** swap in the pool, from **any** caller, including
the attacker. An attacker therefore has a reliable, cheap, permissionless primitive for making the bot act: swap
enough to push the tick out of a position's range, and the bot will emit-then-rebalance.

This converts F-1/F-2/F-3 from "wait for a rebalance to happen" into "schedule the victim transaction at a moment
of my choosing, with a range I can predict from the bot's published policy". It also means the attacker's flash
loan and the victim transaction do not need to be in the same block: the attacker performs the nudge, lets the
bot commit, and then applies the manipulation and capture around the bot's transaction.

It is worth being precise about what is *not* claimed: an attacker cannot hold a manipulated price across a block
boundary for free. If they nudge the price in block N and the bot reacts in block N+1, ordinary arbitrageurs will
have restored the price and taken the attacker's money in between. So the "induce the bot to re-range against a
fake price" variant requires either same-block ordering control (a builder, a searcher bundle, or a
single-sequencer L2 where the attacker can land adjacent transactions) or accepting arbitrage losses on the nudge.
The variant that does *not* require any of that is the cheap one: nudge the price legitimately to a genuinely
out-of-range state, which the bot will rebalance on its own schedule, and then run F-2/F-3 around the resulting
transaction.

**Proof of Concept**:
1. `E` picks a position whose range it can read from `positions(positionId)` (public mapping, line 66) and from
   `PositionOpened` events.
2. `E` swaps in the pool, pushing the tick outside `[tickLower, tickUpper]`. `_afterSwap()` fires
   `AutopilotCheck`. Cost: the LP fee and price impact of the nudge, partially recoverable — and if the nudge is
   toward fair value, free.
3. The bot decides a rebalance is due and submits `rebalance(pid, lo, hi, minLiquidity)`.
4. `E` runs F-2 (flash-borrow to force the 100%-dump branch) and/or F-3(b) (JIT band) around that transaction.
5. Economics: the nudge itself is at worst a few basis points of the nudge size; its value is optionality — `E`
   now knows when the large unbounded swap will occur. Profit is realised in F-1/F-2/F-3.

**Recommendation**: The on-chain fixes in F-1 and F-2 are what actually matter, because they make a rebalance
safe *regardless* of when it is triggered. In addition, on the bot side: require the deviation-from-reference
check of F-2 so an induced rebalance at a manipulated tick reverts rather than executing; add hysteresis and a
randomised delay so the trigger is not a deterministic function of an attacker-controlled event; and consider
gating the rebalance decision on a TWAP being out of range rather than spot (see F-5). Emitting
`AutopilotCheck` on every swap is itself a (minor) information leak about which pools are hook-managed and how
many positions are at stake — consider dropping `count` from the event.

---

## [F-5] `getSlot0()` spot price is the sole input to both branch selection and position sizing — no TWAP, no deviation guard
**Severity**: Medium
**Category**: flashloans
**Location**: `_doRebalance()` — `src/AutopilotHook.sol:346`; `_swapToRatio()` — `:385`
**Description**: This is the textbook "flash loan + AMM spot price manipulation" pattern from the checklist
(`any price derivation from getReserves() or slot0.sqrtPriceX96`). The contract reads
`poolManager.getSlot0()` twice per rebalance and uses the raw instantaneous `sqrtPriceX96` for two
safety-critical decisions: which branch of `_swapToRatio()` to take and how much to swap (line 385), and how much
liquidity to mint (line 346). There is no TWAP, no external oracle, no deviation bound, and — since line 346 is
read *after* the hook's own unbounded swap — the second read is polluted by the hook's own price impact as well
as by any attacker's.

We are separating this from F-1/F-2 because it is the underlying *pattern*, and because it has an independent
consequence that survives even if the swap is bounded: sizing the re-add from a post-swap spot means the position
can be minted with a composition that does not match the true market, leaving most of the value returned to the
owner as loose tokens (lines 371-376) rather than as a working LP position. That is degraded behaviour and
incorrect accounting rather than direct theft, hence Medium on its own.

The multi-block variant from the checklist is worth flagging for the deployment target: on an L2 with cheap gas
and a single sequencer, holding a manipulated price across a block boundary is materially cheaper than on
mainnet, which is what makes the "induced rebalance at a fake price" path in F-4 more than theoretical. We have
not measured this for a specific chain and are not claiming a concrete cost figure.

**Proof of Concept**: See F-2 for the profitable instantiation. The pattern in isolation: any party moves spot
within a single transaction (flash loan, or simply a large swap), and every subsequent `getSlot0()` consumer in
that transaction — here, branch selection and liquidity sizing — acts on the moved price with no sanity check.
Nothing in `AutopilotHook.sol` compares the read against any value that the attacker cannot influence in the same
transaction.

**Recommendation**:
```solidity
// Size from a reference price captured before any hook-induced movement, and validate spot against
// a manipulation-resistant source before acting on it at all.
(uint160 sqrtRefX96,,,) = poolManager.getSlot0(cb.key.toId());   // captured BEFORE modifyLiquidity(-L)
// ... removal, bounded swap ...
newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
    sqrtRefX96,                                                   // NOT the post-swap slot0
    TickMath.getSqrtPriceAtTick(cb.newTickLower),
    TickMath.getSqrtPriceAtTick(cb.newTickUpper),
    freed0,
    freed1
);
```
Combine with the `expectedTick`/`maxTickDeviation` parameter from F-2, and if a truly manipulation-resistant
reference is required, add a Chainlink (or equivalent) cross-check with a bounded deviation before allowing any
rebalance. A v4 pool's own observations are not a sufficient reference for a hook that sizes against that same
pool.

---

## [F-6] The cooldown does not meaningfully rate-limit flash-loan cycles
**Severity**: Low
**Category**: flashloans
**Location**: `rebalance()` — `src/AutopilotHook.sol:235-236`; `minRebalanceInterval` — `:71`, `:467-471`
**Description**: Asked directly: does `minRebalanceInterval` bound repeated extraction? Only weakly.

1. It is **per-position**: `pos.lastRebalanceAt + minRebalanceInterval` (line 235). An attacker who has induced
   drift across `N` positions in the same pool can have `N` rebalances occur in quick succession — each a
   separate `rebalance()` call, each independently attackable by F-1/F-2/F-3. There is no per-pool or global
   throttle, and `poolPositionCount` (line 69) is tracked but never used as a limiter.
2. The **first rebalance is always free**: `lastRebalanceAt` is initialised to `0` at deposit (line 185), so
   `readyAt = minRebalanceInterval`, which is far in the past for any real `block.timestamp`. A freshly deposited
   position can be rebalanced in the very next block. Confirmed by `test_rebalance_cooldown_enforced` only
   passing because the test warps — the first-rebalance case is not covered.
3. It is **owner-settable to zero**: `setMinRebalanceInterval(0)` (line 467) is legal, and the constructor accepts
   `cooldown = 0` (line 118-119). Nothing enforces a floor.
4. Most importantly, it does not bound the *size* of a single extraction. F-1 takes a large share of a position's
   value in one rebalance; a cooldown that permits one such event per hour is not a mitigation.

It does provide one real benefit: it prevents an attacker from looping the same position repeatedly within one
transaction or block, which rules out the "repeat until drained" amplification that makes many flash-loan
attacks catastrophic. That is genuine and worth keeping.

**Proof of Concept**: Not an attack in itself. The concrete gap: `deposit()` → `rebalance()` in the next block
with `minRebalanceInterval = 3600` succeeds, because `0 + 3600 < block.timestamp`.

**Recommendation**:
```solidity
// Start the clock at deposit so the first rebalance is also throttled.
positions[positionId] = Position({
    ...
    lastRebalanceAt: uint64(block.timestamp)   // was: 0
});

// Enforce a non-zero floor so the throttle cannot be configured away.
uint64 public constant MIN_REBALANCE_INTERVAL_FLOOR = 5 minutes;
function setMinRebalanceInterval(uint64 interval) external onlyOwner {
    if (interval > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
    if (interval < MIN_REBALANCE_INTERVAL_FLOOR) revert IntervalTooShort();
    ...
}
```
Consider also a per-pool cooldown so that `N` positions in one pool cannot be drained back to back.

---

## [F-7] A private RPC does not mitigate the capture; it only blunts one of three routes
**Severity**: Low
**Category**: flashloans
**Location**: operational — `rebalance()` submission path
**Description**: The daemon optionally submits through a private RPC. It is worth stating precisely what that
buys, because it is easy to treat it as the fix and it is not.

- It **does** deny the attacker advance sight of `newTickLower`/`newTickUpper`/`minLiquidity`, which is what F-2
  (branch forcing) and F-3(b) (JIT band placement) rely on for precision. Those attacks degrade to guesswork
  against a published rebalancing policy — harder, not impossible, since the bot's range policy is typically
  deterministic and the position's current range is public on-chain (line 66).
- It **does not** mitigate F-1 at all. A backrun needs no mempool visibility: the dislocation is a fact about
  on-chain state after the rebalance is included, visible to every searcher in the same block, and profitable to
  exploit atomically with zero capital. Private-RPC submission is not private *after* inclusion.
- It **does not** mitigate F-4: the attacker's ability to induce a rebalance is unaffected by how the resulting
  transaction is submitted.
- On a single-sequencer L2, "private mempool" guarantees vary and in several cases amount to trusting the
  sequencer operator. We have not verified the specific submission path for this deployment.

**Proof of Concept**: Not applicable — this documents a control that is weaker than it looks. The blocking
argument for F-1 under a private RPC is: there is none; F-1's step 3 runs after inclusion.

**Recommendation**: Keep the private RPC, but do not count it as the control for any of F-1/F-2/F-3. The
on-chain bound in F-1 is the control. Document in the daemon that private submission is defence-in-depth only.

---

## [F-8] Reentrancy through the unlock/callback chain: not exploitable — guards verified against vendored v4-core
**Severity**: Info
**Category**: flashloans
**Location**: `unlockCallback()` — `src/AutopilotHook.sol:271-283`; `deposit()/withdraw()/rebalance()` modifiers
**Description**: Verified against the vendored source at
`lib/uniswap-hooks/lib/v4-core/src/PoolManager.sol` and `lib/uniswap-hooks/src/utils/CurrencySettler.sol`. The
callback path is sound; recording the reasoning so it is not re-litigated.

1. `unlockCallback()` guards `msg.sender != address(poolManager)` (line 272). `PoolManager.unlock()` calls
   `IUnlockCallback(msg.sender).unlockCallback(data)` where `msg.sender` is the caller of `unlock()` — so the
   PoolManager can only ever invoke this hook's callback if this hook itself called `unlock()`. A third party
   cannot cause `hook.unlockCallback` to be called with attacker-chosen `Callback` data.
2. `nonReentrant` **does** cover the callback path. OpenZeppelin's guard is entered by the modifier on
   `deposit()`/`withdraw()`/`rebalance()` *before* `poolManager.unlock()` is called, and is not released until
   after `unlock()` returns. Any re-entry into those three functions from anywhere inside the callback chain —
   including from a token callback — reverts with `ReentrancyGuardReentrantCall`. `unlockCallback()` itself
   carries no guard, but per (1) it is unreachable except through the hook's own `unlock()`.
3. **There is no token-callback window inside the critical section of a rebalance.** `_doRebalance()` performs
   `modifyLiquidity(-L)` → `swap` → `modifyLiquidity(+L)` with **no** `settle` and **no** `take` in between; the
   only `take` calls are at lines 371-376, after every price-dependent computation is finished. A malicious
   ERC-777/ERC-1363-style token (or a malicious position owner receiving the `take`) can re-enter at that point,
   but every value the hook will use has already been computed and its deltas are already fixed. `_doDeposit()`
   does call `settle` with `payer = cb.owner` (lines 297, 300), which performs `safeTransferFrom` and is a genuine
   re-entry window — but the liquidity is already minted at that point and the depositor chose the amount, so
   there is nothing to bias.
4. Re-entering *the PoolManager* during such a window is possible (the lock is still open, so `swap`/
   `modifyLiquidity`/`take` all pass `onlyWhenUnlocked`) but not profitable: `CurrencyDelta` is keyed **per
   address**, so an attacker's operations create deltas against the attacker, never against the hook's balance,
   and `unlock()` enforces `NonzeroDeltaCount.read() == 0` globally before returning — so any value the attacker
   `take`s must be settled by the attacker. They also cannot touch the hook's v4 positions: v4 position keys
   include `owner = msg.sender`, which for the hook's positions is the hook.
5. The hook's own swap re-enters `_afterSwap()` (lines 127-139). It only reads `getSlot0()` and emits an event —
   no state writes, no external calls, and it returns a zero `int128` delta. `afterSwap` is the only enabled
   permission (line 124), so no other hook callback is reachable.

**Proof of Concept**: Not exploitable. The blocking facts, precisely: `PoolManager.unlock()` reverts with
`AlreadyUnlocked` if `Lock.isUnlocked()`, so no nesting; `unlockCallback` is only invoked on the caller of
`unlock()`; the OZ guard is set before `unlock()`; `_doRebalance()` makes no transfer between removal and re-add;
deltas are per-address with a global zero-check at unlock exit.

**Recommendation**: No change required for safety. For defence in depth, consider a transient "expected op" flag
set before `unlock()` and cleared after, asserted at the top of `unlockCallback()` — cheap with transient storage
and it makes the invariant explicit rather than emergent. Note also that this analysis assumes well-behaved
ERC-20s for the *ordering* of `settle`; the hook already blocks native currency (line 151) but does not restrict
callback tokens, so a pool created with an exotic token inherits the (currently unprofitable) re-entry window.

---

## [F-9] Composability: a third party cannot interleave into the hook's unlock — and legitimate integrators cannot compose either
**Severity**: Info
**Category**: flashloans
**Location**: `deposit()/withdraw()/rebalance()` → `poolManager.unlock()`; `lib/.../v4-core/src/PoolManager.sol:unlock`
**Description**: Answering the question directly: **no**, a third party cannot call `poolManager.unlock()` and
interleave calls into this hook. `PoolManager.unlock()` begins with
`if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();` — the lock is a single global (transient) flag,
so unlocks cannot nest. Consequences, both directions:

- An attacker inside their own `unlock()` cannot call `hook.deposit()`, `hook.withdraw()`, or `hook.rebalance()`:
  each of those calls `poolManager.unlock()` and would revert with `AlreadyUnlocked`. There is no way to observe
  or interfere with a partially-completed hook operation from inside a third-party unlock.
- Symmetrically, nobody can call `poolManager.swap`/`modifyLiquidity` *between* the hook's removal and re-add
  except via a token callback, and F-8(3) establishes that no token callback fires in that window.
- The flip side is a usability cost, not a security one: because the hook opens its own unlock, integrators
  cannot batch `deposit()` with other v4 operations in a single unlock (e.g. a router aggregating a swap and a
  deposit). Any contract calling `hook.deposit()` from inside its own unlock will revert.

This is the key atomicity result for this audit and it is the reason the attack surface is entirely *around* the
rebalance transaction (F-1, F-2, F-3) rather than inside it.

**Proof of Concept**: Not exploitable. Blocking mechanism quoted above from the vendored
`PoolManager.unlock()`.

**Recommendation**: No change required. If composability with routers is desired later, expose
`unlockCallback`-compatible variants that assume an already-open lock — but note that doing so would remove the
protection described here and would need the mid-sequence entry analysis redone from scratch.

---

## [F-10] Donation / inflation attacks against position accounting: not applicable
**Severity**: Info
**Category**: flashloans
**Location**: `deposit()` — `src/AutopilotHook.sol:157`; `_doRebalance()` — `:324-336`
**Description**: Checked the checklist's share-price-manipulation and donation-inflation items. They do not
apply:

- There is **no pooled share accounting**. Each position is independent, keyed by
  `positionId = keccak256(abi.encode(msg.sender, id, depositNonce++))` (line 157), which is also used as the v4
  `salt`. A monotonically increasing `depositNonce` makes collisions impossible, so there is no "first depositor"
  or share-price surface, and no `totalSupply()` or `balanceOf()` anywhere in the pricing path.
- `poolManager.donate()` is callable by anyone, and donations accrue to in-range liquidity. For a hook position
  this *increases* the `feesAccrued` component folded into `removed` at line 324 (v4 returns
  `callerDelta = principalDelta + feesAccrued`), so `freed0`/`freed1` go up and the donated value flows either
  into the new position or back to the owner via lines 371-376. A donation is a gift, not an attack vector.
- The hook holds no token balance of its own between transactions (every operation nets to zero deltas inside
  one unlock), so there is no balance for an attacker to inflate or to have the contract mis-read.

One adjacent observation, flagged for the accounting workstream rather than claimed here: `_doRebalance()` has no
`settle` path, so if `net.amount0()` or `net.amount1()` is ever negative the unlock terminates with a non-zero
delta and `PoolManager.unlock()` reverts with `CurrencyNotSettled`. `getLiquidityForAmounts` rounds liquidity
down while v4's `modifyLiquidity` rounds the required amounts up for a positive `liquidityDelta`, so a 1-wei
shortfall looks reachable. We did not reproduce it and do not claim it here; routing it to the
arithmetic/rounding specialist.

**Proof of Concept**: Not exploitable as a donation/inflation attack. Blocking facts: unique per-position salt
from a monotonic nonce, no share accounting, no use of `totalSupply()`/`balanceOf()`, no persistent hook balance.

**Recommendation**: No change required for this class. If a `settle` path is added to `_doRebalance()` to handle
the rounding case noted above, re-check that it cannot be used to pull tokens from an address other than the
position owner.

---

## Out of lane (routed elsewhere)

- **Rebalancer-key abuse.** A malicious or compromised allowlisted rebalancer can pass `minLiquidity = 0` and an
  arbitrary `[newTickLower, newTickUpper]` within the deposit-time bounds, and trigger the unbounded swap
  directly with no third party involved — draining the position by the same mechanism as F-1 but without needing
  to induce or backrun anything. **This is not a flash-loan finding**, since it requires the rebalancer key, and
  per the rules of this pass it is routed to the access-control / privileged-role workstream. Flagging it only so
  it is not lost: the on-chain bound recommended in F-1 is also the mitigation for it, which is an argument for
  fixing F-1 on-chain rather than in the bot.
- **`minLiquidity` being a liquidity floor rather than a value floor** was established empirically by another
  agent; this pass builds on it (F-1, F-2) rather than re-deriving it.
- **The `CurrencyNotSettled` rounding concern** in F-10 is routed to the arithmetic/rounding specialist,
  unreproduced.

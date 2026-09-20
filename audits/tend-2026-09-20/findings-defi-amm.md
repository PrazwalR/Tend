# AutopilotHook — DeFi / AMM & Concentrated-Liquidity-Manager Findings

`contracts/src/AutopilotHook.sol` is a concentrated-liquidity manager implemented as a Uniswap v4 hook that
custodies liquidity directly on the PoolManager (it is the position `owner`, with `salt = positionId`). Only
`afterSwap` is enabled; the hook's own liquidity mechanics live in `deposit()`, `withdraw()` and `rebalance()`,
all of which run inside `poolManager.unlock()`. The dominant risk in this contract is the newly added
`_swapToRatio()` helper: it executes a market order **through the very pool it is rebalancing**, in the same
unlock, **immediately after removing that position's own liquidity**, with `sqrtPriceLimitX96` set to
`MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` — i.e. no price limit at all. Position sizing then reads
instantaneous `getSlot0()` spot with no TWAP or calm-period check, and the single piece of slippage protection,
`minLiquidity`, is chosen by the rebalancer bot itself (it may pass `0`) and constrains a *liquidity* number
rather than *value*. I confirmed with executed Foundry PoCs that a rebalance onto a one-sided range in a pool
whose only meaningful liquidity is the hook's own position drives `slot0` to `MAX_SQRT_PRICE - 1`
(tick `887271`) while the rebalance **succeeds**, and that an arbitrageur then takes the position's value. The
project's own passing test `test_rebalance_to_one_sided_range` already triggers this condition without
asserting on the resulting pool price. Secondary findings cover missing deadline, missing deposit-side
slippage, spot-price sizing, silent partial fills, and rebalancer trust scope. On the positive side I verified
that the hook permission bitmask and the `afterSwap` zero-delta return are handled correctly by v4-core, that
the hook's own swap cannot re-enter its own `_afterSwap` (v4's `noSelfCall` guard), and that accrued fees are
correctly rolled into the new position on rebalance.

## Findings by severity

| Severity | Count | IDs |
| --- | --- | --- |
| Critical | 1 | A-1 |
| High | 2 | A-2, A-3 |
| Medium | 5 | A-4, A-5, A-6, A-7, A-8 |
| Low | 4 | A-9, A-10, A-11, A-12 |
| Info | 4 | A-13, A-14, A-15, A-16 |
| **Total** | **16** | |

All PoCs below were executed against the vendored `lib/uniswap-hooks/lib/v4-core` using Foundry 1.5.1 with the
repo's own `foundry.toml` and `remappings.txt`. Log output is quoted verbatim.

---

## [A-1] `_swapToRatio()` swaps with no price limit through a pool it just drained, destroying `slot0` and handing the position to the first arbitrageur
**Severity**: Critical
**Category**: defi-amm
**Location**: `_swapToRatio()` — `contracts/src/AutopilotHook.sol:425-433`; enabled by `_doRebalance()` ordering at `contracts/src/AutopilotHook.sol:324-342`
**Description**:
`_doRebalance()` first burns the entire position (`liquidityDelta: -int256(uint256(cb.liquidity))`, line 329),
and only then calls `_swapToRatio()`. The swap is therefore executed against a pool from which the hook has
just removed its own — frequently dominant — liquidity, maximising its own price impact. The swap is issued as:

```solidity
return poolManager.swap(
    cb.key,
    SwapParams({
        zeroForOne: zeroForOne,
        amountSpecified: -int256(amountIn),
        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
    }),
    ""
);
```

`MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1` are precisely the sentinel values that mean "no limit" — they are
the loosest values `Pool.swap` will accept without reverting `PriceLimitOutOfBounds`
(`lib/uniswap-hooks/lib/v4-core/src/libraries/Pool.sol:328-337`). Worse, in the two one-sided branches the size
is the *entire* freed balance: `(zeroForOne, amountIn) = (false, have1)` at line 395 and
`(zeroForOne, amountIn) = (true, have0)` at line 399. There is no cap, no oracle, and no acceptable-execution-
price bound.

I verified the v4-core consequence directly. In `Pool.swap`, `SwapMath.computeSwapStep` with `liquidity == 0`
returns `amountIn = 0` and sets `sqrtPriceNextX96 = sqrtPriceTargetX96`
(`lib/uniswap-hooks/lib/v4-core/src/libraries/SwapMath.sol:66-76`), so `amountSpecifiedRemaining` never
decreases and the `while` loop at `Pool.sol:344` keeps walking whole tick-bitmap words until
`result.sqrtPriceX96 == params.sqrtPriceLimitX96`. `Pool.sol:439` then writes that extreme price straight into
`slot0`. Partial fills are legal in v4 — nothing reverts. The swap fills *nothing*, costs the hook nothing, and
sets the pool's price to a number ~1e19x away from reality.

`_doRebalance` then reads that wrecked price back on line 346 and sizes the new position with it, so the
`minLiquidity` floor is evaluated against the manipulated price too (see A-2).

**Proof of Concept**:
Executed PoC. Pool: `currency0/currency1`, fee 3000, tickSpacing 60, initialised at `SQRT_PRICE_1_1`
(tick 0, price 1.0). The hook's position is the pool's only liquidity — the default state for a pool spun up
for this vault, and exactly the state the repo's own `test_rebalance_to_one_sided_range` creates.

1. Owner calls `deposit(key, -600, 600, 1e18, minUsableTick, maxUsableTick)`. This pulls
   `29553010879137170` of each token (verified).
2. `vm.warp(+COOLDOWN)`.
3. Allowlisted bot calls `rebalance(pid, 600, 1200, 0)` — a perfectly ordinary "price moved up, recentre
   upward" instruction, and the same call shape as the repo's `test_rebalance_to_one_sided_range`.
4. Inside `_doRebalance`: the 1e18 of liquidity is burned, leaving the pool with `liquidity == 0` and no
   initialised ticks. `_swapToRatio` takes the `sqrtPriceX96 <= sqrtA` branch (new range sits above spot) and
   issues `oneForZero` for **all** of `have1` with `sqrtPriceLimitX96 = MAX_SQRT_PRICE - 1`.

Measured result:

```
before  sqrtP 79228162514264337593543950336
before  tick  0
after   sqrtP 1461446703485210103287273052203988822378723970341
after   tick  887271
newLiq        941767358693748038
MAX_SQRT-1    1461446703485210103287273052203988822378723970341
```

`rebalance()` returns successfully with the pool's price pinned at `MAX_SQRT_PRICE - 1`.

5. The first arbitrageur (anyone) swaps `zeroForOne` to walk the price back toward fair. The victim's new
   position at `[600, 1200]` is entirely token1 and sits far below spot, so it is fully converted on the way
   down:

```
tick after arb       -887272
VICTIM   net t0  +27090812232353785
VICTIM   net t1  -29553010879137170
ATTACKER net t0  -27090812232353788
ATTACKER net t1  +29553010879137168
```

The victim surrendered `2.9553e16` token1 and received only `2.7091e16` token0 at a fair price of 1:1 — an
8.3% loss on that leg, transferred one-for-one to the arbitrageur. The loss is not capped at 8.3%: it scales
with the distance between the wrecked price and the new range. Rebalancing to `[60, 60000]` produces the same
`tick 887271` and leaves the position exposed across a range whose top is priced ~403x fair.

**An attacker can manufacture the precondition permissionlessly**, which is why this is Critical rather than
High. The thin-liquidity state does not have to occur naturally — an LP in the pool creates it on demand:

- **tx 1 (attacker front-run)**: attacker, who is an ordinary LP in the pool, calls
  `modifyLiquidity(..., liquidityDelta: -1e21, ...)` removing all their liquidity. No permission needed.
- **tx 2 (victim, same block, behind tx 1)**: the bot's pending `rebalance(pid, 600, 1200, 0)` executes.
  The pool now has zero liquidity once the hook burns its own position, so `_swapToRatio` walks `slot0` to
  `MAX_SQRT_PRICE - 1`. Verified: `attack tick after rebalance 887271`.
- **tx 3 (attacker back-run)**: attacker swaps `zeroForOne`, buying the victim's whole position on the way
  back down, then re-adds their liquidity (`liquidityDelta: +1e21`) to restore the pool for the next cycle.

The attacker risks nothing: removing and re-adding one's own liquidity is free, and the back-run is an
ordinary swap. Because `minRebalanceInterval` is the only rate limit, this is repeatable every cooldown.

**Recommendation**:
Do not use sentinel price limits. Derive an explicit, caller-supplied bound and enforce it, and also require
that the pool can actually absorb the trade:

```solidity
struct Callback { /* ... */ uint160 sqrtPriceLimitX96; uint256 minAmountOut; }

function _swapToRatio(Callback memory cb, uint256 have0, uint256 have1) internal returns (BalanceDelta) {
    // ... direction/size selection unchanged ...
    if (amountIn == 0) return BalanceDeltaLibrary.ZERO_DELTA;

    // caller-supplied, computed off-chain against a TWAP; never a MIN/MAX sentinel
    uint160 limit = cb.sqrtPriceLimitX96;
    require(limit != 0, "no price limit");
    if (zeroForOne) require(limit > TickMath.MIN_SQRT_PRICE, "limit too loose");
    else require(limit < TickMath.MAX_SQRT_PRICE, "limit too loose");

    BalanceDelta d = poolManager.swap(
        cb.key,
        SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
        ""
    );

    // reject the silent partial fill: the limit was hit before the order filled
    int128 spent = zeroForOne ? d.amount0() : d.amount1();
    require(uint256(uint128(-spent)) * 1e4 >= amountIn * 9_900, "partial fill");
    int128 got = zeroForOne ? d.amount1() : d.amount0();
    require(uint256(uint128(got)) >= cb.minAmountOut, "swap slippage");
    return d;
}
```

Additionally, bound the limit on-chain against a TWAP observation so a compromised bot cannot pass a useless
one (see A-4), and consider routing the re-ratio trade through an external venue so the rebalance does not
trade against a pool it has just drained (see A-5).

---

## [A-2] `minLiquidity` is the only slippage guard, is supplied by the rebalancer itself, and bounds a liquidity number rather than value
**Severity**: High
**Category**: defi-amm
**Location**: `rebalance()` — `contracts/src/AutopilotHook.sol:225`; check at `_doRebalance()` — `contracts/src/AutopilotHook.sol:346-355`
**Description**:
The in-code comment at lines 379-383 states that "the caller's `minLiquidity` floor is what actually bounds an
adverse fill." That is not true, for three independent reasons.

1. **It is supplied by the party being bounded.** `rebalance(bytes32, int24, int24, uint128 minLiquidity)` is
   `onlyRebalancer`, and the rebalancer passes `minLiquidity`. The bot whose trade needs constraining chooses
   its own constraint, and may pass `0`. The repo's own tests do exactly that in eight places
   (`hook.rebalance(pid, -1200, 1200, 0)`). A compromised, buggy or MEV-captured bot simply passes `0`.
   This is the CLM analogue of the checklist's "hardcoded slippage / `minAmountOut = 0`" item.

2. **It is evaluated at the post-swap, already-manipulated spot price.** Line 346 re-reads `getSlot0()`
   *after* `_swapToRatio()` has moved the price, and line 347 feeds that price into
   `LiquidityAmounts.getLiquidityForAmounts`. This is the checklist's "on-chain slippage calculation is
   manipulable" pattern in its purest form: the value the check compares against is derived from state the
   attacker just moved.

3. **Liquidity `L` is not value.** `getLiquidityForAmounts` returns
   `getLiquidityForAmount0(sqrtA, sqrtB, amount0)` when spot is below the range and
   `getLiquidityForAmount1(sqrtA, sqrtB, amount1)` when spot is above it
   (`lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol:62-73`) — the other token is
   ignored entirely. Pushing the price outside the new range therefore makes `L` a function of a single
   token balance at fixed range endpoints, which is *not* reduced by an adverse fill in the way a value-
   denominated check would be.

**Proof of Concept**:
Executed. Same setup as A-1 (`deposit(key, -600, 600, 1e18, ...)`, then `rebalance(pid, 600, 1200, floor)`).
The honest expectation for this recentre is `L ≈ 1e18`, so a realistic bot would pass a 1–7% floor.

- `minLiquidity = 0` → passes, `slot0` wrecked to tick `887271`.
- `minLiquidity = 0.93e18` (a **7%** slippage tolerance — already far looser than any bot would need, and
  looser than most would set) → **passes**:

```
newLiq                         941767358693748038
tick after (should be ~887271) 887271
```

  `941767358693748038 / 1e18 = 94.18%`, so any floor at or below 94% of the honest expectation lets the
  price destruction through untouched.
- Only `minLiquidity = 1e18` (a **0%** tolerance — i.e. demanding the rebalance be exactly lossless, which
  would make every real rebalance revert on fees and rounding) catches it:
  `[FAIL: SlippageExceeded(941767358693748038, 1000000000000000000)]`.

There is therefore no setting of `minLiquidity` that is simultaneously tight enough to stop A-1 and loose
enough for the contract to function.

**Recommendation**:
Replace the liquidity floor with value-denominated, owner-controlled bounds, and remove the rebalancer's
discretion over them:

```solidity
// stored per position at deposit(), settable only by the position owner
mapping(bytes32 => uint16) public maxRebalanceSlippageBps;

// in _doRebalance, BEFORE the swap, using a TWAP price (see A-4):
uint160 twapSqrtPrice = _twapSqrtPrice(cb.key, twapWindow);
uint256 valueBefore = _inToken1(freed0, twapSqrtPrice) + freed1;

// ... _swapToRatio ...

uint256 valueAfter = _inToken1(freed0, twapSqrtPrice) + freed1; // same reference price both sides
if (valueAfter < valueBefore * (10_000 - maxRebalanceSlippageBps[cb.positionId]) / 10_000) {
    revert SlippageExceeded(uint128(valueAfter), uint128(valueBefore));
}
```

Valuing both sides at the *same* TWAP reference price makes the check measure the trade's real cost instead
of a number that moves with the manipulation. Keep `minLiquidity` as an additional bot-side sanity floor, but
do not treat it as the protection.

---

## [A-3] Sandwich of `rebalance()`: the bot chooses the range and the swap size, but an attacker chooses the price it trades at
**Severity**: High
**Category**: defi-amm
**Location**: `rebalance()` / `_doRebalance()` / `_swapToRatio()` — `contracts/src/AutopilotHook.sol:225-269, 323-434`
**Description**:
`rebalance()` is a public transaction with no private-mempool requirement, no deadline, and (per A-2) no
effective slippage bound. Its execution path contains a market order whose size and direction are fully
predictable from public state — `positions[positionId]`, `boundLower/boundUpper`, and the `newTickLower/
newTickUpper` arguments visible in the pending calldata. An observer can compute, before the transaction
lands, exactly which direction `_swapToRatio` will trade and exactly how much, because the branch selection at
lines 392-421 is a pure function of `getSlot0()`, the new range, and `cb.liquidity`.

One honest nuance worth recording, since it constrains the attack: in the *straddling* branch (lines 400-421)
the re-ratio trade is partially self-correcting. If an attacker pushes the price down, the freed position is
token0-heavy and `want1` shrinks, so `target1 <= have1` and the hook trades `oneForZero` — *against* the
manipulation, which is unprofitable to sandwich. A naive same-direction sandwich of the straddling branch does
not pay. The exploitable ordering is therefore the liquidity-withdrawal sandwich, not a price sandwich.

**Proof of Concept**:
Executed (`test_full_drain`). Attacker `0xA11CE` is an ordinary LP in the pool with `L = 1e21` over
`[-60000, 60000]`; the victim holds a hook position of `L = 1e18` over `[-600, 600]`; spot is tick 0. The bot's
`rebalance(pid, 600, 1200, 0)` is sitting in the public mempool. The attacker builds this bundle:

- **tx 1 — attacker front-run.** `modifyLiquidityRouter.modifyLiquidity(key, {tickLower: -60000,
  tickUpper: 60000, liquidityDelta: -1e21, salt: 0})`. Removes 100% of the pool's external liquidity.
  Cost: gas only; the attacker receives their own tokens back.
- **tx 2 — the victim's transaction, ordered immediately behind.** `rebalance(pid, 600, 1200, 0)` runs.
  `_doRebalance` burns the victim's 1e18, leaving the pool with zero active liquidity. `_swapToRatio` selects
  the `sqrtPriceX96 <= sqrtA` branch, sells 100% of `have1` with `sqrtPriceLimitX96 = MAX_SQRT_PRICE - 1`,
  and the price free-runs to the ceiling. Verified log: `attack tick after rebalance 887271`. `minLiquidity`
  is `0`, so nothing reverts; even at `0.93e18` nothing would revert (A-2).
- **tx 3 — attacker back-run.** `swap(zeroForOne: true, amountSpecified: -1e18,
  sqrtPriceLimitX96: MIN_SQRT_PRICE + 1)`. This walks the price back down through the victim's new
  `[600, 1200]` position, buying the whole thing. Verified: `tick after attacker arb -887272`.
- **tx 4 — attacker restores.** `modifyLiquidity(..., liquidityDelta: +1e21, ...)` puts the attacker's
  liquidity back so the pool looks untouched and the attack can be repeated after `minRebalanceInterval`.

Measured on the clean two-party variant (`test_position_left_in_wrecked_pool`, victim and attacker are
separate contracts so balances are not commingled):

```
VICTIM   net t0  +27090812232353785
VICTIM   net t1  -29553010879137170
ATTACKER net t0  -27090812232353788
ATTACKER net t1  +29553010879137168
```

The transfer is exact and one-directional: `2.9553e16` token1 out of the victim, `2.7091e16` token0 back in,
at a true price of 1:1. The attacker's profit is the `2.46e15` difference plus whatever the wider range
variant yields. Repeating every `minRebalanceInterval` compounds it.

**Recommendation**:
Layer three defences rather than relying on any one:

1. Fix A-1 (explicit price limit) — this alone removes the free-run and caps the damage to the depth the
   attacker is willing to fund.
2. Fix A-2 (value-denominated, owner-set slippage bound evaluated against a TWAP).
3. Require that the pool has sufficient non-hook liquidity for the trade before swapping, so a JIT liquidity
   pull cannot create the condition:

```solidity
uint128 poolLiquidity = poolManager.getLiquidity(cb.key.toId()); // after the burn
if (poolLiquidity < minExternalLiquidity[cb.key.toId()]) revert InsufficientPoolDepth();
```

4. Submit `rebalance()` through a private mempool / builder endpoint. This is an operational mitigation only
   and must not be the primary control.

---

## [A-4] Position sizing and swap sizing read instantaneous `getSlot0()` spot with no TWAP or calm-period check
**Severity**: Medium
**Category**: defi-amm
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:346`; `_swapToRatio()` — `contracts/src/AutopilotHook.sol:385`
**Description**:
Both price reads in the rebalance path are raw spot:

```solidity
(uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cb.key.toId());   // line 346, sizes the new position
(uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cb.key.toId());   // line 385, sizes and directs the swap
```

`Pool.State.slot0` is written by the last swap in the same block — it is the canonical manipulable spot price,
and the checklist's "pool reserves are manipulable / never use as an oracle" item applies directly. This is
also the Dacian CLM finding that cost Beefy Finance ~$1.2M: liquidity deployment driven by an unchecked
instantaneous price, with no `onlyCalmPeriods`-style guard comparing spot against a TWAP before committing
funds.

Every branch of `_swapToRatio` depends on this value: which of the three branches is taken (lines 392, 396,
400), the direction, `want0`/`want1`, `target1`, and the `_inToken0`/`_inToken1` conversions. `_doRebalance`
then re-reads it to size the new position. There is no `maxDeviation`, no observation window, and no revert
path for "the price is currently abnormal".

I have kept this Medium rather than High because in this contract the spot read is not independently
exploitable — it is the *mechanism* by which A-1 and A-3 do their damage, and those carry the severity. Rated
on its own, it is a missing control rather than a standalone loss path.

**Proof of Concept**:
Not separately exploitable from A-1/A-3; the failure mode is that the contract has no way to notice it is
being manipulated. Concretely, in the A-1 PoC the second read at line 346 returns
`1461446703485210103287273052203988822378723970341` (`MAX_SQRT_PRICE - 1`) and the contract accepts it as a
legitimate price, sizing and committing the owner's entire position against it. A TWAP comparison would have
rejected that number instantly — the observed spot is ~1e19x the 1-block-old price.

**Recommendation**:
Add a calm-period guard executed before any liquidity is burned, with hard-coded bounds on the parameters so
the owner cannot neuter it (the Gamma Strategies failure mode — "owner rug-pull via ineffective TWAP
parameters"):

```solidity
uint32 public constant MIN_TWAP_WINDOW = 300;      // 5 min, not owner-settable below this
uint16 public constant MAX_DEVIATION_BPS = 200;    // 2%, hard cap

function _requireCalm(PoolKey memory key) internal view {
    (uint160 spot,,,) = poolManager.getSlot0(key.toId());
    uint160 twap = _twapSqrtPrice(key, twapWindow);   // twapWindow >= MIN_TWAP_WINDOW, enforced in setter
    uint256 diff = spot > twap ? spot - twap : twap - spot;
    if (diff * 10_000 / twap > maxDeviationBps) revert PriceNotCalm();  // maxDeviationBps <= MAX_DEVIATION_BPS
}
```

v4 does not expose a native TWAP, so this requires either a companion observation-recording hook (note the
`beforeSwap`/`afterSwap` flags are address-encoded and cannot be added post-deployment — see A-13) or an
external oracle such as Chainlink for the pair. Call `_requireCalm(cb.key)` at the top of `_doRebalance`.

---

## [A-5] Liquidity is burned before the re-ratio swap, so the hook trades against a pool it has itself just emptied
**Severity**: Medium
**Category**: defi-amm
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:324-342`
**Description**:
The ordering in `_doRebalance` is: `modifyLiquidity(-cb.liquidity)` (line 324-333) → `_swapToRatio` (line 342)
→ `modifyLiquidity(+newLiquidity)` (line 357). The position's own liquidity is therefore *not available* to
absorb the hook's own swap. For a vault whose whole purpose is to be a significant LP in its pool, this is
self-inflicted price impact: the larger the managed position relative to the pool, the worse its own rebalance
executes, and the effect is superlinear because removing depth both widens the spread and lengthens the
distance the price travels per unit of size.

In the degenerate case — the hook is the *only* LP — the pool's active liquidity after line 333 is exactly
zero, which is the precondition for A-1.

**Proof of Concept**:
Failure mode rather than a discrete exploit. In the A-1 PoC the pool holds `L = 1e18` entirely owned by the
hook. After line 333 executes, `Pool.State.liquidity == 0` and the tick bitmap has no initialised ticks left,
so `SwapMath.computeSwapStep` returns `amountIn = 0` at every step and the price walks unopposed to the
sentinel limit. With the ordering reversed — swap first, burn second — the position's own `1e18` of depth
would have absorbed the trade and the price could not have moved more than the normal impact of a trade of
that size against `1e18` of liquidity.

**Recommendation**:
Either (a) reorder so the re-ratio swap executes *before* the burn, when the position's own depth is still
backing the pool (the amounts to trade can be computed from the position's known composition without
removing it first); or (b) route the re-ratio trade to a different venue entirely so a rebalance never trades
against its own vacated book; or (c) split the burn — remove only the portion not needed to back the swap.
Option (b) is the most robust and is what mature CLMs do. Whichever is chosen, A-1's explicit price limit is
still required.

---

## [A-6] Partial fills of the re-ratio swap are silently accepted
**Severity**: Medium
**Category**: defi-amm
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:342-344`; `_swapToRatio()` return at `contracts/src/AutopilotHook.sol:425-433`
**Description**:
`_swapToRatio` returns a `BalanceDelta` that is folded in with no inspection:

```solidity
BalanceDelta swapped = _swapToRatio(cb, freed0, freed1);
freed0 = _add(freed0, swapped.amount0());
freed1 = _add(freed1, swapped.amount1());
```

Nothing compares the realised input against the requested `amountIn`. v4's `Pool.swap` stops early whenever
`result.sqrtPriceX96 == params.sqrtPriceLimitX96` (`Pool.sol:344`) and returns whatever it managed to fill —
partial fills are a normal, non-reverting outcome. A fill of **zero** is therefore indistinguishable, to this
code, from a complete fill. The comment on lines 379-383 explicitly reasons that "exactness is not required
because any residual is returned to the owner", which is correct about *rounding* residue but does not hold
when the fill is 0% and the contract proceeds to commit the position anyway.

This is the mechanism that lets A-1 complete successfully rather than reverting: the swap fills nothing, the
freed balances are unchanged, `getLiquidityForAmounts` at the extreme price computes `L` from the single
untouched token balance, the `minLiquidity` floor passes, and the position is committed into a pool whose
price the same call just destroyed.

**Proof of Concept**:
Executed, A-1 PoC. The `oneForZero` swap for the full `have1` fills `0` (the price reaches
`MAX_SQRT_PRICE - 1` before any liquidity is encountered), so `swapped` is `ZERO_DELTA` and `freed0`/`freed1`
are unchanged. `_doRebalance` continues to line 346, reads the wrecked price, computes
`newLiquidity = 941767358693748038` from the *unswapped* `freed1` via
`getLiquidityForAmount1(sqrtA, sqrtB, freed1)` — a number 94% of the honest expectation — passes the floor,
and adds the position. A one-line fill check at line 343 would have reverted the whole unlock.

**Recommendation**:
Assert the fill in `_swapToRatio` before returning (see the snippet in A-1's recommendation):

```solidity
BalanceDelta d = poolManager.swap(...);
int128 spentSigned = zeroForOne ? d.amount0() : d.amount1();
uint256 spent = uint256(uint128(-spentSigned));
if (spent * 10_000 < amountIn * 9_900) revert PartialFill(spent, amountIn);  // >=99% must fill
return d;
```

A partial fill means the price limit bound — which after A-1's fix is the real signal that execution went
outside tolerance — so reverting is the correct response.

---

## [A-7] `deposit()` has no maximum-amount slippage guard
**Severity**: Medium
**Category**: defi-amm
**Location**: `deposit()` — `contracts/src/AutopilotHook.sol:141-189`; `_doDeposit()` — `contracts/src/AutopilotHook.sol:285-302`
**Description**:
`deposit()` takes a target `liquidity` but no `amount0Max`/`amount1Max`. The token amounts actually pulled are
whatever `modifyLiquidity` computes at the spot price at execution time, and `_doDeposit` settles them
unconditionally from the depositor:

```solidity
if (delta.amount0() < 0) cb.key.currency0.settle(poolManager, cb.owner, uint256(uint128(-delta.amount0())), false);
if (delta.amount1() < 0) cb.key.currency1.settle(poolManager, cb.owner, uint256(uint128(-delta.amount1())), false);
```

Since the depositor has granted the hook an allowance, an attacker who moves the spot price to one edge of
`[tickLower, tickUpper]` immediately before the deposit forces the depositor to fund the position entirely in
whichever token is momentarily expensive; when the price reverts, the depositor holds an adverse mix. This is
the checklist's "hardcoded slippage / missing minimum" item on the liquidity-provision side. Every other
entry point in the contract at least nominally accepts a bound; `deposit()` accepts none.

**Proof of Concept**:
Ordering, against a depositor with a pending `deposit(key, -600, 600, 1e18, ...)`:

1. Attacker front-runs with `swap(zeroForOne: false, ...)` sized to move spot from tick 0 to tick ~600 — the
   top of the victim's intended range.
2. The victim's `deposit` executes. At spot ≈ `sqrtPriceAtTick(600)`, `getAmountsForLiquidity` for
   `[-600, 600]` requires ~100% token1 and ~0 token0, so the victim's entire contribution is pulled in
   token1 at an inflated token1 valuation instead of the ~50/50 split they expected at tick 0.
3. Attacker back-runs with `swap(zeroForOne: true, ...)`, restoring spot to tick 0 and recovering their
   position; the victim's freshly minted position converts back across the range at the LP's expense.

I have not measured an end-to-end profit figure for this ordering, because in a fee-bearing pool the
round-trip swap costs the attacker two lots of LP fee and the victim earns some of it — so the net can be
marginal in a deep pool with a wide range. The severity reflects the missing control (the depositor has no way
to express a spend cap at all), not a demonstrated profit. Treated as Medium on that basis.

**Recommendation**:
```solidity
function deposit(
    PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity,
    int24 minBound, int24 maxBound,
    uint256 amount0Max, uint256 amount1Max        // new
) external whenNotPaused nonReentrant returns (bytes32 positionId) { ... }

// in _doDeposit:
if (uint256(uint128(-delta.amount0())) > cb.amount0Max) revert ExcessiveInput();
if (uint256(uint128(-delta.amount1())) > cb.amount1Max) revert ExcessiveInput();
```

---

## [A-8] The rebalancer picks the new range, the swap size and the slippage floor; the owner's only control is a static tick envelope
**Severity**: Medium
**Category**: defi-amm
**Location**: `rebalance()` — `contracts/src/AutopilotHook.sol:225-269`; bounds check at `contracts/src/AutopilotHook.sol:240`
**Description**:
The owner's envelope is checked only as
`if (newTickLower < boundLower[positionId] || newTickUpper > boundUpper[positionId]) revert OutOfBounds();`.
That constrains where the range may sit, but not:

- how **wide** it is — a rebalancer may collapse a position into a single `tickSpacing`-wide range, or expand
  it to the full envelope, changing the position's risk profile arbitrarily;
- whether the range **straddles spot** — placing it entirely to one side converts the position wholesale into
  a single token via `_swapToRatio` (the two one-sided branches at lines 392-399 trade the *entire* balance);
- how **often** — only `minRebalanceInterval` gates it, and the constructor accepts `cooldown = 0`
  (`contracts/src/AutopilotHook.sol:118` only rejects `> MAX_REBALANCE_INTERVAL`), permitting unlimited
  rebalances in a single block;
- the **slippage floor** — `minLiquidity` is the rebalancer's own argument (A-2).

The realistic default envelope is the widest one: the repo's own helper uses
`hook.deposit(key, lo, hi, liq, TickMath.minUsableTick(60), TickMath.maxUsableTick(60))`
(`contracts/test/AutopilotHook.t.sol:48-50`), i.e. the full tick range, under which the envelope check is a
no-op and the rebalancer has unlimited discretion. With `cooldown = 0`, a compromised bot can bleed the
position to zero through repeated round-trip rebalances, each paying LP fees and price impact, without ever
tripping a single check.

**Proof of Concept**:
Ordering, with the default full-range envelope and `minRebalanceInterval = 0`:

1. Attacker compromises (or the operator misconfigures) an address in `isRebalancer`.
2. Attacker calls `rebalance(pid, 600, 1200, 0)` — within bounds, one-sided, so `_swapToRatio` converts the
   whole position to token0 via a full-size market order paying 0.30% LP fee plus impact.
3. In the same block, `rebalance(pid, -1200, -600, 0)` — also within bounds, one-sided the other way, so the
   whole position is converted back, paying the fee and impact again.
4. Repeat. Each round trip is a guaranteed ~0.6%+ loss with no revert path. 100 round trips leaves the
   position at roughly `0.994^100 ≈ 55%` of its starting value, and in a thin pool A-1 makes each iteration
   far more destructive than the fee alone.

Note this requires a compromised or malicious rebalancer, which is a trust-model violation rather than a
permissionless exploit — hence Medium per the stated definitions ("trust model violation ... or owner-only
fund loss").

**Recommendation**:
Constrain the shape and cadence of a rebalance, not just its location, and move slippage out of the
rebalancer's hands:

```solidity
// per-position, set by the owner at deposit()
struct Guard { int24 minWidth; int24 maxWidth; bool requireStraddle; uint16 maxSlippageBps; }
mapping(bytes32 => Guard) public guards;

// in rebalance():
int24 width = newTickUpper - newTickLower;
Guard memory g = guards[positionId];
if (width < g.minWidth || width > g.maxWidth) revert BadWidth();
if (g.requireStraddle) {
    (, int24 tick,,) = poolManager.getSlot0(key.toId());
    if (tick < newTickLower || tick >= newTickUpper) revert MustStraddleSpot();
}
```

Also reject `cooldown == 0` in the constructor and in `setMinRebalanceInterval`, and enforce a sane minimum
(e.g. `MIN_REBALANCE_INTERVAL = 1 hours`).

---

## [A-9] `rebalance()` and `deposit()` have no deadline parameter
**Severity**: Low
**Category**: defi-amm
**Location**: `rebalance()` — `contracts/src/AutopilotHook.sol:225`; `deposit()` — `contracts/src/AutopilotHook.sol:141`
**Description**:
Neither entry point accepts a `deadline`. A validator, builder or the bot's own relay can hold a signed
`rebalance` transaction and include it many blocks — or hours — later, at which point the `minLiquidity` value
the bot computed against the price at signing time is stale and meaningless. `minRebalanceInterval` bounds how
*often* a rebalance may occur but says nothing about how *old* a pending one may be; the cooldown check
(`if (block.timestamp < readyAt) revert RebalanceTooSoon`) only rejects transactions that are too early.
This is the checklist's "no expiration deadline" item. Note also that a deadline of `block.timestamp` would
provide no protection at all — it must be a caller-supplied future timestamp.

**Proof of Concept**:
Not a standalone exploit. Failure mode: the bot signs `rebalance(pid, lo, hi, minLiquidity)` at block N with
`minLiquidity` computed for the price at block N. A builder withholds it. At block N+2000 the price has moved
20%; the transaction still executes, and `minLiquidity` — derived from a price that no longer exists — is
either trivially satisfied or causes a spurious revert. Combined with A-2 this widens the window in which A-1
and A-3 can be set up.

**Recommendation**:
```solidity
error DeadlinePassed();
function rebalance(bytes32 positionId, int24 newTickLower, int24 newTickUpper, uint128 minLiquidity, uint256 deadline)
    external whenNotPaused nonReentrant returns (uint128 newLiquidity)
{
    if (block.timestamp > deadline) revert DeadlinePassed();
    ...
}
```
Apply the same to `deposit()`.

---

## [A-10] `_add()` silently clamps an underflow to zero, masking accounting errors
**Severity**: Low
**Category**: defi-amm
**Location**: `_add()` — `contracts/src/AutopilotHook.sol:446-450`
**Description**:
```solidity
function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    return base > sub ? base - sub : 0;
}
```
The `: 0` branch turns "the swap consumed more of this token than we had freed" — which should be impossible
and therefore indicates a logic error — into a silently plausible `0`. `_doRebalance` then proceeds to size and
commit a position using that fabricated zero. Because the freed balances are exactly the values the position
is rebuilt from, any discrepancy here is an accounting error that should halt the unlock, not be smoothed
over. Solidity 0.8 checked arithmetic would have caught it for free.

**Proof of Concept**:
I did not find a reachable path where `sub > base` in the current code: `_swapToRatio` always sizes
`amountIn <= have0`/`have1` for the token being sold, and v4 never charges more input than `amountSpecified`
for an exact-input swap. So this is a latent robustness issue rather than a live bug — which is why it is Low.
It becomes live the moment `_swapToRatio`'s sizing is modified (e.g. to add a fee, or to swap exact-output),
and it would then fail silently.

**Recommendation**:
```solidity
function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    if (sub > base) revert AccountingUnderflow();   // do not clamp
    return base - sub;
}
```

---

## [A-11] Rebalance can revert on overflow at extreme `sqrtPriceX96`, and A-1 can leave a pool permanently in that state
**Severity**: Low
**Category**: defi-amm
**Location**: `_inToken1()` / `_inToken0()` — `contracts/src/AutopilotHook.sol:436-444`; `getLiquidityForAmounts` cast at `contracts/src/AutopilotHook.sol:347`
**Description**:
`_inToken1` squares the price via two chained `FullMath.mulDiv` calls:

```solidity
uint256 half = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
return FullMath.mulDiv(half, sqrtPriceX96, FixedPoint96.Q96);
```

Near `MAX_SQRT_PRICE` the ratio `sqrtPriceX96 / Q96` is ~1.8e19, so the result is `amount0 * ~3.4e38`.
`FullMath.mulDiv` reverts when the result exceeds `2^256`, which happens for `amount0` above roughly `3.4e38`.
Separately, `LiquidityAmounts.getLiquidityForAmount0/1` end in `.toUint128()`
(`lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol:26, 42`), which is a reverting
`SafeCast` — at an extreme price with a narrow target range, `L` can exceed `uint128`. This is the Dacian CLM
item "protocol should not revert due to overflow for valid range of `sqrtPriceX96` values".

The compounding concern is with A-1: once `_swapToRatio` has pinned a pool at `MAX_SQRT_PRICE - 1`, a
*subsequent* `rebalance()` on that pool reads that price at lines 346 and 385 and may revert in exactly these
places — leaving the position unable to be rebalanced out of the broken state (though `withdraw()`, which
takes no price reads and only burns, still works, so funds are not locked).

**Proof of Concept**:
I did not construct a concrete overflowing input, so I am flagging this as a latent bound rather than a
demonstrated revert, and rating it Low accordingly. The reachable extreme price is demonstrated by A-1
(`sqrtPriceX96 = 1461446703485210103287273052203988822378723970341`); whether a given position's balances are
large enough to overflow from there depends on token decimals and position size.

**Recommendation**:
Fixing A-1 removes the reachable extreme price, which is the main mitigation. Additionally, bound the price
used for sizing to a sane band before doing arithmetic with it (the TWAP guard in A-4 does this), and
consider computing the value ratio without squaring — e.g. compare `amount0 * sqrtP` against `amount1 * Q96`
in 512-bit space rather than materialising a token1-denominated value.

---

## [A-12] No token rescue, and fee-on-transfer / rebasing tokens are neither supported nor rejected
**Severity**: Low
**Category**: defi-amm
**Location**: contract-wide; `_doDeposit()` — `contracts/src/AutopilotHook.sol:296-301`; `_doWithdraw()` / `_doRebalance()` surplus handling — `contracts/src/AutopilotHook.sol:315-320, 370-376`
**Description**:
Two related gaps, both minor here:

1. **No sweep function.** The contract has `pause`, `unpause`, `setRebalancer` and `setMinRebalanceInterval`,
   but no way to recover ERC-20s sent to the hook address. I verified the normal paths leave nothing behind —
   `CurrencySettler.settle` transfers directly from `payer` to the PoolManager and `take` transfers directly
   to `recipient`, so the hook never holds balances (measured: `hook t0 bal 0`, `hook t1 bal 0` after a
   wrecked rebalance). But airdrops, mistaken transfers, or a future code path that takes to `address(this)`
   would be stranded permanently.

2. **FOT / rebasing tokens.** `deposit()` validates only that `currency0` is not native
   (`if (Currency.unwrap(key.currency0) == address(0)) revert NativeNotSupported();` — note this is sufficient
   to exclude native on both sides, since v4 requires `currency0 < currency1`). Nothing rejects fee-on-
   transfer or rebasing tokens. For FOT the failure is safe-but-opaque: `settle()` syncs, transfers `amount`
   from the payer, the PoolManager credits only the post-fee amount, the delta stays negative, and
   `unlock()`'s `NonzeroDeltaCount` check reverts the whole transaction — so deposits simply fail with an
   unhelpful error. Rebasing tokens are worse in kind (the checklist's "rebasing tokens break AMM accounting"
   item) but the hook tracks liquidity `L` rather than balances, so the divergence lands on the v4 pool rather
   than on this contract's books.

**Proof of Concept**:
Verified absence of stuck balances in the normal and wrecked paths (logged `hook t0 bal 0` / `hook t1 bal 0`).
The FOT revert path is by inspection of `CurrencySettler.settle`
(`lib/uniswap-hooks/src/utils/CurrencySettler.sol:32-52`) plus `PoolManager.unlock`'s
`if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();`
(`lib/uniswap-hooks/lib/v4-core/src/PoolManager.sol:103-105`) — I did not execute it. Rated Low: no funds
are at risk, the failure is a revert.

**Recommendation**:
```solidity
function rescue(address token, address to, uint256 amount) external onlyOwner {
    // no position ever holds a balance here, so any balance is stray
    IERC20(token).safeTransfer(to, amount);
}
```
And document the token assumption explicitly (standard ERC-20, no transfer fee, no rebase), or add an
allowlist of supported currencies checked in `deposit()`.

---

## [A-13] Hook permission bits and the `afterSwap` zero-delta return are handled correctly — verified
**Severity**: Info
**Category**: defi-amm
**Location**: `getHookPermissions()` — `contracts/src/AutopilotHook.sol:123-125`; `_afterSwap()` — `contracts/src/AutopilotHook.sol:127-139`; `contracts/script/DeployAutopilotHook.s.sol:19-27`
**Description**:
Checked against the checklist's address-mining and return-type items; no issue found. Recording the
verification so it is not re-litigated:

- `getHookPermissions()` sets only `p.afterSwap = true`. `BaseHook`'s constructor calls
  `Hooks.validateHookPermissions`, which reverts unless the deployed address's low bits match the declared
  permission set exactly (`lib/uniswap-hooks/lib/v4-core/src/libraries/Hooks.sol:85-99`). A mis-mined address
  cannot be deployed at all, so the "silently never called" failure mode is closed.
- `DeployAutopilotHook.s.sol` mines with `uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG)` via
  `HookMiner.find` and asserts `address(hook) == predicted`. Correct.
- `_afterSwap` returns `(BaseHook.afterSwap.selector, int128(0))`. `AFTER_SWAP_RETURNS_DELTA_FLAG` is *not*
  set, so `Hooks.afterSwap` calls `callHookWithReturnDelta(..., parseReturn: false)`, which returns `0`
  without parsing (`Hooks.sol:159-167`). The `int128(0)` is discarded; `hookDelta` stays `ZERO_DELTA` and
  `_accountPoolBalanceDelta` is skipped (`PoolManager.sol:213-216`). No unsettled-delta risk. Note that
  `BaseHook.afterSwap.selector` and `IHooks.afterSwap.selector` are identical (same signature), so the
  selector check in `callHook` passes.
- `Hooks.isValidHookAddress` is enforced at `initialize()`, and the hook cannot gain `beforeSwap`/oracle
  callbacks later without redeploying to a newly mined address — relevant to the A-4 recommendation.

**Proof of Concept**: N/A — verification, not a finding.
**Recommendation**: None. If a TWAP-recording `afterSwap`/`beforeSwap` is added per A-4, remember the address
must be re-mined and the hook redeployed; existing pools cannot be migrated to the new hook address.

---

## [A-14] The hook's own re-ratio swap does not re-enter `_afterSwap` — verified, no reentrancy
**Severity**: Info
**Category**: defi-amm
**Location**: `_swapToRatio()` — `contracts/src/AutopilotHook.sol:425`; `lib/uniswap-hooks/lib/v4-core/src/libraries/Hooks.sol:293`
**Description**:
I examined the concern that `poolManager.swap()` inside `_swapToRatio` would call back into this hook's
`afterSwap` mid-unlock, while `positions[positionId]` is in an inconsistent state (liquidity burned, not yet
re-added) and `poolPositionCount` still reads `1`. It does not. `Hooks.afterSwap` opens with:

```solidity
if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
```

`msg.sender` there is the caller of `PoolManager.swap()`, which during `_swapToRatio` *is* the hook. v4's
self-call guard therefore skips the callback entirely, so `_afterSwap` never runs and no
`AutopilotCheck` event is emitted with the mid-rebalance (possibly wrecked) tick. The `nonReentrant` guard on
`rebalance()` is also never tested by this path.

Two consequences worth noting for future changes rather than as defects today:
- If a `beforeSwap` fee hook is ever added, the hook's own rebalance swaps would bypass it by the same rule.
- An off-chain autopilot that triggers rebalances from `AutopilotCheck` will *not* be poisoned by the hook's
  own swaps — but it *will* observe the wrecked `slot0` in the very next third-party swap on a pool damaged by
  A-1, and should be defended accordingly.

**Proof of Concept**: N/A — verification. Source: `lib/uniswap-hooks/lib/v4-core/src/libraries/Hooks.sol:293`
and the `noSelfCall` modifier at `Hooks.sol:170-174`.
**Recommendation**: None. Add a comment at `_swapToRatio`'s `poolManager.swap` call recording that v4's
self-call guard makes this non-reentrant into the hook's own callbacks, so a future reader does not add a
redundant (or, worse, a load-bearing-but-wrong) guard.

---

## [A-15] The hook can be attached to arbitrary pools; per-pool state is correctly isolated
**Severity**: Info
**Category**: defi-amm
**Location**: `deposit()` — `contracts/src/AutopilotHook.sol:150`; `poolPositionCount` — `contracts/src/AutopilotHook.sol:69`
**Description**:
Checked against "hooks attached to multiple pools without pool isolation". `deposit()` validates
`if (address(key.hooks) != address(this)) revert HookMismatch();` but not *which* pool — so anyone may
`initialize` a pool (any token pair, any fee tier) with this hook attached and deposit into it, and
`_afterSwap` will fire for every such pool. No `beforeInitialize` restriction exists (and none could be added
post-deployment — see A-13).

This is not exploitable here because the hook keeps no cross-pool shared state: `poolPositionCount` is keyed
by `PoolId`, `positions`/`boundLower`/`boundUpper` are keyed by a `positionId` that includes the pool id
(`keccak256(abi.encode(msg.sender, id, depositNonce++))`), and the v4 position salt is that same
`positionId`. A foreign pool's activity therefore cannot corrupt a legitimate pool's accounting. Depositors
into a scam pool lose only their own funds, self-inflicted.

**Proof of Concept**: N/A — verification.
**Recommendation**: None required. If pool exclusivity is ever wanted, it must be decided before deployment,
since `beforeInitialize` is address-encoded. A cheaper alternative is an owner-maintained
`mapping(PoolId => bool) allowedPools` checked in `deposit()`, which needs no new permission bits.

---

## [A-16] Accrued fees are correctly rolled into the new position on rebalance
**Severity**: Info
**Category**: defi-amm
**Location**: `_doRebalance()` — `contracts/src/AutopilotHook.sol:324-335`
**Description**:
Checked against the checklist's retrospective-fee item and the concern that moving between salt-keyed
positions could strand fee growth. No issue. `PoolManager.modifyLiquidity` returns
`callerDelta = principalDelta + feesAccrued` (`PoolManager.sol:167`), so the burn on line 324 returns
principal *and* all accrued fees in one `BalanceDelta`. `freed0`/`freed1` therefore include fees, and those
fees are recycled into the new range rather than being left behind or paid out separately. The v4 position is
keyed by `(owner, tickLower, tickUpper, salt)`, so re-adding at a new tick range under the same salt writes to
a fresh position slot and the old slot is correctly left at zero liquidity — no fee growth is stranded. There
is also no management-fee mechanism in this contract, so the "updated fees retrospectively applied to pending
rewards" failure mode does not apply.

**Proof of Concept**:
Executed. Deposited `L = 1e18` over `[-600, 600]`, ran two swaps through the range to accrue fees, then
rebalanced to the *same* range `[-600, 600]`:

```
liq after same-range rebalance (was 1e18)  1000001014110883267
```

Liquidity increased by the fees earned — they were reinvested, not lost.

**Recommendation**: None. If a management/performance fee is added later, collect pending fees *before*
applying any fee-rate change, per the Dacian/Arrakis finding.

---

## Checklist items reviewed and found not applicable

For completeness, these checklist items were walked and judged non-applicable to this contract:
cross-contract view reentrancy on reserves (no internal reserve mirror); flash-loan callback ordering (no
flash loans); arbitrary `call` from user input (none); signed-integer balance overflow (`liquidity` is
`uint128`, casts are bounded by v4's `toInt128`); `BeforeSwapDelta` sign/ordering and async-hook custody
(no `beforeSwap`); `lpFeeOverride` DoS (hook returns no fee override); unbounded loops in hooks (`_afterSwap`
has none); `unlockCallback` as an unprotected entry point (guarded by
`if (msg.sender != address(poolManager)) revert NotPoolManager();` at line 272, and `Callback` is only ever
constructed internally — users cannot influence the calldata); missing `onlyPoolManager` on hook functions
(`BaseHook` applies it to every entry point); TWAMM items (no TWAMM); token0/token1 cross-chain ordering (the
contract never assumes an ordering; it reads `key.currency0`/`currency1`); pool factory verification (v4 has a
singleton PoolManager, set immutably in the constructor); hardcoded fee tier (fee comes from the caller's
`PoolKey`); fee-distribution rounding dust (no fee distribution); stale router approvals (no router); withdraw
returning zero while burning shares (no share token — `withdraw()` burns the exact stored liquidity and takes
the full resulting delta to the owner); mismatched slippage decimals (no cross-decimal slippage maths).

I also specifically tested whether `withdraw()` is profitably sandwichable by pushing spot to the edge of the
position's range before the exit. It is not, in a fee-bearing pool: the measured outcome for the LP was a net
*gain* (`net t0 -29553010879137170`, `net t1 +30544622242640678` against a deposit of `29553010879137170` of
each), because the attacker's round-trip pays LP fees into the position it is trying to skim. I am recording
this as a deliberate non-finding rather than reporting a speculative one.

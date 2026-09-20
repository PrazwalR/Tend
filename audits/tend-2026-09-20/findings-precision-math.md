# AutopilotHook — Precision & Math Findings

**Contract**: `/Users/prazw/Desktop/Web3/Tend/contracts/src/AutopilotHook.sol`
**Checklist**: evm-audit-precision-math
**Date**: 2026-09-20
**Compiler**: Solidity 0.8.26, optimizer on (200 runs), evm_version cancun

## Summary

The Q96 fixed-point arithmetic in `_swapToRatio()` is, on its own, sound: `FullMath.mulDiv` is used correctly everywhere (multiply-before-divide in every case), the two-step squaring in `_inToken1()`/`_inToken0()` is accurate to well under 1 wei at realistic prices, the `roundUp=false` arguments to `SqrtPriceMath` are harmless because only the *ratio* of `want0:want1` is consumed, and `LiquidityAmounts.getLiquidityForAmounts()` provably rounds so that the redeposit never demands more than the hook holds. The real defects are not in the digits but in the *sizing model*: `_swapToRatio()` computes an amount to swap from the pre-swap spot price and then executes it with `sqrtPriceLimitX96` pinned to `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`, i.e. with no price bound at all, and in the two single-sided branches it swaps **100%** of the surplus token. Because `getLiquidityForAmounts()` takes `min(L0, L1)`, holding zero of either token forces `newLiquidity == 0`, so any swap that moves spot into the new range reverts the whole rebalance; and in a pool whose active liquidity is thin (the common case, since the hook itself removes its own liquidity immediately before swapping) the unbounded swap walks the pool price all the way to `MAX_SQRT_PRICE - 1`, funding the new position with the wrong token and leaving the pool price destroyed. Both were reproduced against the vendored v4-core with Foundry; numbers below are measured, not estimated.

## Findings by severity

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 1 | P-1 |
| Medium | 1 | P-2 |
| Low | 4 | P-3, P-4, P-5, P-6 |
| Info | 4 | P-7, P-8, P-9, P-10 |
| **Total** | **10** | |

---

## [P-1] `_swapToRatio()` executes the re-ratio swap with no price bound, walking a thin pool to `MAX_SQRT_PRICE - 1`
**Severity**: High
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:425-433` (`sqrtPriceLimitX96` argument), with the 100%-of-a-side sizing at `AutopilotHook.sol:392-399`
**Description**: The swap is issued as

```solidity
sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
```

which is the "no limit" sentinel. The amount is sized from the pre-swap `sqrtPriceX96` read at line 385, so nothing in the contract constrains where the price ends up. This interacts badly with the ordering inside `_doRebalance()`: `modifyLiquidity()` at line 324 **removes the hook's own liquidity first**, so by the time `poolManager.swap()` runs, the pool's active liquidity at spot has been reduced by exactly the position being rebalanced. Because the PoolKey embeds `hooks = address(this)`, these pools are dedicated to this hook — the managed positions frequently *are* the pool's liquidity. When active liquidity at the current tick reaches zero, a Uniswap swap walks tick-by-tick to the price limit consuming no input at all, so the price moves to the extreme for free.

The result is a position funded with the *opposite* token to the one the range was chosen for, and a pool left at the maximum representable price. Every other `AutopilotHook` position in that pool is now wildly out of range, every swapper hitting the pool in that window is filled at a broken price, and the arbitrageur who restores the price trades through those positions at off-market prices. An external LP can deliberately create the precondition by pulling their own liquidity ahead of a scheduled rebalance and taking the other side of the arb.
**Proof of Concept**: Reproduced with Foundry against the vendored `v4-core`, using the project's own `setUp()` (pool at `SQRT_PRICE_1_1`, fee 3000, tickSpacing 60). The scenario is *identical to the existing test* `test_rebalance_to_one_sided_range` at `contracts/test/AutopilotHook.t.sol:241-249`, which passes because it only asserts `assertGt(liq, 0)` and never inspects the pool price:

```
deposit([-600, 600], liquidity 1e18)        // the pool's only liquidity
rebalance(pid, 600, 1200, minLiquidity = 0) // range entirely above spot

sqrtP before  79228162514264337593543950336            (tick 0)
sqrtP after   1461446703485210103287273052203988822378723970341  (tick 887271)
MAX_SQRT-1    1461446703485210103287273052203988822378723970341
newLiquidity  941767358693748038
owner d0      +29553010879137169   (all token0 handed back as "dust")
owner d1      0
```

Control flow: `sqrtPriceX96 <= sqrtA` selects the branch at line 392-395, so `amountIn = have1` (100% of token1) with `zeroForOne = false` and limit `MAX_SQRT_PRICE - 1`. With no active liquidity the swap consumes nothing and pins spot at `MAX_SQRT_PRICE - 1`. `getSlot0` at line 346 now returns `sqrtPriceX96 >= sqrtB`, so `getLiquidityForAmounts` takes its final branch and sizes the position from `amount1` only — the exact inverse of the token0-only range the bot asked for — while the entire token0 balance is returned to the owner at line 372. The `minLiquidity` floor does not catch this: `newLiquidity` is large (9.4e17), it is simply denominated in the wrong token at a destroyed price.
**Recommendation**: Bound the swap by the boundary the position must not cross, and never sell 100% of a side. The price limit is free protection and is exactly the value already in hand:

```solidity
        if (amountIn == 0) return BalanceDeltaLibrary.ZERO_DELTA;
        // Never let the re-ratio swap push spot into (or through) the target
        // range: the redeposit needs a non-zero balance on both sides whenever
        // sqrtA < spot < sqrtB, and an unbounded limit lets a thin pool walk to
        // MIN/MAX for free.
        uint160 limit = zeroForOne
            ? (sqrtB < sqrtPriceX96 ? sqrtB : TickMath.MIN_SQRT_PRICE + 1)
            : (sqrtA > sqrtPriceX96 ? sqrtA : TickMath.MAX_SQRT_PRICE - 1);
        BalanceDelta d = poolManager.swap(
            cb.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: limit
            }),
            ""
        );
```

Additionally, pass a caller-supplied `maxSqrtPriceMovementX96` (or an explicit `sqrtPriceLimitX96`) through `rebalance()` into `Callback` so the bot can bound the fill independently of `minLiquidity`, and re-read `getSlot0` after the swap to assert the price actually landed where the sizing assumed.

---

## [P-2] Swapping 100% of one side guarantees `newLiquidity == 0` whenever the swap crosses into the new range
**Severity**: Medium
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:392-399`; consumed at `_doRebalance()` `AutopilotHook.sol:347-354`
**Description**: In both single-sided branches the entire surplus balance is swapped:

```solidity
if (sqrtPriceX96 <= sqrtA) {
    if (have1 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
    (zeroForOne, amountIn) = (false, have1);   // ALL of token1
} else if (sqrtPriceX96 >= sqrtB) {
    if (have0 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
    (zeroForOne, amountIn) = (true, have0);    // ALL of token0
}
```

After an exact-input swap of `have1`, `_add(freed1, swapped.amount1())` yields exactly `0`. `LiquidityAmounts.getLiquidityForAmounts()` (verified in `lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol:63-72`) returns `min(liquidity0, liquidity1)` whenever `sqrtPriceAX96 < sqrtPriceX96 < sqrtPriceBX96`, and `getLiquidityForAmount1(_, _, 0)` is `0`. So if the swap moves spot into the target range — which is precisely what a swap in that direction does, since it pushes price *toward* the range — `newLiquidity` is forced to `0` and line 354 reverts `ZeroLiquidity()`. The whole `unlock` unwinds, so no funds are lost, but the position cannot be rebalanced onto any range adjacent to spot. Same root cause as P-1; separated because the manifestation and impact differ (DoS rather than mispriced fill), and because it bites in *deep* pools too.
**Proof of Concept**: Measured sweep of external pool liquidity against a managed position of liquidity `1e18`, rebalancing `[-600, 600] -> [60, 1200]` (lower bound one tick-spacing above spot), pool at `SQRT_PRICE_1_1`, fee 3000:

```
external L / managed L      result
      0.1x                  REVERT 0x10074548  (ZeroLiquidity())
      1x                    REVERT 0x10074548
      5x                    REVERT 0x10074548
     10x                    OK  newLiq 1066866366164685739, tick after 58
    100x                    OK  newLiq 1068276298518121744, tick after 5
   1000x                    OK  newLiq 1068417703014502941, tick after 0
  10000x                    OK  newLiq 1068431847588856822, tick after 0
```

`0x10074548` is `ZeroLiquidity()` (confirmed via `cast sig`). The threshold is sharp: at 10x depth the swap lands at tick 58, one tick short of the range's lower bound at 60, and succeeds; at 5x it crosses 60 and reverts. In other words **any managed position larger than roughly 10% of the pool's active liquidity cannot be rebalanced onto a one-sided range near spot** — which is the headline use case for an autopilot LP hook. The straddling branch is *not* affected: a shallow-pool straddle rebalance (external L = `2e18`, managed L = `1e18`, drifted to tick -13681) succeeded with `newLiq 115598273900321394` and moved spot only from tick -13681 to -13684.
**Recommendation**: The price limit from P-1 fixes this directly — with `sqrtPriceLimitX96 = sqrtA` the swap becomes partial, stops at the boundary, and leaves a non-zero token1 balance, so `min(L0, L1) > 0`. Belt-and-braces, reserve a floor on the side being sold rather than emptying it, and give the caller a clearer error:

```solidity
if (sqrtPriceX96 <= sqrtA) {
    if (have1 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
    (zeroForOne, amountIn) = (false, have1);
}
...
// in _doRebalance, distinguish the two zero causes:
if (newLiquidity == 0) revert RatioSwapOvershot(sqrtPriceX96, cb.newTickLower, cb.newTickUpper);
```

---

## [P-3] `_inToken1()` / `_inToken0()` square `sqrtPriceX96` in two truncating steps instead of one exact `Q192` division
**Severity**: Low
**Category**: precision-math
**Location**: `_inToken1()` / `_inToken0()` — `AutopilotHook.sol:436-444`
**Description**:

```solidity
uint256 half = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
return FullMath.mulDiv(half, sqrtPriceX96, FixedPoint96.Q96);
```

Each `mulDiv` multiplies before dividing, so there is no classic division-before-multiplication bug *within* a call. But the composition is `floor(floor(a·r)·r)` where `r = sqrtPriceX96 / 2^96`, and the fractional part discarded by the first `floor` is then scaled by `r`. The absolute error is therefore up to `r` units of token1 (i.e. `sqrt(P)`), versus the exact `floor(a·r²)`. The canonical Uniswap form (`OracleLibrary.getQuoteAtTick`) avoids this by forming `ratioX192 = sqrtPriceX96 * sqrtPriceX96` exactly and doing a single `mulDiv` against `1 << 192`. The relative error is `~1 / (amount0 · r)`, so it only exceeds 1% when `amount0 < 100 · 2^96 / sqrtPriceX96` — value-negligible amounts. Impact is confined to `haveValue`/`wantValue` at line 406-407, where a slight undervaluation of `want0` inflates `target1` and oversells token0; the excess is returned to the owner at line 372 and bounded by `minLiquidity`, so no value is lost.
**Proof of Concept**: At `sqrtPriceX96 = 1.5 · Q96` (price 2.25), the two-step result vs. the exact `floor(a · 2.25)`:

```
amount0   two-step   exact    error
   1         1         2      -50.0%
   2         4         4        0
   5        10        11       -9.1%
   8        18        18        0
```

At a realistic WETH(18)/USDC(6) price — `sqrtPriceX96 = 4339505179874418113536000`, i.e. 3000 USDC/ETH — the two forms agree exactly at every realistic size: `amount0 = 1e18` gives `2999999999` USDC-wei both ways, `amount0 = 1e15` gives `2999999` both ways. `_inToken1` truncates to zero only below `amount0 = 18248` wei of WETH (≈ 5.5e-11 USD). So this is a latent sharp-edge, not an exploitable one at present.
**Recommendation**: Use the exact 192-bit form, falling back to the two-step only when `sqrtPriceX96` exceeds `uint128` max:

```solidity
function _inToken1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
    if (sqrtPriceX96 <= type(uint128).max) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        return FullMath.mulDiv(amount0, ratioX192, 1 << 192);
    }
    uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
    return FullMath.mulDiv(amount0, ratioX128, 1 << 128);
}
```

---

## [P-4] `_add()` saturates to zero on underflow, silently masking an accounting error instead of reverting
**Severity**: Low
**Category**: precision-math
**Location**: `_add()` — `AutopilotHook.sol:446-450`; call sites `AutopilotHook.sol:343-344`
**Description**:

```solidity
function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    return base > sub ? base - sub : 0;
}
```

The saturation branch is currently unreachable: the negative component of `swapped` is always the *specified* side of an exact-input swap, and `amountIn` is by construction `<= have0` / `<= have1` in every branch of `_swapToRatio()` (the single-sided branches use the full balance; the deficit branch clamps at line 414; the surplus branch uses `have1 - target1`). So saturation is dead code today. The concern is that it converts a would-be invariant violation into a silently wrong `freed0`/`freed1`, which then feeds `getLiquidityForAmounts()` at line 347 and sizes a real `modifyLiquidity()` call. The failure is *currently* fail-safe — `net = removed + swapped + added` at line 370 would go negative on that side, the hook only `take`s positive amounts (lines 371-376), and `poolManager.unlock` would revert with `CurrencyNotSettled` — but that safety depends on an unrelated invariant two functions away, and it costs nothing to make the check local and explicit. Note `-delta` on `type(int128).min` would itself revert under 0.8 checked arithmetic, which is the correct behaviour.
**Recommendation**: Revert rather than clamp, so the invariant is stated where it is relied upon:

```solidity
error DeltaUnderflow(uint256 base, int128 delta);

function _add(uint256 base, int128 delta) private pure returns (uint256) {
    if (delta >= 0) return base + uint256(uint128(delta));
    uint256 sub = uint256(uint128(-delta));
    // _swapToRatio never specifies more input than the hook holds, so this
    // cannot underflow; revert loudly if that ever stops being true.
    if (sub > base) revert DeltaUnderflow(base, delta);
    return base - sub;
}
```

---

## [P-5] `target1` ignores the pool fee and price impact, systematically under-deploying the rebalanced position
**Severity**: Low
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:410-421`
**Description**: `target1 = FullMath.mulDiv(haveValue, want1, wantValue)` and `sell0 = _inToken0(deficit1, sqrtPriceX96)` both value the trade at the *mid* price with zero cost. The executed swap pays `key.fee` on the input and moves the price against itself, so the realised token1 received is roughly `deficit1 · (1 - fee) ` minus slippage — the hook always lands *short* on the side it was buying. Because `getLiquidityForAmounts()` takes `min(L0, L1)`, the short side sets the liquidity and the surplus on the other side is returned to the owner as dust at lines 371-376. No value is lost (the dust goes to `cb.owner`, not the hook), but the position is consistently smaller than intended and the owner is handed raw tokens they did not ask to hold. With `minLiquidity = 0` — which the project's own tests pass in 11 of 17 rebalance calls — a badly-sized swap can return most of the position to the owner's wallet as loose tokens, effectively force-closing it without a `PositionClosed` event.
**Proof of Concept**: From the P-2 sweep, holding everything else constant and varying only pool depth (so the only variable is price impact on a fee-3000 pool), the resulting `newLiquidity` for the same inputs:

```
external L / managed L = 10x      newLiq 1066866366164685739
external L / managed L = 10000x   newLiq 1068431847588856822
```

a spread of `1565482171137083`, i.e. **0.147%** of the position, lost to price impact alone at 10x depth and never modelled by the sizing formula. The fee term adds a further ~0.3% shortfall on the bought side for a 30bp pool (sell `deficit1 / P` token0, receive `deficit1 · 0.997`).
**Recommendation**: Gross up the deficit by the fee before converting to an input amount, and treat the remainder explicitly:

```solidity
// key.fee is in hundredths of a bip (1e6 = 100%)
uint256 grossed1 = FullMath.mulDivRoundingUp(deficit1, 1e6, 1e6 - cb.key.fee);
uint256 sell0 = _inToken0(grossed1, sqrtPriceX96);
if (sell0 > have0) sell0 = have0;
```

Separately, require `minLiquidity > 0` in `rebalance()` so a mis-sized swap can never silently unwind a position into the owner's wallet.

---

## [P-6] `want0`, `want1` and `haveValue` can truncate to zero, collapsing the target ratio to an all-or-nothing swap
**Severity**: Low
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:403-419`
**Description**: Three quantities can floor to zero and change the control flow qualitatively rather than marginally:

- `want1 = getAmount1Delta(sqrtA, sqrtPriceX96, cb.liquidity, false)` computes `floor(L · (sqrtP - sqrtA) / 2^96)` (verified in `lib/uniswap-hooks/lib/v4-core/src/libraries/SqrtPriceMath.sol:233-254`). When it is `0`, `target1 = mulDiv(haveValue, 0, wantValue) = 0`, the `else` branch at line 417 sets `surplus1 = have1`, and the hook sells **100% of token1** — which then hits the `min(L0, L1) = 0` trap of P-2 and reverts.
- Symmetrically `want0 = 0` makes `wantValue == want1`, so `target1 == haveValue`, `deficit1 == _inToken1(have0)` and `sell0 == _inToken0(_inToken1(have0))`, which sells essentially all of token0.
- `haveValue == 0` (possible when `have1 == 0` and `_inToken1(have0)` truncates) hits the guard at line 408 and returns `ZERO_DELTA`, leaving the position one-sided and reverting at line 354.

The guard at line 408 correctly catches `wantValue == 0` (which would be a division by zero in `mulDiv`), but nothing catches `want1 == 0` or `want0 == 0` individually.
**Proof of Concept**: `want1 == 0` requires `L · (sqrtP - sqrtA) < 2^96`. At price 1 (`sqrtP = Q96 = 79228162514264337593543950336`) with `sqrtA` one tick below spot, `sqrtP - sqrtA ≈ 3.96e24`, so `want1 = 0` for any `L < 2^96 / 3.96e24 ≈ 20000`. For the WETH/USDC pool above (`sqrtP = 4.3395e24`, tickSpacing 10), `sqrtP - sqrtA ≈ 2.17e21` and `want1 = 0` for `L < 3.65e7` — a position holding under 1 USDC-wei on the token1 leg. So in practice this only fires for dust-sized positions or ranges whose lower bound is within a hair of spot; I could not construct a realistically-sized case, and the severity is set accordingly. The failure mode when it does fire is a revert, not a loss.
**Recommendation**: Treat a zero leg as "this range is single-sided at the current price" explicitly rather than letting it fall through the ratio arithmetic, and reject dust:

```solidity
uint256 want0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, cb.liquidity, false);
uint256 want1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, cb.liquidity, false);
// Below the precision floor the ratio is meaningless; a zero leg would make
// the swap all-or-nothing and strand the redeposit at min(L0, L1) == 0.
if (want0 == 0 || want1 == 0) revert RangeTooCloseToSpot();
```

---

## [P-7] Redundant and misleading clamp expression for `sell0`
**Severity**: Info
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:414`
**Description**:

```solidity
if (sell0 == 0 || sell0 > have0) sell0 = sell0 > have0 ? have0 : sell0;
```

The `sell0 == 0` disjunct is a no-op: when `sell0 == 0` the condition `0 > have0` is false for any `uint256 have0`, so the ternary assigns `sell0 = sell0`. The statement is exactly equivalent to `if (sell0 > have0) sell0 = have0;`. It reads as though a zero case is being handled — it is not; the zero case is handled on the following line. No behavioural bug, but the line invites a future edit that introduces one.
**Proof of Concept**: Not exploitable. `sell0 == 0, have0 == 0` -> condition true, ternary false branch -> `sell0 = 0`, then line 415 returns `ZERO_DELTA`. `sell0 == 0, have0 > 0` -> identical. Behaviour matches the simplified form in all four quadrants.
**Recommendation**:

```solidity
if (sell0 > have0) sell0 = have0;
if (sell0 == 0) return BalanceDeltaLibrary.ZERO_DELTA;
```

---

## [P-8] Unchecked `uint256 -> int256` cast on the swap amount
**Severity**: Info
**Category**: precision-math
**Location**: `_swapToRatio()` — `AutopilotHook.sol:429`
**Description**: `amountSpecified: -int256(amountIn)` reinterprets a `uint256` as `int256` without a `SafeCast`. In Solidity 0.8 this conversion does **not** revert — a value above `type(int256).max` silently becomes negative, and negating it again would flip the sign of the swap. The cast is safe today because `amountIn` is always derived from `freed0`/`freed1`, which come from `BalanceDelta`'s `int128` components (`lib/uniswap-hooks/lib/v4-core/src/types/BalanceDelta.sol:60-70`) and are therefore bounded by `type(int128).max ≈ 1.70e38`, far below `type(int256).max ≈ 5.79e76`. Flagged as a pattern, not a live bug.
**Proof of Concept**: Not reachable. Every assignment to `amountIn` traces to `have0`, `have1`, `surplus1 = have1 - target1` (<= `have1`) or `sell0` clamped to `have0`, all <= `2^127 - 1`.
**Recommendation**: `amountSpecified: -SafeCast.toInt256(amountIn)`, or add an explicit `require(amountIn <= uint256(type(int128).max))` alongside a comment recording the `BalanceDelta` bound.

---

## [P-9] Rounding directions in the redeposit path were verified sound — no change needed
**Severity**: Info
**Category**: precision-math
**Location**: `_doRebalance()` — `AutopilotHook.sol:347-366`; `_swapToRatio()` `AutopilotHook.sol:403-404`
**Description**: Recording the verification, since these were the specific rounding questions raised.

*`getLiquidityForAmounts` vs. `modifyLiquidity`*: `getLiquidityForAmount0` computes `L0 = floor(amount0 · I / d)` with `I = floor(sqrtP·sqrtB/Q96)`, `d = sqrtB - sqrtP`; `modifyLiquidity` for a positive `liquidityDelta` then charges `ceil(ceil(L0·Q96·d/sqrtB)/sqrtP)` (`SqrtPriceMath.getAmount0Delta(..., int128)` dispatches to `roundUp = true` for positive liquidity). Since `L0 · Q96 · d / (sqrtB·sqrtP) <= amount0` and `amount0` is an integer, `ceil(x) <= amount0` holds, and the nested-ceiling identity `ceil(ceil(a/b)/c) = ceil(a/(b·c))` preserves it. The same argument gives `required1 <= amount1`. Taking `min(L0, L1)` only lowers both. So the redeposit provably never demands more than the hook holds, and `net = removed + swapped + added` is non-negative on both legs — which is why only the positive branches at lines 371-376 are needed.

*`roundUp = false` for the `want` target*: correct. `want0` and `want1` are consumed only as the ratio `want1 / (_inToken1(want0) + want1)` at line 410, and both are computed from the same `cb.liquidity`, so the shared scale cancels. Rounding both down biases `target1` in opposite directions (a smaller `want1` lowers it, a smaller `want0` lowers `wantValue` and raises it) and each error is <= 1 wei, so the net effect is negligible. The only hazard is a leg truncating to zero, covered in P-6. Using the old `cb.liquidity` against the *new* range is likewise fine for the same scale-invariance reason.
**Proof of Concept**: Not a defect. Confirmed against the vendored sources at `lib/uniswap-hooks/lib/v4-periphery/src/libraries/LiquidityAmounts.sol:17-72` and `lib/uniswap-hooks/lib/v4-core/src/libraries/SqrtPriceMath.sol:180-288`, and empirically by every passing rebalance in the P-2 sweep settling with no `CurrencyNotSettled` revert.
**Recommendation**: No change. Consider a comment at line 347 recording that `min(L0, L1)` with floor rounding is what guarantees `net >= 0`, so a future switch to a rounding-up helper is recognised as unsafe.

---

## [P-10] Overflow headroom in `_inToken1()` / `_inToken0()` is only ~2x at the extremes of the price range
**Severity**: Info
**Category**: precision-math
**Location**: `_inToken1()` / `_inToken0()` — `AutopilotHook.sol:436-444`
**Description**: `FullMath.mulDiv` reverts (via `require(denominator > prod1)`) when the result would not fit in 256 bits. Worst case for `_inToken1`: `amount0` bounded by `type(int128).max = 1.7014e38` (from `BalanceDelta`), and `sqrtPriceX96 / 2^96` bounded by `MAX_SQRT_PRICE / Q96 = 1.4614e48 / 7.9228e28 = 1.8447e19`. The result is `1.7014e38 · (1.8447e19)² = 5.79e76`, against `2^256 = 1.1579e77` — a factor of 2.0. `_inToken0` is symmetric with `Q96 / MIN_SQRT_PRICE = 1.8447e19`. The intermediate `half` peaks at `3.1e57`, comfortably inside range. So no overflow is reachable given the `int128` bound on freed amounts, but the margin is thin enough that removing that bound (e.g. accepting externally-supplied amounts, or summing several positions) would break it. Also note `haveValue = _inToken1(have0) + have1` at line 406 is checked addition of at most `5.79e76 + 1.70e38`, which cannot overflow.
**Proof of Concept**: Arithmetic bound only; not reachable with realistic token supplies, and a revert rather than a wrap if it were. Stated for completeness because the checklist asks for overflow of intermediate products.
**Recommendation**: No change required. If `_inToken1`/`_inToken0` are ever reused outside `_swapToRatio`, document the `amount <= type(int128).max` precondition on them, or adopt the `ratioX192` form from P-3, which shifts the worst case into `FullMath`'s 512-bit path and widens the margin.

---

## Checklist items walked with no finding

- **Division before multiplication**: every division in the contract is inside `FullMath.mulDiv`, which multiplies to 512 bits before dividing. No `(a / b) * c` pattern. The two-step square in P-3 is the only composition where a truncation precedes a multiplication.
- **Extra / double scaling by a decimal factor**: the contract performs no decimal normalisation at all and does not need to — all arithmetic is in raw token units, and `sqrtPriceX96` already encodes the `10^(d1-d0)` ratio. No hardcoded `1e18`. Checked explicitly against USDC(6)/WETH(18) on Base; see P-3 for the measured numbers.
- **Oracle decimal mismatch**: no external oracle; price comes from `poolManager.getSlot0`.
- **`unchecked` blocks**: none in `AutopilotHook.sol`.
- **Downcasts**: `uint64(block.timestamp)` (line 267) is safe; `pos.lastRebalanceAt + minRebalanceInterval` (line 235) cannot overflow `uint64` because `MAX_REBALANCE_INTERVAL` caps the addend at `3.15e7`; `uint256(uint128(-delta.amountX()))` reverts on `type(int128).min` under checked arithmetic; `int256(uint256(cb.liquidity))` widens a `uint128` and is safe. The only unguarded cast is P-8.
- **Negative-to-unsigned cast**: all three sites take the absolute value correctly as `uint256(uint128(-x))` after an explicit sign test.
- **Off-by-one in comparisons**: the branch boundaries in `_swapToRatio` (`<= sqrtA`, `>= sqrtB`) match `getLiquidityForAmounts`' own boundaries (`<= sqrtPriceAX96`, `< sqrtPriceBX96`) exactly at both endpoints — verified against the vendored source. `target1 > have1` correctly treats equality as "no swap".
- **Negative modulo**: `tickLower % spacing != 0` at line 456 is correct for negative ticks; Solidity's `%` takes the sign of the dividend but the `!= 0` test is sign-agnostic.
- **Reward/accumulator math, ERC4626 share rounding, inverse fee formulas, time-literal `uint24` truncation, assembly `div(x, 0)`, `type(uint256).max` sentinels, exponential weight math**: not applicable — the contract has no share accounting, no interest accrual, no inline assembly, and no exponentiation.

# Findings — AMM mechanics and precision math (full audit, f993a76)

PoCs: `contracts/test/audit/full/AmmMathPoC.t.sol` (10 tests, passing; fuzz runs of 257).
Checklists: evm-audit-defi-amm, evm-audit-precision-math.

| ID | Severity | Title | PoC |
|---|---|---|---|
| AM2-1 | **High** | PR-1 bypass: steps of ≤ 500 ticks are never clamped, so one held block end moves the reference. **Same as OR-1, found independently.** | reproduced |
| AM2-2 | **Medium** | The DS-1 one-sided fallback is skipped when the other token is non-zero (fee dust), leaving 99.98% of the position idle | reproduced |
| AM2-3 | Info | The `_swapPriceLimit` upward impact bound wraps near MAX_SQRT_PRICE (skips the swap, no loss) | reproduced |
| AM2-4 | Info | Token0-funded liquidity computes to 0 below sqrtPrice 2^48 (tick ≈ −665,000) | reproduced |

## [AM2-1] PR-1 bypass at the cap
**Severity**: High. See OR-1 for the full description.
**Impact**: Victim [-420,420] or [-600,600] at L = 1e18, pool depth 1e21. One held block end at
+500 ticks loses **387 bps**; two held block ends at +1000 lose **799 bps**. A further +60 in the
rebalance block passes too, giving 400 and 854 bps. The attacker's gain over the control is positive in
every case. The 700-tick control is refused with `PriceUnsettled`.
**PoC**: `forge test --mt test_AM2_1 -vv`
**Recommendation**: Count a block end as stable only if the reference moved by a small step, or anchor
the rebalance to the reference from K block ends ago.

## [AM2-2] DS-1 fallback defeated by fee dust
**Severity**: Medium. Degraded behaviour: the DS-1 fix is incomplete.
**Location**: `_placeableLiquidity`, the early `if (liq != 0) return liq;` and the strict
`have1 == 0` / `have0 == 0` conditions.
**Description**: An out-of-range position usually holds a little of the other token, from fees earned
while it was in range. `getLiquidityForAmounts` returns min(L0, L1); one wei of token1 already gives
L ≈ 333, so the early return fires. Dust liquidity goes on the straddling range and the rest becomes
idle, so the fallback never runs. A same-range redeploy reproduces the same result until depth returns.
**Impact**: In the DS-1b hook-only pool, after one small earlier trade, placed liquidity falls from
1.76e18 to 1.92e14 and **9998 bps** of token0 sits idle. Nothing is lost, but it earns nothing
indefinitely.
**PoC**: `forge test --mt test_AM2_2 -vv`
**Recommendation**: When spot straddles the range, also compute the one-sided liquidity for the
dominant token on its side of spot, and take whichever is larger. The minority token goes idle.

## [AM2-3] Upward impact bound wraps near MAX_SQRT_PRICE
**Severity**: Info. Within about 100 ticks of MAX_TICK at 50 bps, `uint160(spot * (BPS + bps) / BPS)`
wraps, the function returns 0, and the oneForZero leg is skipped. No loss.
**Recommendation**: Compute in uint256 and clamp before casting.

## [AM2-4] Token0-funded liquidity is zero at extreme low prices
**Severity**: Info. Below sqrtPrice 2^48, `mulDiv(sqrtA, sqrtB, Q96)` floors to 0, so the rebalance
reverts `ZeroLiquidity`. That price (about 1e-29 raw) is unrealistic. Document the floor.

## Verified correct
- The value guard measures exactly "loss compared with not rebalancing, if price returns to the
  reference". By LP concavity, range choice can't inflate either side. The only gap is the reference
  itself (AM2-1).
- The fee estimate (principal at spot, rounded down the same way as v4 removal) is exact.
- `_floorToSpacing` / `_ceilToSpacing` are correct for negative ticks and spacings 1/10/60/200. The
  narrowed range stays aligned, inside the requested range and its bounds, and non-empty.
- Settlement: no `CurrencyNotSettled`, panic or tick error across spacings, depths 0–1e21, liquidity
  10–1e22, straddling and one-sided targets, and the fallback. Claims equal idle throughout
  (`testFuzz_AM2_rebalance_settles_or_refuses_cleanly`, `test_AM2_settle_coverage` with 120 cases).
- No overflow within ±3,000 ticks of MIN/MAX (`testFuzz_AM2_extreme_prices`).
- Prior fixes hold: the corrective leg bound, idle backing, churn termination, DS-1 without fees, and
  the PR-2 shapes without a hold.

# Findings — AMM mechanics & precision math (idle balances, corrective leg)

Reviewer scope: `_releaseIdle` / `_holdIdle` / `_sub`, same-range rebalance, `_correctOvershoot`,
precision in the new code. PoCs: `contracts/test/audit/IdleAmmPoC.t.sol` (5 tests, all passing;
fuzz tests at 2000 runs). Checklists: evm-audit-defi-amm, evm-audit-precision-math.

No Medium-or-above finding.

## [AM-1] Corrective leg skipped when the first leg stops exactly on the near range edge
**Severity**: Low
**Location**: `_correctOvershoot` — `if (sqrtNow <= sqrtA || sqrtNow >= sqrtB) return ZERO_DELTA;`
**Description**: For a range one tick spacing either side of spot, the edge (about 0.3% away in
sqrtPrice) is tighter than the 50 bps impact bound, so the edge itself becomes the first leg's price
limit. In a thin pool the first leg stops exactly on `sqrtA`. That is the overshoot the corrective leg
was written to fix, but the non-strict `<=` returns before it runs. At `sqrtA` the range wants only
token0, so the token1 just bought goes to idle.
**Impact**: Capital is under-deployed, not lost (about 30 bps idle, placed by a later same-range
rebalance). The first leg's fee is paid on value that then isn't used.
**PoC**: `test_first_leg_on_near_edge_skips_correction`. With external depth 3e16, a position at
[60,660] rebalanced to [-60,60] ends at tick -60 (sqrtPrice equals sqrtA) with idle1 = 8.99e13, about
30 bps of the position.
**Recommendation**: Return early only when price is strictly outside the range. The existing clamp at
`origin` already bounds the larger correction this allows.

## [AM-2] Any non-zero idle, even 1 wei, re-enables same-range rebalance
**Severity**: Info
**Location**: `rebalance`, the `NoOpRebalance` check
**Description / PoC**: The suspected attack was endless same-range churn. NOT REPRODUCED. In a deep
pool idle shrank to exactly 0 within 5 passes and `NoOpRebalance` fired again
(`test_same_range_churn_self_terminates`). Each pass is still gated by the cooldown and the guards.
**Recommendation**: Optional: allow the same range only when idle exceeds a small share of the position.

## [AM-3] `_straddleSwap` sizes the ratio from `cb.liquidity`, which is coarse for dust positions
**Severity**: Info
**Description**: With old liquidity below about 330, the amounts used to size the swap round to 0 and
no swap runs. With one-sided holdings the rebalance then reverts with `ZeroLiquidity`. This affects
dust-sized positions only. NOT REPRODUCED in a realistic setup; this is reasoning only.
**Recommendation**: Size the ratio with a fixed reference liquidity.

## [AM-4] Overflow in `_holdIdle` and `_doWithdraw` sums is unreachable
**Severity**: Info. Neither `uint128` limit can be reached with any real token supply.

## [AM-5] Stale NatSpec says the residual is paid to the owner
**Severity**: Info
**Location**: `RebalanceResidual` (first `@dev`), `_swapToRatio` (two comments), `_straddleSwap`
**Description**: The comments still describe the residual as paid out. It is now held as idle, and
the event reports the position's total idle balance.

## Verified correct
- For every currency, the hook's claim balance equals the sum of recorded idle. This held across two
  pools sharing a currency, withdraws with and without `asClaims`, same-range redeploys and full exits
  (`test_idle_backing_holds_across_positions_and_pools`), and over fuzzed sequences
  (`testFuzz_idle_backing_sequence`, 2000 × 6 steps). Every revert was a named hook error, with no
  panic from `_sub` or `SafeCast`.
- No position can spend another's idle: records are written and cleared only by exactly matching
  mint and burn amounts.
- Flash-accounting deltas net to zero in rebalance and in withdraw.
- `_sub` cannot underflow: liquidity is rounded down, so what the pool charges is never more than
  what was freed.
- The value guard counts released idle at the pre-swap price and covers the corrective leg's fee, so
  idle cannot mask a loss.
- The corrective leg only reverses and is clamped at the starting price. Fuzzed, price always ended
  within the starting price ± `maxSwapImpactBps` (`testFuzz_corrective_leg_stays_within_impact_and_origin`).
- Rebalance no longer moves any ERC-20, so a blacklisted owner token cannot make it revert.

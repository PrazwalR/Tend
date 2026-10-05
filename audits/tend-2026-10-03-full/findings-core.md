# Findings — hook core logic and access control (full audit, f993a76)

Scope: the whole of `AutopilotHook.sol`, covering its entry points, authorization, the
position lifecycle, reentrancy, `unlockCallback` and ownership. PoCs:
`contracts/test/audit/full/CorePoC.t.sol` (4 tests, passing). Checklists: evm-audit-general,
evm-audit-access-control.

| ID | Severity | Title | PoC |
|---|---|---|---|
| CO-1 | **Medium** | `deposit()` has no `amount0Max`/`amount1Max`, so any third party can sandwich a depositor. Reported as G-3 / A-7 on 2026-09-20 and never fixed. | reproduced |
| CO-2 | Info | The hook's own re-ratio swap moves spot without writing the price reference | reproduced |
| CO-3 | Low | A request narrowed by the one-sided fallback can land on the current range, an effective no-op | from code |
| CO-4 | Info | Removing one rebalancer cancels a pending addition of another (selector-keyed queue) | n/a |
| CO-5 | Info | Instant allowlist toggles; `_placeableLiquidity` can be `view`; stranded donations | n/a |

## [CO-1] deposit() has no amount0Max/amount1Max: any third party can sandwich a depositor
**Severity**: Medium
**Location**: `deposit` / `_deposit` / `_doDeposit`
**Description**: `deposit` takes a target `liquidity` and pulls whatever token amounts spot requires
at execution time. The only cap is the depositor's ERC20 allowance, and the README flow and the tests
grant the maximum. There is no deadline either. The 2026-09-20 audit reported this as G-3 / A-7,
Medium. Neither later round fixed it, declined it or documented it.
**Impact**: An unprivileged attacker front-runs the deposit by pushing price toward a range edge, so
the victim mints at the skewed ratio. The attacker then back-runs through the victim's new liquidity.
The loss scales with the victim's share of pool depth.
**PoC**: `test_CO1_deposit_sandwich_third_party_extracts_value`. An honest LP holds 20e18 on
[-6000,6000]; the victim deposits 20e18 on [-600,600], worth about 1.18e18 at the fair price. The
control loses 2 wei. The sandwiched victim loses **1.51e16, about 128 bps**, and the attacker's PnL is
**+1.16e16**. The withdraw mirror is not profitable (`test_CO1b_withdraw_sandwich_is_not_profitable`,
where the victim gains), which matches the 09-20 non-finding.
**Recommendation**: Add `amount0Max`, `amount1Max` and `deadline` to both `deposit` overloads, and
check them in `_doDeposit` before settling.

## [CO-2] The hook's own re-ratio swap moves spot without writing the price reference
**Severity**: Info
**Description**: v4 skips `afterSwap` for the hook's own swaps, so `priceRef` isn't updated after a
rebalance swap. `_stableAfter` assumes every block ended in the last write's state, which is off by
up to the impact bound: about 100 ticks at the 50 bps default, and about 3,600 at the 2000 bps cap.
There is no direct loss, because the next third-party swap corrects the reference. But the comment
"every swap writes" is false.
**PoC**: `test_CO2_rebalance_swap_moves_spot_without_ref_write`. Spot goes from -900 to -1001 while
the reference stays at -900, unclamped.
**Recommendation**: Call `_updatePriceRef(id, spotAfter)` at the end of `_doRebalance`, or correct
the comment.

## [CO-3] A narrowed request can land on the current range
**Severity**: Low. The no-op check compares the requested range. A straddling request narrowed by
`_placeableLiquidity` can equal the current range, so the call succeeds as an effective no-op and
resets the cooldown. Only an allowlisted rebalancer can do this.
**Recommendation**: Revert `NoOpRebalance` after the callback if the placed range equals the old one
and there was no idle balance before the call.

## [CO-4] Removing one rebalancer cancels a pending addition of another
**Severity**: Info. `setRebalancer(B,false)` voids `pendingChange[setRebalancer.selector]` even when
it holds `setRebalancer(A,true)`. Revoking a compromised key in an incident silently restarts an
unrelated 2-day wait. Owner-only.
**Recommendation**: Key `setRebalancer` entries by (selector, address), or document the behaviour.

## [CO-5] Minor
**Severity**: Info. `setAllowlistEnforced(false)` and `setAllowedPool` are instant: deposit-only, but
they re-open the DS-3 daemon-cost surface. `_placeableLiquidity` can be `view`. Tokens or claims sent
straight to the hook can't be recovered.

## Verified correct
- No one but a position's owner can move its funds. The only payouts are `_doWithdraw` (to the
  owner's chosen recipient) and the mint and burn of the hook's own idle claims. `executeChange` can
  only self-call the six setters, with the exact calldata length enforced.
- `unlockCallback` accepts calls only from the PoolManager (`test_unlockCallback_only_pool_manager`).
- Reentrancy: deposit, withdraw and rebalance share `nonReentrant`, and withdraw updates state before
  calling out (`test_reentrancy_from_withdraw_payout_is_blocked`).
- DS-1 narrowing: the stored range always equals the PoolManager position's range under its salt, the
  old range is empty, and hook claims equal the sum of idle
  (`test_CO_verify_stored_range_matches_poolmanager_and_idle_solvent`).
- Reseeding on 0→1, the cooldown from deposit (C-3), scoping and `AUTOMATION_OFF` (C-5), the TK-3
  recipient checks, and the TL-2/3/4 queue all hold under their regression tests. `ownerEpoch` is
  bumped on the constructor and on `acceptOwnership`, not on a pending transfer. Ownership can't be
  renounced, and pause never gates withdraw.
- TK-5 events are emitted as claimed, and `Rebalanced` reports the placed range.

# Findings — token handling and settlement (full audit, f993a76)

PoCs: `contracts/test/audit/full/TokenSettlePoC.t.sol` (13 tests, passing; the three fuzz tests ran
at 1,000–2,000 runs each). Checklists: evm-audit-erc20, evm-audit-general.

No Medium-or-above finding.

| ID | Severity | Title |
|---|---|---|
| TS-1 | Info | The fee-on-transfer check only covers the token legs a deposit actually pays |
| TS-2 | Info | Read-only reentrancy window during deposit (T-10 carry-over) |
| — | Low (open since 09-20) | T-5: users give the hook a direct unbounded approval, not Permit2 |
| — | Info | The daemon's `idle_balance(...).unwrap_or((0,0))` treats a read error as zero idle |

## [TS-1] Fee-on-transfer check only covers the paid legs
**Severity**: Info. A one-sided deposit pays only one token, so a fee-on-transfer token on the other
side gets in. A rebalance then converts the position into it without any token transfer, and the
owner's own exit pays the fee. The PoolManager's reserves are never short. The pool allowlist is the
real control (`test_fot_on_unpaid_leg_is_not_detected`).
**Recommendation**: Document that the check is best-effort.

## [TS-2] Read-only reentrancy window during deposit
**Severity**: Info. `positions` and `poolPositionCount` are written after `unlock`, so a payer-side
token callback sees a half-built state. Every value-moving entry point is guarded: deposit, withdraw
and rebalance revert as reentrant calls, and the timelock functions are owner-only. Redirecting the
settle credit doesn't work (`test_payer_callback_reentry_into_every_entry_point`,
`test_payer_cannot_redirect_the_settle_credit`).
**Recommendation**: Optionally write the record before `unlock`.

## Verified correct
- `testFuzz_settlement_and_exact_payout` (3 positions, 2 owners, random depth, swaps, rebalances
  including same-range ones, both exit modes). After every step, claims equal the sum of `idle`, and no
  rebalance revert is ever `CurrencyNotSettled`, a price-limit error or a panic. Every withdraw pays
  exactly principal (rounded down) plus fees plus idle, to its own owner. Over 40 seeds, 185 rebalances
  succeeded and 115 of them left idle.
- The one-sided fallback (`testFuzz_one_sided_fallback_settles`) settles and pays exactly; the range
  narrowed in 17 of 30 seeds.
- Extreme prices at ±800k ticks (`testFuzz_extreme_price_settles`): no overflow in the value guard,
  the swap sizing or the price limits.
- Fee switched on after deposit, tokens that revert on zero transfers, a blacklisted hook (blocks new
  deposits only), a blacklisted PoolManager (the claims exit still pays the idle balance in full), and
  the `InvalidRecipient` rejections.
- Prior fixes hold: T-1, T-2 (with the TS-1 caveat), T-3/TK-4, T-7, T-8/T-9, T-10, TK-1, TK-2, TK-5.
  The hook grants no ERC-6909 operator or allowance.

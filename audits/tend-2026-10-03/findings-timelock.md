# Findings — governance / access control (owner timelock)

PoCs: `contracts/test/audit/TimelockPoC.t.sol` (14 tests, all passing). Checklists:
evm-audit-governance, evm-audit-access-control.

| ID | Title | Severity | PoC |
|---|---|---|---|
| TL-1 | Lowering `maxTickMovePerBlock` is instant but freezes the reference, defeating the A-9 cap | **Medium** | reproduced |
| TL-2 | Calldata with extra trailing bytes gets a new queue id: cancel misses variants, and a matured change stays ready to fire indefinitely | Low | reproduced |
| TL-3 | A queued change is classified at execution, so a no-op entry can loosen with no fresh delay | Low | reproduced |
| TL-4 | The queue survives ownership transfer and can't be listed on-chain | Low | reproduced |
| TL-5 | Any instant tightening takes at least 2 days to undo | Low/Info | reproduced |
| TL-6 | An owner-controlled sequencer feed can be set instantly from zero | Info | n/a |
| TL-7 | `PRICE_REF_STALE_AFTER` is declared but never read | Info | n/a |
| X-1 | A one-sided range at the default 200-tick bound loses 117 bps (A-9 territory) | Low → see synthesis | reproduced |

## [TL-1] Instant "tightening" of `maxTickMovePerBlock` freezes the reference and defeats the A-9 cap
**Severity**: Medium. It is an owner-driven loss to depositors with no timelock warning. It needs owner
and rebalancer working together plus a market move.
**Location**: `setPriceGuard` (the loosening check), `_updatePriceRef`, `_requirePriceNotManipulated`
**Description**: Lowering `maxTickMovePerBlock` counts as a tightening, so it is instant. But a slower
reference is a staler one. After `setPriceGuard(1, 200)` the reference moves 1 tick per block. After a
market move of D ticks, the deviation guard admits any spot within 200 ticks of the stale reference,
which can be up to D+200 ticks from fair. The value guard prices both sides at the pushed price and
sees nothing. A rebalancer then pushes spot, rebalances onto a range that sells the appreciated side
at the pushed price, and swaps back. In the default deploy, owner and daemon key belong to the same
operator.
**Impact**: Liquidity 1e18 on [-600, 3000], deep pool, 1200-tick drift. With the default guard, a
190-tick push loses 117 bps. After the instant `setPriceGuard(1,200)`, a 989-tick push from fair loses
**636 bps**, 6.4× the tolerance. This can repeat per position every cooldown.
**PoC**: `test_TL1_frozen_reference_one_sided_loss` (logs the reference at tick 21, the push at 989,
and the 636 bps loss). Control: `test_TL1_control_default_guard_refuses_same_push`. With the daemon's
centred range the loss is 66 bps (`test_TL1_centred_range_measurement`).
**Recommendation**: Treat `maxTickMovePerBlock` as two-sided: make it constant, timelock both
directions, or floor it. Alternatively, use the unused staleness constant.

## [TL-2] Trailing-byte variants of queued calldata
**Severity**: Low. The id is `keccak256(raw calldata)`, and the ABI decoder ignores trailing bytes.
Cancelling the canonical encoding leaves a variant live
(`test_TL2_trailing_bytes_variant_survives_cancel`). Re-queuing a variant keeps a matured change
ready to fire indefinitely (`test_TL2_change_can_be_kept_armed_indefinitely`: still executable 120 days
after the first queue).
**Recommendation**: Require the exact ABI length, and allow one pending entry per selector.

## [TL-3] A queued change is classified at execution time
**Severity**: Low. The owner queues `setMaxRebalanceLossBps(100)` while the value is already 100 (a
no-op), then instantly tightens to 25 and executes, restoring 100 with no fresh warning
(`test_TL3_noop_queued_becomes_loosening_after_tightening`).
**Recommendation**: An instant tightening should cancel pending entries for the same setter.

## [TL-4] The queue survives an ownership transfer
**Severity**: Low. A new owner, such as a multisig or a key-compromise recovery, can inherit armed
changes it doesn't know about (`test_TL4_queue_survives_ownership_transfer`).
**Recommendation**: Fold an ownership epoch into the change id, or keep pending ids enumerable.

## [TL-5] Tightenings take at least 2 days to undo
**Severity**: Low/Info. An accidental `setPriceGuard(1,1)` or a 365-day cooldown blocks rebalancing
for at least 2 days (`test_TL5_tightening_cannot_be_reverted_without_delay`). Document
`pause`/`unpause` as the emergency lever.

## [TL-6] An owner-controlled sequencer feed can be set instantly from zero
**Severity**: Info. A mutable contract set as the feed can report anything, which is equivalent to
replacing the feed. Pin and assert the expected feed per chain in the deploy script.

## [TL-7] `PRICE_REF_STALE_AFTER` is never read
**Severity**: Info. Its comment describes a rule that doesn't exist. Implement it or remove it.

## [X-1] One-sided range at the default bound exceeds the tolerance
**Severity**: Low as filed here. Escalated in synthesis because it falsifies the §9 A-9 claim.
§9's 78 bps worst case measured only ranges centred on the push. A token1-only range below a pushed
spot loses **117 bps** at the default guard, with no owner action
(`test_X1_one_sided_range_at_default_bound_exceeds_tolerance`).

## Verified correct
- Only the six setters can be queued, and inputs under 4 bytes are rejected. None moves funds or
  makes an external call, and the self-call can't reach withdraw or ownership functions.
- `_executingQueued` rolls back on a failed execution (`test_VC_flag_reset_after_failed_execution`).
  It is not re-enterable, and a call from the hook's own address outside `executeChange` still needs
  the owner (`test_VC_direct_self_flag_unreachable`).
- Compound changes such as raising one price-guard bound while lowering the other, or removing then
  re-adding a rebalancer, need the queue. TL-1 is the only instant route to a looser state.
- The execution window is correct and re-queuing never shortens the wait.
- Withdraw works under pause, allowlist enforcement, every parameter at its tightest, and with the
  rebalancer removed (`test_VC_withdraw_ungated_by_instant_levers`).
- `renounceOwnership` reverts, the two-step transfer works, and a pending owner has no powers.

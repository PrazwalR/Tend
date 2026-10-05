# Findings — DoS, griefing and liveness (full audit, f993a76)

PoCs: `contracts/test/audit/full/LivenessPoC.t.sol` (3 tests, passing) and the test-only module
`crates/lpa/src/chain/subscriber/liveness_poc.rs`. LV-6 is `#[ignore]` because it takes about 40 s.
Checklists: evm-audit-dos, evm-audit-general. OR-1/AM2-1 and AM2-2 are not re-reported.

| ID | Severity | Title | PoC |
|---|---|---|---|
| LV-7 | **High** | A failed send burns a cached nonce, and every later transaction is stuck until restart. **Same root cause as DM-2, reached independently** (a gas estimate failing at send time) | reproduced |
| LV-1 | **Medium** | A dust LP position defeats the DS-1 one-sided fallback, so the position goes ~100% idle repeatedly. Attacker-triggered form of AM2-2 | reproduced |
| LV-2 | **Medium** | With no liquidity at spot, `PriceUnsettled` can be held forever for gas only | reproduced: 100/100 blocks refused, 0 tokens spent |
| LV-3 | **Medium** | A price-dependent `OutOfBounds` is classified Terminal, suppressing an honest position for 6 h | reproduced |
| LV-4 | **Medium** | One backfill chunk the provider refuses blocks the watermark forever, and every replay resets positions to stale ranges | reproduced |
| LV-5 | **Medium** | The in-flight marker leaks when the executor dequeues before `mark_queued`, blocking the position until restart | reproduced: 763 leaks in 20,000 intents |
| LV-6 | **Medium** | The out-of-range sweep isn't batched, so dust positions exhaust the sweep timeout and the idle sweep never runs | reproduced |
| LV-8..LV-13 | Low/Info | Duplicate swap processing and replay order; pokes when the reference already equals spot; global budget; `is_blocked` race; timeout after send; selector search over the whole revert text; backfill reads the unsafe head | — |

## [LV-7] A failed send burns a cached nonce
**Severity**: High. All automation stops until restart, and no attacker is needed.
**Description**: The gas and nonce fillers run in parallel. Once the nonce cache is warm, its branch
increments even when the gas branch then fails. `execute` sends without setting gas, so the gas filler
estimates again at the node's default block, where a refusal is possible. One such failure, or a send
that errors, leaves every later transaction with a future nonce. The node queues it and never mines
it, and nothing re-syncs the cache.
**PoC**: `lv7_failed_send_burns_a_cached_nonce_and_wedges_every_later_tx`: send 1 gets nonce 0 and is
mined; send 2 reverts in estimation; sends 3 and 4 get nonces 2 and 3 while the chain expects 1.
**Recommendation**: Set the nonce yourself from the pending count (or use `SimpleNonceManager`), pass the
gas already estimated at `pending`, and re-sync the nonce after `NotSent` or `Unconfirmed`.

## [LV-1] A dust LP defeats the one-sided fallback
**Severity**: Medium. A one-wei-scale return from the re-ratio swap makes the straddle compute about 2e5
liquidity, so the fallback is skipped. The recorded range straddles spot, and the same-range redeploy
hits the same wall every time. The attacker spends about 230k gas and recovers their tokens.
**PoC**: `test_LV1_dust_depth_defeats_one_sided_fallback`. The control places 1.76e18; under attack 2e5
is placed and 6.0e16 token0 sits idle; a redeploy places 5e5.
**Recommendation**: Compare the straddle against the one-sided placement and take whichever puts more
value to work. This fixes AM2-2 as well.

## [LV-2] `PriceUnsettled` held for gas only
**Severity**: Medium. With no liquidity active at spot (the normal state for an out-of-range position
in a hook-only pool), swaps move price for free. Ending each block more than 500 ticks from the anchor
keeps `stable` at 0. One clamped block end every 5 blocks is enough, roughly $1 an hour on Base. The
daemon pays for a poke every pass.
**PoC**: `test_LV2_free_swaps_hold_price_unsettled_forever`: 100 of 100 blocks refused, 0 tokens spent,
about 48k gas per block.
**Recommendation**: Don't count a block end as destabilising when active liquidity at spot was 0.
Don't poke when the reference already equals spot.

## [LV-3] Transient `OutOfBounds` treated as Terminal
**Severity**: Medium. The daemon centres its proposals on spot without knowing the owner's bounds. Near a
bound, the range crosses it and the position is suppressed for 6 h, although a range clipped to the
bounds succeeds at the same price.
**PoC**: `test_LV3_outOfBounds_is_transient_and_price_dependent`.
**Recommendation**: Read the bounds and clip proposals to them. Classify `OutOfBounds` as Retry.

## [LV-4] A refused backfill chunk blocks the watermark
**Severity**: Medium. If `eth_getLogs` fails for a 500-block chunk (a provider's result cap, the 16 MiB
frame limit, which a dust-swap flood can exceed, or a range limit), the watermark never moves again. Every
pass replays the chunk's `PositionOpened`, resetting rebalanced positions to their opening range, so the
daemon pays to rebalance positions that are in range on-chain.
**PoC**: `lv4_refused_chunk_wedges_watermark_and_replays_stale_ranges`.
**Recommendation**: Split failing chunks in half, down to one block. Make replay idempotent by
(block, logIndex), and interleave hook and swap logs.

## [LV-5] In-flight marker leak
**Severity**: Medium. `try_send` runs before `mark_queued`, so a fast executor on another thread can
remove the marker before it is inserted. It then stays forever, and `prune` never clears it.
**PoC**: `lv5_in_flight_marker_leaks_when_executor_wins_the_race`: 763 leaks in 20,000 intents.
**Recommendation**: Mark before sending and roll back on error, and give markers a TTL.

## [LV-6] Out-of-range sweep not batched
**Severity**: Medium. `propose_rebalance` makes 4 RPCs per position (position value) before deciding,
and before checking queue capacity. About 300 dust positions at 20 ms push every pass past 20 s, so
`sweep_idle` never runs.
**PoC**: `lv6_out_of_range_dust_starves_the_idle_sweep` (`--include-ignored`).
**Recommendation**: Batch with a cursor, check capacity and run `decide` before any RPC, back off
positions the EV gate declines, and give each sweep its own time budget.

## Verified correct
- No third party can block withdraw, including in the LV-1 and LV-2 states.
- The value guard at the reference doesn't refuse honest rebalances: `stable ≥ 5` means the reference
  sat on spot at the last block end.
- DS-1 (attacker-free), DS-2, DS-3, DS-4 (apart from LV-5), DS-5 (apart from LV-6), DS-6, DS-7 and DS-8
  hold. DS-9 holds for the preflight; the send-time estimate does not (LV-7).

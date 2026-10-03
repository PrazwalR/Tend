# Findings — DoS, griefing and liveness (contract + daemon)

Commit audited: `5401dd9`. Checklists: evm-audit-dos (17 items) plus the DoS/liveness/oracle items
of evm-audit-general. PoCs: `contracts/test/audit/DosPoC.t.sol` and a test-only `dos_poc` module in
`crates/lpa/src/chain/subscriber.rs`. Every Medium-or-above PoC was run and passes.

| ID | Severity | Summary | PoC |
|---|---|---|---|
| DS-4 | **High** | 64 stuck or dust out-of-range positions fill the 64-slot intent queue on every sweep; every position indexed after them is permanently dropped | reproduced (Rust) |
| DS-1 | **Medium** | Recentring an out-of-range position onto a straddling range reverts `ZeroLiquidity` with no depth inside the 50 bps band (REG-1 returns; hook-only pools hit it with no attacker) | reproduced (Foundry) |
| DS-2 | **Medium** | The daemon's 99% `minLiquidity` floor turns a depth pull between preflight and inclusion into a paid on-chain revert | reproduced (Foundry) |
| DS-3 | **Medium** | The daemon serves anyone's positions: one free swap in an attacker-owned hooked pool forces about 1,600 paid poke transactions (about 191× gas) | reproduced (Foundry) |
| DS-5 | **Medium** | The sweep blocks the watch loop and restarts from the top on timeout: tail positions are never idle-checked, and logs past the newest 16 are lost while the watermark advances | reproduced (Rust; log loss models alloy's documented behaviour) |
| DS-6 | Low | A reverted rebalance is logged as success; no escalating backoff; the throttle is set even without a send | n/a |
| DS-7 | Low | No timeouts on executor RPCs; one hung request wedges the executor | n/a |
| DS-8 | Info | Daemon maps are never pruned, including on `PositionClosed` | n/a |
| DS-9 | Info | Preflight at `latest` sees the same-block anchor, giving false `PriceDeviation` and useless pokes | n/a |
| DS-10 | Info | `PRICE_REF_STALE_AFTER` is unused; comments still say the residual is "returned to the owner" | n/a |

## [DS-4] 64 stuck or dust out-of-range positions permanently starve every position indexed after them
**Severity**: High (permanent DoS of automation)
**Location**: `subscriber.rs` `sweep_out_of_range` / `propose_rebalance` (`try_send`);
`AUTO_INTENT_CHANNEL_CAP = 64`; `tracker.rs` `positions_with_range_state` (no ORDER BY, so insertion
order)
**Description**: Every sweep pushes an intent for every out-of-range position into the 64-slot
channel, in a loop that never waits on the executor. The executor drains it serially, so the first 64
rows by insertion order take every slot and later intents are dropped. To trigger it, an attacker
opens 64 dust positions that stay out of range forever: with `AUTOMATION_OFF` (refused instantly and
permanently), or in an attacker-owned pool (DS-3). It also happens with no attacker once more than 64
positions are stuck. Dropped idle intents still count as `RedeployGate` strikes.
**Impact**: Positions opened after the spam are never automated. The attacker pays about 64 deposits,
once.
**PoC**: `ds4_attacker_positions_starve_later_honest_positions` (real sweep, strategy and channel):
"pass 0: executor saw 64 intents, honest among them: false", and the same for passes 1 and 2.
**Recommendation**: Stop re-proposing positions whose last refusal was terminal (`AutomationDisabled`,
`NotRebalancer`, `OutOfBounds`, `PositionNotActive`, repeated `ZeroLiquidity`). Allow one in-flight
intent per position, rotate the sweep order, and treat a closed channel separately from a full one.

## [DS-1] Straddling rebalance reverts `ZeroLiquidity` when depth in the swap direction is gone
**Severity**: Medium
**Location**: `_doRebalance`; `_swapToRatio` / `_correctOvershoot`
**Description**: An out-of-range position holds one token only. Recentred onto a range that straddles
spot, with no liquidity within `maxSwapImpactBps` (about 100 ticks) in the swap direction:
- The first leg moves price to the impact limit and fills nothing.
- The correction leg is skipped because it would run in the same direction.
- `getLiquidityForAmounts` returns 0, so the call reverts `ZeroLiquidity` even with
  `minLiquidity = 0`.
There is no partial fill, so the idle mechanism does not help. Two ways to reach it:
- **Attacker:** an LP holding the only depth on that side withdraws it (71.5k gas).
- **No attacker:** each hooked pool is a separate v4 pool, so the hook's own positions are often its
  only liquidity, and the daemon only ever proposes straddling ranges.
**Impact**: The position stays out of range and earns nothing, indefinitely. Funds stay withdrawable.
**PoC**: `test_DS1_depthPull_bricks_straddle_rebalance_with_zero_floor`. The control lands at
9.70e17; after the pull it reverts `ZeroLiquidity`.
`test_DS1b_hook_only_pool_cannot_recentre_out_of_range_position`: `[-1500,-300]` reverts and the
one-sided `[-840,-300]` succeeds.
**Recommendation**: Fall back to the part of the range the held token can fund on its own (contract),
or propose a one-sided range after `ZeroLiquidity` (daemon). Add a straddling-target regression test.

## [DS-2] The daemon's 99% `minLiquidity` floor turns a depth pull into a paid on-chain revert
**Severity**: Medium
**Location**: `exec/mod.rs` `execute` (default `slippage_bps = 100`)
**Description**: The floor is 99% of the liquidity the preflight quoted. A depth pull between
preflight and inclusion makes the transaction revert `SlippageExceeded`. That undoes the contract's
REG-1 fix, which parks the unfilled part as idle instead of reverting. Retries follow a flat 300 s
delay.
**PoC**: `test_DS2_daemon_floor_turns_depth_pull_into_onchain_revert`. Quoted 9.70e17, floor 9.61e17,
reverts after the pull. With floor 0 it lands at 2.04e17 and parks 4.7e16 token0 as idle.
**Recommendation**: Send `minLiquidity = 0` or a value-based floor, and rely on the contract's
guards. Back off exponentially after on-chain reverts.

## [DS-3] Anyone's positions draw on the daemon's gas
**Severity**: Medium
**Location**: `exec/mod.rs` `run_executor_loop` / `poke_once`; `subscriber.rs` `handle_opened`;
`pokePriceRef`; `_pairKey`
**Description**: The daemon indexes and serves every hook position, whoever owns it. The allowlist is
per pair, so anyone can create a new hooked pool for an allowed pair and deposit dust. In their own
empty pool the attacker moves spot freely while the reference trails 500 ticks a block, and the daemon
answers every `PriceDeviation` with a poke it pays for. The EV gate doesn't filter these, because the
position value is unknown (0). If the attacker also adds ordinary liquidity, the daemon pays for full
rebalances whenever the positions are pushed out of range. There is no aggregate spend budget.
**PoC**: `test_DS3_one_free_swap_forces_many_daemon_pokes`. The attacker's swap costs 222k gas; the
daemon sends 1,599 pokes (42.5M gas, about 191×). Gas is warm in the test, so this understates it.
**Recommendation**: Serve only intended positions (scoped to this rebalancer, owner-allowlisted, or
above a minimum value). Add global and per-pool gas budgets, give up poking past K × 500 ticks of gap,
and allowlist full pool keys instead of pairs.

## [DS-5] The sweep blocks the watch loop and is abandoned at 20 s
**Severity**: Medium
**Location**: `subscriber.rs` `watch_once`, `sweep_idle`; alloy-pubsub `sub.rs:348`
**Description**: `sweep_idle` makes one sequential RPC per in-range position. With about 200
positions, every pass times out at 20 s and the next pass restarts from the top, so tail positions are
never examined. While the sweep runs, the `select!` isn't reading logs. alloy buffers 16 items per
subscription and silently skips overflow, so swaps and hook logs are lost, and the watermark still
advances.
**PoC**: `ds5_sweep_timeout_never_reaches_tail_positions` (`#[ignore]`, 20 s; real `sweep_idle`
against a mock RPC): "pass timed out: true … honest position queried: false".
`ds5_logs_arriving_during_a_sweep_beyond_16_are_lost`: 16 of 40 delivered.
**Recommendation**: Run the sweep in its own task, fetch idle with one multicall, resume each pass
from a cursor, and backfill on lag instead of advancing the watermark.

## [DS-6] A reverted rebalance is logged as success
**Severity**: Low. "auto-rebalanced on-chain" is logged without checking the receipt's `success`.
The retry delay is a flat 300 s, and `last` is set before an `execute` that may never send.

## [DS-7] No timeouts on executor RPCs
**Severity**: Low. One hung request blocks the serial executor permanently.

## [DS-8] Daemon maps are never pruned
**Severity**: Info. Growth is bounded by the number of deposits ever made.

## [DS-9] Preflight at `latest` sees the same-block anchor
**Severity**: Info. It gives false refusals and useless pokes, never a false pass. Simulate at
`pending`, or skip the poke when the reference already equals spot.

## [DS-10] Doc/code drift
**Severity**: Info. Same as PR-4, TL-7, AM-5 and TK-5.

## Verified correct
- No third party can make withdraw revert: it is ungated, claims always match recorded idle, and
  `asClaims` or an alternate recipient bypasses a token that reverts on transfer.
- `NoOpRebalance`, the timelock, `SafeCast` in `_holdIdle` and `NothingFreed` can't be used to grief.
- On deep pools, holding a deviation refusal across blocks costs about 2% against arbitrage.
- No loops in the contract; `_afterSwap` is O(1).
- `RedeployGate` arithmetic is capped and overflow-free; `poke_due` throttles per pool.

# Findings — oracles and manipulation resistance (full audit, f993a76)

PoCs: `contracts/test/audit/full/OraclePoC.t.sol` (extends `PriceRefPoC`). OR-1 was re-run
independently during synthesis and reproduced with an unmodified `contracts/src`. Checklists:
evm-audit-oracles, evm-audit-flashloans.

| ID | Severity | Title | PoC |
|---|---|---|---|
| OR-1 | **High** | Moving price ≤ 500 ticks per block end never resets the stability counter, which reopens PR-1 | reproduced, attacker profitable |
| OR-2 | Low | The hook's own re-ratio swap moves spot without writing the reference (same as CO-2) | reproduced |
| OR-3 | Low | Keeping the reference unsettled (DoS) is possible but costs 6–11% of pool TVL per hour | cost measured |
| OR-4 | Info | Daemon ETH/USD oracle: loose answer age, weak feed check, no L1 data fee | n/a |

## [OR-1] Moving price ≤ 500 ticks per block end skips `MIN_STABLE_BLOCKS`
**Severity**: High. It is a third-party fund loss under the same conditions PR-1 was rated High:
hold a pushed price across one block end, and land before arbitrage in the next block.
**Location**: `_updatePriceRef`, `_stableAfter`, `_requirePriceNotManipulated`
**Description**: `stable` only resets when the last write of a block was clamped, which needs a move of
more than `maxTickMovePerBlock` from the anchor. A move of 500 ticks or less is unclamped, and the
reference follows spot completely. So `stable` never resets: on a quiet pool it stays saturated at 255
while the reference moves a full 500 ticks per block end. The fix tracked whether the reference
caught up with spot, never whether it stood still. Its own regression test pushed 700 ticks at once,
which clamps; a 500-tick step never does. Once the reference has moved, every guard measures from it:
the deviation window and the value guard, both at the anchor. A front-run of a further +200 is still
caught by the value guard (`ValueLossExceeded`), so the attack is the step alone, with the daemon
re-centring on the spot it sees.
**Impact** (victim loss against a no-rebalance control; attacker P&L at the fair price, all fees
included; no arbitrage modelled):

| Scenario | Victim loss | Attacker |
|---|---|---|
| The fix's own case: push 700, one held block end | refused | — |
| Deep pool (1e21), victim [-600,600], one block end at +500 | **342 bps** | loses (fees) |
| Same, −500 | **342 bps** | |
| Same, two block ends (500, then 1000) | **799 bps** | |
| 0.05% pool, liquidity 1e19, victim [-1200,-600], one block end | **485 bps** | **+1.14e15 (~4% of victim)** |
| Same pool, two block ends | **949 bps** | **+2.2e15 (~7.7%)** |

Right after one step the reference reads `anchor = 501`, `clamped = false`, `stable = 255`.
**PoC**: `forge test --mc OraclePoC --mt OR1 -vv`, 4 passing tests.
**Recommendation**: Count stability against a fixed base, not the moving anchor. Reset `stable` (and
the base) whenever a completed block end leaves the reference more than `maxDeviationTicks` from the
base, or was clamped. Then the last K block-end ticks must all sit inside one deviation window. Add
regressions for steps of 500, 200×k and alternating directions. The honest cost: a trend faster than
200 ticks per 5 blocks delays rebalancing.

## [OR-2] The hook's own re-ratio swap moves spot without writing the reference
**Severity**: Low. Same root cause as CO-2. A rebalance moves spot (measured −1 → 60) while `ref.tick`
stays at −1 and unclamped, and the quiet blocks after it count as "on spot". Only the trusted
rebalancer triggers these swaps, and no exploit was found.
**Recommendation**: Call `_updatePriceRef(id, spotAfter)` at the end of `_doRebalance`.

## [OR-3] Keeping the reference unsettled is costly but possible
**Severity**: Low. An attacker can either displace the price by more than 200 ticks at each block end,
or force a clamp every 5 blocks. A 201-tick round trip costs 6.05e16 / 6.65e14 / 1.21e14 wei on
background liquidity of 1e21 / 1e19 / 1e18. Held every Base block, that is roughly 6–11% of pool TVL
per hour. The daemon's pokes in response are capped by `SpendBudget`.

## [OR-4] Daemon ETH/USD oracle
**Severity**: Info.
- Answers up to 3,600 s plus 120 s old are accepted. Base's heartbeat is 1,200 s, so about 1,500 s is
  enough.
- The `description()` check only tests that the string contains "ETH" and "USD". This is mitigated by
  the hardcoded addresses (Base `0x7104…Bb70` reads "ETH / USD").
- There is no min/max bound and no `answeredInRound` check.
- `rebalance_cost_usd` leaves out Base's L1 data fee, so the spend caps understate cost.
- With the feed down, spending stops by design: fail-closed.

## Verified correct
- PR-1 as originally framed: a single push beyond the cap is refused both ways. PR-2 / X-1: the guard
  at the anchor catches a further front-run. TL-1 is timelocked both ways. A same-block
  push-and-restore leaves the reference in place. Reseeding converges, and there's no int24 overflow
  at the extremes. All `test/audit/*` suites pass.
- `stable` uint8 saturation is harmless, quiet-block counting is correct, and the write-skip only
  applies within a block.
- `_requireSequencerUp`: `answer == 0` means up, `startedAt == 0` is refused, and the grace period runs
  from `startedAt`. The live Base feed `0xBCF8…6433` description matches the deploy check. The
  gas-bounded staticcall can't be starved into failing open.

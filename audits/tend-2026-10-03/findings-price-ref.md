# Findings — price reference and manipulation guards

PoCs: `contracts/test/audit/PriceRefPoC.t.sol` (12 tests, passing). Victim, background LP and
attacker are separate addresses, and every scenario ends at fair price (tick 0). Losses are measured
against a no-rebalance control and against a fair-price rebalance, with attacker P&L after all fees.
Checklists: evm-audit-oracles, evm-audit-flashloans.

| ID | Severity | Title | PoC |
|---|---|---|---|
| PR-1 | **High** | One block boundary moves the reference 500 ticks, so a rebalance is accepted up to 700 ticks from fair | reproduced, profitable |
| PR-2 | **Medium** | The "78 bps worst case" is understated: 96 bps with the daemon's real range, 148–195 bps out of range | reproduced |
| PR-3 | Low | Rebalances can be refused cheaply in thin pools | reproduced |
| PR-4 | Info | `PRICE_REF_STALE_AFTER` is never used and its comment contradicts the behaviour | n/a |
| PR-5 | Info | The daemon's pokes help drag the reference toward a held price (no new capability) | n/a |

## [PR-1] One block boundary moves the reference 500 ticks, so a rebalance is accepted up to 700 ticks from fair
**Severity**: High
**Location**: `MAX_TICK_MOVE_PER_BLOCK = 500`, `_updatePriceRef`, `_requirePriceNotManipulated`
**Description**: The deviation check compares spot with the reference at the start of the block, which
is the previous block's last write and can sit up to 500 ticks from the block before. The per-block
step (500) is 2.5× the window (200), so one displaced block end shifts the next block's window to
[300, 700]. In general, k displaced block ends admit 500·k + 200 ticks.
This is how A-9 would actually happen. The daemon centres on the tick it sees and simulates against
the latest block, so a pushed price it centres on is already a block-end state that has moved the
reference. Flow: the attacker makes the last swap of block N at +700. The daemon simulates against N
and sends a rebalance onto [640, 780]. That rebalance lands in N+1 while the price is held, and the
attacker swaps back. One push hits every position the daemon rebalances in that pool.
Conditions: the attacker needs the last swap of block N, and the rebalance has to run in N+1 before
arbitrage restores the price. On L1 that means ordering control or the public mempool (the daemon
sends with plain `send()`). It is harder on Base's private sequencer mempool. The hold can't be
flash-loaned.
**Impact**:

| Scenario | Victim loss vs no-rebalance | Attacker absolute P&L |
|---|---|---|
| 0.3% pool, background 1e21, push 200, no hold | 96 bps | negative |
| same pool, push 700, 1 hold | **519 bps** | negative |
| same pool, push 1200, 2 holds | **995 bps** | negative |
| 0.05% pool, background 1e19, out-of-range victim, push 700, 1 hold | **673 bps** | **+1.58e15 (5.5% of victim value)** |

**PoC**: `test_PR1_single_boundary_hold_admits_700_ticks`, `test_PR1_single_boundary_hold_downward`,
`test_PR1_reference_window_after_one_displaced_block_end`, `test_PR_net_profit_fee500`. A 690-tick push
inside a single block is refused, so the block boundary is the only thing the attacker gains.
**Recommendation**: Refuse a rebalance while the reference is still being clamped (require spot within
the window of the last K block-end ticks). Value the loss guard at the reference price, and require the
new range to contain the anchor. Tighter knobs alone do not close it:
`test_PR1_mitigation_tighter_guard` still loses 97 bps at `setPriceGuard(50,50)`. In the daemon, use
a private relay and check price stability over several blocks.

## [PR-2] The "78 bps worst case" at 200 ticks is understated
**Severity**: Medium
**Location**: `MAX_DEVIATION_TICKS` rationale comment; `_a9Run` harness
**Description**: The calibration used `[(push/60)*60 ± 60]`, not the daemon's
`[floor(t−s), ceil(t+s)]`. It also left out the case the daemon acts on most: a position already out
of range, holding one token, which converts about half of it at the pushed price.
**Impact** (same block, push exactly 200, loss vs no-rebalance): tick spacing 60, ±600 position, daemon
range: 96 bps · spacing 60, out-of-range: 183 bps · spacing 60, narrow position: 183 bps · range
placed above spot: 140 bps · wide range: 33 bps · spacing 1, out-of-range: 181 bps · spacing 10:
108 bps · spacing 200, out-of-range: 148 bps · **0.05% pool, out-of-range: 195 bps, attacker net
+4.56e14** · thin book: 21 bps (the impact bound stops the swap and the rest goes idle). Out-of-range
positions lose roughly 1 bps per tick of push.
**PoC**: `test_PR2_shapes_at_the_bound_spacing{60,1,10_200}`, `test_PR2_thin_book_push_plus_impact`.
**Recommendation**: The structural fix is valuing the loss guard at the reference price (PR-1 rec. 3).
Recalibrate the A-9 test and correct the comment.

## [PR-3] Rebalances can be refused cheaply in thin pools
**Severity**: Low. A 201-tick push can front-run a rebalance, and the daemon retries every sweep, so
each refusal is paid for again. Cost per refusal: 6.05e16 at background liquidity 1e21, 6.65e14 at
1e19, 1.2e14 at 1e18 (about 0.2% of position value). Withdrawals are never gated
(`test_PR3_grief_cost_per_refusal`).

## [PR-4] `PRICE_REF_STALE_AFTER` is never used
**Severity**: Info. The comment says a stale reference "must not be allowed to veto". Nothing reads
the constant, and a stale reference does veto until someone pokes it.

## [PR-5] The daemon's pokes help drag the reference toward a held price
**Severity**: Info. A dust swap does the same, so this gives the attacker no new capability. It only
saves the attacker those writes. Fixing PR-1 makes this harmless.

## Verified correct
- A same-block displace-and-restore leaves the reference where it began, and a front-run in the same
  block can't shift the anchor. A 690-tick push within one block is refused.
- The hook's own swap does not update the reference, and several rebalances in one block are checked
  against the same anchor.
- Pokes move one clamped step per block, only toward spot. A poke on a pool with no positions does
  nothing.
- Seeding: a first depositor who seeds at +3000 converges back to fair in 5 blocks of pokes, and
  rebalances are refused during the lag, which is the safe direction.
- `anchor ± 500` can't overflow int24; the reference converged at spot 886621.
- After a genuine move of D ticks, rebalancing resumes in about ⌈(D−200)/500⌉ blocks.

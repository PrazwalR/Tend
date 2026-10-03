# Tend re-audit — 2026-10-03

**Target:** `contracts/src/AutopilotHook.sol` and the `lpa` daemon, at commit `5401dd9`
(`feat/indexing-enrichment`).
**Scope:** everything since the last independently reviewed commit `4a4c95e`
(`contract-changes.diff`, 501 lines), and how the daemon drives it:
- the price-reference redesign (Sept 25), which until now only its author had checked;
- idle balances held as ERC-6909 claims, and the corrective swap leg;
- the 200-tick deviation cap and the 50 bps impact default (the A-9 and R-6 fixes);
- the owner timelock;
- the deploy script's allowlist configuration;
- the daemon's sweep, pokes and idle redeploys.

**Method:** five parallel reviewers, one per domain, each walking an evm-audit-skills checklist:

| Reviewer | Checklists | Findings file |
|---|---|---|
| AMM & math | defi-amm, precision-math | `findings-amm-math.md` |
| Timelock | governance, access-control | `findings-timelock.md` |
| Price reference | oracles, flashloans | `findings-price-ref.md` |
| DoS & liveness | dos, general | `findings-dos.md` |
| Tokens & settlement | erc20, general | `findings-token.md` |

Every Medium-or-above finding had to come with a PoC the reviewer ran. The PoCs are committed on the
reviewers' `worktree-agent-*` branches under `contracts/test/audit/`, plus a test-only Rust module.
The two High findings and three of the Mediums (TL-1, X-1, DS-1) were then **re-run independently**
during synthesis. All reproduced against an unmodified `contracts/src`.

No GitHub issues were filed. The repo is public and these findings are unfixed.

## 1. Summary

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | |
| High | 2 | PR-1, DS-4 |
| Medium | 8 | TL-1, PR-2 (with X-1), DS-1, DS-2, DS-3, DS-5, TK-1 |
| Low | 10 | AM-1, TL-2, TL-3, TL-4, TL-5, PR-3, DS-6, DS-7, TK-2 |
| Info | ~12 | doc drift and notes, including a duplicate cluster on `PRICE_REF_STALE_AFTER` and stale NatSpec |

**The headline: three of my own claims from the last round are false.**

1. **"The 200-tick deviation bound limits manipulation loss to 78 bps."** It doesn't. PR-2 / X-1:
   the 78 bps figure measured only ranges centred on the push. A one-sided or out-of-range position
   loses 117–195 bps at the same bound, and the attacker profits after fees in a 0.05% pool. PR-1:
   the bound isn't really 200 ticks either. One held block boundary moves the reference 500 ticks,
   so a rebalance is accepted 700 ticks from fair. That cost 519–995 bps, and was profitable in a
   0.05% pool (+5.5% of the victim's value).
2. **"Tightening is the safety lever, so it can be instant."** It isn't, for one setter. TL-1:
   lowering `maxTickMovePerBlock` is classed as a tightening, but it freezes the reference. That
   reopens A-9 at 636 bps with no timelock warning.
3. **"A tight impact bound now costs only temporary idle capital."** It doesn't. DS-1 was confirmed
   during synthesis as a regression from the 50 bps default. With no depth within the band, an
   out-of-range position can't be recentred onto a straddling range at all: it reverts
   `ZeroLiquidity` and nothing is filled to park as idle. At the old 1000 bps default the same
   tests pass. In a pool where the hook is the only LP this needs no attacker.

The idle-claims accounting itself held up under everything thrown at it. Four reviewers
independently verified that claims back idle 1:1, flash-accounting deltas net out, and no third
party can block a withdraw.

## 2. Findings by priority

### High

**[PR-1] One block boundary moves the reference 500 ticks, so a rebalance is accepted 700 ticks from
fair.**
- **Mechanism:** the per-block step (500) is larger than the deviation window (200). Each held block
  end widens the admissible push by 500 ticks.
- **How it fits A-9:** this is the realistic path. The daemon centres on what it sees at `latest`,
  and anything at `latest` is already a block-end state.
- **Mitigation does not close it:** tightening the knobs (`setPriceGuard(50,50)`) still loses 97 bps.
- **Fix direction:** refuse while the reference is still being clamped (require spot within the
  window of the last K block-end ticks). Value the loss guard at the reference price. Require the
  new range to contain the anchor. In the daemon, use a private relay and check price stability
  over several blocks.

**[DS-4] 64 stuck positions permanently starve the daemon's intent queue.**
- **Mechanism:** the sweep fills the 64-slot channel in insertion order, so later positions are
  never served.
- **Cost to trigger:** an attacker needs 64 dust deposits (with `AUTOMATION_OFF`, or in their own
  pool). It also happens with no attacker once more than 64 positions are genuinely stuck.
- **Note:** the PoC reproduced. The executor saw 64 intents on pass 0 and 5 on later passes, and the
  honest position was dropped on every pass.
- **Fix direction:** stop re-proposing positions whose last refusal was terminal, allow one
  in-flight intent per position, and rotate the sweep order.

### Medium

| ID | One line | Fix direction |
|---|---|---|
| TL-1 | Instantly lowering `maxTickMovePerBlock` freezes the reference: 636 bps | Make it two-sided (constant, timelocked both ways, or floored) |
| PR-2 / X-1 | A-9 calibration was wrong: 96–195 bps at the 200-tick bound | Structural fix with PR-1; recalibrate `test_a9_*` with the daemon's real range and out-of-range positions |
| DS-1 | One-sided positions can't be recentred onto straddling ranges without depth in the 50 bps band (my regression) | Contract falls back to the fundable one-sided part of the range, or the daemon proposes one-sided after `ZeroLiquidity` |
| DS-2 | The daemon's 99% liquidity floor turns a depth pull into a paid on-chain revert, undoing REG-1's fix off-chain | `minLiquidity = 0` (or value-based); exponential backoff after reverts |
| DS-3 | The daemon pays to serve anyone's positions: one free swap forces about 1,600 pokes | Serve only scoped or allowlisted positions; gas budgets; allowlist full pool keys |
| DS-5 | The sweep blocks the log stream; logs past 16 are dropped while the watermark advances; tail positions are never idle-checked | Run the sweep in its own task; multicall; cursor; backfill on lag |
| TK-1 | Deploy script silently skips the allowlist and feed with keystore signers or a multisig owner, and prints a false reason | Use `vm.readCallers()`; always configure as deployer, then `transferOwnership`; assert the resulting configuration |

### Low
- **AM-1:** the corrective leg is skipped when the first swap stops exactly on the range edge.
- **TL-2:** calldata with trailing bytes gets a new queue id, so cancel misses it and a change stays
  ready to fire indefinitely.
- **TL-3:** a queued change is classified at execution time.
- **TL-4:** the queue survives an ownership transfer.
- **TL-5:** a tightening takes at least 2 days to undo.
- **PR-3:** rebalances can be refused cheaply in thin pools.
- **DS-6:** a reverted rebalance is logged as success.
- **DS-7:** executor RPCs have no timeouts.
- **TK-2:** the daemon values positions without their idle balance or fees.

### Info
- **Unused constant:** `PRICE_REF_STALE_AFTER` is never read (PR-4, TL-7, DS-10).
- **Stale comments:** NatSpec still says the residual is paid to the owner (AM-5, TK-5, DS-10).
- **Indexing gap:** no event when withdraw releases idle (TK-5).
- **Unprotected levers:** an owner-controlled feed can be set instantly (TL-6). Donated claims are
  stranded (TK-3).
- **Dust and limits:** dust-position ratio sizing (AM-3); unreachable overflow (AM-4).
- **Same-range churn:** it terminates on its own (AM-2).
- **Daemon:** maps are never pruned (DS-8); preflight at `latest` gives false refusals (DS-9).
- **Pokes:** pokes help a held drag, though a dust swap could do the same (PR-5).
- **Rebasing tokens:** T-3 exposure is unchanged (TK-4).

## 3. Verified correct (independently, by two or more reviewers)
- **Claims back idle:** per currency, the hook's claims equal the sum of `idle` plus any donations.
  This held across shared currencies, both withdraw modes, and fuzzed sequences (2000 × 6).
- **Flash accounting:** deltas net to zero in rebalance and in withdraw, and `_sub` cannot underflow.
- **Corrective leg:** it only reverses, is clamped at the starting price, and stays within the
  impact bound (fuzzed).
- **Withdraw:** no third party can block it. It works under pause, enforcement, every parameter at
  its tightest, a paused token (via claims) and a blacklisted owner.
- **Timelock:** only six setters can be queued; the flag is non-reentrant and rolls back on revert;
  re-queuing never shortens the wait. Compound instant changes can't loosen anything except via TL-1.
- **Price reference:** a same-block displace-and-restore leaves it where it began; pokes are one
  clamped step toward spot; seeding converges; no int24 overflow at the tick extremes.
- **Reentrancy:** an ERC777-style callback on the withdraw payout is refused by the guard.

## 4. Recommended fix order
1. **PR-1 + PR-2 + TL-1 together.** They are one design problem: the reference can be stale or
   dragged, and the loss guard can't see it. Value the loss guard at the reference anchor, require
   reference stability over K blocks, make `maxTickMovePerBlock` two-sided, and recalibrate A-9 with
   realistic shapes. Then delete or implement `PRICE_REF_STALE_AFTER`.
2. **DS-1.** A one-sided fallback, so the 50 bps bound no longer bricks recentring.
3. **DS-4, DS-3, DS-5, DS-2.** Daemon robustness: terminal-refusal backoff, serve-scope and gas
   budget, sweep off the watch loop, floor of 0.
4. **TK-1.** The deploy script, before any real deployment.
5. The Lows and Infos.

## 5. Not covered
- **Network ordering:** no fork-based test of L1/Base mempool behaviour. Whether PR-1's "last swap
  of block N, then the rebalance in N+1" ordering is practical on Base's private sequencer mempool
  was argued, not measured.
- **Daemon EV gate:** its economics were reviewed only where they touch DS-3 and TK-2.
- **Fixes:** none of these findings is fixed yet. Every fix needs its own regression test that fails
  against the unfixed code, as before.

## 6. Fix status

Every finding above Info was either fixed with a regression test or declined
with evidence. The reviewers' PoC files are now regression tests in
`contracts/test/audit/`, plus the `dos_poc` Rust module. Each one asserts that its
attack is now **refused** or **bounded** within the loss tolerance; previously each
showed the attack working.

### Price reference and loss guard (PR-1, PR-2, X-1, TL-1)

Three changes, which only work together:

1. **Stability (PR-1).** `PriceRef` records whether its last write was clamped
   and counts consecutive block ends where it ended on spot. A rebalance needs
   `MIN_STABLE_BLOCKS` = 5 of them (`PriceUnsettled`). One held boundary used to
   admit 700 ticks; now the push has to be held for more than five.
2. **Loss guard valued at the reference (PR-2, X-1).** The guard now compares
   the position's value at the reference price before and after: the old
   liquidity's amounts plus fees and idle, against the new liquidity's amounts plus
   what is left idle. That covers the swap fee, the impact, and where the new range
   is placed. Measuring only the holdings around the swap left 181 bps undetected
   at spacing 1. When spot sits on the reference, this is the old swap-cost
   measure, and all 101 existing tests pass unchanged.
3. **Per-block step two-sided (TL-1).** `maxTickMovePerBlock` changes in either
   direction go through the timelock. A queued freeze is still refused, because a
   reference creeping behind the market is clamped on every write and never
   settles.

| Scenario (PoC) | Before | After |
|---|---|---|
| PR-1 one held boundary, push 700 | 519 bps | refused |
| PR-1 two held boundaries, push 1200 | 995 bps | refused |
| PR-1 fee-500 pool, profitable to attacker | +5.5% of victim | refused |
| PR-2 shapes (a)–(k) at the 200-tick bound | up to 195 bps | refused, or ≤ 89 bps |
| X-1 one-sided range at the default bound | 117 bps | refused (`ValueLossExceeded`) |
| TL-1 instant freeze | 636 bps | `ChangeMustBeQueued`; queued freeze refused (`PriceUnsettled`) |
| **Residual:** push held across 7 block ends | — | **519 bps** (`test_PR1_residual_requires_holding_past_stability`) |

**What remains.** An attacker who can hold a pushed price against arbitrage across
more than five consecutive block ends moves the reference itself, and every guard
measures from the reference. The test harness models no arbitrage, so it can't show
what that hold costs. On a deep pool, holding 2% off fair value for 10 s (Base) or
60 s (L1) is expensive. On a thin pool it isn't, which is the same exposure any
LP has in a pool that thin.

**Price of the fix.** Honest rebalances wait after a jump faster than 500 ticks a
block: the daemon pokes the reference up to spot, then it has to sit there for 5
block ends. Quiet blocks count, and so does a trend slower than the per-block
step. A single displaced block end also forces 5 blocks of honest refusals, which
is a grief; it's cheaper than before, and PR-3 alerts on it.

### Timelock (TL-2, TL-3, TL-4)

- **TL-2:** one pending change per setter, keyed by selector. The exact ABI length
  is required, so trailing-byte variants are rejected. `cancelChange` takes the
  selector.
- **TL-3:** an instant change to a setter voids any change pending for it.
- **TL-4:** `ownerEpoch` is bumped on every ownership transfer, and a pending change
  from an earlier epoch can't execute.

**TL-5 is declined and documented.** A same-direction undo window would bring back
TL-3's ambiguity. `pause` is the lever that can be reversed at once.

### Liveness and daemon (DS-1 – DS-9, PR-3, TK-2)

- **DS-1, in the contract:** a straddling target that one-sided holdings can't
  fund is narrowed to the part on the held token's side of spot. The placed range
  is returned and stored, and `Rebalanced` reports it.
- **DS-2:** automatic rebalances send `minLiquidity = 0`. The manual `lpa rebalance`
  keeps its floor.
- **DS-3, in the contract:** the allowlist is keyed by full pool key
  (`setAllowedPool`, hook-checked) and enforced by the deploy script.
- **DS-3, in the daemon:** a rolling hourly spend budget across rebalances and
  pokes (`LPA_MAX_SPEND_USD_PER_HOUR`).
- **DS-4:**
  - refusals are classified by selector: terminal refusals suppress the position
    for 6 h, cooldown for 60 s, everything else backs off 60 s to 1 h;
  - one intent in flight per position, and the sweep order rotates;
  - the idle sweep checks queue capacity before charging the redeploy gate.
  - Regression: the honest position is served on the pass after the spam is
    refused.
- **DS-5:**
  - the sweep runs beside the log stream;
  - each sweep backfills from the watermark, and only the backfill advances it;
  - the subscription buffer is 4096;
  - the idle sweep is batched with a cursor.
  - Regression: every position is reached within ⌈n/40⌉ passes, none near the
    timeout.
- **DS-6:**
  - receipt status is checked, and an on-chain revert is logged as such and
    backed off;
  - the per-position interval starts only for a sent transaction (`ExecFailure`
    tells sent and unsent apart).
- **DS-7:** every executor iteration is bounded by the receipt timeout plus 60 s.
- **DS-8:** the executor maps and the automation state are pruned. Closing a
  position clears its entries.
- **DS-9:** preflight and gas estimation run at the `pending` block. The E2E caught
  a related bug: estimation at `latest` refused a rebalance that preflight had
  passed.
- **PR-3:** poking also covers `PriceUnsettled`. After 50 pokes without a rebalance
  landing in a pool, the daemon warns.
- **TK-2:** position value includes uncollected fees and the idle balance.

### Deploy and token (TK-1, TK-3, TK-5, TL-6)

- **TK-1:**
  - the deploy script reads the real broadcaster with `vm.readCallers()`;
  - it always deploys with the broadcaster as owner, configures, then hands over
    through `transferOwnership`;
  - it asserts the resulting state.
- **TL-6:** a sequencer feed must answer
  `description() == "L2 Sequencer Uptime Status Feed"`.
- **TK-3:** `withdraw` rejects the hook and the PoolManager as recipients
  (`InvalidRecipient`).
- **TK-5:**
  - `IdleReleased` is emitted whenever a held balance leaves storage;
  - `RebalanceResidual` is emitted on every rebalance, zeros included.

### Declined, with evidence

- **AM-1 (strict edge check).** Applied, then reverted. With the strict form,
  the corrective leg at the range edge sells the whole other side, reverses the
  first leg, and the rebalance reverts `ZeroLiquidity`
  (`test_first_leg_on_near_edge_skips_correction` failed). The original
  behaviour leaves about 30 bps idle, and a later rebalance places it.
- **AM-3 (ratio sizing).** Applied, and harmless, but moot. A position small
  enough to round its sizing to zero is also too small for the value guard's
  rounding: a 16-wei position is refused `ValueLossExceeded(12, 16)`. Recorded,
  not claimed as fixed.
- **AM-2, AM-4, TK-4, PR-5.** Info, no change: AM-2 terminates by itself, AM-4 is
  unreachable, TK-4 is the T-3 exposure, and PR-5 is subsumed by PR-1.

### Verification
- `forge test`: 147 passed. That is 105 in the main suite, 41 converted audit
  regression tests in `test/audit/` and the fork suite. 1 test is skipped.
- `cargo test`: 101 passed; clippy clean.
- **E2E:** all 8 stages pass on an anvil fork of Base, which now runs 2 s blocks like
  Base.
  - Stage 5 took longer than before: the reference has to settle after the jump.
  - Stage 7: 47 reference-lag refusals and 8 pokes, then recovery with no further
    swaps.
  - Stage 8: the idle balance went from 1.6e16 to 9.5e12 through a same-range
    redeploy.
  - Two E2E-only changes: the anvil block time, and stage 5's window, which goes
    from 90 s to 240 s.
- **Deploy script:** checked on a plain local anvil. With the owner unset, the
  hook is configured and enforced. With a separate `HOOK_OWNER` it is configured
  and enforced too, with the handover pending; before the fix that case shipped
  unconfigured. A keystore or hardware-wallet signer was **not** exercised.


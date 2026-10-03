# Tend / AutopilotHook — Remediation Audit

**Target**: the ~300 lines added to `contracts/src/AutopilotHook.sol` fixing the
[2026-09-20 audit](../tend-2026-09-20/AUDIT-REPORT.md). Diff in `contract-changes.diff`.
**Date**: 2026-09-23
**Method**: three specialist agents scoped to the *new* surface — guards as an attack
surface, the new arithmetic, and the expanded privileged surface — briefed explicitly to
find what the fixes broke rather than re-report the original findings. Synthesis and
re-verification by hand.

> **The re-audit earned its keep.** Two of the seven fixes made something *worse* than the
> state they replaced, and one remediation claim in the previous report was simply false.
> Both are now fixed and the claim corrected.

---

## 1. The two regressions

### [REG-1] The value floor turned a cheap grief into a free one — HIGH

The HIGH-1 fix made the slippage floor protocol-enforced so a rebalancer could not waive
it. That was correct, and it created a new problem: `_guardValueLoss` rejects a rebalance
whose swap costs more than `maxRebalanceLossBps`, and the swap's cost is dominated by price
impact — *a function of pool depth at execution time, which any LP in the pool controls and
the hook does not*.

An LP holding the bulk of a pool's depth could remove it for one block, let the rebalance
revert, and re-add. Cost: gas. The reviewer measured the griefer's net at **+1.4e15 token0,
−1 wei token1** — they profited. Measured threshold: the guard tripped whenever external
active liquidity fell below roughly **1.5×** the position.

Worse, this was *worse than before the fix*: pre-fix, `minLiquidity = 0` — what every test
passes and what `Executor::execute` derives — would have let the call through. The
remediation converted "rebalances at a bad price" into "cannot rebalance at all", and the
position sits out of range earning nothing, which is the exact outcome the product exists
to prevent.

**Fix**: bound the swap's price impact *up front* rather than rejecting it afterwards.
`_swapPriceLimit` now takes whichever is tighter — the target-range boundary or a
`maxSwapImpactBps` deviation from spot. A thin pool now yields a smaller partial fill
instead of a revert. The value guard remains as a backstop for genuine anomalies.

**Verified**: `test_liquidity_pull_does_not_brick_an_out_of_range_rebalance` reproduces the
scenario (griefer holds 4e18 of 5e18 depth, pulls it in the rebalance's block). With the
bound disabled the rebalance reverts and the position is stranded; with it, the rebalance
succeeds.

### [REG-2] The price limit made partial fills the normal outcome, silently — MEDIUM

For a target range entirely on one side of spot, `_swapPriceLimit` returns the *near* edge,
so the swap stops the instant price reaches it with most of the input unspent. The unswapped
remainder is returned to the owner as loose ERC-20 and the position is rebuilt with roughly
half the capital.

Measured with the hook as sole LP: **4850 bps** of the freed value landed outside the
position. Neither guard notices — `newLiquidity` went *up* (1.03e18 vs 1e18, because the new
range is narrower, exactly the HIGH-1 pathology the value guard was meant to replace), and
`_guardValueLoss` counts the loose tokens in `valueAfter` so total value is preserved.

The project's own regression test for that shape asserts only `tick < 887000`, so the strand
was invisible to it.

**Fix (partial)**: a `RebalanceResidual(positionId, amount0, amount1)` event now surfaces
what could not be deployed, so the daemon can see and act on it. A separate event rather
than extra fields on `Rebalanced`, so the indexer's existing signature keeps working.
**The underlying behaviour is unchanged** — the value still lands outside the position. This
is mitigation by visibility, not a fix, and is recorded as open below.

**Fixed in a follow-up — see §8.**

---

## 2. The false claim

§10 of the previous report stated, of C-5:

> "Adding a rebalancer globally no longer silently grants authority over positions that
> predate it."

**That was false.** `positionRebalancer` defaults to `address(0)`, which
`_requireRebalancerFor` treats as "any allowlisted rebalancer". A position whose owner never
sent the opt-in transaction is entirely unchanged by the fix, and nothing in `deposit()`
prompts them to. The reviewer demonstrated a freshly-allowlisted address rebalancing a
pre-existing position.

**Corrected** in the previous report, and improved here: a `deposit` overload now takes the
rebalancer scope, so consent can be expressed atomically at open time rather than in a
follow-up transaction the user has to know to send. The six-argument form keeps its previous
meaning.

---

## 3. Other findings fixed

| ID | Severity | Issue | Fix |
|---|---|---|---|
| M-1 | Medium | `_swapPriceLimit` could return exactly `MIN`/`MAX_SQRT_PRICE`, which v4 rejects with `PriceLimitOutOfBounds`. Reachable for tick spacings **1, 2, 4, 8** — the only divisors of `MIN_TICK = 887272` in range — because `minUsableTick` then equals `MIN_TICK`. **A regression**: verified against the pre-fix blob, the same rebalance succeeded before. | Clamp into the open interval. Regression test fails without it with `PriceLimitOutOfBounds(4295128739)`. |
| A-3 | Medium | `_requireSequencerUp` made a bare external call to an owner-set address. A 1MB returndata bomb consumed **4.1M gas**; a no-code address bricked all rebalancing. | Gas-bounded `staticcall` with a length check, failing **open** — the alternative hands whoever controls that address a protocol-wide kill switch. Plus an `extcodesize` check at set time. |
| A-6 | Low | `setAllowedPair` hashed currencies in the order given while `deposit` always looks them up sorted, so a wrong-order call allowlisted nothing and emitted a success event. A mitigation that looks deployed and isn't. | `_pairKey` sorts. |
| L-2 | Low | `_guardValueLoss` multiplied before comparing; `valueBefore` scales with the *square* of `sqrtPriceX96` and can overflow at extreme prices. | `FullMath.mulDiv`. |
| L-3 | Low | `_settleExact` diffed the PoolManager's *global* balance. A decrease underflowed into a bare `Panic(0x11)` — worse diagnostics than the `CurrencyNotSettled` it was written to replace — and any unrelated inbound transfer masked a real shortfall. | Take the credited amount from `settle()`'s return value. Also drops two `balanceOf` calls. |
| R-5 | Medium | `setMaxRebalanceLossBps` had no *lower* bound. Setting it to 0 makes every rebalance revert, since any swap pays a fee — an off-switch wearing the costume of a safety parameter. | Floored at `MIN_LOSS_TOLERANCE_BPS = 25`. |
| R-7 | Low | `PriceRef.updatedAt` was `uint32` (overflows 2106). | Widened to `uint40`; the struct had 24 spare bytes. |

`viaIR` was enabled in `foundry.toml`. The contract had hit "stack too deep" four times as
guards accumulated, and extracting a helper each time was contorting the code to suit the
legacy codegen's stack limit rather than to be readable.

---

## 4. Confirmed genuinely closed

Re-verified rather than assumed:

- **CRIT-2** — deployed through the real CREATE2 path on anvil: `owner()` is the deployer,
  not the factory, and **all six** owner-only setters execute successfully. See
  `VERIFICATION-NOTES.md`. This mattered beyond the finding itself: the remediation added
  six admin functions that would all have been dead code under the old constructor.
- **CRIT-1** — across every branch the swap's limit is a boundary of the target range;
  measured `tick after = 600` for target `[600,1200]` and `-600` for `[-1200,-600]`, with
  the hook as sole LP. No remaining path moves price past the target range.
- **HIGH-1** — the tolerance is read from contract storage and is genuinely not waivable by
  the rebalancer. At the 25 bps floor on a 1% fee tier it rejects; at 500 bps it permits.
- **HIGH-3** — `asClaims=true` mints ERC-6909 on both currencies with no token call, so a
  blacklisted owner can exit. Confirmed empirically.
- **Exit survives every blocked state.** `withdraw()` carries no pause, cooldown, sequencer
  or price check. Confirmed working with the contract paused *and* the price guard blocking
  rebalances simultaneously. This is what keeps REG-1 and the reference findings out of
  Critical.
- **`_afterSwap` remains O(1) and revert-free.** The only added arithmetic is `ref.tick ± cap`
  on values bounded by ±887272 — well inside `int24`.
- **The hook's own swap does not pollute its own reference.** v4's self-call guard means
  `_afterSwap`, and therefore `_updatePriceRef`, never fires for the rebalance swap.
- **Storage layout** — three new mappings and a struct, no aliasing; `PriceRef` packs into
  one slot; OZ's `ReentrancyGuard` uses an ERC-7201 namespaced slot so it cannot collide.
- **`AUTOMATION_OFF = address(1)`** is a safe sentinel — the `ecrecover` precompile, no code,
  cannot originate a transaction — and the ordering in `_requireRebalancerFor` checks the
  sentinel before the equality, so even allowlisting `address(1)` yields `AutomationDisabled`
  rather than authority.

---

## 5. Still open

Recorded rather than fixed, with the reason.

- **REG-2 (residual strand)** — fixed in a follow-up; see §8.
- **R-2 / R-3 / A-4 — fixed in a follow-up redesign; see §7.** One gap remains, and it
  is in the daemon, not the contract — described there.
- **R-6 (boundary equality)** — fixed; see §9.
- **A-1 / A-5 (owner powers, no timelock)** — fixed; see §10.
- **A-9** — fixed; see §9. The figure recorded here (137 bps) understated it ten-fold.

## 6. What the reviewers could not measure

Stated so the gaps are not mistaken for clean results:

- The cost of the R-3 reference walk at a realistic position-to-pool depth ratio. Measured
  only at ~1000× depth, where it is economically irrational, and a cheaper single-block
  variant at 10× depth (~16% of position value per attempt).
- Whether the REG-1 grief can be mounted without already holding a majority of the pool's
  active liquidity.
- Whether R-6's boundary equality can be steered into a bad *fill* rather than a revert.

---

## 7. Follow-up: price-reference lifecycle redesign

R-2, R-3 and A-4 share a root: the reference's lifecycle had accreted rather than been
designed. Fixed together rather than patched individually.

| Defect | Old behaviour | Now |
|---|---|---|
| R-2(a) seeding | Seeded by the first swap after a pool's first deposit, so whoever landed that swap chose the anchor | Seeded from spot **inside the depositor's own transaction** when a pool goes from 0 to 1 position |
| R-2(b) fossil | Frozen while a pool had no positions, then trusted by the next depositor | Reseeded on every 0 → 1 transition |
| R-2(c) no convergence | After one large move on a pool that then went quiet, nothing ever pulled the reference back; rebalancing stayed blocked with no deadline | Permissionless `pokePriceRef()` advances one capped step per block |
| R-3 free walk | First write per second won, so displace → update → restore in one block moved the reference a full step at no cross-block risk | **Last write per block wins**, clamped to the block-start anchor. A same-block round trip ends the block with the reference back home |
| — | Deviation checked against the intra-block value, which a front-run earlier in the same block could itself have moved | Checked against the **block-start anchor** |
| A-7 | Guard skipped entirely while unseeded | Seeding is guaranteed at first deposit, so unseeded is an invariant break — fails closed |

**Why there is no separate freshness check (A-4).** In v4 a pool's spot price moves only
through swaps in that pool, and every such swap updates the reference. So the reference
can only go stale in two ways: the count-0 freeze (now reseeded) and lag after a large
move (now pokeable). A timestamp check would add a third mechanism for a failure mode the
other two already cover. Time-scaling the per-block cap was considered and rejected: on a
quiet pool it would let an attacker who holds a displaced price across a *single* block
boundary set the reference in one step.

**Poke gives an attacker nothing.** It applies the same clamp as a swap and is rate-limited
to one step per block, so anything it does, a dust swap could already do.

**Verified against the old semantics**, not just reasoned: restoring first-write-wins and
the intra-block comparison inside the new struct makes the R-3 tests fail with exactly
the defects they target —

    [FAIL: a restored price must leave the reference where it was: -500 != 0]
    [FAIL: next call did not revert as expected]   (a 2400-tick front-run passed)

**Cost.** Last-writer-wins means every swap in a pool holding autopilot positions now
writes the reference slot, where previously only the first per second did — roughly
+2.9k gas for each swap after the first in a block (EVM-derived, not measured). The write
is skipped when it would change nothing, which is common once spot sits past the cap.
Pools with no autopilot positions remain untouched.

### A test-harness trap found on the way

Under `via_ir`, repeated reads of `block.number` inside one test function are folded, so
`vm.roll(block.number + 1)` in a loop rolls to the *same* block every iteration. Three of
the new tests initially failed for that reason alone. The tests now read the block number
through the `vm.getBlockNumber()` cheatcode. Every existing test was checked: none rolls or
warps more than once in a single function, so none was silently hollowed out.

### Remaining gap: the daemon does not poke — CLOSED

Closing it exposed a wider daemon bug. The watch loop proposed a rebalance only on the
in → out-of-range **transition**, so any first attempt refused for any reason — price
deviation, cooldown, spend cap, stale ETH price — was never retried unless price re-entered
the range and left again. A position deposited out of range was never managed at all,
because it never had a transition.

Fixed in the daemon:

- **Periodic sweep** over every out-of-range position (auto-execute mode only), so a
  refused rebalance is retried until it succeeds or the strategy declines it. First
  shipped hung off the WS heartbeat, which only fires after 30 s of silence, so on a
  pool that swaps more often than that it never ran. It now has its own fixed timer
  (`LPA_SWEEP_SECS`, default 30); see §8.
- **Refused preflights no longer consume the per-position throttle.** A failed `eth_call`
  costs nothing; only a sent transaction starts the interval. Previously one refusal
  suppressed retries for five minutes.
- **`PriceDeviation` triggers a poke**, recognised by selector `0x1782bd94`, throttled per
  pool *before* anything is spent, and priced against the same fresh-ETH spend cap as a
  rebalance.

Proven end to end: E2E stage 7 makes one large one-block move on a forked Base pool and
then stops swapping. Result — 15 preflight refusals citing `PriceDeviation`, 8 pokes, then
a successful rebalance, with no further swaps.

**The old E2E was passing because of the bug.** In stage 4 the position rebalanced once,
left that range again as price kept falling, had its next attempt refused by the cooldown,
and was abandoned. Stage 6 only checked that the range moved, and it had moved once. With
the sweep the position follows price across cooldown windows. Stage 6 reads the range at
one instant while that is still happening, so the range it prints depends on timing
(`[-900, -720]` and `[-4680, -1260]` have both been observed). Its invariants, that the
range moved and that the daemon's DB agrees with the chain, hold either way.

**Behaviour change to note.** Positions opened *deliberately* out of range — a range order
placed above or below spot — are now rebalanced toward spot like any other out-of-range
position, where before they were left alone by accident. The opt-out already exists:
deposit with `rebalancer = AUTOMATION_OFF`, or call `setPositionRebalancer` afterwards.

## 8. REG-2 fixed: the undeployable remainder stays with the position

The two options recorded in §5 were both wrong on inspection:

- **Revert above a residual threshold.** Measured first: ordinary rebalances leave
  3–28 bps behind, and the one-sided and thin-pool shapes leave 50–96%. A threshold between
  those reverts exactly the thin-pool case, which is **REG-1 again**: any LP able to thin
  the pool for a block could block rebalances for free.
  `test_liquidity_pull_does_not_brick_an_out_of_range_rebalance` fails under it.
- **Shift the range to what is deployable.** That substitutes the contract's choice of
  range for the rebalancer's, and still leaves the remainder of an unfillable swap.

**What shipped instead.** The remainder is never paid out mid-rebalance. It is held for the
position as ERC-6909 claims on the PoolManager (`idle[positionId]`), backed 1:1 by the
hook's claim balance. The next rebalance burns the claims and folds them into the freed
amounts, and `withdraw` pays them out. A rebalance onto the position's *current* range,
which is otherwise `NoOpRebalance`, is accepted when something is idle, because that is how
an idle balance gets placed. `RebalanceResidual` now reports the idle balance after the
rebalance.

**A sizing flaw it exposed.** The re-ratio swap is sized at the pre-swap price. Its own impact
moves price the way that makes the range want more of what was just sold, so it tends to
overshoot. At the extreme, from spot exactly on a range edge, it sold everything, price moved
inside, and the side the range now needed was empty: `ZeroLiquidity`. A second leg,
re-sized at the post-swap price, now corrects an overshoot. It runs only in the reverse
direction and is clamped at the starting price, so it cannot widen the impact bound. For a
position whose price has left its range, the residual went from **28 bps to 0.04 bps**. The
other measured shapes are unchanged at 3–9 bps: they undershoot, because of the fee, and
the remainder goes to the idle balance.

**Daemon.** A sweep reads `idle()` for in-range positions and queues a same-range rebalance
when the idle share is at least `LPA_IDLE_REDEPLOY_BPS` (default 100). In a pool with no
other depth a redeploy fills nothing and would repeat forever, so each retry that finds the
share not at least 10% lower doubles its wait (base 10 min, capped at a day).

**Verified.**
- `test_undeployable_remainder_stays_with_position`: the owner's balances are unchanged,
  and the idle record equals the hook's claim balance.
- `test_withdraw_pays_out_idle_balance`: all idle funds are returned and no claims are left.
- `test_idle_balance_redeployed_when_depth_returns`: liquidity rises and less than 5% stays
  idle. It fails with `ZeroLiquidity` if the corrective leg is removed.
- `test_same_range_rebalance_is_still_a_noop_without_idle`.
- The E2E now runs with the WS heartbeat disabled, so stage 7's recovery depends only on the
  sweep's own timer.

**End to end (E2E stage 8).** The stage pulls the background book and caps swap impact at
1 bps, then rebalances onto a reshaped range. That leaves 2.07e16 idle, against 9.4e13 of
dust before. It then restores depth and the impact bound and leaves the rest to the
daemon. The daemon queued 4 redeploys (the first ones are refused by the hook's cooldown,
which the backoff absorbs). Idle fell to 9.3e12 with the range unchanged, so the balance
was placed by a same-range redeploy, not a range change.

**Two E2E false failures, recorded so they are not re-investigated.** macOS idle sleep froze
anvil and the daemon mid-stage; the power log's sleep window matched the silent gap in the
daemon log to the second. The script now holds a `caffeinate` assertion while it runs.
Separately, stage 5 could pick up the sweep's rebalance of the offline-deposited position
first; it now waits for the position stage 6 inspects.

## 9. R-6 and A-9: two losses the value guard cannot see

> **Superseded by the 2026-10-03 re-audit (`audits/tend-2026-10-03/AUDIT-REPORT.md`).** The 78 bps
> "worst case" below measured only centred ranges. Out-of-range and one-sided positions lose 117–195
> bps at the same bound (PR-2, X-1). A held block boundary admits pushes of 700 ticks (PR-1, High).
> The 50 bps impact default causes DS-1. A-9 and R-6 are **not** closed.

Both findings share a cause. The value guard measures a rebalance at the price it sees
during the rebalance. These two losses happen at a price the guard never measures:
afterwards, or a price an attacker set before it.

### R-6 — the empty-book walk

Re-measured before any change (`test_r6_*`, spot placed exactly on a target edge):

- **Deep pool.** The equality case reverted with `ZeroLiquidity`, reproduced against the
  pre-§8 contract. This was the "unnecessary revert" recorded above. The §8 corrective leg
  had already fixed it: price now moves at most one tick.
- **Hook as sole LP.** The swap walks price through an empty book to the far edge of the
  target. **This is not specific to equality**: any straddle rebalance in an empty book does
  it, limited only by the range width and `maxSwapImpactBps`. The rebalance itself looks
  free, because nothing fills. The cost comes afterwards, when arbitrage pulls price back
  to fair through the newly placed position.
  `test_r6_empty_book_walk_cost_is_bounded` measures it end to end: **133 bps** at the
  old 1000 bps impact default, above the 1% tolerance.

**Fix:** the default `maxSwapImpactBps` is now 50, which is about 1% of price. That
default was set loose for REG-1, when a bounded swap meant a revert. Since §8 the unfilled
part is held as idle funds, so a tight bound now costs only some temporary idle capital.
Walk loss: **2 bps**. All 94 other tests pass unchanged.

### A-9 — rebalancing onto a pushed price

`test_a9_rebalance_at_manipulated_price`: an attacker pushes spot just inside the
deviation bound. The rebalance lands at that price with the new range centred on it, as
the daemon would. The attacker swaps back. The loss is measured against a control that
takes the same push and swap-back without the rebalance.

| push (ticks) | 90 | 190 | 490 | 990 | 1990 |
|---|---|---|---|---|---|
| loss (bps), ±1200 range | 6 | 28 | 162 | 533 | **1428** |

The old 2000-tick bound admitted a **14%** loss. The value guard measures both sides at the
pushed price, so it saw a fair trade. The loss also depends on range width. At the narrowest
range the daemon picks (one tick spacing either side) it is 78 bps at 200 ticks, and over
1% at every looser bound tried (113–159 bps at 250–350 ticks).

**Fix:** `MAX_DEVIATION_TICKS` is now 200, as both the default and the cap, so the owner can
only tighten it. The worst measured case is 78 bps, inside the 1% tolerance. Measuring the
value guard at the reference price instead was rejected: most of the loss is the range
placement, not the swap, and the guard only sees the swap.

**Cost to honest rebalances:** after a fast move, a rebalance is refused until the
reference catches up. The daemon pokes it toward spot at 500 ticks a block, so the cost is a
delay of a few blocks. Six tests that rebalanced straight after a large one-block move now
take that catch-up first (`_catchUpRef`). The daemon's refusal log now dedupes on the
error selector. Keying on the full reason, which contains the changing ticks, had logged
every retry.

## 10. A-1 / A-5: loosening owner changes wait out a timelock

Every setter that **loosens** a protection now needs `queueChange(call)`, then a 2-day wait
(`TIMELOCK_DELAY`), then `executeChange(call)` within the next 14 days (`TIMELOCK_GRACE`).
After that the queued change lapses. Calling one of these setters directly reverts with
`ChangeMustBeQueued`. A depositor who disagrees with a queued change sees `ChangeQueued` two
days ahead and can withdraw, which is never gated.

| Setter | Waits when |
|---|---|
| `setRebalancer` | adding an address (the owner appointing themselves was the A-5 path) |
| `setMaxRebalanceLossBps` | raising it (the 100 → 500 bps change measured ~26× extractable value) |
| `setMaxSwapImpactBps` | raising it |
| `setPriceGuard` | raising either bound |
| `setMinRebalanceInterval` | shortening it |
| `setSequencerUptimeFeed` | replacing or removing an existing feed (adding one where there was none only adds a check) |

**Still instant:**
- **Tightening, and removing a rebalancer.** The worst a tightening can do is stop
  rebalancing, and positions can always be withdrawn. It is also the emergency lever.
- **`pause` / `unpause`**, for the same reason.
- **The pair allowlist.** It gates `deposit` only, so an existing position is never affected.

**The self-call is restricted.** `executeChange` calls the hook as itself, so `queueChange`
accepts only those six selectors. A queued `withdraw` or anything else that moves funds is
rejected with `NotTimelockable`. The self-call still runs the setter's own argument
validation, so an out-of-bounds queued value reverts when executed.

**Verified:** 8 new tests cover direct loosening reverting, tightening staying instant, the
execution window (early, inside, expired), cancel, owner-only queueing, the selector
restriction, argument validation at execution, and the feed add-vs-replace rule. The 6
existing tests that loosened a parameter directly now go through `_queued`.

**What a timelock does not do:** an owner who waits out the delay still gets the change.
The protection is warning time for depositors, not a veto. Ownership should sit with a
multisig. That is an operational choice, and the contract cannot enforce it.

## 11. T-3: rebasing tokens

This is unchanged and cannot be fixed in the hook. v4's PoolManager does not track rebases,
so rebasing balances desync its reserves for every pool, not just this hook's. The
mitigation is the pair allowlist, which ships disabled. The deploy script now enables it and
allowlists the deployment's intended pair, so a production deployment refuses unlisted
tokens from its first block.


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

- **REG-2 (residual strand)** — now visible via `RebalanceResidual`, but the value still
  lands outside the position. Properly fixing it means either shifting the redeposit range
  to what is actually deployable at the post-swap price, or reverting when the undeployed
  fraction exceeds a threshold. Both are behavioural changes that deserve their own design
  pass rather than being bolted on during a remediation round.
- **R-2 / R-3 / A-4 — fixed in a follow-up redesign; see §7.** One gap remains, and it
  is in the daemon, not the contract — described there.
- **R-6 (boundary equality)** — LOW. At `spot == sqrtA` / `spot == sqrtB` the limit selects
  the *far* edge, letting the swap traverse the whole range. Absorbed by the value guard in
  every configuration tested, so it manifests as an unnecessary revert rather than a bad fill.
- **A-1 / A-5 (owner powers, no timelock)** — MEDIUM. Six instant-effect setters, each an
  independent `rebalance()` kill switch. Raising `maxRebalanceLossBps` from 100 to 500 was
  measured to multiply extractable value ~26× (0.44% → 11.4% of a position over 40 minutes),
  and the owner can appoint themselves rebalancer, so no collusion is needed. Still strictly
  better than pre-fix, which was unbounded in a single transaction. A timelock is the answer
  and is a governance change, not a contract patch.
- **A-9** — the value guard bounds the swap's own cost, not pre-existing manipulation, since
  both measurements use the same pre-swap price. The effective bound on manipulation loss is
  `maxDeviationTicks` (2000 ticks ≈ **22%**), not the 1% value floor. Measured: a 1990-tick
  push, inside the deviation bound, produced a **137 bps** real loss against a 100 bps
  configured tolerance. Measuring against `priceRef` instead would make the two guards
  multiply rather than compose.

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

### Remaining gap: the daemon does not poke

The contract now gives a stuck position a bounded way out, but **nothing calls it**. The
daemon only attempts a rebalance when a swap event arrives — and the quiet-pool case is
precisely the one where no swap events arrive. In production today, R-2(c) is fixed only
if the position owner or someone else calls `pokePriceRef` by hand. Closing it properly
needs the daemon to sweep blocked out-of-range positions on its heartbeat, poking and
retrying. That is a daemon change and is the next item.

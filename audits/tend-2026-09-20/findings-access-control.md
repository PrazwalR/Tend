# Access Control Findings — AutopilotHook

**Scope**: `contracts/src/AutopilotHook.sol`
**Checklist**: evm-audit-access-control
**Date**: 2026-09-20

## Summary

Every external entry point on `AutopilotHook` carries the modifier set it should: `deposit` is `whenNotPaused nonReentrant`, `withdraw` is `nonReentrant` with an in-body owner check and is deliberately *not* pausable, `rebalance` is `whenNotPaused nonReentrant` behind the `isRebalancer` allowlist, `unlockCallback` is gated on `msg.sender == address(poolManager)` and is unreachable with foreign calldata (v4's `PoolManager.unlock` only ever calls back its own `msg.sender`), `_afterSwap` is reached only through `BaseHook.afterSwap`'s `onlyPoolManager`, and the four admin setters are `onlyOwner` on a correct `Ownable2Step`. There is no rescue/sweep/`transferFrom` function, so the owner cannot touch user tokens directly. The tick envelope (`boundLower`/`boundUpper`) is written exactly once in `deposit` (lines 158-159), has no setter, and is checked on `rebalance` (line 240) — the only path that can move a position. On the narrow question "are modifiers missing", the contract is clean.

The trust model still does not hold. The envelope bounds *where* a position may sit but not *what a rebalance does to it*: the internal re-ratio swap runs with `sqrtPriceLimitX96` set to the extremes (no price limit at all), the only value floor is `minLiquidity` — a parameter the rebalancer chooses for itself and may set to `0` — and nothing forbids rebalancing a position to the range it is already in. A rebalancer key alone therefore bleeds roughly the pool fee per cycle out of any position it touches while never leaving the envelope and never calling `withdraw`. Three supporting defects compound it: `lastRebalanceAt` is initialised to `0`, so on any real chain (`block.timestamp ≈ 1.75e9` vs a maximum interval of `31_536_000`) the first rebalance of every position is callable in the same block as the deposit regardless of the configured cooldown; `minRebalanceInterval` is a single global with no minimum and no timelock, and at `0` the per-cycle bleed becomes a single-transaction drain (measured: 59% of a position's value destroyed in one tx); and users cannot choose, restrict, or revoke which rebalancer has authority over their position.

## Findings by severity

| ID | Severity | Title |
|----|----------|-------|
| H-1 | High | Rebalancer's only value floor is a parameter the rebalancer chooses; unlimited-price internal swap lets it bleed any position inside the envelope |
| M-1 | Medium | The tick envelope constrains position *location* but not the rebalance action — same-range rebalances are permitted |
| M-2 | Medium | `lastRebalanceAt` initialised to `0` — the first rebalance of every position bypasses the cooldown entirely on any live chain |
| M-3 | Medium | `minRebalanceInterval` is global, retroactive, has no floor and no timelock; at `0` the H-1 bleed becomes a single-transaction drain |
| M-4 | Medium | Position owners cannot choose or revoke their rebalancer; `setRebalancer` instantly grants authority over every existing position |
| L-1 | Low | Position owner cannot rebalance their own position; pause or rebalancer loss freezes positions with only full exit as recourse |
| L-2 | Low | Off-chain executor derives `minLiquidity` from a simulation of the same state, so the floor is self-referential |
| L-3 | Low | `renounceOwnership()` override keeps a redundant `onlyOwner`, giving non-owners a misleading revert |
| I-1 | Info | `boundLower`/`boundUpper` are never cleared on withdraw |
| I-2 | Info | The hook re-enters itself through `_afterSwap` during `_swapToRatio` |
| I-3 | Info | Verified-correct access control (positive findings) |

**Counts**: Critical 0 · High 1 · Medium 4 · Low 3 · Info 3

## VERDICT on the "trusted but bounded" claim

**REFUTED.**

The claim — *"The rebalancer key is trusted but BOUNDED: it can only reposition a position within the owner-set tick envelope and cannot withdraw funds. Cooldown, pause, and the slippage floor are the safety valves."* — fails on three of its four load-bearing clauses.

- *"can only reposition within the envelope"* — true as stated, and the envelope is genuinely immutable after deposit. But repositioning is not the only thing a rebalance does: it removes all liquidity, market-swaps the proceeds with no price limit, and re-adds. The envelope does not bound that swap, and a same-range rebalance is legal, so the envelope constrains nothing that matters (M-1).
- *"cannot withdraw funds"* — true in the literal sense that `withdraw` is owner-gated. False in the sense that matters: a rebalancer alone destroys ~0.3% of a position's value per cycle (measured 5.7% over 20 cycles), and the value lands with the pool's other LPs — a role the attacker can occupy. Funds leave the user without `withdraw` ever being called (H-1).
- *"cooldown … is a safety valve"* — false for the first rebalance of every position on any live chain (M-2), and the valve is a single global the owner can set to `0` instantly and retroactively, at which point the bleed becomes a 59%-in-one-transaction drain (M-3).
- *"pause is a safety valve"* — **true, and correctly implemented.** `withdraw` is genuinely not pausable; funds cannot be trapped. This is the one safety valve that works as advertised.
- *"the slippage floor is a safety valve"* — false. `minLiquidity` is supplied by the rebalancer, so the party being constrained controls its own constraint (H-1). Even the honest off-chain executor's floor is derived from a simulation of the same state (L-2).

The accurate statement of the current trust model is: **the rebalancer key is fully trusted with the value of every position in the contract, and is bounded only in that it cannot choose the recipient of a withdrawal.**

---

## [C-1] Rebalancer's only value floor is a parameter the rebalancer chooses; unlimited-price internal swap lets it bleed any position inside the envelope

**Severity**: High
**Category**: access-control
**Location**: `rebalance()` (AutopilotHook.sol:225-269), `_doRebalance()` (AutopilotHook.sol:355), `_swapToRatio()` (AutopilotHook.sol:425-433)

**Description**: `rebalance` takes `minLiquidity` from `msg.sender`, and `msg.sender` must be an allowlisted rebalancer. The check at line 355 — `if (newLiquidity < cb.minLiquidity) revert SlippageExceeded(newLiquidity, cb.minLiquidity);` — is therefore a constraint the constrained party writes for itself. Passing `0` disables it, and the contract has no independent notion of the position's value: no TWAP, no oracle, no comparison against `oldLiquidity`, no bound on the swap's price impact.

The mechanism this unlocks is `_swapToRatio`, which market-swaps the freed tokens through `poolManager.swap` with `sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1` (line 430) — no price limit whatsoever. When the target range sits entirely on one side of spot (lines 392-399), `amountIn` is set to the position's *entire* `have0` or `have1`, so 100% of the user's holdings are pushed through the pool as a single unlimited market order. Every such cycle pays the pool's LP fee (0.3% on the `fee: 3000` pools the deploy scripts use) plus price impact. Both go to the pool's other LPs — a role the rebalancer can occupy by JIT-minting a concentrated position around spot immediately before the call, converting value destruction into direct value capture. The rebalancer can also sandwich its own call: push the price, force the position to re-ratio at the manipulated price with `minLiquidity = 0`, push the price back.

None of this requires leaving the envelope or calling `withdraw`. The in-code comment at lines 379-383 states the design assumption explicitly — *"the caller's `minLiquidity` floor is what actually bounds an adverse fill"* — which is precisely the assumption that does not hold when the caller is the adversary.

**Proof of Concept**: Reproduced with Foundry against the unmodified contract. Pool `fee = 3000`, `tickSpacing = 60`, background liquidity `5e20` over `[-60000, 60000]`, cooldown left at the deployed 1 hour.

1. Victim calls `hook.deposit(key, -600, 600, 1e18, -1800, 1800)` — a deliberately **narrow** envelope, roughly ±20% around spot, i.e. a careful user.
2. Baseline control: deposit then immediately `withdraw` returns `29_553_010_879_137_169` of each token (≈0.0591 units of combined value at the 1:1 price).
3. Attack: the rebalancer calls 20 times with one hour between calls (cooldown fully respected), alternating two ranges **strictly inside the envelope**, floor disabled: `hook.rebalance(pid, 600, 1800, 0)` on even iterations, `hook.rebalance(pid, -1800, -600, 0)` on odd. Both pass `_validateTicks` and both satisfy `newTickLower >= boundLower && newTickUpper <= boundUpper`.
4. Victim withdraws: receives `0` token0 and `55_741_217_450_451_261` token1 — ≈0.0557 against the 0.0591 baseline. **A 5.7% loss over 20 cycles (~0.29% per cycle, i.e. exactly the pool fee), in under a day, entirely inside the envelope, with `withdraw` never called by the attacker.** At a 1-hour cooldown this is ~6.8%/day indefinitely, against every position simultaneously. The attacker captures the bled value by being the counterparty LP.

**Recommendation**: Three independent fixes; apply all three.

1. Make the value floor protocol-enforced rather than caller-supplied:

```solidity
uint16 public maxRebalanceLossBps;      // owner-set, e.g. 50 = 0.5%
uint16 public constant MAX_LOSS_CAP_BPS = 200;

function setMaxRebalanceLossBps(uint16 bps) external onlyOwner {
    if (bps > MAX_LOSS_CAP_BPS) revert LossCapTooHigh();
    maxRebalanceLossBps = bps;
    emit MaxRebalanceLossBpsSet(bps);
}

// in _doRebalance, replace the caller-only floor:
uint128 protocolFloor = uint128((uint256(cb.liquidity) * (10_000 - maxRebalanceLossBps)) / 10_000);
uint128 floor = cb.minLiquidity > protocolFloor ? cb.minLiquidity : protocolFloor;
if (newLiquidity < floor) revert SlippageExceeded(newLiquidity, floor);
```

This compares liquidity across two different ranges, so it is only a first-order guard; a value-denominated comparison (freed amounts valued at a TWAP, before vs after) is stronger and worth the extra code.

2. Bound the internal swap's price impact — replace the unlimited `sqrtPriceLimitX96` with a limit derived from the pre-swap price and an owner-set tolerance, so a manipulated pool reverts rather than fills:

```solidity
uint160 limit = zeroForOne
    ? uint160((uint256(sqrtPriceX96) * (10_000 - maxSwapImpactBps)) / 10_000)
    : uint160((uint256(sqrtPriceX96) * (10_000 + maxSwapImpactBps)) / 10_000);
```

3. Compare `poolManager.getSlot0` spot against a short TWAP at the top of `_doRebalance` and revert beyond a threshold. This kills the sandwich variant outright.

---

## [C-2] The tick envelope constrains position *location* but not the rebalance action — same-range rebalances are permitted

**Severity**: Medium
**Category**: access-control
**Location**: `rebalance()` (AutopilotHook.sol:239-240)

**Description**: The envelope check is `_validateTicks(key, newTickLower, newTickUpper);` followed by `if (newTickLower < boundLower[positionId] || newTickUpper > boundUpper[positionId]) revert OutOfBounds();`. There is no check that the new range differs from the current one, no check that the move is *useful* (e.g. that the position is actually out of range), and no limit on how many legal targets exist inside an envelope.

A user who sets the tightest envelope the contract permits — `minBound == tickLower`, `maxBound == tickUpper`, so the only legal target is the range already occupied — still cannot stop a rebalancer cycling the position through remove → unlimited market swap → re-add on every cooldown expiry, paying the fee each time. This is the specific reason "bounded" does not survive contact with the code: the envelope is a bound on *state*, while the value leak is in the *transition*.

**Proof of Concept**:

1. Victim picks the strictest possible envelope: `hook.deposit(key, -600, 600, 1e18, -600, 600)`. `_validateTicks(key, -600, 600)` passes.
2. Rebalancer calls `hook.rebalance(pid, -600, 600, 0)` — **the identical range** — once per cooldown. It succeeds every time: `-600 < -600` is false and `600 > 600` is false, so `OutOfBounds` does not fire and nothing else objects.
3. Measured over 5 cycles on a balanced position, liquidity drifts `1e18 → 999_999_999_999_999_841` (rounding dust only, because a straddling range needs almost no swap). Combine with H-1's one-sided targets — the realistic case, since the product exists to recentre a drifted position — and each cycle costs the full 0.3% pool fee on 100% of holdings. The tight envelope protects against neither.

**Recommendation**: Require that a rebalance actually moves the position, and make the envelope govern the transition:

```solidity
if (newTickLower == pos.tickLower && newTickUpper == pos.tickUpper) revert NoOpRebalance();
```

Better, require the rebalance to be *justified* — only permit it when price has actually left the current range, the stated purpose of the feature:

```solidity
(, int24 tick,,) = poolManager.getSlot0(key.toId());
if (tick >= pos.tickLower && tick < pos.tickUpper) revert PositionInRange();
```

Together these reduce the rebalancer's discretion from "unbounded churn" to "recentre a genuinely drifted position". Pair with H-1's protocol-enforced floor.

---

## [C-3] `lastRebalanceAt` initialised to `0` — the first rebalance of every position bypasses the cooldown entirely on any live chain

**Severity**: Medium (High when chained with H-1)
**Category**: access-control
**Location**: `deposit()` (AutopilotHook.sol:185), `rebalance()` (AutopilotHook.sol:235-236)

**Description**: `deposit` creates the position with `lastRebalanceAt: 0` (line 185). `rebalance` then computes `uint64 readyAt = pos.lastRebalanceAt + minRebalanceInterval; if (block.timestamp < readyAt) revert RebalanceTooSoon(readyAt);`. For a fresh position this is `readyAt = minRebalanceInterval`, an absolute Unix timestamp of at most `MAX_REBALANCE_INTERVAL = 365 days = 31_536_000`. Real chain timestamps are ~`1.75e9`. The comparison is therefore **always false on any live network**, and the first rebalance of every position is callable in the same block as the deposit no matter what cooldown the owner configured.

The existing test suite hides this: `test_rebalance_cooldown_enforced` passes only because Foundry's default `block.timestamp` is `1`, below the 3600-second cooldown — an artefact of the harness, not the contract. The test asserts a property the deployed contract does not have. Chained with H-1 this removes the one delay between a user's deposit and the first value-extracting rebalance.

**Proof of Concept**: Reproduced with Foundry, cooldown set to **7 days** at construction:

1. `vm.warp(1758300000)` — a realistic ~Sep 2026 block timestamp.
2. `hook.deposit(key, -600, 600, 1e18, minUsableTick, maxUsableTick)`.
3. In the **same block**, zero seconds elapsed: `vm.prank(rebalancer); hook.rebalance(pid, -1200, 1200, 0);`
4. Succeeds. `readyAt` evaluated to `604800`, and `1758300000 < 604800` is false. `lastRebalanceAt` is then set to the current timestamp, so the cooldown works from the *second* rebalance onward — the gap is exactly the first one, for every position ever created.

**Recommendation**: Stamp the deposit time so the first cooldown is measured from creation:

```solidity
positions[positionId] = Position({
    owner: msg.sender,
    key: key,
    tickLower: tickLower,
    tickUpper: tickUpper,
    liquidity: liquidity,
    active: true,
    lastRebalanceAt: uint64(block.timestamp)   // was: 0
});
```

Separately, fix the test so it cannot pass for the wrong reason — add `vm.warp(1_700_000_000)` to `setUp()` in `AutopilotHook.t.sol` and re-run every cooldown assertion under a realistic clock.

---

## [C-4] `minRebalanceInterval` is global, retroactive, has no floor and no timelock; at `0` the H-1 bleed becomes a single-transaction drain

**Severity**: Medium
**Category**: access-control
**Location**: `setMinRebalanceInterval()` (AutopilotHook.sol:467-471), `rebalance()` (AutopilotHook.sol:235-236)

**Description**: `minRebalanceInterval` is one `uint64` governing every position. `lastRebalanceAt` is per-position, so the *timer* is per-position, but the *interval* is global. `setMinRebalanceInterval` caps the value above (`MAX_REBALANCE_INTERVAL`) but imposes **no lower bound** — `0` is accepted — and takes effect in the same transaction, retroactively, for positions deposited long before under different assumptions. Users who deposited at a 24-hour cooldown get no notice, no opt-out, no chance to exit ahead of the change.

At `interval == 0` the guard reduces to `block.timestamp < block.timestamp`, which is false, so `rebalance` can be called repeatedly in a single transaction. `nonReentrant` does not prevent this: sequential external calls from an attacker contract each acquire and release the guard cleanly.

Per the stated severity rubric this is owner-reachable fund loss and so rated Medium, but its real-world impact is total loss of every position in the contract; a reviewer applying an impact-first rubric would rate it High.

**Proof of Concept**: Reproduced with Foundry. Hook deployed with a 1-hour cooldown; victim's envelope the narrow `[-1800, 1800]`.

1. Victim: `hook.deposit(key, -600, 600, 1e18, -1800, 1800)`. Recorded liquidity `1e18`.
2. Owner: `hook.setMinRebalanceInterval(0)` — instant, no timelock, no floor, one transaction.
3. Rebalancer, in **one transaction**, loops 300 times alternating two in-envelope ranges with the floor disabled:

```solidity
for (uint i; i < 300; ++i)
    hook.rebalance(pid, i % 2 == 0 ? int24(600) : int24(-1800),
                        i % 2 == 0 ? int24(1800) : int24(-600), 0);
```

4. Stored liquidity falls `1_000_000_000_000_000_000 → 425_300_820_386_404_573`. The victim then withdraws and recovers `0` token0 and `24_034_468_724_138_743` token1 — against the `29_553_010_879_137_169` **of each token** a clean round-trip returns. **≈59% of the position destroyed in a single transaction**, inside the envelope, with `withdraw` never called by the attacker.
5. Gas was 48.9M for 300 iterations (~163k each), so one mainnet block accommodates ~180; the remainder trivially spills into the next transaction since the cooldown is `0`.

**Recommendation**: Impose a floor, and make reductions take effect only after a delay:

```solidity
uint64 public constant MIN_REBALANCE_INTERVAL_FLOOR = 15 minutes;
uint64 public constant INTERVAL_REDUCTION_DELAY     = 2 days;

uint64 public pendingInterval;
uint64 public pendingIntervalReadyAt;

function setMinRebalanceInterval(uint64 interval) external onlyOwner {
    if (interval > MAX_REBALANCE_INTERVAL) revert IntervalTooLong();
    if (interval < MIN_REBALANCE_INTERVAL_FLOOR) revert IntervalTooShort();
    if (interval >= minRebalanceInterval) {
        minRebalanceInterval = interval;          // raising is safer: apply immediately
        emit MinRebalanceIntervalSet(interval);
    } else {
        pendingInterval = interval;
        pendingIntervalReadyAt = uint64(block.timestamp) + INTERVAL_REDUCTION_DELAY;
        emit MinRebalanceIntervalPending(interval, pendingIntervalReadyAt);
    }
}

function applyPendingInterval() external {
    if (pendingIntervalReadyAt == 0 || block.timestamp < pendingIntervalReadyAt) revert TooSoon();
    minRebalanceInterval = pendingInterval;
    emit MinRebalanceIntervalSet(pendingInterval);
    delete pendingInterval;
    delete pendingIntervalReadyAt;
}
```

The asymmetry matters: raising a cooldown can be instant because it only ever helps users; lowering it must be delayed so users can exit. Consider additionally letting each position carry its own minimum interval, chosen at deposit alongside the envelope, so the global value can only ever be the stricter of the two.

---

## [C-5] Position owners cannot choose or revoke their rebalancer; `setRebalancer` instantly grants authority over every existing position

**Severity**: Medium
**Category**: access-control
**Location**: `setRebalancer()` (AutopilotHook.sol:462-465), `rebalance()` (AutopilotHook.sol:231)

**Description**: `rebalance` authorises on a single global flag: `if (!isRebalancer[msg.sender]) revert NotRebalancer();`. There is no per-position consent. A depositor cannot nominate a specific rebalancer, cannot restrict the set, and cannot opt out of automation at all — the envelope is the only lever they hold, and M-1 shows it does not constrain the transition. Any address the owner adds gains immediate authority over every position already in the contract, including positions created months earlier by users who had no opportunity to evaluate that address.

Against the checklist's centralization items:

- **Instant parameter changes without timelock** — `setRebalancer`, `setMinRebalanceInterval`, and `pause` all take effect in the calling transaction; events are emitted (good) but there is no reaction window (bad).
- **No cap on privileged role count** — `setRebalancer` is an unbounded mapping write, with no on-chain enumeration and no way for a user to inspect the full set.
- **Corrupted owner can destroy the protocol** — `setRebalancer(attacker, true)` → `setMinRebalanceInterval(0)` → the M-3 drain, three transactions, no delay at any step; the owner cannot move user tokens *directly* (there is correctly no rescue/sweep function), but this indirect path reaches the same outcome.
- **Renounce can brick** — `renounceOwnership` is disabled (correct, since the owner is needed to unpause), but the consequence is that this centralization is permanent.
- **When all agents are the same person** — nothing prevents `owner == rebalancer`, and `DeployAutopilotHook.s.sol` reads `REBALANCER_ADDRESS` from the environment with the broadcasting key as owner; a single EOA holding both roles is the default deployment shape unless operators are careful.

**Proof of Concept**:

1. Alice deposits at block 100 with envelope `[-1800, 1800]`, having reviewed the sole rebalancer address the protocol advertises.
2. At block 200 the owner calls `setRebalancer(0xATTACKER, true)`. One transaction, no delay, no notification to Alice beyond the `RebalancerSet` event.
3. At block 201 `0xATTACKER` calls `hook.rebalance(aliceId, ..., 0)` and begins the H-1 bleed. Alice's only defence is to notice the event and `withdraw` before the next cooldown expires — and per M-2 that window does not exist at all for a freshly-deposited position.

**Recommendation**: Let the position owner scope the authority at deposit time:

```solidity
mapping(bytes32 => address) public positionRebalancer;   // address(0) = any allowlisted rebalancer

function deposit(..., address preferredRebalancer) external ... {
    positionRebalancer[positionId] = preferredRebalancer;
}

function setPositionRebalancer(bytes32 positionId, address who) external {
    if (positions[positionId].owner != msg.sender) revert NotPositionOwner();
    positionRebalancer[positionId] = who;   // a sentinel value disables automation
}

// in rebalance():
address scoped = positionRebalancer[positionId];
if (scoped != address(0) && scoped != msg.sender) revert NotRebalancer();
if (!isRebalancer[msg.sender]) revert NotRebalancer();
```

Additionally: put the owner behind a `TimelockController` (via the existing `Ownable2Step` handover) so `setRebalancer` and interval reductions carry a mandatory delay; keep `pause` on a separate fast path (an owner-appointed guardian) since pausing is the one privileged action that only ever restricts, never extracts. Cap or at least enumerate the rebalancer set so users can audit it.

---

## [C-6] Position owner cannot rebalance their own position; pause or rebalancer loss freezes positions with only full exit as recourse

**Severity**: Low
**Category**: access-control
**Location**: `rebalance()` (AutopilotHook.sol:225-231)

**Description**: `rebalance` is reachable only by an allowlisted rebalancer; the check at line 231 does not admit `pos.owner`. If the contract is paused, if every rebalancer is de-allowlisted, or if the rebalancer infrastructure goes offline, a position is frozen where it stands. The user's sole remedy is `withdraw`, which is correctly always available, so no funds are trapped; but a user who wants to *keep* the position and merely recentre it cannot, and must exit and re-enter, paying gas and potentially realising impermanent loss at a bad moment.

This is the checklist's "pausing that blocks critical user operations" item in a mild form: pause blocks `rebalance` while the position continues to bear market risk. Since `withdraw` remains open the impact is bounded, hence Low rather than Medium.

**Proof of Concept**: Not an exploit path — a liveness/recourse gap.

1. Owner calls `pause()`, or simply `setRebalancer(r, false)` for every `r`.
2. Alice's position drifts out of range and stops earning fees.
3. Alice calls `rebalance` herself: reverts `NotRebalancer` (or `EnforcedPause`).
4. Her only action is `withdraw`, realising her position at the current adverse price.

Confirmed by reading the modifier set; no PoC needed beyond the line-231 check.

**Recommendation**: Allow the position owner to rebalance their own position, subject to the same envelope check but exempt from the allowlist and, optionally, from the cooldown (which exists to limit a delegated key, not the owner):

```solidity
bool isOwnerCall = (pos.owner == msg.sender);
if (!isOwnerCall && !isRebalancer[msg.sender]) revert NotRebalancer();
if (!isOwnerCall) {
    uint64 readyAt = pos.lastRebalanceAt + minRebalanceInterval;
    if (block.timestamp < readyAt) revert RebalanceTooSoon(readyAt);
}
```

The owner path should remain `whenNotPaused` only if pause is intended as a circuit-breaker on pool interaction generally; if pause exists to stop the *rebalancer*, the owner path should be exempt. Decide explicitly and document which.

---

## [C-7] Off-chain executor derives `minLiquidity` from a simulation of the same state, so the floor is self-referential

**Severity**: Low
**Category**: access-control
**Location**: `crates/lpa/src/exec/mod.rs:150-151` (`Executor::execute`)

**Description**: Even on the honest path the floor does not bound absolute value loss. `execute` first calls `simulate`, which `eth_call`s `rebalance(..., 0)` — the floor already disabled — and takes the returned liquidity as `quoted_liquidity`. It then derives:

```rust
let bps = u128::from(slippage_bps).min(BPS_DENOMINATOR);
let floor = sim.quoted_liquidity.saturating_mul(BPS_DENOMINATOR - bps) / BPS_DENOMINATOR;
```

`floor` is thus 99% (at the default `DEFAULT_SLIPPAGE_BPS = 100`) of *whatever the simulation produced*, not 99% of the position's fair value. If the pool is already manipulated when the simulation runs, the quote is correspondingly depressed and the floor sits beneath it, so the on-chain check at AutopilotHook.sol:355 passes comfortably on a fill that has already lost most of the position's value. The floor bounds only drift between simulation and inclusion — useful against ordinary MEV, useless against a state that was adverse at quote time.

Rated Low on its own because it concerns the off-chain component and weakens a mitigation rather than opening a new attack; listed because it removes the last argument that the `minLiquidity` design is safe under an honest operator, and so directly supports H-1.

**Proof of Concept**: Read from the source rather than executed — the Rust path was not run end-to-end against a live node, so this is reasoned from code, not empirically measured, and is rated accordingly.

1. Attacker manipulates the pool price.
2. The daemon's watch loop fires a rebalance intent and `simulate` returns a depressed `quoted_liquidity` Q.
3. `floor` is set to `0.99 * Q`.
4. The transaction lands at the same manipulated price, produces ≈Q, and clears `0.99 * Q`. The user absorbs the full manipulation loss with the floor never binding.

**Recommendation**: Derive the floor from a manipulation-resistant reference rather than from the contract's own quote — value the freed amounts at a TWAP or external oracle, compute the liquidity that value should buy in the target range, and take the floor from that. Regardless, the durable fix is H-1's protocol-enforced floor: an off-chain-only bound cannot constrain a compromised off-chain key.

---

## [C-8] `renounceOwnership()` override keeps a redundant `onlyOwner`, giving non-owners a misleading revert

**Severity**: Low
**Category**: access-control
**Location**: `renounceOwnership()` (AutopilotHook.sol:473-475)

**Description**:

```solidity
function renounceOwnership() public view override onlyOwner {
    revert RenounceDisabled();
}
```

Verified against the vendored OZ v5 `Ownable` (`lib/uniswap-hooks/lib/openzeppelin-contracts/contracts/access/Ownable.sol`): the base is `public virtual` (non-view) and `onlyOwner` delegates to `_checkOwner()`, which is `internal view`. Restricting mutability from non-payable to `view` in an override is legal Solidity and the contract compiles cleanly (confirmed with `forge build`), so there is **no** security hole — renouncing is genuinely impossible and, because unpausing requires an owner, disabling it is the right call.

The defect is the redundant `onlyOwner`: it makes the revert reason depend on the caller. A non-owner gets `OwnableUnauthorizedAccount(caller)`, implying "you lack permission to renounce", while only the owner sees the truthful `RenounceDisabled`. Anyone probing off-chain — an integrator, a monitoring bot, a user checking whether the protocol can be abandoned — draws the wrong conclusion. `test_renounce_ownership_disabled` exercises only the owner path and so does not surface it.

**Proof of Concept**:

1. `vm.prank(attacker); hook.renounceOwnership();` reverts `OwnableUnauthorizedAccount(attacker)`.
2. As owner, the same call reverts `RenounceDisabled`.

Two different answers to the same question, only one of which is true. No fund impact.

**Recommendation**: Drop the modifier so the function tells the truth to every caller:

```solidity
function renounceOwnership() public pure override {
    revert RenounceDisabled();
}
```

`pure` is now correct since nothing is read. Add a test asserting a non-owner also receives `RenounceDisabled`.

---

## [C-9] `boundLower`/`boundUpper` are never cleared on withdraw

**Severity**: Info
**Category**: access-control
**Location**: `withdraw()` (AutopilotHook.sol:191-223)

**Description**: `withdraw` sets `pos.active = false` and `pos.liquidity = 0` but leaves `boundLower[positionId]`, `boundUpper[positionId]`, and the rest of the `Position` struct populated. There is no exploitable consequence: `positionId` is `keccak256(abi.encode(msg.sender, id, depositNonce++))` with a monotonic nonce, so an id is never reused, and `rebalance` gates on `pos.active` before ever reading the bounds.

Noted only as latent state growth and to record that it was checked — a future change reusing position ids, or reading bounds before the `active` check, would turn this into a real issue.

**Proof of Concept**: None; no impact. Verified by grepping every write to the bound mappings (only lines 158-159, inside `deposit`) and confirming `depositNonce` is monotonic.

**Recommendation**: Optional. `delete positions[positionId]; delete boundLower[positionId]; delete boundUpper[positionId];` in `withdraw` reclaims gas and removes the latent trap, at the cost of post-hoc queryability of closed positions — which the events already cover.

---

## [C-10] ~~The hook re-enters itself through `_afterSwap` during `_swapToRatio`~~ — RETRACTED, v4 has a self-call guard

**Severity**: Info (retracted — not a finding)
**Category**: access-control
**Location**: `_swapToRatio()` (AutopilotHook.sol:425), `_afterSwap()` (AutopilotHook.sol:127-139)

> **Corrected during synthesis.** This agent originally reported that the
> `poolManager.swap` inside `_swapToRatio` re-enters the hook's own `afterSwap`
> mid-rebalance. That is **wrong**. The `defi-amm` agent reported the opposite,
> and the conflict was resolved by reading the vendored source.

`Hooks.sol:217` short-circuits before ever dispatching to the hook:

```solidity
function afterSwap(IHooks self, ...) internal returns (BalanceDelta, BalanceDelta) {
    if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
    ...
}
```

v4 applies the same `noSelfCall` protection across the other hook entry points
(`Hooks.sol:171-178`). Because `_swapToRatio` calls `poolManager.swap` with the
hook as `msg.sender`, `afterSwap` is never invoked for the hook's own
re-ratio swap. There is no re-entry edge, no half-completed-rebalance
observation window, and no need for a transient guard flag.

**Proof of Concept**: N/A — retracted.

**Recommendation**: No change. Note the guard explicitly if `_afterSwap` is ever
expanded, so nobody re-introduces a workaround for a problem v4 already solves.
The one real consequence is the inverse of the original claim: the hook's own
rebalance swap is **invisible** to its own `AutopilotCheck` telemetry, so the
off-chain daemon never sees an event for the price move its own rebalance
caused.

---

## [C-11] Verified-correct access control (positive findings)

**Severity**: Info
**Category**: access-control
**Location**: AutopilotHook.sol, whole file

**Description**: Recorded so a reader knows these were checked against the vendored sources rather than assumed.

- **Every external entry point carries the right modifier set.** Line by line: `getHookPermissions()` `public pure`; `deposit()` `external whenNotPaused nonReentrant`, permissionless by design; `withdraw()` `external nonReentrant` with `pos.owner != msg.sender` checked at line 194; `rebalance()` `external whenNotPaused nonReentrant` plus the `isRebalancer` check; `unlockCallback()` `external` with an explicit PoolManager check; `setRebalancer`, `setMinRebalanceInterval`, `pause`, `unpause` all `onlyOwner`; `renounceOwnership` reverting. No sensitive function is unguarded, and no admin function is callable by a third party for griefing.
- **`unlockCallback` cannot be reached with foreign calldata.** Confirmed in `lib/uniswap-hooks/lib/v4-core/src/PoolManager.sol:104-114`: `unlock(data)` calls `IUnlockCallback(msg.sender).unlockCallback(data)` — the callback target is always the caller of `unlock`. Since only `deposit`/`withdraw`/`rebalance` call `poolManager.unlock` on this contract, the `Callback` struct is always hook-constructed. A third party calling `poolManager.unlock` receives its own callback. The `msg.sender != address(poolManager)` check at line 272 closes the direct-call path. Correctly not `nonReentrant` — it must run inside the outer frame's guard.
- **`_afterSwap` is PoolManager-only.** Confirmed in `lib/uniswap-hooks/src/base/BaseHook.sol`: `afterSwap` is `external onlyPoolManager` with `if (msg.sender != address(poolManager)) revert NotPoolManager();`. All other hook entry points are likewise `onlyPoolManager` and revert `HookNotImplemented`; only the `afterSwap` flag is set.
- **Pause coverage is correct and cannot trap funds.** `withdraw` carries no `whenNotPaused`, and its entire path (`unlock` → `_doWithdraw` → `modifyLiquidity` → `take`) contains no pause check. Confirmed against the vendored `Pausable` that `whenNotPaused` is the only gating modifier and it is absent from that path. `test_withdraw_works_while_paused` covers this. This is the one safety valve in the trust-model claim that works exactly as described.
- **The tick envelope is immutable after deposit.** `boundLower`/`boundUpper` are written only at lines 158-159 inside `deposit`; there is no setter, and neither the owner nor a rebalancer can widen a user's envelope. `deposit` validates the envelope itself (`_validateTicks(key, minBound, maxBound)`) and that the initial range sits inside it. The *enforcement* is sound; M-1 concerns what the envelope fails to cover, not a bypass of it.
- **Two-step ownership is correct.** Confirmed against the vendored `Ownable2Step`: `transferOwnership` is `onlyOwner` and only sets `_pendingOwner`; `acceptOwnership` is `public` but checks `pendingOwner() != sender`; `_transferOwnership` clears the pending slot. The constructor's `Ownable(msg.sender)` reverts on the zero address. `test_two_step_ownership_transfer` covers it.
- **No rescue, sweep, or admin-transfer function exists.** The checklist's "admin can move user tokens" item does not apply: there is no `transfer`/`transferFrom` with an admin-controlled destination anywhere in the contract. All `take` calls send to `cb.owner`, read from `positions[positionId].owner` and never attacker-controlled. Admin abuse must route through the rebalancer role (M-4), not a direct token path.
- **Not upgradeable, not an initializer pattern.** No proxy, no `initialize()`, so the `_disableInitializers` and arbitrary-upgrade items do not apply. The hook address is CREATE2-mined in `DeployAutopilotHook.s.sol` and validated by `BaseHook._validateHookAddress`.
- **Counter accounting is balanced.** `poolPositionCount[id] += 1` in `deposit` pairs with `-= 1` in `withdraw`, guarded by the `pos.active` check, so the subtraction cannot underflow and cannot be driven by a third party.

**Proof of Concept**: N/A — these are negative results, each confirmed by reading the vendored dependency source at the paths cited.

**Recommendation**: No action. Preserve these properties under future changes — particularly the absence of a sweep function and the non-pausability of `withdraw`.

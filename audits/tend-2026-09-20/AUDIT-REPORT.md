# Tend / AutopilotHook — Security Audit Report

**Target**: `contracts/src/AutopilotHook.sol` (484 LOC) and the off-chain daemon paths that price and trigger it (`crates/lpa/src/chain/`, `strategy/`, `exec/`).
**Commit**: `b448bfe` (branch `feat/indexing-enrichment`)
**Date**: 2026-09-20
**Method**: 8 parallel specialist agents against the [evm-audit-skills](https://github.com/austintgriffith/evm-audit-skills) checklists, followed by synthesis, deduplication, cross-agent conflict resolution, and independent re-verification of the most consequential claims.
**Chains in scope**: Base (8453), Ethereum (1).

> **Status: still pre-audit, but both Criticals and all five Highs are now
> fixed** (commits `7593b42`, `779e19d`, and the price-guard commit that
> follows). Remediation notes are in §10. The contract remains
> professionally unaudited and a number of Mediums are open — do not use with
> real funds.
>
> *As originally written:* Two Critical findings. The first makes the contract's
> primary function — rebalancing an out-of-range position — a value-extraction
> opportunity for any third party. The second means the contract as deployed by
> its own script has **no owner**, so the pause switch and rebalancer allowlist
> that every other mitigation depends on do not exist.

---

## 1. Result at a glance

| Severity | Count | Deduplicated headline issues |
|---|---|---|
| **Critical** | 2 | Unbounded re-ratio swap; bricked ownership on deploy |
| **High** | 5 | Caller-chosen slippage floor; rebalancer value bleed; blacklist strands both legs; spot-only pricing; flash-loan branch forcing |
| **Medium** | 21 | — |
| **Low** | 26 | — |
| **Info** | 20 | — |
| **Total raw findings** | **101** across 8 agents | |

Two agent findings were **retracted** and one **downgraded** during synthesis (§6). The counts above are post-correction.

---

## 2. Critical findings

### [CRIT-1] The re-ratio swap has no price limit and trades through a pool it has just drained

**Severity**: Critical
**Reported independently by**: `defi-amm` (A-1), `flashloans` (F-1), `precision-math` (P-1), `general` (G-1), `access-control` (C-1), `dos` (D-1/D-2), `oracles` (O-1)
**Location**: `_doRebalance()` AutopilotHook.sol:324-376, `_swapToRatio()` :425-433

**Six of eight agents converged on this independently.** It is the root cause of roughly a third of all findings in this audit.

`_doRebalance()` burns the position's own liquidity **first**, then `_swapToRatio()` market-orders the entire freed balance back through that same pool with:

```solidity
sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
```

These are the v4 sentinels meaning *no limit*. When the hook is the pool's dominant LP, active liquidity after the burn is zero, `SwapMath.computeSwapStep` returns `amountIn = 0` at every step, and `Pool.swap`'s loop walks `slot0` to the sentinel.

**Reproduced.** `rebalance(pid, 600, 1200, 0)` on a 1:1 pool leaves `slot0` at tick **887271** — and the call **succeeds**. The first arbitrageur then takes the position: victim `-2.9553e16` token1 / `+2.7091e16` token0, attacker gains exactly that.

**Zero-capital and permissionless.** The attacker needs no key and no position. Using v4's own `unlock` + `take`, they borrow the inventory from the PoolManager itself, swap the price back, and settle — capital in is gas alone. They manufacture the precondition by JIT-pulling their own liquidity in a front-run transaction, then back-running the wrecked price.

**A private RPC does not mitigate this.** A back-run requires no mempool visibility. `FLASHBOTS_RPC` blunts the front-run variants only.

**There is no safe operating regime** for `rebalance()` as written:

| Position size vs. active liquidity | Outcome |
|---|---|
| Small share | Works, but sandwichable (A-3, F-3) |
| Above ~10% | Reverts `ZeroLiquidity` — measured: fails at 0.1×/1×/5× external depth, succeeds only at 10× (P-2, D-2) |
| Dominant LP | Destroys the pool price and hands the position away (A-1, F-1) |

The project's E2E test exercises only the middle case.

**Recommendation** (agents converged on the same one-line core):

```solidity
// Bound the fill to the target range instead of the tick extremes.
sqrtPriceLimitX96: zeroForOne ? sqrtA : sqrtB
```

This bounds the fill and makes the swap partial, so a non-zero balance survives on both legs. Additionally: cap `amountIn` so one call can never market-sell 100% of a side; add a spot-vs-reference deviation circuit breaker (§CRIT-1 interacts with HIGH-4); and revert when spot lies outside `[sqrtA, sqrtB]` beyond a tolerance, since that discontinuity is what an attacker steers the hook into.

---

### [CRIT-2] Deploying via the project's own script leaves the contract with no reachable owner

**Severity**: Critical (raised from High during synthesis after direct verification)
**Reported by**: `general` (G-2)
**Location**: `constructor` AutopilotHook.sol:113 (`Ownable(msg.sender)`), `script/DeployAutopilotHook.s.sol`

`HookMiner` requires deployment through the canonical CREATE2 factory so the address carries the permission bits. Forge routes a salted `new` through that factory when broadcasting — so `msg.sender` inside the constructor is the factory, not the deployer.

**Verified directly on a local anvil using the unmodified deploy script:**

```
AutopilotHook deployed at 0x5df4140dbB9391Dff4a6Ae2456D2eEBEB2a58040
owner()      = 0x4e59b44847b379578588920cA78FbF26c0B4956C   <- the CREATE2 factory
deployer EOA = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

cast send $HOOK 'pause()' --private-key <deployer>
-> revert OwnableUnauthorizedAccount(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
```

Consequences on any hook deployed this way:

- `pause()` / `unpause()` — **permanently unreachable**
- `setRebalancer()` — **permanently unreachable**, so the rebalancer set at construction can never be revoked
- `setMinRebalanceInterval()` — **permanently unreachable**
- `transferOwnership()` — **permanently unreachable**
- `renounceOwnership()` — reverts by design

**This removes the mitigations every other finding assumes exist.** The README's stated safety valves — "Cooldown, pause, and the slippage floor" — reduce to the cooldown alone, and HIGH-1 shows the floor was never a valve to begin with.

**Why the test suite cannot catch it**: `AutopilotHook.t.sol` uses `deployCodeTo(...)`, which sets `msg.sender = address(this)`. The tests make the test contract the owner and therefore never exercise the production deployment path.

**Recommendation**: Take the owner as an explicit constructor argument rather than inferring it from `msg.sender`:

```solidity
constructor(IPoolManager pm, address initialOwner, address initialRebalancer, uint64 cooldown)
    BaseHook(pm) Ownable(initialOwner)
{
    if (initialOwner == address(0)) revert ZeroOwner();
    ...
}
```

Add a post-deploy assertion to the script (`require(hook.owner() == expectedOwner)`) and a test that deploys through a CREATE2 factory rather than `deployCodeTo`.

---

## 3. High findings

### [HIGH-1] The only slippage floor is chosen by the party it is meant to constrain, and bounds liquidity rather than value
**From**: `defi-amm` A-2, `access-control` C-1, `general` G-1, `access-control` C-7 (off-chain)

`rebalance(..., uint128 minLiquidity)` takes the floor from `msg.sender`, who must be an allowlisted rebalancer. Passing `0` disables it; every non-slippage test in the suite passes `0`.

Worse, it is the wrong quantity. `newLiquidity` is computed at the **post-swap** price, and when spot sits outside `[sqrtA, sqrtB]`, `getLiquidityForAmounts` ignores spot entirely and returns a function of one token amount — so a depressed price can make `newLiquidity` go **up**, satisfying the floor while the owner loses value. **Measured: a 7% floor (`0.93e18`) still passes.** Only a 0% tolerance catches it, which would make every legitimate rebalance revert.

Even on the honest path the floor is self-referential: `Executor::execute` derives it from `simulate()` — an `eth_call` of `rebalance(..., 0)` at head state — so it bounds drift between simulation and inclusion, not absolute value loss.

**Recommendation**: Make the floor protocol-enforced and value-denominated. Snapshot value against a *reference* price (not spot) before and after, and enforce an owner-set `maxSlippageBps` stored at deposit, so a rebalancer cannot waive the owner's protection.

### [HIGH-2] A rebalancer key alone bleeds any position inside its envelope
**From**: `access-control` C-1/C-2/C-4, `general` G-6

**Measured**: 20 cycles alternating two ranges *strictly inside* a deliberately narrow owner envelope, cooldown fully respected, floor at `0` → **5.7% of the position destroyed** (~0.29%/cycle, exactly the pool fee). At a 1-hour cooldown that is ~6.8%/day, indefinitely, against every position at once. The value lands with the pool's other LPs — a role the attacker can occupy via a JIT position, converting destruction into capture.

With `minRebalanceInterval` set to `0` (owner-reachable, no floor, no timelock, applies retroactively): **59% of a position destroyed in a single transaction** over 300 in-envelope iterations.

The envelope does not help. It bounds *where* a position may sit, not *what a rebalance does to it*, and same-range rebalances are legal — so even the tightest possible envelope (`minBound == tickLower`, `maxBound == tickUpper`) stops nothing.

**Recommendation**: Reject no-op rebalances; require the position to actually be out of range before permitting one; impose a non-zero floor on `minRebalanceInterval` with a timelock on reductions; add the protocol-enforced value floor from HIGH-1.

### [HIGH-3] A blacklisted or frozen owner permanently strands both tokens of the position
**From**: `erc20` T-1, `dos` D-3

`withdraw()` hard-codes the payout recipient to `pos.owner` and always takes the underlying (`claims = false`). `PoolManager.take` does a raw `token.transfer(owner, amount)`. A USDC or USDT blacklisting — or a token-level pause — reverts the whole atomic unlock, which takes **both** currencies. The non-blacklisted leg (e.g. 15 WETH in a USDC/WETH position) is permanently stranded alongside the frozen one. `rebalance()`'s surplus `take()` targets `pos.owner` too, so the position cannot even be moved aside.

The hook itself is also a blacklist target on the deposit leg, since `settle()` calls `transferFrom` with the hook as `msg.sender`.

**Recommendation**: Add a `recipient` parameter and an `asClaims` flag. `asClaims = true` mints ERC-6909 credit inside the PoolManager, which never touches the underlying token — rescuing the clean leg unconditionally and preserving a transferable claim on the frozen one.

### [HIGH-4] Instantaneous spot is the only price input, with no TWAP anywhere
**From**: `oracles` O-1/O-2, `defi-amm` A-4, `flashloans` F-5

`getSlot0` — a single `extsload` of the live slot0 word — drives swap direction, swap size, and mint sizing. v4 ships no observation array, so there is no on-chain history to fall back on. Branch selection (`spot <= sqrtA`, `spot >= sqrtB`) is *discontinuous*, and the boundaries are plaintext calldata in the pending transaction: pushing spot across one flips the hook from a small balancing trade to a 100%-of-one-side unlimited market order.

Credit where due: `_swapToRatio` is structurally mean-reverting — it buys whatever the manipulation made cheap — so the naive sandwich in the obvious direction loses money. That is a property of the arithmetic rather than a designed defence, and it does not survive the boundary-crossing case.

**Recommendation**: Maintain a truncated-oracle observation buffer in `afterSwap` (already enabled) or read an external pair feed, then gate `rebalance()` on a spot-vs-reference deviation check.

### [HIGH-5] Flash loans select the branch rather than worsening the price
**From**: `flashloans` F-2, F-3

The profitable use of a flash loan here is not to worsen execution but to push spot outside the `[newTickLower, newTickUpper]` read from mempool calldata, converting a small straddle-branch trade into a 100% single-side dump — maximising the payload for CRIT-1. JIT liquidity provision in the traversal path makes the attacker the direct counterparty.

**Recommendation**: Covered by CRIT-1's price limit plus HIGH-4's deviation gate.

---

## 4. Cross-cutting attack chains

The individually-rated findings understate the risk. Three chains matter more than their parts.

### Chain A — No kill switch behind an unbounded swap
`CRIT-2` (no reachable owner) + `HIGH-2` (rebalancer bleed) + `C-5` (no per-position rebalancer consent)

A deployed hook cannot be paused and its rebalancer cannot be revoked. A compromised rebalancer key therefore drains every position in the contract, indefinitely, with **no on-chain recourse of any kind**. Users' only remedy is to `withdraw()` faster than the attacker can cycle — and per `C-3`, a freshly deposited position has no cooldown protection at all for its first rebalance.

### Chain B — The attacker controls both the trigger and the payload
`O-3` (poisonable tick history) + `F-4` (attacker schedules the victim transaction) + `HIGH-4` (spot-only pricing) + `CRIT-1`

The bot reacts to `Swap` events, so a third party who cannot call `rebalance()` can still *induce* it by moving the price. Distorting the Bollinger window collapses `sigma`, which both fires `out_of_bb` on nearly every swap and shrinks `half_width` to a minimum — and a narrow target range is exactly what makes CRIT-1's boundary-crossing dump cheap. The attacker chooses when the LP rebalances, how narrow the new range is, and what price it trades at.

### Chain C — The feature is either broken or dangerous, never safe
`P-2`/`D-2` (reverts above ~10% of active liquidity) + `CRIT-1` (destroys price when dominant)

See the table in CRIT-1. A position large enough to be worth automating is large enough to be unsafe to automate.

---

## 5. What is correct (verified, not assumed)

Recorded so these properties are preserved under future changes:

- **Access control modifiers are complete.** Every external entry point carries the right set; no sensitive function is unguarded. `unlockCallback` is unreachable with foreign calldata — v4's `PoolManager.unlock` only ever calls back its own `msg.sender`.
- **`withdraw()` is deliberately not pausable**, so pause cannot trap funds. The one safety valve in the stated trust model that works exactly as advertised.
- **The tick envelope is genuinely immutable** after deposit — written once, no setter, neither owner nor rebalancer can widen it. The critique in HIGH-2 is about what it fails to cover, not a bypass.
- **`_afterSwap` is O(1) and revert-free.** `getSlot0` bottoms out in `Extsload.extsload` — `mstore`/`sload`/`return`, no revert path. The pool-wide shared cost is a constant ~5-7k gas and cannot be inflated or made to revert by anyone.
- **No reentrancy.** v4's global `Lock` makes `unlock()` non-nestable; OZ `nonReentrant` is entered before `unlock()` so it covers the whole callback chain; and decisively, `_doRebalance()` performs no `settle`/`take` between the liquidity burn and the re-add, so no malicious-ERC20 window exists in the critical section.
- **`poolPositionCount` underflow is impossible** — gated behind a one-shot `active` flag inside `nonReentrant`, with collision-free position ids.
- **Missing-return-value tokens (USDT) are handled correctly** on both legs; all six zero-amount transfer paths are double-guarded.
- **Fee-on-transfer does not silently corrupt accounting** — v4's `_settle` credits `balanceAfter - balanceBefore`, so a short settle hard-reverts `CurrencyNotSettled`.
- **Chainlink decimal handling is correct** — `decimals()` read dynamically, no hardcoded `1e8`.
- **Tick math and redeposit rounding were verified sound** — the two-step Q96 square matches the exact `Q192` form bit-for-bit at realistic sizes, and `getLiquidityForAmounts` never demands more than the hook holds.

---

## 6. Corrections made during synthesis

Agent output was not taken on trust. Three material corrections:

**Retracted — `afterSwap` self-reentry (2 agents wrong, 1 right).** `access-control` C-10 and `general` G-10 both reported that the hook's own re-ratio swap re-enters `_afterSwap`. `defi-amm` A-14 said it does not. Resolved by reading `Hooks.sol:217`:

```solidity
if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);
```

v4 has an explicit self-call guard. **The dissenting agent was right and the majority was wrong** — agreement between agents is not evidence. The real consequence is the inverse of the original claim: the rebalance swap is *invisible* to the hook's own `AutopilotCheck` telemetry, so the daemon never observes an event for the price move its own rebalance caused — which matters given CRIT-1, where that move is exactly what an attacker back-runs.

**Downgraded — atomic tick-history poisoning (High → Medium).** `oracles` O-3 claimed one row per `Swap` event, enabling a single transaction with 200 dust swaps to rewrite the whole window for a few dollars. `record_tick` is in fact deduplicated per block, so that transaction writes **one** row. The attack requires pinning the tick across ~200 distinct blocks (~7 minutes on Base) against continuous arbitrage. Still a real weakness — unweighted window, arithmetic mean, partial poisoning remains cheap — but not the atomic attack described.

**Two of the coordinator's own premises were corrected by an agent.** The `erc20` agent was briefed that fee-on-transfer tokens silently corrupt `deposit()`'s stored liquidity and that rebasing desyncs `Position.liquidity`. Both are wrong: v4 hard-reverts the former, and the latter stores geometric `L` mirrored exactly by the PoolManager (the desync is one level down, between v4 reserves and `balanceOf`). Recorded because the agent pushing back on its brief is the behaviour that makes this process worth running.

**Independently re-verified by the coordinator**: CRIT-2 (deployed on anvil, `owner()` read, `pause()` revert observed); the cooldown gap (`forge test --block-timestamp`); and O-5 (`grep` confirming `EthPrice` never reaches `exec/`).

---

## 7. Notable Medium findings

| ID | Issue |
|---|---|
| C-3 | `lastRebalanceAt = 0` means the **first rebalance of every position bypasses the cooldown** on any live chain (`readyAt ≤ 31_536_000` vs `block.timestamp ≈ 1.75e9`). The existing test passes only because Foundry's default `block.timestamp` is `1`; it fails at a realistic clock. **The test asserts a property the deployed contract does not have.** |
| C-4 | `minRebalanceInterval` is global, retroactive, has no floor and no timelock. |
| C-5 | Users cannot choose, restrict, or revoke which rebalancer has authority over their position; `setRebalancer` instantly grants power over every existing position. |
| O-5 | The live Chainlink ETH/USD price **never reaches the executor's spend cap**, which uses a static `f64` defaulting to `3000.0`. The gas price is live; the ETH price is not. At ETH `$6000`, a `$95` transaction is computed as `$47.50` and passes a `$50` cap. |
| O-6 | `EthPrice` has no timestamp, so a feed that never connects serves the seed price forever behind a single `warn!`. **If O-5 is fixed without O-6, this escalates.** |
| O-4 | No L2 sequencer-uptime check on Base at either layer; the danger is the resumption edge. |
| P-2 | Swapping 100% of one side forces `newLiquidity == 0` whenever the swap crosses into the new range — positions above ~10% of active liquidity cannot be rebalanced onto a one-sided range near spot. |
| G-5 | Rounding-direction mismatch can leave a ≤2 wei debt and revert the rebalance with `CurrencyNotSettled` (analytically derived; no concrete failing input produced). |
| T-2 / T-3 | Fee-on-transfer pairs revert unconditionally on deposit; rebasing pairs strand yield and risk last-withdrawer insolvency. Neither is rejected or documented. |
| D-1 | A third party can reliably front-run `rebalance()` to force `ZeroLiquidity`/`SlippageExceeded`, pinning a position out of range for as long as they keep paying. Temporary, not permanent — a reverted attempt does not consume the cooldown. |
| A-7 / G-3 | `deposit()` has no maximum-amount slippage guard and is sandwichable. |
| A-6 | Partial fills of the re-ratio swap are silently accepted. |

---

## 8. Recommended remediation order

1. **CRIT-2** — one-line constructor change. Nothing else can be trusted until the contract has an owner.
2. **CRIT-1** — bound `sqrtPriceLimitX96` to `sqrtA`/`sqrtB`; cap `amountIn`. This also closes D-1, D-2, P-1, P-2, G-1, G-4, A-1, A-5, F-1, F-2.
3. **HIGH-1** — protocol-enforced, value-denominated floor with an owner-set `maxSlippageBps`.
4. **C-3** — `lastRebalanceAt = block.timestamp` at deposit, and add `vm.warp` to the test `setUp` so the suite cannot pass for the wrong reason.
5. **HIGH-4** — spot-vs-reference deviation gate; a truncated-oracle buffer in the already-enabled `afterSwap` is the cheap route.
6. **HIGH-3** — `recipient` + `asClaims` on withdraw.
7. **O-5 and O-6 together** — thread `EthPrice` into the executor *and* give it a freshness check. Doing O-5 alone makes things worse.
8. **HIGH-2 supporting fixes** — no-op rebalance rejection, interval floor + timelock, per-position rebalancer consent.

## 9. Test-suite gaps this audit exposed

Every one of the project's 37 contract tests passes. They share assumptions that made the two Criticals invisible:

- **`deployCodeTo` instead of the real CREATE2 path** — cannot observe CRIT-2.
- **`test_rebalance_to_one_sided_range` asserts only `liq > 0`** and never inspects the pool price — it *triggers* CRIT-1 today and passes.
- **Foundry's default `block.timestamp = 1`** — makes the cooldown test pass for the wrong reason.
- **Only solmate `MockERC20`** — no fee-on-transfer, blacklist, rebasing, 6-decimal, or no-return-value coverage.
- **Every non-slippage test passes `minLiquidity = 0`** — the floor is never exercised as a real constraint.

The pattern is consistent: the tests check that operations *complete*, not that they did the *right thing*. That is the same class of blind spot that let the earlier `ZeroLiquidity` bug ship until an end-to-end run caught it.


---

## 10. Remediation status

Fixes were written against this report and each is covered by a regression test
that was confirmed to fail against the unfixed contract.

| ID | Status | Fix |
|---|---|---|
| CRIT-1 | **Fixed** | `_swapPriceLimit()` bounds the fill at the first target-range boundary in the direction of travel, instead of the tick extremes. Strict comparisons because v4 reverts `PriceLimitAlreadyExceeded` unless the limit is strictly past spot; returns 0 to skip the swap when no boundary lies beyond spot. Verified: without the fix the three new tests fail with price at `MAX_SQRT_PRICE-1` and ticks at ±887272. |
| CRIT-2 | **Fixed** | Owner is an explicit constructor argument, not `msg.sender`. The deploy script asserts `owner()` is reachable afterwards. |
| HIGH-1 | **Fixed** | `maxRebalanceLossBps` — owner-set, hard-capped at 500, enforced by the contract. The position is valued before and after the re-ratio swap **at the same pre-swap price**, so the swap cannot move the yardstick it is measured against, and the rebalancer cannot waive it. |
| HIGH-2 | **Fixed** | No-op rebalances rejected; `minRebalanceInterval` floored at 60s in both the constructor and the setter, so the single-transaction drain is impossible. |
| HIGH-3 | **Fixed** | `withdraw(positionId, recipient, asClaims)`. ERC-6909 claims are minted inside the PoolManager without calling the token, so a blacklist on one currency cannot strand the other. One-argument overload retained. |
| HIGH-4 | **Fixed** | Per-pool truncated price reference maintained in `afterSwap`: advances toward spot at most once per block and by at most `maxTickMovePerBlock`. `rebalance()` refuses to act when spot deviates from it by more than `maxDeviationTicks`. Dragging the reference now costs sustained blocks rather than one flash-loaned transaction. |
| C-3 | **Fixed** | `lastRebalanceAt` stamped at deposit; test suite warps to a realistic clock. |
| G-8 / P-7 / T-6 (partial) | **Fixed** | The dead `sell0 == 0` disjunct removed while extracting `_straddleSwap`. |
| O-5 + O-6 | **Fixed together** | `EthPrice` now carries an `updated_at` stamp and exposes `get_fresh()`, which returns `None` for a seed-only or stale price. The executor's spend cap consumes `get_fresh()` and **refuses to send** rather than falling back, so a dead feed gates spending off instead of pricing it against a constant. Fixing O-5 alone would have put the cap behind a silently-seeded value, which is why they moved together. Repeated refresh failures escalate from `warn` to `error`. |

| O-4 | **Fixed** | Owner-settable Chainlink L2 uptime feed (zero disables it for L1), checked in `rebalance()` with a 3600s grace period after a restart. The Base feed `0xBCF85224...` was verified on-chain — `description()` returns `"L2 Sequencer Uptime Status Feed"`. |
| C-5 | **Partly fixed — this entry was previously overstated** | `positionRebalancer` lets an owner scope a position to one rebalancer, or disable automation entirely with the `AUTOMATION_OFF` sentinel. Opting out cannot trap a position — `withdraw` is unaffected. **Correction:** an earlier version of this row claimed "adding a rebalancer globally no longer silently grants authority over positions that predate it." That is false and was demonstrated false in the 2026-09-23 re-audit. `positionRebalancer` defaults to `address(0)`, which `_requireRebalancerFor` treats as "any allowlisted rebalancer", so a position whose owner never sent the opt-in transaction is unchanged by this fix. The scoping is opt-in, and nothing in `deposit()` prompts a user to use it. |
| T-4 (and the enforcement half of T-2 / T-3) | **Fixed** | Owner-curated pair allowlist, off by default, checked **only in `deposit()`** so de-listing a pair can never strand an open position. This is what turns "we don't support fee-on-transfer" from a comment into a rule. |
| O-3 | **Partly fixed** | Per-block collapse moved into SQL rather than relying on the in-memory dedup that resets on reconnect, and the Bollinger centre is now a 10%-trimmed mean instead of an arithmetic mean, so a few extreme samples no longer drag the band. The window is still count-based rather than time-weighted. |

| O-3 (remainder) | **Fixed** | `recent_ticks_weighted` pairs each sample with the number of blocks it prevailed, and the bands are now computed with a weighted, weight-trimmed mean. A tick that stood for one block carries a tenth the influence of one that stood for ten, so band influence is earned with elapsed time rather than bought with swap frequency. |
| T-2 (diagnosability) | **Fixed** | `_settleExact` compares the PoolManager's balance across the settle and reverts `FeeOnTransferNotSupported(currency, expected, received)`. Confirmed: without it the same deposit surfaces as v4's `CurrencyNotSettled()` from inside `unlock`. |
| G-5 | **Not reproduced** | A fuzz over rebalance liquidity (1e12–1e22) and target range (±5000 ticks) found **no settlement shortfall in 20,001 runs**; every revert was a named hook error. The finding was analytically derived and no concrete input was ever produced, by its author or here. Recorded as not-reproduced rather than fixed — absence of a counterexample is evidence, not proof. |

### Still open

- **T-3** — rebasing pairs still strand yield and risk last-withdrawer
  insolvency. This is a v4-wide property, not something the hook can fix; the
  allowlist is the mitigation and it has to be turned on and populated.
- The remaining Low and Info findings.

### What re-auditing would need to cover

These fixes added roughly 300 lines of security-sensitive logic to a contract
audited in its *previous* shape. Each is covered by a regression test confirmed
to fail against the unfixed code, which shows the fix addresses its finding — it
does not show the fix introduced nothing new. The new surface worth pointing a
fresh audit at:

- `_swapPriceLimit` boundary selection, especially the equality cases at
  `spot == sqrtA` and `spot == sqrtB`.
- The value guard's pre-swap price measurement, and whether measuring at a price
  an attacker set one block earlier weakens it.
- The truncated price reference: seeding, and whether a long-idle pool's stale
  reference blocks legitimate rebalances.
- `_settleExact`'s balance delta against tokens that do something unusual
  mid-transfer.
- The interaction of five independent revert paths on `rebalance()`, which is now
  a fair number of ways for a legitimate rebalance to fail closed.

### A note on what the fixes cost

The price guard adds one `SSTORE` per pool per block to `afterSwap`, which every
swapper in the pool pays. That is a real externality and it was weighed: the
alternative is a rebalancer trading at a price nothing corroborates. The write is
gated on `poolPositionCount > 0`, so pools with no autopilot positions are
unaffected.

The value floor and the price guard both **fail closed**. A genuinely fast market
move will block a rebalance rather than execute it at a price the hook cannot
corroborate. For an operation that moves real value on behalf of someone else,
refusing to act is the correct default.

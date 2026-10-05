# Tend full audit — 2026-10-03/04

**Target:** the whole codebase at `f993a76` (`origin/feat/indexing-enrichment`):
`contracts/src/AutopilotHook.sol` (whole contract, not a diff), `contracts/script/*`, and the Rust
daemon `crates/lpa`.
**Goal:** verify every fix claimed by the three earlier audits (2026-09-20, 09-23, 10-03) and find
anything new.

**Method:** seven reviewers, each in its own git worktree reset to `f993a76`:

| Reviewer | Checklists | Findings file |
|---|---|---|
| Core and access control | general, access-control | `findings-core.md` |
| AMM and math | defi-amm, precision-math | `findings-amm-math.md` |
| Oracles | oracles, flashloans | `findings-oracle.md` |
| Governance and deploy | governance, chain-specific | `findings-governance.md` |
| DoS and liveness | dos, general | `findings-liveness.md` |
| Tokens and settlement | erc20, general | `findings-token.md` |
| Daemon security | general, plus Rust/backend practice | `findings-daemon.md` |

Every Medium-or-above finding came with a PoC that its reviewer ran. The PoCs are on the
reviewers' `worktree-agent-*` branches under `contracts/test/audit/full/` and in test-only Rust
modules. Three Highs were **re-run independently during synthesis** and reproduced against unmodified
source: OR-1, DM-1 and DM-2. Two Highs were found **independently by two reviewers each**: OR-1 = AM2-1,
and DM-2 = LV-7. Nothing was broadcast to a real chain; the daemon PoCs used a plain local anvil
behind a lying proxy. No GitHub issues were filed.

## 1. Summary

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | |
| High | 3 | OR-1 (= AM2-1), DM-1, DM-2 (= LV-7) |
| Medium | 10 | CO-1, AM2-2 (with LV-1), LV-2, LV-3, LV-4, LV-5, LV-6, DM-3, DM-6 |
| Low | ~16 | CO-3, OR-2, OR-3, GV-1, GV-2, DM-4, DM-5, DM-7, DM-8, LV-8..LV-11, T-5 (still open) |
| Info | ~20 | across all files |

**The headline: the previous round's main fix is broken, and the daemon's transaction layer was never
audited.**

1. **OR-1: the PR-1 stability fix doesn't hold.** The counter only resets on a *clamped* write. Steps of
   ≤ 500 ticks are never clamped, so the reference follows an attacker who holds the price across
   **one** block end, just as before. The victim loses 342–949 bps, and in a 0.05% pool the attacker
   profits about 4–8% of the victim's value. My regression test pushed 700 ticks at once, which
   clamps, so it couldn't see this. The README's "must hold > 5 block ends" is false.
2. **DM-1: the spend cap doesn't bound what is signed.** Fees and the chain id come from the RPC or
   relay through alloy's fillers. A lying relay got $7,047 of priority fee signed against a $50 cap,
   and got a transaction signed for chain 1.
3. **DM-2 / LV-7: one failed or dropped send stops automation until restart.** The cached nonce manager
   advances even when the send never happens.
4. **CO-1: deposit sandwich.** Reported on 2026-09-20 (G-3 / A-7) and dropped from every report since
   without a fix or a decision. That was my tracking failure. The PoC shows 128 bps to a third party.
5. **The DS-1 fallback is incomplete (AM2-2 / LV-1).** Fee dust, or an attacker's dust LP, means it
   never runs, and the position goes ~100% idle indefinitely.

**What held:** the settlement and accounting core. Every invariant was fuzzed across token types, the
one-sided fallback and extreme prices: claims equal idle, withdraw pays exactly principal + fees + idle,
the PoolManager is always settled, and no third party can block a withdraw. The timelock fixes
(TL-1..TL-4) all hold, and the deploy script now works with keystore signers too.

## 2. Findings by priority

### High
| ID | Area | One line | Fix direction |
|---|---|---|---|
| OR-1 / AM2-1 | hook | Steps ≤ 500 ticks bypass `MIN_STABLE_BLOCKS` | Count stability against a fixed base: reset when a block end leaves the reference more than `maxDeviationTicks` from the base, not only when clamped. Regressions for 500-tick and 200×k steps. |
| DM-1 | daemon | The signed fee and chain id come from the RPC, not the cap | Set the gas limit and fees explicitly from what `check_spend` approved, cap the priority fee absolutely, fix and assert the chain id |
| DM-2 / LV-7 | daemon | A cached nonce gap stops automation until restart | Explicit nonce from the pending count; pass the estimated gas; re-sync after NotSent/Unconfirmed |

### Medium
| ID | One line | Fix direction |
|---|---|---|
| CO-1 | `deposit` has no `amount0Max`/`amount1Max`/deadline (open since 09-20) | Add them to both overloads and check before settling |
| AM2-2 / LV-1 | The one-sided fallback is skipped when the other token is non-zero | Compare the straddle with the one-sided placement and place whichever deploys more value |
| LV-2 | Free `PriceUnsettled` lock where there is no liquidity at spot | Ignore block ends with zero active liquidity; don't poke when ref == spot |
| LV-3 | Transient `OutOfBounds` gets a 6 h Terminal suppression | Clip proposals to the bounds; classify `OutOfBounds` as Retry |
| LV-4 | A refused backfill chunk blocks the watermark, and replays reset ranges | Split chunks; idempotent replay by (block, logIndex); interleave logs |
| LV-5 | The in-flight marker leaks in a race | Mark before `try_send` and roll back on error; TTL |
| LV-6 | The OOR sweep isn't batched, so the idle sweep is starved | Cursor + batch; capacity check and `decide` before RPCs |
| DM-3 | `serve` has no auth by default and can delete positions | Require a token unless `--insecure-no-auth`; `Host` check; protect hook-sourced rows |
| DM-6 | A per-position UPDATE on every Swap, on the log path | One statement in one transaction; proposals off the log path; WAL |

### Low / Info
See the findings files. The most material:
- **CO-2/OR-2:** the hook's own swap doesn't write the reference.
- **GV-1:** pin the sequencer feed per chain.
- **GV-2/CO-4:** the selector-keyed queue cancels unrelated additions.
- **DM-4:** a tiny feed answer zeroes the caps.
- **DM-8:** RPC keys in logs.
- **LV-8:** duplicate processing and replay order.
- **LV-12:** selector matching over the whole revert text.
- **OR-4:** the oracle's answer age and the L1 data fee.
- **`cargo audit`:** four advisories (h2, rustls, quinn-proto, ruint).
- **T-5** (direct unbounded approval) is still open.

## 3. Verified correct
- **Settlement:** fuzzed with 3 positions, 2 owners, random depth, swaps, rebalances and exits, plus the
  fallback and ±800k ticks. Claims equal the sum of idle after every step, payouts are exact, and there
  is never `CurrencyNotSettled` or a panic (`findings-token.md`, `findings-amm-math.md`).
- **Access:** only a position's owner can move its funds. `unlockCallback` accepts calls only from the
  PoolManager. Reentrancy is blocked on both the payer and the recipient side. After narrowing, the
  stored range always equals the PoolManager position.
- **Timelock:** TL-1..TL-4 hold. `msg.sig` is correct on every path. The epoch is bumped on accept and
  not while a transfer is pending.
- **Value guard:** it measures "loss compared with not rebalancing, if price returns to the reference",
  and range choice can't inflate it. The reference is the only gap (OR-1).
- **Deploy script:** works with `--private-key`, `--unlocked --sender` and a keystore. The handover voids
  the old queue.
- **Daemon:** the key is never logged, SQL is parameterized, auth is constant-time when a token is set,
  and DS-2, DS-4, DS-5, DS-6, DS-7, DS-8 and DS-9 hold within the scope described above.

## 4. Recommended fix order
1. **OR-1.** It reopens a profitable third-party loss.
2. **DM-1 and DM-2 / LV-7** together. Both live in how the executor builds and sends transactions:
   explicit nonce, gas and fees, and a fixed chain id.
3. **CO-1.** A deposit-side slippage guard.
4. **AM2-2 / LV-1, LV-2.** Contract liveness.
5. **LV-3..LV-6, DM-3, DM-6.** Daemon robustness.
6. The Lows and Infos.

## 5. Not covered
- **Arbitrage:** no PoC models it, so OR-1's real cost to the attacker (holding a price across one block
  end) is argued, not measured.
- **Base RPC `pending`:** the reviewers weren't allowed a Base RPC, so how Base nodes answer `pending`
  is unverified (GV-4).
- **Ordering:** sequencer and mempool ordering on Base wasn't measured.

## 6. Fix status

Every finding above Info is fixed with a regression test, or declined with the reason recorded.
The reviewers' PoC files are now regression tests: `contracts/test/audit/full/*.t.sol`,
`crates/lpa/src/audit_dm_tests.rs` and `crates/lpa/src/chain/subscriber/liveness_poc.rs`. Each one
asserts that its attack is refused or bounded; previously each showed the attack working.

### High
| ID | Fix | Regression |
|---|---|---|
| OR-1 / AM2-1 | `PriceRef.base`: a block end extends the stable run only if it is unclamped **and** within `maxDeviationTicks` of where the run began. A new level must be held for `MIN_STABLE_BLOCKS` block ends. | `test_OR1_*` (500-tick step, two steps, downward, fee-500 profit: all refused); `test_OR1_fix_walk_in_window_sized_steps_is_refused` (200×2..6); `test_OR1_fix_alternating_steps_refused`; `test_AM2_1_*` |
| DM-1 | The executor builds every transaction itself with no alloy fillers. It sets the nonce, a gas limit of the estimate plus 25%, a max fee of 2 × base fee plus priority, a priority fee capped by `LPA_MAX_PRIORITY_FEE_GWEI`, and the chain id from config. The spend cap and hourly budget price the worst case (gas limit × max fee). At connect it checks `eth_chainId` on both RPCs. | `audit_dm1_*`: the lying relay's 100,000 gwei becomes 2 gwei, paying $0.14 against the $50 cap; a relay naming another chain is refused at connect and nothing is signed |
| DM-2 / LV-7 | The nonce is read from the confirmed count before every send. A transaction stuck at that nonce is outbid by 12.5%, not queued behind. | `audit_dm2_*`: a dropped send, then the next attempt lands, nonce 1, no restart. `fee_plan_caps_the_priority_fee_and_outbids_a_stuck_nonce`. |

**Residual (OR-1), measured:** an attacker who holds a pushed level for exactly
`MIN_STABLE_BLOCKS` block ends gets it trusted. One block end fewer is refused. Holding for the full
count costs 342 bps against a deep pool in the harness, which models no arbitrage
(`test_OR1_fix_residual_requires_holding_a_level`). That is about 10 s of holding a price off fair
against arbitrage on Base. It was one block end (2 s) before the fix.

### Medium
| ID | Fix | Regression |
|---|---|---|
| CO-1 | `deposit` takes `amount0Max`, `amount1Max` and `deadline` (one function replaces both overloads). `_doDeposit` reverts `DepositExceedsMax` before settling; an expired deadline reverts `DeadlineExpired`. | `test_CO1_fix_quoted_maxima_refuse_the_sandwich` |
| AM2-2 / LV-1 | When the target straddles spot, `_placeableLiquidity` also computes the one-sided placement on the dominant token's side and takes whichever deploys more value. | `test_AM2_2_*` (was 9998 bps idle, now under 100); `test_LV1_*` (a dust LP no longer defeats it) |
| LV-3 | The executor clips proposals to the owner's bounds (`boundLower`/`boundUpper`). `OutOfBounds` is Retry, not a 6 h Terminal. | `proposals_are_clipped_to_the_owner_bounds`, `every_refusal_maps_to_its_action` |
| LV-4 | Refused log ranges are halved down to single blocks; a block that still fails is skipped with an error. Hook and swap logs are merged in (block, logIndex) order. A replayed `PositionOpened` for a known position is ignored. | `lv4_*`: the watermark reaches head and the rebalanced range survives replay |
| LV-5 / LV-10 | The intent is marked in flight **before** `try_send` and rolled back on failure. `mark_queued` returning false (already queued) skips. | `lv5_*`: 0 leaks in 20,000 intents (was 763); `ds4_*` |
| LV-6 | The out-of-range sweep is batched (40 a pass) with a cursor, and checks queue capacity before any RPC. | `lv6_*`: each pass finishes inside the timeout and the idle sweep runs |
| DM-3 | `lpa serve` refuses to start without `LPA_API_TOKEN` unless `--insecure-no-auth` is given. | binary run: `refusing to serve without auth` |
| DM-6 | One SELECT and one UPDATE per swap, not one commit per position. WAL mode. In auto-execute mode proposals come from the sweep, not inline on the log path. | `audit_dm6_*`: under 100 ms at 2,000 positions (was 724 ms) |

**Declined: LV-2 (free `PriceUnsettled` lock with no liquidity at spot).** With no active liquidity
at spot, nothing in the pool is a trustworthy price, so the hook can't tell an honest quiet market
from an attacker's free swaps. Any rule that rebalances there anyway hands that attacker the price.
Withdraw is unaffected. Mitigated in the daemon:
- it pokes on `PriceUnsettled` only when the reference is clamped (LV-9);
- the hourly spend budget caps what the daemon pays;
- it warns after 50 pokes without settling (PR-3).

### Low / Info
- **Fixed:**
  - CO-2/OR-2: the rebalance writes the reference after its own swap.
  - CO-3: a narrowed placement equal to the old range is still `NoOpRebalance`.
  - GV-2/CO-4: the queue is keyed per rebalancer address (`changeKey`, `cancelChange(bytes32)`).
  - GV-1: Base pins and requires Chainlink's feed in the deploy script.
  - GV-3: `setAllowedPool` rejects tick spacing ≤ 0, and the script requires fee and spacing.
  - GV-6: the constructor emits the impact default.
  - AM2-3: the upward impact bound no longer wraps near MAX.
  - TS-2: the deposit record is written before `unlock`.
  - TS-1: documented as best-effort.
  - DM-4: ETH/USD answers outside $1–$1M are rejected and never stamped fresh.
  - DM-5: stream tasks exit when the client disconnects.
  - DM-7: ticks are range-checked at the API, the CLI and the strategy.
  - DM-8: every logged error goes through `redact`, which cuts URLs to scheme://host.
  - LV-9: pokes only when they can help.
  - LV-11: a timeout after a send starts the per-position interval.
  - LV-12: refusals are classified by the leading selector only.
  - LV-8: logs are replayed in chain order.
  - `cargo audit`: h2, rustls (0.23.45), quinn-proto and ruint updated; no vulnerabilities remain.
- **Declined or documented:**
  - GV-5: the constructor allowlist default; the deploy script enforces it in the same broadcast.
  - GV-4: Base `pending` semantics; only delays, and the OR-1 stability rule now dominates.
  - OR-3: grief cost, accepted.
  - AM2-4: extreme-price floor.
  - TS-1: best-effort check, documented.
  - CO-5: Info.
  - T-5: direct approval, Low; Permit2 is out of scope for this round.
  - Daemon Info, the key: it stays in the process environment. Clearing it with `remove_var`
    races tokio's worker threads, so the README's advice stands: use a keystore or an external
    signer in production.
  - Daemon Info, API-registered ids: these don't match hook position ids. That is by design: the
    API and CLI `register` are for monitoring, and the hook refuses those ids as terminal. Now
    documented in the CLI table.
- **Fixed in a follow-up commit (2026-10-05):**
  - OR-4: answer age is per feed, the heartbeat plus 5 minutes (Base 1,500 s, Ethereum 3,900 s).
    Test: `answer_age_follows_each_feeds_heartbeat`.
  - Executor supervision: a panic in one intent is caught and logged, and the loop continues. If
    the loop ever exits, it says so, and the sweep reports a closed channel as "executor not
    running", not "queue full".
  - `.env` is read from the working directory only (`dotenvy::from_path`), never a parent.
  - Per-position configs stored with `UpdateConfig` now drive the strategy, and the lower of the
    position's and the global spend cap is used. Test: `stored_position_config_drives_the_strategy`.
  - Migration failures other than "duplicate column" are logged.

### Verification
- `forge test`: **207 passed**, 1 skipped.
- `cargo test`: **112 passed**, plus 5 anvil/long tests passing with `--ignored`. Clippy clean.
- **E2E:** all 8 stages pass on a local anvil fork of Base, with the new stability rule, the explicit
  transaction fields and the batched sweeps. One run failed at stage 8 with "no fresh ETH/USD
  price". The power log showed macOS had entered *maintenance* sleep for 3 minutes, which
  `caffeinate -i` does not block. The script now also passes `-s`, and the rerun passed.
- **Deploy script,** on a plain chain-8453 anvil:
  - a non-Chainlink feed is refused;
  - pool tokens without a tick spacing are refused;
  - with no feed set, it uses the pinned Chainlink address.


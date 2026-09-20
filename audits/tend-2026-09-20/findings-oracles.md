# Tend Autopilot — Oracles & Pricing Findings

**Scope**: `contracts/src/AutopilotHook.sol` (on-chain); `crates/lpa/src/chain/oracle.rs`, `config.rs`, `subscriber.rs`, `strategy/`, `exec/` (off-chain).
**Checklist**: evm-audit-oracles (walked in full).

> **Synthesis note.** One finding in this file (O-3) was **downgraded during
> synthesis** after its central premise was checked against the source and found
> to be wrong. The correction is inline at O-3. Everything else stands as
> reported, and O-5 was independently re-verified and confirmed.

## Summary

The system has **no price oracle in the security sense anywhere in its trade path**. `AutopilotHook` derives every price from `poolManager.getSlot0(poolId)` — a single `extsload` of the packed slot0 word returning instantaneous, post-last-swap `sqrtPriceX96` and `tick`. There is no averaging, no observation buffer, and v4 core ships no built-in oracle, so the hook's price is manipulable to any value inside one transaction. That single value drives both swap direction/size in `_swapToRatio()` and liquidity sizing in `_doRebalance()`. The only guard is `minLiquidity`, denominated in liquidity units computed *at the manipulated price*, supplied by the rebalancer, and derived off-chain from an `eth_call` against whatever state existed at simulation time.

Off-chain, the Chainlink ETH/USD reader is the best-built component in scope — it verifies `description()`, reads `decimals()` dynamically, rejects non-positive answers, and bounds staleness — but its output is wired only into the strategy's EV estimate and **never reaches the spend cap in `Executor::execute`**, which uses a static configured `eth_price_usd` defaulting to `3000.0`. Neither layer has any L2 sequencer-uptime check for Base.

One nuance stated up front to avoid overstating the on-chain findings: `_swapToRatio()` is structurally *mean-reverting* — it always buys whichever token the manipulated price made cheap — so the naive "flash-loan spot, sandwich the hook" attack in the obvious direction does **not** profit. The real price-source exposure is the *induced* rebalance (O-3) and the manipulated baseline (O-2), not a one-shot atomic sandwich.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 1 (O-3 downgraded from High → Medium) |
| Medium | 5 |
| Low | 5 |
| Info | 1 |
| **Total** | **12** |

| ID | Layer | Severity | Title |
| --- | --- | --- | --- |
| O-1 | on-chain | High | Instantaneous `getSlot0` spot is the only price input for swap sizing and liquidity sizing |
| O-2 | on-chain | Medium | No TWAP or independent price reference; `minLiquidity` floor is denominated in a manipulated unit |
| O-3 | off-chain | ~~High~~ **Medium** | Homegrown tick-history oracle is unweighted and poisonable — *but not atomically; see correction* |
| O-4 | on-chain + off-chain | Medium | No L2 sequencer-uptime check on Base at either layer |
| O-5 | off-chain | Medium | Live Chainlink ETH/USD never reaches the USD spend cap; the cap uses a hardcoded price |
| O-6 | off-chain | Medium | `EthPrice` cache never expires — a dead feed serves the seed price forever |
| O-7 | off-chain | Low | 3600s staleness window hardcoded across chains; no margin over the mainnet heartbeat |
| O-8 | off-chain | Low | `description()` substring check accepts stETH/cbETH/rETH-style derivative feeds |
| O-9 | off-chain | Low | No `startedAt`, `answeredInRound`, or `minAnswer`/`maxAnswer` handling |
| O-10 | off-chain | Low | Hardcoded feed / StateView / PoolManager addresses with no override path |
| O-11 | on-chain | Low | `_afterSwap` publishes the manipulable spot tick as the automation trigger; cooldown may be 0 |
| O-12 | off-chain | Info | Feed `decimals()` and `description()` read once at connect and never re-validated |

---

## [O-1] Instantaneous `getSlot0` spot is the only price input for swap sizing and liquidity sizing

**Severity**: High
**Category**: oracles
**Location**: on-chain — `_swapToRatio()` (AutopilotHook.sol:385), `_doRebalance()` (AutopilotHook.sol:346)

**Description**: Both pricing sites read the same value. `StateLibrary.getSlot0` is a single `extsload` of the packed slot0 word returning live `sqrtPriceX96`/`tick` — the pool's spot price *after the most recent swap in the same transaction*. This is exactly the `pool.slot0()` pattern the checklist flags under "NEVER use spot reserves as a price oracle" [beirao O-09, SigmaPrime]. v4 core keeps no observation array, so there is no on-chain history to fall back on.

Three decisions hang off this one manipulable number:

1. **Branch selection** (`:392`, `:396`). `sqrtPriceX96 <= sqrtA` and `>= sqrtB` are *discontinuous* predicates. Crossing either flips the hook from "swap the small balancing delta" to `amountIn = have1` / `have0` — a market order for **100% of one side**. The boundaries are public: `newTickLower`/`newTickUpper` are plaintext calldata in the pending `rebalance()` transaction.
2. **Swap size** in the straddle branch (`:403-421`): `want0`/`want1`, `_inToken1`, `_inToken0`, `target1` are all functions of `sqrtPriceX96`.
3. **Mint sizing** (`:347-353`): `getLiquidityForAmounts` selects which token determines `L` based on where spot sits relative to `[sqrtA, sqrtB]`. When spot is outside the new range, `sqrtPriceX96` drops out of the formula entirely and `L` is a function of one token amount alone — so `minLiquidity` compares against a quantity whose *meaning* the attacker chose.

Combined with `sqrtPriceLimitX96` pinned to the extremes (`:430`) and `minLiquidity` possibly 0, the hook executes an unbounded-size, unlimited-slippage market order whose direction and magnitude a third party controls by moving spot.

**Proof of Concept**: The attacker cannot call `rebalance()` (gated by `isRebalancer`), but does not need to — see O-3 for inducement. Given a pending or induced `rebalance(positionId, L_new, U_new, minLiq)`, within one Base block (FIFO sequencer, so a searcher paying priority can place all three):

1. **T1 (attacker)**: swap to push `sqrtPriceX96` just past `getSqrtPriceAtTick(U_new)`. If the bot centred the new range with half-width `h` ticks, this requires moving spot by `h` ticks. For a ~0.5% half-width (≈50 ticks) on a pool with depth `D`, notional is on the order of `0.5% × D`, fully round-trippable — standing cost ~2× the pool fee plus gas. On a 5 bps Base pool with `D = $2M`: roughly `$10k` notional, ~`$10` of fee.
2. **T2 (the bot's `rebalance`)**: `_doRebalance` removes the old position. Spot now sits above the new range, so `_swapToRatio` takes the `>= sqrtB` branch and issues `amountIn = have0` — the **entire** freed token0 — as a single market sell with no price limit. Position-sized price impact is paid in full.
3. **T3 (attacker)**: back-run, buying back the crashed token0 and re-arbing against other venues.

Two honest caveats capping this at High rather than Critical:

- The hook's forced trade in T2 is *against* the direction the attacker moved price in T1, so the T1/T3 legs alone are net-negative. The attacker's profit is the **back-run of the hook's own price impact**, not a conventional sandwich. That profit scales with position size relative to pool depth and is zero for a small position in a deep pool.
- If `minLiquidity` came from an honest pre-manipulation quote and `slippage_bps` is the default 100, the `L` shortfall exceeds 1% and the transaction reverts — griefing DoS rather than extraction. O-2 covers the manipulated-baseline case.

**Recommendation**: Add an independent reference price and a deviation circuit-breaker, and bound the swap:

```solidity
error PriceDeviation(uint160 spot, uint160 reference);
uint256 public maxDeviationBps; // e.g. 100 = 1%

function _checkSpot(PoolKey memory key) internal view returns (uint160 spot) {
    (spot,,,) = poolManager.getSlot0(key.toId());
    uint160 ref = _referenceSqrtPrice(key); // TWAP observation, or a Chainlink pair feed
    uint256 diff = spot > ref ? uint256(spot - ref) : uint256(ref - spot);
    if (diff * 10_000 > uint256(ref) * maxDeviationBps) revert PriceDeviation(spot, ref);
}
```

Also replace the extreme `sqrtPriceLimitX96` with a limit derived from the reference price, cap `amountIn` so one call can never market-sell 100% of a side, and revert when spot lies outside `[sqrtA, sqrtB]` by more than a tolerance — that discontinuity is precisely what an attacker steers the hook into.

---

## [O-2] No TWAP or independent price reference; the `minLiquidity` floor is denominated in a manipulated unit

**Severity**: Medium
**Category**: oracles
**Location**: on-chain — `_doRebalance()` AutopilotHook.sol:346-355; off-chain baseline at `crates/lpa/src/exec/mod.rs:140-147`

**Description**: There is no TWAP anywhere — not in the hook, not in the bot. v4 provides none natively, so a hook wanting one must maintain observations itself or read an external feed. This contract does neither. The checklist's entire "TWAP Oracles" section is vacuously satisfied and "Spot Price Manipulation" applies in full.

The project's answer is the `minLiquidity` floor, which is weaker than it looks for three reasons specific to it being a *liquidity* floor rather than a *value* floor:

1. **The unit is price-dependent.** `newLiquidity` is computed at post-swap `sqrtPriceX96`. When spot sits outside `[sqrtA, sqrtB]`, `getLiquidityForAmounts` ignores it and returns a function of a single token amount. An attacker who moves spot so the hook converts everything into the token that inflates that amount gets a *larger* `L`, sailing past the floor while fair value has fallen.
2. **The baseline is set off-chain from whatever state the simulation saw.** `Executor::execute` calls `simulate()` — an `eth_call` of `rebalance(..., 0)` at head state — and sets `floor = quoted_liquidity * (10_000 - bps) / 10_000`. If an attacker holds the price moved across the block the bot simulates in, `quoted_liquidity` is itself manipulated. Multi-block hold, not flash-loanable — costs the round-trip fee plus arbitrage risk for one 2-second Base block.
3. **Who sets it.** `minLiquidity` is a parameter of the rebalancer-only `rebalance()`. The position *owner* has no slippage parameter anywhere in `deposit()`. Their only durable protection is `boundLower`/`boundUpper`, which constrains *which ticks* may be used but places no constraint on *execution price*.

`_swapToRatio` does have a genuine structural defence worth crediting: it always trades toward the target ratio at current price, i.e. buys whichever token the manipulation made cheap. A naive flash-loan sandwich in the obvious direction loses money. That is why this is Medium — but it is a property of the arithmetic, not a deliberate oracle design, and it does not survive O-1's boundary-crossing case.

**Proof of Concept**: Failure mode rather than a clean single-transaction exploit.

1. Block N: attacker swaps to move spot to `P'` and leaves it there. Cost is the pool fee plus the risk an arbitrageur corrects it before N+1.
2. Block N: the bot sees the `Swap`, calls `propose_rebalance`, and the executor runs `simulate()` at the manipulated head state. `quoted_liquidity` is computed at `P'`.
3. `floor = quoted_liquidity * 0.99` — 99% of a manipulated quantity, not of fair value.
4. Block N+1: `rebalance()` executes at or near `P'`. The floor is satisfied by construction. When price mean-reverts, the loss is realised by the LP.

Extractable amount is bounded by how long `P'` can be held against arbitrage and by position size relative to pool depth. Not measured numerically here; the access-control agent's bleed measurement is the right figure to apply.

**Recommendation**: Give the floor a manipulation-resistant denominator and give the owner a say:

```solidity
mapping(bytes32 => uint16) public maxSlippageBps;   // owner-set at deposit

uint256 valueBefore = _valueInToken1(freed0, freed1, referenceSqrtPrice);
// ... swap and mint ...
uint256 valueAfter  = _valueInToken1(finalAmount0, finalAmount1, referenceSqrtPrice);
if (valueAfter * 10_000 < valueBefore * (10_000 - maxSlippageBps[cb.positionId])) {
    revert SlippageExceeded(uint128(valueAfter), uint128(valueBefore));
}
```

where `referenceSqrtPrice` never comes from `getSlot0`. Note a v4 hook can maintain its own truncated-oracle observation buffer in `afterSwap` — already enabled here — which would make a TWAP cheap to add.

---

## [O-3] Homegrown tick-history oracle is unweighted and poisonable

**Severity**: ~~High~~ **Medium** — downgraded during synthesis
**Category**: oracles
**Location**: off-chain — `subscriber.rs` (`handle_swap`), `tracker.rs:182-194`, `strategy/math.rs:50-61`, `strategy/mod.rs:172-195`

> ### CORRECTION APPLIED DURING SYNTHESIS
>
> The agent reported that `tick_history` takes **one row per `Swap` event**, and
> built its proof of concept on an *atomic* attack: one transaction containing
> ~200 dust swaps, each writing a row, rewriting the whole window for a few
> dollars.
>
> **That premise is wrong.** `record_tick` is deduplicated per block in
> `handle_swap`:
>
> ```rust
> if !crosses.is_empty() {
>     let new_block = ctx.last_block.get(&pool_id).map(|v| *v != block).unwrap_or(true);
>     if new_block {
>         ctx.last_block.insert(pool_id, block);
>         ctx.tracker.record_tick(&pool_hex, tick, block)?;
>     }
> }
> ```
>
> At most **one sample per pool per block** is written. 200 dust swaps in one
> transaction write exactly **one** row, not 200.
>
> The attack is therefore **not atomic**. Poisoning the full 200-sample window
> requires pinning the tick near `T*` across ~200 distinct blocks — roughly
> **7 minutes of sustained manipulation on Base** (2s blocks), during which
> arbitrageurs are continuously fighting the displaced price and the attacker
> carries inventory risk the whole time. That is a different and far more
> expensive proposition than "a few dollars, atomically".
>
> **Severity downgraded High → Medium.** The window is still unweighted, still
> uses an arithmetic mean vulnerable to skew, and partial poisoning (a few dozen
> samples) remains cheap and meaningfully distorts `sigma`. The recommendation
> below is unchanged and still worth doing — the per-block dedup is a
> mitigation the design already has, not a reason to leave the rest unfixed.

**Description**: The bot maintains its own price history and treats it as an oracle:

- `_afterSwap` emits `AutopilotCheck(poolId, tick, count)`.
- The bot decodes each `Swap`, takes `ev.tick.as_i32()`, calls `propose_rebalance(...)`, and persists a sample via `record_tick` — **subject to the per-block dedup above**.
- `recent_ticks` returns the last `STRATEGY_TICK_WINDOW = 200` samples ordered by block — unweighted by time or volume.
- `math::bollinger` computes a plain arithmetic mean and population stddev over those 200 integers.
- `StrategyEngine::decide` uses those bands for the `out_of_bb` trigger and for `half_width`, then sets `new_lower/upper = current_tick ± half`.

`current_tick` is the instantaneous post-swap tick of whoever swapped last. This is the checklist's "homegrown oracle" [SigmaPrime — Synthetix/MKR] and "TWAP mean skewed by single extreme reading" patterns.

**Proof of Concept** (corrected): Sustained, not atomic.

1. Attacker swaps to push the tick from honest `T` to chosen `T*`.
2. Attacker **holds** the tick near `T*` across ~200 consecutive blocks (~7 min on Base), re-pushing against arbitrageurs each block so each block's recorded sample lands near `T*`. Cost is the ongoing arbitrage fight, not a one-off fee.
3. Attacker releases. The pool recovers, but `tick_history` does not: all 200 rows read ≈`T*`, so `sma ≈ T*` and `sigma ≈ 0`.

From the next honest swap: `out_of_bb` is true for essentially any real tick, so the bot proposes a rebalance on nearly every swap; and `half_width`, driven by `bands.sigma.max(1.0)`, collapses to a minimum, so the bot targets an absurdly narrow range around `current_tick`. A narrow range is exactly the O-1 precondition — the capital needed to push spot outside it collapses toward zero.

Loss channels: forced churn (each induced rebalance costs gas + pool fee + spread, each individually passing the 1% floor — the Harvest Finance pattern [SigmaPrime]); attacker-chosen range; and amplification of O-1.

Partial mitigations that genuinely reduce this: the per-block dedup (above), `minRebalanceInterval` (deploy default 3600s), the off-chain per-position `min_interval` (default 300s), the EV gate, and the tick envelope. These throttle churn; none detect that the history is fabricated, and the EV gate is itself computed from the poisoned `step_sigma`.

**Recommendation**: Replace the count-based unweighted window with a manipulation-resistant statistic:

```sql
SELECT tick FROM tick_history WHERE pool_id = ?1 AND block_number >= ?2
  GROUP BY block_number ORDER BY block_number DESC
```

(a) keep the per-block dedup and make it explicit in the query rather than relying on an in-memory `DashMap` that resets on reconnect; (b) weight each sample by the time it prevailed, making this an actual TWAP; (c) use a median or trimmed mean instead of the arithmetic mean; (d) clamp per-block tick movement (truncated-oracle style) before recording; (e) re-read the tick from a fresh chain call before acting and refuse if it deviates from the windowed statistic beyond a threshold — the bot currently trusts `ev.tick` from the event with no independent confirmation.

---

## [O-4] No L2 sequencer-uptime check on Base at either layer

**Severity**: Medium
**Category**: oracles
**Location**: on-chain — `AutopilotHook` (no uptime feed anywhere); off-chain — `oracle.rs`, `config.rs:5-12`

**Description**: A repository-wide grep for `sequencer`/`uptime` returns nothing. Base is an OP-stack L2 with a centralised sequencer and is the **default chain** for the bot. The checklist calls for a sequencer-uptime feed plus a grace period of at least 3600s [beirao O-06, SigmaPrime].

**On-chain.** `rebalance()` has no uptime gate, and `ChainAddrs` defines no uptime feed address. The hook's price source is the pool itself, so during an outage `getSlot0` is not "stale" in the Chainlink sense — it is frozen along with the chain. The danger is the *resumption* edge: when Base restarts, the backlog lands in one burst, spot gaps to fair value in the first few swaps, and queued `rebalance()` transactions execute against that gap with floors computed from pre-outage simulations.

**Off-chain.** `price_usd` rejects answers older than `MAX_ANSWER_AGE_SECS`, but during a Base outage the Chainlink aggregator on Base cannot update either, so after an hour every read fails — and by O-6 the failure is swallowed and the last-good price is served indefinitely. There is no grace period after restart.

**Proof of Concept**: Failure mode.

1. Base sequencer halts. Pending `rebalance()` transactions queue.
2. During the outage the off-chain fair price moves ~8%.
3. Sequencer resumes; arbitrageurs are first in the FIFO queue and move spot to fair value within a block or two.
4. Queued rebalances execute against state their floors were not quoted against. Either they revert on `SlippageExceeded` (burned gas, position left out of range), or — since `L` is not a value measure (O-2) — the floors pass and the hook re-ratios across a discontinuous gap, executing its unlimited-slippage swap into the thinnest liquidity of the restart.
5. `tick_history` now contains a hard discontinuity, inflating `stddev` and distorting every Bollinger decision for the next 200 samples.

**Recommendation**:

```solidity
AggregatorV3Interface public immutable sequencerUptimeFeed;
uint256 public constant GRACE_PERIOD = 3600;

function _requireSequencerUp() internal view {
    (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
    if (answer != 0) revert SequencerDown();          // 1 == down
    if (startedAt == 0) revert SequencerDown();
    if (block.timestamp - startedAt < GRACE_PERIOD) revert GracePeriodNotOver();
}
```

Call it at the top of `rebalance()` on Base deployments, guarded so mainnet (zero-address feed) skips it. **Verify the Base uptime-feed address against current Chainlink documentation before deploying — it was not independently confirmed in this session.** Off-chain, add the feed to `ChainAddrs`, and have `propose_rebalance` refuse to emit intents until the grace period elapses. On reconnect, drop queued intents rather than replaying stale ones.

---

## [O-5] Live Chainlink ETH/USD never reaches the USD spend cap; the cap uses a hardcoded price

**Severity**: Medium
**Category**: oracles
**Location**: off-chain — `exec/mod.rs:131-166`, `:196-206`; wired at `main.rs`; versus `subscriber.rs:121-140`

> **Independently re-verified during synthesis and CONFIRMED.**
> `grep -rn "EthPrice" crates/lpa/src/exec/ crates/lpa/src/main.rs` returns
> nothing — the live price handle is never referenced on the execution path.

**Description**: There are two separate ETH price values in this codebase and they never meet.

1. **Live, oracle-backed.** `run_watch` constructs `EthPrice::new(...)`, spawns the Chainlink refresher, and hands it to `LiveCostModel::new(gas_price, eth_price)`. Its only consumer is the strategy's EV estimate and the `est_cost > config.max_gas_usd` early-exit in `decide`. That is an advisory filter on whether a rebalance is *worth proposing*.

2. **Static, hardcoded.** The gate that decides whether real money is spent:

```rust
let gas_price = self.provider.get_gas_price().await?;
let est = cost::rebalance_cost_usd(gas, gas_price, eth_price_usd);
if !cost::within_spend_cap(est, max_gas_usd) {
    bail!("spend cap exceeded: ${est:.2} > ${max_gas_usd:.2}");
}
```

`eth_price_usd` is a plain `f64` field of `AutoExec`, populated from the TOML file, then `ETH_PRICE_USD`, then `DEFAULT_ETH_PRICE_USD = 3000.0`. **The gas price is read live from the chain; the ETH price is not.** The whole oracle module — `description()` verification, dynamic `decimals()`, staleness rejection — guards a number that never reaches the spend decision. This is the checklist's "manual oracle update acts as hardcoded during delays" pattern [SigmaPrime, Tangible USDR].

**Proof of Concept**:

1. Operator deploys with defaults: `max_gas_usd = 50.0`, `eth_price_usd = 3000.0`.
2. ETH rises to `$6000`. The refresher picks this up within 60s and the strategy's EV gate uses it correctly.
3. An intent reaches `run_executor_loop`. `execute` computes `est = (gas × gas_price / 1e18) × 3000.0` — **half the true USD cost**.
4. A transaction costing `$95` is computed as `$47.50`, passes `within_spend_cap(47.50, 50.0)`, and is sent. The operator's `$50` cap has been silently doubled.

The error is unbounded and grows the longer the constant goes unrevised. Impact is gas overspend rather than principal — hence Medium — but it is exactly the control the oracle was built to provide, disconnected.

**Recommendation**: Thread the live handle through instead of the constant.

```rust
pub struct AutoExec {
    pub slippage_bps: u32,
    pub max_gas_usd: f64,
    pub eth_price: crate::chain::oracle::EthPrice,  // was: eth_price_usd: f64
    pub min_interval: Duration,
}

let eth_price_usd = eth_price.get_fresh()          // see O-6
    .ok_or_else(|| anyhow!("no fresh ETH/USD price; refusing to price the spend cap"))?;
```

This requires constructing the oracle before the executor in `main.rs`'s `Watch` arm. Keep the configured value strictly as a seed. Do the same for the one-shot `lpa rebalance` CLI path.

---

## [O-6] `EthPrice` cache never expires — a dead feed serves the seed price forever

**Severity**: Medium
**Category**: oracles
**Location**: off-chain — `oracle.rs:88-127`; fallback wiring at `subscriber.rs:125-138`

**Description**: `price_usd()` does staleness correctly. But the value consumers read has no staleness of its own. `EthPrice` stores a bare `Arc<AtomicU64>` of micro-dollars with **no timestamp**, and the refresher swallows every failure — `get()` is infallible and returns the last stored value unconditionally. There is no way to distinguish "priced 40 seconds ago" from "this is the seed constant and the feed has never answered". The 3600s check is load-bearing only for *updating* the cache; it never invalidates it.

Three paths reach the seed, all logging a warning and continuing: `connect()` fails (bad address, `description()` mismatch, RPC down) — the refresher is never spawned, so the seed is permanent; no HTTP RPC configured — same; or the refresher spawns but every answer is stale — same.

Answering the brief directly: **yes, a stale or seed price silently permits over-budget spending** — but today only through the EV filter, because per O-5 the executor cap does not consume this value at all. **If O-5 is fixed without also fixing O-6, this escalates**: the cap would then be gated by a value that silently falls back to `3000.0`.

**Proof of Concept**:

1. Operator mistypes the feed address so `connect()`'s `description()` call fails.
2. One `warn!` at startup; the daemon reports healthy.
3. `get()` returns `3000.0` for the process lifetime.
4. ETH trades at `$6000`. Every EV calculation understates gas by 2×, so `decide()` passes rebalances it should reject and `ev::should_rebalance` approves EV-negative ones. Each pays real gas and real spread for negative expected value — a slow bleed with no alarm.

**Recommendation**: Store the observation time and make freshness explicit at the call site.

```rust
pub struct EthPrice {
    micro_usd: Arc<AtomicU64>,
    updated_at: Arc<AtomicU64>,   // unix seconds; 0 == never refreshed
}

/// None when the price is seed-only or older than the tolerance.
pub fn get_fresh(&self) -> Option<f64> {
    let ts = self.updated_at.load(Ordering::Relaxed);
    if ts == 0 || now_secs().saturating_sub(ts) > MAX_CACHE_AGE_SECS {
        return None;
    }
    Some(self.micro_usd.load(Ordering::Relaxed) as f64 / USD_SCALE)
}
```

Make `get_fresh()` the only accessor used by anything that gates spending. Escalate repeated refresh failures from `warn!` to `error!` after N consecutive failures, and surface feed health on the serve endpoint.

---

## [O-7] 3600s staleness window hardcoded across chains; no margin over the mainnet heartbeat

**Severity**: Low
**Category**: oracles
**Location**: off-chain — `oracle.rs:23` (`MAX_ANSWER_AGE_SECS`), applied at `:75-77`

**Description**: A single constant bounds answer age on both chains. `ChainConfig` is per-chain for addresses but carries no per-chain heartbeat [multichain-auditor, beirao O-03; Cyfrin].

- **Ethereum ETH/USD** (`0x5f4ec3df...`): confirmed to use a **0.5% deviation threshold and 3600-second heartbeat**. The bot's threshold is *exactly equal* to the heartbeat, with zero margin. When quiet and no deviation trigger fires, the feed updates at the boundary; adding RPC latency and block time, `age > 3600` will intermittently be true during entirely normal operation. Those failures are then swallowed by O-6, so the practical effect is silent cache staleness.
- **Base ETH/USD** (`0x71041ddd...`): the address is confirmed as Base ETH/USD, but **the heartbeat and deviation threshold could not be verified from an authoritative source in this session** (`data.chain.link` returned HTTP 403 to automated fetches). Base ETH/USD is commonly documented as materially faster than mainnet's (figures around 1200s / 0.15% are frequently cited), which if correct means 3600s accepts answers up to ~3× the heartbeat. **Treat as unconfirmed and verify before relying on it.** The structural point stands regardless: one constant cannot be correct for two feeds with different heartbeats.

**Recommendation**: Move the threshold into `ChainAddrs` next to the feed it describes, with margin:

```rust
pub eth_usd_heartbeat_secs: u64,
// base:     1200,   // VERIFY against docs.chain.link before deploy
// ethereum: 3600,   // confirmed: 0.5% deviation / 3600s heartbeat

let max_age = self.heartbeat_secs + self.heartbeat_secs / 2;
if age > max_age { bail!("feed answer is {age}s old (max {max_age}s)"); }
```

---

## [O-8] `description()` substring check accepts stETH/cbETH/rETH-style derivative feeds

**Severity**: Low
**Category**: oracles
**Location**: off-chain — `oracle.rs:51-56`

**Description**: Two independent substring tests on an uppercased string admit a large family of wrong feeds. All of the following contain both `ETH` and `USD` and pass silently:

- `WSTETH / USD`, `STETH / USD`, `CBETH / USD`, `RETH / USD`, `WEETH / USD`, `EZETH / USD` — liquid-staking derivatives. The checklist calls this out directly: "ETH pricefeeds used for stETH" [beirao CL-13, SigmaPrime]. stETH depegged to 0.93 ETH in June 2022.
- `ETH / USDC`, `ETH / USDT` — `USD` is a substring of `USDC`/`USDT`.
- `USDT / ETH`, `USDC / ETH` — the pair *inverted*, making the price wrong by ~`price²`.

The comment states the intent correctly; the implementation does not achieve it. Because the consumer is a gas estimate on a near-1:1 derivative, realistic error from an LST feed is a few percent — hence Low.

**Proof of Concept**: An operator lands on `WSTETH / USD` (`0x164b276057258d81941e97B0a900D4C7B358bCE0`). `connect()` logs `"ETH/USD oracle connected" feed_description="WSTETH / USD"` and proceeds. wstETH/USD runs ~15-20% above ETH/USD, so every gas cost is overstated and EV-positive rebalances are rejected — a silent one-directional bias with a reassuring startup log line.

**Recommendation**:

```rust
if normalized != "ETH/USD" {
    bail!("feed {feed} is '{description}', expected exactly 'ETH / USD'");
}
```

Also assert `decimals() == 8` for this pair and fail loudly otherwise.

---

## [O-9] No `startedAt`, `answeredInRound`, or `minAnswer`/`maxAnswer` handling

**Severity**: Low
**Category**: oracles
**Location**: off-chain — `oracle.rs:67-83`

**Description**: `price_usd()` destructures the full `latestRoundData()` tuple but validates only two of five fields. Present and correct: the negative-answer check [beirao O-05], the zero-answer check [Decurity CDP], and the `updatedAt` bound (subject to O-7). Missing:

- **`startedAt == 0`** — signals a round that has not started [SigmaPrime]. Note the code compounds this: `updatedAt.try_into().unwrap_or(0)` maps a conversion failure to `0`, producing `age = now`, which trips the staleness bail. That accidentally fails closed — right direction, by coincidence rather than design.
- **`answeredInRound >= roundId`** — secondary staleness signal [beirao O-02]. Deprecated for OCR2-era aggregators, part of why this is Low; still documented defensive practice.
- **`minAnswer` / `maxAnswer` circuit breakers** — the checklist's most emphasised Chainlink item [SigmaPrime, beirao O-04/CL-14, Cyfrin/Venus-Blizz]. When the real price moves outside the aggregator's bounds the feed clamps and reports the bound. The LUNA/USD `minAnswer = $0.10` case is canonical. Reading these requires `aggregator()` on the proxy then `minAnswer()`/`maxAnswer()` on the underlying; the `sol!` block declares neither.

For an ETH/USD feed gating a gas budget the exposure is small — hence Low.

**Recommendation**: Extend the interface and validate the full tuple; resolve `aggregator()` once at connect and cache `min_answer`/`max_answer`, rejecting any answer at or outside those bounds. Replace `updatedAt.try_into().unwrap_or(0)` with an explicit `bail!` so the fail-closed behaviour is intentional.

---

## [O-10] Hardcoded feed / StateView / PoolManager addresses with no override path

**Severity**: Low
**Category**: oracles
**Location**: off-chain — `config.rs:22-44`

**Description**: `ChainConfig::from_name` returns a `match` over compile-time `address!` literals with no environment override, no config-file override, and no runtime update path. Changing any requires a rebuild and redeploy [SigmaPrime "Deprecated feeds"; beirao CL-10; Cyfrin].

All six addresses were sanity-checked against their published values and appear correct (Base and Ethereum PoolManager, StateView, and ETH/USD feed). So this is a latent maintainability and liveness risk rather than a present misconfiguration.

The existing tests only assert that per-chain values *differ from each other* — they would pass just as happily if every address were wrong, providing no protection against a transcription error.

The `eth_usd_feed` comment claims "Verified by `description()` at connect time, so an override that points elsewhere is rejected loudly." Two corrections: there is no override mechanism, and per O-8 the check is a loose substring test. **Runtime `description()` verification is not adequate as written** — tightened per O-8 it would be reasonable for the feed specifically, but it does nothing for `state_view` or `pool_manager`, neither of which is validated at all.

**Recommendation**: Allow per-field environment overrides layered over compiled defaults, so a deprecated feed can be replaced by restarting rather than shipping a binary. Pair with the exact-match `description()` check and a `decimals() == 8` assertion. For `state_view`/`pool_manager`, add a startup probe that fails loudly if the address does not behave like the expected contract. Replace the "differs per chain" tests with assertions against the literal expected addresses so a typo fails CI.

---

## [O-11] `_afterSwap` publishes the manipulable spot tick as the automation trigger; cooldown may be 0

**Severity**: Low
**Category**: oracles
**Location**: on-chain — `_afterSwap()` AutopilotHook.sol:127-139; constructor `:113-121`; `rebalance()` `:235-236`

**Description**: The hook's sole enabled permission is `afterSwap`, and its body is a spot read and an emit. This makes the contract an active *publisher* of instantaneous spot prices to an automated consumer — the on-chain half of the homegrown oracle in O-3. Anyone able to swap can emit an `AutopilotCheck` carrying a tick of their choosing, and `poolPositionCount[id] > 0` tells them for free whether the pool is watched. The event's `positionCount` also discloses how many positions are exposed.

On throttling, the constructor accepts any `cooldown <= MAX_REBALANCE_INTERVAL` — **including 0** — and `setMinRebalanceInterval` is equally permissive. At `0` there is no on-chain limit on induced churn; the only remaining throttle is the bot's in-memory `min_interval`, which is per-process and lost on restart. The deploy script does default to 3600s, so the realistic deployment is throttled — hence Low. Also note `lastRebalanceAt` is initialised to `0` at deposit, so the *first* rebalance after any deposit is always immediately available regardless of the cooldown setting.

**Recommendation**: Enforce a non-zero floor in both the constructor and the setter, set `lastRebalanceAt = uint64(block.timestamp)` at deposit, and consider dropping `tick` from `AutopilotCheck` entirely — the bot already decodes the pool's own `Swap` event for the tick, so the hook pays gas on every swap to publish a redundant value.

---

## [O-12] Feed `decimals()` and `description()` read once at connect and never re-validated

**Severity**: Info
**Category**: oracles
**Location**: off-chain — `oracle.rs:44-64`, `:78-82`

**Description**: Recorded primarily to credit what is done correctly. **Decimal handling is correct**: `connect()` calls `agg.decimals()` and `price_usd()` scales dynamically with `raw / 10f64.powi(self.decimals as i32)`. No hardcoded `1e8`/`1e18` anywhere — this correctly handles the AMPL/USD-style exception where a USD feed uses 18 decimals [beirao O-07/CL-09, Cyfrin].

Two minor observations, neither with security impact here:

1. **Read-once against a mutable proxy.** Chainlink `EACAggregatorProxy` can be repointed. In practice decimals and description are preserved across migrations, so this is theoretical, but a long-running daemon would not notice a change.
2. **`i256` → `f64` via string.** `round.answer.to_string().parse::<f64>()` — `f64` carries ~15-16 significant digits, so an 8-decimal ETH/USD answer (10-11 digits) is exact. Inefficient rather than incorrect.

**Recommendation**: Optional — re-read `decimals()` inside the refresher and treat a change as fatal rather than silently rescaling. Combine with the O-8 exact-match check so a proxy repoint to a different pair is caught on the next refresh.

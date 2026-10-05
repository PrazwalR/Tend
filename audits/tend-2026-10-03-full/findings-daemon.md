# Findings — daemon security (`crates/lpa`, full audit, f993a76)

PoCs: `crates/lpa/src/audit_dm_tests.rs`, plus `crates/lpa/tests/fixtures/evil_rpc.py`, a lying
JSON-RPC proxy in front of a plain local anvil. The anvil tests are `#[ignore]`d; run them with
`cargo test -p lpa audit_dm -- --ignored --test-threads=1 --nocapture`. DM-1 and DM-2 were re-run
independently during synthesis and reproduced against unchanged daemon code.

| ID | Severity | Title | PoC |
|---|---|---|---|
| DM-1 | **High** | The signed transaction's fees and chain id come from the submit RPC or relay, not the spend cap | reproduced: $7,047 paid against a $50 cap; tx signed for chain 1 |
| DM-2 | **High** | One dropped send leaves a nonce gap that blocks every later transaction until restart | reproduced: nonce stuck at 0 after 3 attempts |
| DM-3 | **Medium** | `lpa serve` is unauthenticated by default and can delete positions the watcher manages | reproduced (real binary + curl) |
| DM-6 | **Medium** | Dust positions make every Swap cost thousands of SQLite commits on the log path | reproduced: 724 ms per swap at 2,000 positions |
| DM-4 | Low | A tiny feed answer truncates the ETH price to 0 while still counting as fresh, zeroing the caps | reproduced |
| DM-5 | Low | `StreamPositions` leaks its polling task when no requested id matches | reproduced: 100 tasks after 100 disconnects |
| DM-7 | Low | Ticks from the API or CLI aren't range-checked: debug builds panic, release builds wrap | reproduced |
| DM-8 | Low | RPC API keys in URLs end up in error logs | reproduced |
| — | Info | dotenv walks up parent dirs; key not zeroized; executor task unsupervised; budget records the estimate; per-position configs ignored; API-registered ids never match the hook's; migration errors swallowed; 4 `cargo audit` advisories (h2, rustls, quinn-proto, ruint) | — |

## [DM-1] Signed fees and chain id come from the submit RPC
**Severity**: High
**Location**: `exec/mod.rs`: `Executor::connect` (`ProviderBuilder::new().wallet(..)`), `execute` /
`poke` → `.send()`; `check_spend`
**Description**: `check_spend` prices the transaction as gas × `eth_gasPrice` from the primary RPC.
The transaction that actually gets signed has its fields filled by alloy's fillers on the `submit`
provider: the relay when `FLASHBOTS_RPC` is set, otherwise the primary RPC. The priority fee comes from
`eth_feeHistory` with no upper bound, and `chainId` comes from that RPC's `eth_chainId`. The signed
fields are never compared with what was capped. The `to` address and calldata are built locally, so
the RPC can't redirect the call.
**Impact**: Whoever runs the RPC or relay picks the priority fee. One transaction can spend up to the
hot wallet's whole balance, past both the per-transaction cap and the hourly budget. If the relay is
also a builder, it keeps that fee. It can also get transactions signed for another chain.
**PoC**: `audit_dm1_relay_sets_priority_fee_past_spend_cap`: `cap $50, gas_used 23490,
effective_gas_price 100001000000000 wei, paid $7047.07`. `audit_dm1b_chain_id_comes_from_the_rpc`:
`captured tx signed for chain_id Some(1)`.
**Recommendation**: Set the gas limit, `maxFeePerGas` and `maxPriorityFeePerGas` explicitly from the
values `check_spend` approved. Cap the priority fee absolutely, and check `gasLimit × maxFee` (the
worst case) against the cap. Fix the chain id from config and assert `eth_chainId` on both providers
at startup.

## [DM-2] A dropped send leaves a nonce gap that blocks everything until restart
**Severity**: High (permanent DoS of automation until a manual restart)
**Location**: alloy's default `NonceFiller<CachedNonceManager>`, used by `Executor::connect`
**Description**: The cached nonce manager adds 1 for every transaction it fills, whether or not that
transaction is ever mined. A relay that accepts a transaction and never includes it (Flashbots Protect
drops ones that would revert), or a send that errors after the fill, uses up the nonce anyway. Every
later transaction then waits behind the gap, ends `Unconfirmed`, and takes the next nonce, so the gap
never closes. The DS-7 timeouts don't reset the nonce.
**PoC**: `audit_dm2_one_dropped_send_gaps_the_nonce_for_good`: 3 attempts end unconfirmed, and the
on-chain nonce stays 0.
**Recommendation**: Set the nonce from `eth_getTransactionCount(pending)` on the primary RPC, or use
`SimpleNonceManager`. After an `Unconfirmed` result, re-read the nonce, and replace or cancel the
stuck transaction.

## [DM-3] `lpa serve` is unauthenticated by default
**Severity**: Medium. `LPA_API_TOKEN` is optional, and `.env.example` ships it empty.
`DeregisterPosition` deletes the row that `watch` uses, and nothing ever re-indexes it.
`RegisterPosition` can overwrite rows. There's no `Host` check, so DNS rebinding against 127.0.0.1 is
plausible. The Dockerfile's `CMD serve` pushes operators toward binding 0.0.0.0.
**PoC**: An unauthenticated grpc-web `DeregisterPosition` returns 200 and the row count goes from 1
to 0. With the token set, the same call gets `grpc-status 16`.
**Recommendation**: Refuse to start without a token unless `--insecure-no-auth` is given. Validate
`Host`. Keep hook-sourced positions out of the API's reach.

## [DM-6] Dust positions slow the log path
**Severity**: Medium. Each Swap runs one autocommit `UPDATE` per position in the pool while holding the
tracker mutex, and `propose_rebalance` runs inline for every position the swap moves out of range,
with up to 4 RPCs each.
**PoC**: `audit_dm6_swap_cost_scales_with_dust_positions`: one Swap with 2,000 positions takes 724 ms.
**Recommendation**: Do the update as one statement in one transaction, move proposals off the log path,
and use WAL mode.

## [DM-4] A tiny feed answer zeroes the caps
**Severity**: Low. `(usd * 1e6) as u64` truncates to 0, but freshness is still stamped, so
`get_fresh() = Some(0.0)` and every transaction prices at $0.
**Recommendation**: Reject answers outside a plausible band, and never stamp freshness on a value that
rounds to 0.

## [DM-5] StreamPositions task leak
**Severity**: Low. The task only notices a disconnected client when a send fails, so with no matching
ids it polls forever. Exit on `tx.closed()` and cap concurrent streams.

## [DM-7] Unchecked ticks from the API or CLI
**Severity**: Low. An i32 tick outside the int24 range overflows the arithmetic: debug builds panic at
`strategy/mod.rs:195`, release builds wrap. Validate ticks at every entry point.

## [DM-8] API keys in logs
**Severity**: Low. Transport errors print the full URL, path included. Redact before logging.

## Verified correct
- O-5/O-6 (fresh ETH price required), DS-2 (floor of 0), DS-4 (in-flight dedupe, refusal
  classification, rotation), DS-5 (concurrent sweep, backfill-driven watermark), DS-6 (receipt status
  checked), DS-7 (iteration timeout), DS-8 (map pruning) and DS-9 (pending block) all hold.
- The private key is never logged, and a malformed key's parse error doesn't echo it
  (`audit_dm_key_parse_error_does_not_echo_the_key`).
- No `unwrap` on RPC data reachable in release builds. Every SQL query is parameterized.
- With a token set, auth is enforced correctly: a constant-time compare and a 127.0.0.1 default bind.

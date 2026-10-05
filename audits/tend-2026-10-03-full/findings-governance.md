# Findings — governance, timelock, deployment, Base specifics (full audit, f993a76)

PoCs: `contracts/test/audit/full/GovernancePoC.t.sol` (8 tests, passing), plus deploy-script runs on a
plain local anvil (chain ids 31337 and 8453) using anvil's default keys only. Checklists:
evm-audit-governance, evm-audit-chain-specific.

No Medium-or-above finding.

| ID | Severity | Title | PoC |
|---|---|---|---|
| GV-1 | Low | The deploy script accepts any contract that returns the right `description()` as the sequencer feed, and deploys on Base with no feed at all | anvil transcript |
| GV-2 | Low | The selector-keyed queue means an emergency removal cancels an unrelated queued addition (same as CO-4) | reproduced |
| GV-3 | Info | With fee and spacing unset, the deploy script lists a pool key that can never exist, and the post-check passes | reproduced |
| GV-4 | Info | On op-geth/op-reth `pending` defaults to `latest`, which weakens the DS-9 preflight fix (delays only) | reproduced (N vs N+1) |
| GV-5 | Info | The allowlist is off between the deploy transaction and the enforce transaction | n/a |
| GV-6 | Info | Constructor emits no `MaxSwapImpactBpsSet`; `HOOK_OWNER=0` accepted; `POOL_MANAGER` not code-checked; E2E doesn't use the production deploy path; stability window counted in blocks | anvil runs |

## [GV-1] Sequencer feed is checked only by its description
**Severity**: Low. A `FakeSequencerFeed` returning "L2 Sequencer Uptime Status Feed" was accepted, and a
third party could then set its answer. On chain id 8453, a deploy with no feed succeeded with no
warning. Replacing a feed afterwards takes the 2-day queue.
**Recommendation**: Pin the feed per chain (Base: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`), and
require a non-zero feed on known L2 chain ids.

## [GV-2] Emergency removal cancels an unrelated pending addition
**Severity**: Low (operational). `test_GV1_emergency_removal_cancels_unrelated_queued_addition`. Key
`setRebalancer` entries by (selector, address), or document the behaviour.

## [GV-3] A pool key that can never exist gets listed
**Severity**: Info. Deposits fail closed (`test_GV3_allowlist_accepts_uninitialisable_key`). Require
fee and spacing whenever the tokens are set, and reject `tickSpacing <= 0` in `setAllowedPool`.

## [GV-4] `pending` on Base nodes
**Severity**: Info. If `pending` is just `latest`, an honest 300-tick move is refused in block N but
passes in block N+1 (`test_GV4_latest_vs_next_block_preflight_diverge`). This only delays rebalances; no
false pass was found. Base nodes' actual behaviour was not checked (no Base RPC allowed).
**Recommendation**: Simulate with a block-number override.

## [GV-5] Allowlist window at deploy
**Severity**: Info. Start with `allowlistEnforced = true` in the constructor.

## Verified correct
- TL-1: the per-block step change is queued in both directions. TL-2: a non-canonical encoding of the
  exact length never executes, because the decoder reverts. TL-3: `msg.sig` is correct on every
  direct call, and executing a change leaves other setters' pending changes intact. TL-4: the epoch is
  bumped on the constructor and on `acceptOwnership`, not on a pending transfer, and a pending owner
  has no powers. TL-7: the unused constant is gone.
- No instant path to a looser state through any of the six setters. Withdraw is never gated. The
  sequencer feed's gas cap can't be starved into failing open.
- Deploy script signers: `--private-key`, `--unlocked --sender` and a **keystore** (closing the gap
  noted in the 10-03 report) all leave the right owner. A mismatched sender and key is refused before
  broadcast. The handover voids the old queue.

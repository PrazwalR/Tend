# Findings — token handling, settlement, deploy configuration

PoCs: `contracts/test/audit/TokenPoC.t.sol` (5 tests, passing), plus a configurable mock token
`contracts/test/mocks/WeirdERC20.sol` (pause, blacklist, ERC777-style callback, negative rebase).
The deploy script was exercised on a plain local anvil. Checklists: evm-audit-erc20,
evm-audit-general.

| ID | Severity | Title | PoC |
|---|---|---|---|
| TK-1 | **Medium** | Deploy script skips configuration whenever the signer isn't a plain `--private-key` | reproduced on anvil |
| TK-2 | Low | Daemon values positions without their idle balance (or fees) | by inspection |
| TK-3 | Info | Claims donated to the hook are stranded (harmless) | test passes |
| TK-4 | Info | Idle claims share the PoolManager-wide rebasing exposure (T-3 unchanged) | test passes |
| TK-5 | Info | Stale NatSpec, and no event when withdraw releases idle | n/a |

## [TK-1] Deploy script skips configuration whenever the signer isn't a plain `--private-key`
**Severity**: Medium. The T-3/T-4 allowlist and the L2 sequencer guard look deployed and aren't.
**Location**: `contracts/script/DeployAutopilotHook.s.sol` (the `hookOwner == msg.sender` branch)
**Description**: Foundry sets the script's `msg.sender` to the signer only when it can infer it from
`--private-key`. With `--keystore`, `--account` or a hardware wallet and no `--sender`, `msg.sender`
stays Foundry's DefaultSender `0x1804c8AB…`, while `vm.startBroadcast()` signs with the keystore.
- **Keystore signer, `HOOK_OWNER` set to that same address:** all three config calls are skipped. The
  script reports success and logs the false "Owner is not the deployer". The hook goes live with the
  allowlist off and no sequencer feed.
- **Multisig owner (the recommended production setup):** the script never configures the hook. It is
  live and unprotected until the multisig sends three transactions.
- **Keystore signer, `HOOK_OWNER` unset:** the owner defaults to DefaultSender, which nobody can use
  (CRIT-2 again). It is caught only by accident, because the owner-only setter reverts during
  simulation. `require(hook.owner() == hookOwner)` compares the owner to the value just passed in,
  so it can never fail.
**PoC**: On anvil with `--keystore` and `HOOK_OWNER` set to the keystore address, the run reports
success and on-chain shows `allowlistEnforced=false`, `sequencerFeed=0x0`, pair not listed. The
multisig case gives the same result. With `HOOK_OWNER` unset, the run fails with
`OwnableUnauthorizedAccount` and nothing is broadcast.
**Recommendation**: Get the real broadcaster with `vm.readCallers()` after `startBroadcast`. Always
deploy with the broadcaster as owner, configure, then `transferOwnership(HOOK_OWNER)` and have the
multisig `acceptOwnership`. Assert the resulting configuration, not the always-true owner check.

## [TK-2] Daemon values positions without their idle balance
**Severity**: Low. `position_value_usd` (crates/lpa/src/chain/subscriber.rs) prices only the deployed
amounts, ignoring `idle()` and the uncollected fees `position_snapshot` already returns. Positions with
large idle balances pass the off-chain EV gate more easily than they should. On-chain guards are
unaffected.

## [TK-3] Claims donated to the hook are stranded
**Severity**: Info. Anyone can send ERC-6909 claims to the hook. They affect no position and can't be
recovered (`test_claims_back_idle_across_pools_and_donation_is_inert`). `withdraw(pid, address(hook),
true)` strands the user's own payout the same way. Optionally reject `recipient == address(this)`.

## [TK-4] Idle claims share the rebasing exposure
**Severity**: Info. This is the same as T-3. Only the timing changed: the remainder used to be paid out
and now stays in the PoolManager until the next rebalance or withdraw
(`test_negative_rebase_leaves_claims_exit_underbacked`). Keep the allowlist enforced, which TK-1
currently undermines.

## [TK-5] Stale NatSpec, and no event when withdraw releases idle
**Severity**: Info. The `RebalanceResidual` doc and the `_swapToRatio` comments still describe a
payout. Withdraw releases idle silently. `RebalanceResidual` is never emitted with zeros, so an
event-based indexer can't see idle return to zero.

## Verified correct
- Per currency, hook claims equal the sum of `idle` plus donations, across two pools sharing the same
  currencies. The hook grants no operator or allowance.
- Withdraw pays liquidity plus idle in the right currencies, as tokens or as claims. With a paused
  token, the claims exit still pays the full idle balance.
- A rebalance makes no ERC-20 transfer, so a blacklisted or paused owner can still be rebalanced and
  can exit to another address.
- Native ETH and fee-on-transfer tokens are still rejected at deposit. No `decimals()` assumptions.
- An ERC777-style callback during the withdraw payout gets `ReentrancyGuardReentrantCall` when
  re-entering withdraw, rebalance or deposit. State seen mid-payout is already final.

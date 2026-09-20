# Independent verification by the synthesis step

Two agent findings were re-tested directly rather than taken on trust. Both confirmed.

## 1. Bricked ownership on real deployment — CONFIRMED (raises G-2 to Critical)

Claim: `Ownable(msg.sender)` in the constructor makes the CREATE2 factory the owner,
because `HookMiner` requires deployment through `0x4e59b448...` and Forge routes a
salted `new` through that factory when broadcasting.

Reproduced on a local anvil using the project's own unmodified deploy script
(`script/DeployAutopilotHook.s.sol`), deployer EOA `0xf39Fd6e5...`:

    AutopilotHook deployed at 0x5df4140dbB9391Dff4a6Ae2456D2eEBEB2a58040
    owner()       = 0x4e59b44847b379578588920cA78FbF26c0B4956C   <- the CREATE2 factory
    deployer EOA  = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    isRebalancer(0x7099...) = true

    cast send $HOOK 'pause()' --private-key <deployer>
    -> revert OwnableUnauthorizedAccount(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)

Consequence: `pause()`, `unpause()`, `setRebalancer()`, `setMinRebalanceInterval()`
and `transferOwnership()` are permanently unreachable on any hook deployed this way.
`renounceOwnership()` reverts by design. The rebalancer set at construction can never
be revoked and the contract can never be paused.

This removes both safety valves that the other findings assume exist as mitigations.

Why the test suite misses it: `AutopilotHook.t.sol` uses `deployCodeTo(...)`, which sets
`msg.sender = address(this)`, so the test owner is the test contract. The tests
structurally cannot observe the production deployment path.

## 2. Cooldown does not apply to the first rebalance — CONFIRMED

Claim: `lastRebalanceAt` starts at 0, so `readyAt = minRebalanceInterval` (<= 31_536_000),
which is always below a real chain's `block.timestamp` (~1.75e9). The existing test only
passes because Foundry's default `block.timestamp` is 1.

Reproduced with no code change, using forge's clock override:

    forge test --match-test test_rebalance_cooldown_enforced
    -> [PASS]

    forge test --match-test test_rebalance_cooldown_enforced --block-timestamp 1758300000
    -> Suite result: FAILED. 0 passed; 1 failed

The test asserts a property the deployed contract does not have.

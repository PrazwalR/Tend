# Tend — LP Position Autopilot

Automated rebalancing for Uniswap v4 concentrated-liquidity positions. A Rust
daemon monitors positions over a WebSocket RPC, decides when to rebalance using
a volatility-aware strategy with an EV gate, and executes the move on-chain
through a custom v4 hook — with a spend cap, slippage floor, preflight
simulation, and optional private-orderflow submission.

> Status: research. An internal multi-agent audit is in
> [`audits/tend-2026-09-20/`](audits/tend-2026-09-20/AUDIT-REPORT.md); both
> Criticals, all five Highs and most Mediums are fixed. The fixes have **not**
> been re-audited, and the hook has never been professionally audited. Do not use
> with real funds. See [Security](#security).

## Why

Concentrated liquidity earns fees only while the pool price sits inside a
position's tick range. When price drifts out, the position stops earning, sits
100% in the worse-performing token, and realizes impermanent loss. Manual
rebalancing is gas-heavy and easy to get wrong ("chasing the price"). Tend does
it automatically, only when it is expected-value positive.

## Architecture

```
chain WS ──► monitor ──chan──► strategy ──chan──► executor ──► AutopilotHook.rebalance()
                 │                                                    ▲
                 ├──► SQLite (positions, tick history, configs)       │
                 └──► indexes hook events (Opened/Closed/Rebalanced)  on-chain

  lpa serve ──► tonic + tonic-web ◄──── Connect-ES TS SDK ◄──── dashboard / app
```

A single Rust binary (`lpa`) runs the monitor, strategy, and executor in one
process, wired by in-process channels. The only network surface is `lpa serve`
(gRPC + gRPC-web, bearer-token auth) for the TypeScript SDK.

- **Monitor** — alloy WS subscription to the v4 `PoolManager` `Swap` event and
  the hook's position events; SQLite tracks positions and per-block tick history.
  A per-chain watermark plus an `eth_getLogs` backfill closes the gap after a
  restart; reorged position events resync from the hook's own storage. In
  auto-execute mode a periodic sweep retries every out-of-range position, and a
  rebalance refused because spot has run ahead of the hook's price reference
  triggers a `pokePriceRef` to walk the reference back within tolerance.
  Whatever a rebalance's bounded swap could not place stays with the position
  as an idle balance in the hook; the sweep places it back with a same-range
  rebalance once it is worth a transaction, and `withdraw` pays it out.
- **Strategy** — concentrated-LP impermanent-loss, block-sampled Bollinger
  bands, and an expected-value gate
  (`E[fee gain] + E[IL avoided] − gas − slippage − MEV > 0`). Expected IL is
  integrated over the horizon's terminal tick distribution, not point-estimated,
  because IL is convex in price.
- **Executor** — alloy signer; preflight `eth_call` against the pending block,
  hard gas estimate, per-transaction USD cap and a rolling hourly budget,
  receipt timeout, optional private RPC. Refusals are classified by the hook's
  error: a lagging price reference is poked, a terminal refusal suppresses the
  position for hours, anything else backs off exponentially.
- **`AutopilotHook.sol`** — v4 hook that custodies liquidity and moves ranges
  via PoolManager flash accounting. Ownable2Step, ReentrancyGuard, pausable,
  per-position tick envelope, rebalancer allowlist with per-position scoping,
  cooldown floor, protocol-enforced value floor, a truncated per-pool price
  reference, an optional L2 sequencer check, and a pool allowlist (full pool
  keys; the deploy script enforces it).

## Layout

```
crates/lpa/        Rust daemon (chain, position, strategy, exec, serve)
contracts/         Foundry: AutopilotHook.sol + tests + deploy scripts
packages/sdk/      TypeScript Connect-ES client + React hook
proto/             autopilot.proto — single source of truth (Rust + TS codegen)
```

## Quick start

Requires Rust 1.96, Foundry, Node 22.

```bash
cp .env.example .env            # fill in RPC URLs (WS required)

# Rust daemon
cargo build --release
cargo test --workspace

# Contracts
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/uniswap-hooks --no-commit
forge test
cd ..

# SDK
cd packages/sdk && npm ci && npm run generate && npm run build
```

## CLI

Global flags: `--config <path>` (TOML), `--log-format json|pretty`.

| Command | Purpose |
|---|---|
| `lpa serve [--host --port --db --chain --hook --insecure-no-auth]` | gRPC(-web) API for the SDK. Requires `LPA_API_TOKEN` (bearer auth) and refuses to start without it unless `--insecure-no-auth`; `--hook` enables on-chain position enrichment |
| `lpa watch [--chain --hook --db --execute]` | monitor a chain; `--execute` sends real rebalance txs for indexed positions |
| `lpa register --pool-id --owner --tick-lower --tick-upper [--fee --tick-spacing]` | track a position off-chain (for monitoring: its id is not a hook position id, so it is never rebalanced) |
| `lpa simulate --position-id` | dry-run the strategy on a stored position |
| `lpa rebalance --position-id --new-lower --new-upper --hook [--dry-run]` | preflight or execute a single rebalance |
| `lpa config init\|show\|path` | manage the TOML config file |

Config precedence: CLI flag > env var > config file > built-in default. Environment
variables are read from `./.env` in the working directory only, never from a parent
directory. A strategy config stored for a position with `UpdateConfig` overrides the
default for that position, including a lower `max_gas_usd` spend cap.

## Deploy the hook

The hook address must encode its permission bits, so it is deployed via CREATE2
with a mined salt (`HookMiner`). Deploy to a testnet first:

```bash
cd contracts
POOL_MANAGER=$POOL_MANAGER REBALANCER_ADDRESS=$REBALANCER_ADDRESS \
forge script script/DeployAutopilotHook.s.sol:DeployAutopilotHook \
  --rpc-url $RPC_TESTNET --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
```

Put the deployed address in `AUTOPILOT_HOOK_ADDRESS`.

## Security

- **Never commit secrets.** `.env` is gitignored; use `.env.example` as the
  template. `REBALANCER_PRIVATE_KEY` in `.env` is for testnet only — use a
  keystore or external signer in production.
- **Trust model.** The rebalancer key is trusted but only *partly* bounded. It
  cannot withdraw funds and cannot move a position outside the owner-set tick
  envelope. It can still churn a position inside that envelope, paying the pool
  fee each cycle — an audit measured ~0.3%/cycle. The envelope bounds where a
  position sits, not what a rebalance does to it. `minLiquidity` is **not** a
  safety valve: it is supplied by the rebalancer itself and bounds a liquidity
  number rather than value. Pause and the cooldown do work as described.
  See [`audits/`](audits/) for the full picture before trusting a rebalancer key.
- **serve** binds `127.0.0.1` by default and requires a bearer token
  (`LPA_API_TOKEN`) on every RPC when set.
- The executor's spend cap uses a live gas price **and** the chain's Chainlink
  ETH/USD feed, verified by `description()` at connect and rejected when stale.
  The cap requires a *fresh* read and refuses to send a transaction without one,
  so a dead feed gates spending off rather than pricing it against a stale
  constant. `ETH_PRICE_USD` is only a seed for the strategy's estimate.
- Pool volume (`LPA_VOLUME_USD_PER_BLOCK`) and token1's USD price
  (`LPA_TOKEN1_USD`) remain operator assumptions. Without the latter a position
  cannot be valued, and the EV gate runs fee-and-gas only rather than guessing
  at IL and friction.
- Position liquidity, token amounts and uncollected fees are read from the v4
  `StateView` lens. Without `--hook` (or an HTTP RPC) those fields stream empty
  rather than guessed.

## Owner powers

Owner changes that **loosen** a protection wait out a 2-day timelock: adding a
rebalancer, raising the loss tolerance or swap-impact bound, widening the
deviation window, changing the price reference's per-block step **in either
direction** (slowing it freezes the reference), shortening the cooldown, and
replacing the sequencer feed. Queue the change with
`queueChange(abi.encodeCall(...))` and run it with `executeChange` between 2 and 16
days later. One change can be pending per setter (per address, for `setRebalancer`);
queuing again replaces it, an instant change to the same setter (or address)
cancels it, and an ownership transfer voids the whole queue. `changeKey(call)`
gives the slot a call occupies, and `cancelChange(key)` takes it. Tightening, pausing and the pool allowlist take effect at once.
Withdraw is never gated, so a depositor who disagrees with a queued change can leave
before it applies. Undoing a tightening is itself a loosening and waits too — in an
emergency, `pause` is the lever that can be reversed at once.

## Manipulation guards

A rebalance runs only when the hook's price reference has stayed within
`maxDeviationTicks` (200) of one level, unclamped, for five consecutive block
ends (`MIN_STABLE_BLOCKS`), and spot is within 200 ticks of it. A reference walked
in steps — even steps small enough never to be clamped — restarts the count each
time it leaves that band. The rebalance's cost — swap fee, price impact and where
the new range is placed — is measured as the position's value at the reference
price before versus after, and must stay within `maxRebalanceLossBps`.

What remains is an attacker able to hold a pushed level against arbitrage for
five consecutive block ends (about 10 s on Base): the reference then sits there,
and every guard measures from it. The cost to honest users: after a price move
faster than about 200 ticks per five blocks, rebalances wait until price has held
still. See `audits/tend-2026-10-03-full/AUDIT-REPORT.md`.

## Deposits

`deposit(key, lower, upper, liquidity, minBound, maxBound, rebalancer,
amount0Max, amount1Max, deadline)`. The token amounts a liquidity target needs
depend on spot when the transaction executes, so quote `amount0Max`/`amount1Max`
off-chain (the amounts at the current price plus a small margin): a deposit that
would pull more reverts with `DepositExceedsMax` instead of being sandwiched.

## Range orders

The daemon rebalances every out-of-range position toward spot, including one opened
out of range on purpose. To keep a range order, open it with automation off:
`deposit(..., rebalancer = AUTOMATION_OFF, ...)`, or call
`setPositionRebalancer(positionId, AUTOMATION_OFF)` afterwards.

## End-to-end

`scripts/e2e.sh` runs the whole loop against an anvil fork of Base: deploy the
hook, start the daemon, open a position, swap the price out of range, and
assert the daemon sends a real rebalance tx that moves the range on-chain. It
also restarts the daemon across a deposit to prove the watermark and backfill
recover it. Needs `RPC_BASE`; skips cleanly without one.

```bash
RPC_BASE=https://... ./scripts/e2e.sh
```

## Development

`cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test`,
`forge test`, `npm run typecheck`. CI runs all of these
([.github/workflows/ci.yml](.github/workflows/ci.yml)).

## License

[MIT](LICENSE).

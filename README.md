# Tend — LP Position Autopilot

Automated rebalancing for Uniswap v4 concentrated-liquidity positions. A Rust
daemon monitors positions over a WebSocket RPC, decides when to rebalance using
a volatility-aware strategy with an EV gate, and executes the move on-chain
through a custom v4 hook — with a spend cap, slippage floor, preflight
simulation, and optional private-orderflow submission.

> Status: research. An internal multi-agent audit is in
> [`audits/tend-2026-09-20/`](audits/tend-2026-09-20/AUDIT-REPORT.md); its two
> Critical findings are fixed, the remaining Highs are not. The hook has not been
> professionally audited. Do not use with real funds. See [Security](#security).

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
  restart; reorged position events resync from the hook's own storage.
- **Strategy** — concentrated-LP impermanent-loss, block-sampled Bollinger
  bands, and an expected-value gate
  (`E[fee gain] + E[IL avoided] − gas − slippage − MEV > 0`). Expected IL is
  integrated over the horizon's terminal tick distribution, not point-estimated,
  because IL is convex in price.
- **Executor** — alloy signer; preflight `eth_call`, hard gas estimate, USD
  spend cap, slippage floor, receipt timeout, optional private RPC.
- **`AutopilotHook.sol`** — v4 hook that custodies liquidity and moves ranges
  via PoolManager flash accounting. Ownable2Step, ReentrancyGuard, pausable,
  per-position tick envelope, rebalancer allowlist, cooldown.

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
| `lpa serve [--host --port --db --chain --hook]` | gRPC(-web) API for the SDK (bearer auth via `LPA_API_TOKEN`); `--hook` enables on-chain position enrichment |
| `lpa watch [--chain --hook --db --execute]` | monitor a chain; `--execute` sends real rebalance txs for indexed positions |
| `lpa register --pool-id --owner --tick-lower --tick-upper [--fee --tick-spacing]` | track a position off-chain |
| `lpa simulate --position-id` | dry-run the strategy on a stored position |
| `lpa rebalance --position-id --new-lower --new-upper --hook [--dry-run]` | preflight or execute a single rebalance |
| `lpa config init\|show\|path` | manage the TOML config file |

Config precedence: CLI flag > env var > config file > built-in default.

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

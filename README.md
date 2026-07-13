# Tend — LP Position Autopilot

Automated rebalancing for Uniswap v4 concentrated-liquidity positions. A Rust
daemon monitors positions over a WebSocket RPC, decides when to rebalance using
a volatility-aware strategy with an EV gate, and executes the move on-chain
through a custom v4 hook — with a spend cap, slippage floor, preflight
simulation, and optional private-orderflow submission.

> Status: research / pre-audit. The hook has not been professionally audited.
> Do not use with real funds on mainnet. See [Security](#security).

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
- **Strategy** — concentrated-LP impermanent-loss, block-sampled Bollinger
  bands, and an expected-value gate (`E[fee gain] − E[IL] − cost > 0`).
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
| `lpa serve [--host --port --db]` | gRPC(-web) API for the SDK (bearer auth via `LPA_API_TOKEN`) |
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
- **Trust model.** The rebalancer key is trusted but *bounded*: it can only
  reposition a position within the owner-set tick envelope and cannot withdraw
  funds. Cooldown, pause, and the slippage floor are the safety valves.
- **serve** binds `127.0.0.1` by default and requires a bearer token
  (`LPA_API_TOKEN`) on every RPC when set.
- The strategy's USD volume input is an operator assumption pending a price
  oracle; the executor's spend cap uses a live gas price.

## Development

`cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test`,
`forge test`, `npm run typecheck`. CI runs all of these
([.github/workflows/ci.yml](.github/workflows/ci.yml)).

## License

[MIT](LICENSE).

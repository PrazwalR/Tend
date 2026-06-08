# LP Autopilot — Build Roadmap

Status: planning locked, no code yet. Build is strictly phased; each phase ends in build → test → audit → commit.

## Locked architecture (v1)

- **Single Rust binary `lpa`** holds monitor + strategy + executor in one process. No internal gRPC; monitor → strategy → executor communicate via in-process channels.
- **gRPC exists in exactly one place**: `lpa serve` exposes a `tonic` + `tonic-web` server (the `AutopilotStrategy` service) for the TS SDK and any dashboard. This is the only network surface.
- **TS SDK** (`@lp-autopilot/sdk`) is a thin Connect-ES client to `lpa serve`. React hooks via Connect-Query.
- **AutopilotHook.sol** stays in v1: `afterSwap` emits `AutopilotTriggered`; `rebalance()` is called by the executor hot wallet and moves liquidity via PoolManager flash accounting.
- **Persistence**: SQLite (position registry + tick history) so restarts don't wipe state.
- Proto (`proto/autopilot.proto`) is the single source of truth for Rust (`tonic-prost-build`) and TS (`buf` + `protoc-gen-es`).

```
chain WS ──► monitor ──chan──► strategy ──chan──► executor ──► AutopilotHook.rebalance()
                 │                                                    ▲
                 └──► SQLite (positions, tick history)                │
                                                                 on-chain
  lpa serve ──► tonic + tonic-web ◄──── Connect-ES TS SDK ◄──── dashboard / app
```

## Stack pins (June 2026)

| Component | Spec said | Use instead |
|---|---|---|
| alloy | 0.3 | **1.7.x** (`.connect_ws(WsConnect::new(url))`, not `.on_ws`) |
| tonic | 0.12, tonic-build | **0.14.x**, **`tonic-prost-build`**; maintenance-mode CNCF crate |
| grpc-web bridge | Envoy / grpc-web-proxy | **`tonic-web`** layer — no proxy box |
| TS transport | `@protobuf-ts/grpcweb-transport` | **Connect-ES** (`@connectrpc/connect-web`) + `buf` codegen |
| React | hand-rolled `usePosition` stream | **Connect-Query** hooks |

## Corrections to fold in

1. **IL formula**: spec uses the v2 full-range formula `2√r/(1+r)−1`. Replace with concentrated-liquidity IL (bounded, range-aware) for the IL guard.
2. **Bollinger sampling**: sample one tick per block (or a TWAP tick), not per-swap — per-swap over-weights high-activity windows. Persist the window.
3. **EV gate**: gate rebalances on `expected_fee_gain − IL_avoided > gas + slippage + MEV`, not just `gas_usd < max`.
4. **Addresses config-driven** per chain (PoolManager, StateView, PositionManager differ across Ethereum/Base/Arbitrum).
5. **Key safety**: keystore / external signer, private-orderflow RPC (Flashbots), pre-flight `eth_call` simulation, per-position spend caps. Raw key in `.env` is testnet-only.

## Process rules

- Docs `.md` (e.g. `uniswapv4.md`) are gitignored, never committed/pushed.
- Each phase ships its own `.env.example` additions (keys only, no secrets).
- Near-zero comments in code.
- Audit each feature before moving on; never bundle phases.

## Phases

**P0 — Scaffolding.** Cargo workspace, foundry init, packages/sdk init, `.gitignore`, `.env.example`. Commit skeleton.

**P1 — Proto + codegen + walking skeleton.** `autopilot.proto`; Rust codegen via `tonic-prost-build`; TS codegen via `buf`. `lpa serve` answers `Ping` over tonic-web. *Test:* `grpcurl` Ping + a Connect-ES client Ping.

**P2 — Chain layer.** alloy WS subscriber on PoolManager `Swap`; StateView reads (tick, fees, liquidity); position tracker with SQLite. *Test:* anvil `--fork-url` mainnet, replay a real swap, assert state updates + persistence across restart.

**P3 — Strategy engine.** Correct concentrated-LP IL; block-sampled Bollinger; EV gate; fee-capture. *Test:* `cargo test` on synthetic tick series + property tests for tick-spacing rounding and gate monotonicity.

**P4 — AutopilotHook.sol.** afterSwap trigger, rebalance() via flash accounting, cooldown, rebalancer auth. *Test:* foundry unit + fork tests. Audit pass (reentrancy, auth, tick validation, hook-permission mask).

**P5 — Executor.** alloy signer, `eth_call` simulation, Flashbots/private RPC, spend caps, calls `hook.rebalance()`. *Test:* fork + testnet dry-run.

**P6 — CLI UX.** `clap` subcommands (`watch`, `register`, `rebalance`, `simulate`, `config`, `serve`), config file, JSON logs.

**P7 — serve + TS SDK.** tonic + tonic-web `AutopilotStrategy`; Connect-ES SDK; React hook. *Test:* SDK ↔ serve integration (register → stream → command).

**P8 — E2E + hardening.** Full flow on testnet, per-feature audit, failure-mode tests (RPC drop, reorg, stuck tx).

## Open questions for later

- Target chain(s) for v1? (affects addresses + gas model — leaning Base for cheap rebalances)
- Hook execution: route liquidity moves through canonical PositionManager from inside the hook, or self-custody the LP NFT in the hook?
- Caveman/cavekit: terse output style only, or you run cavekit's validation loop on each phase?

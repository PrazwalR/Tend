#!/usr/bin/env bash
# End-to-end run against an anvil fork of Base.
#
# Exercises the whole loop on a real PoolManager: deploy hook -> daemon watches
# -> position opened -> swaps push price out of range -> daemon decides and
# sends a real rebalance tx -> hook moves the range -> daemon indexes it back.
# Also restarts the daemon mid-run to prove the watermark + backfill path
# recovers a position opened while it was down.
#
# Requires RPC_BASE. Skips (exit 0) without it, so CI stays green unfunded.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

if [[ -z "${RPC_BASE:-}" || "$RPC_BASE" == *YOUR_KEY* ]]; then
  echo "SKIP: RPC_BASE not set — the e2e needs an archive-capable Base RPC to fork."
  exit 0
fi

for bin in anvil forge cast cargo jq sqlite3; do
  command -v "$bin" >/dev/null || { echo "FAIL: $bin not on PATH"; exit 1; }
done

PORT="${E2E_PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
WS="ws://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DB="$WORK/e2e.sqlite"
ANVIL_LOG="$WORK/anvil.log"
DAEMON_LOG="$WORK/daemon.log"

# anvil's first two deterministic accounts: [0] deploys and owns the LP,
# [1] is the rebalancer hot wallet.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
REBALANCER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
REBALANCER_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b

ANVIL_PID=""; DAEMON_PID=""
cleanup() {
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null || true
  [[ -n "$ANVIL_PID" ]] && kill "$ANVIL_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- daemon ---"; tail -40 "$DAEMON_LOG" 2>/dev/null || true; exit 1; }
step() { echo; echo "=== $* ==="; }

start_daemon() {
  RPC_BASE="$RPC" RPC_WS_BASE="$WS" \
  AUTOPILOT_HOOK_ADDRESS="$HOOK" \
  REBALANCER_PRIVATE_KEY="$REBALANCER_KEY" \
  LPA_DB="$DB" \
  RUST_LOG=lpa=debug \
  LPA_MIN_TICKS=6 \
  LPA_AUTO_INTERVAL_SECS=1 \
  LPA_WS_HEARTBEAT_SECS=5 \
  LPA_VOLUME_USD_PER_BLOCK=5000000 \
  DEFAULT_MAX_GAS_USD=500 \
    ./target/debug/lpa --log-format json watch --chain base --execute >>"$DAEMON_LOG" 2>&1 &
  DAEMON_PID=$!
  sleep 3
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "daemon exited on startup"
}

stop_daemon() {
  [[ -n "$DAEMON_PID" ]] || return 0
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
}

# Each forge script broadcast mines its own block, so ticks land one per block.
swap() {
  ZERO_FOR_ONE="$1" SWAP_AMOUNT="$2" \
  POOL_MANAGER="$POOL_MANAGER" SWAPPER="$SWAPPER" \
  TOKEN0="$TOKEN0" TOKEN1="$TOKEN1" HOOK="$HOOK" \
    fscript script/E2ESwap.s.sol:E2ESwap \
      --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow >/dev/null 2>&1 \
    || fail "swap failed"
}

kv() { grep -oE "^\s*$1=\S+" "$2" | tail -1 | cut -d= -f2; }

# forge resolves script paths against its project root, not the shell's cwd.
fscript() { (cd "$ROOT/contracts" && forge script "$@"); }

step "booting anvil fork of Base"
anvil --fork-url "$RPC_BASE" --port "$PORT" --silent >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || fail "anvil never became ready"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
[[ "$CHAIN_ID" == "8453" ]] || fail "expected forked chain id 8453, got $CHAIN_ID"
echo "anvil up, forked chain id $CHAIN_ID"

step "building daemon"
cargo build --bin lpa >/dev/null 2>&1 || fail "cargo build failed"

step "stage 1 — deploy hook, pool, background liquidity"
SETUP_LOG="$WORK/setup.log"
POOL_MANAGER="$POOL_MANAGER" REBALANCER_ADDRESS="$REBALANCER_ADDR" REBALANCE_COOLDOWN_SECS=60 \
  fscript script/E2ESetup.s.sol:E2ESetup \
    --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow >"$SETUP_LOG" 2>&1 \
  || { tail -30 "$SETUP_LOG"; fail "setup script failed"; }

HOOK=$(kv HOOK "$SETUP_LOG")
TOKEN0=$(kv TOKEN0 "$SETUP_LOG")
TOKEN1=$(kv TOKEN1 "$SETUP_LOG")
SWAPPER=$(kv SWAPPER "$SETUP_LOG")
[[ -n "$HOOK" && -n "$TOKEN0" && -n "$SWAPPER" ]] || { tail -30 "$SETUP_LOG"; fail "could not parse setup output"; }
echo "hook=$HOOK token0=$TOKEN0 token1=$TOKEN1"

cast call "$HOOK" "isRebalancer(address)(bool)" "$REBALANCER_ADDR" --rpc-url "$RPC" \
  | grep -q true || fail "rebalancer not authorised on hook"

step "stage 2 — daemon starts watching, then a position is opened"
start_daemon

DEP_LOG="$WORK/deposit.log"
HOOK="$HOOK" TOKEN0="$TOKEN0" TOKEN1="$TOKEN1" TICK_LOWER=-600 TICK_UPPER=600 \
  fscript script/E2EDeposit.s.sol:E2EDeposit \
    --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow >"$DEP_LOG" 2>&1 \
  || { tail -30 "$DEP_LOG"; fail "deposit failed"; }
POSITION=$(kv POSITION "$DEP_LOG")
[[ -n "$POSITION" ]] || { tail -30 "$DEP_LOG"; fail "could not parse position id"; }
echo "position=$POSITION"

sleep 3
grep -q "indexed PositionOpened" "$DAEMON_LOG" \
  || fail "daemon did not index PositionOpened from the live stream"
echo "OK: position indexed from live stream"

step "stage 3 — restart daemon across a second deposit (watermark + backfill)"
stop_daemon
DEP2_LOG="$WORK/deposit2.log"
HOOK="$HOOK" TOKEN0="$TOKEN0" TOKEN1="$TOKEN1" TICK_LOWER=-1200 TICK_UPPER=-60 \
  fscript script/E2EDeposit.s.sol:E2EDeposit \
    --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow >"$DEP2_LOG" 2>&1 \
  || { tail -30 "$DEP2_LOG"; fail "second deposit failed"; }
POSITION2=$(kv POSITION "$DEP2_LOG")
echo "opened $POSITION2 while the daemon was down"

start_daemon
sleep 3
grep -q "backfilling missed logs" "$DAEMON_LOG" || fail "daemon did not attempt a backfill on restart"
COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM positions" 2>/dev/null || echo 0)
[[ "$COUNT" -ge 2 ]] || fail "backfill did not recover the offline deposit (positions=$COUNT)"
echo "OK: backfill recovered the offline deposit (positions=$COUNT)"

step "stage 4 — swap the price out of range"
for _ in $(seq 1 8); do swap true -1e15; done   # build tick history in range
for _ in $(seq 1 6); do swap true -4e19; done   # push hard through the lower bound

TICK=$(cast call "$HOOK" "positions(bytes32)(address,(address,address,uint24,int24,address),int24,int24,uint128,bool,uint64)" \
  "$POSITION" --rpc-url "$RPC" 2>/dev/null | sed -n '3p' || true)
echo "post-swap stored range lower=$TICK"

# The contract enforces a minimum cooldown, and it is now measured from the
# deposit rather than from 0. Advance chain time past it so the daemon's next
# attempt is eligible.
cast rpc evm_increaseTime 120 --rpc-url "$RPC" >/dev/null 2>&1 || true
cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1 || true

step "stage 5 — wait for the daemon to rebalance on-chain"
DEADLINE=$((SECONDS + 90))
REBALANCED=0
while (( SECONDS < DEADLINE )); do
  if grep -q "auto-rebalanced on-chain" "$DAEMON_LOG"; then REBALANCED=1; break; fi
  sleep 3
done

if (( REBALANCED == 0 )); then
  echo "--- daemon tail ---"; tail -60 "$DAEMON_LOG"
  grep -q "position EXITED range" "$DAEMON_LOG" \
    || fail "daemon never saw the position exit range"
  fail "position exited range but no rebalance tx landed"
fi

# Pull the first 32-byte word off the success line: the tx hash precedes the
# position id. Tolerates any log format, and must not trip `set -e` on no match.
TXH=$(grep "auto-rebalanced on-chain" "$DAEMON_LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{64}' | head -1 || true)
echo "rebalance tx: $TXH"
[[ -n "$TXH" ]] || fail "could not parse rebalance tx hash"
STATUS=$(cast receipt "$TXH" --rpc-url "$RPC" --json | jq -r '.status')
[[ "$STATUS" == "0x1" ]] || fail "rebalance tx reverted (status=$STATUS)"

step "stage 6 — assert the hook actually moved the range"
NEW_LOWER=$(cast call "$HOOK" \
  "positions(bytes32)(address,(address,address,uint24,int24,address),int24,int24,uint128,bool,uint64)" \
  "$POSITION" --rpc-url "$RPC" | sed -n '3p' | tr -d ' ')
NEW_UPPER=$(cast call "$HOOK" \
  "positions(bytes32)(address,(address,address,uint24,int24,address),int24,int24,uint128,bool,uint64)" \
  "$POSITION" --rpc-url "$RPC" | sed -n '4p' | tr -d ' ')
echo "hook range now [$NEW_LOWER, $NEW_UPPER]"
[[ "$NEW_LOWER" != "-600" || "$NEW_UPPER" != "600" ]] || fail "hook range did not move"

sleep 4
grep -q "indexed Rebalanced" "$DAEMON_LOG" || fail "daemon did not index its own Rebalanced event"

DB_RANGE=$(sqlite3 "$DB" "SELECT tick_lower||','||tick_upper FROM positions WHERE position_id='$POSITION'")
echo "daemon db range: $DB_RANGE"
[[ "$DB_RANGE" == "$NEW_LOWER,$NEW_UPPER" ]] \
  || fail "daemon db range $DB_RANGE disagrees with chain [$NEW_LOWER,$NEW_UPPER]"

echo
echo "E2E PASSED — full loop verified against a real v4 PoolManager."

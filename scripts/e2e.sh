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
# The run takes ~15 minutes, long enough for macOS idle or maintenance sleep
# (-i, -s: the latter blocks system sleep on AC), which freezes
# anvil and the daemon mid-stage and fails whichever stage is waiting.
CAFFEINATE_PID=""
command -v caffeinate >/dev/null && { caffeinate -i -s -w $$ & CAFFEINATE_PID=$!; }
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
  # caffeinate is waiting for this script to exit, so a bare `wait` here would
  # wait on it forever. Stop it, and wait only on what was killed above.
  [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null || true
  wait $DAEMON_PID $ANVIL_PID $CAFFEINATE_PID 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; echo "--- daemon ---"; tail -40 "$DAEMON_LOG" 2>/dev/null || true; exit 1; }
step() { echo; echo "=== $* ==="; }

# The heartbeat is pushed out of reach on purpose. It only fires after a quiet
# spell, which a busy mainnet pool never has, so nothing that has to work there
# may depend on it; with it disabled, stage 7's recovery proves the sweep runs
# on its own timer.
start_daemon() {
  RPC_BASE="$RPC" RPC_WS_BASE="$WS" \
  AUTOPILOT_HOOK_ADDRESS="$HOOK" \
  REBALANCER_PRIVATE_KEY="$REBALANCER_KEY" \
  LPA_DB="$DB" \
  RUST_LOG=lpa=debug \
  LPA_MIN_TICKS=6 \
  LPA_AUTO_INTERVAL_SECS=1 \
  LPA_WS_HEARTBEAT_SECS=100000 \
  LPA_SWEEP_SECS=5 \
  LPA_IDLE_REDEPLOY_WAIT_SECS=20 \
  LPA_VOLUME_USD_PER_BLOCK=5000000 \
  DEFAULT_MAX_GAS_USD=500 \
  LPA_MAX_SPEND_USD_PER_HOUR=1000000 \
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

# Anvil only mines on a transaction, so with no swaps block.timestamp stands
# still and a cooldown never elapses. A live chain keeps producing blocks.
mine() { cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1 || true; }

# Waits until the daemon stops queueing and sending rebalances.
settle() {
  local deadline=$((SECONDS + 180)) l0
  while (( SECONDS < deadline )); do
    l0=$(wc -l < "$DAEMON_LOG")
    mine
    sleep 15
    tail -n +"$((l0 + 1))" "$DAEMON_LOG" | grep -qE "intent queued|redeploy queued|auto-rebalanced on-chain" || return 0
  done
  fail "daemon never settled after $1"
}

# Sum of a position's idle balance, both tokens, as a decimal integer.
idle_sum() {
  cast call "$HOOK" "idle(bytes32)(uint128,uint128)" "$1" --rpc-url "$RPC" 2>/dev/null \
    | awk '{ print $1 }' | paste -sd+ - | bc
}

kv() { grep -oE "^\s*$1=\S+" "$2" | tail -1 | cut -d= -f2; }

# forge resolves script paths against its project root, not the shell's cwd.
fscript() { (cd "$ROOT/contracts" && forge script "$@"); }

step "booting anvil fork of Base"
# A block every 2 s, like Base. The hook needs the price reference to have sat
# on spot for several block ends before it rebalances, and an anvil that only
# mines on a transaction never produces the quiet blocks a real chain does.
anvil --fork-url "$RPC_BASE" --port "$PORT" --block-time 2 --silent >"$ANVIL_LOG" 2>&1 &
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
LP_ROUTER=$(kv LP_ROUTER "$SETUP_LOG")
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

# The cooldown is measured from the deposit, so it has to elapse BEFORE the
# swaps push the position out of range — the daemon only attempts a rebalance
# when a swap event arrives, and nothing re-triggers it once the swaps stop.
step "advancing chain time past the rebalance cooldown"
cast rpc evm_increaseTime 120 --rpc-url "$RPC" >/dev/null 2>&1 || true
cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1 || true

step "stage 4 — swap the price out of range"
for _ in $(seq 1 8); do swap true -1e15; done   # build tick history in range
for _ in $(seq 1 6); do swap true -4e19; done   # push hard through the lower bound

TICK=$(cast call "$HOOK" "positions(bytes32)(address,(address,address,uint24,int24,address),int24,int24,uint128,bool,uint64)" \
  "$POSITION" --rpc-url "$RPC" 2>/dev/null | sed -n '3p' || true)
echo "post-swap stored range lower=$TICK"

step "stage 5 — wait for the daemon to rebalance on-chain"
# After a jump the hook waits for its price reference to catch up with spot and
# then sit there for MIN_STABLE_BLOCKS block ends; the daemon pokes it along.
DEADLINE=$((SECONDS + 240))
REBALANCED=0
while (( SECONDS < DEADLINE )); do
  # This position specifically: the sweep may rebalance the offline-deposited
  # one first, and stage 6 inspects this one.
  if grep "auto-rebalanced on-chain" "$DAEMON_LOG" | grep -q "$POSITION"; then REBALANCED=1; break; fi
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
TXH=$(grep "auto-rebalanced on-chain" "$DAEMON_LOG" | grep "$POSITION" | tail -1 | grep -oE '0x[0-9a-fA-F]{64}' | head -1 || true)
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

step "stage 7 — a position stuck behind the price guard on a quiet pool recovers"
# One large move in a single block, then no more swaps. The price reference may
# follow only one capped step per block, so the next rebalance is refused with
# PriceDeviation — and since nothing else will ever swap here, only the daemon's
# sweep and its pokes can move the reference back within tolerance.
#
# Let the daemon finish following stage 4's price walk first. Its sweep keeps
# re-rebalancing positions that fell out of range again, and a rebalance landing
# after the mark would both read as the recovery and restart the cooldown.
settle "stage 6"
# Past the cooldown FIRST: the contract checks it before the price guard, and a
# RebalanceTooSoon would otherwise mask the condition under test.
cast rpc evm_increaseTime 120 --rpc-url "$RPC" >/dev/null 2>&1 || true
cast rpc evm_mine --rpc-url "$RPC" >/dev/null 2>&1 || true
MARK=$(wc -l < "$DAEMON_LOG")
swap true -3e20
echo "large one-block move done; no further swaps"

since() { tail -n +"$((MARK + 1))" "$DAEMON_LOG"; }
DEADLINE=$((SECONDS + 240))
RECOVERED=0
while (( SECONDS < DEADLINE )); do
  if since | grep -q "auto-rebalanced on-chain"; then RECOVERED=1; break; fi
  sleep 5
done

# The executor logs a reference-lag refusal (PriceDeviation or PriceUnsettled)
# as action "Poke".
BLOCKED=$(since | grep "blocked at preflight" | grep -c '"action":"Poke"' || true)
POKES=$(since | grep -c "poked price reference toward spot" || true)
echo "preflight refusals on a lagging price reference: $BLOCKED"
echo "pokes sent: $POKES"
(( BLOCKED > 0 )) || fail "stage 7 never reproduced the stuck condition (no reference-lag refusal)"
(( POKES > 0 )) || fail "daemon never poked the price reference"
(( RECOVERED == 1 )) || fail "position stayed stuck behind the price guard"
echo "OK: stuck position recovered via sweep + poke with no further swaps"

step "stage 8 — a capped swap leaves an idle balance, and the daemon places it"
# Starve the re-ratio swap: pull the background book (1e21, ~1000x a position),
# leaving only the other hook position as depth. Under the default 50 bps impact
# bound a rebalance onto a reshaped range then cannot convert what it needs, and
# part of the position is left over. (Loosening the bound afterwards would be a
# timelocked change, and jumping anvil two days would stale the ETH price feed.) The rebalance is sent here directly, as the
# rebalancer: this stage tests the daemon noticing and placing the balance, not
# whether its strategy would pick this moment to rebalance.
settle "stage 7"
cast rpc evm_increaseTime 120 --rpc-url "$RPC" >/dev/null 2>&1 || true
mine
IDLE_POS=$POSITION
BASE=$(idle_sum "$IDLE_POS"); BASE=${BASE:-0}
SPOT=$(sqlite3 "$DB" "SELECT current_tick FROM positions WHERE position_id='$IDLE_POS'")
C=$(( (SPOT / 60) * 60 ))
# Asymmetric around spot, so the old holdings are the wrong mix for it, but not
# near either edge, so the daemon's strategy has no reason to move it again.
LO=$((C - 1800)); HI=$((C + 600))
# Settling does not mean the price reference has caught up with spot, and a
# direct rebalance gets no pokes from the daemon; walk it in, one block a step.
for _ in $(seq 1 12); do
  cast send "$HOOK" "pokePriceRef((address,address,uint24,int24,address))" \
    "($TOKEN0,$TOKEN1,3000,60,$HOOK)" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null 2>&1 || true
done
background() {
  cast send --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" "$LP_ROUTER" \
    "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
    -- "($TOKEN0,$TOKEN1,3000,60,$HOOK)" "(-60000,60000,$1,0x0000000000000000000000000000000000000000000000000000000000000000)" 0x \
    >/dev/null 2>&1 || fail "background liquidity change $1 failed"
}
background -1000000000000000000000
MARK=$(wc -l < "$DAEMON_LOG")
# Options before `--`: everything after it is a positional argument, and the
# negative ticks need it so they are not read as flags.
if ! OUT=$(cast send --private-key "$REBALANCER_KEY" --rpc-url "$RPC" \
  "$HOOK" "rebalance(bytes32,int24,int24,uint128)" -- "$IDLE_POS" "$LO" "$HI" 0 2>&1); then
  echo "$OUT" | tail -3
  fail "starved rebalance onto [$LO, $HI] reverted"
fi
IDLE_BEFORE=$(idle_sum "$IDLE_POS"); IDLE_BEFORE=${IDLE_BEFORE:-0}
echo "starved rebalance onto [$LO, $HI]: idle $BASE -> $IDLE_BEFORE"
[[ $(echo "$IDLE_BEFORE > $BASE * 100" | bc) == 1 ]] || fail "the starved swap did not leave an idle balance"

# Depth is usable again. The daemon has to notice the idle balance on its own.
background 1000000000000000000000
PLACED=0
DEADLINE=$((SECONDS + 300))
while (( SECONDS < DEADLINE )); do
  mine
  sleep 5
  v=$(idle_sum "$IDLE_POS"); v=${v:-0}
  if [[ $(echo "$v * 10 < $IDLE_BEFORE" | bc) == 1 ]]; then PLACED=1; break; fi
done
QUEUED=$(since | grep -c "idle balance redeploy queued" || true)
echo "idle redeploys queued: $QUEUED; idle now: $v"
(( QUEUED > 0 )) || fail "daemon never queued an idle redeploy"
(( PLACED == 1 )) || fail "idle balance was not placed (still $v of $IDLE_BEFORE)"
RANGE_NOW=$(cast call "$HOOK" "positions(bytes32)(address,(address,address,uint24,int24,address),int24,int24,uint128,bool,uint64)" "$IDLE_POS" --rpc-url "$RPC" | sed -n '3,4p' | awk '{ print $1 }' | paste -sd, -)
[[ "$RANGE_NOW" == "$LO,$HI" ]] || fail "placed by a range change ($RANGE_NOW), not a same-range redeploy"
echo "OK: idle balance placed back into [$LO, $HI] by a same-range rebalance"

echo
echo "E2E PASSED — full loop verified against a real v4 PoolManager."

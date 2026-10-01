#!/usr/bin/env bash
# Where am I in the setup, and what is the next action?
# Safe to run at any time, including on a bare clone with nothing set up.
#   scripts/status.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Ports: defaults unless this deployment had to move off them. ports.sh records
# the choice in .tn-env so every session resolves to the same node.
[ -f "$ROOT/.tn-env" ] || "$ROOT/scripts/ports.sh" >/dev/null 2>&1
# shellcheck disable=SC1091
[ -f "$ROOT/.tn-env" ] && . "$ROOT/.tn-env"
PGHOST=${TN_PGHOST:-127.0.0.1}; PGPORT=${TN_PGPORT:-5432}
PGUSER=${TN_PGUSER:-postgres};  PGDB=${TN_PGDB:-kwild}
RPC=${TN_RPC:-http://127.0.0.1:${TN_RPC_PORT:-8484}}
UPSTREAM=${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}

ok(){ printf '  [ok]   %s\n' "$1"; }
no(){ printf '  [--]   %s\n' "$1"; }
PHASE=0; NEXT=""
step(){ [ -z "$NEXT" ] && { PHASE=$1; NEXT="$2"; }; }

echo "=== 1. tools ==="
command -v kwild >/dev/null && ok "kwild $(kwild version 2>/dev/null | grep -i Version | head -1 | tr -s " \t" " " | sed "s/^ //")" || { no "kwild not installed"; step 1 "install kwild: see skills/truf-node-up/SKILL.md section 1"; }
PGV=$(psql --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ "${PGV:-0}" = "16" ] && ok "psql 16" || { no "psql is ${PGV:-absent}, kwild requires 16"; step 1 "install postgresql-client-16: skills/truf-node-up/SKILL.md section 2 (needs sudo, ASK THE HUMAN)"; }
command -v docker >/dev/null && ok "docker" || { no "docker missing"; step 1 "install docker"; }
command -v go >/dev/null && ok "go $(go version 2>/dev/null | awk '{print $3}')" || no "go missing (needed once, to build the SDK helper)"

# Report the binary and verify the schema this repo reads. An upgrade on its own
# is harmless. What matters is whether the objects the queries need are present,
# and that is worth checking every time rather than guessing when it changed.
NOWV=$(pgrep -af 'kwild[^[:space:]]* start' 2>/dev/null | grep -o 'kwild[^ /]*' | head -1)
[ -n "${NOWV:-}" ] && ok "node binary $NOWV"
if [ -x "$ROOT/scripts/check-schema.sh" ]; then
  if "$ROOT/scripts/check-schema.sh" >/dev/null 2>&1; then
    ok "schema: every table and column this repo reads is present"
  else
    no "schema changed, run scripts/check-schema.sh"
  fi
fi

echo "=== 2. postgres ==="
if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc 'SELECT 1' >/dev/null 2>&1; then
  ok "reachable on $PGHOST:$PGPORT"
else
  no "no postgres on $PGHOST:$PGPORT"; step 2 "start postgres: skills/truf-node-up/SKILL.md section 4"
fi

echo "=== 3. node config ==="
if [ -f "$ROOT/tn-node/genesis.json" ]; then
  CID=$(grep -o '"chain_id": *"[^"]*"' "$ROOT/tn-node/genesis.json" | cut -d'"' -f4)
  [ "$CID" = "tn-v2.1" ] && ok "genesis chain_id $CID (mainnet)" \
    || { no "genesis chain_id is '$CID', expected tn-v2.1"; step 3 "re-init against configs/network/v2/genesis.json"; }
else
  no "no tn-node/genesis.json"; step 3 "kwild setup init: skills/truf-node-up/SKILL.md section 5"
fi

echo "=== 4. sync ==="
# Match THIS deployment's root. A bare "kwild start" match would report
# another node on the same machine as if it were ours, which is the same trap
# as connecting to another node's Postgres. The root may be given relatively,
# so resolve each process's argument against its own working directory rather
# than comparing the command line as text.
node_here(){
  local pid root want
  want=$(readlink -f "$ROOT/tn-node" 2>/dev/null) || return 1
  for pid in $(pgrep -f "kwild[^[:space:]]* start" 2>/dev/null); do
    [ -r "/proc/$pid/cmdline" ] || continue
    root=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
           | awk '/^--root$/{getline;print;exit} /^--root=/{sub(/^--root=/,"");print;exit}')
    [ -n "$root" ] || continue
    case "$root" in /*) ;; *) root="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)/$root" ;; esac
    [ "$(readlink -f "$root" 2>/dev/null)" = "$want" ] && return 0
  done
  return 1
}
if node_here; then
  ok "kwild running for this deployment"
  h(){ curl -s --max-time 8 "$1/api/v1/health" 2>/dev/null \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['height'])" 2>/dev/null; }
  peers(){ curl -s --max-time 8 "$RPC/api/v1/health" 2>/dev/null \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['peer_count'])" 2>/dev/null; }
  # The timestamp of the block we are currently on. This is what tells a person
  # where the node has actually got to, which a height alone never does.
  btime(){ curl -s --max-time 8 "$RPC/api/v1/health" 2>/dev/null \
       | python3 -c "import sys,json;print(int(json.load(sys.stdin)['services']['user']['block_time'])//1000)" 2>/dev/null; }
  L=$(h "$RPC"); U=$(h "$UPSTREAM")
  # The upstream tip is only a denominator. It moves about one block every few
  # seconds, so a stale value costs almost nothing, while losing it blanks the
  # whole display. Remember the last good one.
  TIPF="$ROOT/.tn-tip"
  if [ -n "${U:-}" ]; then echo "$U" > "$TIPF"
  elif [ -f "$TIPF" ]; then U=$(cat "$TIPF"); fi
  # The RPC goes unresponsive while the node is replaying hard, which is exactly
  # when progress matters most. The log still records every commit, so fall back
  # to it rather than going blind.
  if [ -z "${L:-}" ] && [ -f "$ROOT/kwild-run.log" ]; then
    L=$(grep -oE 'Committed Block \{height=[0-9]+' "$ROOT/kwild-run.log" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    [ -n "$L" ] && echo "SYNC_SOURCE=log"
  fi
  # Machine-readable sync metrics. A rate needs two samples, so remember the
  # last one and compute against it rather than guessing a constant.
  PROG="$ROOT/.tn-progress"
  NOW=$(date +%s)
  LOGF="$ROOT/kwild-run.log"
  # When this run started, and the snapshot height it restored from. Together
  # these give elapsed time and a real denominator for the catch-up stage.
  if [ -f "$LOGF" ]; then
    T0=$(head -1 "$LOGF" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}')
    [ -n "$T0" ] && echo "SYNC_START=$(date -d "$T0" +%s 2>/dev/null)"
    BASE=$(grep -oE 'Discovered snapshot \{height=[0-9]+' "$LOGF" | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -n "$BASE" ] && echo "SYNC_BASE=$BASE"
  fi
  if [ -n "${L:-}" ] && [ -n "${U:-}" ]; then
    # Throughput swings by two orders of magnitude depending on what is in the
    # blocks: light ones replay at 100 per minute, digest-heavy ones at 2. A
    # two-sample rate therefore predicts anything between 2 hours and 8 days.
    # Average over the whole catch-up instead, which is what actually converges.
    RATE=""; ETA=""
    MARK="$ROOT/.tn-replaystart"
    [ ! -f "$MARK" ] && printf '%s %s\n' "$L" "$NOW" > "$MARK"
    read -r RH RT < "$MARK" 2>/dev/null || true
    if [ -n "${RH:-}" ] && [ "$NOW" -gt "${RT:-0}" ] && [ "$L" -gt "${RH:-0}" ]; then
      RATE=$(awk -v a="$L" -v b="$RH" -v t="$NOW" -v u="$RT" 'BEGIN{printf "%.2f",(a-b)/(t-u)}')
      ETA=$(awk -v d="$((U-L))" -v r="$RATE" 'BEGIN{if(r>0){s=d/r;printf "%dh %02dm",s/3600,(s%3600)/60}else{printf "unknown"}}')
    fi
    BT=$(btime)
    # Carry the last known block time forward. The log has no block timestamp,
    # so without this the display loses the one field that reads as progress.
    if [ -z "$BT" ] && [ -f "$PROG" ]; then
      read -r _ph _pt _pb < "$PROG" 2>/dev/null || true
      BT=${_pb:-}
    fi
    printf '%s %s %s\n' "$L" "$NOW" "${BT:-}" > "$PROG"
    echo "SYNC_STAGE=replay"
    # Record the true chunk total once, so the next restore can show a percent.
    [ ! -f "$ROOT/.tn-chunktotal" ] && [ -f "$LOGF" ] && \
      grep -c 'Received snapshot chunk' "$LOGF" 2>/dev/null > "$ROOT/.tn-chunktotal"
    echo "SYNC_LOCAL=$L"; echo "SYNC_TIP=$U"; echo "SYNC_BEHIND=$((U-L))"
    [ -n "$RATE" ] && echo "SYNC_RATE=$RATE"
    [ -n "$ETA" ] && echo "SYNC_ETA=$ETA"
    echo "SYNC_PEERS=$(peers)"
    [ -n "${BT:-}" ] && echo "SYNC_BLOCK_TIME=$BT"
  else
    # Never regress. Once the catch-up has been seen, a momentary failure
    # means the RPC is busy, not that the load restarted. Reporting a finished
    # stage as in-progress again is worse than reporting nothing.
    if [ -f "$ROOT/.tn-progress" ]; then
      echo "SYNC_STAGE=replay"
      echo "SYNC_STALE=yes"
      read -r LH LT < "$ROOT/.tn-progress" 2>/dev/null || true
      [ -n "${LH:-}" ] && echo "SYNC_LOCAL=$LH"
      echo "SYNC_TIP=${U:-$LH}"
      exit 0
    fi
    # Three stages, not two. Once every chunk is down, kwild shells out to psql
    # and loads 3 GB into Postgres. That takes tens of minutes and kwild logs no
    # progress for it, so the progress has to come from the database itself.
    if grep -q "All chunks downloaded successfully" "$LOGF" 2>/dev/null; then
      echo "SYNC_STAGE=apply"
      AT0=$(grep -m1 "Restoring database from snapshot" "$LOGF" | grep -oE '^[0-9-]+ [0-9:]{8}')
      [ -n "$AT0" ] && echo "SYNC_APPLY_START=$(date -d "$AT0" +%s 2>/dev/null)"
      EST=$(grep -m1 -oE 'estimated_duration=[0-9hms]+' "$LOGF" | cut -d= -f2)
      if [ -n "$EST" ]; then
        echo "SYNC_APPLY_EST=$(echo "$EST" | sed -E 's/([0-9]+)h/\1*3600+/;s/([0-9]+)m/\1*60+/;s/([0-9]+)s/\1+/;s/\+$//' | bc 2>/dev/null)"
      fi
      echo "SYNC_APPLY_TABLE=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc \
        "SELECT substring(query from 'COPY ([a-zA-Z0-9_.]+)') FROM pg_stat_activity
          WHERE datname='$PGDB' AND query LIKE 'COPY %' LIMIT 1" 2>/dev/null)"
      echo "SYNC_APPLY_BYTES=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc \
        "SELECT pg_database_size('$PGDB')" 2>/dev/null)"
      echo "SYNC_APPLY_ROWS=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc \
        "SELECT sum(n_live_tup) FROM pg_stat_user_tables" 2>/dev/null)"
    else
      echo "SYNC_STAGE=restore"
    fi
    if [ -f "$LOGF" ]; then
      # Peers first. Zero peers makes every downstream number meaningless, and
      # the failure otherwise presents as a snapshot problem.
      echo "SYNC_PEERS_OK=$(grep -c 'Connected to peer' "$LOGF" 2>/dev/null || echo 0)"
      echo "SYNC_DIAL_FAIL=$(grep -c 'failed to connect to' "$LOGF" 2>/dev/null || echo 0)"
      echo "SYNC_CHUNKS=$(grep -c 'Received snapshot chunk' "$LOGF" 2>/dev/null || echo 0)"
      # Bytes actually on disk. The chunk COUNT is in metadata kwild never logs,
      # so size is the only measurable progress during this stage.
      RS="$ROOT/tn-node/received_snapshots"
      [ -d "$RS" ] && echo "SYNC_BYTES=$(du -sb "$RS" 2>/dev/null | cut -f1)"
      # kwild logs the real total once, as total_chunks in "Starting chunk download".
      TC=$(grep -oE 'total_chunks=[0-9]+' "$LOGF" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
      [ -n "$TC" ] && echo "SYNC_CHUNK_TOTAL=$TC"
      echo "SYNC_SNAPSHOTS=$(grep -c 'Discovered snapshot' "$LOGF" 2>/dev/null || echo 0)"
      grep -q 'verified snapshot with trusted provider' "$LOGF" 2>/dev/null && echo "SYNC_VERIFIED=yes" || echo "SYNC_VERIFIED=no"
      echo "SYNC_DISCOVERY_ROUNDS=$(grep -c 'Discovering snapshots' "$LOGF" 2>/dev/null || echo 0)"
    fi
  fi
  if [ -z "${L:-}" ]; then
    no "local RPC not answering yet (normal during snapshot restore)"
    # Progress during restore. The log carries no total, so report what is
    # known rather than inventing a denominator.
    LOG="$ROOT/kwild-run.log"
    if [ -f "$LOG" ]; then
      GOT=$(grep -c "Received snapshot chunk" "$LOG" 2>/dev/null || echo 0)
      TOP=$(grep -o "chunk=[0-9]*" "$LOG" 2>/dev/null | grep -o "[0-9]*" | sort -n | tail -1)
      grep -q "verified snapshot with trusted provider" "$LOG" 2>/dev/null \
        && ok "snapshot verified with a trusted provider" \
        || no "snapshot NOT yet verified against a trusted provider"
      echo "         restore progress: $GOT chunks received, highest index ${TOP:-0}"
    fi
    step 4 "WAIT for the restore, then re-run this script"
  elif [ -z "${U:-}" ]; then
    # Our node is fine. Do not send anyone debugging it over a network blip.
    ok "local height $L (upstream unreachable, cannot compare)"
    step 4 "check network access to $UPSTREAM, then re-run this script"
  else
    D=$((U-L))
    if [ "$D" -lt 20 ]; then
      ok "at tip: local $L, upstream $U"
    else
      no "behind by $D blocks (local $L, upstream $U)"
      step 4 "WAIT. Roughly 2 blocks/sec, so about $((D/7200))h remaining. Re-run this script later."
    fi
  fi
elif pgrep -f "kwild[^[:space:]]* start" >/dev/null 2>&1; then
  no "a kwild is running, but not for $ROOT/tn-node"
  step 4 "start THIS node, or point this checkout at the other deployment"
else
  no "kwild not running"; step 4 "start the node: skills/truf-node-up/SKILL.md section 6"
fi

echo "=== 5. sdk helper ==="
[ -x "$ROOT/agent/agent" ] && ok "agent binary built" || { no "agent binary not built"; step 5 "cd agent && go build -o agent ."; }
[ -f "$ROOT/agent/agent.key" ] && ok "agent key present" || { no "no agent key"; step 5 "./agent/agent keygen"; }

echo "=== 6. wallet ==="
MAA=${TN_MAA:-}
if [ -n "$MAA" ]; then
  BAL=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc \
    "SELECT round(b.balance/1e6,2) FROM kwil_erc20_meta.balances b
      JOIN kwil_erc20_meta.reward_instances r ON r.id=b.reward_id
      WHERE b.address=decode('${MAA#0x}','hex') AND r.erc20_decimals=6" 2>/dev/null)
  if [ -n "${BAL:-}" ]; then
    ok "MAA $MAA holds \$${BAL} USDC"
    awk -v b="${BAL:-0}" 'BEGIN{exit !(b+0>0)}' && step 7 "READY. Pick a market: psql -f sql/market-scan.sql, then scripts/edge.py <book>" \
      || step 6 "fund the agent: skills/truf-agent-wallet/SKILL.md (ASK THE HUMAN, only they can send funds)"
  else
    no "MAA $MAA has no balance record yet"; step 6 "fund the agent: skills/truf-agent-wallet/SKILL.md (ASK THE HUMAN)"
  fi
else
  no "TN_MAA not set"; step 6 "set TN_MAA=0x... once the owner has approved the rule: skills/truf-agent-wallet/SKILL.md"
fi

echo
if [ -z "$NEXT" ]; then PHASE=7; NEXT="READY. Pick a market: psql -f sql/market-scan.sql, then scripts/edge.py <book>"; fi
echo "PHASE $PHASE of 7"
echo "NEXT: $NEXT"

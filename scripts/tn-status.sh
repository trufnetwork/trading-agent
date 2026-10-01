#!/usr/bin/env bash
# Status of the local TN mainnet node: process, sync position, DB readiness.
# Usage: scripts/tn-status.sh
set -uo pipefail

PGHOST=127.0.0.1
PGPORT=5433
PGUSER=postgres
PGDB=kwild
RPC=http://127.0.0.1:8485
UPSTREAM=http://node-1.mainnet.truf.network:8484
LOG="$(dirname "$0")/../kwild-run.log"

echo "=== process ==="
if pgrep -f "kwild start --root" >/dev/null; then
  echo "kwild: running (up $(ps -o etime= -p "$(pgrep -f 'kwild start --root' | head -1)" | tr -d ' '))"
else
  echo "kwild: NOT RUNNING"
fi
docker ps --filter name=tn-postgres --format 'postgres: {{.Status}} {{.Ports}}'

echo
echo "=== sync ==="
LOCAL_JSON=$(curl -s --max-time 8 "$RPC/api/v1/health" 2>/dev/null)
if [ -z "$LOCAL_JSON" ]; then
  echo "RPC not up yet (expected during state sync restore)"
  CHUNKS=$(grep -c 'Received snapshot chunk' "$LOG" 2>/dev/null || echo 0)
  echo "snapshot chunks received: ${CHUNKS}/203"
  grep -E "STATESYNC" "$LOG" 2>/dev/null | tail -1 | cut -c1-150
else
  python3 - "$LOCAL_JSON" "$(curl -s --max-time 8 "$UPSTREAM/api/v1/health" 2>/dev/null)" <<'PY'
import json, sys
loc = json.loads(sys.argv[1])["services"]["user"]
print(f"local height : {loc['block_height']}")
print(f"syncing      : {loc['syncing']}")
try:
    tip = json.loads(sys.argv[2])["services"]["user"]["block_height"]
    print(f"network tip  : {tip}")
    print(f"behind by    : {tip - loc['block_height']} blocks")
except Exception:
    print("network tip  : unreachable")
PY
fi

echo
echo "=== database ==="
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDB -tAc \
  "SELECT 'size: ' || pg_size_pretty(pg_database_size('$PGDB'));" 2>/dev/null \
  || { echo "postgres unreachable on $PGPORT"; exit 1; }

# main only exists once the snapshot has been restored.
HAS=$(psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDB -tAc \
  "SELECT count(*) FROM information_schema.tables
   WHERE table_schema='main' AND table_name='ob_queries';" 2>/dev/null)
if [ "${HAS:-0}" = "1" ]; then
  psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDB -tAc \
    "SELECT 'markets: ' || count(*) FILTER (WHERE NOT settled) || ' live / '
          || count(*) || ' total' FROM main.ob_queries;"
  psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDB -tAc \
    "SELECT 'open orders: ' || count(*) FROM main.ob_positions WHERE price <> 0;"
else
  echo "main.ob_queries not present yet (snapshot not restored)"
fi

echo
echo "=== indexer ==="
if pgrep -f "index-tick.sh --loop" >/dev/null; then
  echo "loop: running (pid $(pgrep -f 'index-tick.sh --loop' | head -1))"
else
  echo "loop: NOT RUNNING  <-- restart: setsid nohup ./scripts/index-tick.sh --loop >> indexer.log 2>&1 &"
fi
LOG="$(dirname "$0")/../indexer.log"
if [ -f "$LOG" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$LOG") ))
  printf "last tick: %ss ago" "$AGE"
  [ "$AGE" -gt 180 ] && echo "   <-- STALE (expected <120s)" || echo "   ok"
fi
psql -h $PGHOST -p 5434 -U $PGUSER -d tnidx -tAc \
  "SELECT '  '||source||': '||rows_ingested||' rows, cursor '||last_height FROM sync_state ORDER BY source;" \
  2>/dev/null || echo "  indexer DB unreachable on 5434"

# Long-running queries anywhere. A client that dies does NOT always stop the
# backend -- use pg_cancel_backend(pid), then verify.
for PORT in 5433 5434; do
  STUCK=$(psql -h $PGHOST -p $PORT -U $PGUSER -d postgres -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE state='active'
       AND query NOT LIKE '%pg_stat_activity%' AND query NOT LIKE 'START_REPLICATION%'
       AND now()-query_start > interval '2 minutes';" 2>/dev/null)
  [ "${STUCK:-0}" != "0" ] && echo "  WARNING: $STUCK query(s) >2min on port $PORT"
done


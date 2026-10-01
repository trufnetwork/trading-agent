#!/usr/bin/env bash
# One ingest tick: copy new rows from the node's Postgres into the indexer DB.
#
# Captures ONLY what an OPEN QUESTION needs and the node destroys. Backfill to
# bootstrap a question is setup, not standing collection: do it once, store the
# ANSWER, and do not keep the raw material running.
#
# Open questions today:
#   "has the settling print landed, and when do prints arrive?"
#     -> stream_prints. tn_digest collapses revisions within ~2 days. first_seen
#        gives publication lag directly, so no height-to-time table is needed.
#   "are we earning LP rewards, and what share?"
#     -> lp_rewards. ob_rewards is DELETED at settlement.
#
# Dropped for having no open question:
#   blocks         : first_seen supersedes it for lag
#   book_snapshots : no trading question named it
#   markets        : ob_queries is durable on the node, so this was a copy
#
# NOT captured continuously, on purpose:
#   - ob_order_events : quote churn for all participants. ~70% of it is
#       place/cancel that leaves no economic trace. Capture per-market ON DEMAND
#       when there is a question, not forever for every market.
#   - ob_net_impacts  : DURABLE on the node (395k rows, no trim). Holds
#       shares_change and collateral_change per tx, so PnL and per-market VOLUME
#       are queryable live. Filter shares_change <> 0 to skip fee rows, and take
#       one side only: both buyer and seller are recorded.
#
# Both psql processes run on the HOST and are piped together. Do not use
# COPY ... FROM PROGRAM: that executes inside the indexer container, whose
# 127.0.0.1 is not the host, so it cannot reach the node database.
#
# Idempotent. Safe to run on a loop or from cron. Scoped to streams that back
# markets, not all 259k streams on the network.
#
#   scripts/index-tick.sh          # one tick
#   scripts/index-tick.sh --loop   # every 60s
set -uo pipefail

NODE="psql -h 127.0.0.1 -p 5433 -U postgres -d kwild -tAX"
IDX="psql -h 127.0.0.1 -p 5434 -U postgres -d tnidx -tAX"

nq() { $NODE -c "$1"; }
iq() { $IDX -c "$1"; }

# Stream a query from the node into a staging table, then upsert.
# $1 staging DDL, $2 source SELECT, $3 insert statement
pipe() {
  local ddl="$1" src="$2" ins="$3" stg="$4"
  iq "DROP TABLE IF EXISTS $stg; CREATE UNLOGGED TABLE $stg ($ddl);" >/dev/null || return 1
  if ! $NODE -c "COPY ($src) TO STDOUT" | $IDX -c "COPY $stg FROM STDIN"; then
    echo "  pipe FAILED for $stg" >&2; return 1
  fi
  iq "$ins" || { echo "  insert FAILED for $stg" >&2; return 1; }
  iq "DROP TABLE IF EXISTS $stg;" >/dev/null
}

MARKET_STREAMS="SELECT DISTINCT rtrim(encode(decode(substring(encode(query_components,'hex') from 65 for 64),'hex'),'escape'), E'\\\\000') FROM main.ob_queries"

tick() {
  local h; h=$(nq "SELECT max(block_height) FROM main.ob_order_events;")
  [ -z "$h" ] && { echo "node unreachable"; return 1; }

  # ---- stream_prints. Revisions land as extra rows: PK is (stream, event_time, created_at).
  # Cursor 0 means a fresh install. Start from the CURRENT height, never from
  # zero: a backfill would copy node history we can already query, and every
  # backfilled row carries a first_seen of the copy time, which poisons
  # publication lag. Bootstrap a question from main.primitive_events directly.
  local c; c=$(iq "SELECT last_height FROM sync_state WHERE source='stream_prints';")
  if [ "${c:-0}" = "0" ]; then
    c=$(nq "SELECT COALESCE(max(created_at),0) FROM main.primitive_events;")
    iq "UPDATE sync_state SET last_height=${c:-0} WHERE source='stream_prints';" >/dev/null
    echo "  bootstrap: stream_prints cursor set to $c (no backfill by design)"
  fi
  local before_p; before_p=$(iq "SELECT count(*) FROM stream_prints;")
  pipe "stream_id TEXT, event_time BIGINT, created_at BIGINT, value NUMERIC(36,18)" \
    "SELECT s.stream_id, pe.event_time, pe.created_at, pe.value
       FROM main.primitive_events pe JOIN main.streams s ON s.id = pe.stream_ref
      WHERE pe.created_at > $c AND s.stream_id IN ($MARKET_STREAMS)" \
    "INSERT INTO stream_prints (stream_id,event_time,created_at,value)
       SELECT * FROM stg_p ON CONFLICT DO NOTHING;" stg_p && ok_p=1 || ok_p=0
  local np=$(( $(iq "SELECT count(*) FROM stream_prints;") - ${before_p:-0} ))
  [ "$ok_p" = 1 ] && iq "UPDATE sync_state SET last_height=$h, rows_ingested=rows_ingested+${np:-0}, last_run=now() WHERE source='stream_prints';" >/dev/null

  # ---- ob_rewards: LP reward accrual, sampled every 50 blocks by the
  #      EndBlockHook and DELETED at settlement (033-order-book-settlement.sql).
  #      This is the authoritative record of who earned what, and it is the one
  #      thing here that cannot be recovered after a market settles.
  pipe "query_id BIGINT, participant_id BIGINT, wallet TEXT, block BIGINT, reward_percent NUMERIC(5,2)" \
    "SELECT r.query_id, r.participant_id, '0x'||encode(p.wallet_address,'hex'),
            r.block, r.reward_percent
       FROM main.ob_rewards r JOIN main.ob_participants p ON p.id = r.participant_id" \
    "INSERT INTO lp_rewards (query_id,participant_id,wallet,block,reward_percent)
       SELECT * FROM stg_r ON CONFLICT DO NOTHING;" stg_r
  local nr; nr=$(iq "SELECT count(*) FROM lp_rewards;")



  echo "$(date '+%H:%M:%S') h=$h  prints=${np:-0}  lp_rewards=${nr:-0}"
}

if [ "${1:-}" = "--loop" ]; then
  while true; do tick; sleep 60; done
else
  tick
fi

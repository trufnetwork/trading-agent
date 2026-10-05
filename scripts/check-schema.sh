#!/usr/bin/env bash
# Verify the node still exposes everything this repo reads.
#
#   scripts/check-schema.sh        # exits non-zero if anything is missing
#
# A node upgrade can rename or drop what the scripts depend on. Without this,
# the failure surfaces as a confusing SQL error mid-analysis, or worse as a
# query that still runs and returns a different meaning. Run it after any
# upgrade, and before trusting a number from a node you have not used recently.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.tn-env" ] && . "$ROOT/.tn-env"
PGHOST=${TN_PGHOST:-127.0.0.1}; PGPORT=${TN_PGPORT:-5432}
PGUSER=${TN_PGUSER:-postgres};  PGDB=${TN_PGDB:-kwild}
Q(){ psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAX -c "$1" 2>/dev/null; }

# schema.table:columns this repo actually reads. Keep in step with the scripts.
DEPS="
main.streams:id,stream_id,data_provider
main.primitive_events:stream_ref,event_time,value,created_at,tx_id
main.ob_queries:id,hash,query_components,settle_time,settled,winning_outcome,settled_at,min_order_size
main.ob_positions:query_id,participant_id,outcome,price,amount
main.ob_participants:id,wallet_address
main.ob_net_impacts:participant_id,query_id,collateral_change,is_negative
main.ob_order_events:query_id,event_type,block_height,block_timestamp
main.attestations:attestation_hash,result_canonical,signature,created_height,signed_height
main.maa_events:block_height,block_timestamp
kwil_erc20_meta.balances:address,balance,reward_id
kwil_erc20_meta.reward_instances:id,erc20_decimals
kwil_erc20_meta.transaction_history:block_height,block_timestamp
"

printf 'node binary : %s\n' "$(pgrep -af 'kwild[^[:space:]]* start' 2>/dev/null | grep -o 'kwild[^ /]*' | head -1 || echo '?')"
printf 'database    : %s:%s/%s\n\n' "$PGHOST" "$PGPORT" "$PGDB"

# An unreachable database must not read as a pass. Without this, a failed
# connection returns no rows, "no rows missing" looks like success, and a
# machine with no node at all reports its schema as complete.
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAXc 'SELECT 1' >/dev/null 2>&1; then
  echo "Cannot check: no database answering on $PGHOST:$PGPORT/$PGDB."
  exit 2
fi

# One query. Cheap enough to run on every status check rather than only after
# an upgrade, which is the wrong trigger anyway: schema drift comes from
# migrations, and those can land without the binary changing.
VALUES=$(printf '%s' "$DEPS" | awk 'NF{t=$0; sub(/:.*/,"",t); c=$0; sub(/^[^:]*:/,"",c);
  n=split(c,a,","); for(i=1;i<=n;i++) printf "(%s%s%s,%s%s%s),", "'"'"'", t, "'"'"'", "'"'"'", a[i], "'"'"'"}' | sed 's/,$//')

MISSING=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAX -F'.' -c "
WITH want(tbl,col) AS (VALUES $VALUES)
SELECT w.tbl, w.col FROM want w
LEFT JOIN information_schema.columns c
  ON c.table_schema = split_part(w.tbl,'.',1)
 AND c.table_name   = split_part(w.tbl,'.',2)
 AND c.column_name  = w.col
WHERE c.column_name IS NULL ORDER BY 1,2;" 2>/dev/null)

if [ -z "$MISSING" ]; then
  echo "All reads satisfied. Every table and column this repo queries is present."
  exit 0
fi
echo "Missing objects, so a query in this repo will break or change meaning:"
printf '  %s\n' $MISSING
echo
echo "Fix the affected queries in sql/ and scripts/, then re-run."
exit 1

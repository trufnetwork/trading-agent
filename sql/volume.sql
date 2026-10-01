-- Prediction market VOLUME and UNIQUE TRADERS, per the definition settled in
-- trufnetwork/indexer#102. Run against the node: no indexing required.
--
-- Volume = filled orders only, counted ONCE per trade, in CENTS of that
-- market's own collateral token. NEVER sum across bridges.
--
--   mint_fill / burn_fill  -> 100 * amount, YES row only (a pair locks $1)
--   direct_buy_fill        -> price * amount (the sell row is the same trade)
--   everything else        -> 0  (placements, cancels, split_placed, settled)
--
-- split_placed is a DEPOSIT, not volume: it locks collateral with no counterparty.
-- Unique traders = distinct participant over the FOUR fill types, which includes
-- direct_sell_fill: both sides of a match are traders, only the buy side is volume.
--
-- CAVEAT: trim_order_events() deletes old events. Retention measured at ~21 days
-- (310 of 1,236 markets). Lifetime figures are a FLOOR for any market created
-- before min(block_height) in ob_order_events. The `complete` flag says which.
--
-- Group by EXACT settle_time, not ::date. A stream can run several ladders in
-- one day and grouping by date silently merges them.

\set ON_ERROR_STOP on

WITH horizon AS (SELECT min(block_height) AS h FROM main.ob_order_events),
q AS (
  SELECT id, settle_time, bridge,
         rtrim(encode(decode(substring(encode(query_components,'hex')
              from 65 for 64),'hex'),'escape'), E'\\000') AS stream_id,
         created_at >= (SELECT h FROM horizon) AS complete
  FROM main.ob_queries
  WHERE NOT settled                       -- drop for all-time
),
v AS (
  SELECT q.stream_id, q.settle_time, q.bridge, q.id AS bucket, q.complete,
         COALESCE(SUM(CASE
           WHEN e.event_type IN ('mint_fill','burn_fill') AND e.outcome IS TRUE
             THEN 100 * e.amount
           WHEN e.event_type = 'direct_buy_fill'
             THEN e.price * e.amount
           ELSE 0 END), 0)::numeric(78,0) AS volume_cents,
         COUNT(DISTINCT e.participant_id) FILTER (
           WHERE e.event_type IN ('direct_buy_fill','direct_sell_fill',
                                  'mint_fill','burn_fill')) AS traders
  FROM q LEFT JOIN main.ob_order_events e ON e.query_id = q.id
  GROUP BY 1,2,3,4,5
)
SELECT stream_id,
       to_timestamp(settle_time)::timestamptz(0) AS settles,
       bridge,
       count(*)                       AS buckets,
       bool_and(complete)             AS full_history,
       sum(volume_cents)              AS volume_cents,
       round(sum(volume_cents)/100.0, 2) AS volume_usdc,
       max(traders)                   AS traders
FROM v
GROUP BY 1,2,3
ORDER BY sum(volume_cents) DESC;

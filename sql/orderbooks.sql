-- Order books inside ONE market. Pass the market's stream and settle time.
--
--   psql -h 127.0.0.1 -p $TN_PGPORT -U postgres -d kwild \
--     -v stream="'<stream_id from sql/market-scan.sql>'" \
--     -v settle=1789934100 -f sql/orderbooks.sql
--
-- A MARKET is the ladder of order books sharing (stream_id, settle_time).
-- An ORDER BOOK is one query_id, one strike band. See sql/market-scan.sql.
--
-- `pair_cost` is what one share of an LP-eligible pair ties up: $1.00 to mint
-- the YES/NO pair via place_split_limit_order, plus the NO buy lock of
-- (100 - p)/100. It is the number that decides how much size a small wallet can
-- post, and it is cheapest nearest the middle of the ladder.

\set ON_ERROR_STOP on
\pset footer off

WITH b AS (
  SELECT q.id, q.settle_time
  FROM main.ob_queries q
  WHERE NOT q.settled
    AND convert_from(decode(regexp_replace(
          substring(encode(q.query_components,'hex') from 65 for 64),
          '(00)+$', ''),'hex'),'UTF8') = :stream
    AND q.settle_time = :settle
),
t AS (
  SELECT query_id,
         MAX(ABS(price)) FILTER (WHERE price < 0 AND outcome)     AS y_bid,
         MIN(price)      FILTER (WHERE price > 0 AND outcome)     AS y_ask,
         MAX(ABS(price)) FILTER (WHERE price < 0 AND NOT outcome) AS n_bid,
         MIN(price)      FILTER (WHERE price > 0 AND NOT outcome) AS n_ask,
         SUM(amount) FILTER (WHERE price <> 0)                    AS resting,
         SUM(amount) FILTER (WHERE price = 0)                     AS held
  FROM main.ob_positions GROUP BY 1
),
f AS (
  SELECT query_id, count(*) FILTER (WHERE event_type='direct_buy_fill') AS fills
  FROM main.ob_order_events
  WHERE block_timestamp > extract(epoch FROM now())::INT8 - 86400*7 GROUP BY 1
)
SELECT b.id AS order_book,
       t.y_bid, t.y_ask, t.n_bid, t.n_ask,
       (t.y_ask - t.y_bid)                       AS spread,
       ((t.y_bid + t.y_ask)/2.0)                 AS y_mid,
       t.resting, t.held,
       COALESCE(f.fills,0)                       AS fills_7d,
       round((1.0 + (100 - (t.y_bid + t.y_ask)/2.0)/100.0)::numeric, 2) AS pair_cost_usd
FROM b
LEFT JOIN t ON t.query_id = b.id
LEFT JOIN f ON f.query_id = b.id
ORDER BY b.id;

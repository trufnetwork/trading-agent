-- Market scan. One row per MARKET.
--
--   psql -h 127.0.0.1 -p 5433 -U postgres -d kwild -f sql/market-scan.sql
--
-- TERMINOLOGY, as used on TRUF.NETWORK:
--
--   MARKET      a collection of ORDER BOOKS, typically 5, all settling at the
--               SAME EXACT TIME on the same stream. The ladder. Identified by
--               (stream_id, settle_time). This is what a person means by "a
--               market" and what the UI shows as one question.
--   ORDER BOOK  one `query_id`. One strike band. Has its own bids and asks.
--
-- So `ob_queries` holds ORDER BOOKS. The count of real markets is about a fifth
-- of its row count. Group on (stream_id, settle_time), never on ::date, since a
-- stream can run several markets in one day.
--
-- Order books on a ladder are quoted as one distribution, not independently.
-- Measured on CESR: YES mids 10 + 22 + 36 + 22 + 10 = 100.
--
-- For the books inside one market, see sql/orderbooks.sql.
--
-- NOTE: strip trailing NUL padding in HEX before decoding. rtrim(x, E'\\000')
-- does NOT strip NULs, it strips the character set {backslash, 0}, which
-- silently corrupts any stream id ending in 0.
--
-- Read-only, creates nothing. Do NOT install as a stored procedure in the
-- node's database: that is kwild's consensus state and `kwild setup reset`
-- drops it.

\set ON_ERROR_STOP on
\pset footer off

WITH book AS (
  -- Identity of an order book is the COMPOSITE (data_provider, stream_id).
  -- 564 stream_ids are shared across providers, so joining on stream_id alone
  -- can silently read another provider's data.
  --   data_provider : ABI word 0, address in its low 20 bytes -> hex 25..64
  --   stream_id     : ABI word 1, ASCII NUL-padded            -> hex 65..128
  SELECT q.id, q.settle_time, q.min_order_size,
         lower('0x'||substring(encode(q.query_components,'hex') from 25 for 40)) AS provider,
         convert_from(decode(regexp_replace(
           substring(encode(q.query_components,'hex') from 65 for 64),
           '(00)+$',''),'hex'),'UTF8') AS stream_id
  FROM main.ob_queries q
  WHERE NOT q.settled AND q.settle_time > extract(epoch FROM now())
),
sref AS (
  -- Resolve the composite to streams.id ONCE. main.streams has no index on
  -- stream_id, so each text lookup is a seq scan over ~260k rows. One scan for
  -- all distinct streams beats one per market.
  SELECT DISTINCT s.id AS sid, lower(s.data_provider) AS provider, s.stream_id
  FROM main.streams s
  JOIN (SELECT DISTINCT provider, stream_id FROM book) u
    ON u.stream_id = s.stream_id AND u.provider = lower(s.data_provider)
),
decided AS (
  SELECT d.provider, d.stream_id, d.settle_time,
         EXISTS (SELECT 1 FROM main.primitive_events pe
                 WHERE pe.stream_ref = r.sid
                   AND pe.event_time <= d.settle_time
                   AND pe.event_time >= d.settle_time - 86400) AS is_decided
  FROM (SELECT DISTINCT provider, stream_id, settle_time FROM book) d
  JOIN sref r ON r.stream_id = d.stream_id AND r.provider = d.provider
),
tob AS (
  SELECT query_id,
         MAX(ABS(price)) FILTER (WHERE price < 0 AND outcome) AS y_bid,
         MIN(price)      FILTER (WHERE price > 0 AND outcome) AS y_ask,
         SUM(amount)                                          AS depth
  FROM main.ob_positions GROUP BY 1
),
elig AS (   -- same participant, complementary price, EQUAL SIZE
  SELECT y.query_id, count(*) AS pairs, count(DISTINCT y.participant_id) AS lps
  FROM (SELECT query_id,participant_id,price,amount
          FROM main.ob_positions WHERE outcome AND price > 0) y
  JOIN (SELECT query_id,participant_id,ABS(price) AS price,amount
          FROM main.ob_positions WHERE NOT outcome AND price < 0) n
    ON n.query_id=y.query_id AND n.participant_id=y.participant_id
   AND n.price = 100 - y.price AND n.amount = y.amount
  GROUP BY 1
),
act AS (
  SELECT query_id, count(*) FILTER (WHERE event_type='direct_buy_fill') AS fills
  FROM main.ob_order_events
  WHERE block_timestamp > extract(epoch FROM now())::INT8 - 86400*7
  GROUP BY 1
)
SELECT b.stream_id,
       substr(b.provider,1,10)||'..' AS provider,
       to_timestamp(b.settle_time)::timestamptz(0)                            AS settles,
       round(((b.settle_time - extract(epoch FROM now()))/3600.0)::numeric,0)  AS hrs,
       CASE WHEN bool_or(d.is_decided) THEN 'DECIDED' ELSE '-' END            AS decided,
       count(*)                                        AS books,
       count(*) FILTER (WHERE t.y_bid IS NOT NULL
                          AND t.y_ask IS NOT NULL)     AS quoted,
       sum(COALESCE(t.depth,0))                        AS depth,
       min(t.y_ask - t.y_bid)                          AS tightest,
       max(t.y_ask - t.y_bid)                          AS widest,
       sum(COALESCE(e.pairs,0))                        AS elig_pairs,
       max(COALESCE(e.lps,0))                          AS lps,
       sum(COALESCE(a.fills,0))                        AS fills_7d,
       round((min(b.min_order_size)/1e6)::numeric,2)   AS min_usdc,
       string_agg(b.id::text, ',' ORDER BY b.id)       AS order_books
FROM book b
JOIN decided d ON d.stream_id = b.stream_id AND d.provider = b.provider
                AND d.settle_time = b.settle_time
LEFT JOIN tob  t ON t.query_id = b.id
LEFT JOIN elig e ON e.query_id = b.id
LEFT JOIN act  a ON a.query_id = b.id
GROUP BY b.provider, b.stream_id, b.settle_time
HAVING count(*) FILTER (WHERE t.y_bid IS NOT NULL AND t.y_ask IS NOT NULL) > 0
ORDER BY bool_or(d.is_decided) ASC,
         sum(COALESCE(e.pairs,0)) ASC,
         sum(COALESCE(t.depth,0)) DESC;

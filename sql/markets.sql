-- Prediction market reads against a local TN node.
-- Connect: psql -h 127.0.0.1 -p $TN_PGPORT -U postgres -d kwild
--
-- Kwil stores each namespace as a Postgres schema of the SAME NAME.
-- The prediction market protocol lives in the `main` namespace => schema `main`.
-- NOTE: the `ds_` prefix in kwil-db source is a changeset FILTER, not the
-- schema naming rule. Tables are main.ob_queries, NOT ds_main.ob_queries.
--
-- PRICE SEMANTICS in main.ob_positions (confirmed against migration 038):
--   price = 0   -> holding (shares owned, not listed)
--   price > 0   -> SELL order at that price, in cents (1..99)
--   price < 0   -> BUY  order at ABS(price) cents (1..99)
--   best_bid = MAX(ABS(price)) WHERE price < 0
--   best_ask = MIN(price)      WHERE price > 0
--   spread   = best_ask - best_bid
--
-- outcome: TRUE = YES, FALSE = NO
-- amount is share count (INT8). Collateral amounts elsewhere are wei (18 dp).


-- ===========================================================================
-- 1. Live markets, with time remaining
-- ===========================================================================
SELECT
    q.id                                            AS market_id,
    encode(q.hash, 'hex')                           AS query_hash,
    '0x' || encode(q.creator, 'hex')                AS creator,
    q.bridge,
    q.settle_time,
    to_timestamp(q.settle_time) AT TIME ZONE 'UTC'  AS settles_utc,
    (q.settle_time - extract(epoch FROM now())::INT8) / 3600.0 AS hours_left,
    q.min_order_size,
    q.created_at                                    AS created_block
FROM main.ob_queries q
WHERE q.settled = false
ORDER BY q.settle_time;


-- ===========================================================================
-- 2. Top of book for every live market, both outcomes
-- ===========================================================================
WITH tob AS (
    SELECT
        p.query_id,
        p.outcome,
        MAX(ABS(p.price)) FILTER (WHERE p.price < 0) AS best_bid,
        MIN(p.price)      FILTER (WHERE p.price > 0) AS best_ask,
        SUM(p.amount)     FILTER (WHERE p.price < 0) AS bid_shares,
        SUM(p.amount)     FILTER (WHERE p.price > 0) AS ask_shares,
        SUM(p.amount)     FILTER (WHERE p.price = 0) AS held_shares
    FROM main.ob_positions p
    GROUP BY p.query_id, p.outcome
)
SELECT
    q.id AS market_id,
    CASE WHEN t.outcome THEN 'YES' ELSE 'NO' END AS side,
    t.best_bid,
    t.best_ask,
    t.best_ask - t.best_bid                       AS spread,
    (t.best_bid + t.best_ask) / 2.0               AS mid,
    t.bid_shares,
    t.ask_shares,
    t.held_shares,
    to_timestamp(q.settle_time) AT TIME ZONE 'UTC' AS settles_utc
FROM tob t
JOIN main.ob_queries q ON q.id = t.query_id
WHERE q.settled = false
ORDER BY q.settle_time, q.id, t.outcome DESC;


-- ===========================================================================
-- 3. Full depth ladder for one market  (:market_id)
-- ===========================================================================
SELECT
    CASE WHEN outcome THEN 'YES' ELSE 'NO' END AS side,
    CASE WHEN price < 0 THEN 'BID'
         WHEN price > 0 THEN 'ASK'
         ELSE 'HOLD' END                       AS kind,
    ABS(price)                                 AS price_cents,
    SUM(amount)                                AS shares,
    COUNT(*)                                   AS orders
FROM main.ob_positions
WHERE query_id = :market_id
GROUP BY outcome, kind, ABS(price)
ORDER BY side, kind, price_cents DESC;


-- ===========================================================================
-- 4. Recent order events (fills, placements, cancels)
--    NOTE: ob_order_events is EPHEMERAL on-chain. trim_order_events() deletes
--    old rows once the upstream indexer has synced them, so this is a rolling
--    window, not full history. Persist it if you want history.
-- ===========================================================================
SELECT
    e.id,
    e.block_height,
    to_timestamp(e.block_timestamp) AT TIME ZONE 'UTC' AS ts_utc,
    e.query_id                                   AS market_id,
    e.event_type,
    CASE WHEN e.outcome THEN 'YES' ELSE 'NO' END AS side,
    e.price,
    e.amount,
    '0x' || encode(pa.wallet_address, 'hex')     AS wallet,
    encode(e.tx_hash, 'hex')                     AS tx_hash
FROM main.ob_order_events e
JOIN main.ob_participants pa ON pa.id = e.participant_id
ORDER BY e.id DESC
LIMIT 100;


-- ===========================================================================
-- 5. A wallet's portfolio  (:wallet_hex without 0x)
-- ===========================================================================
SELECT
    p.query_id                                   AS market_id,
    CASE WHEN p.outcome THEN 'YES' ELSE 'NO' END AS side,
    CASE WHEN p.price < 0 THEN 'open buy'
         WHEN p.price > 0 THEN 'open sell'
         ELSE 'holding' END                      AS kind,
    ABS(p.price)                                 AS price_cents,
    p.amount                                     AS shares,
    to_timestamp(p.last_updated) AT TIME ZONE 'UTC' AS updated_utc
FROM main.ob_positions p
JOIN main.ob_participants pa ON pa.id = p.participant_id
WHERE pa.wallet_address = decode(:'wallet_hex', 'hex')
ORDER BY p.query_id, p.outcome DESC, p.price;


-- ===========================================================================
-- 6. Identifying what a market is ABOUT
--    ob_queries carries no human-readable metadata. Identity lives in
--    query_components: ABI-encoded (address data_provider, bytes32 stream_id,
--    string action_id, bytes args).
--    Decode off-chain (eth_abi) or via the tn_utils.unpack_query_components
--    precompile, then join the stream to its metadata:
-- ===========================================================================
SELECT
    s.stream_id,
    s.data_provider,
    s.stream_type,
    m.metadata_key,
    COALESCE(m.value_s, m.value_ref, m.value_i::TEXT, m.value_f::TEXT,
             m.value_b::TEXT)                    AS value
FROM main.streams s
LEFT JOIN main.metadata m
       ON m.data_provider = s.data_provider
      AND m.stream_id     = s.stream_id
      AND m.disabled_at IS NULL
WHERE s.stream_id = :'stream_id'
ORDER BY m.metadata_key;

-- Which metadata keys exist at all (run once to learn the vocabulary):
--   SELECT metadata_key, COUNT(*) FROM main.metadata
--   WHERE disabled_at IS NULL GROUP BY 1 ORDER BY 2 DESC;

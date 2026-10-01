-- Custom indexing database for TRUF.NETWORK prediction markets.
-- Runs in its OWN Postgres instance (port 5434), never inside kwild's cluster.
--
-- WHY THIS EXISTS. The node is not an archive. Three things are destroyed:
--
--   1. main.ob_order_events is EPHEMERAL. trim_order_events() deletes rows once
--      the upstream indexer has consumed them.
--   2. main.ob_positions rows are DELETED at settlement, so the closing book of
--      every settled market is lost.
--   3. tn_digest is ENABLED on mainnet (digest_config.enabled = true, every 2h)
--      and collapses each stream-day of main.primitive_events into OHLC rows,
--      keeping only the latest created_at and preserving ~2 days of raw data.
--      Revision history is therefore destroyed within days. Measured 2026-09-18:
--      across the 11 streams backing open markets, 35,000+ points retain exactly
--      ONE extra row. That is digest at work, not an absence of revisions.
--
-- So revision behaviour CANNOT be fitted from node history. It can only be
-- captured live, which is what this database is for.

CREATE TABLE IF NOT EXISTS blocks (
    height          BIGINT PRIMARY KEY,
    block_time      BIGINT NOT NULL,          -- unix seconds
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE blocks IS
 'Height to wall-clock map. The node exposes no such table, so publication lag
  has to be approximated from ob_order_events. Recording it directly removes
  that approximation.';

-- Every write to a stream, including revisions of the same event_time.
-- PK mirrors the node: (stream, event_time, created_at). A revision is a second
-- row with the same event_time and a higher created_at.
CREATE TABLE IF NOT EXISTS stream_prints (
    stream_id       TEXT   NOT NULL,
    event_time      BIGINT NOT NULL,
    created_at      BIGINT NOT NULL,          -- block height of the write
    value           NUMERIC(36,18) NOT NULL,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (stream_id, event_time, created_at)
);
CREATE INDEX IF NOT EXISTS sp_stream_created ON stream_prints (stream_id, created_at);
CREATE INDEX IF NOT EXISTS sp_created        ON stream_prints (created_at);

-- Order lifecycle. Captured before trim_order_events() removes it.
CREATE TABLE IF NOT EXISTS order_events (
    id              BIGINT PRIMARY KEY,
    tx_hash         TEXT   NOT NULL,
    query_id        BIGINT NOT NULL,
    wallet          TEXT   NOT NULL,
    event_type      TEXT   NOT NULL,
    outcome         BOOLEAN NOT NULL,
    price           INT    NOT NULL,
    amount          BIGINT NOT NULL,
    counterparty    TEXT,
    block_height    BIGINT NOT NULL,
    block_timestamp BIGINT NOT NULL,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS oe_query   ON order_events (query_id, block_height);
CREATE INDEX IF NOT EXISTS oe_wallet  ON order_events (wallet, block_height);
CREATE INDEX IF NOT EXISTS oe_height  ON order_events (block_height);

-- Market definitions, including terminal state. ob_queries survives settlement
-- on the node, but positions do not, so snapshot the outcome alongside.
CREATE TABLE IF NOT EXISTS markets (
    query_id        BIGINT PRIMARY KEY,
    query_hash      TEXT   NOT NULL,
    stream_id       TEXT,
    action_id       TEXT,
    data_provider   TEXT,
    settle_time     BIGINT NOT NULL,
    settled         BOOLEAN NOT NULL,
    winning_outcome BOOLEAN,
    settled_at      BIGINT,
    created_at      BIGINT NOT NULL,
    creator         TEXT   NOT NULL,
    bridge          TEXT   NOT NULL,
    min_order_size  BIGINT,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mk_stream ON markets (stream_id, settle_time);
CREATE INDEX IF NOT EXISTS mk_settle ON markets (settle_time);

-- Periodic book snapshots. ob_positions is deleted at settlement, so without
-- these the closing book of every settled market is unrecoverable.
CREATE TABLE IF NOT EXISTS book_snapshots (
    taken_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    height          BIGINT NOT NULL,
    query_id        BIGINT NOT NULL,
    outcome         BOOLEAN NOT NULL,
    best_bid        INT,
    best_ask        INT,
    bid_shares      BIGINT,
    ask_shares      BIGINT,
    held_shares     BIGINT,
    PRIMARY KEY (height, query_id, outcome)
);
CREATE INDEX IF NOT EXISTS bs_query ON book_snapshots (query_id, height);

-- Ingest cursors, one row per source table.
CREATE TABLE IF NOT EXISTS sync_state (
    source          TEXT PRIMARY KEY,
    last_height     BIGINT NOT NULL DEFAULT 0,
    last_id         BIGINT NOT NULL DEFAULT 0,
    rows_ingested   BIGINT NOT NULL DEFAULT 0,
    last_run        TIMESTAMPTZ
);
INSERT INTO sync_state (source) VALUES
    ('stream_prints'), ('order_events'), ('markets'), ('book_snapshots')
ON CONFLICT (source) DO NOTHING;

-- Revisions, the thing the node destroys. Empty until one is observed live.
CREATE OR REPLACE VIEW revisions AS
SELECT stream_id, event_time,
       count(*)                       AS versions,
       min(created_at)                AS first_height,
       max(created_at)                AS latest_height,
       min(value)                     AS min_value,
       max(value)                     AS max_value,
       max(value) - min(value)        AS spread
FROM stream_prints
GROUP BY stream_id, event_time
HAVING count(*) > 1;

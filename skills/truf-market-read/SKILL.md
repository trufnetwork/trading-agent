---
name: truf-market-read
description: >
  Read TRUF.NETWORK prediction markets directly from the local node's Postgres.
  Use before any analysis, pricing, or trading task, and whenever a query
  returns a number whose meaning is not certain. Covers market versus order book
  terminology, the composite stream key, price and side encoding, the pair
  invariant, what counts as volume, how markets resolve and settle, and the
  specific column meanings that produce wrong answers when assumed.
---

# Read the markets

Market state lives in schema `main` of the node's Postgres. Query it with plain
SQL. Never write to it, because that database is consensus state.

```bash
psql -h 127.0.0.1 -p 5433 -U postgres -d kwild
```

## Rule 0: verify what a value MEANS before computing on it

This is the dominant failure mode in this schema, well ahead of wrong joins or
slow queries. The column names are honest but incomplete, so a query can be
syntactically perfect, run fast, and return a confidently wrong number.

Check the defining migration or the live schema before you aggregate anything
you have not aggregated before.

| Looks like | Actually is |
|------------|-------------|
| `query_id` is a market | One **order book**, one strike band |
| `price` is a price | Price **and side**, see below |
| `collateral_change > 0` filters inflows | A **magnitude**, direction is in `is_negative` |
| `stream_id` identifies a stream | Only with `data_provider`, the key is **composite** |
| a fill is any order event | Only events with a **counterparty** |
| `created_at` is when a print was posted | The **latest revision**, the digest deletes earlier ones |
| `metadata(data_provider, stream_id)` | Normalized to `metadata.stream_ref -> streams.id` |

## Terminology, which the schema does not encode

- **MARKET**, also called the ladder. A collection of order books, typically 5,
  all settling at the **same exact time** on the same stream. This is what a
  person means by "a market" and what a UI shows as one question. Identified by
  `(data_provider, stream_id, settle_time)`.
- **ORDER BOOK**. One `query_id`. One strike band. Its own bids and asks.

So `ob_queries` holds **order books**, and the number of real markets is about a
fifth of its row count. Group on `(data_provider, stream_id, settle_time)`,
never on a date, because a stream can run several markets in one day.

Books on a ladder are quoted as one distribution rather than independently.
Measured on a live 5-book ladder, the YES mids were 10, 22, 36, 22, and 10,
summing to 100.

The strike bands are not columns. They live inside the `query_components` ABI
blob and need the SDK to decode.

## The stream key is composite, by design

Two providers can publish the identical `stream_id`, and 564 of them do. Joining
on `stream_id` alone reads another provider's data and is correct only by luck.

```sql
-- data_provider : ABI word 0, address in its low 20 bytes -> hex 25..64
-- stream_id     : ABI word 1, ASCII NUL-padded            -> hex 65..128
SELECT lower('0x'||substring(encode(query_components,'hex') from 25 for 40)) AS provider,
       convert_from(decode(regexp_replace(
         substring(encode(query_components,'hex') from 65 for 64),
         '(00)+$',''),'hex'),'UTF8') AS stream_id
FROM main.ob_queries WHERE id = $1;
```

Strip the NUL padding **in hex**, as above. `rtrim(x, E'\\000')` does not strip
NULs, it strips the character set `{backslash, 0}`, and it silently corrupts any
stream id ending in `0`.

`main.streams` has no index on `stream_id`, so each text lookup is a sequential
scan over roughly 260k rows. Resolve the composite to `streams.id` **once** and
join on the integer afterwards. Doing this turned a 2.6 second scan into 0.285
seconds.

## Price encodes side as well as level

In `main.ob_positions`:

| `price` | Meaning |
|---------|---------|
| `= 0` | a **holding**, shares owned outright |
| `> 0` | a resting **sell** at that price |
| `< 0` | a resting **buy** at `ABS(price)` |

```sql
MAX(ABS(price)) FILTER (WHERE price < 0 AND outcome)     AS yes_bid,
MIN(price)      FILTER (WHERE price > 0 AND outcome)     AS yes_ask,
MAX(ABS(price)) FILTER (WHERE price < 0 AND NOT outcome) AS no_bid
```

You buy at the **ask**. Comparing a probability estimate to the mid overstates
your edge by half the spread on every line.

## The pair invariant

Shares exist only as one dollar YES plus NO pairs. So YES outstanding always
equals NO outstanding, and the count of winning shares equals the count of
pairs, exactly.

Use this as a check on any position or open interest calculation. If your YES
and NO totals disagree, your query is wrong, not the chain.

## What counts as volume

**A fill is exactly an event with a counterparty. Nothing else is.**

| Event | Counterparty | Volume |
|-------|--------------|--------|
| `direct_buy_fill` | yes | `price * amount` |
| `direct_sell_fill` | yes | `price * amount` |
| `mint_fill` | yes | `100 * amount`, YES row only |
| `burn_fill` | yes | `100 * amount`, YES row only |
| `split_placed` | **no** | not volume, it is a unilateral deposit |

`mint_fill` and `burn_fill` are volume. They have real wallet counterparties and
they carry price discovery, even though one side is creating or destroying a
pair. `split_placed` is a deposit and carries none.

Derive trade counts, unique traders, and volume from **one allowlist**. If fills
are in your volume they must be in your trade count too.

Volume is recorded **per bridge**. Never sum across bridges.

## How a market resolves

The settling value is the latest print inside the resolution window.

```sql
WHERE event_time <= $settle_time
  AND event_time >= $settle_time - 86400
ORDER BY event_time DESC, created_at DESC
-- frozen_at IS NULL means the latest revision
```

Note `event_time` is the data's own timestamp and `created_at` is the block
height at which the surviving row was written.

**`created_at` is the LAST revision, not the first publication.** `tn_digest`
deletes every other row for a stream-day, so when a provider re-posts a day it
already published, the original is destroyed. A stream that posted daily and
later re-posted three weeks in one transaction leaves exactly the same footprint
as one that only ever posted in a single batch.

So **do not measure publication lag from `created_at`**, and do not conclude a
stream is late because its rows share a write height. Use settled markets
instead. An attestation is immutable and captures `result_canonical` at
attestation time, so a winning band proves what the chain held at that
`settle_time`.

Observed 2026-09-20: a stream whose 18 September prints all carried one
`created_at` from a 19 September transaction had already settled markets on
those values on 17 and 18 September.

**An attestation proves a value existed, not who wrote it or when.** The
archival chain runs attestation, then the writing transaction, then the block
holding it, and only the first link is consensus state. A snapshot-synced node
never received the blocks below its snapshot height, and the digest deleted the
`primitive_events` row that carried the original `tx_id`.

Tracing a print back to its transaction therefore needs an archival node, a full
block sync from genesis, or an off-chain chain indexer such as Trufscan.

## How settlement actually fires

`settle_market` does **not** re-run the query. It reads `result_canonical` from
a signed attestation, so **the outcome is fixed at attestation time**.

The node requests attestations itself. `tn_settlement`'s scheduler, leader only,
runs `*/5 * * * *` and selects `settled = false AND settle_time <= now()`. The
comparison is inclusive, so a ladder is picked up by the tick **at**
`settle_time`.

**A publisher can change its broadcast schedule at any time, without telling
anyone.** This is a permissionless network, so there is no announcement and
nothing to version-check. Detect it from the prints.

**Cadence is the signal that matters.** A change in how often prints arrive
changes the stream's behaviour for every future market, so cut any timing base
rate at that point.

**A change of broadcast time is arbitrary**, including a move between
observation-dated and publish-time stamps. It carries no information for a
market opened after the change, as long as the new time is consistent. The one
exception is a market that was already open when the time moved, because that
book was priced under the old schedule.

**This does not damage analysis.** Only the broadcast window changed, so the
value series is continuous and every price model built on it keeps the full
history. What resets is the settlement-timing base rate, which describes a
schedule that no longer runs.

Detect the shape from the timestamp. An `event_time` that is an exact multiple
of 86400 is observation-dated, anything else is publish-time.

**Print arrival is never a trigger.** Attestation captures whatever state exists
at `settle_time`. A provider that publishes late simply resolves on the previous
value, predictably, and that is the design rather than a fault.

That makes publication lag a **tradeable property of the stream**. Where a
stream reliably publishes after `settle_time`, the resolving value is already on
chain and the outcome is knowable in advance.

One real bug applies here. The scheduler broadcasts one attestation request per
order book and waits for each to commit, so a ladder is captured one book per
block.

If a print lands inside that window the ladder splits and settles with two
winners or none. Tracked as trufnetwork/node#1430, and `scripts/edge.py` reports
a stream's exposure to it.

## Data you cannot get back

`tn_digest` is enabled and runs every two hours. It collapses stream-days into
OHLC and destroys intra-day revisions within about two days.

If you need revision history, capture it forward from now. You cannot backfill
an observation time, and a column recording when *you* first saw a value is
meaningless if you populate it retrospectively.

## Reference queries

| File | Returns |
|------|---------|
| [sql/market-scan.sql](../../sql/market-scan.sql) | one row per **market**, all open ladders ranked |
| [sql/orderbooks.sql](../../sql/orderbooks.sql) | the books inside one market, with pair cost |
| [sql/volume.sql](../../sql/volume.sql) | volume and unique traders, no indexing needed |
| [sql/markets.sql](../../sql/markets.sql) | reference queries with price semantics documented |

Markets carry no on-chain metadata identifying what they are about. Verified
across all 259,575 streams: `main.metadata` holds operational keys only. A
human-readable name exists nowhere on chain.

Names therefore come from off chain, and they are optional. Build a local cache
once if you want tickers in the output.

```bash
scripts/refresh-streams.py     # reads the public page for each of your streams
```

It fetches `https://trufscan.io/<data_provider>/<stream_id>`, one plain GET per
stream, and pulls the record out of the page's hydration payload. No API key and
no undocumented endpoint, so the only thing that can break it is the page
itself changing.

Nothing depends on it. Without the cache the tools print the stream id, which is
the identifier that actually matters.

## If you build an index

Index around **open questions, not around tables**. Never capture a table you
cannot name a question for. The cost of over-capture is query speed and noise,
not storage.

Do not mirror consensus tables you can already query. Blocks, order events, and
raw prints are all available live, and copying them buys nothing.

## Evidence

- [protocol/06-signal-architecture.md](../../protocol/06-signal-architecture.md), the one to read first
- [protocol/07-indexer.md](../../protocol/07-indexer.md)
- [protocol/08-operations.md](../../protocol/08-operations.md)

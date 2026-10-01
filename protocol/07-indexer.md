# Step 7 — Custom indexing database

Captures what the node deliberately destroys. Runs in its **own Postgres
instance** on port 5434, never inside kwild's cluster.

## What the node destroys, and why that matters

Three separate mechanisms, all verified on mainnet 2026-09-18:

**1. `tn_digest` is ENABLED and erases revision history.**

```sql
SELECT * FROM main.digest_config;   -- enabled = t, schedule '0 */2 * * *'
```

`batch_digest` collapses each stream-day of `main.primitive_events` into OHLC
rows and deletes the rest, ordering by `created_at DESC` so only the newest
revision survives. It preserves `$preserve_past_days` (default 2) of raw data.

Measured consequence: across the 11 streams backing open markets, **35,000+
data points retain exactly ONE extra row**. That is not an absence of revisions,
it is digest having already removed the evidence.

**Nuance, because the first version of this doc overstated it.** Digest keeps
**OHLC** rows, so a day whose value *changed* intraday must leave 2 or more
rows. History therefore still bounds revision behaviour:

```
1,974 stream-days across the 11 live-market streams (180d)
  -> exactly ONE day kept more than one row
  -> avg 1.00 rows/day for 10 of 11 streams
```

So these streams historically **never revise a day's value after the fact**, a
prior of roughly 0.05%. What history cannot show is repeated *identical* prints,
since OHLC collapses those to a single row. A revision that does not change the
value cannot change an outcome, so the measurable part is the part that matters.

What still requires live capture is the exact timing and magnitude of a revision
when one does occur, plus print counts within a day. That is what this database
adds on top of the historical prior.

**2. `main.ob_order_events` is ephemeral.** `trim_order_events()` deletes rows
once the upstream indexer has consumed them.

**3. `main.ob_positions` rows are deleted at settlement.** Without periodic
snapshots, the closing book of every settled market is unrecoverable.

`duplicate_prune_config.enabled` is **false** on mainnet, so that one is not a
factor today. It could be switched on, which would remove repeated identical
values older than 30 days.

## Why a separate Postgres instance

**The durability argument is the real one**, and it is worth stating precisely
because two intuitive reasons turn out to be wrong.

*Not* a consensus risk, as far as the code shows. The changeset filter is an
allowlist of registered Kwil namespaces, not a prefix match:

```go
func (n *namespaceManager) Filter(ns string) bool {
    _, ok := n.namespaces[ns]; return ok      // app/node/namespace_manager.go
}
```

An unregistered schema is excluded from changeset hashing, so writes to it would
not enter the consensus hash.

*Not* available for cross-database joins either. **Postgres has no
cross-database references, even within one instance:**

```
ERROR:  cross-database references are not implemented: "kwild.main.ob_queries"
```

So a second database on the node's Postgres gains nothing over a separate
instance. Both need `postgres_fdw` or `dblink`. Only same-database-different-
schema gives native joins.

**And that is the option that dies.** `kwild setup reset` runs
`DROP DATABASE` (`app/setup/reset.go:133`). State sync restore itself is safe,
streaming a schema-scoped dump into the existing database with `--clean`
commented out, but a reset, a fresh resync or fork recovery destroys everything
in there. This database exists to hold what the chain no longer has, so its
lifecycle must not be tied to the node's. The operator guide also asks for a
dedicated cluster.

Use `postgres_fdw` from the indexer when a join against live node state is
genuinely needed.

**It is NOT because analytics are heavy.** They are not. A representative
per-stream query is an index-only scan:

```
SELECT count(*), min(event_time), max(event_time)
  FROM main.primitive_events WHERE stream_ref = 231559;   -- 12,312 rows

Index Only Scan using pe_stream_created_idx
  actual time = 17.9 ms, Buffers: shared hit=9593 (all cache), CPU 0.05%
```

Normal analytical load is free, because `pe_stream_created_idx` is
`(stream_ref, created_at, event_time)` and real questions are scoped to one
stream. Baseline for a node at chain tip is **0.15-0.25% CPU, ~350 MB**.

The cautionary note is about *bad* queries, not analytics in general. A
`count(DISTINCT (stream_ref, event_time))` across all 75M rows of the largest
table drove that instance to 93% CPU and kept running after the client was
killed. Two lessons worth more than the design conclusion:

- Scope queries to a stream. Unbounded scans of `primitive_events` are
  pathological and never necessary.
- Killing a client does not always stop the backend. Use
  `pg_cancel_backend(pid)` and verify with `pg_stat_activity`.

Resource notes, to avoid treating non-constraints as constraints: disk is a
non-issue (328 GB free, node DB 22 GB, indexer 68 MB). Memory is the only real
budget at 14 GB total, shared with two Postgres instances and kwild, and even
that is not currently binding. The indexer container is capped at 2 GB.

```bash
docker run -d --name tn-indexer -p 127.0.0.1:5434:5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=tnidx \
  -v tn-idxdata:/var/lib/postgresql/data \
  --shm-size=512m --memory=2g --restart unless-stopped postgres:16-alpine

psql -h 127.0.0.1 -p 5434 -U postgres -d tnidx -f sql/indexer-schema.sql
```

## Ingest

`scripts/index-tick.sh` copies new rows from the node into the indexer.
Idempotent, safe on a loop or cron, scoped to streams that back markets rather
than all 259k on the network.

```bash
scripts/index-tick.sh          # one tick
scripts/index-tick.sh --loop   # every 60s
```

### Two traps that cost real time here

**Do not use `COPY ... FROM PROGRAM`.** It executes *inside* the indexer
container, whose `127.0.0.1` is not the host, so it cannot reach the node
database. Run both `psql` processes on the host and pipe them together.

**Advance cursors only on success.** The first version updated `sync_state`
unconditionally. When the copy failed, the cursor still jumped to the current
height, and every later run then queried `created_at > <height>` and found
nothing. A silent, self-perpetuating no-op. Cursor advancement must be gated on
the pipe's exit status.

Also: `convert_from(..., 'UTF8')` rejects NUL bytes, and the `bytes32 stream_id`
is NUL-padded. Strip the padding in hex first:
`regexp_replace(hex, '(00)+$', '')`.

## Index around OPEN QUESTIONS, not around tables

This is the governing rule, and the first three versions of this indexer broke
it. "Does the node destroy it" is necessary but nowhere near sufficient. The
node destroys plenty that nothing needs.

**Every captured table must name the open question it answers.** If you cannot
name one, do not capture it. Interesting, cheap, and irrecoverable are all
insufficient. Data captured without a question is data you will later defend
rather than use.

**Destruction is not value.** The node destroys a great deal, and at scale it
will destroy far more, almost none of which anyone needs to see. "It will be
gone forever" feels like a reason and is not one.

**The cost is query performance, not storage.** This is the part that is easy to
underrate. Storage is free at these volumes, so hoarding looks harmless, but
every unused table is noise in the database the indexer exists to make fast. It
lands in plans, competes for cache, inflates vacuum and backup, and makes the
queries that matter slower and harder to write. An indexer that keeps everything
ends up needing its own tuning, which defeats the point of having built it.

**Backfill is setup, not standing collection.** A new question may need history
to bootstrap. Backfill it once, as part of setting up that question, then store
**the answer** rather than keeping the raw material streaming. A per-stream lag
distribution is worth keeping. The 58,897 rows used to compute it are not.

**Never backfill into a live-capture table.** This is a correctness rule, not a
tidiness one. `stream_prints.first_seen` means "when the indexer observed this
write", which is what publication lag is. A backfilled row carries a
`first_seen` of the copy time, so mixing the two silently poisons every lag
calculation. The first version of this indexer pulled 36,516 historical rows on
its first tick and would have reported nonsense lag for all of them.

A fresh install therefore starts its cursor at the **current height**, not zero.
Bootstrap questions by querying `main.primitive_events` on the node directly,
which still holds that history.

### Current captures

| Table | Open question | What destroys it |
|-------|---------------|------------------|
| `stream_prints` | has the settling print landed, and when do prints arrive | `tn_digest` collapses revisions within ~2 days |
| `lp_rewards` | are we earning LP rewards, and what share | `ob_rewards` is deleted at settlement |

That is the whole indexer. 16 MB.

### Dropped, with reasons

Each of these was captured on the "node destroys it" test alone, and each failed
the question test:

- **`order_events`** (120,058 rows). Every application turned out to be served
  elsewhere: PnL and volume by `ob_net_impacts`, reward attribution by
  `ob_rewards`, market decidedness by `primitive_events`. Also does not scale:
  that volume came from **11 wallets**, and participant counts are expected to
  reach thousands. Query it **per market, on demand**, when a question needs it.
- **`blocks`** (58,897 rows). Existed to map block height to wall clock for
  publication lag. Superseded by `stream_prints.first_seen`, which is both
  simpler and **more correct**: what matters for trading is when the data became
  visible to us, not what the chain clock recorded. Verified to agree, 0.98h
  against 1.0h on the same stream.
- **`book_snapshots`** (growing ~260 rows/tick). No trading question named it.
- **`markets`**. `ob_queries` is durable on the node. Market 426 settled in July
  and its row is still there, while its events are long trimmed. This was a copy
  of something nobody deletes.

### Query the node directly for anything durable

`ob_queries`, `ob_net_impacts` (395k rows, no trim) and `ob_positions` are all
live on the node. Copying durable state into an indexer adds staleness and a
second source of truth for no gain.

## Publication lag, without a block-time table

```sql
SELECT stream_id, avg(EXTRACT(epoch FROM first_seen) - event_time)/3600.0 AS lag_h
FROM stream_prints GROUP BY 1;
```

`first_seen` is when the indexer observed the write, which is the number that
matters for trading. No height-to-time mapping, no `blocks` table, and it stays
correct as the node trims.

The `revisions` view reports any `(stream_id, event_time)` with more than one
version. It is empty until one is observed live, which is the point.

## First load

```
stream_prints  36,516     order_events  119,579
markets         1,236     book_snapshots    260
```

## What this enables

The analysis in [06-signal-architecture.md](06-signal-architecture.md) needs
inputs the node cannot provide after the fact:

- **Revision rate and magnitude** — only obtainable live, see above.
- **Publication lag** — measurable now, and it varies enormously by stream:
  CESR 0.2h, Argentina CPI 1.0h, UK CPI 1.9h, BMDI and Netflix 6.5h, US CPI and
  PCE 13.3h, Eggs 28.5h.
- **Book response to a print** — requires snapshots either side of the write.

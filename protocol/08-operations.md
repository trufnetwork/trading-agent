# Operational discipline for an agent running this stack

**Audience: an agent operating a local TN node, an indexer, and eventually real
money.** Every item here cost real time or produced a wrong answer during the
build. They are failure modes, not theory.

Run `scripts/status.sh` periodically. It checks all of this in one command:
node process, sync position, database size, market counts, indexer liveness,
tick staleness, ingest cursors, and any query running over two minutes.

---

## 0. Verify what a value MEANS before computing on it

**This is the rule that would have prevented most of the others.** The dominant
failure mode here is not bad retrieval. It is correct data interpreted wrongly,
computed on confidently, and written into an artifact before anyone checks.

Nine errors in one session, all the same shape. Every one produced a plausible
number and nothing raised an error:

| Assumed | Actually |
|---------|----------|
| schema `ds_main` | `main`. The `ds_` prefix is a changeset filter |
| `metadata(data_provider, stream_id)` | `metadata.stream_ref` -> `streams.id` |
| streams have names in metadata | no on-chain names exist at all |
| `collateral_change` is signed | it is a **magnitude**, direction is `is_negative` |
| volume is direct fills only | mint and burn are fills and count |
| trade count excludes mint/burn | same allowlist as volume, or it is inconsistent |
| "the protocol is a counterparty" | mint/burn carry **real wallet** counterparties |
| `first_seen` is safe to backfill | it means observation time, so backfill poisons it |
| 93% CPU was the chain | it was an abandoned query of mine |

### The rule

**Before computing on a column, establish its meaning from the thing that
defines it.** The DDL comment, the migration that writes it, or the spec. Never
from its name, and never from eyeballing its values.

Specifically, establish:

- **Signed or magnitude?** `collateral_change` is a magnitude with a separate
  direction flag. Filtering `> 0` summed spends and receipts together and
  doubled the figure.
- **Units.** Cents or base units, and which token. Volume in `eth_usdc` and
  `eth_truf` differ by 1e12 and must never be summed.
- **What rows exist.** Fee payouts appear as zero-share rows. Both sides of a
  fill are recorded. Grouping or summing naively double-counts or includes
  things that are not trades.
- **Does its meaning depend on when it was written?** If so it cannot be
  backfilled. `first_seen` is the example.

### Hex identifiers change form at every boundary

Same bytes, different required spelling, and each consumer rejects the others:

| Consumer | Wants |
|----------|-------|
| Account app, Connect Agent form | **`0x`-prefixed** |
| Trufscan URLs and display | `0x`-prefixed |
| Postgres `decode(x,'hex')` | **bare** |
| Go `hex.EncodeToString` | bare |

**Accept both on input, emit what the consumer expects.** Handing a user tool
output verbatim produced a form rejection that looked like their mistake and was
not. Anything a person will paste somewhere should be printed in that
destination's format, not the producer's.

### Corollaries

**A plausible number is not evidence of correct interpretation.** Every wrong
figure above looked reasonable. Several were reported confidently. The only
thing that caught them was someone asking where the number came from.

**When a definition is corrected, propagate it to every derived concept in the
same pass.** After adopting the corrected volume rule, trade count was still
computed on the old model minutes later, because the artifact in front of me was
updated and the model behind it was not.

**Report the meaning alongside the number.** State the window, the units, the
filter, and what the column means. It costs a line and it is what makes the
number checkable by someone who was not there.

**Prefer invariants to estimates.** "Roughly half the shares win" was right only
by luck. The pair invariant makes it exact: shares exist only in YES+NO pairs,
so winning shares equal pairs, always. An invariant you can re-verify with one
query will not drift the way a remembered assumption does.

---

## 1. Background jobs die silently

`nohup ./script.sh &` started **inside an agent tool call** does not reliably
survive the tool call's shell exiting. The indexer loop died during its first
sleep and went unnoticed for 14 minutes. Nothing errored. The log simply stopped.

```bash
# fragile
nohup ./scripts/index-tick.sh --loop > indexer.log 2>&1 &

# survives: own session, detached
setsid nohup ./scripts/index-tick.sh --loop >> indexer.log 2>&1 < /dev/null &
```

Better still, let the agent harness manage it, or install a systemd user unit or
cron entry for anything that must outlive a session.

**Detect it, do not trust it.** A long-running job is not running because you
started it. Check log mtime against wall clock:

```bash
AGE=$(( $(date +%s) - $(stat -c %Y indexer.log) ))
[ "$AGE" -gt 180 ] && echo STALE
```

## 2. Killing a client does not stop the query

The single most expensive mistake in this build. A `count(DISTINCT ...)` over
75M rows kept running on the **server** after the client was killed and after
the agent's task was stopped. It consumed the database for many minutes.

Worse, it corrupted a measurement: the node's Postgres read 93% CPU, which was
attributed to "keeping up with the chain" and used to justify a design decision.
The true baseline is **0.15-0.25% CPU**.

```sql
-- find it
SELECT pid, now()-query_start AS dur, left(query,60)
FROM pg_stat_activity
WHERE state='active' AND now()-query_start > interval '2 minutes';

-- stop it, then VERIFY
SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid = <pid>;
```

Beware self-matching: a query that searches `pg_stat_activity` for a string
contains that string, so it matches itself. Confirm with the CPU drop, not the
row count.

## 2b. Check whether a key is composite before joining on part of it

`main.streams` is keyed on `(data_provider, stream_id)` because two providers
can publish the same stream id. On mainnet **564 stream_ids are shared**.

Joining on `stream_id` alone silently reads another provider's data. Our scan
had this bug and was correct only by luck: no stream id used by a live market
currently collides. It would have started returning wrong answers the day one
did.

The tell is that it never errors. It returns a plausible number, which is the
failure mode rule 0 exists for.

**Check the primary key before joining on any part of it.**

```sql
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'main.streams'::regclass AND contype = 'p';
```

## 3. Scope every query to a stream

`main.primitive_events` holds 75M+ rows. Unbounded scans are pathological and
never necessary.

```sql
-- pathological: no index usable, whole table
SELECT count(DISTINCT (stream_ref, event_time)) FROM main.primitive_events;

-- representative: 17.9 ms, index-only, all cache hits
SELECT count(*), min(event_time), max(event_time)
FROM main.primitive_events WHERE stream_ref = 231559;
```

`pe_stream_created_idx` is `(stream_ref, created_at, event_time)`. Real questions
are about one stream, so they are nearly free. Scope to markets that are open
rather than every market ever.

## 4. Cursors must advance only on success

An ingest loop that updates its cursor unconditionally will, after one failed
copy, jump the cursor to the current height and then find nothing forever. It
reports success while capturing nothing, indefinitely.

Gate cursor advancement on the copy's exit status. Prefer counting rows actually
inserted over "rows above the old cursor", so the log reflects reality.

## 5. Containers do not share your localhost

`COPY ... FROM PROGRAM` executes **inside the database container**, whose
`127.0.0.1` is not the host. It cannot reach another container's published port.
Run both `psql` processes on the host and pipe them together.

## 6. Read the live schema, not the migrations

Migration 000 defines tables that migration 017 then normalized. Three wrong
assumptions came from reading the original migration:

| Assumed | Actual |
|---------|--------|
| schema `ds_main` | schema **`main`** (`ds_` is a changeset filter, not a name) |
| `metadata(data_provider, stream_id)` | `metadata.stream_ref` -> `streams.id` |
| streams carry names in metadata | **no on-chain names exist at all** |

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema='main' AND table_name='<t>' ORDER BY ordinal_position;
```

## 7. Measure before attributing

Two wrong claims, both from attributing an observation to the wrong cause:

- 93% CPU blamed on the chain. It was an abandoned query of mine.
- A 60-second sample at the start of block replay read 1.1 blocks/sec and was
  published as the rate. The full-run average was 1.98, nearly 2x higher. The
  instantaneous rate varies ~5x, so short samples are worthless.

Average over the longest window available. State the window alongside the
number.

## 8. Do not infer facts you can check

A UTC+10 offset was reported as "Australia" in a public GitHub issue. UTC+10
covers Australia, Guam, the Northern Mariana Islands, Papua New Guinea and parts
of Russia. A timezone is not a location.

Publishing an inference next to genuinely measured numbers invites a reader to
discount the measurements too.

## 9. Distinguish verified from assumed, in writing

Every document here marks claims as verified or not, and cites the migration or
source file that proves them. An agent replaying this protocol cannot tell a
measurement from a confident guess unless the document says which it is.

Mark design that has not been executed as **DESIGN, NOT EXECUTED**, and carry an
explicit VERIFY list.

## 10. Resource facts, so they are not re-guessed

| Resource | Reality |
|----------|---------|
| Disk | 328 GB free, node DB 22 GB, indexer 68 MB. Not a constraint. |
| Memory | 14 GB total, shared by two Postgres instances and kwild. The only real budget, and not currently binding. |
| Node Postgres at tip | 0.15-0.25% CPU, ~350 MB |
| Per-stream analytical query | ~18 ms, index-only scan |

Do not cite a non-constraint as a reason for a design decision.

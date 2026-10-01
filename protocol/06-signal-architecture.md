# Signal architecture — how these markets actually resolve

**Audience: an agent operating on TRUF.NETWORK prediction markets with a local
node.** This is the part you cannot recover by rerunning setup commands. Every
claim below is cited to the migration that proves it; verify rather than trust.

---

## 1. Price semantics

In `main.ob_positions` one column encodes side, and the sign carries it
(`030-order-book-schema.sql`, confirmed against `038-order-book-queries.sql`):

| `price` | Meaning |
|---------|---------|
| `= 0` | a **holding** — shares owned, not listed |
| `> 0` | a **sell** order at that price, in cents (1–99) |
| `< 0` | a **buy** order at `ABS(price)` cents |

```sql
best_bid = MAX(ABS(price)) WHERE price < 0
best_ask = MIN(price)      WHERE price > 0
spread   = best_ask - best_bid
```

`outcome` is boolean: TRUE = YES, FALSE = NO. YES + NO prices sum to 100c.

**Trap:** `MIN(price)` looks like the best bid and is not. Buys are negative, so
the numerically smallest is the *highest* bid. Use `MAX(ABS(price))`.

---

## 2. Terminology: MARKET vs ORDER BOOK

Get this right, it is the source of most confusion here.

| Term | Means |
|------|-------|
| **MARKET** | a **collection of order books**, typically 5, all settling at the **same exact time** on the same stream. Also called the **ladder**. Identified by `(stream_id, settle_time)`. This is what a person means by "a market", and what the UI shows as one question |
| **ORDER BOOK** | one `query_id`. One strike band. Has its own bids and asks |

A `query_id` is **an order book, not a market.** So the ~1,240 rows in
`ob_queries` are order books, and the number of actual markets is roughly a
fifth of that.

Reconstruct a market by grouping order books on `(stream_id, settle_time)`.
Never group by `::date`: a stream can run several markets in one day, and
merging them silently combines distinct ladders. `sdk-go`'s
`MarketData.Timestamp` confirms the key: *"Every bucket of one market shares
it."*

Reporting one order book in isolation is technically correct and practically
useless. It is a fragment of a market, and because one maker usually quotes the
whole ladder, five near-identical rows are one participant rather than five
opinions.

**Order books on a ladder are priced as one distribution.** Measured on CESR
2026-09-18, YES mids across the five books: `10 + 22 + 36 + 22 + 10 = 100`.
Symmetric and summing to exactly 100c, which is a probability distribution over
the strike bands, not five independent quotes.

---

## 3. How a market resolves — THE most important rule here

From `040-binary-attestation-actions.sql`:

```sql
WHERE pe.event_time  <= $timestamp
  AND pe.event_time  >= $timestamp - 86400      -- 1-day lookback window
  AND pe.created_at  <= $effective_frozen_at    -- frozen_at NULL -> latest
ORDER BY pe.event_time DESC, pe.created_at DESC
LIMIT 1
```

The settling value is **the most recent `event_time` at or before the market's
timestamp, within one day, taking its latest revision.**

Three consequences:

**(a) Revisions outrank prints.** `primitive_events` has PK
`(stream_ref, event_time, created_at)`, where `created_at` is a **block
height**. The same data point can be rewritten later. Because ordering is
`created_at DESC` within an `event_time`, a revision **replaces** the value that
settles the market. Anyone reading a "current value" API sees revisions late or
never.

**But do not expect to find revisions in node history.** `tn_digest` is ENABLED
on mainnet (`digest_config.enabled = true`, every 2h) and collapses each
stream-day into **OHLC** rows, keeping only the latest `created_at` and
preserving roughly 2 days of raw data.

### `created_at` is the LAST revision, not the first publication

This follows from the digest and it is easy to get wrong, so state it plainly.
`020-digest-actions.sql` keeps a small set of rows per stream-day and issues

```sql
DELETE FROM primitive_events WHERE EXISTS (SELECT 1 FROM events_to_delete d ...)
```

for every other `(stream_ref, event_time, created_at)`. So when a provider
re-posts a day it already published, the original row is **destroyed** and only
the newest survives.

**You therefore cannot date a print's first appearance from `created_at`, and
you cannot measure publication lag from it.** A provider that posted daily and
then re-posted three weeks in one transaction leaves exactly the same footprint
as one that only ever posted in a single batch.

Observed 2026-09-20 on `st908370bca6840a648f48e7346f7c61`. All 18 September
prints carried one `created_at`, from a single `insertRecords` transaction on
19 September, which reads as a monthly backfill. Markets settling on 17 and 18
September had already resolved against fresh September values, so the data was
demonstrably on chain days before the transaction that now appears to have
created it.

### Use attestations to date what existed

Attestations are immutable and capture `result_canonical` at attestation time,
so a settled market is a tamper-proof record of what the chain held at its
`settle_time`. Decode the winning band and compare it against the candidate
values.

```sql
SELECT q.id, q.settle_time, q.winning_outcome, encode(q.query_components,'hex')
FROM main.ob_queries q WHERE q.settled AND <stream predicate>
ORDER BY q.settle_time DESC;
```

If the winning band contains a value that `created_at` says did not yet exist,
`created_at` is wrong and the digest has rewritten it. That check cost nothing
and overturned a confident conclusion built on three other lines of evidence.

### What an attestation proves, and what it does not

An attestation proves **a value existed at a `settle_time`**. It does not prove
which transaction wrote that value, or which block carried it.

The full archival chain is attestation, then the transaction that wrote the
attested print, then the block containing that transaction. Only the first link
lives in consensus state.

| Link | On a snapshot-synced node |
|------|---------------------------|
| attestation and `result_canonical` | **present**, it is state |
| `transaction_events` row, tx to height | **present**, it is state |
| the transaction payload, which print it wrote | **absent**, it is block body |
| the block itself, below the snapshot height | **never received** |

The `primitive_events` row that carried the original `tx_id` is exactly what the
digest deleted, so even the pointer back to the writing transaction is gone.

Measured on this deployment: 22 GB of consensus state against a 106 MB
blockstore holding the 81,595 blocks replayed since the snapshot at height
2,543,774. Nothing below that height was ever received.

`052-transaction-events-retention.sql` also trims `method_id = 2`
(`insertRecords`) from the ledger, and says so plainly: the transaction "remains
permanently resolvable off-chain via the Trufscan chain indexer". The low-volume
classes, including `requestAttestation` and `createMarket`, are left untouched.

**So a value is verifiable to a point in time from any synced node, but the
provenance of the write is not.** That needs an archival node carrying full
replayable history, a full block sync from genesis, or an off-chain chain
indexer. State it that way rather than calling an attestation tamper-proof
evidence of publication.

That still leaves a usable historical signal, because OHLC is four slots: **a
day whose value changed intraday must leave 2 or more rows.** Measured
2026-09-18 over 180 days and the 11 streams backing open markets:

```
1,974 stream-days  ->  exactly ONE day kept more than one row
                       avg 1.00 rows/day for 10 of 11 streams
```

So these streams historically **never revise a day's value after the fact**,
a prior around 0.05%. Treat "the current value is final" as the base case and
size positions accordingly, rather than pricing in phantom revision risk.

What history cannot show is repeated *identical* prints, since OHLC collapses
those to one row. A revision that does not change the value cannot change an
outcome, so the measurable part is the part that matters. Exact revision timing
and magnitude, and print counts within a day, require live capture. See
[07-indexer.md](07-indexer.md).

**(b) A print is not necessarily THE print.** A print is terminal for a market
only if all hold:

- its `event_time <= T`, and
- no later `event_time` still `<= T` arrives before settlement (`event_time`
  sorts first), and
- no revision of it arrives before settlement

If a stream prints daily and T is three days out, **the print that settles the
market has not happened yet.** Trading an early print as final is being wrong
early. This is the single easiest way to lose money here while feeling informed.

**(c) There is a hard one-day lookback.** If nothing printed in
`[T-86400, T]`, resolution falls through to the composed-stream `get_record`
path — different semantics. A stream going quiet near its timestamp is its own
tradeable event.

### What to compute per stream

The question is never "did it print" but **P(the currently-implied outcome
survives to settlement)**. Fit from local history:

| Input | From | Available historically? |
|-------|------|-------------------------|
| cadence | inter-arrival of `event_time` | **yes** |
| publication lag | block time of `created_at` minus `event_time` | **NO, see below** |
| intraday value change | >1 row surviving digest for a day | **yes, as a bound** |
| exact revision timing/size | multiple `created_at` per `event_time` | **no, digest erases it** |
| print count per day | identical prints collapse to one row | **no** |
| time remaining | T and `settle_time` vs now | yes |

Measured on the 11 live-market streams, 2026-09-18:

| Stream | Cadence | Publication lag |
|--------|---------|-----------------|
| CESR | daily, 20:00 UTC | **0.2h** |
| Argentina CPI | daily | 1.0h |
| UK CPI | daily | 1.9h |
| BMDI, Netflix | daily | 6.5h |
| US CPI, PCE | daily | **13.3h** |
| Eggs | daily | **28.5h** |
| BLS CPI, PCE Inflation | monthly | n/a |

Nine streams print daily with min gap = max gap = 24.0h, which is clockwork.
**Publication lag is what sets the real edge window**, not the settle time. A
market settling 16:00 UTC resolves on the 00:00 print, but only if that print
has been *written* by then. At 13.3h lag that window is under three hours. At
28.5h the print can miss settlement entirely.

The node exposes no height-to-time map, so publication lag has to be
approximated from the nearest `ob_order_events.block_timestamp` until the
indexer records it directly.

---

## 3b. The pair invariant, and how to read collateral

Shares only come into existence by **minting a YES+NO pair for $1.00**. So for
every market:

```
YES shares outstanding == NO shares outstanding        (verified: 130/130 markets)
pairs = shares_outstanding / 2 = dollars of collateral locked
```

Exactly one side of each pair wins, so **winning shares = pairs**, exactly. No
estimate is needed to size a settlement fee:

```
fee      = pairs x $1.00 x 2%
LP share = fee x 75%          (12.5% data provider, 12.5% validators)
```

### Reading `main.ob_net_impacts`

Durable (395k rows, no trim), and it answers PnL and per-market volume. Column
semantics matter:

| Column | Meaning |
|--------|---------|
| `shares_change` | **signed**: + acquired, − disposed |
| `collateral_change` | **magnitude only**, always positive |
| `is_negative` | TRUE = collateral spent, FALSE = received/refunded |
| `timestamp` | unix seconds, so any time window works |
| `query_id` | **one bucket**, not the user-facing question |

**Trap:** filtering `collateral_change > 0` sums spends *and* receipts together,
roughly doubling the figure. Use `is_negative` for direction.

**Trap:** fee payouts are recorded as zero-share rows (406 of 1,012 on one
market). Filter `shares_change <> 0` for trade activity.

**Trap:** `query_id` is a bucket. Aggregate by `(stream_id, settle_time)` for the
question, or understate it by about 5x.

### Streams are keyed by (data_provider, stream_id)

**Never resolve a stream by `stream_id` alone.** The key is composite by design,
because two providers can publish the same stream id, and on mainnet **564
stream_ids are currently shared across providers**.

A single-column join does not error. It returns another provider's data, as a
plausible number. Both halves are in `query_components`:

```
data_provider : ABI word 0, address in the low 20 bytes -> hex chars 25..64
stream_id     : ABI word 1, ASCII NUL-padded            -> hex chars 65..128
```

**Also: `main.streams` has no index on `stream_id`.** Every text lookup is a
parallel seq scan over ~260k rows, about 21 ms. Resolve the composite to
`streams.id` **once**, then join on the integer. Doing it per market makes a
scan O(markets x streams).

Both fixes are the same change. Together they took the market scan from
**2.6 s to 0.285 s** across 167 live markets, and the gain grows with market
count.

### Volume: the settled definition (trufnetwork/indexer#102)

Volume is **filled orders, counted once per trade, in CENTS of that market's own
collateral token**. Never sum across bridges: one `eth_usdc` base unit and one
`eth_truf` base unit differ by 1e12 and nothing here reconciles them.

```sql
SUM(CASE
  WHEN event_type IN ('mint_fill','burn_fill') AND outcome IS TRUE
    THEN 100 * amount          -- a pair locks/unlocks exactly $1
  WHEN event_type = 'direct_buy_fill'
    THEN price * amount        -- direct_sell_fill is the SAME trade
  ELSE 0 END)::numeric(78,0)
```

**Mint and burn ARE volume.** This is not an accounting convenience. Mint and
burn are the **arbitrage boundaries that hold YES + NO at 100**: if the combined
bid exceeds 100 you sell both sides rather than burn, and if the combined ask is
below 100 you buy both rather than mint. Choosing to burn is therefore a real
market decision — that the book's combined bid is worse than par — expressed
against the protocol rather than against another wallet. It is price discovery,
and real collateral moves on it.

**`split_placed` is NOT volume.** It locks collateral and mints a pair with no
counterparty and no price view. It moves open interest, not volume.

**`direct_sell_fill` is NOT volume** but its participant IS a trader. Both sides
of a match are traders; only the buy row is counted, or you double it.

| Event | Volume? | Trader? |
|-------|---------|---------|
| `direct_buy_fill` | `price * amount` | yes |
| `direct_sell_fill` | no, same trade | **yes** |
| `mint_fill`, `burn_fill` | `100 * amount`, YES row only | yes |
| `split_placed` | no, it is a deposit | no |
| `*_placed`, `cancelled`, `bid_changed`, `ask_changed`, `settled` | no | no |

Use an **allowlist**, never `ELSE price`. A denylist admits every future node
event type silently. The eleven pinned types live in the indexer's
`types.PMFillEventTypes()`.

### One allowlist drives EVERY derived metric

**A fill has a counterparty. Nothing else does.** Mechanically checkable, not a
judgement call. Verified across 119k rows:

```
direct_buy_fill  9,140/9,140 have counterparty_id   split_placed  0/9,634
direct_sell_fill 9,140/9,140                        cancelled     0
burn_fill        9,022/9,022                        *_placed      0
mint_fill          750/750                          bid_changed   0
```

`mint_fill` and `burn_fill` are **two-party matches**, not protocol operations.
Both sides agreed complementary prices, and the match settles by creating or
destroying a pair rather than transferring existing shares. The protocol is the
mechanism, not the counterparty.

`split_placed` is unilateral: collateral in, pair out, no counterparty and no
agreed price. It moves open interest, never volume.

If an event is a fill, then all of the following follow together:

| Derived metric | Rule |
|----------------|------|
| volume | counted at its collateral value |
| fill count | counted as an event |
| unique traders | its participant is a trader |

**Never let one of these use a narrower notion of "real trading" than the
others.** This was gotten wrong here: after adopting the corrected volume rule,
"trade count" was still being computed on the old wallet-to-wallet-only notion
minutes later, because the artifact was updated and the underlying model was
not. When a definition changes, propagate it to every derived concept in the
same pass.

**De-duplicate identically too.** Both patterns write **two rows per economic
event**: `direct_buy_fill` alongside `direct_sell_fill` for a match, and a YES
row alongside a NO row for a mint or burn. One row per event, for sums and
counts alike.

**Unique traders** = distinct wallet over the four fill types. Comparable across
bridges, unlike volume, so it is reported per bridge *and* as a single figure.
The top-level count is not the sum of the per-bridge counts: a wallet trading on
two bridges is one trader in two buckets.

### Measured, live markets, 2026-09-18

```
all 167 live markets      $66,719.15 eth_usdc,  8 unique traders
  from complete history   $29,290.49
```

A **floor**, not a total: `trim_order_events()` retains roughly 21 days (310 of
1,236 markets), so any market created before `min(block_height)` in
`ob_order_events` is truncated. Flag it rather than presenting it as lifetime.

Group by **exact `settle_time`**, never `::date`. A stream can run several
ladders in one day, and grouping by date silently merges distinct questions.

Composition is worth watching separately even though both count. On one CESR
bucket over 24h: $343.00 `burn_fill` against $16.92 `direct_buy_fill`. Both are
volume, but the split tells you whether activity is counterparty trading or
boundary arbitrage, and those respond to different things.

### Why spent and received differ on a live market

They differ by exactly the collateral still locked inside it:

```
spent − received = open buy collateral + (pairs x $1.00)
   $401.71       =      $118.71        +     $283.00      (market 770)
```

Nothing is missing. Resting buy orders return on fill or cancel, and pair
backing is released at settlement.

---

## 3c. Finding an edge: the standard method

`scripts/edge.py <order_book_id>` runs all of this. The reasoning, so it can be
checked rather than trusted:

1. **Resolve the market**, the ladder of order books sharing
   `(stream_id, settle_time)`.
2. **Decode each band** from `query_components`. Thresholds live in the ABI
   `args` blob, which only `contractsapi.DecodeMarketData` reads.
3. **Model the next print** from the stream's daily-move distribution, anchored
   on the latest value.
4. **P(band) vs the ASK.** You buy at the ask, so comparing a probability to the
   mid overstates edge by half the spread on every line. This was gotten wrong
   first time.
5. **Size against both the book and the wallet**, whichever binds.

### Buying beats split-and-sell for a directional view

To go long YES you can buy at the ask, or `place_split_limit_order` to mint a
pair for $1 and sell the NO leg. Measured on CESR book 1176:

```
buy YES at ask                     38c/share, locks 38c
split, sell NO into its 61c bid    39c/share, locks $1.00 up front
```

A cent worse on price, and **2.6x worse on capital**, because minting locks the
full dollar while buying locks only the ask. Splitting is the LP play, where you
want the NO leg resting as a limit order, not the directional one.

**Compare against the NO bid, not the YES bid.** Net split cost is
`100 - NO_bid`.

### How settlement ACTUALLY fires (corrected twice, verified in code)

`settle_market` does **not** recompute the query. It reads a signed attestation:

```sql
-- 032-order-book-actions.sql, settle_market SECTION 2
SELECT result_canonical, signature FROM attestations
WHERE attestation_hash = $market_hash
ORDER BY signed_height DESC NULLS LAST LIMIT 1
-- no attestation      -> ERROR
-- signature IS NULL   -> ERROR
```

**The outcome is fixed at ATTESTATION time, not settlement time.** That is the
moment that matters, and it is the thing to reason about.

Attestation cannot happen early. `validate_not_before_timestamp` errors when
`@block_timestamp < $timestamp`, so nobody can attest before `settle_time`.

Settlement is then a **cron, not a scheduled time**. `tn_settlement` runs
`*/5 * * * *` (leader-only, `settlement_config`), sweeping for markets that are
past `settle_time` **and** have a signed attestation. It lands on whichever
5-minute boundary follows the attestation.

```
20:00   print event_time
20:15   settle_time. Attestation now PERMITTED, not triggered
~20:18  print written on chain
~20:18  attestation requested, computed, signed
20:20   cron sweep settles, reading result_canonical
```

**The requester is the node itself, and it does NOT wait for the print.**
`tn_settlement`'s scheduler (leader-only, gocron `*/5 * * * *`) runs
`FindUnsettledMarkets` on `settled = false AND settle_time <= now()`. The
comparison is inclusive and settle times sit on 5-minute boundaries, so a ladder
is picked up by the tick AT `settle_time`.

It then broadcasts one `request_attestation` per ORDER BOOK with
`broadcaster(ctx, tx, 1)`, which is WaitCommit. The loop blocks until each
commits, so **at most one book is attested per block, and that queue is GLOBAL
across every market due**, not per ladder. Measured: 15 books from 3 different
ladders took 15 consecutive blocks, 2607089 to 2607103.

A 5-book ladder therefore spans at least 4 blocks. Median 4, p90 42, max 207,
over 110 ladders. At 13.5s average block time that is ~54s typically.

**Three outcomes, ONE of which is a bug:**

| print relative to window | result |
|---|---|
| on chain before | resolves on the new print |
| lands inside | ladder SPLITS: 2 or 0 winners. **BUG** |
| arrives after | resolves on the PRIOR print. **BY DESIGN** |

**Print arrival is never a trigger.** Attestation captures whatever state exists
at `settle_time`. Whether the provider has published is outside the protocol, and
making settlement wait on it would hand a third party control over when markets
resolve. A stream that publishes late resolves on the previous value,
predictably, and traders price that.

So the third row is NOT a defect. Measured: one stream resolved on the prior
value 3 of 3 times, which is just its publication lag. On CESR, 2 of 11 ladders
settled with a winner count other than 1, and those are the real bug.

The protocol's job is to attest **atomically and as close to `settle_time` as
possible**. Today it is neither, because the scheduler waits for commit between
books.

Filed as trufnetwork/node#1430. Minimum fix is same-block attestation per
ladder. Settle time is chosen per market and 00:00 UTC already dominates
(440 books, 112 instants), so the global queue concentrates there.

**Trading consequence.** Publication lag is a property of the stream, not a bug.
Where a stream reliably publishes after `settle_time`, the resolving value is
ALREADY ON CHAIN and the outcome is knowable in advance. That is edge, and it
survives the fix.

### A publisher can change its broadcast schedule without telling anyone

This is a permissionless network. A data publisher can change when it broadcasts,
how often, or how it stamps a value, at any time, with no announcement and
nothing to version-check. Expect it periodically and detect it from the prints.

Two kinds of change, and they do not matter equally.

**Cadence is what matters.** If prints start arriving at a different frequency,
the stream behaves differently for every market from that point on, so any
timing base rate measured before it is describing a schedule that no longer
runs. Cut the history at the changepoint.

**A change of broadcast time is arbitrary.** Which hour of the day a publisher
broadcasts in, including a move between observation-dated and publish-time
stamps, carries no information for a market opened after the change, provided
the new time is consistent.

**The exception is a market that was already open when the time moved.** That
book was priced under the old schedule and the publisher shifted it underneath,
so its assumptions about the resolving value may no longer hold. That is the one
case where a time change is worth acting on.

`scripts/edge.py` reports both, and compares the changepoint against when the
market being analysed was opened so it can tell you which case you are in. Only
a cadence change resets the timing history.

Alignment is checked separately from cadence because it is binary, so one print
after a flip is enough to see it. A cadence shift needs history on both sides
before it can be called.

**Worked example.** Truflation streams changed on 2026-09-30, moving from
observation-dated prints, stamped 00:00 and published about 26 hours late, to
publish-time prints landing within seconds. The gasoline index went from 26
hours of lag to 3 seconds.

The cadence did not change, so markets opened after that date are unaffected.
Books already open had their schedule moved underneath them. There was no
announcement.

**This costs you nothing analytically.** Only the broadcast window changed. The
value series is continuous across the switch, so volatility, drift and every
price model built on it use the full history untouched.

What resets is the settlement-timing base rate, because it describes a schedule
that no longer runs. `scripts/edge.py` keeps the full history for the move model
and counts only post-switch settlements for timing.

**Measure that lag from settled markets, never from `created_at`.** The digest
rewrites `created_at` on any revised day, so a stream that posts daily and later
re-posts looks identical to one that only ever posted in a batch. Settled
ladders carry an immutable attestation of what existed at each `settle_time`,
which is the only honest record. `scripts/edge.py` reports this per stream under
SETTLEMENT MECHANICS.

**Do not reason about "will settlement run before the print".** Settlement cannot
run without an attestation. Reason about what data existed when the attestation
was computed.

### Settlement-timing checks that can invalidate the whole analysis

**Is a print already in `[T-86400, T]`?** If yes the outcome is knowable and
resting orders are exposed. Do not be an LP there.

**Can the settling print arrive in time?** The window excludes the previous
day's print, so exactly one print can settle the market. Measured on CESR,
whose prints are due 15 minutes before `settle_time`:

```
6 of 11 prints were written AFTER settle_time, by up to 3.3 min
worst observed lag 18.3 min vs a 15 min nominal deadline
```

They still settled correctly, because `settle_market` runs about 5 minutes
after `settle_time` and `created_at` is unconstrained when `frozen_at` is NULL.
The print only has to exist when settlement executes. **The true margin was
1.7 minutes**, not the 3 minutes a naive reading of the schedule suggests.

Check `settled_at - settle_time` on recent markets for the real deadline, and
compare it to the stream's worst publication lag.

---

## 4. Fees — know exactly which ones exist

Verified against `032-order-book-actions.sql` and
`033-order-book-settlement.sql`:

- **Placing / cancelling orders: free.** No per-trade protocol fee. Cancelled
  and unfilled orders refund in full.
- **Settlement: 2% on winning shares only.** A winning share pays **$0.98**, not
  $1.00. Losing shares cost nothing beyond their purchase price.
- **Market creation: 2 TRUF**, paid in TRUF via a transfer to the block leader —
  charged by `create_market` only.

Consequence for an MAA agent: the trading allow-list (`place_buy_order`,
`place_sell_order`, `place_split_limit_order`, `cancel_order`) contains **no fee
logic whatsoever**, so the MAA token boundary's leader-transfer carve-out is
unreachable from it. A trading agent cannot drain a wallet through fees. The
residual risk is bad trading, not fee leakage.

Part of that 2% funds LP rewards, so a liquidity-providing agent earns from the
pool it pays into when it wins.

---

## 5. LP reward eligibility

- Orders must be **paired**: buy one outcome + sell the other, at prices summing
  to **100c**, same size.
- Scored by **spread tightness** (tiers), **liquidity-hours** (duration on the
  book), and **size** above the minimum.
- Sampled **per block** while the market is live; paid atomically at settlement.

---

## 6. Agent architecture: fast loop / slow loop

**An LLM must not be in the hot path.** Encode the reflex; supervise the rules.

```
FAST LOOP  — compiled daemon, sub-second, no LLM
  watch primitive_events WHERE created_at > last_seen_height
  -> join to active markets on that stream
  -> recompute fair value; cancel/replace orders

SLOW LOOP  — the agent, minutes to hours
  fit cadence / revision models per stream
  set the parameters the daemon acts on
  review what it did; handle novel cases
```

The agent's edge is reading comprehension, which belongs in *authoring* the
rules. Reaction speed belongs in compiled code.

### NEVER put triggers on `main` tables

Tempting: a trigger calling `pg_notify` for push instead of poll. **Do not.**
Those tables are written by kwild inside consensus transactions. If the trigger
errors, it aborts kwild's transaction, and a node that cannot commit a block
halts or forks. That converts a latency optimisation into a consensus failure.

### Poll instead — you are already at the latency floor

The detection query is indexed (`pe_prov_stream_created_idx` on
`(data_provider, stream_id, created_at)`) and returns almost nothing. The real
floor is **block time**: data appears when a block commits, not continuously.
Polling faster than blocks arrive buys nothing.

If true push is ever needed, use a **read-only logical replication slot**, which
never touches kwild's write path. Caveat: a stalled slot retains WAL and can
fill the disk.

### Why a local node is structurally fast enough

You see a write **when the block commits** — the same instant as any other node
operator. Everyone on a public RPC or the indexer sees it strictly later. The
remaining contest is against other node operators running their own daemons,
which is a far smaller field than "the market".

---

## 7. Risk rules

**Event-driven, not clock-driven.**

| | Naive rule | Real rule |
|---|---|---|
| Trigger | 15 min before `settle_time` | any write to the market's stream |
| Basis | a clock | `created_at > last_seen_height` |
| Misses | early prints, revisions | - |

Sharpened by the cadence and lag measurements above. For a daily stream the
settling print lands at a **predictable** moment: `event_time` 00:00 plus that
stream's publication lag. The dangerous window is not the last 15 minutes, it is
the interval between that write and settlement, which runs from under 3 hours
(US CPI) to negative (Eggs, where the print can arrive after settlement).

**Verified case.** Eggs markets settling 06:00 UTC had **zero prints inside the
resolution window** `[T-86400, T]`, because the 28.5h publication lag pushes the
00:00 print past the settlement. They still settled, via the composed-stream
`get_record` fallback in 3(c). Most participants would assume the primitive
print decided it.

Keep the 15-minute pre-settlement pull as a **backstop** — it covers settlement
arriving with no fresh print at all. The reference bots
(`truflation/market-maker-bot`, `truflation/liquidity-provider-bot`) both use
the clock rule alone; treat that as a floor, not a ceiling.

---

## 8. Read/write asymmetry — never violate this

- **Reads: plain SQL.** Arbitrary shapes, no rate limits, no SDK.
- **Writes: SDK only.** That database *is* consensus state. A direct INSERT
  forks your node's state hash and drops it out of consensus. Every write is a
  signed transaction.

---

## Naming streams

Markets carry no readable metadata on chain. Identity is in
`ob_queries.query_components`, ABI-encoded
`(address data_provider, bytes32 stream_id, string action_id, bytes args)`. The
`bytes32 stream_id` is **plain ASCII** of the `st...` string, right-padded with
NULs (verified against live data 2026-09-17). Decode the outer tuple by hand
(fixed 4-word head) or with `contractsapi.DecodeMarketData`, a **pure function**
needing no client.

**Streams have no on-chain name either.** VERIFIED NEGATIVE: `main.metadata`
holds only operational keys (`readonly_key`, `read_visibility`, `type`,
`stream_owner`) across all 259,575 streams. There is nothing to join to.

Names come from **trufscan**, which has no documented API but whose frontend
calls an internal batch endpoint:

```
POST https://trufscan.io/api/streamlist
{"streamIds": ["st...", ...], "isV2": false}
```

It returns `display_name`, `ticker`, `description`, `unit`, `tick_rate`,
`categories` and more. `scripts/refresh-streams.py` reads the stream ids that
actually appear in local `ob_queries`, asks for those, and writes
`streams.json`. Per-stream pages at `https://trufscan.io/<data_provider>/<stream_id>`
carry the same data in a standard layout if the endpoint ever changes.

**Do not seed names from `market-maker-bot/config.example.yaml`.** That table is
partly wrong. It labels `ste03c2844...` "EU Inflation YoY" when trufscan calls
it *Truflation PCE Index*, and `st1d6d4142...` "US CPI Index Alt" when it is
*PCE Inflation Index*. Treat trufscan as authoritative.

**`tick_rate` is unreliable.** Observed values across 22 streams: `unknown` x11,
`daily` x7, `Daily` x2, `hourly` x1, `$` x1. It is free text, inconsistently
filled. Use it as a hint and **measure real cadence from
`main.primitive_events`** instead.

# Field manual

[RUNBOOK.md](RUNBOOK.md) assumes things work. This is for when they do not.

Find your symptom, not your theory. Each entry says what you are seeing, what it
usually means, how to confirm it, and what to do. Every one of these was hit on a
real run.

| What you see | Go to |
|--------------|-------|
| The person says they see no progress | [The person sees nothing](#the-person-sees-nothing) |
| kwild fails to bind its admin socket | [The socket path is too long](#the-socket-path-is-too-long) |
| Node exits with `snapshot file not provided` | [Sync never starts](#sync-never-starts) |
| Status reports a phase you already finished | [Status disagrees with reality](#status-disagrees-with-reality) |
| The RPC stops answering mid-sync | [The RPC goes quiet](#the-rpc-goes-quiet) |
| Progress goes backwards, or a finished stage reappears | [Progress regressed](#progress-regressed) |
| The progress feed stops for 30 minutes | [The feed went quiet](#the-feed-went-quiet) |
| A background job vanished | [Background jobs die with the call](#background-jobs-die-with-the-call) |
| Sync is far slower than estimated | [Sync speed swings wildly](#sync-speed-swings-wildly) |
| A query errors on a column that used to exist | [The schema moved](#the-schema-moved) |
| A number looks right but the conclusion is wrong | [Right data, wrong meaning](#right-data-wrong-meaning) |
| You connected to Postgres and the data looks odd | [You are reading the wrong node](#you-are-reading-the-wrong-node) |
| A market settled with two winners or none | [A ladder settled wrong](#a-ladder-settled-wrong) |
| A market settled with no recent data | [Settlement with nothing in the window](#settlement-with-nothing-in-the-window) |
| A stream's prints changed shape | [A publisher changed its schedule](#a-publisher-changed-its-schedule) |

---

## The person sees nothing

**What you see.** You are making progress, and the person asks what is
happening, or stops the run.

**What it means.** They cannot see your tool calls. Running the display command
shows the block to you. It reaches them only when you write it as text in your
message.

**What to do.** Run `scripts/onboard.sh --md` and write its whole output into
your message now, before any other tool call. Then carry on. Do this at the
start of every phase, not at the end of the turn.

This happened on three outside tests of this runbook. Each agent ran the display
command at every phase and wrote nothing into the chat. `status.sh --shown` now
checks the Claude Code transcript and refuses until the block is really there.

## The socket path is too long

**What you see.** kwild fails at startup binding its admin socket, or the
socket file never appears.

**What it means.** A Unix socket path is limited to about 107 characters. A
socket inside the node root exceeds that when the checkout itself is deep.

**Confirm it.**

```bash
grep -A4 '^\[admin\]' tn-node/config.toml | grep listen | awk -F"'" '{print length($2)}'
```

**What to do.** Use the `TN_ADMIN_SOCKET` value from `.tn-env`. `scripts/ports.sh`
already falls back to a short `/tmp` path when the in-root one would not fit.

## Sync never starts

**What you see.** `snapshots_discovered=0`, then `Statesync exhausted its
retries`, then the node exits with `snapshot file not provided`.

**What it usually means.** Not a snapshot problem. **No peer ever connected.**
The errors name the stage that failed, not the cause.

**Confirm it.** `scripts/status.sh` reports `SYNC_PEERS_OK`. Zero peers makes
every downstream number meaningless, and tuning `discovery_time` is wasted
effort.

```bash
grep -c 'Connected to peer' kwild-run.log       # successes
grep -c 'failed to connect to' kwild-run.log    # failures
```

**Testing the port proves nothing.** A raw TCP connection to a bootnode succeeds
while every dial fails, because the remote accepts the socket and never
completes the libp2p handshake. Each dial then burns a full 15 second timeout.

**kwild will not tell you why.** It keeps the addresses and discards the
per-address causes, at every log level. See trufnetwork/kwil-db#1738. The only
way through is libp2p's own logger.

```bash
GOLOG_LOG_LEVEL="swarm2=debug,tcp-tpt=debug" kwild start --root ./tn-node
```

**What to do.** Add another bootnode you trust, to both `bootnodes` and
`trusted_providers`. Then wait rather than restarting in a loop, because each
retry costs a minute of dial timeouts and fixes nothing when the remote is the
problem.

Observed: five consecutive attempts failed with zero peers, then the same
configuration connected and pulled all three snapshots. Nothing local changed.

## Status disagrees with reality

**What you see.** The node is running and synced, but status reports an early
phase and tells you to start it.

**What it usually means.** The process check stopped matching. A release can
install under a versioned name, so a 2.6.0 node appears as `kwild-2.6.0` and a
pattern expecting `kwild` finds nothing.

**Confirm it.** Compare what is listening against what the check looks for.

```bash
ss -tlnp | grep ':8484'        # names the actual binary
```

**What to do.** Match on the subcommand rather than an exact binary name. If the
schema also moved, see [The schema moved](#the-schema-moved).

**A node upgrade is not itself a hazard.** Going from 2.5.8 to 2.6.0 changed
nothing this repo reads. What broke was the tooling around it.

## The RPC goes quiet

**What you see.** The local RPC stops answering for long stretches during
catch-up. Height readings disappear.

**What it usually means.** Nothing is wrong. The RPC goes unresponsive while the
node replays hard, which is exactly when you want to watch it.

**Confirm it.** The log still records every commit.

```bash
grep -c 'Committed Block' kwild-run.log     # climbing means it is working
```

**What to do.** Nothing. `scripts/status.sh` already falls back to counting
commits in the log. Do not restart the node on this symptom.

## Progress regressed

**What you see.** A stage you already finished reappears, for example a database
load showing 99% with an elapsed time longer than its own estimate.

**What it usually means.** A momentary failure to read the RPC fell through to an
earlier branch of the stage detector.

**Confirm it.** An elapsed time larger than the estimate it is measured against
is impossible for a stage that really finished.

**What to do.** Progress should only move forward. Report a stage as busy rather
than regressing it. Already fixed in `status.sh`, but worth recognising if you
write your own view.

## The feed went quiet

**What you see.** Progress updates stop arriving, with no error.

**What it usually means.** The watcher expired, not the node. Claude Code's
monitoring tool caps at 30 minutes, so a multi-hour catch-up needs re-arming
roughly twenty times.

**Confirm it.** Run `scripts/status.sh` directly. If it reports progress, the
node is fine.

**What to do.** Re-arm the watcher. Check status before concluding anything about
the node.

## Background jobs die with the call

**What you see.** A long-running process started in a tool call is gone later,
with no log and no exit status.

**What it usually means.** A plain `nohup ... &` inside an agent tool call does
not reliably outlive the call.

**What to do.** Use `setsid`, and log unfiltered to a file. Verified: a node
started this way kept replaying through a dropped session and reached the chain
tip on its own.

```bash
setsid nohup kwild start --root "$TN_HOME/tn-node" > "$TN_HOME/kwild-run.log" 2>&1 < /dev/null &
```

Never pipe a long job through a buffering filter. `cmd | tail` writes nothing
until exit, hides progress, and masks the exit code.

## Sync speed swings wildly

**What you see.** An estimate that moves between a few hours and several days.

**What it usually means.** Replay throughput varies by more than twenty times
with block content. Ordinary blocks replay at about 2.6 per second. Blocks
carrying digest work drop to 0.1 while Postgres goes I/O bound.

**What to do.** Average over the whole catch-up rather than sampling twice. A
two-sample rate on this workload predicts anything. Measured end to end on a
cleared machine: about 5 hours, being 18 minutes download, 39 minutes load, and
3.5 hours catch-up.

## The schema moved

**What you see.** A query errors on a column, or a join returns far fewer rows
than it should.

**What it usually means.** A migration changed what you read. This happens
without any binary change, so an upgrade is the wrong thing to watch for.

**Confirm it.**

```bash
scripts/check-schema.sh     # one query, names anything missing
```

**What to do.** Fix the affected queries in `sql/` and `scripts/`, then re-run
the check. Precedent: a migration normalised `metadata(data_provider, stream_id)`
into `metadata.stream_ref` and silently broke a working query.

## Right data, wrong meaning

**What you see.** A query that runs fast, returns a plausible number, and
supports a confident conclusion that turns out to be wrong.

**This is the dominant failure in this domain.** It outranks wrong joins and slow
queries combined. The column names are honest but incomplete.

| Looks like | Actually is |
|------------|-------------|
| `query_id` is a market | one **order book**, one strike band |
| `price` is a price | price **and side** |
| `collateral_change > 0` filters inflows | a **magnitude**, direction is in `is_negative` |
| `stream_id` identifies a stream | only with `data_provider`, the key is **composite** |
| any order event is a fill | only events with a **counterparty** |
| `created_at` dates a print | the **latest revision**, the digest deletes earlier rows |

**What to do.** Check the defining migration before aggregating anything new.
When a conclusion rests on a timestamp, ask what rewrites it.

**Corroboration is not confirmation.** Three independent measurements once agreed
on a wrong conclusion because all three depended on the same misread field. The
check that overturned it used a different mechanism entirely.

## You are reading the wrong node

**What you see.** Postgres answers, the data is plausible, and the conclusions
are strange.

**What it usually means.** A port collision. Kwil-family nodes all default to the
same ports, and a second Postgres container starts happily without publishing its
port, so a connection silently lands on another node's database.

**Confirm it.**

```bash
docker port <container>      # empty output means the port is NOT published
```

**What to do.** Run `scripts/ports.sh`, which uses defaults when free and steps
to the next free port when not. Always confirm which instance answered before
trusting a number.

## A ladder settled wrong

**What you see.** A market whose bands partition the number line settles with two
winning bands, or none.

**What it means.** The settlement scheduler attests one order book per block, so
a ladder is captured across several blocks. If a print lands inside that window,
books on either side resolve against different values. Tracked as
trufnetwork/node#1430.

**What to do.** Check the whole ladder, not just your own book. Exactly one book
should show `winning_outcome = true`. `scripts/edge.py` reports a stream's
historical exposure and its realised harm separately, because they are different
numbers.

## Settlement with nothing in the window

**What you see.** A market settled although the stream had no value inside the
24 hour resolution window.

**What it means.** Resolution fell through to the `get_record` fallback, which
returns the last known value regardless of the window. The market still settles.

**What to do.** Treat it as a data gap rather than a settlement bug. `edge.py`
reports how many recent settlements had no print in window.

## A publisher changed its schedule

**What you see.** A stream's prints change shape, with no announcement.

**What it means.** This is a permissionless network. A publisher can change when
it broadcasts, how often, or how it stamps a value, at any time.

**Only one kind matters.** A **cadence** change alters the stream's behaviour for
every future market, so any timing base rate measured before it is describing a
schedule that no longer runs. A change of **broadcast time** is arbitrary and
carries no information for a market opened after it, provided the new time is
consistent.

**The exception** is a market already open when the time moved, because it was
priced under the old schedule.

**What to do.** `scripts/edge.py` detects both and compares the changepoint
against when your market opened. The value series is continuous through either,
so pricing keeps the full history.

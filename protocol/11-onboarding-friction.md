# Onboarding friction, observed by running the runbook

Recorded 2026-09-18 while executing [RUNBOOK.md](../RUNBOOK.md) end to end on a
machine cleared back to nothing. Every item below cost something during a real
run. None were visible from reading the documents.

This is the input for a session-based onboarding UI.

## What the UI needs, in one line

`scripts/status.sh` already emits the right primitive: **one phase number and
one next action**. A UI should render that, not re-derive it.

```
PHASE 4 of 7
NEXT: WAIT for the restore, then re-run this script
```

The three UI states that matter are **agent working**, **waiting on the human**,
and **long wait with progress**. Every phase is one of those.

## Phases that block on a human

These cannot be automated and should render as a distinct state, with the exact
commands to copy and a control to confirm completion.

| Phase | What the human does | Why it cannot be delegated |
|-------|--------------------|----------------------------|
| 1 | install `postgresql-client-16` | needs sudo |
| 6 | approve the agent rule | needs a wallet signature |
| 6 | send the funds | only the owner can move money |

Phase 6 also needs the human to **compare an address character by character**.
That is the single step where a mistake loses money, so a UI should show both
addresses side by side and make the comparison visual rather than asking someone
to eyeball two hex strings in a terminal.

## Long waits

Phase 4 dominates everything else. Measured on this run: snapshot at height
2543774 against a tip of 2616184, so about **72,400 blocks to replay at roughly
2 per second, near 10 hours**.

The wait has two distinct stages that look completely different, and conflating
them confuses people.

1. **Snapshot restore.** The RPC does not answer at all. Progress is only
   visible as chunk counts in the log, and there is no total in the log to
   divide by.
2. **Block replay.** The RPC answers and reports a height, so remaining time is
   computable as `(tip - local) / 2` seconds.

A UI should show a chunk counter for stage 1 and an ETA for stage 2, and should
never present stage 1 as a stalled stage 2.

**Do not poll this in a tight loop.** Emit on a change rather than a timer, and
add a heartbeat so a slow stretch does not read as a stall. See
`scripts/watch-progress.sh`.

## Defects the run exposed

**The node was not recognised as its own.** The runbook launches with
`--root ./tn-node`, a relative path, while the status script compared against an
absolute one. The result was "a kwild is running, but not for this deployment"
about a node it had just started. Fixed by resolving each process's `--root`
against its own `/proc/<pid>/cwd` rather than matching command line text.

**The RPC binds to `0.0.0.0` by default.** `kwild setup init` generates
`listen = '0.0.0.0:8484'`, and this protocol deliberately does not pass
`--rpc.private`. That combination publishes an unauthenticated RPC to the
network. Binding to loopback has to be a mandatory step rather than a remark,
and the admin socket has to move off its `/tmp/kwild.socket` default for the
same collision reasons as the ports.

**Working directory resets between agent tool calls.** Relative paths such as
`./tn-node` and `kwild-run.log` silently resolve somewhere else, and a check
then reports a missing file that exists. Instructions aimed at an agent should
use absolute paths or begin with an explicit `cd`.

**A background process needs `setsid`.** A plain `nohup ... &` inside a tool call
does not reliably outlive the call.

## Smaller things that still cost time

**The Postgres container is not ready when `docker run` returns.** It needs
roughly 15 seconds, and a status check in between reports no database at all.
Either wait, or have the UI retry rather than show a failure.

**`git clone truf-node-operator` has no stated destination.** The follow-up
command uses a relative path that implies the repository root, which would leave
an untracked clone inside the checkout. The location has to be explicit and
ignored.

**The port step can be a no-op.** When the defaults are free, the generated
config already matches and there is nothing to edit. Telling someone to edit
`config.toml` when no edit is needed invites them to break a correct file.

## Second run, and what it added

The run was repeated from a cleared machine to check the fixes. Everything above
held, and five more things surfaced that only a real run exposes.

**State sync can fail with zero peers and blame snapshots.** Five consecutive
starts died with `snapshots_discovered=0` and `snapshot file not provided`, which
points at state sync. The cause was that no dial ever completed, and a raw TCP
test of the bootnode ports succeeded throughout, which made the network look
healthy.

kwild will not say why a dial failed. `CompressDialError` keeps each address and
discards its cause at every log level, so the only way through is
`GOLOG_LOG_LEVEL="swarm2=debug"`. Filed as trufnetwork/kwil-db#1738.

**The sync is three stages, not two.** Loading the snapshot into Postgres takes
about 39 minutes and kwild logs no progress for it at all, so the display sat
silent through the longest part of setup. Progress has to come from Postgres,
using the table being copied, live row counts and database size.

**The RPC stops answering while the node replays hard.** Height was read only
from the RPC, so the display went blind for half an hour while the node was in
fact committing blocks the whole time. The log records every commit, so it is a
usable fallback.

**Throughput varies by more than twenty times.** Ordinary blocks replay at about
2.6 per second, blocks carrying `tn_digest` work at 0.1. A rate from two samples
predicted anything between two hours and eight days, so the estimate has to
average over the whole run.

**Real timings, measured.** Download 18 minutes for 3.0 GB in 203 pieces, load
39 minutes growing the database to 22 GB, catch-up 3h 30m for 73,000 blocks.
About 5 hours end to end, against the 10 the first arithmetic suggested.

## What already worked

The default-first port resolution behaved correctly. `5432`, `8484`, and `6600`
were free after teardown and were chosen without intervention, and the earlier
collision path had been exercised against a real conflict.

The verification gates caught what they were meant to. The genesis diff proved
mainnet, the database listing proved a fresh instance rather than another node's,
and `verified snapshot with trusted provider` appeared before any chunk was
trusted.

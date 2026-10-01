# Runbook: from nothing to a first trade

Follow this in order. It takes you from a bare machine to a placed trade on
TRUF.NETWORK mainnet, using real money.

**You do not need to read this whole file.** Run the status script, do what it
says, run it again.

If a check fails, go to [FIELD-MANUAL.md](FIELD-MANUAL.md) and look up the
symptom rather than guessing at the cause.

```bash
scripts/onboard.sh          # the session view, for a human watching
scripts/onboard.sh --watch  # refresh until the phase changes
scripts/status.sh           # the raw checks, for an agent parsing
```

`status.sh` reports `PHASE n of 7` and one `NEXT:` action, and `onboard.sh`
renders it. Detection lives in one place, so the two cannot disagree. It is safe to run at any time
and it works on a bare clone. **If you are resuming a session, run it first.**

## Progress tracking (MANDATORY)

Before doing anything else, call `TodoWrite` with these seven todos, all
`pending`. Claude Code renders them as a live checklist, which is the only
progress display the person actually sees. Output written inside a tool call is
not shown to them.

1. `Phase 1: Tools`
2. `Phase 2: Postgres`
3. `Phase 3: Node config`
4. `Phase 4: Sync to tip`
5. `Phase 5: SDK helper`
6. `Phase 6: Wallet (needs the owner)`
7. `Phase 7: First trade`

Transitions, updated the moment a phase starts or ends, never batched at the
end. Exactly one todo is `in_progress` at any time.

If your runtime has no `TodoWrite`, skip it and rely on the status block below.

## Showing progress in your reply

**Print the status block in your own message, not inside a tool call.** Generate
it with `scripts/onboard.sh --md` and paste the result. It renders as a table
with a progress bar, and it is how the person follows along.

Print it when you start, at every phase transition, and whenever you hand back
to the person. Do not print it more than once per reply.

At the start of a run, print this banner first:

```
████████╗██████╗ ██╗   ██╗███████╗
╚══██╔══╝██╔══██╗██║   ██║██╔════╝
   ██║   ██████╔╝██║   ██║█████╗
   ██║   ██╔══██╗██║   ██║██╔══╝
   ██║   ██║  ██║╚██████╔╝██║
   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝
```

`agent onboarding  ·  node → wallet → first trade`

## Rules for the agent following this

**Verify each phase before moving on.** Every phase has a check. A phase that
has not passed its check is not done, and continuing produces confusing failures
several steps later.

**Three phases need a human.** They are marked **HUMAN**. Stop, explain what you
need in plain language, and wait.

**Never read, print, or copy a key.** `tn-node/nodekey.json` and
`agent/agent.key` are private. The tooling signs with them without revealing
them.

**Use absolute paths, or `cd` first.** An agent's working directory can reset
between tool calls, so a relative path silently resolves elsewhere and a check
then reports a missing file that exists. Set `TN_HOME` once and use it.

```bash
export TN_HOME=$(pwd)      # from the repository root
```

**Ports resolve automatically.** `scripts/ports.sh` uses the upstream defaults
when free and steps to the next free port when not, recording the choice in
`.tn-env`. Do not hardcode a port.

**Start long jobs with `setsid`.** A plain `nohup ... &` inside a tool call does
not reliably outlive it.

### Showing progress during phase 4

Phase 4 runs for hours. Poll fast, print only on change.

```bash
scripts/watch-progress.sh
```

It polls every ten seconds and emits one line when progress crosses a step
boundary, stepping 2% through the fast stages and 1% through the catch-up, with
a heartbeat every five minutes so a slow stretch does not read as a stall.
Override with `STEP_FAST`, `STEP_SLOW` and `HEARTBEAT`.

| Mode | When | Looks like |
|------|------|-----------|
| `--line` | routine refresh | one scrolling line |
| `--md` | stage or phase change, handing back | the full block |

In Claude Code, run it through the monitoring tool so each line arrives as its
own message. **Relay the line and nothing else.** Commentary on every tick is
what makes a progress feed unreadable.

## Phase 1. Tools — **HUMAN** for one step

```bash
scripts/status.sh          # shows exactly which tools are missing
```

`kwild`, Docker, and Go you can install yourself. See
[skills/truf-node-up/SKILL.md](skills/truf-node-up/SKILL.md) section 1.

**The Postgres 16 client needs sudo, so the human runs it.** kwild refuses to
start on any other major version, and most current distributions ship 17 or 18.
The commands are in section 2 of that skill. Hand them over and wait.

**Check:** `psql --version` and `pg_dump --version` both report 16.x.

## Phase 2. Postgres

```bash
cd "$TN_HOME"
scripts/ports.sh           # resolve ports, defaults first
PGPORT=$(grep TN_PGPORT .tn-env | cut -d= -f2)
docker run -d --name tn-postgres \
  -p 127.0.0.1:$PGPORT:5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v tn-pgdata:/var/lib/postgresql/data \
  --shm-size=2gb --restart unless-stopped \
  ghcr.io/trufnetwork/kwil-postgres:16.8-2
```

**The container is not ready when `docker run` returns.** It needs roughly 15
seconds to initialise. Checking immediately reports no database at all, which
looks like a failure and is not. Wait for it:

```bash
for i in $(seq 1 30); do
  psql -h 127.0.0.1 -p "$PGPORT" -U postgres -d kwild -tAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
```

**Check:** `scripts/status.sh` reports postgres reachable.

Confirm the database that answered is **yours**. Another Kwil node's Postgres
answers a connection and returns plausible data from a different chain. See
[FIELD-MANUAL.md](FIELD-MANUAL.md) under **You are reading the wrong node**.

Confirm the database that answered is **yours**. Another Kwil node's Postgres
will answer a connection and return plausible data from a different chain.

## Phase 3. Node config

Clone the config repo **outside this checkout**, so it does not end up as an
untracked directory inside it.

```bash
git clone https://github.com/trufnetwork/truf-node-operator.git \
  "$(dirname "$TN_HOME")/truf-node-operator"
export TN_OPERATOR="$(dirname "$TN_HOME")/truf-node-operator"
```

Then `kwild setup init` against `$TN_OPERATOR/configs/network/v2/genesis.json`,
which is **mainnet**. The full command is in section 5 of the node skill.

**Check:** `grep chain_id tn-node/genesis.json` shows `tn-v2.1`. If it shows
anything else you have initialised a private network that will sync instantly
and contain nothing.

### Then fix two insecure defaults. This is not optional.

`kwild setup init` writes `listen = '0.0.0.0:8484'` for the RPC, and this
protocol deliberately does not pass `--rpc.private`. **Left alone, that
publishes an unauthenticated RPC to the network.** Bind it to loopback.

It also puts the admin socket at `/tmp/kwild.socket`, which collides with any
other Kwil node on the machine for the same reason the ports do.

```bash
cd "$TN_HOME"
RPCPORT=$(grep TN_RPC_PORT .tn-env | cut -d= -f2)
sed -i "s|^listen = '0.0.0.0:$RPCPORT'|listen = '127.0.0.1:$RPCPORT'|" tn-node/config.toml
sed -i "s|^listen = '/tmp/kwild.socket'|listen = '$TN_HOME/tn-node/admin.socket'|" tn-node/config.toml
grep -nE "^ *(port|listen) *=" tn-node/config.toml
```

**Only edit the ports if they differ from the generated defaults.** When 5432,
8484, and 6600 were free, `setup init` already wrote exactly those and there is
nothing to change. Editing a correct file is how you break it.

## Phase 4. Sync — **LONG WAIT**

```bash
cd "$TN_HOME"
setsid nohup kwild start --root "$TN_HOME/tn-node" \
  > "$TN_HOME/kwild-run.log" 2>&1 < /dev/null &
sleep 30
grep STATESYNC "$TN_HOME/kwild-run.log" | tail -5
```

`setsid` matters. A plain `nohup ... &` started inside an agent tool call does
not reliably outlive that call.

Look for `verified snapshot with trusted provider`. Without that line the node
accepted a snapshot nobody vouched for.

**The wait has three stages that look nothing alike.** Do not mistake one for a
stall.

| Stage | What it is | Measured on one run |
|-------|-----------|---------------------|
| Download | pulling the snapshot from peers | 18 min, 203 pieces, 3.0 GB |
| Load | psql restoring it into Postgres | 39 min, growing to 22 GB |
| Catch up | replaying every block since | 3h 30m, 73,000 blocks |

That run took about **5 hours end to end**, not the 10 the arithmetic first
suggested. Compute the estimate rather than quoting one, because the number
moves.

**Throughput varies by more than twenty times.** Ordinary blocks replay at
around 2.6 per second. Blocks containing `tn_digest` work, the job that collapses
stream-days into OHLC, drop it to 0.1 while Postgres goes I/O bound.

So a rate taken from two samples predicts anything between two hours and eight
days. `status.sh` averages over the whole catch-up instead, which converges.

**The RPC stops answering while the node replays hard.** That is not a stall and
not a crash. `status.sh` falls back to counting `Committed Block` lines in the
log, so check its output rather than the RPC directly.

**Check:** `scripts/status.sh` reports `at tip`.

If it never starts, or the estimate swings wildly, see
[FIELD-MANUAL.md](FIELD-MANUAL.md) under **Sync never starts** and **Sync speed
swings wildly**. Do not restart in a loop, and do not trust a raw port test.

## Phase 5. SDK helper

```bash
cd agent && go build -o agent . && cd ..
./agent/agent keygen
```

Strike bands are encoded in an ABI blob that only the SDK decodes, so the
analysis scripts need this binary. `keygen` writes `agent/agent.key` at mode
0600.

**Check:** `scripts/status.sh` shows the binary built and the key present.

## Phase 6. Wallet — **HUMAN**

Read [skills/truf-agent-wallet/SKILL.md](skills/truf-agent-wallet/SKILL.md)
before starting this.

You create the rule and derive the expected agent address. **The owner approves
it and sends the money, and only they can.** Give them
[skills/truf-agent-wallet/owner-walkthrough.md](skills/truf-agent-wallet/owner-walkthrough.md),
which is written for a non-technical reader.

```bash
./agent/agent create-rule
./agent/agent derive <owner-address>     # give this to the owner to verify
```

Tell the owner the one thing that matters: **compare the agent address the site
shows against the one you derived, character by character, before sending
anything.**

Suggest five dollars. Enough to be real, small enough not to matter.

Once funded, record the address so later sessions find it:

```bash
echo "TN_MAA=0x..." >> .tn-env
```

**Check:** `scripts/status.sh` reports a USDC balance.

## Phase 7. Trade

Read [skills/truf-market-read/SKILL.md](skills/truf-market-read/SKILL.md)
first. The expensive mistakes here are reading comprehension, not execution.

```bash
psql -f sql/market-scan.sql            # one row per MARKET, best first
scripts/edge.py <order-book-id>        # should I bet, which book, what price
```

`edge.py` compares each band's probability against the **ask**, sizes against
the book and your capital, and reports settlement exposure. Read its
`SETTLEMENT MECHANICS` block before committing, because a ladder can settle with
two winners or none.

```bash
./agent/agent buy <maa> <order-book> <yes|no> <price-cents> <shares>
scripts/portfolio.py <maa>
```

**Check:** the position appears in `portfolio.py`, marked at the best
other-party bid.

Before trusting any number you derived yourself, read **Right data, wrong
meaning** in [FIELD-MANUAL.md](FIELD-MANUAL.md). It is the failure that costs
most here.

### After it settles

Settlement runs on a `*/5` sweep, so expect it a few minutes past `settle_time`.
Check the whole ladder, not only your own book.

```sql
SELECT id, settled, winning_outcome,
       to_timestamp(settle_time)::timestamptz(0)  AS settle_time,
       to_timestamp(settled_at)::timestamptz(0)   AS settled_at
FROM main.ob_queries
WHERE settle_time = <your settle_time> ORDER BY id;
```

**Exactly one book must show `winning_outcome = t`.** The bands partition the
number line, so two winners or none means the ladder attested against two
different values and settlement is wrong, whatever your own book says. That is
trufnetwork/node#1430.

A worked example from this protocol's own first trade. The ladder settled at
20:20:00 through 20:20:05, one book per second, which is the serialised
attestation the issue describes. Exactly one book won, so the exposure did not
become harm on that occasion.

```
spent     $3.42     9 shares at 38c
received  $8.82     9 winning shares at 98c after the 2% fee
net       +$5.40
```

---

## The scripts

| Script | What it does |
|--------|--------------|
| `scripts/status.sh` | the raw checks, `PHASE n of 7` plus one next action, and `SYNC_*` metrics |
| `scripts/check-schema.sh` | verifies every table and column this repo reads is present |
| `scripts/refresh-streams.py` | optional, caches stream names so output shows tickers |
| `scripts/onboard.sh` | renders that. `--md` for the full block, `--line` for one line |
| `scripts/watch-progress.sh` | emits a line when progress crosses a step boundary |
| `scripts/ports.sh` | resolves ports, defaults first, into `.tn-env` |
| `scripts/tnconn.py` | shared connection settings for the Python scripts |
| `scripts/edge.py` | which order book to trade, at what price, and the settlement exposure |
| `scripts/portfolio.py` | holdings marked at the best other-party bid |

Detection lives only in `status.sh`. Everything else renders it, so the views
cannot disagree with each other.

## When something does not work

[FIELD-MANUAL.md](FIELD-MANUAL.md) is indexed by symptom. Look up what you are
seeing rather than what you think the cause is.

The most common by far is not a crash. It is a query that runs, returns a
plausible number, and supports a wrong conclusion. That one is under **Right
data, wrong meaning**.

# trading-agent

Running a local TRUF.NETWORK mainnet node so an agent can read prediction market
state **directly from Postgres**, and trade against it through the SDK.

The deliverable is not the node. It is a **reproducible protocol** an agent can
download and replay on a clean machine — eventually packaged as open-source
skills.

## The core idea

Access is **asymmetric**, and that asymmetry is the whole design:

- **Reads — plain SQL, no SDK.** Kwil maps each namespace to a Postgres schema of the same name
  so the market protocol lives in schema `main`. Arbitrary queries,
  no rate limits, no indexer's opinion of what matters.
- **Writes — SDK only, never SQL.** That database *is* consensus state. A direct
  INSERT forks your node and drops it out of consensus.

The edge is not latency. It is **reading comprehension** — the market mechanics
that are sitting in migration files nobody reads. See
[06-signal-architecture.md](protocol/06-signal-architecture.md); that is the
document worth reading first.

## Just follow the directions

Point an agent at this repository and it can go from a bare machine to a placed
trade.

```
Clone https://github.com/trufnetwork/trading-agent and follow RUNBOOK.md
```

[RUNBOOK.md](RUNBOOK.md) is the ordered path, and it assumes things work.
[FIELD-MANUAL.md](FIELD-MANUAL.md) is the fallback, indexed by symptom, for when
they do not. `scripts/status.sh` reports
`PHASE n of 7` and the single next action, works on a bare clone, and is how a
later session resumes without guessing.

Verified end to end on a cleared machine: about 5 hours from nothing to a
placed trade, of which 18 minutes is downloading, 39 minutes is loading the
database and the rest is replaying blocks.

Three phases need a human, and the runbook marks them: installing the Postgres
16 client, approving the agent wallet, and funding it.

## Skills

The reference material the runbook links into. Start at
[AGENTS.md](AGENTS.md) if you want the map rather than the path.

| Skill | Use when |
|-------|----------|
| [truf-node-up](skills/truf-node-up/SKILL.md) | getting a node running and synced |
| [truf-agent-wallet](skills/truf-agent-wallet/SKILL.md) | giving an agent a funded, non-custodial wallet |
| [truf-market-read](skills/truf-market-read/SKILL.md) | understanding and querying the markets |
| [truf-trade](skills/truf-trade/SKILL.md) | choosing a trade, placing it, tracking it |

These are plain Markdown and executable scripts, so any agent can use them. No
server, no runtime, nothing to install beyond the node.

Claude Code users can install the set as a plugin:

```
/plugin marketplace add trufnetwork/trading-agent
/plugin install truf-agent@trading-agent
```

Everything under [protocol/](protocol/) is the evidence trail behind the skills:
the measurements, the reasoning, and the mistakes that produced each rule.

## Documents

| File | What it is |
|------|-----------|
| [protocol/01-prerequisites.md](protocol/01-prerequisites.md) | kwild install, PG16 client requirement, mainnet config |
| [protocol/02-node-up.md](protocol/02-node-up.md) | Postgres + node, port conflicts, state sync |
| [protocol/05-wallet-funding-design.md](protocol/05-wallet-funding-design.md) | MAA agent wallet, bridging, who signs what *(design)* |
| [protocol/06-signal-architecture.md](protocol/06-signal-architecture.md) | **Market mechanics, resolution rule, agent architecture** |
| [protocol/07-indexer.md](protocol/07-indexer.md) | Custom indexing DB: what the node destroys and how we keep it |
| [protocol/08-operations.md](protocol/08-operations.md) | **Operational failure modes an agent will hit** |
| [protocol/09-lp-opportunity.md](protocol/09-lp-opportunity.md) | LP reward pool sizing, APY, and why it is validation not income |
| [protocol/owner-walkthrough.md](protocol/owner-walkthrough.md) | Funding instructions written for a non-technical owner |
| [sql/markets.sql](sql/markets.sql) | Reference queries with price semantics documented |
| [sql/volume.sql](sql/volume.sql) | Volume and traders per indexer#102, no indexing needed |
| [sql/market-scan.sql](sql/market-scan.sql) | All open markets ranked, one row per market |
| [sql/orderbooks.sql](sql/orderbooks.sql) | The order books inside one market |
| [scripts/edge.py](scripts/edge.py) | **Where is the price wrong, and what do I buy?** |
| [scripts/portfolio.py](scripts/portfolio.py) | Cash, positions, cost basis, mark, settlement outcomes |
| [agent/](agent/) | Go client: keygen, create-rule, derive, decode, buy |
| [sql/indexer-schema.sql](sql/indexer-schema.sql) | Indexer tables, each naming its open question |
| [scripts/tn-status.sh](scripts/tn-status.sh) | Node process, sync position, DB readiness |
| [scripts/markets.py](scripts/markets.py) | Live market report straight from Postgres |
| [scripts/refresh-streams.py](scripts/refresh-streams.py) | Stream names from trufscan (no on-chain names exist) |
| [scripts/index-tick.sh](scripts/index-tick.sh) | One ingest tick, or `--loop` |

## Conventions

**Every claim is marked verified or not.** Docs cite the migration or source
file that proves them. Anything unconfirmed says so. Setup steps carry an
explicit verification command — a step is not done because it ran, it is done
because a check passed.

This matters more than usual: an agent replaying this protocol has no way to
tell a measured fact from a confident guess unless the document says which it
is.

## Ports (side-by-side deployment)

Kwil-family nodes default to 8484 / 6600 / 5432 and collide with any other node
on the machine. This deployment deliberately shifts:

| Service | Port |
|---------|------|
| Postgres | 5433 |
| Node RPC | 127.0.0.1:8485 |
| P2P | 0.0.0.0:6601 |

## Status

- [x] 1. Prerequisites — kwild 2.5.8, PG16 client
- [x] 2. Postgres + node running on mainnet `tn-v2.1`
- [x] 3. State sync — at chain tip. Replay took 9h15m, see [findings-blocksync-latency.md](protocol/findings-blocksync-latency.md)
- [x] 4. Direct read of live markets (167 live, 1,189 open orders, bucket ladders confirmed)
- [~] 5. Agent wallet + funding — design verified against mainnet, not executed
- [x] 6. SDK write — 9 YES @ 38c on order book 1176, filled block 2616043
- [x] 7. Custom indexing DB — running on 5434, capturing prints, order events, book snapshots
- [ ] 8. Package as skills

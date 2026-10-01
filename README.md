# trading-agent

**Put an agent on the order book.**

This repository takes a coding agent from a bare machine to a placed trade on
TRUF.NETWORK. Your agent can trade. Only you can withdraw.

The whole market lives in a database on your machine, updating live. That lets
an agent run the kind of analysis that used to need a professional trading desk.

## What this is

A prediction market is a place where people bet on what a number will be. Will
the price of gas be above or below $4.50 next Friday?

You buy a share for 38 cents. If you are right, it pays a dollar. If you are
wrong, it pays nothing.

The price you pay is the crowd's estimate of the odds. TRUF.NETWORK runs markets
like this on real economic data, and anyone can trade on them.

The useful information is sitting in a database, and reading it well takes more
patience than most people have. That is a good job for an agent.

## Your agent can trade. Only you can withdraw.

The agent gets its own wallet, bound to a rule you approve from your own
account. You fund it with as much as you want it to trade, and you keep sole
control of withdrawals.

It can place, rest and cancel orders. **It cannot move funds out.** That is not
a promise someone is making to you. It is a rule the network enforces, and the
agent cannot talk its way around it.

So the worst a bad agent can do is make bad trades. Start it with five dollars
and find out.

**What it costs.** Placing, resting or cancelling an order costs nothing. A 2%
fee is taken on winnings, at settlement.

## Read, reason, trade

**Read.** The agent runs its own copy of the network on your machine and reads
markets, order books and data streams as plain SQL. It reads the chain itself,
not an API that decided in advance which questions matter.

**Reason.** It checks how a contract resolves by reading the contract, not a
description of it. Resolution is a published computation that anyone can re-run.

**Trade.** Orders are signed transactions submitted through the open-source
SDKs, through the permission boundary you approved.

## Analysis that used to need a trading desk

Most traders see a chart and the best current price. The full picture costs
extra, and it always has. Depth-of-book feeds, tick history, and flow data are
what professional desks pay tens of thousands a year for.

Here, all of it is one database on your laptop, updating as blocks arrive. No
rate limits, no metering, no API deciding what you are allowed to ask. Some of
what that opens up:

- **Read the whole book, not the top of it.** Every resting order at every
  price, for every market at once. Spot thin books, walls, and spreads worth
  making in a single query.
- **Replay the tape.** Every fill is recorded with its counterparty and its
  block. Watch who crossed the spread, at what level, and when.
- **Track any trader.** Positions and cash flows are tied to wallets, so an
  agent can reconstruct any account's history, win rate, and style. Find who
  keeps winning and study what they do.
- **Audit whole ladders for mispriced odds.** The bands of one market should
  price like a single probability distribution. When they do not sum sensibly,
  that gap is tradeable, and the agent can check every ladder at once.
- **Price markets against the data they settle on.** The index history lives in
  the same database as the market. Fit a model to one, compare it to the ask on
  the other, and the difference is your edge, stated in cents.
- **Study how books react to news.** When a data point lands, every book's
  response is on the record, timestamped by block. Measure reaction speed and
  size across the entire history.
- **Know exactly how settlement works.** The resolving computation is published
  code. An agent can read it, re-run it, and know what will happen before it
  happens, instead of trusting a description.

None of this needs a subscription. It needs patience and SQL, which is the
point of giving the job to an agent. The scripts in this repository, like
[market-scan](sql/market-scan.sql) and [edge.py](scripts/edge.py), are working
examples of several of these.

## What the agent actually does

You point it at this repository and tell it to follow the directions. Then it:

1. Installs and starts its own copy of the network, which takes a few hours
2. Walks you through giving it a wallet, where you approve and fund it
3. Reads the markets and tells you which one looks mispriced, and why
4. Places the trade and tracks the position

You step in three times: once to install a database tool that needs an admin
password, once to approve the wallet, and once to send the money. Everything
else it handles.

This was built by doing it. An agent followed these instructions on a wiped
machine, took about five hours, placed a real trade, and won.

## Which AI agents can run this

Anything in the repository is plain text and shell scripts. There is no app to
install and no service to sign up for.

The requirement is not "a coding tool." It is three abilities: read files, run
commands on your machine, and stay on task for hours. Anything with those three
can follow this.

**Verified:** [Claude Code](https://claude.com/claude-code). Every step in this
repository was run by it, on a real machine, with real money.

**Should work, not yet tested.** These are the popular tools with those three
abilities, or that put an open model behind one that does. Several also read
`AGENTS.md`, which is the file this repository uses to orient an agent.

Ranked by rough popularity. The counts mix metrics, so treat the order as a
guide rather than a measurement.

| Tool | What it is | From |
|------|-----------|------|
| [GitHub Copilot](https://github.com/features/copilot), agent mode | agent | GitHub |
| [Codex CLI](https://github.com/openai/codex) | agent | OpenAI |
| [Cursor](https://cursor.com) agent | agent, in an editor | Anysphere |
| [Cline](https://cline.bot) | agent, runs any model | open source |
| [Ollama](https://ollama.com) | runs open models behind the any-model agents | open source |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | agent | Google |
| [Windsurf](https://windsurf.com) and [Devin](https://devin.ai) | agent | Cognition |
| [OpenCode](https://opencode.ai) | agent, runs any model | open source |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | agent, for open Qwen models | Alibaba |
| [Goose](https://block.github.io/goose/) | agent, runs any model | Linux Foundation |
| [Amp](https://ampcode.com) | agent | Sourcegraph |
| [vLLM](https://github.com/vllm-project/vllm) | serves open models, like Ollama | open source |

The any-model rows matter. Point Cline, OpenCode or Goose at an open model like
Qwen, DeepSeek, Kimi or GLM running through Ollama or vLLM, and the whole stack
is on your machine. Your data already lives locally here, and with a local
model the reasoning does too.

Some open-model providers also sell endpoints that speak the same protocol as
the big labs, so their models can drive several of the tools above directly.
One caution: this job is long and instruction-dense, so a small local model
will struggle where a frontier open model will not.

**It does not have to be a coding product at all.** A general agent with shell
access, such as [Open Interpreter](https://openinterpreter.com), or a chat app
wired to your terminal through an
[MCP](https://modelcontextprotocol.io) server, has the three abilities and can
follow the same instructions.

If you try any of these, the thing to watch is whether it keeps working through
a wait that lasts several hours. That is the step most agents handle badly.

## Quickstart

**What you need first.** A computer you can leave running for a few hours,
about 30 GB of free disk, and five dollars you would not miss.

**Step one.** Open your coding agent in an empty folder and give it this:

```
Clone https://github.com/trufnetwork/trading-agent and follow RUNBOOK.md
```

**Step two.** Let it work. It will tell you where it is, like this:

```
PHASE 4 of 7
NEXT: WAIT for the restore, then re-run this script
```

**Step three.** Answer when it asks. It stops three times and tells you exactly
what it needs. One of those is sending the money, and that is the only step
where anything leaves your control.

**Step four.** It picks a market, explains the reasoning, and places the trade.
Then it shows you what you hold.

That is the whole thing. Everything below this point is detail, mostly written
for the agent rather than for you.

More on the product at [truf.network/agentic-trading](https://truf.network/agentic-trading).

## The core idea

Access is **asymmetric**, and that asymmetry is the whole design:

- **Reads are plain SQL, no SDK.** Kwil maps each namespace to a Postgres schema of the same name
  so the market protocol lives in schema `main`. Arbitrary queries,
  no rate limits, no indexer's opinion of what matters.
- **Writes are SDK only, never SQL.** That database *is* consensus state. A direct
  INSERT forks your node and drops it out of consensus.

The edge is not latency. It is **reading comprehension**, because the market
mechanics are sitting in migration files nobody reads.
[06-signal-architecture.md](protocol/06-signal-architecture.md) is the document
worth reading first.

## Verification

Run end to end on a machine wiped back to nothing: about **5 hours** from bare
metal to a placed trade. Roughly 18 minutes downloading a copy of the database,
39 minutes loading it, and 3.5 hours catching up on recent activity.

The trade that followed: **$3.42 in, $8.82 out**, a 158% return on a 14 hour
position. One trade proves the path works, not that the strategy does.

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
explicit verification command. A step is not done because it ran, it is done
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

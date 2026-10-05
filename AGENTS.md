# Agent instructions

This repository teaches an agent to run a TRUF.NETWORK node locally, read
prediction market state directly from Postgres, and trade against it.

Everything here is plain Markdown and executable scripts. There is no server to
run and nothing to install beyond the node itself.

## Start here

**[RUNBOOK.md](RUNBOOK.md) takes you from nothing to a placed trade.** Follow it
in order. It assumes things work.

**[FIELD-MANUAL.md](FIELD-MANUAL.md) is for when they do not.** It is indexed by
symptom, so look up what you are seeing rather than what you think the cause is.
Every entry in it was hit on a real run. If you are resuming, or you are not sure what state this machine is
in, run the status script first and do what it tells you.

```bash
scripts/status.sh         # PHASE n of 7, and STOP on a phase not yet shown
scripts/onboard.sh --md   # the block to end your turn with
scripts/status.sh --go    # after the person replies: the single next action
```

**Show progress where the person can see it.** They see only the final message
of your turn, not tool calls and often not the text between them. At every new
phase, end your turn with the whole output of `scripts/onboard.sh --md`, and
continue with `scripts/status.sh --go` once they reply.

Three phases need a human: installing the Postgres 16 client, approving the
agent wallet, and funding it. Stop and ask rather than trying to work around
them.

## Reference

The runbook links into these. Read the one that matches the task, not all four.

| Task | Skill |
|------|-------|
| Get a node running and synced | [skills/truf-node-up/SKILL.md](skills/truf-node-up/SKILL.md) |
| Give an agent a funded, non-custodial wallet | [skills/truf-agent-wallet/SKILL.md](skills/truf-agent-wallet/SKILL.md) |
| Understand and query the markets | [skills/truf-market-read/SKILL.md](skills/truf-market-read/SKILL.md) |
| Choose a trade, place it, track it | [skills/truf-trade/SKILL.md](skills/truf-trade/SKILL.md) |

`truf-market-read` is the one worth reading even if you think you only need to
trade. Most expensive mistakes in this domain are reading comprehension
failures, not execution failures.

## The two rules that matter most

**1. Reads are plain SQL. Writes are SDK only.** Kwil maps each namespace to a
Postgres schema of the same name, so the market protocol lives in schema `main`.
Query it freely. Never `INSERT` or `UPDATE` it, because that database is
consensus state and a direct write forks your node out of consensus.

**2. Verify what a value MEANS before computing on it.** The column names in
this schema are honest but incomplete. `collateral_change` is a magnitude with
its sign held in another column, `price` encodes side as well as level, and a
`query_id` is one order book rather than one market. Check the defining
migration before you aggregate anything.

## Evidence

Each skill is a distilled procedure. The reasoning, measurements, and the
mistakes that produced each rule live in [protocol/](protocol/). Read those when
a skill's instruction seems arbitrary, because it probably is not.

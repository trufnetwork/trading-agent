---
name: truf-trade
description: >
  Choose which TRUF.NETWORK market to trade, size the position, place the order
  through the SDK, and track the portfolio. Use when asked which market to
  trade, whether a price is wrong, how to buy or sell, or what a wallet
  currently holds. Answers the question a trader asks most often, which is where
  the price is wrong and what to do about it.
---

# Trade

Read [truf-market-read](../truf-market-read/SKILL.md) first. Most losses in this
domain come from misreading the schema, not from bad execution.

**Reads are SQL. Writes are SDK only.** A direct `INSERT` into the market tables
forks your node out of consensus.

## Which market should I trade

This is the most frequent question, so it is a script rather than an ad hoc
query. It runs in under a second.

```bash
./scripts/edge.py <any_order_book_id>            # analyse that book's market
./scripts/edge.py 1176 --capital 5               # size against real money
```

It resolves the market containing the book, decodes every strike band, models
the daily move, compares each band's probability against the **ask**, sizes
against both the book and the wallet, and reports settlement exposure.

To find candidates first:

```bash
psql -h 127.0.0.1 -p "$(grep TN_PGPORT .tn-env | cut -d= -f2)" -U postgres -d kwild -f sql/market-scan.sql
```

That returns one row per **market**, not per order book, ranked with the most
tradeable first.

## The method, so you can check the script

1. Resolve the market containing the order book, on the composite key.
2. Decode each band from `query_components` using the SDK.
3. Take the stream's current value and its daily move distribution.
4. Estimate the probability the next print lands in each band.
5. Compare that probability to the **ask**, never the mid.
6. Size against available depth at that level and against free capital.
7. Check settlement exposure before committing.

Step 5 is the one people get wrong. You buy at the ask, so comparing to the mid
inflates edge by half the spread on every line.

## Buy at market, or split and sell the other side

Two ways into the same exposure, and they are not always priced the same.

- **Buy YES** at the ask. Costs `ask` per share.
- **Split**, which mints a YES plus NO pair for one dollar, then sell the leg
  you do not want. Nets `100 - other_leg_bid` per share.

Compare `ask` against `100 - NO_bid`. Use the **NO bid**, because that is the
leg you are selling. Using the YES bid here is a real and easy mistake.

Buying direct is also far more capital efficient, because a split locks a full
dollar per pair up front while a direct buy locks only the ask.

## Placing the order

The write path is Go. `sdk-py` is a cgo binding over the same library and ships
narrower wheels, so prefer `sdk-go`.

```bash
./agent/agent keygen                    # create the agent key, mode 0600
./agent/agent create-rule               # operator side, no funds needed
./agent/agent derive <owner>            # expected agent address, give to owner
./agent/agent decode <hex>              # strike bands out of the ABI blob
scripts/describe.py <book>              # what the market is, in words, with its trufscan link
./agent/agent buy <maa> <order-book> <yes|no> <price-cents> <shares>
```

The order goes through the agent's permission boundary:

```go
tx, err := actions.ExecuteAgentAction(ctx, types.MAAExecuteInput{
    MAAAddress: maaAddr.Bytes(),
    Namespace:  "main",
    Action:     "place_buy_order",
    Args:       []any{book, outcome, price, amount},
})
```

**Never read the agent key into the conversation.** It is mode 0600 and
gitignored, and the tooling signs with it without printing it.

## Portfolio

```bash
./scripts/portfolio.py <wallet_address>
```

Positions are marked at the best **other-party bid**, which is what you could
actually sell into now. Marking at the mid or the ask overstates the book,
because you cannot transact at either.

Cost basis comes from `main.ob_net_impacts`, the protocol's own per-transaction
ledger. Remember `collateral_change` is a magnitude with its direction in
`is_negative`, so spend and receipt must be separated rather than summed.

## Before you commit

**Is the outcome already decided?** If no further print is due before
`settle_time`, the current print is the resolving value and every other book is
a loser, whatever the prices say. `edge.py` says so under **IS IT DECIDED?** and
withholds its buy recommendation when it is.

**Can this ladder split?** Settlement captures a ladder one book per block, so
a print landing in that window can settle it with two winners or none, meaning
a correct band can pay nothing. `edge.py` reports a stream's historical exposure and realised harm
separately, because the two are different numbers.

**What is the publication lag?** A stream that publishes after `settle_time`
resolves on the previous value, which is already on chain. That is by design and
it is a legitimate edge.

## Fees

There are **no protocol fees for trading**. Placing and cancelling are free and
unfilled orders return whole.

A winning share pays **98 cents**, after the 2% settlement fee. Losing shares
pay nothing. Size on the 98, not the dollar.

## Evidence

- [protocol/06-signal-architecture.md](../../protocol/06-signal-architecture.md)
- [protocol/09-lp-opportunity.md](../../protocol/09-lp-opportunity.md)

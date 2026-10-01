# The LP reward opportunity, measured 2026-09-18

A snapshot analysis, not a standing claim. Every figure is reproducible from the
node with the queries in [sql/volume.sql](../sql/volume.sql) and the invariants
in [06-signal-architecture.md](06-signal-architecture.md). Re-measure before
acting: this market is small enough that a single participant changes it.

## The finding

**LP rewards are going almost entirely unclaimed**, and not because they are
hard to earn. Eligibility is being missed on a mechanical requirement.

```
25 settlements in 24h  ->  0 LPs paid, $0.00 distributed
main.ob_rewards        ->  0 rows
```

Eligibility needs the same participant holding a YES sell at `p` and a NO buy at
`100 - p`, **at equal size**. Across all live markets:

```
pairs summing to exactly 100c :  45
actually eligible             :   2   (1 participant, 2 markets)
```

Forty-five pairs reach 100c and only two match on size. The pool is not
contested, it is simply not being collected.

## Pool size, exact rather than estimated

The pair invariant makes this an identity, not an estimate. Shares exist only by
minting a YES+NO pair for $1, so YES outstanding always equals NO outstanding
(verified 130 of 130 markets) and **exactly one side of each pair wins**.

```
pairs outstanding, all live markets   4,116
settlement fee = pairs x $1 x 2%     $82.32
LP share       = fee x 75%           $61.74     <- the entire prize
```

Roughly **$0.47 per market**, which is below the 1 USDC minimum order size in
most of them.

Split by settlement horizon:

| Settling | Markets | Pairs | LP pool |
|----------|---------|-------|---------|
| 0-7 days | 85 | 3,264 | $24.48 |
| 8-30 days | 30 | 3,788 | $28.41 |
| 30+ days | 15 | 1,180 | $8.85 |

The near-term bucket gives the cycle rate: **$24.48/week, so ~$1,273/year** at
current open interest. That is the ceiling on this entire activity.

## Capital and return

Posting N shares of paired liquidity ties up roughly **$1 per share**: a split
mints the pair, and the buy side locks its price. Capital recycles as markets
settle, so APY is weekly yield times 52 rather than a year of lockup.

| Approach | Capital | Weekly capture | APY | Annual |
|----------|---------|----------------|-----|--------|
| Match existing liquidity, ~50% | $3,264 | $12.24 | ~19% | ~$637 |
| Modest size, low competition, ~75% | $1,500 | $18.36 | ~64% | ~$955 |
| Sole eligible LP, ~100% | $1,500 | $24.48 | ~85% | ~$1,273 |

The high end is plausible **only** because nobody currently qualifies. You do
not need to outspend anyone, only to form the orders correctly.

## Why the APY is misleading

1. **It is not yield, it is compensation for risk.** Paired orders fill. When
   they do you hold directional exposure in a market you meant to be neutral in,
   and one bad settlement erases many weeks of rewards.
2. **The absolute number is ~$1,273/year at 100% capture.** An 85% APY on $1,500
   is about $100/month. That is not an income stream.
3. **It dilutes on contact.** Rewards are pro-rata and the strategy is open
   source. A second competent LP roughly halves it.
4. **Rewards weight on spread tightness and liquidity-hours, not just size**, and
   the exact `reward_percent` weighting across tiers has not been verified here.
5. **The market is tiny.** See below.

## Market reality, so the numbers are not read as bigger than they are

```
wallets ever seen in order events        11
traders per question                    2-3
true trading volume, per question       $600-1,000  (whole market life)
mint/burn to trade ratio                ~49:1
volume, all 167 live markets            $66,719     (floor: 21d event retention)
```

Fill risk is **low**, which is good for an LP. On one market, $278 of direct
fills across its entire life. Quotes rest largely untouched, so liquidity-hours
accrue without much inventory accumulating.

Note that volume and the fee pool are decoupled. The fee is charged on winning
shares at settlement, so heavy churn does not enlarge the pool, and low trading
does not shrink it.

## What this is actually good for

Not income. **Validation.**

It is the right shape for a first live trade: small enough that total loss is
irrelevant, real enough to exercise the whole stack end to end, and it tests a
specific falsifiable claim. If we post size-matched pairs and `main.ob_rewards`
starts showing our participant with a non-zero `reward_percent`, we have
verified the entire chain from local SQL through MAA execution to on-chain
reward capture.

Size it at **$100-200**, and do not scale until a settlement has actually paid.

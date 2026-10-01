---
name: truf-agent-wallet
description: >
  Give an agent a funded, non-custodial wallet on TRUF.NETWORK using a Modular
  Agent Address, so it can trade but can never withdraw. Use when onboarding a
  new trading agent, when funding or bridging USDC to an agent, or when
  explaining the process to a non-technical owner. Covers the permission
  boundary, what the owner must verify, and the bridge path.
---

# Set up an agent wallet

A **Modular Agent Address** is a non-custodial wallet an agent controls for
trading and cannot drain. The owner keeps withdrawal rights.

The boundary is enforced by the network, not by the agent's good behaviour. A
restricted agent is blocked from `transfer`, `bridge`, `issue`, and `lock_admin`
**at any call depth**, so it cannot reach them indirectly. `lock` and `unlock`
stay open because trading needs them.

## Who does what

The agent operator and the owner are different people, and the split matters.

| Step | Who | Why |
|------|-----|-----|
| Create the rule | operator | no signature or funds needed |
| Derive the expected agent address | operator | the owner checks against it |
| Approve the rule | owner | signs a message, moves no money |
| Fund | owner | the only step where money moves |
| Trade | agent | the only thing it can do |

**Interactive logins and wallet signatures belong to the owner.** An agent must
never hold or request the owner's credentials.

## Grant only these four actions

Verify the rule before approving. A trading agent needs exactly:

- place buy order
- place sell order
- place split limit order
- cancel order

**If the rule mentions withdraw, bridge, transfer, or settle, stop.** Those are
the only things that can move money somewhere the owner did not choose.

## Hex prefixes are a boundary, not a formatting detail

A Rule ID must be given to the owner **with its `0x` prefix**. The form rejects
it otherwise with a message about 32-byte hexadecimal format, and the owner has
no way to know what is wrong.

The same applies to any address you hand a human to paste.

## The one check worth slowing down for

After approval the interface shows an **agent wallet address**. The owner
compares it to the expected address the operator derived, character by
character.

If they do not match, stop and send nothing. Everything else in this process is
routine and reversible. This is the step that is not.

Connect with **zero initial funding** on the first pass. The modal does not show
the agent address before signing, and connection and funding are separate
transactions anyway, so funding first would mean sending money before seeing
where it goes. Connect, read the address, verify it, then add funds.

## Funding

Two sources. Use whichever matches where the money already is.

| Source | When | Cost |
|--------|------|------|
| Fund from TN Account | USDC already on TRUF.NETWORK | about a cent, instant |
| Fund via Ethereum Bridge | USDC on Ethereum | gas, plus a few minutes |

Set the asset to **USDC**. It defaults to `$TRUF`, which is not what these
markets settle in.

Quote **up to 15 minutes** for a bridge. It is usually much faster, and the
number depends on how busy Ethereum is. Underpromise here rather than explain a
delay later.

Verified on mainnet: a five dollar bridge credited exactly five dollars in about
two and a half minutes. Deposits are not subject to the protocol's fee config.

## Confirming the money arrived

Read it from the node rather than from a UI.

```sql
SELECT round(b.balance/1e6, 6) AS usdc
FROM kwil_erc20_meta.balances b
JOIN kwil_erc20_meta.reward_instances r ON r.id = b.reward_id
WHERE b.address = decode('<address without 0x>','hex')
  AND r.erc20_decimals = 6;
```

## What the owner is actually risking

Worth stating plainly, because the real risk is easy to lose among the
reassurances.

The agent can place and cancel orders and nothing else. It cannot withdraw or
send money anywhere, and that is a network rule rather than a promise. The owner
can withdraw at any time, and open orders are cancelled first so nothing is
stranded.

**So the risk is bad trades, not theft.** There are no fees for placing or
cancelling, unfilled orders return whole, and a winning share pays 98 cents on
the dollar after the 2% settlement fee.

Start with an amount the owner would shrug off. Increase it only after watching
it work.

## For the owner

[owner-walkthrough.md](owner-walkthrough.md) is written for a non-technical
person, with clickable links and no jargon. Hand them that rather than this
file.

## Evidence

- [protocol/05-wallet-funding-design.md](../../protocol/05-wallet-funding-design.md)

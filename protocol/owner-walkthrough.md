# Setting up your trading agent

This gives an AI agent its own wallet that it can **trade with but never take
money out of**. Only you can withdraw. You stay in control the whole time.

**Time:** about 10 minutes. **Cost:** whatever you fund it with, plus about
**3 cents** in Ethereum fees.

For a first try, **$5 is plenty.** Don't send more until you've seen it work.

---

## Before you start

You need **USDC on Ethereum** and a tiny bit of **ETH** for the fee.

You do **not** need a crypto wallet. You can sign in with Google, Apple, X, or
just your email address, and a wallet is made for you.

Your agent operator gives you a **Rule ID**, a long string of letters and
numbers. Keep it somewhere you can copy and paste from.

After Step 1 you send them your wallet address, and they send back an **expected
agent address**. You need that before Step 4.

---

## Step 1. Sign in

Go to **[truf.network/account](https://truf.network/account)** and click
**Connect Wallet** at the top right.

A **Sign in** box appears. Pick whichever you like:

- **Google**, **Apple**, or **X**. One click.
- **Email address**. Type it, then enter the code they send you.
- **Connect a Wallet**, if you already have MetaMask or similar.

You'll know it worked when the page shows your balances.

**Now copy your wallet address and send it to your operator.** It's shown on the
dashboard and starts with `0x`. They need it to work out your agent's address,
and they'll send that back to you.

*Signing in is free and doesn't move any money.*

---

## Step 2. Check what the agent is allowed to do

On that same page, find the **Manage Agents** box and click it. Then click
**Connect Agent** and paste in the **Rule ID** you were given.

**The Rule ID must start with `0x`.** The form rejects it otherwise, with
"Enter a 32-byte Rule ID in 0x-prefixed hexadecimal format". If your operator
sent it without the prefix, add `0x` to the front.

Click **Verify Rule**.

**Before you approve, check the list of allowed actions. It should have exactly
these four, and nothing else:**

- place buy order
- place sell order
- place split limit order
- cancel order

**If you see anything mentioning *withdraw*, *bridge*, *transfer*, or *settle*,
stop and ask.** A trading agent never needs those. Those are the only things
that could move your money somewhere you didn't choose.

Also check the **commission** is what you agreed (zero, if you're running this
yourself).

---

## Step 3. Approve it, then check the address

Approve. Your wallet will ask you to sign a message.

**This doesn't move any money** and it's free. It just records the agreement.

When it finishes, the page shows you an **agent wallet address**.

> ### ⚠️ This is the one step worth slowing down for
>
> **Compare that address to the "expected agent address" you were given.**
> Character by character. They must match exactly.
>
> If they don't match, **stop**. Don't send anything. Ask your operator.
>
> Everything else here is routine. This is the part that matters.

---

## Step 4. Fund it

Funding is built into the **Connect Agent** modal. There is no need to visit the
bridge page separately. The modal offers two **Funding source** buttons:

| Source | Use when |
|--------|----------|
| **Fund from TN Account** | you already hold USDC on TRUF.NETWORK. Instant, costs about a cent |
| **Fund via Ethereum Bridge** | your USDC is on Ethereum. Costs gas and takes a few minutes |

Set **Asset** to USDC. It defaults to `$TRUF`, which is not what these markets
settle in.

### Connect with zero, then fund

**Set Initial funding to `0` on the first pass.**

The modal does not show the agent wallet address before you sign, and it states
that connection and funding are separate transactions anyway. Funding here would
mean sending money before seeing where it goes.

So connect with zero, read the address off the Manage Agents list, check it
against the expected address, then use **Add Funds**. Same result, with the
address check in the right place.

## Step 5. That's it

**Allow up to 15 minutes.** It is often much quicker, but how long depends on
how busy Ethereum is, and 15 minutes is the safe upper end.

You don't need to watch.

Your operator is monitoring their own copy of the network and will tell you the
moment it lands, with the exact amount.

---

## What you should know

**Your money, your control.**

- The agent can place and cancel orders. That's all it can do.
- It **cannot** withdraw, send, or move your money anywhere. The network
  enforces that. It is not a promise, it is a rule that cannot be broken.
- **You can take your money out whenever you want.** If some is tied up in open
  orders, those get cancelled first, then you get everything back.
- You can see every order the agent has made, at any time.

**What you're actually risking:** the agent making bad trades. That's it.

There are no fees for placing or cancelling orders, and unfilled orders come
back to you whole. If a bet wins you get 98 cents per dollar instead of a full
dollar, which is the network's 2% fee.

So: start with an amount you'd shrug off entirely. Increase it only after you've
watched it work.

---

## If something looks wrong

**Stop before signing.** Nothing is lost by pausing. A rule you've set up but
never funded is harmless and costs nothing.

The only step where money can actually go wrong is Step 4, and only if you
skipped the address check in Step 3.

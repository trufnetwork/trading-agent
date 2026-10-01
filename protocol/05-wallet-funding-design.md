# Step 5 (design) — Wallet, bridging, and the agent wallet

> **Status: design verified, not yet executed.** The four open VERIFY items were
> cleared against the synced node on 2026-09-18 and are recorded below. No funds
> have moved and no transaction has been signed.

## Verified against mainnet, 2026-09-18

**Executed end to end with real funds on 2026-09-18.** Rule created at block
2615853, joined at 2615883, funded with 5.000000 USDC via the Ethereum bridge.

| Measured | Value |
|----------|-------|
| Credited | **5000000 base units, exactly $5.00.** Nothing skimmed |
| Bridge latency | **2.5 minutes** on this run, at 0.08 gwei. The UI quotes 15 as a deliberate upper bound, which is the right way round: quote the ceiling, beat it. Do not tell users to expect the best case |
| Ethereum gas | ~$0.03 at 0.08 gwei |
| MAA address | `0x1167edf0430a562b06a48e027a4be52c44305e0a`, matched local derivation exactly |

**`fee_configs` is NOT applied to bridge deposits.** This was left explicitly
unresolved rather than assumed, and the deposit settled it: the full 5 USDC
arrived. Reading `fee_percentage = 0.0100` as a live 1% would have been wrong.

**Bridge funding produces no `maa_events` row.** Only `JOIN` appears there. A
deposit credits `kwil_erc20_meta.balances` directly without passing through an
MAA action, so `maa_events` cannot answer "how much was put into this agent".
Use the balance table for funding and `maa_events` for rule lifecycle and agent
actions.

**MAA is active.**

```
kwild consensus params --root <root>   ->  MAA Activation Height: 1732055
```

Non-zero and far below current height (2,615,790+), so `maa_exec` is live.

**The `eth_usdc` bridge.** From `kwil_erc20_meta.reward_instances`:

```
token     0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48   canonical USDC, Ethereum
chain_id  1
decimals  6            <- NOT 18. Amounts are cents x 10^4, not wei
escrow    0x67f087bc88e36721919a4531b83c62c5022ca810
vault     6,743,730,000 base units = $6,743.73 held by the network
```

The vault figure cross-checks: 4,116 outstanding pairs ($4,116) plus roughly
$2,120 of open buy collateral is about $6,236, against $6,743.73 held.

**Deposit arrival is visible in `kwil_erc20_meta.balances`:**

```sql
SELECT b.balance
FROM kwil_erc20_meta.balances b
JOIN kwil_erc20_meta.reward_instances r ON r.id = b.reward_id
WHERE b.address = decode('<wallet hex, no 0x>','hex')
  AND r.erc20_decimals = 6 AND r.chain_id = '1';
```

Poll this to confirm a bridge deposit landed, rather than refreshing a UI.

**Transfer fee is a flat cent**, not a percentage
(`erc20-bridge/002-public-transfer-actions.prod.sql`):

```
eth_usdc_transfer  fee = 10000 base units = 0.01 USDC
eth_truf_transfer  fee = 1 TRUF
```

**Unresolved, do not assume.** `main.fee_configs` carries `deposit` and
`withdraw` rows at `fee_percentage = 0.0100` with a treasury address. No
migration searched applies that column, so whether it means 1% or 0.01%, and
whether it is even live, is **not established**. It does not affect the transfer
fee above, which is a flat literal. Resolve it before any withdrawal.

## Key handling

Three keys, and only one of them lives on this machine.

| Key | Where it lives | What it can do |
|-----|----------------|----------------|
| **Owner** | the user's wallet or social login, in a browser | fund, withdraw, run any allowed action |
| **Agent** | `agent/agent.key` on the operator machine, mode 0600 | the four allow-listed trading actions, nothing else |
| **MAA** | nowhere. It is *derived*, not generated | the wallet both operate |

**The agent key is generated to a file and never read into an agent session.**
`go run . keygen` writes it directly and prints only the derived address. It is
gitignored. Scripts read it from disk; the operator can read it locally; it does
not pass through a transcript, a log, or a model context.

**A plaintext hot key is acceptable here precisely because of the MAA boundary.**
The agent key can place and cancel orders and can never withdraw, bridge or
transfer. Its compromise costs bad trades, not theft. That bounded blast radius
is what makes an always-available trading key a reasonable thing to hold at all,
and it is the whole argument for using an MAA rather than trading from a funded
wallet directly.

Losing the agent key means losing the agent side of an existing rule, so
`keygen` refuses to overwrite.

## Why a Modular Agent Address (MAA)

Do not trade from a wallet whose key an agent holds outright. Use an MAA: a
non-custodial agent wallet where the owner funds and can always withdraw, and
the agent key is limited to an allow-list and **provably cannot move funds out**.

The guarantee is enforced at the token boundary, not by convention: `transfer`,
`bridge`, `issue` and `lock_admin` are blocked for a restricted agent **at any
call depth**, while `lock` / `unlock` stay open. Trading only ever escrows
collateral into the network vault and gets it back on fill/cancel/settlement.

**The one carve-out:** a `transfer` whose recipient is the block leader's
address — the network's write-fee sink. The recipient is consensus-determined
and never a call parameter, so a rogue agent cannot steer tokens to an address
of its choosing.

**That carve-out is unreachable from the trading allow-list.** VERIFIED
2026-09-17 against `032-order-book-actions.sql`: the only fee in the order book
is a 2 TRUF **market creation** fee in `create_market` (paid in TRUF via the
leader transfer). `place_buy_order`, `place_sell_order`,
`place_split_limit_order` and `cancel_order` contain no fee logic whatsoever,
and `create_market` is deliberately not allow-listed.

So for a liquidity agent there are **no protocol fees for trading**, and the
leader carve-out — which matters for the Data Provision Agent example, where
write fees are the point — never fires. The residual risk is bad trading, not
fee drainage.

## Roles

| Role | Key | Powers |
|------|-----|--------|
| **Unrestricted (owner)** | operator's wallet | funds the MAA, runs any allowed action, withdraws at any time via `maa_withdraw` / `maa_bridge_out` |
| **Restricted (agent)** | the agent's key | only the rule's allow-list; can never withdraw or bridge |
| **MAA** | — | the wallet both operate; address is *derived*, not generated |

The MAA address is deterministic: `DeriveMAAAddress(unrestricted, restricted,
ruleID)` (`core/util/maa_address.go`). It can be computed before it is funded.

Note the direction: **the agent creates the rule** (fixing its own allow-list
and commission), then **the owner joins it**. The owner is agreeing to terms the
agent published, so the owner must inspect the rule before joining.

## The canonical trading allow-list

Namespace `main`, exactly four actions:

| Action | Purpose |
|--------|---------|
| `place_buy_order` | open a buy (locks collateral) |
| `place_sell_order` | sell from existing holdings |
| `place_split_limit_order` | mint a YES/NO pair, list one side |
| `cancel_order` | cancel an open order (unlocks collateral) |

Deliberately excluded: every withdrawal/bridge primitive, `create_market`,
`settle_market`. **Never allow-list `maa_join_and_fund`** — it moves funds, and
through `maa_exec` it would strand them in a nested wallet.

Rule terms (`MAACreateRuleInput`): `FeeMode` `"bps"` or `"flat"`, plus the
parallel `Namespaces` / `Actions` / `BodyHashes` arrays. `BodyHashes` pins the
exact action body; leave nil to stay unpinned. For an owner-operated agent set
the commission to zero.

## Activation gate

`maa_exec` is gated by the consensus parameter **`maa_activation_height`**; `0`
means not activated and transactions are rejected as "unknown payload type".
The parameter is invisible while zero, so it cannot be inferred from block data
and is not exposed over the REST API.

The operator reports MAA is live on mainnet and in use today. VERIFY on our own
node before relying on it:

```bash
kwild consensus params --root ~/dev/agentic-truf/tn-node   # => maa_activation_height: <H>
```

Record the actual `H`. A non-zero value that is **below current height** means
active now.

## Bridging USDC in

Live mainnet markets settle in **`eth_usdc`** — real USDC on Ethereum, 6
decimals. Confirmed against the indexer: 100/100 active markets. Minimum order
is typically 1.0 USDC (`min_order_size` 1000000).

**Bridging in is an Ethereum L1 transaction and cannot be done by the agent.**
`sdk-go` exposes `GetWalletBalance`, `Transfer`, `GetHistory` and `withdraw` —
all network-side. The deposit happens on Ethereum; bridge validators then credit
the TN balance. It needs the owner's Ethereum key and ETH for gas, and that key
should never be held by the agent.

### Division of labour

The owner signs the L1 deposit and holds all keys. The agent does everything
else:

1. **Read bridge config from the local node** — contract address, chain id,
   decimals — rather than trusting a doc or UI. VERIFY: locate these in the
   `kwil_erc20_meta` tables once synced.
2. **Compute the exact call and amounts.** USDC is 6 decimals while most TN
   amounts are 18 — a factor of 10^12 is the obvious way to lose money here.
   Convert once, show the human-readable figure alongside base units, and have
   the owner confirm both.
3. **Detect arrival from our own Postgres.** Poll the bridge balance table
   directly and report the moment credit lands — our node confirming, not a
   third-party explorer.
4. **Fund the agent wallet atomically** with `maa_join_and_fund` (SDK:
   `joinAndFundAgentAddress`). One transaction for join + fund; either leg
   failing rolls back both. The older two-step flow could leave a
   joined-but-unfunded wallet.

Top-ups after activation use the ordinary per-bridge transfer actions and pay
the flat fee; `maa_join_and_fund` is activation-only.

## Where each step happens (decided 2026-09-17)

All key handling and value movement stays on **official audited rails**; all
verification, monitoring and trading runs against **our own node**.

| Step | Signed by | Where |
|------|-----------|-------|
| Create rule → `ruleID` | agent key | agent's terminal, `sdk-go` |
| Link rule + fund the MAA | owner | truf.network/account → **Manage Agents** |
| Bridge USDC → MAA address | owner | truf.network/account/bridge |
| Trade (allow-list only) | agent key | agent's terminal, `sdk-go` |

The rule is created by the **restricted (agent) key**, so the owner never needs
the *Create Rule* UI. The owner's only browser steps are the two that involve
their funds.

### Why the official UI rather than a local signing page

MetaMask *can* sign TN transactions — Kwil's `EthPersonalSigner` uses the exact
EIP-191 `\x19Ethereum Signed Message:\n` prefix that `personal_sign` produces,
and `sdk-js` ships `BrowserTNClient` plus `maaActions.joinAgentAddress`. So a
local page is technically possible.

It is still the wrong choice: **a local page realistically supports injected
MetaMask only**, silently excluding hardware wallets and every mobile wallet
arriving over WalletConnect. The official pages support them all. Wallet
coverage, not blast radius, is the deciding argument.

The official UI covers the whole owner-side lifecycle:

- **Create Rule** — "Define a ruleset for agent wallets"
- **Manage Agents** — "Link a verified agent rule, then fund its dedicated
  Modular Agent Address"
- **Bridge** — Ethereum → TRUF.NETWORK, **USDC** selectable, and a **changeable
  Recipient Address**, so USDC can be bridged straight to the MAA in one
  signature.

### What a local page SHOULD do: verify, never sign

A local companion page has no signing surface at all. It:

- computes the expected MAA address so the owner can compare it
  character-by-character against what the UI shows;
- pre-computes amounts in both human and base units (USDC is 6 decimals);
- watches **our own Postgres** and reports the instant funds land, which rule
  was registered, and what the agent is doing — the one thing no official UI
  can do, because it cannot read our node.

## Order of operations

```
1. Owner wallet holds USDC on Ethereum + ETH for gas
2. VERIFY maa_activation_height > 0 and <= current height
3. Agent creates the rule (4 actions, zero commission)  -> ruleID   [terminal]
4. Owner INSPECTS the rule: allow-list is exactly the 4
   trading actions, commission is zero                             [browser]
5. Owner links the rule via Manage Agents -> MAA registered         [browser]
6. Verify the MAA address matches the locally derived one
7. Owner bridges USDC, Recipient = MAA address                      [browser]
8. Detect arrival by polling local Postgres
9. Agent trades via ExecuteAgentAction, allow-list only            [terminal]
```

Step 4 is not a formality. The owner is accepting terms the agent wrote; the
allow-list and commission must be read before linking, not after. Step 6 guards
against funding an address that came from a string the agent printed.

Register the MAA (step 5) **before** bridging to it (step 7). The address is
derivable in advance, but a derived address is not yet a registered wallet, and
the bridge UI warns that tokens sent to an incorrect address are unrecoverable.

## Open items to verify on a synced node

- [ ] `maa_activation_height` actual value
- [ ] `kwil_erc20_meta` table names and the `eth_usdc` bridge config
- [ ] Which table holds creditable balances, for arrival detection
- [ ] Flat fee charged on ordinary transfers

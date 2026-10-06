#!/usr/bin/env python3
"""
Portfolio for an agent wallet: cash, positions, cost basis, mark, and risk.

    scripts/portfolio.py 0x<your agent wallet>

Everything here is read from the local node. Nothing is taken on trust from a UI.

MARKING. A share is marked at the price you could SELL it for right now, which
is the YES bid for a YES holding and the NO bid for a NO holding. Marking at the
mid or the ask overstates the book, because you cannot sell at either.

COST BASIS comes from main.ob_net_impacts, the protocol's own per-transaction
ledger. `collateral_change` is a MAGNITUDE with direction in `is_negative`, so
spend and receipt must be separated rather than summed.

SETTLEMENT VALUE. Each share pays $1.00 if its band wins, minus the 2% fee, so
$0.98. Losing shares pay nothing. Open buy orders refund in full.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).parent.parent
AGENT = ROOT / "agent" / "agent"

AGENT_MISSING = (
    f"the SDK helper binary is not built: {AGENT}\n"
    "  Strike bands live in an ABI blob that only the SDK can decode.\n"
    "  Build it once:  cd agent && go build -o agent .   (needs Go 1.21+)"
)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tnconn import PSQL  # noqa: E402  ports resolve via .tn-env, env, then defaults
from describe import describe  # noqa: E402


def q(sql):
    r = subprocess.run(PSQL + ["-c", f"SELECT coalesce(json_agg(t),'[]'::json) FROM ({sql}) t;"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr.strip()}")
    return json.loads(r.stdout.strip() or "[]")


def band(components_hex):
    if not AGENT.exists():
        return None
    r = subprocess.run([str(AGENT), "decode", components_hex], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    d = json.loads(r.stdout)
    th = [float(x) for x in d["thresholds"]]
    if d["type"] == "below":
        return f"below {th[0]:g}"
    if d["type"] == "above":
        return f"above {th[0]:g}"
    return f"{th[0]:g}-{th[1]:g}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wallet", help="agent wallet address (0x...)")
    a = ap.parse_args()
    w = a.wallet.lower().removeprefix("0x")

    cash = q(f"""SELECT round(b.balance/1e6, 6) AS usdc
                 FROM kwil_erc20_meta.balances b
                 JOIN kwil_erc20_meta.reward_instances r ON r.id = b.reward_id
                 WHERE b.address = decode('{w}','hex') AND r.erc20_decimals = 6""")
    free = float(cash[0]["usdc"]) if cash else 0.0

    pid = q(f"""SELECT id FROM main.ob_participants
                WHERE wallet_address = decode('{w}','hex')""")
    if not pid:
        print(f"wallet 0x{w}\n  free USDC {free:.6f}\n  no trading history")
        return
    pid = pid[0]["id"]

    pos = q(f"""SELECT p.query_id, p.outcome, p.price, p.amount,
                       q.settle_time, q.settled, q.winning_outcome,
                       encode(q.query_components,'hex') AS comp,
                       (SELECT MAX(ABS(x.price)) FROM main.ob_positions x
                         WHERE x.query_id=p.query_id AND x.outcome=p.outcome
                           AND x.price<0 AND x.participant_id<>{pid}) AS best_bid
                FROM main.ob_positions p
                JOIN main.ob_queries q ON q.id = p.query_id
                WHERE p.participant_id = {pid}
                ORDER BY q.settle_time, p.query_id""")

    led = q(f"""SELECT
                  round(sum(collateral_change) FILTER (WHERE is_negative)/1e6, 6)     AS spent,
                  round(sum(collateral_change) FILTER (WHERE NOT is_negative)/1e6, 6) AS received
                FROM main.ob_net_impacts WHERE participant_id = {pid}""")
    spent = float(led[0]["spent"] or 0)
    received = float(led[0]["received"] or 0)

    print(f"AGENT WALLET  0x{w}")
    print(f"  free USDC        {free:>10.2f}")

    held_val = locked = 0.0
    if pos:
        print(f"\n{'book':>6} {'band':<16} {'side':<4} {'kind':<9} {'qty':>5} "
              f"{'mark':>6} {'value':>8} {'settles':>17}")
        print("-" * 78)
    for p in pos:
        side = "YES" if p["outcome"] else "NO"
        kind = "holding" if p["price"] == 0 else ("open buy" if p["price"] < 0 else "open sell")
        b = band(p["comp"]) or "?"
        when = datetime.fromtimestamp(p["settle_time"], timezone.utc).strftime("%m-%d %H:%M UTC")
        if p["price"] < 0:
            # collateral locked in a resting bid, refunded on cancel or fill
            v = p["amount"] * abs(p["price"]) / 100.0
            locked += v
            mark = f"{abs(p['price'])}c"
        else:
            bid = p["best_bid"]
            v = p["amount"] * (bid or 0) / 100.0
            held_val += v
            mark = f"{bid}c" if bid else "no bid"
        print(f"{p['query_id']:>6} {b:<16} {side:<4} {kind:<9} {p['amount']:>5} "
              f"{mark:>6} {v:>8.2f} {when:>17}")

    equity = free + held_val + locked
    print(f"\n  positions (at bid) {held_val:>8.2f}")
    print(f"  locked in bids     {locked:>8.2f}")
    print(f"  free USDC          {free:>8.2f}")
    print(f"  EQUITY             {equity:>8.2f}")

    net = received - spent
    print(f"\nLEDGER (main.ob_net_impacts)")
    print(f"  spent    {spent:>8.2f}")
    print(f"  received {received:>8.2f}")
    print(f"  net      {net:>+8.2f}   (negative while capital is deployed)")

    # settlement outcomes for open positions
    if pos:
        print(f"\nIF EACH POSITION SETTLES IN THE MONEY")
        for p in pos:
            if p["price"] != 0 or p["settled"]:
                continue
            win = p["amount"] * 0.98          # 2% settlement fee on winning shares
            cost = p["amount"] * (p["best_bid"] or 0) / 100.0
            print(f"  book {p['query_id']}: {p['amount']} shares -> ${win:.2f} if it wins, "
                  f"$0.00 if not (marked ${cost:.2f})")
            print(f"    {describe(p['query_id'])[0]}")

    print("\nMark is the best OTHER-PARTY bid, which is what you could sell into now.")


if __name__ == "__main__":
    main()

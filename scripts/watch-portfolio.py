#!/usr/bin/env python3
"""Watch the agent wallet without spending tokens.

    setsid nohup scripts/watch-portfolio.py <maa> > /dev/null 2>&1 &
    tail -f watch-portfolio.log

Polls the local node and appends one line per event to watch-portfolio.log in
the repo root. It reads only, never trades, and exits by itself once every
position has settled, so it is a temporary service for as long as there is
something to watch. Leave it running across sessions: an agent can read the
log when the person asks, or tail it, without polling the node itself.

Events
  FILLED    a resting order became shares
  SETTLED   a ladder you hold settled: which band won, and your result
  WARNING   that ladder settled with two winners or none
  PAID      the wallet's free USDC changed
  DONE      nothing left to watch

Ask it for status at any time, from any session:

    scripts/watch-portfolio.py <maa> --status

That prints whether the watcher is running, what it holds right now, and the
last events it logged. --stop ends a running watcher.

Options
  --interval SECONDS   poll gap, default 60
  --notify             also send a desktop notification per event
  --keep               do not exit when everything has settled
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from tnconn import PSQL  # noqa: E402
from describe import describe  # noqa: E402

LOG = ROOT / "watch-portfolio.log"
PID = ROOT / ".tn-watcher.pid"


def running():
    """pid of a live watcher, or None."""
    try:
        pid = int(PID.read_text().split()[0])
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def status(w, pid):
    p = running()
    if p:
        started = datetime.fromtimestamp(PID.stat().st_mtime, timezone.utc)
        print(f"WATCHER   running (pid {p}) since {started:%Y-%m-%d %H:%M UTC}")
    else:
        print("WATCHER   not running")
    free, pos = snapshot(w, pid)
    print(f"FREE      {free:.2f} USDC")
    if not pos:
        print("POSITIONS none")
    for x in sorted(pos, key=lambda x: (x["settle_time"], x["query_id"])):
        side = "YES" if x["outcome"] else "NO"
        kind = "holding" if x["price"] == 0 else (f"bid at {-x['price']}c" if x["price"] < 0 else f"ask at {x['price']}c")
        print(f"POSITION  {x['amount']} {side} {kind}, {describe(x['query_id'])[0]}")
    if LOG.exists():
        lines = LOG.read_text().splitlines()
        print(f"LOG       {LOG} ({len(lines)} lines), last events:")
        for line in lines[-8:]:
            print("  " + line)
    else:
        print("LOG       nothing logged yet")


def q(sql):
    r = subprocess.run(PSQL + ["-c", f"SELECT coalesce(json_agg(t),'[]'::json) FROM ({sql}) t;"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return json.loads(r.stdout.strip() or "[]")


def snapshot(w, pid):
    free = q(f"""SELECT round(b.balance/1e6, 6) AS usdc
                 FROM kwil_erc20_meta.balances b
                 JOIN kwil_erc20_meta.reward_instances r ON r.id = b.reward_id
                 WHERE b.address = decode('{w}','hex') AND r.erc20_decimals = 6""")
    free = float(free[0]["usdc"]) if free else 0.0
    pos = q(f"""SELECT p.query_id, p.outcome, p.price, p.amount, q.settled, q.winning_outcome,
                       q.settle_time,
                       lower('0x'||substring(encode(q.query_components,'hex') from 25 for 40)) AS provider,
                       convert_from(decode(regexp_replace(
                           substring(encode(q.query_components,'hex') from 65 for 64),
                           '(00)+$',''),'hex'),'UTF8') AS stream
                FROM main.ob_positions p JOIN main.ob_queries q ON q.id = p.query_id
                WHERE p.participant_id = {pid}""")
    return free, pos


def ladder(provider, stream, settle_time):
    return q(f"""SELECT id, settled, winning_outcome FROM main.ob_queries
                 WHERE settle_time = {settle_time}
                   AND lower('0x'||substring(encode(query_components,'hex') from 25 for 40)) = '{provider}'
                   AND convert_from(decode(regexp_replace(
                       substring(encode(query_components,'hex') from 65 for 64),
                       '(00)+$',''),'hex'),'UTF8') = '{stream}'
                 ORDER BY id""")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wallet")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--notify", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--status", action="store_true", help="report and exit")
    ap.add_argument("--stop", action="store_true", help="end a running watcher")
    a = ap.parse_args()
    w = a.wallet.lower().removeprefix("0x")
    notify = a.notify and shutil.which("notify-send")

    if a.stop:
        p = running()
        if p:
            os.kill(p, 15)
            print(f"stopped watcher pid {p}")
        else:
            print("no watcher running")
        return

    def log(kind, msg):
        line = f"{datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S} UTC  {kind:<8} {msg}"
        with LOG.open("a") as f:
            f.write(line + "\n")
        print(line, flush=True)
        if notify:
            subprocess.run(["notify-send", f"TRUF {kind}", msg[:200]], check=False)

    pid = q(f"SELECT id FROM main.ob_participants WHERE wallet_address = decode('{w}','hex')")
    if not pid:
        sys.exit(f"wallet 0x{w} has no trading history on this node")
    pid = pid[0]["id"]

    if a.status:
        status(w, pid)
        return
    if running():
        sys.exit(f"a watcher is already running (pid {running()}). Use --status or --stop.")
    PID.write_text(f"{os.getpid()}\n")

    free, pos = snapshot(w, pid)
    log("START", f"watching 0x{w}: {len(pos)} positions, {free:.2f} USDC free, every {a.interval}s")
    reported = set()

    while True:
        time.sleep(a.interval)
        try:
            free2, pos2 = snapshot(w, pid)
        except RuntimeError as e:
            log("ERROR", f"node query failed, will retry: {e}")
            continue

        # The node deletes a position when its book settles, so settlement shows
        # up as shares vanishing from a book that is now marked settled. Resting
        # orders vanish or shrink when they fill, or when they are cancelled.
        now = {(p["query_id"], p["outcome"], p["price"]): p for p in pos2}
        for k, p in {(p["query_id"], p["outcome"], p["price"]): p for p in pos}.items():
            left = now[k]["amount"] if k in now else 0
            if left >= p["amount"]:
                continue
            gone = p["amount"] - left
            book = q(f"SELECT settled, winning_outcome FROM main.ob_queries WHERE id = {p['query_id']}")[0]
            side = "YES" if p["outcome"] else "NO"
            if p["price"] != 0 and not book["settled"]:
                kind = "buy" if p["price"] < 0 else "sell"
                log("FILLED", f"{gone} {side} {kind} at {abs(p['price'])}c filled or was cancelled, "
                              f"{describe(p['query_id'])[0]}")
                continue
            if not book["settled"]:
                continue
            key = (p["provider"], p["stream"], p["settle_time"])
            if key not in reported:
                reported.add(key)
                books = ladder(*key)
                winners = [b["id"] for b in books if b["winning_outcome"]]
                if len(winners) != 1:
                    log("WARNING", f"ladder settling {datetime.fromtimestamp(p['settle_time'], timezone.utc):%Y-%m-%d %H:%M UTC} "
                                   f"has {len(winners)} winning books ({winners}). Exactly one is correct.")
            if p["price"] == 0:
                won = book["winning_outcome"] == p["outcome"]
                pay = gone * 0.98 if won else 0.0
                log("SETTLED", f"{'WON' if won else 'LOST'} {gone} {side} shares, pays ${pay:.2f}. "
                               f"{describe(p['query_id'])[0]}")
            else:
                log("SETTLED", f"resting {side} order at {abs(p['price'])}c returned unfilled. "
                               f"{describe(p['query_id'])[0]}")

        if abs(free2 - free) >= 0.000001:
            log("PAID", f"free USDC {free:.2f} -> {free2:.2f} ({free2-free:+.2f})")
        free, pos = free2, pos2

        if not a.keep and not pos:
            log("DONE", f"every position has settled. {free:.2f} USDC free.")
            PID.unlink(missing_ok=True)
            return


if __name__ == "__main__":
    main()

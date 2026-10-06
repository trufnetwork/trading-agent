#!/usr/bin/env python3
"""
Live prediction market report, read straight from the local TN node's Postgres.

No SDK, no network. Requires only psql on PATH.

    scripts/markets.py            # live markets with top of book
    scripts/markets.py --all      # include settled
    scripts/markets.py --id 1216  # depth ladder for one market

Market identity is not stored in readable form on chain. It lives in
ob_queries.query_components, which is ABI-encoded:

    (address data_provider, bytes32 stream_id, string action_id, bytes args)

The outer tuple is decoded here by hand (it is a fixed 4-word head, so this
needs no eth-abi dependency). `args` holds thresholds in Kwil's own encoded
value format; decoding that is left to the SDK. stream_id is plain ASCII of
the 'st...' stream id -- verified against live indexer data 2026-09-17.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tnconn import PSQL  # noqa: E402  ports resolve via .tn-env, env, then defaults


def q(sql):
    """Run SQL, return rows as list of dicts (via JSON aggregation)."""
    wrapped = f"SELECT coalesce(json_agg(t), '[]'::json) FROM ({sql}) t;"
    r = subprocess.run(PSQL + ["-c", wrapped], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr.strip()}")
    return json.loads(r.stdout.strip() or "[]")


def decode_components(hexstr):
    """Decode ABI (address, bytes32, string, bytes) -> dict. Head is 4 words."""
    try:
        b = bytes.fromhex(hexstr)
        if len(b) < 128:
            return {}
        provider = "0x" + b[12:32].hex()
        stream_raw = b[32:64]
        # stream_id is ASCII, right-padded with NULs
        stream_id = stream_raw.rstrip(b"\x00").decode("ascii", "replace")
        action_off = int.from_bytes(b[64:96], "big")
        action_len = int.from_bytes(b[action_off:action_off + 32], "big")
        action = b[action_off + 32:action_off + 32 + action_len].decode("ascii", "replace")
        return {"data_provider": provider, "stream_id": stream_id, "action_id": action}
    except Exception as e:  # malformed blob should not kill the report
        return {"decode_error": str(e)}


def fmt_ts(ts):
    if not ts:
        return "-"
    return datetime.fromtimestamp(int(ts), timezone.utc).strftime("%Y-%m-%d %H:%M")


def report(show_all):
    where = "" if show_all else "WHERE NOT q.settled"
    markets = q(f"""
        SELECT q.id, encode(q.hash,'hex') AS hash,
               encode(q.query_components,'hex') AS components,
               q.settle_time, q.settled, q.winning_outcome, q.bridge,
               q.min_order_size, '0x'||encode(q.creator,'hex') AS creator
        FROM main.ob_queries q {where}
        ORDER BY q.settle_time
    """)
    if not markets:
        print("No markets found. Is the node synced? (scripts/status.sh)")
        return

    book = {}
    for r in q("""
        SELECT p.query_id, p.outcome,
               MAX(ABS(p.price)) FILTER (WHERE p.price < 0) AS bid,
               MIN(p.price)      FILTER (WHERE p.price > 0) AS ask,
               SUM(p.amount)     FILTER (WHERE p.price < 0) AS bid_sz,
               SUM(p.amount)     FILTER (WHERE p.price > 0) AS ask_sz
        FROM main.ob_positions p GROUP BY p.query_id, p.outcome
    """):
        book[(r["query_id"], r["outcome"])] = r

    # stream_id -> human name.
    # Streams carry NO on-chain name. main.metadata holds only operational keys
    # (readonly_key, read_visibility, type, stream_owner) -- verified across all
    # 259,575 streams, 2026-09-17. Names must come from a maintained mapping.
    names = {}
    try:
        import json as _j, pathlib as _p
        f = _p.Path(__file__).parent.parent / "streams.json"
        for k, v in _j.loads(f.read_text()).items():
            if k.startswith("_"):
                continue
            # Regenerate with scripts/refresh-streams.py
            names[k] = f"{v['ticker']} {v['name']}" if v.get("ticker") else v["name"]
    except Exception:
        pass

    now = datetime.now(timezone.utc).timestamp()
    print(f"{len(markets)} markets\n")
    hdr = f"{'id':>6} {'type':<22} {'stream':<40} {'YES bid/ask':>12} {'NO bid/ask':>12} {'settles (UTC)':>17} {'hrs':>7}"
    print(hdr)
    print("-" * len(hdr))

    for m in markets:
        d = decode_components(m["components"] or "")
        sid = d.get("stream_id", "?")
        label = names.get(sid, sid)
        yes = book.get((m["id"], True), {})
        no = book.get((m["id"], False), {})

        def tob(e):
            b, a = e.get("bid"), e.get("ask")
            return f"{b if b is not None else '-'}/{a if a is not None else '-'}"

        hrs = (m["settle_time"] - now) / 3600
        print(f"{m['id']:>6} {d.get('action_id','?'):<22} {label[:40]:<40} "
              f"{tob(yes):>12} {tob(no):>12} {fmt_ts(m['settle_time']):>17} {hrs:>7.1f}")


def depth(market_id):
    rows = q(f"""
        SELECT CASE WHEN outcome THEN 'YES' ELSE 'NO' END AS side,
               CASE WHEN price < 0 THEN 'BID' WHEN price > 0 THEN 'ASK' ELSE 'HOLD' END AS kind,
               ABS(price) AS px, SUM(amount) AS shares, COUNT(*) AS orders
        FROM main.ob_positions WHERE query_id = {int(market_id)}
        GROUP BY 1,2,3 ORDER BY 1, 2, 3 DESC
    """)
    if not rows:
        print(f"No positions for market {market_id}")
        return
    print(f"{'side':<5} {'kind':<5} {'price':>6} {'shares':>14} {'orders':>7}")
    for r in rows:
        print(f"{r['side']:<5} {r['kind']:<5} {r['px']:>6} {r['shares']:>14} {r['orders']:>7}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help="include settled markets")
    ap.add_argument("--id", type=int, help="depth ladder for one market")
    a = ap.parse_args()
    depth(a.id) if a.id else report(a.all)

#!/usr/bin/env python3
"""
Refresh streams.json: stream_id -> name and metadata, from trufscan.

Streams carry NO human-readable name on chain. main.metadata holds only
operational keys (readonly_key, read_visibility, type, stream_owner), verified
across all 259,575 streams. Names must come from off-chain.

trufscan has no public/documented API, but its SvelteKit frontend calls an
internal endpoint that takes a batch of stream ids:

    POST https://trufscan.io/api/streamlist
    {"streamIds": ["st...", ...], "isV2": false}

It returns display_name, ticker, description, unit, tick_rate, categories and
more. This script reads the stream ids that actually appear in our local
ob_queries, asks for exactly those, and writes streams.json.

    scripts/refresh-streams.py           # streams in live markets
    scripts/refresh-streams.py --all     # streams in all markets, settled too

Being an internal endpoint, it may change without notice. If it breaks, the
per-stream page at https://trufscan.io/<data_provider>/<stream_id> carries the
same information in a standard layout and can be scraped instead.
"""

import argparse
import json
import pathlib
import sys
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from markets import q, decode_components  # noqa: E402

ENDPOINT = "https://trufscan.io/api/streamlist"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")
OUT = pathlib.Path(__file__).parent.parent / "streams.json"


def stream_ids(include_settled):
    where = "" if include_settled else "WHERE NOT settled"
    ids = set()
    for r in q(f"SELECT encode(query_components,'hex') AS c FROM main.ob_queries {where}"):
        d = decode_components(r["c"] or "")
        if d.get("stream_id"):
            ids.add(d["stream_id"])
    return sorted(ids)


def fetch(ids):
    """Ask trufscan for these ids. Batched, since the endpoint takes a list."""
    out = []
    for i in range(0, len(ids), 50):
        chunk = ids[i:i + 50]
        body = json.dumps({"streamIds": chunk, "isV2": False}).encode()
        req = urllib.request.Request(
            ENDPOINT, data=body,
            headers={"Content-Type": "application/json", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=45) as r:
            out.extend(json.loads(r.read()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true",
                    help="include streams from settled markets")
    a = ap.parse_args()

    ids = stream_ids(a.all)
    print(f"{len(ids)} distinct streams in {'all' if a.all else 'live'} markets")

    meta = fetch(ids)
    print(f"{len(meta)} returned by trufscan")

    doc = {
        "_comment": ("stream_id -> metadata from trufscan's internal "
                     "/api/streamlist. Streams have NO on-chain name. "
                     "Regenerate with scripts/refresh-streams.py."),
        "_source": ENDPOINT,
    }
    for s in sorted(meta, key=lambda x: x.get("display_name") or ""):
        sid = s["stream_id"]
        ticker = s.get("ticker")
        doc[sid] = {
            "name": s.get("display_name") or s.get("stream_name") or sid,
            "ticker": None if ticker in (None, "NO_TICKER") else ticker,
            "unit": s.get("unit"),
            "tick_rate": s.get("tick_rate"),
            "data_provider": s.get("data_provider"),
            "type": s.get("type"),
        }

    OUT.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {OUT}")

    missing = set(ids) - {s["stream_id"] for s in meta}
    if missing:
        print(f"WARNING: no metadata for {len(missing)}: {sorted(missing)}")

    # tick_rate is free text and inconsistent ("Daily", "daily", "unknown",
    # "$"). Treat it as a hint. Measure real cadence from main.primitive_events.
    rates = {}
    for v in doc.values():
        if isinstance(v, dict):
            rates[v.get("tick_rate")] = rates.get(v.get("tick_rate"), 0) + 1
    print("tick_rate values seen (unreliable, measure instead):", rates)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Refresh streams.json: stream_id -> name and metadata, from trufscan.

Streams carry NO human-readable name on chain. main.metadata holds only
operational keys (readonly_key, read_visibility, type, stream_owner), verified
across all 259,575 streams. Names must come from off chain.

Source of truth is the public stream page, one plain GET per stream:

    https://trufscan.io/<data_provider>/<stream_id>

SvelteKit embeds the record in the page's hydration payload, so the metadata is
in the HTML that any client receives. No API key, no undocumented endpoint, and
nothing that can be changed out from under us without the page itself changing.

trufscan does expose an internal batch endpoint that the frontend calls. It is
faster, but it is undocumented and can move without notice, so this does not
use it.

Pairs are read from the markets in the local node, so it asks about exactly the
streams you can trade and nothing else.
"""

import argparse
import json
import pathlib
import sys
import re
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from markets import q, decode_components  # noqa: E402

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")
OUT = pathlib.Path(__file__).parent.parent / "streams.json"


def stream_pairs(include_settled):
    """The (data_provider, stream_id) pairs in this node's markets.

    The key is composite. Two providers can publish the same stream_id, so a
    page URL needs both halves.
    """
    where = "" if include_settled else "WHERE NOT settled"
    pairs = set()
    for r in q(f"SELECT encode(query_components,'hex') AS c FROM main.ob_queries {where}"):
        d = decode_components(r["c"] or "")
        if d.get("stream_id") and d.get("data_provider"):
            pairs.add((d["data_provider"].lower(), d["stream_id"]))
    return sorted(pairs, key=lambda x: x[1])


def fetch_one(provider, sid):
    """Read one stream's public page and pull its record out of the payload."""
    url = f"https://trufscan.io/{provider}/{sid}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=45) as r:
        html = r.read().decode("utf-8", "replace")
    m = re.search(r'stream_details:\[\{(.*?)\}\]', html, re.S)
    if not m:
        return None
    blob = m.group(1)
    def field(name):
        f = re.search(name + r':"(.*?)"', blob)
        return f.group(1) if f else None
    if not field("stream_id"):
        return None
    return {"stream_id": field("stream_id"),
            "data_provider": field("data_provider") or provider,
            "ticker": field("ticker"),
            "display_name": field("display_name"),
            "type": field("type"),
            "unit": field("unit"),
            "tick_rate": field("tick_rate")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true",
                    help="include streams from settled markets")
    a = ap.parse_args()

    pairs = stream_pairs(a.all)
    print(f"{len(pairs)} distinct streams in {'all' if a.all else 'live'} markets")

    meta = []
    for i, (pv, sid) in enumerate(pairs, 1):
        try:
            r = fetch_one(pv, sid)
        except Exception as e:
            print(f"  [{i}/{len(pairs)}] {sid} failed: {e}", file=sys.stderr)
            continue
        if r:
            meta.append(r)
        print(f"  [{i}/{len(pairs)}] {sid} {'ok' if r else 'no record on page'}")
    print(f"{len(meta)} of {len(pairs)} resolved")

    doc = {
        "_comment": ("stream_id -> metadata from trufscan's internal "
                     "public stream pages. Streams have NO on-chain name. "
                     "Regenerate with scripts/refresh-streams.py."),
        "_source": "https://trufscan.io/<data_provider>/<stream_id>",
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

    missing = {sid for _, sid in pairs} - {s["stream_id"] for s in meta}
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

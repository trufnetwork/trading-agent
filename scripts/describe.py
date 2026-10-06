#!/usr/bin/env python3
"""Describe an order book in words a person can read.

    scripts/describe.py <order-book> [<order-book> ...]

An order book number means nothing to the person. This prints what the market
is: the stream's display name, the question (value in range 12.37 to 12.51,
price above 3.763), when it settles, and a link to the book on trufscan.

The description comes from trufscan's page data, which is the same JSON the
site renders from. The provider and stream for the book come from the local
node, since trufscan's order book route needs all three. Falls back to the
stream id when trufscan is unreachable, so the caller always gets a line.
"""
import json
import pathlib
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tnconn import PSQL  # noqa: E402

TRUFSCAN = "https://trufscan.io"


def _q(sql):
    wrapped = f"SELECT coalesce(json_agg(t),'[]'::json) FROM ({sql}) t;"
    r = subprocess.run(PSQL + ["-c", wrapped], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr.strip()}")
    return json.loads(r.stdout.strip() or "[]")


def _devalue(node):
    """SvelteKit serialises page data as a flat list of values that reference
    each other by index. Rebuild the root object."""
    data = node["data"]

    def R(i, depth=0):
        v = data[i]
        if depth > 8:
            return None
        if isinstance(v, dict):
            return {k: R(j, depth + 1) for k, j in v.items()}
        if isinstance(v, list):
            return [R(j, depth + 1) for j in v]
        return v
    return R(0)


def _num(s):
    return f"{float(s):g}"


def fetch(provider, stream, book):
    url = f"{TRUFSCAN}/{provider}/{stream}/order-books/{book}"
    req = urllib.request.Request(url + "/__data.json", headers={"User-Agent": "trading-agent"})
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r)
    for n in d.get("nodes") or []:
        if n and n.get("type") == "error":
            raise LookupError(n["error"].get("message", "trufscan error"))
        if n and n.get("type") == "data":
            r = _devalue(n)
            if isinstance(r, dict) and "market" in r:
                r["url"] = url
                return r
    raise LookupError("no market in page data")


def describe(book):
    """Return (one-line description, details dict). Never raises on a network
    failure, so a caller can always print something."""
    row = _q(f"""SELECT id, settle_time,
                 lower('0x'||substring(encode(query_components,'hex') from 25 for 40)) AS provider,
                 convert_from(decode(regexp_replace(
                     substring(encode(query_components,'hex') from 65 for 64),
                     '(00)+$',''),'hex'),'UTF8') AS stream
               FROM main.ob_queries WHERE id = {int(book)}""")
    if not row:
        return f"order book {book}: not found on this node", {}
    row = row[0]
    settle = datetime.fromtimestamp(int(row["settle_time"]), timezone.utc)
    when = f"settles {settle:%Y-%m-%d %H:%M UTC}"
    url = f"{TRUFSCAN}/{row['provider']}/{row['stream']}/order-books/{book}"
    try:
        r = fetch(row["provider"], row["stream"], book)
    except Exception as e:  # noqa: BLE001  offline or settled, still describe it
        return (f"order book {book}: stream {row['stream']}, {when} "
                f"(no description from trufscan: {e}) {url}"), dict(url=url, settle=settle)
    m = r["market"]
    name = (r.get("stream") or {}).get("displayName") or row["stream"]
    th = {t["label"].lower(): _num(t["value"]) for t in m.get("thresholds", [])}
    kind = m.get("marketType")
    if kind == "between":
        ask = f"value between {th.get('minimum')} and {th.get('maximum')}"
    elif kind == "above":
        ask = f"value above {th.get('threshold')}"
    elif kind == "below":
        ask = f"value below {th.get('threshold')}"
    else:
        ask = m.get("marketTypeLabel", "?").lower() + " " + " ".join(th.values())
    line = f"order book {book}: {name}, {ask}, {when}. {url}"
    return line, dict(name=name, ask=ask, settle=settle, url=url,
                      related=[x["queryId"] for x in r.get("relatedMarkets", [])],
                      open_interest=r.get("openInterest"))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for b in sys.argv[1:]:
        print(describe(b)[0])

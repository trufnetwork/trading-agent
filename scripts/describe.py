#!/usr/bin/env python3
"""Describe an order book in words a person can read.

    scripts/describe.py <order-book> [<order-book> ...]

An order book number means nothing to the person. This prints what the market
is: the stream's name, the question (value between 12.37 and 12.51, value
above 3.763), when it settles or how it settled, and a link to the book on
trufscan.

Two sources, each for what it holds. The local node has the question, the
settle time, the result, and the value that was on chain at settle time. It
does not hold the stream's name, because names are not on chain. Trufscan's
stream page has the name, and unlike its order book page it answers for a
settled book too. The name is read from streams.json when that cache exists,
otherwise from trufscan, and the line is still printed when neither answers.
"""
import json
import pathlib
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from tnconn import PSQL  # noqa: E402

TRUFSCAN = "https://trufscan.io"
AGENT = ROOT / "agent" / "agent"
_names = {}


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
            return [R(j, depth + 1) if isinstance(j, int) else j for j in v]
        return v
    return R(0)


def _page(path):
    req = urllib.request.Request(f"{TRUFSCAN}{path}/__data.json",
                                 headers={"User-Agent": "trading-agent"})
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r)
    for n in d.get("nodes") or []:
        if n and n.get("type") == "data":
            r = _devalue(n)
            if isinstance(r, dict) and len(r) > 1:
                return r
    return {}


def stream_name(provider, stream):
    """Display name and ticker, or (None, None) when nothing answers."""
    if not _names:
        try:
            for k, v in json.loads((ROOT / "streams.json").read_text()).items():
                if not k.startswith("_"):
                    _names[k] = (v.get("display_name") or v.get("name"), v.get("ticker"))
        except Exception:  # noqa: BLE001  no cache is the normal case
            pass
    if stream in _names:
        return _names[stream]
    try:
        d = _page(f"/{provider}/{stream}").get("stream_details") or [{}]
        d = d[0] if isinstance(d, list) else d
        _names[stream] = (d.get("display_name"), d.get("ticker"))
    except Exception:  # noqa: BLE001  offline: the id will have to do
        _names[stream] = (None, None)
    return _names[stream]


def _num(x):
    return f"{float(x):g}"


def question(components_hex):
    """The band this book pays on, decoded from the query blob by the helper."""
    if not AGENT.exists():
        return None
    r = subprocess.run([str(AGENT), "decode", components_hex], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    d = json.loads(r.stdout)
    th = [_num(x) for x in d["thresholds"]]
    if d["type"] == "between":
        return f"value between {th[0]} and {th[1]}"
    if d["type"] == "above":
        return f"value above {th[0]}"
    if d["type"] == "below":
        return f"value below {th[0]}"
    return f"{d['type']} {' '.join(th)}"


def describe(book):
    """Return (one-line description, details dict). Never raises on a network
    failure, so a caller can always print something."""
    row = _q(f"""SELECT q.id, q.settle_time, q.settled, q.winning_outcome, q.settled_at,
                 encode(q.query_components,'hex') AS c,
                 lower('0x'||substring(encode(q.query_components,'hex') from 25 for 40)) AS provider,
                 convert_from(decode(regexp_replace(
                     substring(encode(q.query_components,'hex') from 65 for 64),
                     '(00)+$',''),'hex'),'UTF8') AS stream
               FROM main.ob_queries q WHERE q.id = {int(book)}""")
    if not row:
        return f"order book {book}: not found on this node", {}
    row = row[0]
    provider, stream = row["provider"], row["stream"]
    settle = datetime.fromtimestamp(int(row["settle_time"]), timezone.utc)
    url = f"{TRUFSCAN}/{provider}/{stream}/order-books/{book}"
    name, ticker = stream_name(provider, stream)
    label = name or f"stream {stream}"
    ask = question(row["c"]) or "band unavailable, build the helper (cd agent && go build -o agent .)"

    if row["settled"]:
        val = _q(f"""SELECT pe.value::float8 AS v, pe.event_time
                     FROM main.primitive_events pe
                     JOIN main.streams s ON s.id = pe.stream_ref
                     WHERE s.stream_id = '{stream}' AND lower(s.data_provider) = '{provider}'
                       AND pe.event_time <= {int(row['settle_time'])}
                     ORDER BY pe.event_time DESC LIMIT 1""")
        v = f", value on chain at settle time {_num(val[0]['v'])}" if val else ""
        won = "paid YES" if row["winning_outcome"] else "paid NO"
        at = datetime.fromtimestamp(int(row["settled_at"]), timezone.utc) if row["settled_at"] else None
        when = (f"settled {settle:%Y-%m-%d %H:%M UTC}, {won}{v}"
                + (f", paid out at {at:%H:%M:%S UTC}" if at else ""))
    else:
        when = f"settles {settle:%Y-%m-%d %H:%M UTC}"
    line = f"order book {book}: {label}, {ask}, {when}. {url}"
    return line, dict(name=name, ticker=ticker, ask=ask, settle=settle, url=url,
                      settled=row["settled"], won=row["winning_outcome"])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for b in sys.argv[1:]:
        print(describe(b)[0])

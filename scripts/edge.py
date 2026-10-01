#!/usr/bin/env python3
"""
Should I bet, on which order book, and at what price?

    scripts/edge.py 1176          # analyse the market containing order book 1176

Answers the question a trader asks most: given a MARKET (a ladder of order
books settling at one time), where is the price wrong, and what can I do about
it with the capital I have.

Method, in order:

  1. Resolve the MARKET containing the given order book: (stream_id, settle_time)
  2. Decode every order book's strike band from query_components (via ./agent)
  3. Take the stream's current value and its DAILY MOVE distribution
  4. P(each band) = probability the next print lands in it
  5. Compare P against the ASK (what buying costs), not the mid
  6. Size against the book and the wallet
  7. Check the settlement-timing risks that can invalidate all of the above

WHY THE ASK, NOT THE MID. You buy at the ask. Comparing a probability to the
mid overstates edge by half the spread on every line.

TERMINOLOGY. A MARKET is the ladder of order books sharing (stream_id,
settle_time). An ORDER BOOK is one query_id, one strike band.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone
from statistics import NormalDist

ROOT = pathlib.Path(__file__).parent.parent
AGENT = ROOT / "agent" / "agent"

AGENT_MISSING = (
    f"the SDK helper binary is not built: {AGENT}\n"
    "  Strike bands live in an ABI blob that only the SDK can decode.\n"
    "  Build it once:  cd agent && go build -o agent .   (needs Go 1.21+)"
)
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tnconn import PSQL  # noqa: E402  ports resolve via .tn-env, env, then defaults


def q(sql):
    wrapped = f"SELECT coalesce(json_agg(t),'[]'::json) FROM ({sql}) t;"
    r = subprocess.run(PSQL + ["-c", wrapped], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr.strip()}")
    return json.loads(r.stdout.strip() or "[]")


def decode(components_hex):
    """Strike bands live in the ABI args blob. Only the SDK decodes it."""
    if not AGENT.exists():
        sys.exit(AGENT_MISSING)
    r = subprocess.run([str(AGENT), "decode", components_hex],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"decode failed (build ./agent first): {r.stderr.strip()}")
    return json.loads(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("order_book", type=int, help="any order book id in the market")
    ap.add_argument("--capital", type=float, default=5.0, help="USDC available")
    ap.add_argument("--days", type=int, default=90, help="history for the move model")
    a = ap.parse_args()

    # ---- 1. the market this order book belongs to
    # Streams are keyed on the COMPOSITE (data_provider, stream_id): 564
    # stream_ids are shared across providers, so a single-column join silently
    # reads someone else's data. Resolve to streams.id once and use the integer.
    m = q(f"""SELECT convert_from(decode(regexp_replace(
                  substring(encode(query_components,'hex') from 65 for 64),
                  '(00)+$',''),'hex'),'UTF8') AS stream_id,
                lower('0x'||substring(encode(query_components,'hex') from 25 for 40)) AS provider,
                settle_time
              FROM main.ob_queries WHERE id = {a.order_book}""")
    if not m:
        sys.exit(f"order book {a.order_book} not found")
    stream, provider, settle = m[0]["stream_id"], m[0]["provider"], m[0]["settle_time"]
    sref = q(f"""SELECT id FROM main.streams
                 WHERE stream_id='{stream}' AND lower(data_provider)='{provider}'""")
    if not sref:
        sys.exit(f"no stream {stream} for provider {provider}")
    sid = sref[0]["id"]

    books = q(f"""SELECT id, encode(query_components,'hex') AS c, settled, winning_outcome
                  FROM main.ob_queries
                  WHERE settle_time = {settle}
                    AND convert_from(decode(regexp_replace(
                        substring(encode(query_components,'hex') from 65 for 64),
                        '(00)+$',''),'hex'),'UTF8') = '{stream}'
                    AND lower('0x'||substring(encode(query_components,'hex') from 25 for 40)) = '{provider}'
                  ORDER BY id""")

    names = {}
    try:
        names = {k: (v.get("ticker") or v.get("name"))
                 for k, v in json.loads((ROOT / "streams.json").read_text()).items()
                 if not k.startswith("_")}
    except Exception:
        pass

    hrs = (settle - datetime.now(timezone.utc).timestamp()) / 3600
    print(f"MARKET  {names.get(stream, stream)}  ({stream})")
    print(f"        provider {provider}  stream_ref {sid}")
    print(f"        settles {datetime.fromtimestamp(settle, timezone.utc):%Y-%m-%d %H:%M UTC}"
          f"   in {hrs:.1f}h   {len(books)} order books")

    # ---- 2. current value and daily move distribution
    hist = q(f"""SELECT pe.event_time, pe.value::float8*100 AS v
                 FROM main.primitive_events pe
                 WHERE pe.stream_ref = {sid}
                   AND pe.event_time > extract(epoch FROM now())::INT8 - 86400*{a.days}
                 ORDER BY pe.event_time""")
    if len(hist) < 10:
        sys.exit(f"only {len(hist)} prints in {a.days}d: not enough to model")
    cur = hist[-1]["v"]
    moves = [hist[i]["v"] - hist[i - 1]["v"] for i in range(1, len(hist))]
    mu = sum(moves) / len(moves)
    sd = (sum((x - mu) ** 2 for x in moves) / (len(moves) - 1)) ** 0.5
    print(f"        current {cur:.4f}   daily move mu={mu:+.4f} sd={sd:.4f} "
          f"over {len(moves)} moves")

    # ---- 3. bands, probability, and the book
    N = NormalDist(mu, sd)
    rows = []
    for b in books:
        d = decode(b["c"])
        th = [float(x) * 100 for x in d["thresholds"]]
        lo, hi = (None, th[0]) if d["type"] == "below" else \
                 (th[0], None) if d["type"] == "above" else (th[0], th[1])
        p = (N.cdf((hi - cur) if hi is not None else 9e9) -
             N.cdf((lo - cur) if lo is not None else -9e9)) * 100
        tob = q(f"""SELECT MAX(ABS(price)) FILTER (WHERE price<0 AND outcome)     AS bid,
                           MIN(price)      FILTER (WHERE price>0 AND outcome)     AS ask,
                           MAX(ABS(price)) FILTER (WHERE price<0 AND NOT outcome) AS no_bid
                    FROM main.ob_positions WHERE query_id={b['id']}""")[0]
        bid, ask = tob["bid"], tob["ask"]
        size = q(f"""SELECT SUM(amount) AS n FROM main.ob_positions
                     WHERE query_id={b['id']} AND outcome AND price={ask}""")[0]["n"] if ask else None
        rows.append(dict(id=b["id"], lo=lo, hi=hi, p=p, bid=bid, ask=ask,
                         no_bid=tob["no_bid"], size=size,
                         settled=b["settled"], won=b["winning_outcome"]))

    print(f"\n{'book':>6} {'band':<16} {'P':>7} {'bid':>5} {'ask':>5} "
          f"{'buy edge':>9} {'sell edge':>10} {'size@ask':>9}")
    print("-" * 74)
    best = None
    for r in rows:
        band = (f"below {r['hi']:.2f}" if r["lo"] is None else
                f"above {r['lo']:.2f}" if r["hi"] is None else
                f"{r['lo']:.2f}-{r['hi']:.2f}")
        # buy edge = P - ask (you pay the ask). sell edge = bid - P (you receive the bid).
        be = (r["p"] - r["ask"]) if r["ask"] is not None else None
        se = (r["bid"] - r["p"]) if r["bid"] is not None else None
        if be is not None and (best is None or be > best[0]):
            best = (be, r)
        print(f"{r['id']:>6} {band:<16} {r['p']:>6.1f}% "
              f"{('-' if r['bid'] is None else r['bid']):>5} "
              f"{('-' if r['ask'] is None else r['ask']):>5} "
              f"{('-' if be is None else f'{be:+.1f}'):>9} "
              f"{('-' if se is None else f'{se:+.1f}'):>10} "
              f"{(r['size'] or '-'):>9}")

    # ---- 4. what to do
    if best and best[0] > 0:
        e, r = best
        n_book = int(r["size"] or 0)
        n_cash = int(a.capital * 100 // r["ask"])
        n = min(n_book, n_cash)
        print(f"\nBEST BUY  order book {r['id']} at {r['ask']}c, edge {e:+.1f} points")
        print(f"          {n} shares = ${n*r['ask']/100:.2f}  "
              f"(book has {n_book} at that level, ${a.capital:.2f} affords {n_cash})")
        # Split alternative: mint the pair for $1.00, sell the NO leg into its
        # bid. Net cost = 100 - NO_bid. Uses the NO bid, NOT the YES bid.
        if r["no_bid"]:
            sp = 100 - r["no_bid"]
            cmp = "cheaper" if r["ask"] < sp else ("same" if r["ask"] == sp else "DEARER")
            print(f"          split-and-sell NO at {r['no_bid']}c nets {sp}c/share and locks "
                  f"$1.00 up front: buying at {r['ask']}c is {cmp}")
            print(f"          and ~{100/r['ask']:.1f}x more capital efficient "
                  f"({n_cash} shares vs {int(a.capital)} pairs mintable)")
    else:
        print("\nNo positive-edge buy. The book is priced at or above model.")

    # ---- 5. settlement mechanics: what value will this ladder actually resolve on
    #
    # settle_market does NOT re-run the query. It reads result_canonical from a
    # signed attestation, so the outcome is fixed the moment the attestation is
    # captured, not at settle_time and not at settlement.
    #
    # The settlement scheduler requests one attestation per order book with a
    # WaitCommit broadcast, so a ladder is captured one book per block, and that
    # queue is GLOBAL across every market due. The window opens at settle_time.
    # Three things can happen, and only one of them is correct:
    #
    #   print on chain BEFORE the window -> resolves on the new print
    #   print lands INSIDE the window    -> ladder SPLITS: 2 or 0 winners (BUG)
    #   print arrives AFTER the window   -> resolves on the PRIOR print
    #
    # Only the middle case is a bug (trufnetwork/node#1430). The third is the
    # DESIGNED behaviour: attestation captures whatever state exists at
    # settle_time, and print arrival is never a trigger. A provider that
    # publishes late simply resolves on the previous value.
    #
    # That is the tradeable part. Publication lag is a property of the stream,
    # so where a stream reliably publishes after settle_time the resolving
    # value is ALREADY ON CHAIN and the outcome is knowable in advance.
    print("\nSETTLEMENT MECHANICS")

    att = q(f"""SELECT q.id, a.created_height
                FROM main.ob_queries q
                JOIN main.attestations a ON a.attestation_hash = q.hash
                WHERE q.id IN ({','.join(str(b['id']) for b in books)})""")
    if att:
        print(f"  ATTESTATION ALREADY EXISTS for {len(att)} of {len(books)} books.")
        print("  -> The outcome is FIXED. Nothing below changes it. Do not buy on model.")

    # Base rate: for each past settled ladder on this stream, compare the ladder's
    # attestation heights against the block height at which the print for that
    # settle window was actually written.
    # On a permissionless network a publisher can change its broadcast schedule
    # at any time, with no announcement. Two kinds of change, and they do not
    # matter equally.
    #
    #   CADENCE   how often prints arrive. Changes the stream's behaviour for
    #             every future market, so the timing base rate resets.
    #   TIME      which hour of the day it broadcasts, including a move between
    #             observation-dated and publish-time stamps. Arbitrary, and
    #             insignificant for a market opened after the change, provided
    #             the new time is consistent. It only hurts a market that was
    #             already open when the schedule moved under it.
    #
    # The value series is continuous through both, so the move model keeps the
    # full history either way.
    pr = q(f"""SELECT event_time FROM main.primitive_events
               WHERE stream_ref = {sid}
                 AND event_time > extract(epoch FROM now())-86400*120
               ORDER BY event_time""")
    ts = [int(r["event_time"]) for r in pr]

    sw_cad = sw_time = None
    if len(ts) >= 4:
        al = [x % 86400 == 0 for x in ts]
        for i in range(len(al) - 1, 0, -1):
            if al[i] != al[i - 1]:
                sw_time = ts[i]
                break
        if len(ts) >= 16:
            def med(w):
                g = sorted(b - a for a, b in zip(w, w[1:]))
                return g[len(g) // 2] if g else 0
            for i in range(len(ts) - 6, 5, -1):
                x, y = med(ts[max(0, i - 12):i]), med(ts[i:i + 12])
                if x and y and max(x, y) / min(x, y) > 2:
                    sw_cad = ts[i]
                    break

    # When was this market opened? A time change before that is irrelevant to it.
    opened = q(f"""SELECT (SELECT e.block_timestamp FROM main.ob_order_events e
                            ORDER BY abs(e.block_height - q.created_at) LIMIT 1) AS opened_at
                   FROM main.ob_queries q WHERE q.id = {a.order_book}""")
    opened = int(opened[0]["opened_at"]) if opened and opened[0]["opened_at"] else None

    # Only a cadence change resets the timing history.
    since = f"AND q.settle_time >= {sw_cad}" if sw_cad else ""

    hist_lad = q(f"""
      WITH b AS (
        SELECT q.settle_time, q.hash, q.winning_outcome AS won,
               (SELECT a.created_height FROM main.attestations a
                 WHERE a.attestation_hash = q.hash
                 ORDER BY a.signed_height DESC NULLS LAST LIMIT 1) AS att
        FROM main.ob_queries q
        WHERE q.settled {since}
          AND convert_from(decode(regexp_replace(
              substring(encode(q.query_components,'hex') from 65 for 64),
              '(00)+$',''),'hex'),'UTF8') = '{stream}'
          AND lower('0x'||substring(encode(q.query_components,'hex') from 25 for 40)) = '{provider}'
      ),
      lad AS (SELECT settle_time, min(att) AS lo, max(att) AS hi, count(*) AS books,
                     count(*) FILTER (WHERE won) AS winners
              FROM b WHERE att IS NOT NULL GROUP BY 1)
      SELECT l.settle_time, l.lo, l.hi, l.books, l.winners,
             (SELECT pe.created_at FROM main.primitive_events pe
               WHERE pe.stream_ref = {sid}
                 AND pe.event_time <= l.settle_time
                 AND pe.event_time >= l.settle_time - 86400
               ORDER BY pe.event_time DESC, pe.created_at DESC LIMIT 1) AS print_h
      FROM lad l ORDER BY l.settle_time DESC LIMIT 20""")

    stale = split = fine = unknown = 0
    bad_ladders = 0
    for h in hist_lad:
        ph = h["print_h"]
        if ph is None:
            unknown += 1
        elif h["hi"] < ph:
            stale += 1
        elif h["lo"] < ph <= h["hi"]:
            split += 1
        else:
            fine += 1
        # A ladder partitions the line, so anything other than one winner is wrong.
        if h["winners"] is not None and h["winners"] != 1:
            bad_ladders += 1
    n = stale + split + fine
    if n:
        print(f"  last {n} settled ladders on this stream:")
        print(f"    {fine:>3} print was on chain first (resolved on the new print)")
        print(f"    {stale:>3} print arrived after attestation (resolved on the PRIOR")
        print(f"        print, as designed: publication lag, not a bug)")
        print(f"    {split:>3} straddled the print (EXPOSED to a split: BUG #1430)")
        if unknown:
            print(f"    {unknown:>3} unclassified")
        print(f"  split harm: {bad_ladders} of {n} settled with a winner count other than 1")
        if split and not bad_ladders:
            print("  Split exposure is structural. It only bites when the prior and the")
            print("  new value fall in DIFFERENT bands, which has not happened here yet.")
    else:
        print("  no settled history for this stream: cannot establish a base rate")

    import datetime as _dt
    def _d(x):
        return _dt.datetime.fromtimestamp(x, _dt.timezone.utc).strftime("%Y-%m-%d")

    if sw_cad:
        print(f"\n  ** CADENCE CHANGED on {_d(sw_cad)} ** The stream now prints at a")
        print("  different frequency, which changes its behaviour for every market from")
        print("  here on. The table above counts only settlements since that date.")
        if n < 3:
            print(f"  Just {n} so far, too few for a base rate. Treat the timing")
            print("  classification as provisional, not the pricing.")

    if sw_time:
        if opened and opened < sw_time:
            print(f"\n  ** BROADCAST TIME MOVED on {_d(sw_time)}, AFTER this market opened **")
            print("  This market was priced under the old schedule and the publisher shifted")
            print("  it underneath. Check what the resolving value will be rather than")
            print("  assuming the pattern that held when the book was written.")
        else:
            print(f"\n  Broadcast time moved on {_d(sw_time)}, before this market opened.")
            print("  Which hour a publisher broadcasts in is arbitrary. As long as it stays")
            print("  consistent, it does not affect a market opened after the change.")

    if sw_cad or sw_time:
        print("  The value series is continuous either way, so the move model above uses")
        print("  the full history and is unaffected.")

    # Whether the ladder attests early or straddles, the value already on chain is
    # the one at risk of deciding it. Name the band it falls in.
    if n and (stale or split):
        hit = [r for r in rows
               if (r["lo"] is None or cur >= r["lo"]) and (r["hi"] is None or cur < r["hi"])]
        if hit:
            r = hit[0]
            b = (f"below {r['hi']:.2f}" if r["lo"] is None else
                 f"above {r['lo']:.2f}" if r["hi"] is None else
                 f"{r['lo']:.2f}-{r['hi']:.2f}")
            ask = "no ask" if r["ask"] is None else f"{r['ask']}c"
            print(f"  current print {cur:.4f} sits in order book {r['id']} ({b}), asking {ask}.")
            if sw_time:
                print("  That is the newest value on chain. This stream now stamps its publish")
                print("  time, so expect it to be fresh at settlement rather than knowable early.")
            else:
                print("  This stream tends to publish after settle_time, so that is the value")
                print("  attestation is likely to capture. Modelling publication lag, not a bug.")


    print("\nCAVEATS. The move model assumes normality and constant variance from "
          f"{len(moves)} observations. A maker quoting against you may hold intraday "
          "data that is not on chain. Size accordingly.")


if __name__ == "__main__":
    main()

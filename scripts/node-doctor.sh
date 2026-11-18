#!/usr/bin/env bash
# Is the local TN node following the chain? If not, why, and what is the safe fix?
#
#   scripts/node-doctor.sh          check only: NODE_* lines, then one VERDICT line
#   scripts/node-doctor.sh --fix    also apply the safe fix for that verdict
#   scripts/node-doctor.sh --quiet  print nothing, only log and alert on a change
#
# Exit 0 for OK or CATCHING_UP, 1 when the node needs attention, 2 when it could
# not be checked. Run it on a timer (see RUNBOOK.md, "Keep the node healthy").
#
# Why it exists: a node can keep running while it follows nothing. Restarting an
# exited kwild does not catch that, and a trading script that refuses to act on
# a stale node usually does so quietly. Orders already resting on chain stay
# live the whole time, at prices set before the stall.
#
# Verdicts, and what --fix does for each:
#   OK                lag within NODE_MAX_LAG blocks       nothing
#   CATCHING_UP       behind, but the height is moving      nothing
#   NOT_RUNNING       no kwild process                      nothing: start it as RUNBOOK.md Phase 4 does
#   STARTING          process up, RPC not answering yet     nothing
#   PEER_ID_MISMATCH  a bootnode presents a different key   refresh IDs from the published list, restart
#   NO_PEERS          stuck with zero peers                 restart (at most once per 10 min)
#   APPHASH           consensus mismatch: outdated binary   nothing: report version vs latest release
#   STUCK             stuck with peers, cause unknown       nothing: read the kwild log
#   UNCHECKED         the upstream height was unreadable    nothing
#
# Settings, all optional (environment or .tn-env):
#   TN_UPSTREAM     a node that is known to be current, for the chain tip
#   TN_GATEWAY      fallback for the tip when TN_UPSTREAM does not answer
#   NODE_MAX_LAG    blocks behind that still count as OK (default 20)
#   NODE_ALERT_CMD  command run with one message argument on each alert, for
#                   machines without a desktop (default: notify-send if present)
#   TN_BOOT_SRC     where the network publishes its current bootnodes
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/.tn-env" ] && . "$ROOT/.tn-env"
RPC=${TN_RPC:-http://127.0.0.1:${TN_RPC_PORT:-8484}}
UPSTREAM=${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}
GATEWAY=${TN_GATEWAY:-https://gateway.mainnet.truf.network}
HOME_DIR=${TN_HOME:-$ROOT}
STATE="$HOME_DIR/.node-doctor.state"
OUT="$HOME_DIR/node-doctor.log"
MAX_LAG=${NODE_MAX_LAG:-20}
BOOT_SRC=${TN_BOOT_SRC:-https://raw.githubusercontent.com/trufnetwork/node/main/docs/node-operator-guide.md}

FIX=0; QUIET=0
for a in "$@"; do case $a in --fix) FIX=1 ;; --quiet) QUIET=1 ;; *) echo "unknown flag $a"; exit 2 ;; esac; done

say(){ [ $QUIET = 1 ] || echo "$*"; }
note(){ echo "$(date '+%F %H:%M %Z')  $*" >> "$OUT"; say "$*"; }
height(){ curl -s -m 15 -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"user.chain_info","params":{}}' "$1/rpc/v1" 2>/dev/null \
  | grep -oE '"block_height":[0-9]+' | grep -oE '[0-9]+$'; }
# Anchored to a path ending in /kwild: a bare "kwild start" pattern also matches
# any shell whose command line mentions it, and a kill then lands on the shell.
kpid(){ pgrep -f '^[^ ]*/?kwild start' | while read -r p; do
          [ "$(basename "$(readlink -f "/proc/$p/exe" 2>/dev/null)")" = kwild ] && echo "$p"; done | head -1; }
get(){ grep -E "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
put(){ { grep -vE "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } > "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }

# Read the running node's own settings: its binary, its --root, and the file its
# output goes to. Fall back to the runbook's layout when it is not running.
PID=$(kpid)
KWILD=$(command -v kwild); NODE_ROOT="$HOME_DIR/tn-node"; LOGF="$HOME_DIR/kwild-run.log"
if [ -n "$PID" ]; then
  KWILD=$(readlink -f "/proc/$PID/exe")
  r=$(tr '\0' ' ' < "/proc/$PID/cmdline" | grep -oE -- '--root [^ ]+' | cut -d' ' -f2)
  [ -n "$r" ] && NODE_ROOT=$r
  o=$(readlink -f "/proc/$PID/fd/1" 2>/dev/null)
  [ -f "$o" ] && LOGF=$o
fi
CONF="$NODE_ROOT/config.toml"

verdict(){
  if [ -z "$PID" ]; then V=NOT_RUNNING; return; fi
  L=$(height "$RPC"); U=$(height "$UPSTREAM"); [ -n "$U" ] || U=$(height "$GATEWAY")
  say "NODE_PID=$PID"; say "NODE_LOCAL=${L:-?}"; say "NODE_TIP=${U:-?}"
  if [ -z "$L" ]; then
    up=$(ps -o etimes= -p "$PID" | tr -d ' ')
    if [ "${up:-0}" -lt 600 ]; then V=STARTING; else V=STUCK; fi; return
  fi
  if [ -z "$U" ]; then V=UNCHECKED; return; fi
  LAG=$((U - L)); say "NODE_BEHIND=$LAG"
  if [ "$LAG" -le "$MAX_LAG" ]; then V=OK; return; fi
  # Moving? Compare with the last run, or sample twice if there is no recent one.
  pl=$(get height); pt=$(get time); now=$(date +%s)
  if [ -z "$pl" ] || [ $((now - ${pt:-0})) -gt 900 ]; then
    pl=$L; pt=$now; sleep 20; L=$(height "$RPC"); now=$(date +%s); L=${L:-$pl}
  fi
  if [ "$L" -gt "$pl" ]; then
    rate=$(awk -v d=$((L - pl)) -v t=$((now - pt)) 'BEGIN{printf "%.1f", d/(t>0?t:1)}')
    say "NODE_RATE=${rate}/s"; V=CATCHING_UP; return
  fi
  if grep -q 'peer id mismatch' "$LOGF" 2>/dev/null; then V=PEER_ID_MISMATCH
  elif grep -qiE 'apphash mismatch|wrong app ?hash|consensus failure' "$LOGF" 2>/dev/null; then V=APPHASH
  elif tail -50 "$LOGF" 2>/dev/null | grep -q 'No connected peers'; then V=NO_PEERS
  else V=STUCK; fi
}

# Stop kwild by its exact PID. If a supervisor (systemd, a watchdog) starts it
# again within a minute, leave it to that. Otherwise start it the way the
# runbook does, with a fresh log, so the next check reads only the new run.
restart_kwild(){
  note "restarting kwild (pid $PID)"
  kill -TERM "$PID"
  for _ in $(seq 60); do kill -0 "$PID" 2>/dev/null || break; sleep 2; done
  if kill -0 "$PID" 2>/dev/null; then note "kwild did not stop within 2 min, leaving it"; return 1; fi
  for _ in $(seq 20); do [ -n "$(kpid)" ] && { note "kwild started again by its supervisor"; put restarted "$(date +%s)"; return 0; }; sleep 3; done
  mv "$LOGF" "${LOGF%.log}.$(date +%Y%m%d-%H%M%S).log" 2>/dev/null
  setsid nohup "$KWILD" start --root "$NODE_ROOT" > "$LOGF" 2>&1 < /dev/null &
  note "started kwild again (pid $!), log $LOGF"
  put restarted "$(date +%s)"
}

# Swap each configured bootnode whose host now presents a different key for the
# published entry of that host, but only if the published key derives to exactly
# the peer ID the host presented. Anything else is refused: a key that matches
# neither the config nor the published list is not one to trust.
refresh_bootnodes(){
  pub=$(curl -s -m 20 "$BOOT_SRC" | grep -oE '[0-9a-f]{64,66}#(ed25519|secp256k1)@[A-Za-z0-9.-]+:[0-9]+' | sort -u)
  [ -n "$pub" ] || { note "could not read the published bootnodes from $BOOT_SRC"; return 1; }
  seen=$(grep 'peer id mismatch' "$LOGF" | grep -oE '@[A-Za-z0-9.-]+:[0-9]+: all dials failed.*remote key matches [1-9A-HJ-NP-Za-km-z]+' \
         | sed -E 's/^@([^:]+:[0-9]+).*remote key matches ([1-9A-HJ-NP-Za-km-z]+).*/\1 \2/' | sort -u)
  cp "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M)"
  python3 - "$CONF" "$pub" "$seen" <<'EOF' || return 1
import re, sys
conf, pub, seen = sys.argv[1], sys.argv[2].split(), [l.split() for l in sys.argv[3].splitlines() if l.strip()]
A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
def peer_id(entry):
    key, typ = entry.split('@')[0].split('#')
    k = bytes.fromhex(key)
    pb = bytes([8, 1 if typ == 'ed25519' else 2, 0x12, len(k)]) + k   # libp2p PublicKey protobuf
    b = bytes([0, len(pb)]) + pb                                        # identity multihash
    n, s = int.from_bytes(b, 'big'), ''
    while n:
        n, r = divmod(n, 58); s = A[r] + s
    return '1' * (len(b) - len(b.lstrip(b'\0'))) + s
by_host = {e.split('@')[1]: e for e in pub}
text = open(conf).read()
changed = 0
for host, presented in seen:
    new = by_host.get(host)
    if not new:
        print(f"REFUSED {host}: not in the published list"); continue
    if peer_id(new) != presented:
        print(f"REFUSED {host}: presents {presented}, published key derives to {peer_id(new)}"); continue
    for old in set(re.findall(r'[0-9a-f]{64,66}#(?:ed25519|secp256k1)@' + re.escape(host), text)):
        if old != new:
            text = text.replace(old, new); changed += 1
            print(f"UPDATED {host}: {old[:12]}... -> {new[:12]}... (= {presented})")
open(conf, 'w').write(text)
sys.exit(0 if changed else 1)
EOF
}

alert(){
  last=$(get verdict); lt=$(get alerted)
  # Alert on any change, and again hourly while it persists.
  if [ "$V" != "$last" ] || { [ "$V" != OK ] && [ "$V" != CATCHING_UP ] && [ $(( $(date +%s) - ${lt:-0} )) -gt 3600 ]; }; then
    note "VERDICT $V (local ${L:-?}, tip ${U:-?})"
    if [ "$V" != OK ] && [ "$V" != CATCHING_UP ]; then
      msg="TN node: $V (local ${L:-?}, tip ${U:-?}). Resting orders are unmanaged while it is stale. Run scripts/node-doctor.sh"
      if [ -n "${NODE_ALERT_CMD:-}" ]; then $NODE_ALERT_CMD "$msg"
      elif command -v notify-send >/dev/null; then notify-send -u critical "TN node: $V" "$msg" 2>/dev/null; fi
    fi
    put alerted "$(date +%s)"
  fi
  put verdict "$V"
}

verdict
say "VERDICT $V"
alert
[ -n "${L:-}" ] && { put height "$L"; put time "$(date +%s)"; }

case $V in
  OK|CATCHING_UP) exit 0 ;;
  UNCHECKED) exit 2 ;;
esac
[ $FIX = 1 ] || { say "NEXT: run with --fix, or see FIELD-MANUAL.md 'Node stalled'"; exit 1; }

case $V in
  PEER_ID_MISMATCH)
    if r=$(refresh_bootnodes); then note "$r"; restart_kwild
    else note "bootnode refresh made no change: ${r:-no output}"; fi ;;
  NO_PEERS)
    rs=$(get restarted)
    if [ $(( $(date +%s) - ${rs:-0} )) -ge 600 ]; then restart_kwild
    else note "NO_PEERS: restarted under 10 min ago, waiting"; fi ;;
  APPHASH)
    have=$("$KWILD" version 2>/dev/null | grep -i version | awk '{print $NF}')
    want=$(curl -s -m 15 https://api.github.com/repos/trufnetwork/node/releases/latest | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
    note "APPHASH: binary ${have:-?}, latest release ${want:-?}. Install the release (FIELD-MANUAL.md 'Node stalled'). Not automatic." ;;
  *) note "$V: no automatic fix. Read the end of $LOGF." ;;
esac
exit 1

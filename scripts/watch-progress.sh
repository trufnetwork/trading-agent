#!/usr/bin/env bash
# Trigger watcher. Emits ONE line each time progress crosses a step boundary.
#
#   scripts/watch-progress.sh                 # 2% while fast, 1% while catching up
#   STEP_SLOW=1 STEP_FAST=2 POLL=10 ...        # or set them yourself
#
# Polling is cheap, printing is not. Poll often so the feed feels live, and emit
# only when a number the person cares about has actually moved. Percent is the
# right trigger rather than elapsed time: during the download a step is seconds,
# during the catch-up the same rule goes quiet on its own.
#
# Each emitted line is one event. In Claude Code, run this through the
# monitoring tool so every line arrives as its own message.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Step size per stage. The fast stages move a percent in seconds, so a coarser
# step keeps the feed readable. The catch-up runs for hours, so a percent there
# is several minutes and deserves every one.
STEP_FAST=${STEP_FAST:-2}
STEP_SLOW=${STEP_SLOW:-1}
POLL=${POLL:-10}
# Percent alone goes silent when throughput drops, and silence reads as a
# stall. Emit at least this often regardless, because the block time in the
# line keeps moving even when the percent does not.
HEARTBEAT=${HEARTBEAT:-300}

prev=""
last_emit=0
while true; do
  line=$("$ROOT/scripts/onboard.sh" --line 2>/dev/null) || true
  if [ -n "$line" ]; then
    # Bucket the percent so only a real step change fires. Stage and phase
    # changes are part of the key, so a transition always emits.
    pct=$(printf '%s' "$line" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
    stage=$(printf '%s' "$line" | grep -oE 'downloading|loading|catching up|phase [0-9]+' | head -1)
    case "$stage" in
      "catching up") step=$STEP_SLOW ;;
      *)             step=${STEP:-$STEP_FAST} ;;
    esac
    if [ -n "${pct:-}" ]; then
      key="$stage:$(( pct / step ))"
    else
      key="$stage"
    fi
    now=$(date +%s)
    if [ "$key" != "$prev" ] || [ $((now - last_emit)) -ge "$HEARTBEAT" ]; then
      printf '%s\n' "$line"
      prev="$key"; last_emit=$now
    fi
  fi
  sleep "$POLL"
done

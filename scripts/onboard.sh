#!/usr/bin/env bash
# Session view of the onboarding run.
#
#   scripts/onboard.sh            # render once
#   scripts/onboard.sh --watch    # refresh every 20s until the phase changes
#
# Detection is not duplicated here. This renders scripts/status.sh, which stays
# the single source of truth for what phase the machine is in.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W=64

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[0m'
else B=""; D=""; G=""; Y=""; C=""; R=""; fi

vis(){ printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g' | wc -m; }
pad(){ local n=$(( W - $(vis "$1") )); printf '%s%*s' "$1" "$n" ""; }
top(){ printf '%s╭─ %s %s╮%s\n' "$D" "$1" "$(printf '─%.0s' $(seq 1 $((W-1-${#1}))))" "$R"; }
row(){ printf '%s│%s %s %s│%s\n' "$D" "$R" "$(pad "$1")" "$D" "$R"; }
bot(){ printf '%s╰%s╯%s\n' "$D" "$(printf '─%.0s' $(seq 1 $((W+2))))" "$R"; }

comma(){ awk -v n="${1:-0}" 'BEGIN{s=sprintf("%d",n);r="";while(length(s)>3){r="," substr(s,length(s)-2) r;s=substr(s,1,length(s)-3)}printf "%s%s",s,r}'; }
hm(){ awk -v s="${1:-0}" 'BEGIN{if(s<3600)printf "%dm",s/60+1;else printf "%dh %02dm",s/3600,(s%3600)/60}'; }

NAMES=("Tools" "Postgres" "Node config" "Sync" "SDK helper" "Wallet" "Trade")

render(){
  local out phase next
  out="$(TN_PEEK=1 "$ROOT/scripts/status.sh" 2>/dev/null)"
  phase=$(printf '%s' "$out" | sed -n 's/^PHASE \([0-9]*\) of.*/\1/p'); phase=${phase:-1}
  # TN_DEMO_PHASE renders a given phase without changing anything, for reviewing
  # the human-facing copy without having to be in that state.
  phase=${TN_DEMO_PHASE:-$phase}
  next=$(printf '%s' "$out" | sed -n 's/^NEXT: //p')

  clear 2>/dev/null || true
  printf '\n  %sTRUF.NETWORK agent onboarding%s%*sphase %s%s of 7%s\n\n' \
    "$B" "$R" $((W-38)) "" "$B" "$phase" "$R"

  local i name mark detail
  for i in $(seq 1 7); do
    name="${NAMES[$((i-1))]}"
    if   [ "$i" -lt "$phase" ]; then mark="${G}✔${R}"
    elif [ "$i" -eq "$phase" ]; then mark="${C}▶${R}"
    else mark="${D}·${R}"; fi
    detail=""
    case $i in
      1) detail=$(printf '%s' "$out" | grep -c '^  \[ok\]' >/dev/null && printf '%s' "$(printf '%s' "$out" | sed -n '/1. tools/,/2. postgres/p' | grep -c '\[ok\]')/4 present") ;;
      2) detail=$(printf '%s' "$out" | sed -n '/2. postgres/,/3. node/p' | sed -n 's/.*\] *//p' | head -1) ;;
      3) detail=$(printf '%s' "$out" | sed -n '/3. node config/,/4. sync/p' | sed -n 's/.*\] *//p' | head -1) ;;
      4) detail=$(printf '%s' "$out" | grep -m1 'restore progress:' | sed 's/.*progress: //;s/ received, highest.*//;s/$/ restored/')
         [ -z "$detail" ] && detail=$(printf '%s' "$out" | sed -n '/4. sync/,/5. sdk/p' | sed -n 's/.*\] *//p' | sed -n 2p)
         [ -z "$detail" ] && detail=$(printf '%s' "$out" | sed -n '/4. sync/,/5. sdk/p' | sed -n 's/.*\] *//p' | head -1) ;;
      6) [ "$i" -eq "$phase" ] && detail="${Y}needs you${R}" ;;
    esac
    printf '   %b  %s%s%s  %s%-13s%s %s%s%s\n' "$mark" "$D" "$i" "$R" "$B" "$name" "$R" "$D" "${detail:0:40}" "$R"
  done
  echo

  case $phase in
    1) if printf '%s' "$out" | grep -q 'kwild requires 16'; then
         top "WAITING ON YOU"
         row "Install the Postgres 16 client. It needs sudo, so it is"
         row "yours to run, not mine."
         row ""
         row "  ${C}sudo apt-get install -y postgresql-client-16${R}"
         row ""
         row "kwild refuses to start on any other major version."
         row "Full instructions, including the PGDG repo if 16 is not"
         row "available: skills/truf-node-up/SKILL.md section 2"
         bot
       else
         top "WORKING"
         printf '%s│%s %s %s│%s\n' "$D" "$R" "$(pad "${next:0:58}")" "$D" "$R"
         bot
       fi ;;
    4) top "LONG WAIT"
       row "Syncing from a snapshot, then replaying every block since."
       row ""
       printf '%s│%s %s %s│%s\n' "$D" "$R" "$(pad "  ${next:0:56}")" "$D" "$R"
       row ""
       row "Around 10 hours from cold. Nothing for you to do."
       row "Close this if you like. Progress survives."
       bot ;;
    6) top "WAITING ON YOU"
       row "Two things only you can do, in this order."
       row ""
       row "${B}1.${R} Approve the agent rule in your wallet."
       row "${B}2.${R} Send the funds. \$5 is plenty to start."
       row ""
       row "${Y}Before sending, compare the agent address the site${R}"
       row "${Y}shows against the one I derived, character by${R}"
       row "${Y}character. That is the only step that loses money.${R}"
       row ""
       row "Walkthrough written for you, not for me:"
       row "  skills/truf-agent-wallet/owner-walkthrough.md"
       bot ;;
    7) top "READY"
       row "Node synced, wallet funded. I can trade."
       row ""
       row "  ${C}psql -f sql/market-scan.sql${R}   pick a market"
       row "  ${C}scripts/edge.py <book>${R}        should I bet, and how much"
       bot ;;
    *) top "WORKING"
       printf '%s│%s %s %s│%s\n' "$D" "$R" "$(pad "${next:0:58}")" "$D" "$R"
       bot ;;
  esac
  echo
  printf '   %sscripts/status.sh for the raw checks%s\n\n' "$D" "$R"
  printf '%s' "$phase" > "$ROOT/.tn-phase"
}

# --md emits GitHub-flavored markdown instead of a terminal drawing. An agent
# running in a chat client pastes this into its own reply, where the client
# renders it. Anything written to stdout inside a tool call is not shown.
render_md(){
  local out phase next i name mark detail bar done_n
  out="$(TN_PEEK=1 "$ROOT/scripts/status.sh" 2>/dev/null)"
  phase=$(printf '%s' "$out" | sed -n 's/^PHASE \([0-9]*\) of.*/\1/p'); phase=${phase:-1}
  phase=${TN_DEMO_PHASE:-$phase}
  next=$(printf '%s' "$out" | sed -n 's/^NEXT: //p')
  done_n=$((phase-1))
  bar=""
  for i in $(seq 1 7); do
    if   [ "$i" -lt "$phase" ]; then bar="$bar🟩"
    elif [ "$i" -eq "$phase" ]; then bar="$bar🟦"
    else bar="$bar⬜"; fi
  done

  # Addressed to the agent. An HTML comment, so it vanishes when rendered.
  local pending=0 code=
  [ "$(cat "$ROOT/.tn-shown" 2>/dev/null || true)" = "$phase" ] || pending=1
  if [ "$pending" = 1 ]; then
    code=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
    echo "$code" > "$ROOT/.tn-code"
    printf '<!-- agent: start a background wake-up timer (sleep 3), then END YOUR TURN with this whole block, verbatim, as your final message. Text between tool calls often never reaches the person. The timer wakes you without them replying. Then run: scripts/status.sh --shown %s -->\n\n' "$code"
  else
    printf '<!-- agent: tool output is not shown to the person. To show this block, make it the final message of a turn. -->\n\n'
  fi
  local wk='⚙️ Working'
  # The banner rides along until the person has seen a first block and replied.
  if [ ! -f "$ROOT/.tn-shown" ] || [ "${2:-}" = "--banner" ]; then
    printf '```\n'
    printf '████████╗██████╗ ██╗   ██╗███████╗\n'
    printf '╚══██╔══╝██╔══██╗██║   ██║██╔════╝\n'
    printf '   ██║   ██████╔╝██║   ██║█████╗\n'
    printf '   ██║   ██╔══██╗██║   ██║██╔══╝\n'
    printf '   ██║   ██║  ██║╚██████╔╝██║\n'
    printf '   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═╝\n'
    printf '```\n\n`agent onboarding  ·  node → wallet → first trade`\n\n'
  fi
  printf '### TRUF.NETWORK onboarding\n\n'
  printf '%s\n\n' "$bar"
  printf '**Phase %s of 7** — %s\n\n' "$phase" "${NAMES[$((phase-1))]}"
  printf '| | Phase | Detail |\n|:-:|---|---|\n'
  for i in $(seq 1 7); do
    name="${NAMES[$((i-1))]}"
    if   [ "$i" -lt "$phase" ]; then mark="✅"
    elif [ "$i" -eq "$phase" ]; then mark="▶️"
    else mark="⬜"; fi
    detail=""
    case $i in
      1) detail="$(printf '%s' "$out" | sed -n '/1. tools/,/2. postgres/p' | grep -c '\[ok\]')/4 present" ;;
      2) detail=$(printf '%s' "$out" | sed -n '/2. postgres/,/3. node/p' | sed -n 's/.*\] *//p' | head -1) ;;
      3) detail=$(printf '%s' "$out" | sed -n '/3. node config/,/4. sync/p' | sed -n 's/.*\] *//p' | head -1) ;;
      4) detail=$(printf '%s' "$out" | grep -m1 'restore progress:' | sed 's/.*progress: //;s/ received, highest.*//;s/$/ restored/')
         [ -z "$detail" ] && detail=$(printf '%s' "$out" | sed -n '/4. sync/,/5. sdk/p' | sed -n 's/.*\] *//p' | sed -n 2p)
         [ -z "$detail" ] && detail=$(printf '%s' "$out" | sed -n '/4. sync/,/5. sdk/p' | sed -n 's/.*\] *//p' | head -1) ;;
      6) [ "$i" -eq "$phase" ] && detail="**needs you**" ;;
    esac
    printf '| %s | **%s** %s | %s |\n' "$mark" "$i" "$name" "$detail"
  done
  echo
  case $phase in
    1) if printf '%s' "$out" | grep -q 'kwild requires 16'; then
         printf '> ### ⏸ Waiting on you\n> Install the Postgres 16 client. It needs sudo, so it is yours to run.\n> \n> ```\n> sudo apt-get install -y postgresql-client-16\n> ```\n> \n> kwild refuses to start on any other major version. If 16 is not available,\n> the PGDG steps are in `skills/truf-node-up/SKILL.md` section 2.\n'
       else
         printf '> ### %s\n> %s\n' "$wk" "$next"
       fi ;;
    4) v(){ printf '%s' "$out" | sed -n "s/^$1=//p"; }
       stage=$(v SYNC_STAGE); now=$(date +%s); st=$(v SYNC_START)
       el=""
       [ -n "$st" ] && el=$(awk -v s=$((now-st)) 'BEGIN{if(s<3600)printf "%dm %02ds",s/60,s%60;else printf "%dh %02dm",s/3600,(s%3600)/60}')
       if [ "$stage" = "replay" ]; then
         base=$(v SYNC_BASE); loc=$(v SYNC_LOCAL); tip=$(v SYNC_TIP); rate=$(v SYNC_RATE)
         tot=$((tip-base)); dn=$((loc-base))
         pct=$(awk -v d="$dn" -v t="$tot" 'BEGIN{if(t>0)printf "%.0f",100*d/t;else print 0}')
         bar=$(awk -v p="$pct" 'BEGIN{n=int(p/7);for(i=0;i<14;i++)printf (i<n?"#":"-")}')
         bar=$(printf '%s' "$bar" | sed 's/#/█/g;s/-/░/g')
         printf '> ### ⏳ Step 3 of 3 — catching up on recent activity\n>\n'
         printf '> `%s` **%s%%**\n>\n' "$bar" "$pct"
         printf '> | | |\n> |---|---|\n'
         printf '> | Caught up | %s of %s blocks |\n' "$(comma "$dn")" "$(comma "$tot")"
         bt=$(v SYNC_BLOCK_TIME)
         [ -n "$bt" ] && printf '> | Now replaying | %s |\n' "$(date -d "@$bt" '+%a %d %b, %H:%M')"
         [ -n "$rate" ] && printf '> | Speed | %s blocks per second |\n' "$rate"
         [ -n "$el" ] && printf '> | Running for | %s |\n' "$el"
         if [ -n "$rate" ]; then
           secs=$(awk -v d="$(v SYNC_BEHIND)" -v r="$rate" 'BEGIN{if(r>0)printf "%d",d/r;else print 0}')
           printf '> | Time left | about %s |\n' "$(hm "$secs")"
           printf '> | Expected finish | %s |\n' "$(date -d "+$secs seconds" '+%H:%M %Z, %a %d %b')"
         else
           printf '> | Time left | measuring, check again in a minute |\n'
         fi
         printf '>\n> Nothing for you to do. Progress survives a restart.\n'
       elif [ "$stage" = "apply" ]; then
         as=$(v SYNC_APPLY_START); est=$(v SYNC_APPLY_EST); ael=$((now-${as:-now}))
         pct=$(awk -v e="$ael" -v t="${est:-1}" 'BEGIN{p=100*e/t; if(p>99)p=99; printf "%d",p}')
         bar=$(awk -v p="$pct" 'BEGIN{n=int(p/7);for(i=0;i<14;i++)printf (i<n?"#":"-")}')
         bar=$(printf '%s' "$bar" | sed 's/#/█/g;s/-/░/g')
         arem=$((${est:-0}-ael)); [ "$arem" -lt 0 ] && arem=0
         printf '> ### ⏳ Step 2 of 3 — loading it into the database\n>\n'
         printf '> `%s` **%s%%**\n>\n' "$bar" "$pct"
         printf '> | | |\n> |---|---|\n'
         printf '> | Loading table | %s |\n' "$(v SYNC_APPLY_TABLE)"
         printf '> | Rows so far | %s |\n' "$(comma "$(v SYNC_APPLY_ROWS)")"
         printf '> | Database size | %s GB |\n' "$(awk -v b="$(v SYNC_APPLY_BYTES)" 'BEGIN{printf "%.1f",b/1073741824}')"
         printf '> | Running for | %s of about %s |\n' "$(hm "$ael")" "$(hm "${est:-0}")"
         printf '> | Time left | about %s |\n' "$(hm "$arem")"
         base=$(v SYNC_BASE)
         if [ -n "$base" ]; then
           tip=$(curl -s --max-time 6 "${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}/api/v1/health" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['height'])" 2>/dev/null)
           if [ -n "$tip" ]; then
             csecs=$(awk -v d=$((tip-base)) 'BEGIN{printf "%d",d/1.98}')
             printf '> | Then catching up | %s blocks, about %s |\n' "$(comma $((tip-base)))" "$(hm "$csecs")"
             printf '> | Everything done around | %s |\n' "$(date -d "+$((arem+csecs)) seconds" '+%H:%M %Z, %a %d %b')"
           fi
         fi
         printf '>\n> Do not interrupt this. Nothing for you to do.\n'
       elif [ "$stage" = "restore" ]; then
         ch=$(v SYNC_CHUNKS); tc=$(v SYNC_CHUNK_TOTAL); by=$(v SYNC_BYTES); base=$(v SYNC_BASE)
         gb=$(awk -v b="${by:-0}" 'BEGIN{printf "%.2f",b/1073741824}')
         sp=""
         [ -n "$st" ] && [ "${ch:-0}" -gt 0 ] 2>/dev/null && sp=$(awk -v c="$ch" -v s=$((now-st)) 'BEGIN{if(s>0)printf "%.2f",c/s}')
         printf '> ### ⏳ Step 1 of 3 — downloading a copy of the database\n>\n'
         if [ -n "$tc" ] && [ "$tc" -gt 0 ] 2>/dev/null; then
           pct=$(awk -v c="$ch" -v t="$tc" 'BEGIN{printf "%.0f",100*c/t}')
           bar=$(awk -v p="$pct" 'BEGIN{n=int(p/7);for(i=0;i<14;i++)printf (i<n?"#":"-")}')
           bar=$(printf '%s' "$bar" | sed 's/#/█/g;s/-/░/g')
           printf '> `%s` **%s%%**\n>\n' "$bar" "$pct"
         fi
         printf '> | | |\n> |---|---|\n'
         if [ -n "$tc" ]; then printf '> | Downloaded | %s of %s pieces, %s GB |\n' "$ch" "$tc" "$gb"
         else printf '> | Downloaded | %s pieces, %s GB |\n' "$ch" "$gb"; fi
         [ -n "$sp" ] && printf '> | Speed | %s pieces per second |\n' "$sp"
         [ -n "$el" ] && printf '> | Running for | %s |\n' "$el"
         rem=0
         if [ -n "$tc" ] && [ -n "$sp" ]; then
           rem=$(awk -v t="$tc" -v c="$ch" -v r="$sp" 'BEGIN{if(r>0)printf "%d",(t-c)/r;else print 0}')
           [ "$rem" -gt 0 ] 2>/dev/null && printf '> | Download done in | about %s |\n' "$(hm "$rem")"
         fi
         if [ -n "$base" ]; then
           tip=$(curl -s --max-time 6 "${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}/api/v1/health" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['height'])" 2>/dev/null)
           if [ -n "$tip" ]; then
             blocks=$((tip-base))
             csecs=$(awk -v d="$blocks" 'BEGIN{printf "%d",d/1.98}')
             printf '> | Then catching up | %s blocks, about %s |\n' "$(comma "$blocks")" "$(hm "$csecs")"
             printf '> | Everything done around | %s |\n' "$(date -d "+$((csecs+rem)) seconds" '+%H:%M %Z, %a %d %b')"
           fi
         fi
         printf '>\n'
         if [ "$(v SYNC_PEERS_OK)" = "0" ]; then
           printf '> ⚠️ **Cannot reach any other machine on the network.** This is a\n'
           printf '> connection problem, not a download problem, whatever the errors say.\n'
           printf '> See RUNBOOK.md, "If sync never starts".\n'
         else
           vv=$(v SYNC_VERIFIED)
           [ "$vv" = "yes" ] && vv="✅ verified against a trusted source" || vv="⏳ not yet verified"
           printf '> %s, connected to %s other machines.\n' "$vv" "$(v SYNC_PEERS_OK)"
         fi
       else
         printf '> ### ⏳ Long wait\n> %s\n' "$next"
       fi ;;
    6) printf '> ### ⏸ Waiting on you\n> **1.** Approve the agent rule in your wallet.\n> **2.** Send the funds. $5 is plenty to start.\n> \n> ⚠️ **Before sending, compare the agent address the site shows against the one\n> I derived, character by character.** That is the only step that loses money.\n> \n> Walkthrough written for you: `skills/truf-agent-wallet/owner-walkthrough.md`\n' ;;
    7) printf '> ### ✅ Ready\n> Node synced, wallet funded.\n> \n> ```\n> psql -f sql/market-scan.sql   # pick a market\n> scripts/edge.py <book>        # should I bet, and how much\n> ```\n' ;;
    *) printf '> ### %s\n> %s\n' "$wk" "$next" ;;
  esac
  # The stamp lets status.sh --shown confirm the block reached the chat.
  [ "$pending" = 1 ] && printf '\n`updated %s · %s`\n' "$(date +%H:%M:%S)" "$code"
}

# --line prints ONE compact line: the routine refresh. Use the full --md block
# only at a stage or phase change, otherwise the display is all noise.
render_line(){
  local out phase stage v now st el
  out="$(TN_PEEK=1 "$ROOT/scripts/status.sh" 2>/dev/null)"
  v(){ printf '%s' "$out" | sed -n "s/^$1=//p"; }
  phase=$(printf '%s' "$out" | sed -n 's/^PHASE \([0-9]*\) of.*/\1/p'); phase=${phase:-1}
  stage=$(v SYNC_STAGE); now=$(date +%s); st=$(v SYNC_START)
  el=""
  [ -n "$st" ] && el=$(awk -v s=$((now-st)) 'BEGIN{if(s<3600)printf "%dm",s/60;else printf "%dh%02dm",s/3600,(s%3600)/60}')
  if [ "$stage" = "restore" ]; then
    local ch tc gb pct rem base tip csecs
    ch=$(v SYNC_CHUNKS); tc=$(v SYNC_CHUNK_TOTAL)
    gb=$(awk -v b="$(v SYNC_BYTES)" 'BEGIN{printf "%.1f",b/1073741824}')
    pct=$(awk -v c="$ch" -v t="${tc:-0}" 'BEGIN{if(t>0)printf "%d",100*c/t;else print 0}')
    rem=$(awk -v t="${tc:-0}" -v c="$ch" -v s=$((now-st)) 'BEGIN{if(c>0&&t>c)printf "%d",(t-c)*s/c;else print 0}')
    base=$(v SYNC_BASE)
    tip=$(curl -s --max-time 6 "${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}/api/v1/health" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['height'])" 2>/dev/null)
    csecs=0; [ -n "$tip" ] && [ -n "$base" ] && csecs=$(awk -v d=$((tip-base)) 'BEGIN{printf "%d",d/1.98}')
    printf '📥 **downloading %s%%** · %s/%s pieces · %s GB · %s elapsed · all done ~%s\n' \
      "$pct" "$ch" "${tc:-?}" "$gb" "$el" "$(date -d "+$((rem+csecs)) seconds" '+%H:%M %a')"
  elif [ "$stage" = "apply" ]; then
    local as est ael pct arem base tip csecs
    as=$(v SYNC_APPLY_START); est=$(v SYNC_APPLY_EST); ael=$((now-${as:-now}))
    pct=$(awk -v e="$ael" -v t="${est:-1}" 'BEGIN{p=100*e/t;if(p>99)p=99;printf "%d",p}')
    arem=$((${est:-0}-ael)); [ "$arem" -lt 0 ] && arem=0
    base=$(v SYNC_BASE)
    tip=$(curl -s --max-time 6 "${TN_UPSTREAM:-http://node-1.mainnet.truf.network:8484}/api/v1/health" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['services']['user']['height'])" 2>/dev/null)
    csecs=0; [ -n "$tip" ] && [ -n "$base" ] && csecs=$(awk -v d=$((tip-base)) 'BEGIN{printf "%d",d/1.98}')
    printf '🗄️ **loading %s%%** · %s · %s rows · %s GB · %sm of ~%sm · all done ~%s\n' \
      "$pct" "$(v SYNC_APPLY_TABLE)" \
      "$(awk -v r="$(v SYNC_APPLY_ROWS)" 'BEGIN{printf "%.1fM",r/1000000}')" \
      "$(awk -v b="$(v SYNC_APPLY_BYTES)" 'BEGIN{printf "%.1f",b/1073741824}')" \
      "$((ael/60))" "$(( ${est:-0} /60))" \
      "$(date -d "+$((arem+csecs)) seconds" '+%H:%M %a')"
  elif [ "$stage" = "replay" ]; then
    local base loc tip tot dn pct rate secs
    base=$(v SYNC_BASE); loc=$(v SYNC_LOCAL); tip=$(v SYNC_TIP); rate=$(v SYNC_RATE)
    tot=$((tip-base)); dn=$((loc-base))
    pct=$(awk -v d="$dn" -v t="$tot" 'BEGIN{if(t>0)printf "%d",100*d/t;else print 0}')
    secs=$(awk -v d="$(v SYNC_BEHIND)" -v r="${rate:-1.98}" 'BEGIN{if(r>0)printf "%d",d/r;else print 0}')
    local bt at
    bt=$(v SYNC_BLOCK_TIME); at=""
    [ -n "$bt" ] && at=$(date -d "@$bt" '+%a %d %b %H:%M')
    if [ "$(v SYNC_STALE)" = "yes" ]; then
      printf '🔄 **catching up** · RPC busy, numbers will refresh shortly\n'
      return
    fi
    printf '🔄 **catching up %s%%** · at %s · %s/%s blocks · %s b/s · done ~%s\n' \
      "$pct" "${at:-?}" "$(comma "$dn")" "$(comma "$tot")" "${rate:-?}" \
      "$(date -d "+$secs seconds" '+%H:%M %a')"
  else
    printf '▶️ **phase %s of 7** · %s\n' "$phase" "$(printf '%s' "$out" | sed -n 's/^NEXT: //p')"
  fi
}

if [ "${1:-}" = "--line" ]; then render_line; exit 0; fi

if [ "${1:-}" = "--md" ]; then render_md "$@"; exit 0; fi
if [ "${1:-}" = "--watch" ]; then
  render; last=$(cat "$ROOT/.tn-phase" 2>/dev/null)
  while sleep 20; do
    render; now=$(cat "$ROOT/.tn-phase" 2>/dev/null)
    [ "$now" != "$last" ] && { printf '   %sphase changed %s -> %s%s\n\n' "$G" "$last" "$now" "$R"; break; }
  done
else
  render
fi

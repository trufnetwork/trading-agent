#!/usr/bin/env bash
# Resolve the ports this deployment uses, and remember them.
#
#   scripts/ports.sh            # resolve (idempotent), print the result
#   scripts/ports.sh --force    # re-resolve from scratch
#
# Upstream defaults are used whenever they are free. Kwil-family nodes all
# default to the same three ports, so if another node is already running we
# step to the next free port rather than silently sharing its database.
#
# The result is written to .tn-env at the repo root. Every other script reads
# that file, so a later session resumes against the same deployment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ROOT/.tn-env"

in_use(){ ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
pick(){ local p=$1; while in_use "$p"; do p=$((p+1)); done; printf '%s' "$p"; }

if [ "${1:-}" = "--force" ]; then rm -f "$ENVF"; fi

# A Unix socket path is limited to about 107 characters. The natural home for
# the admin socket is inside the node root, but a deep checkout pushes that
# past the limit and kwild then fails to bind. Fall back to a short /tmp path
# keyed to this checkout, so two deployments still cannot collide.
SOCK="$ROOT/tn-node/admin.socket"
if [ ${#SOCK} -gt 100 ]; then
  SOCK="/tmp/tn-admin-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1).sock"
fi

CFG="$ROOT/tn-node/config.toml"

if [ -f "$ENVF" ]; then
  echo "using existing $ENVF"
  grep -q '^TN_ADMIN_SOCKET=' "$ENVF" || echo "TN_ADMIN_SOCKET=$SOCK" >> "$ENVF"
elif [ -f "$CFG" ]; then
  # A node is already configured. Adopt ITS ports, never re-pick, or a later
  # session would talk to a different database than the one the node writes.
  PG=$(awk '/^\[db\]/{f=1;next}/^\[/{f=0}f&&/^ *port/{gsub(/[^0-9]/,"");print;exit}' "$CFG")
  RPC=$(awk '/^\[rpc\]/{f=1;next}/^\[/{f=0}f&&/^ *listen/{n=split($0,a,":");gsub(/[^0-9]/,"",a[n]);print a[n];exit}' "$CFG")
  P2P=$(awk '/^\[p2p\]/{f=1;next}/^\[/{f=0}f&&/^ *listen/{n=split($0,a,":");gsub(/[^0-9]/,"",a[n]);print a[n];exit}' "$CFG")
  {
    echo "# Adopted from tn-node/config.toml by scripts/ports.sh."
    echo "TN_PGPORT=${PG:-5432}"
    echo "TN_RPC_PORT=${RPC:-8484}"
    echo "TN_P2P_PORT=${P2P:-6600}"
    echo "TN_ADMIN_SOCKET=$SOCK"
  } > "$ENVF"
  echo "  adopted ports from an existing node config"
else
  PG=$(pick 5432); RPC=$(pick 8484); P2P=$(pick 6600)
  {
    echo "# Written by scripts/ports.sh. Delete to re-resolve."
    echo "TN_PGPORT=$PG"
    echo "TN_RPC_PORT=$RPC"
    echo "TN_P2P_PORT=$P2P"
    echo "TN_ADMIN_SOCKET=$SOCK"
  } > "$ENVF"
  for pair in "5432:$PG:postgres" "8484:$RPC:rpc" "6600:$P2P:p2p"; do
    d=${pair%%:*}; rest=${pair#*:}; got=${rest%%:*}; name=${rest##*:}
    [ "$d" != "$got" ] && echo "  note: $name default $d was in use, chose $got"
  done
fi
cat "$ENVF" | grep -v '^#'

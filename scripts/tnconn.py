"""Connection settings for the local node, resolved once and shared.

Precedence: environment variable, then .tn-env at the repo root, then the
upstream default. .tn-env is written by scripts/ports.sh, which uses the
default port whenever it is free and steps to the next free one when it is not.
"""
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _from_file():
    f = ROOT / ".tn-env"
    out = {}
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip("\"'")
    return out


_FILE = _from_file()


def setting(key, default):
    return os.environ.get(key) or _FILE.get(key) or default


PGHOST = setting("TN_PGHOST", "127.0.0.1")
PGPORT = setting("TN_PGPORT", "5432")
PGUSER = setting("TN_PGUSER", "postgres")
PGDB = setting("TN_PGDB", "kwild")
RPC = setting("TN_RPC", "http://127.0.0.1:" + setting("TN_RPC_PORT", "8484"))

PSQL = ["psql", "-h", PGHOST, "-p", PGPORT, "-U", PGUSER, "-d", PGDB, "-tAX"]

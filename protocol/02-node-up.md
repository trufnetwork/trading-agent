# Step 2 — Postgres + node running on mainnet

## 2.0 Check for port conflicts FIRST

This step cost a failed launch. Before starting anything:

```bash
ss -tlnp | grep -E ':8484|:6600|:5432'
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'
```

Kwil-family nodes default to **8484** (RPC), **6600** (P2P) and **5432**
(Postgres). If any other Kwil/TN/branch node is already running, all three
collide. On this machine a `branchd` node and a `kwil-postgres` container
already held all three.

A collision is not always obvious: a second Postgres container will still
*start* without its port published, and `psql -h 127.0.0.1 -p 5432` then
silently connects to **the other node's database**. Always confirm which
instance answered:

```bash
docker port <container>    # empty output = port NOT published
```

### Ports used by this deployment (side-by-side, defaults in parentheses)

| Service | Port | Default |
|---------|------|---------|
| Postgres | 5433 | 5432 |
| Node RPC | 127.0.0.1:8485 | 0.0.0.0:8484 |
| P2P | 0.0.0.0:6601 | 0.0.0.0:6600 |
| Admin socket | `<root>/admin.socket` | `/tmp/kwild.socket` |

## 2.1 Start Postgres

Use the **pinned** image, not `:latest` — the guide says `:latest`, but compose
pins `16.8-2`, and a protocol should not drift under you.

```bash
docker run -d --name tn-postgres \
  -p 127.0.0.1:5433:5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v tn-pgdata:/var/lib/postgresql/data \
  --shm-size=2gb --restart unless-stopped \
  ghcr.io/trufnetwork/kwil-postgres:16.8-2
```

Never publish Postgres on a public interface. `127.0.0.1` is deliberate.

Verify it is **yours** and published:

```bash
docker port tn-postgres        # => 5432/tcp -> 127.0.0.1:5433
psql -h 127.0.0.1 -p 5433 -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;"
```

A fresh instance lists exactly: `kwil_test_db`, `kwil_test_db2`, `kwild`,
`postgres`. The image ships a `kwild` superuser role and `kwild` database
already — kwild's default `[db]` config expects them, so no setup needed.

## 2.2 Initialize node config against mainnet genesis

```bash
git clone https://github.com/trufnetwork/truf-node-operator.git

kwild setup init \
  --genesis .../truf-node-operator/configs/network/v2/genesis.json \
  --root ~/dev/agentic-truf/tn-node \
  --p2p.bootnodes "4e0b5c952be7f26698dc1898ff3696ac30e990f25891aeaf88b0285eab4663e1#ed25519@node-1.mainnet.truf.network:26656,0c830b69790eaa09315826403c2008edc65b5c7132be9d4b7b4da825c2a166ae#ed25519@node-2.mainnet.truf.network:26656" \
  --state-sync.enable \
  --state-sync.trusted-providers "4e0b5c952be7f26698dc1898ff3696ac30e990f25891aeaf88b0285eab4663e1#ed25519@node-1.mainnet.truf.network:26656"
```

Produces `config.toml`, `genesis.json`, `nodekey.json` in the root dir.

**Verify the genesis is really mainnet** — `setup init` will happily generate a
config for a brand-new single-validator network if the genesis is wrong:

```bash
grep -E '"chain_id"|"initial_height"' tn-node/genesis.json
# => "chain_id": "tn-v2.1",  "initial_height": 195391
diff <(jq -S . tn-node/genesis.json) \
     <(jq -S . .../configs/network/v2/genesis.json)   # must be identical
```

`nodekey.json` is this node's private identity key (mode 0600). Do not read,
copy or commit it.

## 2.3 Adjust config.toml

```toml
[db]
port = '5433'
[rpc]
listen = '127.0.0.1:8485'
[p2p]
listen = '0.0.0.0:6601'
[admin]
listen = '<root>/admin.socket'
```

### Deviation: `--rpc.private` not enabled

The operator guide passes `--rpc.private`, which requires challenge
authentication on every call — correct for an internet-facing node. This node
binds RPC to `127.0.0.1` only and is consumed locally by the SDK, so private
mode adds signing overhead with no benefit. **If this node is ever exposed
beyond loopback, turn `private` back on.**

## 2.4 Start

```bash
nohup kwild start --root ~/dev/agentic-truf/tn-node > kwild-run.log 2>&1 &
```

Log unfiltered to a file — piping through `tail`/`grep` at write time buffers
output and hides progress, and masks the exit code.

## 2.5 Verify state sync began

```bash
grep STATESYNC kwild-run.log | tail -20
```

Expected sequence: `Discovering snapshots` → `Discovered snapshot` (several
heights) → `verified snapshot with trusted provider` → `Starting chunk
download`.

Observed 2026-09-17: snapshot height **2543774**, 203 chunks, **3.23 GB**,
served by one provider. Chain tip at the time was 2611936, so ~68k blocks of
replay follow the restore.

`verified snapshot with trusted provider` is the security-critical line. Without
it, the node accepted a snapshot nobody vouched for.

## Status

| Item | State |
|------|-------|
| Postgres 16.8 on 5433 | running, verified ours |
| Node config | mainnet genesis, byte-identical to operator repo |
| kwild process | running, 6 peers |
| State sync | downloading 203 chunks |
| Height at tip | pending — step 3 |

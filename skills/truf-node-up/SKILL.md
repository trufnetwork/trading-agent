---
name: truf-node-up
description: >
  Install and run a TRUF.NETWORK mainnet node locally, then verify it is synced
  and reading the right chain. Use when setting up a node from scratch, when a
  node will not start or stay synced, or before any task that reads market data
  from a local Postgres. Covers the PG16 client requirement, port collisions
  with other Kwil nodes, state sync verification, and sync-time expectations.
---

# Bring up a TRUF.NETWORK node

Goal: a local node synced to mainnet tip, with its Postgres readable by you.

Target: mainnet, chain id `tn-v2.1`.

**Budget real time for this.** Measured end to end on a cleared machine, about
5 hours: 18 minutes downloading 3.0 GB, 39 minutes loading it into Postgres, and
3h 30m replaying 73,000 blocks.

Throughput during the replay swings by more than twenty times, from 2.6 blocks
per second on ordinary blocks to 0.1 on blocks carrying `tn_digest` work. Average
over the whole run rather than sampling twice, or the estimate is meaningless.

**The RPC stops answering while the node replays hard.** That is neither a stall
nor a crash. Count `Committed Block` lines in the log instead.

## 1. Install kwild from a release, not from source

The operator guide recommends building from source. Prefer the release. It is
reproducible, needs no Go toolchain, and pins an exact version.

Resolve the newest release rather than hardcoding one. Releases land every few
weeks, so a pinned version in a document is stale before anyone reads it.

```bash
V=$(gh release list --repo trufnetwork/node --limit 1 --json tagName --jq '.[0].tagName')
echo "installing $V"
gh release download "$V" --repo trufnetwork/node \
  --pattern "tn_${V#v}_linux_amd64.tar.gz" --dir dist
tar -xzf "dist/tn_${V#v}_linux_amd64.tar.gz" -C dist
install -D dist/kwild ~/.local/bin/kwild
```

Verified on v2.5.8 and v2.6.0.

Three things that mislead:

- The archive contains **only `kwild`**. There is no `kwil-cli` in the TN
  release, and you do not need one to sync or to read the database.
- `kwild version` reports the **framework** version, such as 0.10.1, not the TN
  release version. Do not use it to confirm which release you installed.
- **The running binary may be named for its version.** A 2.6.0 install can
  appear in the process table as `kwild-2.6.0`, so anything matching on the
  process name needs to allow a suffix. `scripts/status.sh` reported a healthy
  node as not running until this was fixed.

## 2. Postgres client tools must be major version 16

kwild checks `pg_dump` and `psql` at startup and **refuses to start unless the
major version is 16.x**. State sync shells out to them to restore the snapshot,
so they are required even though the server itself runs in Docker.

Most current distributions ship 17 or 18, which kwild rejects. Add the PGDG
repository and install the 16 client.

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
. /etc/os-release
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update && sudo apt-get install -y postgresql-client-16
pg_dump --version && psql --version    # both must report 16.x
```

This needs interactive sudo, so a human runs it. `config.toml` exposes
`skip_dependency_verification`, but skipping only moves the failure from startup
to restore time. Install the real client.

## 3. Check for port collisions BEFORE starting anything

This is the step that silently corrupts everything downstream.

```bash
ss -tlnp | grep -E ':8484|:6600|:5432'
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'
```

Kwil-family nodes all default to **8484** RPC, **6600** P2P, and **5432**
Postgres. If another Kwil, TN, or branch node is running, all three collide.

**A Postgres collision does not announce itself.** A second container starts
happily without publishing its port, and `psql -h 127.0.0.1 -p 5432` then
connects to *the other node's database*. You will read plausible data from the
wrong chain. Always confirm which instance answered:

```bash
docker port <container>    # empty output means the port is NOT published
```

Let the tooling resolve this rather than choosing by hand.

```bash
scripts/ports.sh        # defaults when free, next free port when not
```

It uses **5432, 8484, and 6600 whenever they are available**, steps to the next
free port when they are not, and records the result in `.tn-env`. Every script
in this repo reads that file, so a later session resolves to the same
deployment.

If a node is already configured it adopts the ports from `tn-node/config.toml`
instead of picking again, which is what makes resuming safe.

Keep the admin socket inside the node root, `<root>/admin.socket`, rather than
the `/tmp/kwild.socket` default, for the same collision reason.

## 4. Start Postgres

Pin the image. The guide says `:latest`, but a protocol should not drift under
you.

```bash
docker run -d --name tn-postgres \
  -p 127.0.0.1:$(grep TN_PGPORT .tn-env | cut -d= -f2):5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -v tn-pgdata:/var/lib/postgresql/data \
  --shm-size=2gb --restart unless-stopped \
  ghcr.io/trufnetwork/kwil-postgres:16.8-2
```

Bind to `127.0.0.1` deliberately. Trust authentication on a public interface
hands over the database.

**Wait for it.** The container is not ready when `docker run` returns, and a
check in the gap reports no database at all, which reads as a failure.

```bash
PGPORT=$(grep TN_PGPORT .tn-env | cut -d= -f2)
for i in $(seq 1 30); do
  psql -h 127.0.0.1 -p "$PGPORT" -U postgres -d kwild -tAc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
docker port tn-postgres     # confirm it is published where you expect
psql -h 127.0.0.1 -p "$PGPORT" -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;"
```

A fresh instance lists exactly `kwil_test_db`, `kwil_test_db2`, `kwild`, and
`postgres`. The image ships the `kwild` role and database that the default
config expects, so there is nothing to create.

## 5. Initialize against mainnet genesis

Clone the config repo **outside this checkout**, or it becomes an untracked
directory inside it.

```bash
TN_OPERATOR="$(dirname "$(pwd)")/truf-node-operator"
git clone https://github.com/trufnetwork/truf-node-operator.git "$TN_OPERATOR"

kwild setup init \
  --genesis "$TN_OPERATOR/configs/network/v2/genesis.json" \
  --root ./tn-node \
  --p2p.bootnodes "4e0b5c952be7f26698dc1898ff3696ac30e990f25891aeaf88b0285eab4663e1#ed25519@node-1.mainnet.truf.network:26656,0c830b69790eaa09315826403c2008edc65b5c7132be9d4b7b4da825c2a166ae#ed25519@node-2.mainnet.truf.network:26656" \
  --state-sync.enable \
  --state-sync.trusted-providers "4e0b5c952be7f26698dc1898ff3696ac30e990f25891aeaf88b0285eab4663e1#ed25519@node-1.mainnet.truf.network:26656"
```

`configs/network/v2` is **mainnet**. The `testnet-v1` and `staging` directories
also exist and look equally plausible.

**Verify the genesis is really mainnet.** `setup init` will cheerfully generate
a config for a brand new single-validator network if you point it at the wrong
file, and that network will sync instantly and contain nothing.

```bash
grep -E '"chain_id"|"initial_height"' tn-node/genesis.json
# => "chain_id": "tn-v2.1",  "initial_height": 195391
diff <(jq -S . tn-node/genesis.json) \
     <(jq -S . "$TN_OPERATOR/configs/network/v2/genesis.json")
```

`nodekey.json` is this node's private identity, mode 0600. Do not read, copy, or
commit it.

### Fix two insecure defaults before starting. Not optional.

`setup init` generates `listen = '0.0.0.0:8484'` for the RPC. This protocol
deliberately does not pass `--rpc.private`, which would require challenge
authentication on every call and is the right choice for an internet-facing
node. **The two together publish an unauthenticated RPC to the network**, so the
RPC must be bound to loopback.

The admin socket also defaults to `/tmp/kwild.socket`, which collides with any
other Kwil node on the machine for the same reason the ports do.

```bash
RPCPORT=$(grep TN_RPC_PORT .tn-env | cut -d= -f2)
sed -i "s|^listen = '0.0.0.0:$RPCPORT'|listen = '127.0.0.1:$RPCPORT'|" tn-node/config.toml
sed -i "s|^listen = '/tmp/kwild.socket'|listen = '$(pwd)/tn-node/admin.socket'|" tn-node/config.toml
grep -nE "^ *(port|listen) *=" tn-node/config.toml     # verify
```

**Only change the ports if they differ from what was generated.** When the
defaults were free, `setup init` already wrote exactly the ports in `.tn-env`
and there is nothing to edit. The node and the scripts have to agree, so read
the values rather than retyping them.

```toml
[db]
port = '<TN_PGPORT>'
[rpc]
listen = '127.0.0.1:<TN_RPC_PORT>'
[p2p]
listen = '0.0.0.0:<TN_P2P_PORT>'
[admin]
listen = '<root>/admin.socket'
```

**If you ever expose this node beyond loopback, turn `--rpc.private` back on.**
The loopback bind above is the only thing standing between an open RPC and the
network.

## 6. Start and verify state sync

```bash
TN_HOME=$(pwd)
setsid nohup kwild start --root "$TN_HOME/tn-node" \
  > "$TN_HOME/kwild-run.log" 2>&1 < /dev/null &
```

`setsid` and absolute paths both matter. A plain `nohup ... &` started inside an
agent tool call does not reliably outlive it, and a relative path resolves
against a working directory that may have changed.

Log unfiltered to a file. Piping through `tail` or `grep` at write time buffers
the output, hides progress, and masks the exit code.

```bash
grep STATESYNC kwild-run.log | tail -20
```

Expect `Discovering snapshots`, then `Discovered snapshot`, then **`verified
snapshot with trusted provider`**, then `Starting chunk download`.

That verified line is the security-critical one. Without it the node accepted a
snapshot nobody vouched for.

## 7. Confirm you reached the real tip

Find the target, then compare.

```bash
curl -s http://node-1.mainnet.truf.network:8484/api/v1/health | jq .
```

Check your own height the same way against your RPC port. The chain is moving,
so "synced" means you are within a few blocks and keeping pace, not equal to a
number you recorded an hour ago.

`gas: false` on mainnet means transactions carry no gas fee. The prediction
market protocol charges its own fees separately and that is unrelated.

### If sync never starts

The errors point at snapshots. The cause is usually peers.

```
STATESYNC: Statesync exhausted its retries, falling back to block sync
           {retries=4 snapshots_discovered=0 trusted_providers=1}
node stopped with error: snapshot file not provided
```

**Check peer connections first.** `scripts/status.sh` reports `SYNC_PEERS_OK`.
If it is zero, nothing downstream matters and tuning `discovery_time` is wasted
effort.

```bash
grep -c 'Connected to peer' kwild-run.log     # successes
grep -c 'failed to connect to' kwild-run.log  # failures
```

**Testing the port proves nothing.** A raw TCP connection to a bootnode
succeeds even while every dial fails, because the remote accepts the socket and
then never completes the libp2p handshake. Each dial then burns the full 15
second timeout.

**kwild will not tell you why a dial failed.** `CompressDialError` keeps the
addresses and discards the per-address causes, at every log level. The only way
to see the real error is libp2p's own logger.

```bash
GOLOG_LOG_LEVEL="swarm2=debug,tcp-tpt=debug" kwild start --root ./tn-node
```

**What to do.** Add another bootnode you trust, to both `bootnodes` and
`trusted_providers`. Then wait rather than restarting in a loop, because a
teardown and retry cycle costs a minute of dial timeouts each time and fixes
nothing when the remote is the problem.

Observed on 2026-09-18: five consecutive attempts failed with zero peers, then
the same configuration connected and pulled all three snapshots. Nothing local
changed.

## Operational notes

**Keeping up with the chain is nearly free.** Steady-state CPU for the node and
Postgres together sits at 0.15% to 0.25%. If you measure high CPU, suspect your
own abandoned query first. Cancelling a client does not stop the backend:

```sql
SELECT pg_cancel_backend(pid) FROM pg_stat_activity
 WHERE state = 'active' AND query NOT ILIKE '%pg_stat_activity%';
```

**Background jobs started inside an agent tool call do not survive it.** Use
`setsid` for anything that must outlive the call, and add a health check that
proves the process is still alive rather than assuming it.

**Trust the live schema over the migration files.** Migrations show intent and
the database shows reality. Run `\d main.<table>` before writing a query against
a table you have not inspected in this session.

## Evidence

- [protocol/01-prerequisites.md](../../protocol/01-prerequisites.md)
- [protocol/02-node-up.md](../../protocol/02-node-up.md)
- [protocol/08-operations.md](../../protocol/08-operations.md)
- [protocol/findings-blocksync-latency.md](../../protocol/findings-blocksync-latency.md)

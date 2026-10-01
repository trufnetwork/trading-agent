# Step 1 — Prerequisites

Goal: a `kwild` binary and the Postgres client tools it checks for at startup.

Target network: TRUF.NETWORK mainnet, chain id `tn-v2.1`.

## 1.1 Verify what's already present

```bash
docker --version          # need Docker + compose plugin
docker compose version
go version                # only needed if building from source (we don't)
```

Verified on this machine 2026-09-17: Docker 29.1.3, Compose 2.40.3, Go 1.26.0.
Free disk 355G, RAM 14G.

## 1.2 Install kwild from a release (NOT from source)

The node operator guide labels "build from source" as recommended. Prefer the
release download: it is reproducible, needs no Go toolchain, and pins an exact
version.

```bash
gh release list --repo trufnetwork/node --limit 5
gh release download v2.5.8 --repo trufnetwork/node \
  --pattern "tn_2.5.8_linux_amd64.tar.gz" --dir dist
tar -xzf dist/tn_2.5.8_linux_amd64.tar.gz -C dist
install -D dist/kwild ~/.local/bin/kwild
```

Verify:

```bash
kwild version   # => Version: 0.10.1, go1.25.3, linux/amd64
```

### Gotchas found

- The archive contains **only `kwild`**. There is no `kwil-cli` in the TN
  release; it ships from the `trufnetwork/kwil-db` repo instead. Not needed for
  syncing or for reading the DB.
- `kwild version` reports the **framework** version (0.10.1), not the TN release
  version (2.5.8). Don't use it to confirm which TN release you have.
- The guide says `sudo mv kwild /usr/local/bin/`. `~/.local/bin` works without
  sudo and is already on PATH on this machine.

## 1.3 Postgres client tools — must be major version 16

kwild verifies `pg_dump` and `psql` at startup and **fails if the major version
is not 16.x** (`app/node/build.go:755` in kwil-db). State sync uses these to
restore the snapshot, so they are required even though Postgres itself runs in
Docker.

Ubuntu 26.04's default `postgresql-client` is **18**, which kwild rejects. The
PGDG repo is required to get 16:

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
. /etc/os-release
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update
sudo apt-get install -y postgresql-client-16
```

Verify:

```bash
pg_dump --version   # must report 16.x
psql --version      # must report 16.x
```

Requires interactive sudo, so the operator runs this, not the agent.

### Escape hatch (not recommended)

`config.toml` exposes `skip_dependency_verification`, plus `pg_dump_path` and
`psql_path` overrides. Skipping the check lets kwild start, but state sync will
then fail at restore time instead of at startup. Prefer real PG16 clients.

## 1.4 Network config repo

```bash
git clone https://github.com/trufnetwork/truf-node-operator.git
```

Mainnet config lives at `configs/network/v2/`:

- `genesis.json` — chain id `tn-v2.1`, initial height 195391
- `network-nodes.csv` — seed node addresses

`configs/network/testnet-v1/` and `staging/` also exist. **`v2` is mainnet.**

## 1.5 Confirm the sync target before starting

```bash
curl -s http://node-1.mainnet.truf.network:8484/api/v1/health | jq .
```

Observed 2026-09-17: height **2611936**, `chain_id: tn-v2.1`, `syncing: false`,
`gas: false`.

`gas: false` means no gas fees on transactions. The prediction market protocol
charges its own fees separately — that is unrelated to gas.

Record this height. Step 3 is not complete until the local node reaches it.

## Status

| Item | State |
|------|-------|
| Docker + Compose | present |
| kwild 2.5.8 | installed, `kwild version` passes |
| truf-node-operator config | cloned, mainnet genesis present |
| Mainnet reachable | yes, height 2611936 |
| psql / pg_dump 16 | **BLOCKED — needs operator sudo** |

# Troubleshooting

Symptoms first. Each entry says what is actually happening, not just what to
type.

## Sync

### The node is stuck at a block height

Check peers before anything else — isolation is far more common than a broken
daemon.

```bash
docker compose exec verus verus getpeerinfo | jq length
docker compose exec verus verus getblockchaininfo | jq '{blocks, headers}'
```

| What you see | Meaning |
| --- | --- |
| `headers` far ahead of `blocks` | Normal. It knows the chain and is validating through it. |
| Both frozen, peers > 0 | Possibly wedged. Restart cleanly and watch the logs. |
| Both frozen, peers = 0 | Network problem. See below. |

### Zero peers

Almost always the P2P port. The daemon needs **outbound** connectivity to sync
at all, and **inbound** connectivity to sync at a reasonable speed — without it
you are limited to a handful of outbound peers.

```bash
# Is the P2P port published?
docker compose ps
# Can the container reach the internet?
docker compose exec verus curl -sI https://verus.io | head -1
```

Publish P2P (27485 mainnet, 18842 testnet) and open it in your firewall. Every
example in this repository publishes P2P and withholds RPC, which is the correct
way round.

To prime peering manually:

```bash
docker compose exec verus verus addnode <ip>:27485 onetry
```

In Kubernetes, check the NetworkPolicy is not blocking egress, and that the P2P
Service sets `publishNotReadyAddresses: true` — a syncing node is exactly the
one that needs peers.

### Sync is extremely slow

Usually IOPS, not bandwidth. Block validation is random reads against LevelDB.

- Local SSD or NVMe. Network storage with a low IOPS allowance turns days into
  weeks.
- Check you have not set `MAX_CONNECTIONS` low. It is useful in CI, harmful in
  production.
- Consider a bootstrap for the initial sync (see below).

## RPC

### `connection refused` from another container

The RPC listener is bound inside the container network and the port is
deliberately not published.

```bash
# From another container on the same network — this is the intended path
curl -s --user "$USER:$PASS" --data '{"method":"getinfo"}' http://verus:18843/
```

Check the service name, and check the port matches the chain: **18843 testnet,
27486 mainnet**. Note that `8232` is Zcash's port and appears in a lot of
copied-around Verus configuration — it is wrong for Verus.

### `connection refused` from the host

Expected. The RPC port is not published by default and should stay that way. For
development only, bind to loopback:

```yaml
ports:
  - "127.0.0.1:18843:18843"
```

### `401 Unauthorized`

Credentials are generated per data volume. A fresh volume means fresh
credentials.

```bash
docker compose exec verus cat /home/verus/.komodo/vrsctest/rpc-credentials
```

If you set `RPC_USER`/`RPC_PASSWORD` *after* the first start, they were ignored:
the config is written once and never overwritten. Either use the values in the
file, or delete `<chain>.conf` and restart to regenerate it.

### The `verus` command needs no flags — but mine does

Inside the container, `verus getinfo` works because a wrapper on `PATH` injects
`-chain`. If you are calling `/opt/verus-cli/verus` directly you get the raw
client and must pass `-chain=` yourself.

## Volumes and permissions

### `Permission denied` creating the data directory

You are using a **host bind mount**. Named volumes inherit ownership from the
image; bind mounts keep the host's.

```bash
# Option 1: fix ownership on the host
sudo chown -R 1000:1000 /path/to/data

# Option 2: start as root and let the entrypoint remap and drop privileges
docker run --user 0:0 -e PUID=$(id -u) -e PGID=$(id -g) ...
```

The container never *requires* root — that path exists only to fix ownership,
and privileges are dropped before the daemon starts.

### Kubernetes volume permission errors

`fsGroup: 1000` should handle it, and the shipped manifests set it. Some CSI
drivers ignore `fsGroup`; if yours does, use an init container to `chown`, or
run with `PUID`/`PGID`.

## Memory and crashes

### The container is OOM-killed

```bash
docker inspect verus --format '{{.State.OOMKilled}}'
```

verusd wants roughly **12 GiB at the mainnet chain tip**. Set the limit to
16 GiB. Testnet is happy with 4–8 GiB.

Two things that surprise people:

- **Initial sync uses less memory than steady state.** A node that synced fine
  can be OOM-killed weeks later on reaching the tip.
- **An OOM kill often lands mid-flush**, which corrupts chain state. Fix the
  limit *and* check for corruption afterwards.

Adding swap is a legitimate mitigation. Slow beats killed.

## Database corruption

### `Corruption: block checksum mismatch` or a forced reindex

Caused by a hard kill or an OOM during a flush.

```bash
# Back up the wallet FIRST — it lives in the same volume
docker compose exec verus verus backupwallet emergency
docker compose cp verus:/home/verus/.komodo/VRSC/emergency ./wallet-emergency.dat

docker compose down
docker volume rm <project>_verus-data-vrsc
# restart with USE_BOOTSTRAP=true to re-seed
```

Then fix the cause, or it recurs:

- Raise `stop_grace_period` / `terminationGracePeriodSeconds`. 120s is a floor;
  a synced mainnet node may want far more.
- Raise the memory limit.
- Never `docker kill` a Verus node.

### Every restart triggers a reindex

Check you are not passing `-bootstrap` via `EXTRA_ARGS`. The daemon's own
`-bootstrap` flag is **unconditional and destructive on every start** — it
deletes `blocks`, `chainstate`, `notarisations`, `peers.dat` and `komodostate`,
and forces `-zappwallettxes=2`. This image never passes it and implements its
own verified, first-run-only fetcher instead.

Also note that changing `-idindex` or `-insightexplorer` on an existing chain
forces a reindex by design.

### `set addressindex, will reindex` on first start

Normal and unavoidable. verusd forces `addressindex` and `spentindex` on
regardless of configuration. On an empty data directory this completes
instantly.

## Bootstrap

### `checksum sidecar did not contain a SHA-256 line`

The server returned an error page instead of a checksum. `bootstrap.verus.io`
answers **HTTP 403 to a default curl User-Agent**; this image sends a browser
User-Agent and validates the response is really a checksum line rather than
comparing against an HTML error page.

If you set a custom `BOOTSTRAP_URL`, confirm a `<url>.sha256sum` exists next to
the archive.

### `TLS certificate verification failed`

Some third-party bootstrap hosts serve expired certificates — notably
`bootstrap.dexstats.info`, which the daemon has compiled in. This project ships
`chains/*.json` pointing at a host with valid TLS instead, so you should only
see this if you set `BOOTSTRAP_URL` yourself. See
[docs/pbaas.md](pbaas.md#a-note-on-the-other-host).

`BOOTSTRAP_INSECURE_TLS=true` proceeds anyway. The SHA-256 check still runs, so
corruption is still caught — but the server's identity is not authenticated.
Decide knowingly.

### Bootstrap seems to be ignored

It only runs when the data directory has no `blocks/` or `chainstate/`. On an
existing volume it is skipped by design, and the log says so.

## PBaaS

### `Cannot find blockchain data`

The single most common PBaaS error, and the message is unhelpful. It means the
daemon could not reach the **root chain** to resolve the chain definition.

This image checks for that before starting the daemon and tells you what is
wrong. Verify:

- `ROOT_RPC_HOST` / `ROOT_RPC_PORT` point at a reachable VRSC node
- `ROOT_RPC_USER` / `ROOT_RPC_PASSWORD` match that node's credentials
- The root node is **synced**, not merely running
- `ROOT_WAIT_TIMEOUT` is generous — a mainnet sync takes a long time

See [pbaas.md](pbaas.md).

### `ROOT_RPC_URL uses https://, which cannot work`

Correct, and not a bug in this image. verusd performs the root lookup itself
over plain HTTP to a `host:port` pair; it cannot speak TLS. A public gateway
such as `https://api.verus.services` therefore cannot be a PBaaS root. Use your
own node over a private network.

### `set P2P_PORT and RPC_PORT for chain ...`

PBaaS P2P ports are derived by the daemon from a CRC32 over the chain
definition, so they are not predictable. Pin both explicitly. Suggested values
per chain are in `chains/*.json`.

## Parameters

### Download fails or is very slow

~740 MB from `https://verus.io/zcparams`, fetched once and shared by every
chain on the host.

```bash
docker compose exec verus ls -la /home/verus/.zcash-params
```

Use a mirror with `PARAMS_SOURCE`, or pre-populate the volume in air-gapped
setups. Each file is SHA-256 verified against the value pinned in the daemon's
own source, so a partial download fails loudly rather than producing a daemon
that will not start.

## Architecture

### arm64

Verus publishes official Linux arm64 binaries, and this image uses them. A
testnet node has been verified end to end on Apple Silicon: it syncs, peers,
shuts down cleanly and restarts without reindexing.

Note the release asset uses the token `arm64`, not `aarch64`, if you are
scripting against upstream yourself.

### Alpine or musl

Will not work. The upstream binaries need `GLIBC_2.28` and `GLIBCXX_3.4.22`.
This image is Debian-based for that reason.

## Getting help

Before opening an issue, collect:

```bash
docker compose exec verus verus getinfo
docker compose exec verus healthcheck.sh
docker compose logs --tail 100 verus
docker inspect verus --format '{{.Config.Image}} {{.State.Status}} OOMKilled={{.State.OOMKilled}}'
```

Then use the bug report template, which asks for exactly those. Questions rather
than bugs are better suited to GitHub Discussions.

# Quickstart

From nothing to a working Verus RPC endpoint, then a fork in the road depending
on why you are here.

## Prerequisites

Docker with Compose v2 (`docker compose version` should print `v2.x`), and `jq`
if you want to pretty-print RPC output.

Disk: budget **~20 GB** for a fully synced testnet node, plus ~740 MB once for
the Zcash parameters, which every chain on the host then shares. A few GB is
enough to get started, but the node keeps growing — running out mid-sync
corrupts the database.

## Start a testnet node

```bash
git clone https://github.com/chainvue/verus-docker
cd verus-docker
docker compose -f examples/compose.testnet.yml up -d
```

Watch it come up:

```bash
docker compose -f examples/compose.testnet.yml logs -f
```

The first start does three things, in this order:

```
2026-07-26T18:19:36Z [INFO ] RPC access restricted to the container network: 172.17.0.0/16
2026-07-26T18:19:36Z [INFO ] Generated random RPC credentials.
2026-07-26T18:19:36Z [INFO ] They are stored in the data volume at: /home/verus/.komodo/vrsctest/rpc-credentials
2026-07-26T18:19:36Z [INFO ] wrote a new configuration file: /home/verus/.komodo/vrsctest/vrsctest.conf
2026-07-26T18:19:36Z [INFO ] Fetching Zcash parameters (about 740 MB, one time, shared by every chain).
2026-07-26T18:19:58Z [INFO ] Zcash parameters ready.
```

then a banner, then the daemon:

```
  ┌───────────────────────────────────────────────────────────────┐
  │  verus-docker — production Verus nodes in containers          │
  └───────────────────────────────────────────────────────────────┘
    chain          : VRSCTEST (testnet)
    verusd version : v1.2.17-2
    data directory : /home/verus/.komodo/vrsctest
    rpc endpoint   : http://0.0.0.0:18843 (inside the container network)
    p2p port       : 18842
    running as     : uid 1000, gid 1000
```

Total time to a responding RPC: **about a minute**, most of it the parameter
download. It is faster on every subsequent node, because the parameters live on
a shared volume.

## Talk to it

```bash
./scripts/verus-cli.sh -f examples/compose.testnet.yml getinfo
```

```json
{
  "version": 2000753,
  "VRSCversion": "1.2.17-2",
  "blocks": 716,
  "connections": 1,
  "name": "VRSCTEST",
  "chainid": "iJhCezBExJHvtyH3fGhNnt2NhU4Ztkf2yq"
}
```

That works with no arguments and no configuration because the image ships a
`verus` wrapper on `PATH` that injects the right `-chain` flag. `docker compose
exec verus verus getinfo` does the same thing.

## Is it healthy? Is it synced?

Two different questions, with two different answers:

```bash
docker compose -f examples/compose.testnet.yml exec verus healthcheck.sh
# syncing: block 716/7360 (0.06%), 1 peers      -> exit 0
```

**A node that is still syncing is healthy.** It is answering RPC and doing
exactly what it should. Only ask the second question when you need a node that
can give correct answers about the chain tip:

```bash
docker compose -f examples/compose.testnet.yml exec verus healthcheck.sh --require-synced
# exit 2 until fully caught up
```

Testnet takes a few hours to sync from genesis. You do not have to wait for it
to start building.

## Stopping

```bash
docker compose -f examples/compose.testnet.yml down
```

Compose waits for the grace period configured in the file (120s). **Do not
shorten it and do not `docker kill`.** verusd flushes its databases on exit;
interrupting that corrupts chain state and forces a reindex measured in hours.

---

## Where to go next

### If you are a developer

You want an RPC endpoint to build against.

**Runnable examples** live in [`examples/rpc/`](../examples/rpc/) — each one
connects, calls `getinfo` and `getblockchaininfo`, then fetches the current tip
block. All three read the generated credentials straight out of the container.

```bash
cd examples/rpc
./curl.sh                # works as-is: runs curl inside the container
```

`node.mjs` and `python.py` make the HTTP call from your machine, so they need a
reachable endpoint. The stacks deliberately do not publish one — add it to
`examples/compose.testnet.yml` first, bound to loopback:

```yaml
ports:
  - "127.0.0.1:18843:18843"
```

```bash
node node.mjs            # Node 18+, no dependencies
python3 python.py        # Python 3.9+, standard library only
```

Or open the devcontainer, where both are preconfigured against the node.

**Getting the credentials yourself:**

```bash
docker compose -f examples/compose.testnet.yml exec verus \
  cat /home/verus/.komodo/vrsctest/rpc-credentials
```

**Reaching the node from your own container** — put it on the same network and
use the service name. This is the intended pattern:

If your app lives in the *same* compose file, the service name just works. From
a *different* compose project, join the node's network explicitly:

```yaml
services:
  my-app:
    environment:
      VERUS_RPC_URL: http://verus:18843
    networks: [verus]

networks:
  verus:
    # Created by compose.testnet.yml, whose project name is verus-testnet.
    name: verus-testnet_default
    external: true
```

**Reaching it from the host.** The RPC port is deliberately not published. If
you need it during development, bind to loopback only — never `0.0.0.0`:

```yaml
ports:
  - "127.0.0.1:18843:18843"
```

**A devcontainer** is included: open the repository in VS Code, choose *Reopen
in Container*, and a testnet node comes up alongside your editor. See
[development.md](development.md).

Next: [pbaas.md](pbaas.md) if you are building against a PBaaS chain or need
cross-chain data.

### If you are an operator

You want a node that stays up and does not lose anything.

Read [production.md](production.md) before you deploy. It covers the things
that actually cause incidents: hardware sizing that accounts for indexes you
cannot disable, why the shutdown grace period matters, what to back up, and how
to upgrade without a surprise reindex.

Then, depending on what you are running:

| You want | Read |
| --- | --- |
| A staking node | [staking.md](staking.md) — different threat model entirely |
| Kubernetes | [kubernetes.md](kubernetes.md) — probes, PVC sizing, affinity |
| Alerting | [monitoring.md](monitoring.md) — exporter, dashboard, alert rules |
| Any PBaaS chain | [pbaas.md](pbaas.md) — needs a root node, read this first |

## Switching to mainnet

One environment variable, but understand what changes:

```bash
docker compose -f examples/compose.mainnet.yml up -d
```

| | Testnet | Mainnet |
| --- | --- | --- |
| Sync from genesis | hours | days |
| Bootstrap size | ~6.6 GB | ~22 GB |
| Disk | ~50 GB | ~150 GB and growing |
| RAM at chain tip | 4–8 GB | ~12 GB |
| Coins | worthless | real |

Read [production.md](production.md) first.

## Common first-run questions

**Nothing is happening for a minute after `up -d`.** The Zcash parameter
download. It is ~740 MB, happens once per host, and the logs show each file.

**`connections: 0`.** Peer discovery takes a moment. If it stays at zero for
more than a few minutes, the P2P port is probably blocked — see
[troubleshooting.md](troubleshooting.md).

**`blocks` is far behind `headers`.** Normal. Headers arrive first, then blocks
are downloaded and validated.

**Permission denied on a volume.** You are using a host bind mount. Use `PUID`
and `PGID`; see [troubleshooting.md](troubleshooting.md).

Anything else: [troubleshooting.md](troubleshooting.md).

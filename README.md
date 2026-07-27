# verus-docker

**Production-ready Docker images for Verus — mainnet, testnet, and every PBaaS chain.**

[![CI](https://github.com/chainvue/verus-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/chainvue/verus-docker/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/chainvue/verus-docker?sort=semver)](https://github.com/chainvue/verus-docker/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Verus](https://img.shields.io/badge/verusd-v1.2.17--2-blueviolet)](https://github.com/VerusCoin/VerusCoin/releases)

---

## ⚡ Quickstart

No clone, no config. A **testnet** node with an RPC endpoint on your machine:

```bash
docker run -d --name verus-node \
  -e CHAIN=VRSCTEST \
  -p 127.0.0.1:18843:18843 \
  -v verus-data:/home/verus/.komodo \
  -v verus-params:/home/verus/.zcash-params \
  ghcr.io/chainvue/verus-docker:latest

docker exec verus-node verus getinfo
```

```json
{ "VRSCversion": "1.2.17-2", "name": "VRSCTEST", "blocks": 26880, ... }
```

**First start takes about a minute** — it downloads ~740 MB of Zcash parameters
once, then shares them with every other Verus container on the host. Later
starts take seconds.

The chain then syncs in the background. **A node that is still syncing is
healthy, not broken** — you can use the RPC immediately.

> `-p 127.0.0.1:...` binds to **loopback only**, so the RPC is reachable from
> your machine but not from your network. Verus RPC controls the wallet and has
> no rate limiting — never bind it to `0.0.0.0`.

---

## Which chain do you want?

| | **VRSCTEST** (testnet) | **VRSC** (mainnet) |
| --- | --- | --- |
| `CHAIN=` | `VRSCTEST` | `VRSC` |
| RPC / P2P port | 18843 / 18842 | 27486 / 27485 |
| Sync from genesis | hours | **days** |
| Sync with bootstrap | ~6.6 GB download | ~22 GB download |
| Disk when synced | ~20 GB (provision 50 GB) | ~150 GB and growing |
| RAM at chain tip | 4–8 GB | ~12 GB |
| Coins | worthless — safe to experiment | real |

Start on **testnet** — same software, same RPC surface, same config, none of
the commitment; moving to mainnet later is a one-line change. Any **PBaaS
chain** works too (`CHAIN=chips`, `CHAIN=vdex`, an i-address —
[there is no whitelist](#pbaas-chains-read-this-first)).

---

## Recipes

Each one complete and copy-pasteable. Compose files work without cloning:

```bash
curl -O https://raw.githubusercontent.com/chainvue/verus-docker/main/examples/compose.testnet.yml
docker compose -f compose.testnet.yml up -d
```

<details>
<summary><b>Mainnet</b> — with or without a verified bootstrap</summary>

```bash
docker run -d --name verus-mainnet -e CHAIN=VRSC \
  -e USE_BOOTSTRAP=true `# drop this line to sync from genesis instead` \
  -p 27485:27485 -p 127.0.0.1:27486:27486 \
  -v verus-mainnet:/home/verus/.komodo -v verus-params:/home/verus/.zcash-params \
  --stop-timeout 120 \
  ghcr.io/chainvue/verus-docker:latest
```

Publish P2P (27485) — without inbound peers the daemon is limited to a handful
of outbound connections and sync gets noticeably slower. With `USE_BOOTSTRAP`
the ~22 GB archive downloads **before** the daemon starts, so the RPC is
unavailable until it finishes; its published SHA-256 is verified before
anything is extracted, and it only runs on an empty data directory.
</details>

<details>
<summary><b>A PBaaS chain</b> — needs a Verus root node</summary>

```bash
docker run -d --name chips -e CHAIN=chips \
  -e ROOT_RPC_HOST=vrsc-node -e ROOT_RPC_PORT=27486 \
  -e ROOT_RPC_USER=... -e ROOT_RPC_PASSWORD=... \
  -v chips-data:/home/verus/.verus -v verus-params:/home/verus/.zcash-params \
  ghcr.io/chainvue/verus-docker:latest
```

A chain without a [`chains/`](chains/) entry also needs `P2P_PORT` and
`RPC_PORT`. Full VRSC + CHIPS + vARRR stack:
[`examples/compose.pbaas.yml`](examples/compose.pbaas.yml).
</details>

<details>
<summary><b>Staking node, or Grafana + Prometheus</b></summary>

Staking has a different threat model — read [staking.md](docs/staking.md), then
use [`examples/compose.staking.yml`](examples/compose.staking.yml), which keeps
the RPC unreachable. For metrics, overlay the monitoring stack:

```bash
docker compose -f examples/compose.testnet.yml \
               -f examples/compose.monitoring.yml up -d
```

Grafana on <http://localhost:3000> (admin/admin), Prometheus on
<http://localhost:9090>, and a [purpose-built exporter](exporter/README.md).
</details>

---

## Connect your app

Credentials are random per node, generated on first start and stored `0600` in
the data volume — nothing to configure, nothing checked into your repo.

**From another container** (recommended — no ports published at all):

```yaml
services:
  verus:
    image: ghcr.io/chainvue/verus-docker:latest
    environment: { CHAIN: VRSCTEST }
    volumes: [verus-data:/home/verus/.komodo, verus-params:/home/verus/.zcash-params]
  myapp:
    build: .
    # Node is at http://verus:18843; mount the volume read-only for credentials.
    volumes: [verus-data:/verus:ro]
    environment: { VERUS_CREDS_PATH: /verus/vrsctest/rpc-credentials }
```

**From your host**, with the loopback publish from the quickstart:

```bash
# Pull the generated credentials into your shell
eval "$(docker exec verus-node cat /home/verus/.komodo/vrsctest/rpc-credentials)"

curl -s --user "$RPC_USER:$RPC_PASSWORD" \
  --data '{"jsonrpc":"1.0","id":"1","method":"getblockchaininfo","params":[]}' \
  http://127.0.0.1:18843/ | jq .result
```

**Ready-made clients** in [`examples/rpc/`](examples/rpc/) — `curl.sh`,
`node.mjs` and `python.py`, each of which finds the credentials, connects and
reads a block with zero configuration. The `verus` CLI needs no flags either
(the chain is injected): `docker exec verus-node verus getblockcount`.

---

## Is it working?

```bash
docker exec verus-node healthcheck.sh                    # liveness: responding?
docker exec verus-node healthcheck.sh --require-synced   # readiness: caught up?
docker exec verus-node cat /tmp/health.json
```

```json
{"state":"syncing","chain":"VRSCTEST","blocks":2656,"headers":26880,
 "verificationprogress":0.0023,"peers":1,"ts":"2026-07-26T18:21:12Z"}
```

Exit `0` healthy · `1` not responding · `2` responding but still syncing. The
Docker `HEALTHCHECK` uses **liveness only**, so a node doing its initial sync is
never restarted out from under itself.

**Normal on a fresh node:** the first minute is the one-time ~740 MB parameter
download, and `blocks` far below `headers` just means it is syncing — watch
`verificationprogress`. **Not normal:**
[zero peers](docs/troubleshooting.md#zero-peers) ·
[RPC refused from the host](docs/troubleshooting.md#connection-refused-from-the-host) ·
[every restart reindexes](docs/troubleshooting.md#every-restart-triggers-a-reindex) ·
[stuck at one height](docs/troubleshooting.md#the-node-is-stuck-at-a-block-height).

---

## Why this image

**Verified binaries** — upstream publishes no checksum asset, so we pin a
reviewed SHA-256 per architecture and cross-check the VerusID signature in the
release; the build fails hard on mismatch. **Never root** — uid/gid 1000.
**Real multi-arch** — amd64 and arm64 from official binaries. **Safe RPC
defaults** — container network only, never `0.0.0.0/0`, random credentials
stored `0600`. **Verified bootstrap** — we never use the daemon's `-bootstrap`
flag, which is destructive on every start and verifies nothing. **Clean
shutdown** — SIGTERM is forwarded and awaited, because verusd flushes for a
long time and killing it early corrupts chain state.

---

## Image tags

| Tag | Moves? | Use it if... |
| --- | --- | --- |
| `v1.2.17-2-r1` | **Never** | You run this in production. Always these exact bits. |
| `v1.2.17-2` | Yes | You want image fixes for one daemon version, upgrading the daemon deliberately. |
| `latest` | Yes | You are evaluating or developing. **Not** for a staking node. |

`-rN` increments when the image changes but the daemon does not, and resets to
`r1` on every daemon upgrade. Releases are built only by CI from a git tag,
signed with cosign keyless, and ship an SPDX SBOM:

```bash
cosign verify ghcr.io/chainvue/verus-docker:v1.2.17-2-r1 \
  --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

`make verify-release` confirms the daemon inside an image is a Foundation-signed
release, using any Verus node.

---

## Configuration

Every variable is optional. Full reference with commentary: [`.env.example`](.env.example).

| Variable | Default | Description |
| --- | --- | --- |
| `CHAIN` | `VRSC` | `VRSC`, `VRSCTEST`, or any PBaaS chain name / i-address. |
| `ROOT_CHAIN` | `VRSC` | Root chain a PBaaS chain belongs to. |
| `PUID` / `PGID` | `1000` | Remap the runtime user for host bind mounts (start as root). |
| `RPC_USER` / `RPC_PASSWORD` | generated | Random on first start, written to the data volume. |
| `RPC_PORT` / `P2P_PORT` | per chain | VRSC 27486/27485, VRSCTEST 18843/18842. PBaaS chains take them from `chains/` metadata if present, otherwise required. |
| `RPC_ALLOW_IP` | `auto` | `auto` = the container's own network. Never silently `0.0.0.0/0`. |
| `TXINDEX` | `1` | Full transaction index. Costs disk. |
| `IDINDEX`, `TIMESTAMPINDEX`, `INSIGHT_EXPLORER` | `false` | Applied at config creation only; changing later needs `-reindex`. `TIMESTAMPINDEX` does nothing without `INSIGHT_EXPLORER`, which forces it either way. |
| `DISABLE_WALLET` | `false` | Wallet-less infrastructure node. |
| `ENABLE_STAKING` | `false` | Stake with `-mint`. Keep RPC private. |
| `WALLET_WARNING` | `true` | Set `false` to silence the wallet-backup reminder on start. |
| `USE_BOOTSTRAP` | `false` | Verified chain snapshot, first run only. |
| `BOOTSTRAP_URL` | per chain | Override. Needs a `.sha256sum` or `.verusid` sidecar. |
| `BOOTSTRAP_INSECURE_TLS` | `false` | Skip cert validation. The checksum comes over the same connection, so this trades away authenticity, not just convenience. |
| `PARAMS_SOURCE` · `PARAMS_VERIFY_EXISTING` | `verus.io/zcparams` · `false` | Zcash parameter mirror, and whether to re-hash existing ones on every start (slow). |
| `DOWNLOAD_LOCK_TIMEOUT` | `3600` | Seconds to wait for another container downloading the same parameter file into a shared volume. |
| `ROOT_RPC_URL` | — | Root node as a URL, e.g. `http://vrsc:27486`. `https://` cannot work — see below. |
| `ROOT_RPC_HOST` · `ROOT_RPC_PORT` · `ROOT_RPC_USER` · `ROOT_RPC_PASSWORD` | — · per root chain · — · — | Root node connection for PBaaS chains, as separate parts instead of a URL. |
| `ROOT_WAIT_TIMEOUT` · `ROOT_MAX_TIP_AGE` | `900` · `1800` | Seconds to wait for the root chain to become usable, and how stale its tip may be before a PBaaS chain will start. |
| `SYNCED_TOLERANCE_BLOCKS` · `SYNCED_MAX_TIP_AGE` | `2` · `1800` | How far behind the peers' height, and how stale the tip, still counts as synced. |
| `MAX_CONNECTIONS` · `EXTRA_ARGS` | daemon default · — | Cap peers (lowering slows sync); extra flags passed to `verusd` verbatim. |
| `HEALTH_FILE` · `RPC_TIMEOUT` · `DEBUG` | `/tmp/health.json` · `60` · `false` | Probe state file, entrypoint RPC timeout, verbose entrypoint logging. |

> **Note:** `addressindex` and `spentindex` are **not** configurable. verusd
> forces both on regardless of configuration, so budget disk for them.

---

## Volumes

`/home/verus/.komodo` holds VRSC and VRSCTEST chain data, config and
`wallet.dat` — **back up `wallet.dat`**. `/home/verus/.verus` holds PBaaS chain
data; mount the parent and let the daemon name the `pbaas/<hash>/`
subdirectory. `/home/verus/.zcash-params` holds the ~740 MB Zcash parameters —
share this one volume across every node on the host.

---

## PBaaS chains: read this first

A PBaaS daemon does **not** read its chain definition from disk. On startup it
calls `getcurrency` on the Verus root chain over plain HTTP; if that fails it
exits with `Cannot find blockchain data`. So "one env var to run any PBaaS
chain" needs one more thing: **a reachable root node**. This image resolves it,
waits for it to sync far enough, and verifies the chain exists before starting
the daemon — so a typo gives a clear error instead of a cryptic one.

**`https://` root URLs cannot work** (verusd speaks plain HTTP to a host:port
pair, so `api.verus.services` cannot serve as a root — use your own node), and
**bootstraps only work for chains with a [`chains/`](chains/) entry**, since the
archive must land in a hash-named directory. Details:
[pbaas.md](docs/pbaas.md#bootstraps).

---

## Deployments and documentation

Ready-made stacks: [testnet](examples/compose.testnet.yml) ·
[mainnet](examples/compose.mainnet.yml) · [PBaaS](examples/compose.pbaas.yml) ·
[staking](examples/compose.staking.yml) · [monitoring](examples/compose.monitoring.yml) ·
[Kubernetes](deploy/kubernetes/) · [Helm](deploy/helm/verus-node/). In Kubernetes
the pod becomes **Ready only once the chain is synced** — readiness means "safe
to serve RPC", and liveness is a separate probe, so a node doing its initial
sync is never restarted out from under itself.

| Guide | For |
| --- | --- |
| [Quickstart](docs/quickstart.md) | Zero to a working RPC endpoint, then a developer/operator fork |
| [Production](docs/production.md) | Sizing, backups, upgrades, security, failure modes |
| [Staking](docs/staking.md) | Different threat model — read before staking |
| [PBaaS chains](docs/pbaas.md) | Running any PBaaS chain, and why it needs a root node |
| [Kubernetes](docs/kubernetes.md) | Manifests, Helm, and why the probes differ |
| [Monitoring](docs/monitoring.md) | Metrics reference, dashboard, alert rules |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-first fixes |
| [Development](docs/development.md) | Building, testing, conventions, invariants |
| [Releasing](docs/maintainers/releasing.md) · [Repo setup](docs/maintainers/repository-setup.md) | Maintainer runbooks |
| [Licensing](LICENSING.md) | What is in the image, and under which licences |

## Building locally

```bash
make build            # host architecture      make lint     # every linter, containerised
make build-multiarch  # amd64 + arm64          make smoke    # smoke test
make up-testnet       # local testnet node     make cli CMD=getinfo
make logs             # follow logs            make down
```

A [devcontainer](.devcontainer/) is included — *Reopen in Container* in VS Code
brings up a testnet node alongside your editor.

---

## Community

[Discussions](https://github.com/chainvue/verus-docker/discussions) for
questions and ideas · [Issues](https://github.com/chainvue/verus-docker/issues)
for bugs · [Chain support template](https://github.com/chainvue/verus-docker/issues/new?template=chain_support.yml)
to add a PBaaS chain (easy, and very welcome) ·
[CONTRIBUTING.md](CONTRIBUTING.md) ·
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) · [SECURITY.md](SECURITY.md) (report
privately, never as an issue) · [verus.io/community](https://verus.io/community).

**Non-goals:** no mining images, no wallet GUI, no custody features — this is
daemon and RPC infrastructure. The project never asks for or handles your keys
beyond the standard `wallet.dat` in a volume you own.

---

## Disclaimer and licence

An independent community project, **not affiliated with or endorsed by the
Verus Coin Foundation**. We containerise the upstream daemon without modifying
it; protocol issues belong [upstream](https://github.com/VerusCoin/VerusCoin).
Nothing here is financial advice — running a node carries operational risk, and
running one with a wallet carries financial risk. You are responsible for your
own keys, backups and security posture. Provided as-is, with no warranty.

This repository is [Apache-2.0](LICENSE). The **published image is a composite
work** — it bundles the upstream daemon (MIT), which links Berkeley DB 6.2
(AGPL-3.0), upstream's own build choice. For a licence review read
**[LICENSING.md](LICENSING.md)**.

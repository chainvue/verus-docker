# verus-docker

**Production-ready Docker images for Verus — mainnet, testnet, and every PBaaS chain.**

[![CI](https://github.com/chainvue/verus-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/chainvue/verus-docker/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/chainvue/verus-docker?sort=semver)](https://github.com/chainvue/verus-docker/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Verus](https://img.shields.io/badge/verusd-v1.2.17--2-blueviolet)](https://github.com/VerusCoin/VerusCoin/releases)

---

## ⚡ Quickstart

A Verus **testnet** node with a working RPC endpoint:

```bash
git clone https://github.com/chainvue/verus-docker && cd verus-docker

docker compose -f examples/compose.testnet.yml up -d

# Watch it come up (it fetches ~740 MB of Zcash parameters once)
docker compose -f examples/compose.testnet.yml logs -f

# Talk to it — no flags, no config
./scripts/verus-cli.sh -f examples/compose.testnet.yml getinfo
```

Prefer plain Docker?

```bash
docker run -d --name verus \
  -e CHAIN=VRSCTEST \
  -v verus-data:/home/verus/.komodo \
  -v verus-params:/home/verus/.zcash-params \
  ghcr.io/chainvue/verus-docker:latest

docker exec verus verus getinfo
```

```json
{
  "version": 2000753,
  "VRSCversion": "1.2.17-2",
  "blocks": 26880,
  "name": "VRSCTEST",
  "chainid": "iJhCezBExJHvtyH3fGhNnt2NhU4Ztkf2yq"
}
```

### Talk to it over HTTP

Credentials are generated on first start and written into the data volume, so
this works as-is:

```bash
docker compose -f examples/compose.testnet.yml exec -T verus sh -c '
  . /home/verus/.komodo/vrsctest/rpc-credentials
  curl -s --user "$RPC_USER:$RPC_PASSWORD" \
    --data "{\"jsonrpc\":\"1.0\",\"id\":\"1\",\"method\":\"getblockchaininfo\",\"params\":[]}" \
    http://127.0.0.1:18843/' | jq .result
```

To read the credentials yourself, or to reach the node from your own
application, see [`examples/rpc/`](examples/rpc/) — runnable curl, Node and
Python clients that need no configuration.

> The RPC port is deliberately **not** published to the host. Reach it from
> another container on the same network, or via `exec` as above.

### Switch to mainnet

```bash
-e CHAIN=VRSC
```

### Run a PBaaS chain

```bash
-e CHAIN=chips \
-e ROOT_RPC_HOST=<your-vrsc-node> -e ROOT_RPC_USER=... -e ROOT_RPC_PASSWORD=...
```

A chain without a `chains/` entry also needs `P2P_PORT` and `RPC_PORT`, since
the daemon derives an unpredictable P2P port.

Any chain name or i-address works — there is no whitelist. PBaaS chains do need
a reachable Verus root node; see [PBaaS chains](#pbaas-chains-read-this-first).
A complete VRSC + CHIPS + vARRR stack is in
[`examples/compose.pbaas.yml`](examples/compose.pbaas.yml).

### Add monitoring

```bash
docker compose \
  -f examples/compose.testnet.yml \
  -f examples/compose.monitoring.yml up -d
```

Grafana on <http://localhost:3000> (admin/admin) with a provisioned dashboard,
Prometheus on <http://localhost:9090>, and a
[purpose-built exporter](exporter/README.md).

---

## Why this image

| | |
| --- | --- |
| **Verified binaries** | Upstream publishes no checksum asset. We pin a reviewed SHA-256 per architecture, and cross-check the VerusID signature file embedded in the release. The build fails hard if either check fails. |
| **Never root** | Runs as uid/gid 1000. Root is supported only to remap `PUID`/`PGID` for host bind mounts, and privileges are dropped before the daemon starts. |
| **Real multi-arch** | `linux/amd64` and `linux/arm64`, both from official upstream binaries. |
| **Safe RPC defaults** | The RPC listener is restricted to the container network, never `0.0.0.0/0`. Random credentials are generated and stored 0600 in the volume. |
| **Verified bootstrap** | We do not use the daemon's `-bootstrap` flag, which is destructive on every start and performs no verification. Our fetcher checks the published SHA-256 before extracting. |
| **Honest health probes** | Liveness ("is it alive?") and readiness ("has it synced?") are separate questions with separate answers. |
| **Clean shutdown** | SIGTERM is forwarded and awaited. verusd flushes for a long time; killing it early corrupts chain state. |

---

## Image tags

```
v1.2.17-2-r1
└──┬─────┘ └┬┘
   │        └── image revision: our changes, same daemon
   └─────────── the upstream VerusCoin release
```

| Tag | Moves? | Use it if... |
| --- | --- | --- |
| `v1.2.17-2-r1` | **Never** | You run this in production. Immutable — always these exact bits. |
| `v1.2.17-2` | Yes | You want image fixes for one daemon version, but upgrade the daemon deliberately. |
| `latest` | Yes | You are evaluating or developing. **Not** for a staking node. |

`-rN` increments when the image changes but the daemon does not — a base image
security rebuild, an entrypoint fix. It resets to `r1` on every daemon upgrade.

Every release is built only by CI from a git tag, signed with cosign keyless,
and ships an SPDX SBOM:

```bash
cosign verify ghcr.io/chainvue/verus-docker:v1.2.17-2-r1 \
  --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Release process and automation: [`docs/maintainers/releasing.md`](docs/maintainers/releasing.md).

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
| `IDINDEX`, `TIMESTAMPINDEX`, `INSIGHT_EXPLORER` | `false` | Applied at config creation only; changing later needs `-reindex`. |
| `DISABLE_WALLET` | `false` | Wallet-less infrastructure node. |
| `ENABLE_STAKING` | `false` | Stake with `-mint`. Keep RPC private. |
| `WALLET_WARNING` | `true` | Set `false` to silence the wallet-backup reminder on start. |
| `USE_BOOTSTRAP` | `false` | Verified chain snapshot, first run only. |
| `BOOTSTRAP_URL` | per chain | Override. A `.sha256sum` sidecar must exist. |
| `BOOTSTRAP_INSECURE_TLS` | `false` | Skip cert validation (checksum still enforced). |
| `PARAMS_SOURCE` | `https://verus.io/zcparams` | Mirror for the Zcash parameters. |
| `PARAMS_VERIFY_EXISTING` | `false` | Re-hash already-downloaded parameters on every start. Slow. |
| `ROOT_RPC_URL` | — | Root node as a URL, e.g. `http://vrsc:27486`. `https://` cannot work — see below. |
| `ROOT_RPC_HOST` | — | Root node host for PBaaS chains. |
| `ROOT_RPC_PORT` | per root chain | Root node RPC port. |
| `ROOT_RPC_USER` | — | Root node RPC user. |
| `ROOT_RPC_PASSWORD` | — | Root node RPC password. |
| `ROOT_WAIT_TIMEOUT` | `900` | Seconds to wait for the root chain to become usable. |
| `ROOT_MIN_PROGRESS` | `0.999` | How synced the root chain must be before a PBaaS chain starts. |
| `SYNCED_TOLERANCE_BLOCKS` | `2` | Blocks behind tip still counted as synced. |
| `MAX_CONNECTIONS` | daemon default | Cap peers. Lowering it slows initial sync. |
| `EXTRA_ARGS` | — | Passed to `verusd` verbatim. |
| `RPC_TIMEOUT` | `60` | Timeout in seconds for the entrypoint's own RPC calls. |
| `DEBUG` | `false` | Verbose entrypoint logging. |

> **Note:** `addressindex` and `spentindex` are **not** configurable. verusd
> forces both on regardless of configuration, so budget disk for them.

---

## Health probes

```bash
healthcheck.sh                   # liveness: is the daemon responding?
healthcheck.sh --require-synced  # readiness: has it caught up?
```

Exit `0` healthy, `1` not responding, `2` responding but still syncing. Both
write `/tmp/health.json`:

```json
{"state":"syncing","chain":"VRSCTEST","blocks":2656,"headers":26880,
 "verificationprogress":0.0023,"peers":1,"ts":"2026-07-26T18:21:12Z"}
```

A node doing its initial sync is **healthy** and must not be restarted — which
is why the Docker `HEALTHCHECK` uses liveness only.

---

## PBaaS chains: read this first

A PBaaS daemon does **not** read its chain definition from disk. On startup it
calls `getcurrency` on the Verus root chain over plain HTTP; if that call fails
it exits with `Cannot find blockchain data`.

So "one env var to run any PBaaS chain" needs one more thing: a reachable root
node. This image resolves it, waits for it to sync far enough, verifies the
chain actually exists, and only then starts the daemon — so a typo gives you a
clear error instead of a cryptic one.

Two caveats worth knowing up front:

- **`https://` root URLs cannot work.** verusd speaks plain HTTP to a host:port
  pair, so a public gateway such as `api.verus.services` cannot serve as the
  root. Use your own node over a private network.
- **PBaaS bootstraps are unavailable.** The community bootstrap host currently
  serves an expired certificate issued for a different hostname. PBaaS chains
  sync from the network.

---

## Volumes

| Path | Holds | Notes |
| --- | --- | --- |
| `/home/verus/.komodo` | VRSC and VRSCTEST chain data, config, `wallet.dat` | Back up `wallet.dat`. |
| `/home/verus/.verus` | PBaaS chain data (`pbaas/<hash>/`) | Mount the parent; the daemon names the subdirectory. |
| `/home/verus/.zcash-params` | Zcash parameters (~740 MB) | Share this volume across every node. |

---

## Deployments

| Where | What |
| --- | --- |
| [`examples/compose.testnet.yml`](examples/compose.testnet.yml) | Quickstart testnet node |
| [`examples/compose.mainnet.yml`](examples/compose.mainnet.yml) | Mainnet, production-shaped |
| [`examples/compose.pbaas.yml`](examples/compose.pbaas.yml) | VRSC plus two PBaaS chains |
| [`examples/compose.staking.yml`](examples/compose.staking.yml) | Staking node, RPC deliberately unreachable |
| [`examples/compose.monitoring.yml`](examples/compose.monitoring.yml) | Exporter + Prometheus + Grafana overlay |
| [`deploy/kubernetes/`](deploy/kubernetes/) | Plain manifests, kustomize-friendly |
| [`deploy/helm/verus-node/`](deploy/helm/verus-node/) | Helm chart |

In Kubernetes the pod becomes **Ready only once the chain is synced** — readiness
means "safe to serve RPC". Liveness is a separate probe, so a node doing its
initial sync is never restarted out from under itself.

## Documentation

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
| [Releasing](docs/maintainers/releasing.md) | Maintainer runbook |
| [Repository setup](docs/maintainers/repository-setup.md) | One-time GitHub settings |

Runnable RPC examples in [`examples/rpc/`](examples/rpc/) — curl, Node and
Python, each connecting and reading a block with no configuration.

## Building locally

```bash
make build            # host architecture
make build-multiarch  # amd64 + arm64
make lint             # every linter, all containerised
make smoke            # 23-assertion smoke test
make up-testnet       # local testnet node
make cli CMD=getinfo
make down
```

A [devcontainer](.devcontainer/) is included: open the repo in VS Code, choose
*Reopen in Container*, and a testnet node comes up alongside your editor.

---

## Roadmap

- [x] **Phase 1** — core image, entrypoint, CLI wrapper, health probes
- [x] **Phase 2** — Compose examples, Kubernetes manifests, Helm chart, Prometheus exporter, Grafana dashboard
- [x] **Phase 3** — release automation, multi-arch signed releases, upstream watcher
- [x] **Phase 4** — full documentation set
- [x] **Phase 5** — community and governance files
- [x] **Phase 6** — clean-room verification and final polish
- [x] **First release** — `v1.2.17-2-r1` published, signed, with an SBOM

---

## Community

| | |
| --- | --- |
| Questions, ideas, show and tell | [Discussions](https://github.com/chainvue/verus-docker/discussions) |
| Bugs and feature requests | [Issues](https://github.com/chainvue/verus-docker/issues) |
| Adding a PBaaS chain | [Chain support template](https://github.com/chainvue/verus-docker/issues/new?template=chain_support.yml) — genuinely easy, genuinely welcome |
| Contributing | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Security | [SECURITY.md](SECURITY.md) — report privately, never as an issue |
| Conduct | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |
| The wider Verus community | [verus.io/community](https://verus.io/community) |

## Non-goals

- **No mining images.** Out of scope; plenty of miner projects exist already.
- **No wallet GUI.** This is daemon and RPC infrastructure.
- **No custody advice.** The project never asks for or handles your keys beyond
  the standard `wallet.dat` in a volume you own.

---

## Disclaimer

An independent community project. **Not affiliated with, endorsed by, or
operated by the Verus Coin Foundation.** We containerise the upstream daemon
without modifying it; protocol issues belong
[upstream](https://github.com/VerusCoin/VerusCoin).

Nothing here is financial advice. Running a node carries operational risk, and
running one with a wallet carries financial risk. You are responsible for your
own keys, your own backups and your own security posture — start with
[production.md](docs/production.md) and, if you stake,
[staking.md](docs/staking.md).

Provided as-is under the MIT licence, with no warranty of any kind.

## License

[MIT](LICENSE)

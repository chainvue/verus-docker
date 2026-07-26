# verus-docker

**Production-ready Docker images for Verus — mainnet, testnet, and every PBaaS chain.**

> **Status: Phase 1 (core image).** The image, entrypoint, CLI wrapper and health
> probes are complete and tested. Compose examples, Kubernetes manifests, the
> Helm chart, the metrics exporter and the full documentation set are landing
> next. See [Roadmap](#roadmap).

---

## ⚡ Quickstart

A Verus **testnet** node with a working RPC endpoint:

```bash
docker run -d --name verus \
  -e CHAIN=VRSCTEST \
  -v verus-data:/home/verus/.komodo \
  -v verus-params:/home/verus/.zcash-params \
  ghcr.io/chainvue/verus-docker:latest

# Watch it come up (it fetches ~740 MB of Zcash parameters once)
docker logs -f verus

# Talk to it — no flags, no config
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

Credentials are generated on first start and stored in the data volume:

```bash
docker exec verus cat /home/verus/.komodo/vrsctest/rpc-credentials
```

```bash
curl -s --user "$RPC_USER:$RPC_PASSWORD" \
  --data '{"jsonrpc":"1.0","id":"1","method":"getblockchaininfo","params":[]}' \
  http://<container-ip>:18843/ | jq .
```

### Switch to mainnet

```bash
-e CHAIN=VRSC
```

### Run a PBaaS chain

```bash
-e CHAIN=chips -e P2P_PORT=22777 -e RPC_PORT=22778 \
-e ROOT_RPC_HOST=<your-vrsc-node> -e ROOT_RPC_USER=... -e ROOT_RPC_PASSWORD=...
```

Any chain name or i-address works — there is no whitelist. PBaaS chains do need
a reachable Verus root node; see [PBaaS chains](#pbaas-chains-read-this-first).

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

## Configuration

Every variable is optional. Full reference with commentary: [`.env.example`](.env.example).

| Variable | Default | Description |
| --- | --- | --- |
| `CHAIN` | `VRSC` | `VRSC`, `VRSCTEST`, or any PBaaS chain name / i-address. |
| `ROOT_CHAIN` | `VRSC` | Root chain a PBaaS chain belongs to. |
| `PUID` / `PGID` | `1000` | Remap the runtime user for host bind mounts (start as root). |
| `RPC_USER` / `RPC_PASSWORD` | generated | Random on first start, written to the data volume. |
| `RPC_PORT` / `P2P_PORT` | per chain | VRSC 27486/27485, VRSCTEST 18843/18842. Required for PBaaS. |
| `RPC_ALLOW_IP` | `auto` | `auto` = the container's own network. Never silently `0.0.0.0/0`. |
| `TXINDEX` | `1` | Full transaction index. Costs disk. |
| `IDINDEX`, `TIMESTAMPINDEX`, `INSIGHT_EXPLORER` | `false` | Applied at config creation only; changing later needs `-reindex`. |
| `DISABLE_WALLET` | `false` | Wallet-less infrastructure node. |
| `ENABLE_STAKING` | `false` | Stake with `-mint`. Keep RPC private. |
| `USE_BOOTSTRAP` | `false` | Verified chain snapshot, first run only. |
| `BOOTSTRAP_URL` | per chain | Override. A `.sha256sum` sidecar must exist. |
| `BOOTSTRAP_INSECURE_TLS` | `false` | Skip cert validation (checksum still enforced). |
| `PARAMS_SOURCE` | `https://verus.io/zcparams` | Mirror for the Zcash parameters. |
| `ROOT_RPC_HOST` / `_PORT` / `_USER` / `_PASSWORD` | — | Root node for PBaaS chains. |
| `ROOT_WAIT_TIMEOUT` | `900` | Seconds to wait for the root chain. |
| `SYNCED_TOLERANCE_BLOCKS` | `2` | Blocks behind tip still counted as synced. |
| `MAX_CONNECTIONS` | daemon default | Cap peers. Lowering it slows initial sync. |
| `EXTRA_ARGS` | — | Passed to `verusd` verbatim. |
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

## Building locally

```bash
make build            # host architecture
make build-multiarch  # amd64 + arm64
make lint             # shellcheck + shfmt + hadolint + JSON
make up-testnet       # local testnet node
make cli CMD=getinfo
make down
```

---

## Roadmap

- [x] **Phase 1** — core image, entrypoint, CLI wrapper, health probes
- [ ] **Phase 2** — Compose examples, Kubernetes manifests, Helm chart, Prometheus exporter, Grafana dashboard
- [ ] **Phase 3** — release automation, multi-arch signed releases, upstream watcher
- [ ] **Phase 4** — full documentation set
- [ ] **Phase 5** — community and governance files

---

## Non-goals

- **No mining images.** Out of scope; plenty of miner projects exist already.
- **No wallet GUI.** This is daemon and RPC infrastructure.
- **No custody advice.** The project never asks for or handles your keys beyond
  the standard `wallet.dat` in a volume you own.

---

## Disclaimer

An independent community project. Not affiliated with or endorsed by the Verus
Coin Foundation. Nothing here is financial advice. Run at your own risk, and
back up your `wallet.dat`.

## License

[MIT](LICENSE)

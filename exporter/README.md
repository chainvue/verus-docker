# verus-exporter

A small Prometheus exporter for a Verus (`verusd`) node. Python 3 standard
library only — no dependencies to install, patch, or audit on a host that sits
next to a wallet.

## Why not an existing exporter

We evaluated reusing one rather than writing another:

| Candidate | Verdict |
| --- | --- |
| [`jvstein/bitcoin-prometheus-exporter`](https://github.com/jvstein/bitcoin-prometheus-exporter) | Active and BSD-3, but it calls `getrpcinfo`, `uptime`, `getmemoryinfo`, `getchaintxstats` and `estimatesmartfee` — none of which exist in verusd (they are Bitcoin 0.15–0.18 additions, and verusd forked from Zcash, which forked from Bitcoin ~0.11). It issues them unguarded, so it dies on the first one. |
| [`zcash-hackworks/zcashd_exporter`](https://github.com/zcash-hackworks/zcashd_exporter) | Archived since 2019, no license stated. |
| `scabraha/komodo-exporter` | Unrelated — that is Komodo the container-deployment platform (komo.do), not the cryptocurrency. |
| A Verus-specific exporter | Does not exist. |

Patching the first option would have meant deleting five of its twelve calls and
adding Verus-native ones — most of the code, carried as a fork. Writing ~350
lines that only ever call RPCs verusd implements was the smaller, clearer
option, and it lets us expose the Verus-specific things (staking supply, PBaaS
chain labelling) that no Bitcoin-shaped exporter models.

Every call is guarded individually: an unsupported or failing method costs you
that method's metrics and nothing else. A partially-answering node still
produces a useful scrape.

## Running it

Alongside a node started by `verus-docker`, the simplest wiring reads the
credentials the entrypoint generated:

```bash
# Both the network and the volume are named after the compose project, which
# defaults to the directory name. Check yours first:
#   docker network ls | grep verus
#   docker volume ls  | grep verus
docker run -d --name verus-exporter \
  --network verus-testnet_default \
  -e VERUS_RPC_HOST=verus \
  -e VERUS_RPC_PORT=18843 \
  -e VERUS_CREDENTIALS_FILE=/creds \
  -v verus-testnet_verus-data-vrsctest:/data:ro \
  ghcr.io/chainvue/verus-exporter:latest
```

Two things people get wrong here, both silent:

- **Without `--network`**, `VERUS_RPC_HOST=verus` does not resolve — the
  container lands on the default bridge, where the compose service name means
  nothing.
- **Volume names are project-prefixed.** `-v verus-data-vrsctest:...` does not
  attach the node's volume; it creates a new empty one, and the exporter exits
  reporting no credentials.

Passing `VERUS_RPC_USER` and `VERUS_RPC_PASSWORD` directly avoids the volume
entirely, which is the better option if you already manage the credentials.

Or use the monitoring overlay, which wires exporter, Prometheus and Grafana
together:

```bash
docker compose -f examples/compose.testnet.yml -f examples/compose.monitoring.yml up -d
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `VERUS_CREDENTIALS_FILE` | — | Path to the node's `rpc-credentials` file. Supplies user, password, port and chain in one go. |
| `VERUS_RPC_HOST` | `127.0.0.1` | Node hostname. |
| `VERUS_RPC_PORT` | from credentials, else `27486` | Node RPC port. |
| `VERUS_RPC_USER` / `VERUS_RPC_PASSWORD` | from credentials | Override individually. |
| `CHAIN` | from credentials, else `VRSC` | Value of the `chain` label. |
| `VERUS_RPC_TIMEOUT` | `15` | Per-call timeout in seconds. |
| `EXPORTER_ADDR` | `0.0.0.0` | Listen address. |
| `EXPORTER_PORT` | `9838` | Listen port. |
| `EXPORTER_CACHE_SECONDS` | `5` | Reuse a scrape for this long so multiple Prometheus servers cost one RPC round. |
| `EXPORTER_EXPOSE_BALANCES` | `false` | Include wallet balances. Off by default — a metrics endpoint is usually less protected than the RPC behind it. |
| `SYNCED_TOLERANCE_BLOCKS` | `2` | Blocks behind the tip that still count as synced. |
| `SYNCED_MAX_TIP_AGE` | `1800` | How old the chain tip may be, in seconds, and still count as synced. Must match the node's value or `verus_sync_complete` will disagree with the readiness probe. |
| `DEBUG` | `false` | Log every HTTP request. |

## Endpoints

| Path | Purpose |
| --- | --- |
| `/metrics` | Prometheus exposition |
| `/healthz` | Exporter liveness (says nothing about the node) |

## Metrics

Every metric carries a `chain` label.

| Metric | Type | Meaning |
| --- | --- | --- |
| `verus_up` | gauge | `1` when the daemon answered `getblockchaininfo`. Always emitted, so an alert can tell "node down" from "exporter down". |
| `verus_blocks` | gauge | Validated blocks in the local chain. |
| `verus_headers` | gauge | Known block headers. A widening gap against `verus_blocks` means falling behind. |
| `verus_verification_progress` | gauge | Sync progress, 0 to 1. |
| `verus_sync_complete` | gauge | `1` when fully caught up. Same rule as `healthcheck.sh --require-synced`: peers present, tip recent, level with the peers' height. Deliberately ignores `verificationprogress` and `headers`, which verusd reports unreliably during initial sync. |
| `verus_difficulty` | gauge | Current chain difficulty. |
| `verus_size_on_disk_bytes` | gauge | Chain data size on disk. |
| `verus_version_info` | gauge | Always `1`; the daemon version rides in a `version` label. |
| `verus_network_height` | gauge | Highest height any connected peer reported. The honest denominator for sync progress. |
| `verus_tip_age_seconds` | gauge | Age of the local chain tip. A synced node's tip is minutes old, not years. |
| `verus_peers` | gauge | Peer count, split by `direction` (`inbound`/`outbound`, or `all` on fallback). |
| `verus_connections_total` | gauge | Total connections as the daemon reports them. |
| `verus_mempool_txs` | gauge | Transactions in the mempool. |
| `verus_mempool_bytes` | gauge | Mempool size in bytes. |
| `verus_mempool_usage_bytes` | gauge | Mempool memory usage. |
| `verus_network_hashps` | gauge | Estimated network hashes per second. |
| `verus_staking_supply` | gauge | Supply participating in staking (Verus is hybrid PoW/PoS). |
| `verus_net_bytes_received_total` | counter | Bytes received from peers. |
| `verus_net_bytes_sent_total` | counter | Bytes sent to peers. |
| `verus_wallet_enabled` | gauge | `1` when a wallet is loaded; `0` on a `-disablewallet` node. |
| `verus_wallet_unlocked` | gauge | `1` when the wallet can sign. A locked wallet does not stake. |
| `verus_wallet_txcount` | gauge | Wallet transaction count. |
| `verus_wallet_balance` | gauge | Only with `EXPORTER_EXPOSE_BALANCES=true`. |
| `verus_wallet_immature_balance` | gauge | Only with `EXPORTER_EXPOSE_BALANCES=true`. |
| `verus_rpc_errors_total` | counter | Failed calls since start, by `method`. Non-zero for a method verusd lacks. |
| `verus_scrape_duration_seconds` | gauge | Time to collect a scrape. |

## Alerts

Ready-made rules live in
[`examples/prometheus/alerts.yml`](../examples/prometheus/alerts.yml): node
down, height stuck, zero peers, peer starvation, fell out of sync, and wallet
locked on a staking node.

## Licence

Apache-2.0, same as the rest of the repository. See
[LICENSING.md](../LICENSING.md).

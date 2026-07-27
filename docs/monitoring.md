# Monitoring

A purpose-built Prometheus exporter, a provisioned Grafana dashboard, and alert
rules that catch the failures that actually happen.

## Quick start

```bash
docker compose \
  -f examples/compose.testnet.yml \
  -f examples/compose.monitoring.yml up -d
```

- Grafana: <http://localhost:3000> (`admin` / `admin`, change it)
- Prometheus: <http://localhost:9090>

Both ports are configurable, because 3000 and 9090 are popular:

```bash
GRAFANA_PORT=3010 PROMETHEUS_PORT=9110 docker compose ... up -d
```

The dashboard is provisioned automatically into a **Verus** folder. No import
step.

## Why a purpose-built exporter

No off-the-shelf exporter works against verusd — the closest candidate calls
five RPCs the daemon does not implement and dies on the first. The full
evaluation is in [`exporter/README.md`](../exporter/README.md).

Every RPC call here is guarded individually, so an unsupported or failing
method costs that method's metrics and nothing else.

## Metrics

Every metric carries a `chain` label, so one dashboard covers a multi-chain host.

### Sync and chain state

| Metric | Meaning |
| --- | --- |
| `verus_up` | `1` when the daemon answered. **Always emitted**, so alerts can tell "node down" from "exporter down". |
| `verus_blocks` | Validated blocks locally |
| `verus_headers` | Headers known. A widening gap against `verus_blocks` means falling behind. |
| `verus_verification_progress` | 0 to 1 — **do not trust this during initial sync**; verusd reports 1 almost immediately. Use `verus_blocks / verus_network_height` instead. |
| `verus_sync_complete` | `1` when caught up. Same rule as `healthcheck.sh --require-synced`. |
| `verus_network_height` | Highest height any peer reported — the real denominator for sync progress. |
| `verus_tip_age_seconds` | Age of the local chain tip. |
| `verus_difficulty` | Current difficulty |
| `verus_size_on_disk_bytes` | Chain data size |
| `verus_version_info` | Always `1`; version rides in a `version` label |

### Network

| Metric | Meaning |
| --- | --- |
| `verus_peers{direction}` | `inbound` / `outbound` (or `all` on fallback) |
| `verus_connections_total` | Total as the daemon reports it |
| `verus_net_bytes_received_total` | Counter |
| `verus_net_bytes_sent_total` | Counter |

### Mempool and mining

| Metric | Meaning |
| --- | --- |
| `verus_mempool_txs` | Transactions queued |
| `verus_mempool_bytes` | Mempool size |
| `verus_mempool_usage_bytes` | Memory used |
| `verus_network_hashps` | Estimated network hash rate |
| `verus_staking_supply` | Supply participating in staking |

### Wallet

| Metric | Meaning |
| --- | --- |
| `verus_wallet_enabled` | `0` on a `-disablewallet` node |
| `verus_wallet_unlocked` | `1` when the wallet can sign. **A locked wallet does not stake.** |
| `verus_wallet_txcount` | Transaction count |
| `verus_wallet_balance` | Only with `EXPORTER_EXPOSE_BALANCES=true` |
| `verus_wallet_immature_balance` | Only with `EXPORTER_EXPOSE_BALANCES=true` |

**Balances are off by default.** A metrics endpoint is usually less protected
than the RPC behind it, and balance is the one value worth withholding. Opt in
knowingly.

### Exporter health

| Metric | Meaning |
| --- | --- |
| `verus_rpc_errors_total{method}` | Failed calls since start. Non-zero for a method your daemon lacks. |
| `verus_scrape_duration_seconds` | Collection time |

## Configuration

Full reference in [`exporter/README.md`](../exporter/README.md). The essentials:

| Variable | Default | Notes |
| --- | --- | --- |
| `VERUS_CREDENTIALS_FILE` | — | Path to the node's `rpc-credentials`. Supplies user, password, port and chain at once. |
| `VERUS_RPC_HOST` / `VERUS_RPC_PORT` | `127.0.0.1` / `27486` | |
| `VERUS_RPC_USER` / `VERUS_RPC_PASSWORD` | from the file | |
| `CHAIN` | from the file | The `chain` label |
| `EXPORTER_PORT` | `9838` | |
| `EXPORTER_CACHE_SECONDS` | `5` | Several Prometheus servers cost one RPC round |
| `EXPORTER_EXPOSE_BALANCES` | `false` | |

The credentials-file approach means you never duplicate secrets: mount the
node's data volume read-only and point at the file the entrypoint generated.

```yaml
verus-exporter:
  environment:
    VERUS_RPC_HOST: verus
    VERUS_RPC_PORT: "18843"
    VERUS_CREDENTIALS_FILE: /data/vrsctest/rpc-credentials
  volumes:
    - verus-data-vrsctest:/data:ro
```

## The dashboard

`examples/grafana/dashboards/verus-node.json`, provisioned automatically. It has
a `chain` template variable, so a multi-chain host gets one dashboard with a
selector rather than one per chain.

Rows:

- **Status** — up, synced, height, peers, version at a glance
- **Sync** — blocks vs headers, verification progress, blocks added per hour
- **Network, mempool and wallet** — traffic rates, mempool depth, wallet
  unlocked state

*Blocks added per hour* is the panel to watch during initial sync: flat means
stalled, and it is the signal behind the `VerusHeightStuck` alert.

To import it into an existing Grafana, use the JSON file directly. It references
a datasource with uid `verus-prometheus`; either create one with that uid or
remap on import.

## Alerts

`examples/prometheus/alerts.yml`:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `VerusNodeDown` | `verus_up == 0` or the target vanished, 5m | critical |
| `VerusHeightStuck` | No new blocks in 30m, sustained 15m (so ~45m) | warning |
| `VerusNoPeers` | Zero peers, 10m | critical |
| `VerusFewPeers` | Under 3 peers, 30m | warning |
| `VerusNotSynced` | Not synced for 6h | warning |
| `VerusWalletLocked` | Wallet present but locked, 15m | warning |
| `VerusDiskFillingUp` | Under 10% free, 30m | critical |

Two deliberate design choices:

`VerusNodeDown` includes `absent(verus_up)`. If the exporter itself dies, the
metric disappears entirely and an expression testing only `== 0` stays silent
forever. That failure mode is easy to miss and exactly the one you care about.

`VerusNotSynced` is set at **6 hours**, not minutes. Initial sync legitimately
takes days on mainnet; a tight threshold would fire continuously on every new
node and be muted, which is worse than no alert. This one is for a node that
*was* synced and fell behind.

### What to actually page on

- `VerusNodeDown` and `VerusNoPeers` — genuine outages
- `VerusDiskFillingUp` — chain data only grows, and a full disk corrupts LevelDB
- `VerusWalletLocked` — only on staking nodes, but there it means you are
  earning nothing while looking perfectly healthy

The rest are worth a ticket, not a phone call.

## Multiple chains on one host

The exporter is one process per node, and every metric carries a `chain` label,
so a multi-chain host runs one exporter per chain and gets one dashboard with a
`chain` selector. Give each its own `EXPORTER_PORT` and point Prometheus at all
of them:

```yaml
scrape_configs:
  - job_name: verus
    static_configs:
      - targets: [verus-exporter-vrsc:9838, verus-exporter-chips:9838]
```

## Kubernetes

```bash
helm upgrade verus deploy/helm/verus-node \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true
```

Runs the exporter as a sidecar sharing the pod's network namespace (so it talks
to `127.0.0.1`), adds a `-metrics` Service, and registers a ServiceMonitor for
the Prometheus Operator. It reads credentials from the Secret if you supplied
one, otherwise from the generated file in the data volume.

## Troubleshooting

**No metrics at all.** The exporter refuses to start without credentials, by
design. Check its logs:

```bash
docker compose logs verus-exporter
```

**`verus_up` is 0.** The exporter is fine but the daemon is not answering. Check
`VERUS_RPC_PORT` matches the chain (18843 testnet, 27486 mainnet) and that the
node is on the same network.

**`verus_rpc_errors_total` is climbing.** Some method is failing. The `method`
label says which; it is harmless if it is a wallet call on a `-disablewallet`
node.

**A stale `chain` label lingers in Prometheus.** Old series persist after a
label changes. It ages out with retention.

**Grafana shows "No data".** Confirm Prometheus is scraping:

```bash
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[].health'
```

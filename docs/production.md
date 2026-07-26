# Running Verus nodes in production

Written for the person who gets paged. Numbers here come from real deployments
and from reading the daemon's source, not from guesswork — where something is
uncertain, it says so.

## Hardware sizing

### Memory

This is the number people get wrong, and getting it wrong corrupts data.

| Chain | Steady state | Limit to set | Notes |
| --- | --- | --- | --- |
| VRSC mainnet | ~12 GiB at the chain tip | **16 GiB** | Measured in production |
| VRSCTEST | 2–4 GiB | 8 GiB | |
| CHIPS | ~6 GiB | 8 GiB | Observed |
| vARRR | ~2 GiB | 3 GiB | Observed |
| vDEX | ~4 GiB | 5 GiB | Observed |

**A memory limit below the working set does not degrade gracefully.** The
kernel OOM-kills verusd, often mid-flush, and you come back to a corrupted
chainstate and a multi-hour reindex. If you are tight on RAM, add swap: it is
much better to be slow than to be killed.

Initial sync uses *less* memory than steady state, so a node that synced fine
can still be OOM-killed weeks later when it reaches the tip. Size for the tip.

### Disk

| Chain | Now | Plan for |
| --- | --- | --- |
| VRSC mainnet | ~100 GB | 150 GB+, growing continuously |
| VRSCTEST | ~20 GB | 50 GB |

**You cannot make this smaller by turning off indexes.** `-txindex` is
configurable and does cost real space, but `addressindex` and `spentindex` are
forced on by the daemon regardless of configuration — `init.cpp` sets
`fAddressIndex = true` unconditionally in the non-reindex startup path. Budget
for them.

**IOPS matter far more than capacity.** Block validation is a random-read
workload against LevelDB. On spinning disks or network storage with low IOPS,
initial sync goes from days to weeks, and a node can fall behind the tip
permanently. Use local SSD or NVMe. If you must use network storage, provision
IOPS explicitly rather than relying on a capacity-derived default.

Set `LimitNOFILE`/`ulimits` to at least 32768. LevelDB plus one descriptor per
peer adds up fast.

### CPU

Two cores is workable, four is comfortable. Verus is a hybrid PoW/PoS chain and
validation is not especially parallel, so more cores help less than faster ones.

**Do not set a CPU limit** in Kubernetes or Compose. Throttling verusd during
block validation slows sync without protecting anything else — use requests for
scheduling and let it burst. The shipped manifests deliberately set a memory
limit and no CPU limit.

## Sync strategies

### Bootstrap versus genesis

A bootstrap is a snapshot of the chain, published as a tarball.

| | Bootstrap | From genesis |
| --- | --- | --- |
| Mainnet | ~22 GB download, then hours of catch-up | Days |
| Testnet | ~6.6 GB, regenerated weekly | Hours |
| Trust | You trust whoever published the snapshot | Only the network |

**Turn it on only for the first start of a fresh volume.** `USE_BOOTSTRAP=true`
in this image runs only when the data directory has no `blocks/` or
`chainstate/`, downloads the archive, **verifies the published SHA-256**, and
only then extracts. On mismatch it deletes the file and aborts loudly.

The RPC is unavailable while the bootstrap downloads, because it has to finish
before the daemon starts. If you want an endpoint immediately and do not care
about the tip yet, leave it off.

> **Never pass `-bootstrap` to verusd yourself.** The daemon's own flag is
> unconditional and destructive on *every* start: it deletes `blocks`,
> `chainstate`, `notarisations`, `peers.dat` and `komodostate`, and forces
> `-zappwallettxes=2`, which discards wallet transaction metadata. Its
> downloader also performs no verification at all — it fetches the signature
> sidecar and never reads it, and it disables TLS verification. This image
> implements its own verified fetcher and never passes that flag.

### Peer starvation is the quiet killer

Without inbound connections, the daemon is limited to a handful of outbound
peers and sync crawls. **Publish the P2P port** (27485 mainnet, 18842 testnet)
and open it in your firewall. Every example in this repository publishes P2P and
withholds RPC, which is the right way round.

If a node is stuck with few peers:

```bash
docker compose exec verus verus getpeerinfo | jq length
docker compose exec verus verus addnode <ip>:27485 onetry
```

### Resuming an interrupted sync

Just start the container again. The daemon resumes from its last flushed state.
An interrupted sync is not a reason to re-bootstrap — a *corrupted* one is, and
you will see `Corruption` in the logs if so.

## Backup and disaster recovery

### What is actually valuable

| | Rebuildable? | Back up? |
| --- | --- | --- |
| `wallet.dat` | **No. Never. It is the only copy of your keys.** | **Yes** |
| `blocks/`, `chainstate/` | Yes, from the network | No |
| `<chain>.conf` | Yes, but hand-tuning is tedious | Yes, cheap |
| `rpc-credentials` | Yes, but dependents would need updating | Yes, cheap |

Backing up 150 GB of chain data nightly is wasted money. Backing up a 200 KB
wallet is the whole job.

### Backing up a running node safely

`wallet.dat` is a live BDB file; copying it while the daemon writes can give you
a torn file. Use the daemon's own dump instead, which takes a consistent
snapshot:

```bash
docker compose exec verus verus backupwallet wallet-backup
# writes into the data directory
docker compose cp verus:/home/verus/.komodo/VRSC/wallet-backup ./wallet-$(date +%F).dat
```

Then get it off the host and encrypt it:

```bash
age -p -o wallet-$(date +%F).dat.age wallet-$(date +%F).dat
shred -u wallet-$(date +%F).dat
```

If the node is stopped, copying `wallet.dat` directly is fine.

### The restore drill

Untested backups are not backups. Do this once, on purpose:

1. Start a second node on a throwaway volume.
2. Stop it. Copy your backup in as `wallet.dat`.
3. Start it and wait for it to sync (or bootstrap).
4. `verus getwalletinfo` and confirm the balance and addresses are what you
   expect.
5. Destroy the test node.

Do it again after any change to how you take backups.

## Upgrades

The safe sequence, in order:

```bash
# 1. Read the release notes. Look specifically for "reindex" or "resync".
# 2. Back up the wallet, and verify the backup is non-empty.
docker compose exec verus verus backupwallet pre-upgrade
docker compose cp verus:/home/verus/.komodo/VRSC/pre-upgrade ./wallet-pre-upgrade.dat

# 3. Stop cleanly. Watch it actually finish.
docker compose down          # honours stop_grace_period
docker compose logs --tail 5 # expect "Shutdown: done"

# 4. Change the tag, then start.
docker compose up -d
```

**Pin immutable tags in production.** Use `v1.2.17-2-r1`, not `latest`. An
unattended image change under a staking wallet is not a good surprise. See the
tag table in the [README](../README.md#image-tags).

**Reading release notes for required reindexes.** Some upstream releases change
index formats or consensus rules. If a reindex is required, the first start
after upgrading will take hours and the node will be unavailable throughout —
plan for it rather than discovering it. Changing `-idindex` or
`-insightexplorer` on an existing chain also forces a reindex.

**Rolling back is not symmetric.** A newer daemon may have written database
formats an older one cannot read. If you must roll back, expect to restore chain
data from a bootstrap or resync. Your wallet backup is what makes this survivable.

## Security

### RPC exposure

The single most important rule: **the Verus RPC controls the wallet and has no
rate limiting.** Anyone who reaches it on a node with an unlocked wallet can
empty it.

| Situation | Do this |
| --- | --- |
| App in the same Compose project | Use the service name. No published port. |
| App on another host | Private network or WireGuard. Never the public internet. |
| Occasional human access | `docker compose exec`, or an SSH tunnel |
| You think you need it public | You do not. Put a service you control in front and expose that. |

If you publish it during development, bind to loopback: `127.0.0.1:18843:18843`.

`RPC_ALLOW_IP` defaults to `auto`, which resolves to the container's own network
plus loopback. The entrypoint prints a loud warning if you set `0.0.0.0/0`.

### Reduce what a compromise costs

```yaml
environment:
  DISABLE_WALLET: "true"    # a node that cannot sign is a much smaller problem
```

For pure RPC infrastructure — explorers, indexers, dApp backends — there is no
reason to carry keys. Do this.

### Everything else

- The container runs as uid/gid 1000 and never needs root. Root is only used to
  remap `PUID`/`PGID` for host bind mounts, and is dropped before the daemon
  starts.
- Firewall: P2P open, RPC closed. That is the whole policy.
- Credentials are generated into the data volume at mode 0600 and never logged.
  Do not put them in environment variables that end up in `docker inspect`
  output if you can read them from the file instead.
- Verify what you are running:
  ```bash
  cosign verify ghcr.io/chainvue/verus-docker:v1.2.17-2-r1 \
    --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```

## Reliability

### Restart policy

`restart: unless-stopped`. Combined with `stop_grace_period: 120s`, this
restarts on crashes without fighting you during maintenance.

**Do not use Watchtower or any auto-updater on a staking node.** Pin an
immutable tag and upgrade deliberately, after reading release notes and taking a
backup. Automatic image updates on a node holding keys trade a small
convenience for an unbounded risk. For a wallet-less RPC node the calculus is
softer, but pinned tags plus a scheduled maintenance window is still better.

### Shutdown grace period

Every example sets 120 seconds. This is a floor:

- A testnet node typically flushes in 10–20 seconds.
- A synced mainnet node can take considerably longer.
- The reference bare-metal deployment this project draws on used
  `TimeoutStopSec=900`.

If you see forced reindexes after restarts, raise it. The cost of waiting is
seconds; the cost of not waiting is hours.

### Alerts worth having

Ready-made rules are in
[`examples/prometheus/alerts.yml`](../examples/prometheus/alerts.yml).

| Alert | Why |
| --- | --- |
| Node not responding for 5m | The obvious one |
| Block height unchanged for 30m | Wedged daemon, or stalled sync |
| Peers = 0 for 10m | Isolated; cannot learn about blocks |
| Peers < 3 for 30m | Peer starvation; sync will crawl |
| Not synced for 6h | It *was* synced and fell behind |
| Wallet locked (staking nodes) | A locked wallet earns nothing |
| Disk > 90% full | Chain data grows continuously; a full disk corrupts LevelDB |

Disk is the one people forget. Chain data only ever grows.

## Common failure modes

### Database corruption

```
Corruption: block checksum mismatch
```

Almost always a hard kill or an OOM during a flush. Recovery:

**Back up the wallet before you do anything else** — `wallet.dat` lives in the
same volume you are about to delete, and this step is irreversible:

```bash
docker compose exec verus verus backupwallet emergency
docker compose cp verus:/home/verus/.komodo/VRSC/emergency ./wallet-emergency.dat
```

Only then:

```bash
docker compose down
# DESTROYS EVERYTHING IN THE VOLUME, INCLUDING wallet.dat
docker volume rm <project>_verus-data-vrsc
# start with USE_BOOTSTRAP=true to re-seed the chain
```

Then fix the cause, or it recurs: raise the grace period, raise the memory
limit, or both.

### Stuck at a height

Check peers first — height stops moving when a node is isolated, and that is far
more common than a broken daemon.

```bash
docker compose exec verus verus getpeerinfo | jq length
docker compose exec verus verus getblockchaininfo | jq '{blocks, headers}'
```

`headers` far ahead of `blocks` means it knows about the chain and is working
through it — that is progress, not a stall. Both frozen means a network problem.

### Out of memory during sync

Raise the memory limit to 16 GiB for mainnet, or add swap. Check `dmesg` or
`docker inspect` for `OOMKilled: true`.

### Where the logs are

Everything goes to stdout, so `docker compose logs` is the answer. There is also
a `debug.log` in the data directory for the daemon's own detail:

```bash
docker compose exec verus tail -100 /home/verus/.komodo/VRSC/debug.log
```

Set `DEBUG=true` for verbose entrypoint logging.

---

More specific situations: [troubleshooting.md](troubleshooting.md).
Staking has its own rules: [staking.md](staking.md).

# Kubernetes

Two options, same image: plain manifests you can read and patch, or a Helm chart
with the knobs already wired.

## Plain manifests

```bash
kubectl create secret generic verus-rpc \
  --from-literal=RPC_USER="verus_$(openssl rand -hex 4)" \
  --from-literal=RPC_PASSWORD="$(openssl rand -hex 32)"

kubectl apply -k deploy/kubernetes/
```

What that creates:

| Object | Purpose |
| --- | --- |
| `StatefulSet verus` | The node, with PVC templates for data and parameters |
| `Service verus-headless` | Stable per-pod DNS |
| `Service verus-rpc` | Internal RPC. ClusterIP only. Routes to **synced** pods only. |
| `Service verus-p2p` | P2P. Routes to unready pods too — on purpose. |
| `ConfigMap verus-config` | Chain, bootstrap toggle, indexes, allowed CIDRs |
| `NetworkPolicy` | RPC restricted to labelled clients; P2P open |

The Secret is deliberately not in the kustomization. `secret.example.yaml` shows
the shape; create the real one out of band, or with SealedSecrets, External
Secrets or SOPS.

If you omit the Secret entirely, the entrypoint generates credentials into the
data volume on first start. Fine for a self-contained node, awkward when
something else needs to authenticate against it.

### kustomize overlays

The manifests are plain and layerable. Testnet, for example:

```yaml
# overlays/testnet/kustomization.yaml
resources:
  - ../../deploy/kubernetes

configMapGenerator:
  - name: verus-config
    behavior: merge
    literals:
      - CHAIN=VRSCTEST
      - RPC_PORT=18843
      - P2P_PORT=18842

patches:
  - target: { kind: StatefulSet, name: verus }
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/ports/0/containerPort
        value: 18842
      - op: replace
        path: /spec/template/spec/containers/0/ports/1/containerPort
        value: 18843
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/resources/requests/storage
        value: 50Gi
```

`labels` in the base kustomization deliberately sets `includeSelectors: false`.
A StatefulSet's selector is immutable, so anything that flows into it can never
be changed afterwards — a label added today becomes permanent.

## Helm

```bash
helm install verus deploy/helm/verus-node \
  --set chain=VRSCTEST \
  --set persistence.data.size=50Gi \
  --set monitoring.enabled=true
```

Values you will actually touch:

| Value | Default | Notes |
| --- | --- | --- |
| `chain` | `VRSC` | Any chain name or i-address |
| `rootChain` | `VRSC` | Only relevant for PBaaS chains |
| `ports.p2p` / `ports.rpc` | derived | **Required** for PBaaS chains |
| `useBootstrap` | `false` | A deliberate seeding operation, not a default |
| `txindex` | `true` | Costs real disk; decide before first start |
| `disableWallet` | `false` | Set `true` for pure RPC infrastructure |
| `enableStaking` | `false` | Read [staking.md](staking.md) first |
| `persistence.data.size` | `150Gi` | Mainnet. Testnet ~50Gi |
| `resources.limits.memory` | `16Gi` | Mainnet needs ~12Gi at the tip |
| `monitoring.enabled` | `false` | Adds the exporter as a sidecar |
| `monitoring.serviceMonitor.enabled` | `false` | Needs Prometheus Operator CRDs |
| `networkPolicy.enabled` | `false` | Needs a CNI that implements it |
| `rpcAuth.existingSecret` | `""` | Otherwise credentials are generated |

The chart **refuses to guess ports for a PBaaS chain**:

```
Error: chain "chips" is a PBaaS chain: set ports.p2p and ports.rpc explicitly
(the daemon derives an unpredictable P2P port)
```

That is intentional, and CI asserts it stays that way.

Note this is **stricter than the container**, which falls back to the
conventional ports in `chains/` when the chain has an entry there. Helm
templating cannot read that file, so the chart asks rather than guesses. Pinning
ports explicitly is the better habit in Kubernetes anyway — Service and
NetworkPolicy ports have to agree with the container, and an implicit value that
could change is exactly what you do not want there.

## The probes, explained

This is the part most node charts get wrong, so it is worth being explicit.

```yaml
startupProbe:    healthcheck.sh                      # has it opened its databases?
livenessProbe:   healthcheck.sh                      # is the daemon responding?
readinessProbe:  healthcheck.sh --require-synced     # has it caught up?
```

**Startup.** Opening LevelDB on a large chain takes minutes, and during that
time the RPC does not answer. Without a startup probe, liveness would kill the
pod before it ever finished starting — a restart loop that looks like a broken
image. Default allowance is 15s × 120 = 30 minutes.

### Sizing the startup budget when using a bootstrap

30 minutes is generous for a normal cold start and **not enough for a
bootstrap**. The RPC stays down for the entire download *and* extraction, so
the startup probe has to cover both:

```
failureThreshold = (archive_GB × 1000 / link_MBps + extract_seconds) / periodSeconds
```

Worked example — mainnet (~22 GB) on a 50 Mbps link (~6 MB/s):

```
download   22000 MB / 6 MB/s   ≈ 3700 s
extraction                     ≈  900 s
total                          ≈ 4600 s
4600 / 15 s per period         ≈ 307   →  set failureThreshold: 400
```

| Chain | Archive | Suggested `failureThreshold` at 50 Mbps |
| --- | --- | --- |
| VRSCTEST | ~6.6 GB | 150 |
| VRSC | ~22 GB | 400 |
| PBaaS (CHIPS/VARRR/VDEX) | 5–10 GB | 150 |

Set it generously. An oversized budget costs nothing — the probe stops as soon
as the RPC answers — while an undersized one makes the pod restart partway
through.

Getting it wrong is no longer fatal: an interrupted download resumes from where
it stopped and a verified archive is reused rather than re-fetched, so a low
threshold costs extra restarts instead of never finishing. Earlier releases
restarted from zero every time, which never converged.

**Liveness — "is it alive?"** A node doing its initial sync answers RPC and is
perfectly healthy. **Never make liveness depend on sync state.** If you do, a
node that legitimately needs three days to sync gets killed every few minutes
and never finishes. This is the single most common way to make a blockchain node
unrunnable in Kubernetes.

**Readiness — "should it get traffic?"** Only a synced node returns correct
answers about the tip, so readiness is where sync belongs. The `verus-rpc`
Service therefore routes only to synced pods.

Consequently **a fresh pod stays Running but not Ready for hours or days.** That
is correct, not a failure. `kubectl get pods` showing `0/1 READY` on a syncing
node is the system working.

`verus-p2p` sets `publishNotReadyAddresses: true` — a syncing node is exactly
the one that needs peers.

## Storage

```yaml
volumeClaimTemplates:
  - metadata: { name: data }     # 150Gi mainnet, 50Gi testnet
  - metadata: { name: params }   # 2Gi, the Zcash parameters
```

**IOPS matter more than capacity.** Block validation is random reads against
LevelDB. On low-IOPS network storage a node can fall behind the tip permanently.
Use a storage class backed by local SSD or NVMe, or provision IOPS explicitly.

The parameters PVC is per-pod by default. With a `ReadWriteMany` storage class
you can share one across nodes and save ~740 MB each; with `ReadWriteOnce` the
duplication is the cost of simplicity.

**Chain data only grows.** Alert on PVC utilisation and plan expansion, or a
full volume will corrupt the database.

## Scheduling

Verus nodes are disk-heavy, IOPS-sensitive and effectively pinned to their
volume. Pin them deliberately:

```yaml
nodeSelector:
  storage: nvme

tolerations:
  - key: dedicated
    operator: Equal
    value: blockchain
    effect: NoSchedule

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: verus-node
        topologyKey: kubernetes.io/hostname
```

Anti-affinity matters on multi-chain hosts: several nodes on one machine will
compete for exactly the resource that is scarce.

## Graceful shutdown

```yaml
terminationGracePeriodSeconds: 120
```

**This is a floor.** verusd flushes LevelDB on exit; SIGKILL mid-flush corrupts
chain state and forces a reindex. A synced mainnet node may want more — the
bare-metal deployment this project draws on used 900 seconds.

Kubernetes sends SIGTERM, waits this long, then SIGKILLs. If you see
`Corruption` in the logs after a rollout, this value was too low.

Consider a PodDisruptionBudget so a drain does not take your only node down
mid-flush:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: verus
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: verus-node
```

## Monitoring

```bash
helm upgrade verus deploy/helm/verus-node \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true
```

That runs the exporter as a sidecar, adds a `-metrics` Service, and registers a
ServiceMonitor. The sidecar reads credentials from the Secret if you supplied
one, or from the generated file in the data volume if you did not.

Metrics reference and alert rules: [monitoring.md](monitoring.md).

## PBaaS chains

Read [pbaas.md](pbaas.md) first — a PBaaS chain needs a reachable, synced VRSC
root node, and that shapes the whole deployment.

```bash
helm install chips deploy/helm/verus-node \
  --set chain=chips \
  --set ports.p2p=22777 --set ports.rpc=22778 \
  --set persistence.data.size=60Gi \
  --set extraEnv[0].name=ROOT_RPC_HOST \
  --set extraEnv[0].value=verus-verus-node-rpc \
  --set extraEnv[1].name=ROOT_RPC_PORT \
  --set extraEnv[1].value="27486" \
  --set extraEnv[2].name=ROOT_WAIT_TIMEOUT \
  --set extraEnv[2].value="86400"
```

Point `ROOT_RPC_HOST` at the VRSC release's RPC Service. Note that Service
routes only to *synced* pods, which is what you want: the PBaaS chain cannot
start against a half-synced root anyway.

Root credentials go in via `ROOT_RPC_USER` / `ROOT_RPC_PASSWORD`, ideally from
the same Secret the root release uses.

## Common problems

**Pod is `Running` but never `Ready`.** Usually correct — it is still syncing.
Confirm:

```bash
kubectl exec verus-0 -c verus -- healthcheck.sh
```

**CrashLoopBackOff on a fresh install.** Check whether liveness is firing before
startup completes; raise `probes.startup.failureThreshold`. Also check for
`OOMKilled` — mainnet needs a 16Gi limit.

**Permission denied on the volume.** `fsGroup: 1000` should handle it. Some CSI
drivers ignore `fsGroup`; if yours does, the container also supports
`PUID`/`PGID` when started as root.

**PBaaS pod exits with `Cannot find blockchain data`.** The root node is
unreachable or not synced. See [pbaas.md](pbaas.md).

More: [troubleshooting.md](troubleshooting.md).

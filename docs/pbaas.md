# Running PBaaS chains

PBaaS ("Public Blockchains as a Service") chains are independent blockchains
launched on top of Verus. `chips`, `varrr` and `vdex` are examples, but there is
no fixed list — anyone can launch one, and this image runs any of them without a
code change.

## The one thing you need to know first

**A PBaaS daemon does not read its chain definition from disk.**

On startup, verusd reads `rpcuser`, `rpcpassword`, `rpcport` and `rpchost` out
of the **VRSC** configuration, then makes a live `getcurrency` JSON-RPC call to
the Verus root chain to learn what chain it is supposed to be running. If that
call fails, it exits:

```
Cannot find blockchain data
```

That is the real meaning of that error, and it is not documented upstream. So
"one environment variable to run any PBaaS chain" is true only once a reachable
root node exists.

This image handles the awkward parts: it resolves the root RPC, waits for the
root chain to answer *and* to be sufficiently synced, verifies via `getcurrency`
that your chain actually exists, and only then starts the daemon. A typo gets
you a clear error instead of `Cannot find blockchain data`.

### Two consequences worth planning around

**The root node must be synced, not merely running.** On mainnet that means a
full VRSC sync before any PBaaS chain will start. Set `ROOT_WAIT_TIMEOUT`
generously rather than letting containers restart-loop while they wait.

**A public gateway cannot be the root.** verusd speaks plain HTTP to a
`host:port` pair; it cannot use TLS and cannot follow a URL path. So
`https://api.verus.services` will not work, and this image fails fast with an
explanation rather than letting you discover it from a cryptic daemon error. Use
a node you can reach over plain HTTP on a private network.

## Running one

The complete working example is
[`examples/compose.pbaas.yml`](../examples/compose.pbaas.yml) — VRSC plus CHIPS
plus vARRR. The essential shape:

```yaml
services:
  verus-mainnet:
    image: ghcr.io/chainvue/verus-docker:latest
    environment:
      CHAIN: VRSC
      # Pinned, not auto-generated: the child chains must authenticate with them.
      RPC_USER: ${VRSC_RPC_USER:?set this in .env}
      RPC_PASSWORD: ${VRSC_RPC_PASSWORD:?set this in .env}
    volumes:
      - verus-data-vrsc:/home/verus/.komodo

  chips:
    image: ghcr.io/chainvue/verus-docker:latest
    depends_on:
      verus-mainnet:
        condition: service_healthy
    environment:
      CHAIN: chips
      P2P_PORT: "22777"          # must be pinned; see below
      RPC_PORT: "22778"
      ROOT_RPC_HOST: verus-mainnet
      ROOT_RPC_PORT: "27486"
      ROOT_RPC_USER: ${VRSC_RPC_USER}
      ROOT_RPC_PASSWORD: ${VRSC_RPC_PASSWORD}
      ROOT_WAIT_TIMEOUT: "86400"  # a full mainnet sync takes a long time
    volumes:
      # Mount the PARENT. See "Data directories" below.
      - verus-data-chips:/home/verus/.verus
```

Generate the shared credentials once:

```bash
echo "VRSC_RPC_USER=verus_$(openssl rand -hex 4)"  >> .env
echo "VRSC_RPC_PASSWORD=$(openssl rand -hex 32)"   >> .env
```

`depends_on: service_healthy` only means "the root daemon answers RPC" — the
entrypoint still waits for it to finish syncing before starting the PBaaS
daemon. Both waits are doing useful work.

## Ports must be pinned

A PBaaS chain's P2P port is **derived by the daemon** from a CRC32 over the
chain definition:

```c
if (magic == 0x8de4eef9)  return 7770;
else if (extralen == 0)   return 8000  + (magic % 7777);
else                      return 16000 + (magic % 49500);
```

It is deterministic per chain but not predictable without running the code, so
this image requires `P2P_PORT` and `RPC_PORT` for any non-root chain and tells
you so rather than guessing. `-port` overrides P2P for non-VRSC chains only;
`-rpcport` works everywhere.

The conventional assignments recorded in `chains/` follow the daemon's own
`RPC = P2P + 1` rule:

| Chain | P2P | RPC |
| --- | --- | --- |
| CHIPS | 22777 | 22778 |
| vARRR | 20777 | 20778 |
| vDEX | 21777 | 21778 |

Any free ports work — these are just what the metadata suggests.

## Data directories

PBaaS chains do not live under `.komodo`:

| Chain kind | Path |
| --- | --- |
| VRSC | `~/.komodo/VRSC/` |
| VRSCTEST | `~/.komodo/vrsctest/` |
| PBaaS on mainnet | `~/.verus/pbaas/<hash>/` |
| PBaaS on testnet | `~/.verustest/pbaas/<hash>/` |

`<hash>` is derived from the chain's currency ID — lowercase the name, append
`@`, resolve it to an identity, hex-encode the result byte-reversed.

**You do not need to compute it.** Mount the *parent* directory
(`/home/verus/.verus`) as the volume and let the daemon create the subdirectory
itself. That is why the examples mount `.verus` rather than a chain path, and it
is the single trick that makes arbitrary chains work without a lookup table.

For reference, the known hashes are recorded in `chains/*.json`:

| Chain | Directory |
| --- | --- |
| CHIPS | `f315367528394674d45277e369629605a1c3ce9f` |
| vARRR | `e9e10955b7d16031e3d6f55d9c908a038e3ae47d` |
| vDEX | `53fe39eea8c06bba32f1a4e20db67e5524f0309d` |

## Bootstraps are not available for PBaaS

The daemon has bootstrap URLs compiled in for CHIPS, vARRR and vDEX, pointing at
`bootstrap.dexstats.info`. Two problems:

1. **That host serves an expired TLS certificate**, issued for a different
   hostname entirely. `curl` fails with error 60. The daemon does not notice
   because it disables certificate verification.
2. It is published by a **third party** (`dexstatsbootstrap@`), not the Verus
   Coin Foundation. That is a different trust decision from a mainnet bootstrap
   and deserves to be made consciously.

So `USE_BOOTSTRAP=true` on a PBaaS chain logs a clear warning and continues with
a normal network sync. PBaaS chains are much smaller than VRSC, so this is
usually fine.

If you have your own snapshot behind working TLS, point `BOOTSTRAP_URL` at it —
a `<url>.sha256sum` sidecar must exist, and it is verified before extraction.

## Adding a chain nobody has run before

Nothing special is required. `CHAIN=<name>` with pinned ports works for any
chain the root node knows about:

```bash
docker run -d \
  -e CHAIN=mycooltoken \
  -e P2P_PORT=25777 -e RPC_PORT=25778 \
  -e ROOT_RPC_HOST=verus-mainnet \
  -e ROOT_RPC_USER=... -e ROOT_RPC_PASSWORD=... \
  -v mytoken-data:/home/verus/.verus \
  -v verus-params:/home/verus/.zcash-params \
  ghcr.io/chainvue/verus-docker:latest
```

An i-address works in place of the name.

If the chain does not exist on the root chain, you get:

```
The root chain does not know a currency called 'mycooltoken'.
Check the spelling, or pass the chain's i-address instead.
```

### Contributing chain metadata

`chains/*.json` is a convenience cache — bootstrap URLs, conventional ports,
notes. **It is never an allowlist**, and unknown chains must keep working
without an entry.

Adding one is a small, welcome pull request. Use the `chain_support` issue
template or open the PR directly with a file following `chains/schema.json`:

```json
{
  "name": "MYCHAIN",
  "kind": "pbaas",
  "currencyid": "i...",
  "ports": { "p2p": 25777, "rpc": 25778 },
  "notes": "Observed memory use around 4 GB."
}
```

Include a `bootstrap` block only if the URL has a working `.sha256sum` sidecar
and valid TLS, and record who publishes it in `signer`. Readers deserve to know
whose snapshot they are trusting.

## Multi-chain hosts

Running several chains on one machine:

- **Share the Zcash parameters.** One `verus-params` volume across every
  container saves ~740 MB per chain.
- **Separate data volumes.** One per chain, never shared.
- **Budget memory per chain.** VRSC ~12 GiB at the tip, CHIPS ~6, vDEX ~4,
  vARRR ~2. They add up faster than people expect.
- **The root chain is a dependency.** If VRSC goes down, PBaaS chains that
  restart cannot start again until it is back. Give it the most reliable
  storage.
- **Publish each chain's P2P port**, and keep every RPC port unpublished.

## Cross-chain development

For DeFi or bridge work you generally need VRSC plus each PBaaS chain you touch,
because currency and conversion state is queried per chain:

```bash
docker compose exec chips verus -chain=chips getcurrency chips
docker compose exec chips verus -chain=chips getcurrencystate chips
```

The `verus` wrapper injects `-chain` automatically, so inside the container
`verus getcurrency chips` is enough.

The exporter reports `verus_up` and sync state per chain with a `chain` label,
so a multi-chain stack gets one dashboard — see [monitoring.md](monitoring.md).

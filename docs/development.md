# Development

Working on this repository.

## Repository layout

```
Dockerfile              Multi-stage build. ARG VERUS_VERSION is the ONLY place
                        the upstream version lives.
rootfs/                 Copied verbatim into the image (COPY rootfs/ /), so a
                        file's repo path IS its in-container path:
  usr/local/bin/
    entrypoint.sh       Chain selection, config, params, bootstrap, signals
    healthcheck.sh      Liveness vs readiness probing
    verus               CLI wrapper injecting -chain=
  usr/local/lib/verus/
    common.sh           Logging, HTTP, checksum verification, JSON-RPC
    chain.sh            CHAIN -> paths, ports, chain kind
    config.sh           Config generation and credentials
    params.sh           Zcash parameter fetch and verification
    bootstrap.sh        Verified bootstrap download
    pbaas.sh            Root-chain resolution and waiting
chains/                 OPTIONAL per-chain metadata. Never an allowlist.
exporter/               Prometheus exporter (Python stdlib only)
examples/               Compose stacks, Prometheus/Grafana config, RPC snippets
deploy/kubernetes/      Plain manifests, kustomize-friendly
deploy/helm/verus-node/ Helm chart
scripts/                Host-side helpers and CI tooling
docs/                   Everything deep; the README stays lean
```

## Prerequisites

Docker with Compose v2 and buildx. That is genuinely all — every linter runs in
a container, pinned to a specific version, so there is nothing to install and
nothing that drifts between your machine and CI.

## The loop

```bash
make build            # build for your architecture
make up-testnet       # start a testnet node
make cli CMD=getinfo
make logs
make down
```

`make help` lists everything.

## Testing changes

### Lint everything

```bash
make lint
```

Runs shellcheck, shfmt, hadolint (both Dockerfiles), actionlint, JSON
validation, the exporter syntax check, `helm lint` plus three template
permutations, kustomize, kubeconform, and the environment-variable
documentation check. CI runs the same set.

Individual targets exist too: `make shellcheck`, `make helm-lint`,
`make env-docs`, and so on. `make shfmt-fix` reformats in place.

### Smoke test

```bash
make smoke
```

23 assertions in about two minutes: the container runs unprivileged, the
generated config is safe, credentials are 0600, the CLI wrapper needs no
arguments, liveness and readiness genuinely disagree while syncing, SIGTERM
produces a clean shutdown, and a restart neither reindexes nor re-downloads.

**It deliberately does not sync a chain or download a bootstrap.** Neither is
feasible in CI, and a test that pretends otherwise is worse than an honest
smaller one.

The Zcash parameters dominate the runtime on a cold run. Reuse them:

```bash
PARAMS_DIR=/tmp/verus-params-cache make smoke
```

### The three cases entrypoint changes must handle

Any change to `entrypoint.sh` should be checked against all three, because they
exercise genuinely different code paths:

1. **Fresh start** — empty volume. Config generated, params fetched.
2. **Restart** — existing data. Config untouched, params reused, no reindex.
3. **Hand-written config** — an operator's own `<chain>.conf`. Must be left
   completely alone, with credentials read back out of it.

The smoke test covers 1 and 2. For 3:

```bash
docker run --rm -v verus-test:/home/verus/.komodo alpine \
  sh -c 'mkdir -p /home/verus/.komodo/vrsctest && printf "server=1\nrpcuser=me\nrpcpassword=secret\nrpcport=18843\n" > /home/verus/.komodo/vrsctest/vrsctest.conf'
# start the container and confirm the log says "existing configuration found"
```

## Devcontainer

Open the repository in VS Code and choose **Reopen in Container**. You get a
shell with Docker access and a testnet node already running as a sibling
container, reachable at `http://verus-dev:18843`.

```bash
cd examples/rpc && ./curl.sh
```

See [`.devcontainer/`](../.devcontainer/).

## Conventions

### Shell

- `bash`, `set -euo pipefail`, always.
- Must pass shellcheck at `--severity=style` and shfmt. CI enforces both.
- Quote every expansion.
- Log to stderr via the helpers in `common.sh`, so stdout stays usable for
  values captured by command substitution.
- **Never log a credential.** The entrypoint redacts `-rpcpassword` before
  printing the daemon command line.

Two shell gotchas this codebase has already been bitten by:

`set -e` does not fire for `false && cmd`, but a block whose *last* statement is
a failing test returns non-zero and will exit. If a `{ ... }` group ends with
conditional `echo`s, terminate it with `true`.

ShellCheck directives only apply file-wide when they appear **before the first
command** — after `set -euo pipefail` is too late.

### Docker

- Both Dockerfiles must pass hadolint.
- Multi-arch: `linux/amd64` and `linux/arm64`. Do not introduce amd64
  assumptions.
- Debian base is not a preference: the upstream binaries need `GLIBC_2.28` and
  `GLIBCXX_3.4.22`, so musl images cannot run them.
- Build tooling stays in earlier stages.

### Documentation

- The README stays under ~350 lines. Depth belongs here in `docs/`.
- **Every environment variable read anywhere in `rootfs/` must appear in the
  README table and in `.env.example`.** `scripts/check-env-docs.sh` enforces it
  and CI runs it. Add the variable to both, or extend the ignore list if it is
  genuinely internal.
- Write for two readers: someone following a tutorial, and someone running this
  in production. When adding a feature, decide which one needs to know.

### Commits

Conventional Commits, enforced on pull request titles:

```
feat: add IDINDEX support
fix: correct testnet config filename
docs: explain the PBaaS root chain requirement
ci: pin actions to commit SHAs
```

Breaking changes to environment variables, volume paths, ports or defaults need
`feat!:` or a `BREAKING CHANGE:` footer **and** a migration note. People pin
their infrastructure on our defaults.

## Invariants

These hold regardless of what a task appears to ask for. If something conflicts
with one, say so rather than working around it.

1. **Any PBaaS chain works by name.** `chains/` is convenience metadata, never
   an allowlist, and unknown chains must degrade gracefully.
2. **Never overwrite an existing `<chain>.conf`.** Environment variables apply
   on first run only. Operators hand-tune configs.
3. **Graceful shutdown is sacred.** SIGTERM reaches verusd and is awaited; every
   example keeps a grace period of at least 120s. Hard kills corrupt the chain
   database.
4. **Non-root at runtime.** Root is only for `PUID`/`PGID` remapping, and is
   dropped before the daemon starts.
5. **RPC is never publicly exposed by default**, and `0.0.0.0/0` produces a loud
   warning.
6. **Verify everything downloaded.** Binaries against a pinned checksum at build
   time; bootstraps and parameters against published checksums at runtime. Fail
   hard, never silently continue.
7. **No secrets in the repository or in image layers.** Generated credentials
   live only in volumes and are never logged.
8. **The entrypoint is idempotent.** Existing data skips the bootstrap, existing
   params skip the download, an existing config is left alone.
9. **Wallet safety.** Nothing may move, delete or transmit `wallet.dat`. Backup
   guidance only.

## Adding a chain

Metadata pull requests are welcome and intentionally lightweight. Add
`chains/<name>.json` following `chains/schema.json`. Include a `bootstrap` block
only if the URL has a working `.sha256sum` sidecar and valid TLS, and record who
publishes it in `signer` — readers deserve to know whose snapshot they are
trusting. See [pbaas.md](pbaas.md).

## Upstream versions

Do not bump `VERUS_VERSION` by hand. The `upstream-watch` workflow runs daily
and opens a pull request with recomputed checksums and the upstream release
notes. To trigger one early:

```bash
scripts/bump-upstream.sh          # newest stable
scripts/bump-upstream.sh v1.2.18  # a specific tag
```

Release mechanics: [maintainers/releasing.md](maintainers/releasing.md).

## Things not to do

- No mining functionality, wallet GUIs, or key handling. Explicitly out of
  scope.
- No PBaaS allowlist, and unknown chains must not fail.
- No weakening defaults for convenience — enabling `USE_BOOTSTRAP` by default or
  widening `RPC_ALLOW_IP` needs discussion in an issue first.
- No new *required* environment variables. New configuration needs a safe
  default.
- No hand-editing `CHANGELOG.md` or the release-please manifest.

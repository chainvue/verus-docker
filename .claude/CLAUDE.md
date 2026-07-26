# CLAUDE.md — verus-node

Guidance for Claude Code (and other AI agents) working in this repository. Read this fully before making changes.

## What this project is

`verus-node` provides production-ready Docker and Kubernetes tooling for running Verus (VRSC) full nodes — **mainnet, testnet, and any PBaaS chain** — with a single image. Target users: developers who need an RPC endpoint fast, and operators running nodes/stakers in production. The goal is to be *the* standard way to run Verus nodes in containers.

We containerize the upstream `verusd` daemon from https://github.com/VerusCoin/VerusCoin — we do **not** modify, patch, or fork the daemon itself. Protocol-level issues belong upstream, not here.

## Repository layout

```
Dockerfile              # Multi-stage build; VERUS_VERSION arg is the ONLY place the upstream version lives
rootfs/                 # Copied verbatim into the image (COPY rootfs/ /), so a file's
                        # repo path IS its in-container path:
  usr/local/bin/entrypoint.sh    # Chain selection, config generation, bootstrap, params, signals
  usr/local/bin/healthcheck.sh   # RPC health/sync probing (liveness vs readiness semantics)
  usr/local/bin/verus            # CLI wrapper that injects -chain= (and creds for PBaaS)
  usr/local/lib/verus/*.sh       # Sourced libraries: common, chain, config, params, bootstrap, pbaas
scripts/                # Host-side helpers (verus-cli.sh wrapper, env-var doc checker, etc.)
chains/                 # OPTIONAL per-chain convenience metadata (bootstrap URLs, ports). Never a whitelist.
examples/               # compose.*.yml stacks + .env.example + examples/rpc/ (curl/node/python snippets)
deploy/kubernetes/      # Plain manifests (StatefulSet, Service, ConfigMap/Secret patterns)
deploy/helm/verus-node/ # Helm chart
docs/                   # All deep documentation; README stays lean
.github/workflows/      # ci, release, upstream-watch, release-please, rebuild
```

## Non-negotiable invariants

Violating any of these is a bug, regardless of what a task seems to ask for:

1. **Any PBaaS chain must work by name.** `CHAIN=<anything>` is passed to `verusd -chain=`. The `chains/` directory is convenience metadata only — never gate chain support on an allowlist.
2. **Never overwrite an existing `<chain>.conf`.** Env vars only apply on first run. Operators hand-tune configs; clobbering them destroys production setups.
3. **Graceful shutdown is sacred.** SIGTERM must propagate to `verusd` (tini + `exec`), and every compose/k8s example must keep `stop_grace_period` / `terminationGracePeriodSeconds` ≥ 120s. Hard kills corrupt the chain DB and force resyncs.
4. **Non-root at runtime.** The container runs as the `verus` user; respect PUID/PGID handling.
5. **RPC is never exposed publicly by default.** No example may publish the RPC port to `0.0.0.0` without a loud, explicit opt-in comment and warning.
6. **Verify everything downloaded.** Upstream binaries: checksum/signature verification at build time, fail hard on mismatch. Bootstraps: checksum verification before extraction. No unverified downloads, ever.
7. **No secrets in the repo or in image layers.** Generated RPC credentials live only in volumes. Never log passwords.
8. **Idempotent entrypoint.** Every startup path must be safe to re-run: existing data dir → skip bootstrap; existing params → skip download; existing conf → don't touch.
9. **Wallet safety.** Never add code or docs that move, delete, or transmit `wallet.dat`. Backup guidance only.

## Conventions

### Shell
- `bash` with `set -euo pipefail` in every script.
- Must pass `shellcheck` and `shfmt` (CI enforces this). Quote all variable expansions.
- Log to stdout/stderr only. Prefix log lines consistently (e.g. `[entrypoint]`, `[bootstrap]`).

### Docker
- Dockerfile must pass `hadolint`.
- Multi-arch: linux/amd64 + linux/arm64. Don't introduce amd64-only assumptions.
- Keep the final image slim; build/download tooling stays in earlier stages.

### Commits & PRs
- **Conventional Commits** are enforced on PR titles: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `refactor:`, `test:`.
- Breaking changes to env vars, volume paths, ports, or defaults → `feat!:` or `BREAKING CHANGE:` footer **plus** a migration note. These surface in the changelog; users pin their infra on our defaults.
- One logical change per PR. Update docs in the same PR as the behavior change.

### Documentation
- README stays under ~350 lines; depth goes in `docs/`.
- **Every env var read anywhere in `entrypoint.sh`/`healthcheck.sh` must appear in the README env-var table.** CI diffs these (`scripts/check-env-docs.sh`); if you add a variable, update the table or CI fails.
- Docs are written for two personas: tutorial follower and production operator. When adding a feature, ask which persona needs to know and update the right doc.

## Versioning & releases

- Immutable release tags: `v<verusd-version>-rN` (e.g. `v1.2.10-r1`). `-rN` bumps for image-level changes with the same upstream version.
- Moving tags: `latest`, `<verusd-version>`. Never change what an immutable tag points to.
- Releases are built **only** by CI from git tags. Never build and push images manually.
- Upstream version bumps arrive via the automated `upstream-watch` PR — review upstream release notes for reindex/resync requirements before merging, and reflect them in our release notes.
- Changelog and release PRs are managed by release-please; don't hand-edit `CHANGELOG.md`.
- Release runbook: `docs/maintainers/releasing.md`.

## Testing changes

- Fast loop: `make build && make up-testnet`, then `make cli CMD=getinfo`.
- Smoke test (what CI runs): container starts → healthcheck reaches healthy → RPC answers `getinfo`. Run it locally before pushing entrypoint changes.
- Never require a full chain sync in CI or tests. Testnet + bootstrap or stubbed checks only.
- Test entrypoint changes against at least: fresh start (empty volume), restart (existing data), and existing hand-written conf (must be left untouched).
- Helm changes: `helm lint` + `helm template` must stay green.

## Things NOT to do

- Don't add mining functionality, wallet GUIs, or key-handling features — explicitly out of scope (see README non-goals).
- Don't add a PBaaS chain allowlist or make unknown chains fail.
- Don't weaken defaults for convenience (e.g. enabling `USE_BOOTSTRAP` by default, widening `RPC_ALLOW_IP`) without discussion in an issue first.
- Don't bump `VERUS_VERSION` outside the upstream-watch flow unless explicitly asked.
- Don't introduce new required env vars — new configuration must have a safe default.
- Don't edit generated files (`CHANGELOG.md`, release-please manifests) by hand.
- Don't commit anything containing real addresses, keys, or credentials — examples use obvious placeholders.

## Security posture

- Treat this repo as supply-chain-sensitive: users run this next to wallets holding funds. Any change touching downloads, verification, credentials, or signal handling deserves extra scrutiny and a careful PR description.
- Images are cosign-signed with SBOMs attached in CI — don't break or bypass the signing/SBOM steps in `release.yml`.
- Vulnerability reports go through `SECURITY.md`, not public issues.

## When in doubt

- Check `docs/development.md` for local workflows and `docs/maintainers/releasing.md` for release mechanics.
- If a task conflicts with an invariant above, stop and flag the conflict instead of working around it.
- Prefer opening a draft PR with questions over guessing on anything that changes user-facing defaults.

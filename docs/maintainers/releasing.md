# Releasing

The release runbook, and how the automations fit together.

## The version scheme

```
v1.2.17-2-r1
└──┬─────┘ └┬┘
   │        └── image revision: our changes, same upstream daemon
   └─────────── the upstream VerusCoin release, verbatim
```

| Tag | Moves? | Who should use it |
| --- | --- | --- |
| `v1.2.17-2-r1` | Never | **Production.** Immutable — this tag always means these exact bits. |
| `1.2.17-2` | Yes | Track image fixes for one daemon version without tracking daemon upgrades. |
| `latest` | Yes | Development and evaluation. Never a staking node. |

`-rN` increments when we change the image but not the daemon: a base image
security rebuild, an entrypoint fix, a new default. It resets to `r1` whenever
the upstream version changes.

`scripts/next-version.sh` is the single place this is computed. It reads
`ARG VERUS_VERSION` from the Dockerfile and finds the highest existing `-rN`
tag for it:

```bash
scripts/next-version.sh              # v1.2.17-2-r1  — the tag to push next
scripts/next-version.sh --current    # the highest tag that already exists
scripts/next-version.sh --upstream   # v1.2.17-2     — what the Dockerfile pins
```

## Why release-please does not own the version

`v<upstream>-rN` has no semver equivalent, and release-please can only produce
versions its strategies understand. Rather than fight it with a custom
versioning plugin that would break the first time upstream's format shifted, we
split the job:

| Concern | Owner |
| --- | --- |
| `CHANGELOG.md` and the release pull request | release-please (`skip-github-release: true`) |
| Which version comes next | `scripts/next-version.sh` |
| Creating the tag | a human, deliberately |
| Building, signing and publishing | `release.yml`, triggered by the tag |

The upside is that nothing publishes without someone pushing a tag on purpose.

## Cutting a release

**1. Merge everything you want in the release.** Conventional Commits matter
here — release-please builds the changelog from commit titles, and
`feat!:` / `BREAKING CHANGE:` produce the section users actually read.

**2. Merge the release-please pull request.** It updates `CHANGELOG.md` and
nothing else. If there is no open release PR, no releasable commits have landed
since the last one.

**3. Check what the next tag should be.**

```bash
git checkout main && git pull
scripts/next-version.sh
```

**4. Push the tag.**

```bash
TAG="$(scripts/next-version.sh)"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
```

**5. Watch `release.yml`.** From here it is fully automatic:

| Job | What it does | Fails the release? |
| --- | --- | --- |
| `verify-tag` | Rejects a malformed tag, or one whose upstream version disagrees with the Dockerfile | Yes, before anything is built |
| `smoke` | Builds amd64 and runs the full smoke test | Yes |
| `publish` | Multi-arch build, push, cosign keyless signature, SBOM attestation | Yes |
| `scan` | Trivy; fails on critical, unfixed excluded | No — see below |
| `github-release` | Release with generated notes and the SBOM attached | No |

**6. Verify what shipped.**

```bash
cosign verify ghcr.io/chainvue/verus-docker:$TAG \
  --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker run --rm ghcr.io/chainvue/verus-docker:$TAG --version
```

### Why the scan runs after publishing

Blocking a release on a newly disclosed CVE in the base image would also block
the daemon update the release is usually carrying — and upstream security
releases are the ones users need fastest. A critical finding fails the job
loudly and visibly; the fix then ships as the next `-rN`, which is exactly what
`rebuild.yml` automates.

## The automations

```
                    ┌─────────────────┐
   daily cron  ───▶ │ upstream-watch  │ ──▶ PR: bump VERUS_VERSION + checksums
                    └─────────────────┘         │
                                                │  human reviews the upstream
                                                │  notes, then merges
   weekly cron ───▶ ┌─────────────────┐         ▼
                    │    rebuild      │ ──▶ PR: base image digest moved
                    └─────────────────┘         │
                                                ▼
   push to main ──▶ ┌─────────────────┐   ┌──────────┐
                    │ release-please  │──▶│   main   │
                    └─────────────────┘   └────┬─────┘
                       CHANGELOG only          │  human pushes vX-rN
                                               ▼
                                        ┌─────────────┐
                                        │   release   │ ──▶ ghcr.io, signed,
                                        └─────────────┘     SBOM, GH release
```

Nothing in that diagram merges itself. Two cron jobs open pull requests; a
human merges them and pushes a tag.

### `upstream-watch.yml`

Daily. Runs `scripts/bump-upstream.sh`, which downloads both architecture
assets, verifies each archive's embedded `.signature.txt` against its inner
tarball and signer, computes the SHA-256 of the outer `.tgz`, and rewrites the
three `ARG` lines in the Dockerfile. The pull request body carries the new
checksums and the upstream release notes.

**Always read the upstream notes before merging.** Some releases require a
reindex or change consensus behaviour, and that has to be repeated in our
release notes — users pin their infrastructure on our defaults.

### `rebuild.yml`

Weekly. Compares the current `debian:bookworm-slim` digest against
`.github/base-image-digest`. If it moved, published images are missing whatever
was patched, so it opens a PR updating the recorded digest. Merge it and tag the
next `-rN`.

### Manually pinning a specific upstream version

```bash
scripts/bump-upstream.sh v1.2.18
```

Or run the `upstream-watch` workflow from the Actions tab with a version input.

## Verifying upstream by hand

Worth doing when you bump the pinned checksums.

VerusCoin publishes no `SHA256SUMS`, `.asc` or `.sig` asset. The hashes in the
release notes reference nothing that ships in the release — verified against
`v1.2.17-2`, where the advertised value matched neither the outer `.tgz`, the
inner `.tar.gz`, nor any extracted file. **Do not use them.**

What does exist is a VerusID signature inside each archive. Checking it needs a
synced node, which is why it cannot happen during a container build:

```bash
tar -xzf Verus-CLI-Linux-v1.2.17-2-x86_64.tgz
cat Verus-CLI-Linux-v1.2.17-2-x86_64.tar.gz.signature.txt
# {"hash": "...", "signature": "...", "signer": "Verus Coin Foundation Releases@"}

verus verifyfile "Verus Coin Foundation Releases@" \
  "<signature from that file>" \
  "$PWD/Verus-CLI-Linux-v1.2.17-2-x86_64.tar.gz"
```

The root of trust in this repository is therefore the reviewed checksum pinned
in the Dockerfile. The build cross-checks the embedded signature file as
defence in depth, but an attacker who replaced the archive would control both —
which is precisely why a human confirms the pinned value.

## If a release goes wrong

**Never move or delete a published immutable tag.** Someone has already pulled
it, and silently changing what it means is worse than the original bug.

Instead: fix forward. Push `-r(N+1)`. The moving tags follow automatically, and
the broken revision stays in place, documented, for anyone who needs to
reproduce the problem.

If the bad image is actively dangerous, additionally:

1. Say so in the GitHub release notes for the broken tag.
2. Open a pinned issue describing the impact and the fixed tag.
3. If it affects wallet safety, follow `SECURITY.md`.

## Checklist

- [ ] CI green on `main`
- [ ] release-please PR merged (`CHANGELOG.md` reads correctly)
- [ ] Breaking changes to env vars, volume paths, ports or defaults carry a migration note
- [ ] Any upstream-required reindex is called out
- [ ] `scripts/next-version.sh` gives the tag you expect
- [ ] Tag pushed; `release.yml` green
- [ ] `cosign verify` passes against the published tag

# Security Policy

This project produces images that people run next to wallets holding funds.
Reports are taken seriously and handled privately.

## Reporting a vulnerability

**Do not open a public issue.**

Use GitHub's private vulnerability reporting:

**[Report a vulnerability →](https://github.com/chainvue/verus-docker/security/advisories/new)**

That creates a private advisory only you and the maintainers can see. It needs
no email address, and it gives us a place to work on a fix and coordinate
disclosure with you.

If that form is unavailable, contact a maintainer listed in
[`.github/CODEOWNERS`](.github/CODEOWNERS) through their GitHub profile and ask
for a private channel. Do not include details until one is established.

### What to include

- What the issue is, and what an attacker gains
- Affected image tags or commit
- Reproduction steps, or a proof of concept
- Anything you already know about mitigations

### What to expect

| | |
| --- | --- |
| Acknowledgement | Within 3 working days |
| Initial assessment | Within 7 days |
| Fix for a confirmed critical issue | Prioritised; released as the next `-rN` |
| Credit | Offered in the advisory and release notes, or withheld if you prefer |

This is a community project, not a company with an on-call rota. If you have not
heard back within a week, please ping the advisory — it is far more likely to be
an oversight than a decision.

## Scope

### In scope

The image and this repository's tooling:

- The `Dockerfile` and the binary verification chain
- `entrypoint.sh`, `healthcheck.sh`, the `verus` wrapper, and the libraries in
  `rootfs/usr/local/lib/verus/`
- The bootstrap and Zcash parameter download paths
- Credential generation, storage and permissions
- The Prometheus exporter
- Compose examples, Kubernetes manifests and the Helm chart, where a default
  exposes something it should not
- The release workflow, signing, and anything else that could let someone
  publish an image users would trust

Insecure **defaults** are in scope even without an exploit. If a shipped example
exposes RPC, leaks a credential, or weakens verification, that is a valid report.

### Out of scope — route upstream

**Vulnerabilities in the Verus daemon or protocol** belong with
[VerusCoin/VerusCoin](https://github.com/VerusCoin/VerusCoin), not here. We
containerise the upstream daemon and do not modify, patch or fork it. Consensus
bugs, RPC vulnerabilities in verusd, cryptographic issues and P2P protocol flaws
are all upstream.

If you are unsure which side of the line something falls on, report it here and
we will help route it.

Also out of scope:

- Vulnerabilities in Debian packages with no fix available upstream (we rebuild
  weekly to pick fixes up as they land)
- Findings that require an attacker who already has root on the host
- Deliberate, documented trade-offs — for example `BOOTSTRAP_INSECURE_TLS=true`,
  which is opt-in, warns loudly, and still verifies the archive checksum
- Reports that a user who sets `RPC_ALLOW_IP=0.0.0.0/0` can be attacked. The
  entrypoint warns prominently; that is working as intended.

## Verifying what you are running

Every release is built only by CI from a git tag, signed with cosign keyless
signing, and ships an SPDX SBOM.

**Verify the signature:**

```bash
cosign verify ghcr.io/chainvue/verus-docker:v1.2.17-2-r1 \
  --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

A valid result proves the image was produced by this repository's release
workflow, not by someone with registry credentials.

**Inspect the SBOM:**

```bash
cosign download attestation ghcr.io/chainvue/verus-docker:v1.2.17-2-r1 \
  | jq -r '.payload' | base64 -d | jq '.predicate'
```

The SBOM is also attached to each GitHub release.

## How the supply chain is secured

| Layer | Approach |
| --- | --- |
| Verus binaries | Reviewed SHA-256 pinned per architecture; the build fails hard on mismatch |
| Zcash parameters | SHA-256 verified against the values pinned in the daemon's own source |
| Bootstraps | Published SHA-256 verified before extraction; abort and delete on mismatch |
| Base image | Rebuilt weekly when the upstream digest moves |
| GitHub Actions | Pinned to 40-character commit SHAs, not mutable tags |
| Releases | CI-only, from a tag, cosign-signed with an SBOM |

### An honest note on binary verification

VerusCoin publishes **no** `SHA256SUMS`, `.asc` or `.sig` release asset. The
SHA-256 values embedded in the release notes reference nothing that ships in the
release — verified against `v1.2.17-2`, where the advertised value matched
neither the outer `.tgz`, the inner `.tar.gz`, nor any extracted file.

Each archive does contain a VerusID signature file, but checking that signature
requires a synced Verus node, which is impossible during a container build.

So the root of trust here is **a checksum pinned in this repository and reviewed
by a human** when the version is bumped. The build additionally cross-checks the
embedded signature file against the inner tarball and its expected signer, but
that is defence in depth rather than an independent root: an attacker who
replaced the archive would control both.

We would rather state this plainly than imply a stronger guarantee than exists.
If upstream begins publishing signed checksums, we will use them.

## Wallet safety

This project never asks for, generates, transmits or stores private keys beyond
the standard `wallet.dat` in a volume you own. No feature will be added that
does.

**If anything claiming to be part of this project asks for your seed phrase or
private keys, it is not.** Report it.

# Licensing

Short version: **this repository is Apache-2.0. The published container image is
not solely Apache-2.0** — it bundles the upstream Verus daemon, and that daemon
links a component under the AGPL. If you are doing a licence review, the image
is the part that needs your attention, not this repository.

> Not legal advice. This page states what the image contains and what upstream
> says about it, so you can make your own determination. If the answer is
> commercially material to you, take it to counsel.

## This repository

Everything written here — the Dockerfile, the entrypoint and its libraries, the
healthcheck, the CLI wrapper, the Prometheus exporter, the Compose stacks, the
Kubernetes manifests, the Helm chart, the scripts and the documentation — is
licensed under the [Apache License 2.0](LICENSE).

Source files carry an `SPDX-License-Identifier: Apache-2.0` line so automated
scanners can classify them without guessing.

## The published image

`ghcr.io/chainvue/verus-docker` is a composite work:

| Component | Licence | How it gets there |
| --- | --- | --- |
| This project's scripts and configuration | Apache-2.0 | Copied from `rootfs/` |
| **Verus daemon** (`verusd`, `verus`) | MIT | Downloaded unmodified from official upstream releases at build time, verified against a pinned SHA-256 |
| **Oracle Berkeley DB 6.2.x** | **AGPL-3.0** | Linked into the upstream binary — see below |
| Debian base image and packages | Various (mostly GPL, LGPL, MIT, BSD) | `debian:bookworm-slim` |
| Zcash proving parameters | — | **Not in the image.** Downloaded at runtime into a volume you own, and hash-verified |

### The Berkeley DB / AGPL question

This is the one that matters, and it comes from upstream rather than from
anything this project does. VerusCoin's own `COPYING` says:

> Although almost all of the Zcash/Komodo/VerusCoin code is licensed under
> "permissive" open source licenses, users and distributors should note that
> when built using the default build options, Verus depends on Oracle Berkeley
> DB 6.2.x, which is licensed under the GNU Affero General Public License.

The official release binaries this image ships are built with those default
options. So the image contains AGPL-licensed code.

This is a long-standing situation in this software lineage, not a novelty:
Bitcoin Core deliberately stayed on Berkeley DB 4.8 (Sleepycat licence) to avoid
it, while Zcash, Komodo and Verus moved to 6.2 and carry the warning instead.

**What it means in practice** depends entirely on what you do:

- **Running the image** — running software does not trigger AGPL obligations.
  The AGPL's network clause concerns *conveying* modified versions.
- **Redistributing the image unmodified** — you are redistributing the same
  binaries upstream publishes, under the same terms upstream publishes them.
- **Modifying the daemon and offering it over a network** — this is where the
  AGPL becomes a live question. This project does not modify the daemon and has
  a standing rule never to, but a fork that did would need to think carefully.

We deliberately do not tell you the answer for your situation. We tell you the
component is there, because a licence review will find it and it should not be a
surprise.

### Why the daemon is not rebuilt from source

Building verusd ourselves would let us choose a different Berkeley DB, but it
would also mean shipping binaries that differ from what upstream signs — and
this project's whole verification story rests on the binaries being byte-identical
to the official releases. Shipping the official ones and documenting what is in
them is the more honest trade.

## Verifying for yourself

Every release is signed and ships an SPDX SBOM listing every package in the
image.

```bash
# Confirm the image came from this repository's release workflow
cosign verify ghcr.io/chainvue/verus-docker:v1.2.17-2-r5 \
  --certificate-identity-regexp 'https://github.com/chainvue/verus-docker/.github/workflows/release.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Read the SBOM attached to the image
cosign download attestation ghcr.io/chainvue/verus-docker:v1.2.17-2-r5 \
  | jq -r '.payload' | base64 -d | jq '.predicate'

# Or take it from the GitHub release
gh release download v1.2.17-2-r5 --repo chainvue/verus-docker --pattern sbom.spdx.json
jq -r '.packages[] | "\(.name)\t\(.licenseConcluded // .licenseDeclared // "NOASSERTION")"' sbom.spdx.json
```

The last command gives you a per-package licence inventory, which is usually
what an OSPO wants.

## Attribution

If you redistribute this project or a derivative, Apache-2.0 §4 asks you to
include the [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE) files, and to mark files
you changed. `NOTICE` already records the upstream attributions.

## Upstream

- Verus daemon: <https://github.com/VerusCoin/VerusCoin> — licence text in its
  `COPYING`
- Protocol and consensus issues belong there, not here. See
  [SECURITY.md](SECURITY.md) for how we route them.

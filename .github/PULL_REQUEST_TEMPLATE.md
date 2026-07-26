## What and why

<!-- What changes, and what problem it solves. The "what" is in the diff; the
     "why" is what reviewers need. -->

Closes #

## Type

- [ ] Bug fix
- [ ] Feature
- [ ] Documentation
- [ ] Chain metadata
- [ ] CI / tooling
- [ ] Breaking change

## Checklist

- [ ] PR title follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`)
- [ ] `make lint` passes
- [ ] `make smoke` passes (skip only for docs-only changes)
- [ ] Documentation updated in this PR, if behaviour changed
- [ ] Any new environment variable is in **both** the README table and `.env.example`
- [ ] No secrets, credentials, real addresses or personal data added

## Tested on

<!-- Delete what does not apply. "Not tested" is an acceptable answer for
     docs-only changes — just say so. -->

- Chain:
- Architecture: `linux/amd64` / `linux/arm64`
- Deployment: docker run / Compose / Kubernetes / Helm

## Entrypoint changes

<!-- Delete this section if you did not touch rootfs/. These three paths are
     genuinely different code and the smoke test only covers the first two. -->

- [ ] Fresh start on an empty volume
- [ ] Restart with existing data — no reindex, config untouched
- [ ] Existing hand-written `<chain>.conf` left completely alone

## Breaking changes

<!-- Delete if none. Otherwise describe the migration: people pin
     infrastructure on our defaults. -->

## Security-relevant?

<!-- Delete if not. Call it out if this touches downloads, verification,
     credentials, signal handling, or anything that could expose the RPC.
     These changes get read more carefully, and that is deliberate. -->

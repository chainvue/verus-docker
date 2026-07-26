# Repository setup

Settings that cannot be committed to the repository and have to be applied in
the GitHub UI or via the API. Written as a checklist so it can be handed to
whoever owns the org.

Everything here is a one-time task. Nothing in this file is required for the
image to work — it is required for the *project* to work.

## About

**Description:**

> Production-ready Docker & Kubernetes images for Verus — mainnet, testnet, and
> every PBaaS chain.

**Website:** leave empty until there is a docs site.

**Topics:**

```
verus  vrsc  pbaas  docker  kubernetes  blockchain  full-node  helm
```

Set them with the CLI rather than clicking:

```bash
gh repo edit chainvue/verus-docker \
  --description "Production-ready Docker & Kubernetes images for Verus — mainnet, testnet, and every PBaaS chain." \
  --add-topic verus --add-topic vrsc --add-topic pbaas --add-topic docker \
  --add-topic kubernetes --add-topic blockchain --add-topic full-node --add-topic helm
```

**Social preview image.** Settings → General → Social preview, 1280×640. Text
that works at thumbnail size:

> **verus-docker**
> Production Verus nodes in containers
> mainnet · testnet · every PBaaS chain

## Features to enable

| Feature | Setting | Why |
| --- | --- | --- |
| Discussions | On | The Q&A venue. Issue templates route questions here. |
| Issues | On | |
| Projects | Optional | |
| Wiki | **Off** | Documentation lives in `docs/`, versioned with the code. |
| Private vulnerability reporting | **On** | `SECURITY.md` links to it. Without it that link 404s. |
| Dependency graph | On | Needed for Dependabot alerts |
| Dependabot alerts | On | |
| Dependabot security updates | On | `.github/dependabot.yml` covers version updates |
| Code scanning | On | `release.yml` uploads Trivy SARIF |

```bash
gh api -X PATCH repos/chainvue/verus-docker \
  -f has_discussions=true -f has_wiki=false -f has_issues=true \
  -f allow_squash_merge=true -f allow_merge_commit=false -f allow_rebase_merge=false \
  -f delete_branch_on_merge=true
```

Squash-only merging matters: release-please builds the changelog from the
squashed commit title, which is what the PR title check validates.

Private vulnerability reporting has to be enabled separately:

```bash
gh api -X PUT repos/chainvue/verus-docker/private-vulnerability-reporting
```

## Branch protection for `main`

Required, since releases are cut from tags on `main`.

- Require a pull request before merging
- Require 1 approval
- Dismiss stale approvals on new commits
- Require review from Code Owners
- Require status checks to pass:
  - `Lint`
  - `Documentation`
  - `Helm and Kubernetes`
  - `Build and smoke test`
- Require branches to be up to date before merging
- Require conversation resolution
- Do **not** allow force pushes or deletions

```bash
gh api -X PUT repos/chainvue/verus-docker/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Lint", "Documentation", "Helm and Kubernetes", "Build and smoke test"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
```

Status check names must match the workflow `name:` fields exactly. If CI job
names change, update this list or merges will block on checks that no longer
exist.

`enforce_admins: false` is deliberate — an admin needs a way to unstick a broken
`main` without disabling protection wholesale.

## Actions permissions

Settings → Actions → General:

- Allow all actions, **or** allow only actions pinned to a SHA if the org
  supports it (all of ours are)
- Workflow permissions: **Read repository contents and packages permissions**.
  Individual workflows request more where they need it; nothing should get write
  access by default.
- Allow GitHub Actions to create and approve pull requests: **On** — required by
  `upstream-watch`, `rebuild` and `release-please`

## Packages

The first successful `release.yml` run creates `ghcr.io/chainvue/verus-docker`
as a **private** package. After that run:

1. Package settings → Change visibility → **Public**
2. Package settings → Manage Actions access → add the repository with **Write**

Until it is public, `docker pull` fails for everyone and the quickstart does not
work — worth checking immediately after the first release.

## Labels

Managed as code in `.github/labels.yml` and synced by `.github/workflows/labels.yml`
on push to `main`. Run it once manually first, so the path-based labeler has
labels to apply:

```bash
gh workflow run labels.yml
```

## Discussions categories

Defaults are close enough. Worth adding:

| Category | Format | For |
| --- | --- | --- |
| Q&A | Question | Where issue templates route questions |
| Show and tell | Open | What people built on top |
| Chain support | Open | PBaaS chains before they become a metadata PR |

## Funding

`.github/FUNDING.yml` ships with everything commented out on purpose — a
placeholder address that looks real is worse than nothing. To enable, uncomment
one entry and fill it in.

Note that `custom:` takes **URLs**, not raw addresses. A VRSC or VerusID
donation address belongs on a page you control that the URL points at, not
inline in the file.

## Secrets

None are required. Releases authenticate to ghcr.io with the automatic
`GITHUB_TOKEN`, and cosign signs keylessly via OIDC — there is no private key to
store or rotate.

If Docker Hub is added later it will need `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN`.

## After the first release

- [ ] Package visibility set to public
- [ ] `docker pull ghcr.io/chainvue/verus-docker:latest` works from a clean machine
- [ ] `cosign verify` passes against the published tag (command in `SECURITY.md`)
- [ ] README badges resolve
- [ ] The quickstart works verbatim, copy-pasted, on a machine that has never
      seen this repository

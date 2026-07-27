# Contributing

Thanks for considering it. This project aims to be the boring, reliable way to
run Verus nodes in containers — which means changes are held to a slightly
higher bar than usual, because people run this next to wallets holding funds.

## Where to start a conversation

| You want to | Go to |
| --- | --- |
| Ask how something works | [Discussions](https://github.com/chainvue/verus-docker/discussions) |
| Report something broken | [Bug report](https://github.com/chainvue/verus-docker/issues/new?template=bug_report.yml) |
| Propose a feature | [Feature request](https://github.com/chainvue/verus-docker/issues/new?template=feature_request.yml) — open one *before* writing code for anything non-trivial |
| Add a PBaaS chain | [Chain support](https://github.com/chainvue/verus-docker/issues/new?template=chain_support.yml) — or just open the PR, these are easy |
| Report a vulnerability | **Not an issue.** See [SECURITY.md](SECURITY.md) |

## Chain metadata pull requests are especially welcome

Adding a PBaaS chain to `chains/` is the lowest-friction contribution here, and
one of the most useful. It is a single JSON file:

```json
{
  "name": "MYCHAIN",
  "kind": "pbaas",
  "currencyid": "iAbc...",
  "datadir_hash": "40-hex-chars-if-you-know-it",
  "ports": { "p2p": 25777, "rpc": 25778 },
  "notes": "Observed memory use in production is ~4 GB at the chain tip."
}
```

Follow [`chains/schema.json`](chains/schema.json). Two things we ask:

- **Include a `bootstrap` block only if it actually works** — the URL needs
  a working `<url>.sha256sum` sidecar and valid TLS. Record who publishes it in
  `signer`. Readers deserve to know whose snapshot they would be trusting, and
  not every bootstrap comes from the Verus Coin Foundation.
- **Remember `chains/` is not an allowlist.** Unknown chains must keep working
  without an entry. If a change would make an unlisted chain fail, that is a bug.

No test is required beyond `make json-lint`, though saying that you actually ran
the chain helps a lot.

## Development setup

Docker with Compose v2 and buildx. That is all — every linter runs in a pinned
container, so there is nothing to install and nothing that drifts between your
machine and CI.

```bash
git clone https://github.com/chainvue/verus-docker && cd verus-docker
make build
make up-testnet
make cli CMD=getinfo
```

Or open the repository in VS Code and choose *Reopen in Container*; a testnet
node comes up alongside your editor.

Full detail, including repository layout and shell conventions:
[docs/development.md](docs/development.md).

## Testing your change

```bash
make lint    # shellcheck, shfmt, hadolint, actionlint, helm, kubeconform, env-docs
make smoke   # runs a real node and asserts against it, ~2 minutes
```

CI runs the same commands, so a green `make lint && make smoke` locally means a
green pull request.

**If you touched `entrypoint.sh`, test all three startup paths.** They are
genuinely different code, and the smoke test only covers the first two:

1. Fresh start on an empty volume — config generated, params fetched
2. Restart with existing data — config untouched, no reindex
3. A hand-written `<chain>.conf` — must be left completely alone

**If you touched anything security-relevant** — downloads, verification,
credentials, signal handling — say so prominently in the pull request
description. Those changes get read more carefully, and that is a feature.

## What makes a good pull request

- **One logical change.** A bug fix and a refactor in the same diff is two pull
  requests.
- **Docs updated in the same PR** as the behaviour change. A feature that lands
  without documentation is a feature nobody finds.
- **New environment variable?** It must appear in the README table *and*
  `.env.example`. CI fails otherwise — `scripts/check-env-docs.sh` checks both
  directions.
- **New env vars need a safe default.** Nothing may become newly required.
- **Explain the why.** The what is in the diff.

Small, obviously-correct pull requests get merged quickly. Large ones that
change defaults will get questions — not because they are unwelcome, but because
people pin infrastructure on our defaults.

## Commit and PR titles

[Conventional Commits](https://www.conventionalcommits.org/), enforced on pull
request titles because that is what the changelog is generated from:

```
feat: add IDINDEX support
fix: correct testnet config filename
docs: explain the PBaaS root chain requirement
ci: pin actions to commit SHAs
chore: bump base image
```

Types: `feat`, `fix`, `docs`, `ci`, `chore`, `refactor`, `test`, `perf`.

**Breaking changes** to environment variables, volume paths, ports or defaults
need `feat!:` or a `BREAKING CHANGE:` footer, **plus a migration note**:

```
feat!: rename VERUS_RPCUSER to RPC_USER

BREAKING CHANGE: VERUS_RPCUSER is now RPC_USER. Existing deployments must
update their environment. Nodes with an existing config file are unaffected,
since credentials are read from the config on restart.
```

Individual commits inside a PR can say whatever you like; the squashed title is
what counts.

## The invariants

Nine rules hold regardless of what an issue seems to ask for — no PBaaS
allowlist, never overwrite an existing config, graceful shutdown is sacred, and
so on. They live in one place so they cannot drift:
**[docs/development.md#invariants](docs/development.md#invariants)**.

If your change conflicts with one, **say so in the PR rather than working
around it**. The invariant might be wrong, but that is a conversation to have
explicitly.

## Things that are out of scope

Not because they are bad, but because this project is deliberately narrow:

- **Mining.** Other projects do this well.
- **Wallet GUIs.** This is daemon and RPC infrastructure.
- **Key handling of any kind** beyond the standard `wallet.dat` in a volume you
  own.
- **Forking or patching verusd.** We containerise the upstream daemon; protocol
  issues belong with [VerusCoin](https://github.com/VerusCoin/VerusCoin).

## Review and merge

Pull requests need CI green. `main` is protected — everything lands through a
PR, nobody pushes to it directly — and a maintainer merges once the checks pass.

Release mechanics are automated and documented in
[docs/maintainers/releasing.md](docs/maintainers/releasing.md) — merging your PR
does not publish anything, so there is no need to worry about timing.

## Licensing of contributions

This project is Apache-2.0. Under section 5 of that licence, anything you
deliberately submit for inclusion is licensed under the same terms unless you
say otherwise in the pull request. There is no CLA to sign.

If you are contributing on behalf of an employer, make sure you are entitled to.

Note that the *published image* is a composite work — see
[LICENSING.md](LICENSING.md).

## Code of Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). It is
the Contributor Covenant, and it is enforced.

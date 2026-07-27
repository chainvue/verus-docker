# verus-docker — common developer verbs.
#
# Run `make help` for the list.

IMAGE       ?= verus-docker
TAG         ?= dev
PLATFORM    ?= linux/$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
CONTAINER   ?= verus
CHAIN       ?= VRSCTEST
CMD         ?= getinfo

SHELLCHECK_IMAGE  ?= koalaman/shellcheck:v0.10.0
HADOLINT_IMAGE    ?= hadolint/hadolint:v2.12.0
SHFMT_IMAGE       ?= mvdan/shfmt:v3.10.0-alpine
HELM_IMAGE        ?= alpine/helm:3.16.3
# bitnami/kubectl no longer publishes resolvable versioned tags, so use
# the upstream kustomize image directly.
KUSTOMIZE_IMAGE   ?= registry.k8s.io/kustomize/kustomize:v5.4.3
KUBECONFORM_IMAGE ?= ghcr.io/yannh/kubeconform:v0.6.7
ACTIONLINT_IMAGE  ?= rhysd/actionlint:1.7.7
K8S_VERSION       ?= 1.31.0

COMPOSE_TESTNET    := examples/compose.testnet.yml
COMPOSE_MONITORING := examples/compose.monitoring.yml

SHELL_SCRIPTS := rootfs/usr/local/bin/entrypoint.sh \
                 rootfs/usr/local/bin/healthcheck.sh \
                 rootfs/usr/local/bin/verus \
                 rootfs/usr/local/lib/verus/common.sh \
                 rootfs/usr/local/lib/verus/chain.sh \
                 rootfs/usr/local/lib/verus/config.sh \
                 rootfs/usr/local/lib/verus/params.sh \
                 rootfs/usr/local/lib/verus/bootstrap.sh \
                 rootfs/usr/local/lib/verus/pbaas.sh \
                 scripts/verus-cli.sh \
                 scripts/smoke-test.sh \
                 scripts/next-version.sh \
                 scripts/check-env-docs.sh \
                 scripts/bump-upstream.sh \
                 scripts/verify-release.sh \
                 examples/rpc/curl.sh \
                 .devcontainer/post-create.sh

.DEFAULT_GOAL := help
.PHONY: help build build-multiarch build-exporter lint shellcheck shfmt shfmt-fix \
        hadolint actionlint env-docs json-lint helm-lint k8s-validate py-check smoke \
        verify-release \
        up-testnet up-published up-monitoring cli logs shell down down-monitoring clean version

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## --- Build ----------------------------------------------------------------

build: ## Build the image for the host architecture
	docker buildx build --platform $(PLATFORM) --load -t $(IMAGE):$(TAG) .

build-multiarch: ## Build both architectures (no load; verifies the cross build)
	docker buildx build --platform linux/amd64,linux/arm64 -t $(IMAGE):$(TAG) .

build-exporter: ## Build the Prometheus exporter image
	docker buildx build --platform $(PLATFORM) --load -t verus-exporter:$(TAG) exporter/

## --- Lint -----------------------------------------------------------------

lint: shellcheck shfmt hadolint json-lint py-check helm-lint k8s-validate actionlint env-docs ## Run every linter

shellcheck: ## Lint shell scripts
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHELLCHECK_IMAGE) \
		--shell=bash --external-sources --severity=style $(SHELL_SCRIPTS)

shfmt: ## Check shell formatting
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHFMT_IMAGE) -d $(SHELL_SCRIPTS)

shfmt-fix: ## Reformat shell scripts in place
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHFMT_IMAGE) -w $(SHELL_SCRIPTS)

hadolint: ## Lint both Dockerfiles
	docker run --rm -i $(HADOLINT_IMAGE) < Dockerfile
	docker run --rm -i $(HADOLINT_IMAGE) < exporter/Dockerfile

actionlint: ## Lint the GitHub Actions workflows
	docker run --rm -v "$(PWD):/repo" -w /repo $(ACTIONLINT_IMAGE)
	@echo "  ok  .github/workflows"

env-docs: ## Check every env var is documented in the README and .env.example
	@bash scripts/check-env-docs.sh

json-lint: ## Validate the chain metadata and dashboard JSON
	@for f in chains/*.json examples/grafana/dashboards/*.json; do \
		jq -e . "$$f" > /dev/null && echo "  ok  $$f"; \
	done

py-check: ## Syntax-check the exporter (compiles in memory; leaves no artifacts)
	docker run --rm -v "$(PWD):/w" -w /w python:3.12-slim \
		python -B -c "import pathlib; f='exporter/verus_exporter.py'; compile(pathlib.Path(f).read_text(), f, 'exec')"
	@echo "  ok  exporter/verus_exporter.py"

helm-lint: ## Lint and render the Helm chart
	docker run --rm -v "$(PWD):/apps" -w /apps $(HELM_IMAGE) lint deploy/helm/verus-node
	docker run --rm -v "$(PWD):/apps" -w /apps $(HELM_IMAGE) template verus deploy/helm/verus-node > /dev/null
	docker run --rm -v "$(PWD):/apps" -w /apps $(HELM_IMAGE) template verus deploy/helm/verus-node \
		--set chain=VRSCTEST --set monitoring.enabled=true --set networkPolicy.enabled=true > /dev/null
	@echo "  ok  deploy/helm/verus-node"

k8s-validate: ## Validate the plain manifests and rendered chart against Kubernetes schemas
	docker run --rm -v "$(PWD):/w" -w /w $(KUSTOMIZE_IMAGE) \
		build deploy/kubernetes/ > /dev/null
	docker run --rm -v "$(PWD):/w" -w /w $(KUBECONFORM_IMAGE) \
		-strict -summary -kubernetes-version $(K8S_VERSION) \
		-ignore-filename-pattern 'kustomization.yaml' deploy/kubernetes/

## --- Test -----------------------------------------------------------------

smoke: build ## Run the full smoke test against a freshly built image
	IMAGE=$(IMAGE):$(TAG) PARAMS_DIR=$${PARAMS_DIR:-/tmp/verus-params-cache} \
		bash scripts/smoke-test.sh

verify-release: ## Cryptographically verify the pinned upstream release on-chain
	@bash scripts/verify-release.sh

version: ## Show the next release tag
	@echo "upstream pinned : $$(scripts/next-version.sh --upstream)"
	@echo "next tag        : $$(scripts/next-version.sh)"

## --- Run ------------------------------------------------------------------

up-testnet: build ## Build this working tree and start a testnet node from it
	VERUS_IMAGE=$(IMAGE):$(TAG) docker compose -f $(COMPOSE_TESTNET) up -d
	@echo "Started $(IMAGE):$(TAG). Follow along with: make logs"

up-published: ## Start a testnet node from the published image instead
	docker compose -f $(COMPOSE_TESTNET) up -d
	@echo "Started the published image. Follow along with: make logs"

up-monitoring: ## Start testnet + exporter + Prometheus + Grafana
	docker compose -f $(COMPOSE_TESTNET) -f $(COMPOSE_MONITORING) up -d --build
	@echo "Grafana:    http://localhost:$${GRAFANA_PORT:-3000}  (admin/admin)"
	@echo "Prometheus: http://localhost:$${PROMETHEUS_PORT:-9090}"

cli: ## Run a verus command: make cli CMD="getinfo"
	@docker compose -f $(COMPOSE_TESTNET) exec -T verus verus $(CMD)

logs: ## Follow node logs
	docker compose -f $(COMPOSE_TESTNET) logs -f verus

shell: ## Open a shell in the node container
	docker compose -f $(COMPOSE_TESTNET) exec verus bash

down: ## Stop the testnet stack (allows a clean shutdown)
	docker compose -f $(COMPOSE_TESTNET) down -t 120

down-monitoring: ## Stop the monitoring stack too
	docker compose -f $(COMPOSE_TESTNET) -f $(COMPOSE_MONITORING) down -t 120

clean: ## Remove the stack AND its data volumes (DESTRUCTIVE — chain data is deleted)
	@echo "This deletes chain data volumes. wallet.dat lives there too."
	@printf 'Type YES to continue: ' && read ans && [ "$$ans" = "YES" ]
	docker compose -f $(COMPOSE_TESTNET) -f $(COMPOSE_MONITORING) down -t 120 -v

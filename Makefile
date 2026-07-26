# verus-docker — common developer verbs.
#
# Run `make help` for the list.

IMAGE       ?= verus-docker
TAG         ?= dev
PLATFORM    ?= linux/$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
CONTAINER   ?= verus
CHAIN       ?= VRSCTEST
CMD         ?= getinfo

SHELLCHECK_IMAGE ?= koalaman/shellcheck:stable
HADOLINT_IMAGE   ?= hadolint/hadolint
SHFMT_IMAGE      ?= mvdan/shfmt:v3-alpine

SHELL_SCRIPTS := rootfs/usr/local/bin/entrypoint.sh \
                 rootfs/usr/local/bin/healthcheck.sh \
                 rootfs/usr/local/bin/verus \
                 rootfs/usr/local/lib/verus/common.sh \
                 rootfs/usr/local/lib/verus/chain.sh \
                 rootfs/usr/local/lib/verus/config.sh \
                 rootfs/usr/local/lib/verus/params.sh \
                 rootfs/usr/local/lib/verus/bootstrap.sh \
                 rootfs/usr/local/lib/verus/pbaas.sh \
                 scripts/verus-cli.sh

.DEFAULT_GOAL := help
.PHONY: help build build-multiarch lint shellcheck shfmt shfmt-fix hadolint \
        json-lint up-testnet cli logs shell down clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## --- Build ----------------------------------------------------------------

build: ## Build the image for the host architecture
	docker buildx build --platform $(PLATFORM) --load -t $(IMAGE):$(TAG) .

build-multiarch: ## Build both architectures (no load; verifies the cross build)
	docker buildx build --platform linux/amd64,linux/arm64 -t $(IMAGE):$(TAG) .

## --- Lint -----------------------------------------------------------------

lint: shellcheck shfmt hadolint json-lint ## Run every linter

shellcheck: ## Lint shell scripts
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHELLCHECK_IMAGE) \
		--shell=bash --external-sources --severity=style $(SHELL_SCRIPTS)

shfmt: ## Check shell formatting
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHFMT_IMAGE) -d $(SHELL_SCRIPTS)

shfmt-fix: ## Reformat shell scripts in place
	docker run --rm -v "$(PWD):/mnt" -w /mnt $(SHFMT_IMAGE) -w $(SHELL_SCRIPTS)

hadolint: ## Lint the Dockerfile
	docker run --rm -i $(HADOLINT_IMAGE) < Dockerfile

json-lint: ## Validate the chain metadata files
	@for f in chains/*.json; do \
		jq -e . "$$f" > /dev/null && echo "  ok  $$f"; \
	done

## --- Run ------------------------------------------------------------------

up-testnet: build ## Start a local testnet node (no bootstrap)
	-docker rm -f $(CONTAINER) 2>/dev/null
	docker run -d --name $(CONTAINER) \
		-e CHAIN=$(CHAIN) \
		-e USE_BOOTSTRAP=false \
		-v verus-data-$(shell echo $(CHAIN) | tr A-Z a-z):/home/verus/.komodo \
		-v verus-params:/home/verus/.zcash-params \
		$(IMAGE):$(TAG)
	@echo "Started. Follow along with: make logs"

cli: ## Run a verus command: make cli CMD="getinfo"
	@docker exec $(CONTAINER) verus $(CMD)

logs: ## Follow container logs
	docker logs -f $(CONTAINER)

shell: ## Open a shell in the container
	docker exec -it $(CONTAINER) bash

down: ## Stop and remove the container (allows a clean shutdown)
	-docker stop -t 120 $(CONTAINER)
	-docker rm $(CONTAINER)

clean: down ## Also remove the data volumes (DESTRUCTIVE — chain data is deleted)
	@echo "This deletes chain data volumes. wallet.dat lives there too."
	@printf 'Type YES to continue: ' && read ans && [ "$$ans" = "YES" ]
	-docker volume rm verus-data-$(shell echo $(CHAIN) | tr A-Z a-z)

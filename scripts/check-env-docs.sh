#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fail if an environment variable the container reads is not documented.
#
# Undocumented configuration is the classic way a node image rots: someone adds
# a variable, the README never learns about it, and a year later nobody knows
# it exists. CI runs this on every pull request.
#
# Checked in both directions:
#   1. every variable read at runtime appears in the README table
#   2. every variable read at runtime appears in .env.example
#
# The exporter is checked separately against its own README, because it is a
# separate image with its own configuration. It went unchecked for a while, and
# SYNCED_MAX_TIP_AGE — which decides what the exporter calls "synced" — was
# missing from its documentation the whole time.
#
# Usage: scripts/check-env-docs.sh

set -euo pipefail

readonly README="${README:-README.md}"
readonly ENV_EXAMPLE="${ENV_EXAMPLE:-.env.example}"
readonly SOURCE_DIRS=("rootfs/usr/local/bin" "rootfs/usr/local/lib/verus")

readonly EXPORTER_SOURCE="exporter/verus_exporter.py"
readonly EXPORTER_README="exporter/README.md"
# Set by the Dockerfile or by Python itself, not user-facing configuration.
readonly EXPORTER_IGNORE='^(PYTHON[A-Z]*|PATH|HOME|LANG|LC_[A-Z]+)$'

# Variables that are internal plumbing rather than user-facing configuration:
# globals our own scripts set, constants, and values baked in by the Dockerfile.
readonly IGNORE_PATTERN='^(CHAIN_(NAME|SLUG|KIND|HOME|DATADIR|CONF|META_FILE|METADATA_DIR)|DEFAULT_(P2P|RPC)_PORT|VRSC(TEST)?_DEFAULT_(P2P|RPC)|RPC_ALLOW_LIST|ROOT_RPC_[A-Z_]+_RESOLVED|PBAAS_CURRENCY_ID|ROOT_CHAIN_CANON|ROOT_CONF_SHIM_MARKER|BOOTSTRAP_(SENTINEL|PARTIAL)|VERUSD_(PID|BIN)|VERUS_(BIN|HOME|HTTP_UA|VERSION)|IMAGE_REVISION|LIB_DIR|PARAMS_DEFAULT_SOURCE|ZCASH_PARAMS|HEALTH_FILE|REQUIRE_SYNCED|QUIET|BASH_[A-Z]+|FUNCNAME|HOME|PATH|PWD|IFS|SECONDS|EOF)$'

errors=0

note() { printf '  %s\n' "$*"; }

fail() {
	printf '\033[31mFAIL\033[0m %s\n' "$*"
	errors=$((errors + 1))
}

# Collect every ${VAR...} reference from the runtime scripts.
collect_vars() {
	grep -rhoE '\$\{[A-Z][A-Z0-9_]*[:}]' "${SOURCE_DIRS[@]}" 2>/dev/null |
		sed -E 's/^\$\{//; s/[:}]$//' |
		sort -u |
		grep -vE "$IGNORE_PATTERN" || true
}

main() {
	local var missing_readme=() missing_env=() vars

	[[ -f "$README" ]] || {
		echo "cannot find ${README}" >&2
		exit 1
	}
	[[ -f "$ENV_EXAMPLE" ]] || {
		echo "cannot find ${ENV_EXAMPLE}" >&2
		exit 1
	}

	mapfile -t vars < <(collect_vars)

	if ((${#vars[@]} == 0)); then
		echo "no environment variables found — the extraction is probably broken" >&2
		exit 1
	fi

	echo "Checking ${#vars[@]} environment variables against ${README} and ${ENV_EXAMPLE}"

	for var in "${vars[@]}"; do
		# Word-boundary match so RPC_PORT does not satisfy ROOT_RPC_PORT.
		grep -qE "\b${var}\b" "$README" || missing_readme+=("$var")
		grep -qE "\b${var}\b" "$ENV_EXAMPLE" || missing_env+=("$var")
	done

	if ((${#missing_readme[@]} > 0)); then
		fail "not documented in ${README}:"
		for var in "${missing_readme[@]}"; do note "$var"; done
	fi

	if ((${#missing_env[@]} > 0)); then
		fail "not documented in ${ENV_EXAMPLE}:"
		for var in "${missing_env[@]}"; do note "$var"; done
	fi

	check_exporter

	if ((errors > 0)); then
		echo
		echo "Add the missing variables to the configuration table, or extend the"
		echo "ignore list in this script if they are genuinely internal."
		exit 1
	fi

	echo "All environment variables are documented."
}

# The exporter reads its configuration through os.environ, so the names are
# plain string literals rather than shell expansions.
check_exporter() {
	local var vars missing=()

	[[ -f "$EXPORTER_SOURCE" && -f "$EXPORTER_README" ]] || return 0

	mapfile -t vars < <(
		grep -oE 'os\.environ(\.get)?\(\s*"[A-Z][A-Z0-9_]*"' "$EXPORTER_SOURCE" |
			grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"' |
			sort -u | grep -vE "$EXPORTER_IGNORE" || true
	)

	((${#vars[@]} > 0)) || {
		fail "no environment variables found in ${EXPORTER_SOURCE} — extraction is probably broken"
		return 0
	}

	echo "Checking ${#vars[@]} exporter variables against ${EXPORTER_README}"
	for var in "${vars[@]}"; do
		grep -qE "\b${var}\b" "$EXPORTER_README" || missing+=("$var")
	done

	if ((${#missing[@]} > 0)); then
		fail "not documented in ${EXPORTER_README}:"
		for var in "${missing[@]}"; do note "$var"; done
	fi
}

main "$@"

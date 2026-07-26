#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Health and readiness probe.
#
# Two questions that must not be conflated:
#
#   liveness  — is the daemon responding at all? A node doing its initial sync
#               is perfectly healthy and must NOT be restarted.
#   readiness — has it caught up? Only then should traffic be routed to it.
#
# Default invocation answers liveness. --require-synced answers readiness.
# Both write /tmp/health.json so other tooling can read the detail.
#
# Exit codes:
#   0  healthy for the requested question
#   1  daemon is not responding
#   2  daemon is responding but not yet synced (--require-synced only)

set -euo pipefail

readonly LIB_DIR="/usr/local/lib/verus"
# shellcheck source=../lib/verus/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/verus/chain.sh
source "${LIB_DIR}/chain.sh"

readonly HEALTH_FILE="${HEALTH_FILE:-/tmp/health.json}"

REQUIRE_SYNCED=false
QUIET=false

usage() {
	cat <<'EOF'
Usage: healthcheck.sh [--require-synced] [--quiet]

  --require-synced   Exit non-zero until the chain is fully synced (readiness).
  --quiet            Suppress human-readable output; only write health.json.
EOF
}

parse_args() {
	while (($# > 0)); do
		case "$1" in
		--require-synced) REQUIRE_SYNCED=true ;;
		--quiet) QUIET=true ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 64
			;;
		esac
		shift
	done
}

say() {
	[[ "$QUIET" == true ]] || printf '%s\n' "$*"
}

write_health() {
	local state="$1" blocks="$2" headers="$3" progress="$4" peers="$5"
	local tmp="${HEALTH_FILE}.tmp.$$"

	jq -n \
		--arg state "$state" \
		--arg chain "$CHAIN_NAME" \
		--argjson blocks "${blocks:-0}" \
		--argjson headers "${headers:-0}" \
		--argjson progress "${progress:-0}" \
		--argjson peers "${peers:-0}" \
		--arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		'{state: $state, chain: $chain, blocks: $blocks, headers: $headers,
		  verificationprogress: $progress, peers: $peers, ts: $ts}' \
		>"$tmp" 2>/dev/null || return 0

	mv -f -- "$tmp" "$HEALTH_FILE" 2>/dev/null || rm -f -- "$tmp"
}

load_credentials() {
	local creds_file
	creds_file="$(chain_credentials_file)"

	if [[ -r "$creds_file" ]]; then
		# shellcheck disable=SC1090  # runtime path, generated at startup
		source "$creds_file"
	fi

	if [[ -z "${RPC_USER:-}" || -z "${RPC_PASSWORD:-}" ]]; then
		# Fall back to the config file for hand-tuned setups.
		if [[ -n "$CHAIN_CONF" && -r "$CHAIN_CONF" ]]; then
			RPC_USER="$(awk -F= '/^[[:space:]]*rpcuser[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$CHAIN_CONF" || true)"
			RPC_PASSWORD="$(awk -F= '/^[[:space:]]*rpcpassword[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$CHAIN_CONF" || true)"
		fi
	fi
}

main() {
	local info peers blocks headers progress tolerance behind state

	parse_args "$@"

	resolve_chain
	load_credentials
	resolve_ports

	if [[ -z "${RPC_USER:-}" || -z "${RPC_PASSWORD:-}" ]]; then
		say "unhealthy: no RPC credentials available yet"
		write_health "starting" 0 0 0 0
		exit 1
	fi

	if ! info="$(rpc_call "http://127.0.0.1:${RPC_PORT}/" "$RPC_USER" "$RPC_PASSWORD" getblockchaininfo)"; then
		say "unhealthy: daemon is not responding on 127.0.0.1:${RPC_PORT}"
		write_health "starting" 0 0 0 0
		exit 1
	fi

	blocks="$(jq -r '.blocks // 0' <<<"$info")"
	headers="$(jq -r '.headers // 0' <<<"$info")"
	progress="$(jq -r '.verificationprogress // 0' <<<"$info")"

	# Best effort; never fail the probe because the peer count was unavailable.
	peers="$(rpc_call "http://127.0.0.1:${RPC_PORT}/" "$RPC_USER" "$RPC_PASSWORD" getconnectioncount 2>/dev/null || echo 0)"
	[[ "$peers" =~ ^[0-9]+$ ]] || peers=0

	tolerance="${SYNCED_TOLERANCE_BLOCKS:-2}"
	behind=$((headers - blocks))
	((behind < 0)) && behind=0

	if ((headers > 0)) && ((behind <= tolerance)) &&
		awk -v p="$progress" 'BEGIN {exit !(p >= 0.9999)}'; then
		state="synced"
	else
		state="syncing"
	fi

	write_health "$state" "$blocks" "$headers" "$progress" "$peers"

	if [[ "$state" == "synced" ]]; then
		say "synced: block ${blocks}, ${peers} peers"
		exit 0
	fi

	# During initial sync the header count briefly lags the block count, which
	# would otherwise render as a nonsensical "block 6292/3968".
	local target="$headers"
	((blocks > target)) && target="$blocks"
	say "syncing: block ${blocks}/${target} ($(awk -v p="$progress" 'BEGIN {printf "%.2f%%", p * 100}')), ${peers} peers"

	if [[ "$REQUIRE_SYNCED" == true ]]; then
		exit 2
	fi

	# Alive but still catching up. That is healthy.
	exit 0
}

main "$@"

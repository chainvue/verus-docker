#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
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

	read_credentials_file "$creds_file" || true

	if [[ -z "${RPC_USER:-}" || -z "${RPC_PASSWORD:-}" ]]; then
		# Fall back to the config file for hand-tuned setups.
		if [[ -n "$CHAIN_CONF" && -r "$CHAIN_CONF" ]]; then
			RPC_USER="$(awk -F= '/^[[:space:]]*rpcuser[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$CHAIN_CONF" || true)"
			RPC_PASSWORD="$(awk -F= '/^[[:space:]]*rpcpassword[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$CHAIN_CONF" || true)"
		fi
	fi
}

main() {
	local info info_general peers blocks headers progress tolerance behind state
	local rpc_url tiptime tip_age max_tip_age network_height

	parse_args "$@"

	resolve_chain
	load_credentials
	resolve_ports

	if [[ -z "${RPC_USER:-}" || -z "${RPC_PASSWORD:-}" ]]; then
		say "unhealthy: no RPC credentials available yet"
		write_health "starting" 0 0 0 0
		exit 1
	fi

	rpc_url="http://127.0.0.1:${RPC_PORT}/"

	if ! info="$(rpc_call "$rpc_url" "$RPC_USER" "$RPC_PASSWORD" getblockchaininfo)"; then
		say "unhealthy: daemon is not responding on 127.0.0.1:${RPC_PORT}"
		write_health "starting" 0 0 0 0
		exit 1
	fi

	blocks="$(jq -r '.blocks // 0' <<<"$info")"
	headers="$(jq -r '.headers // 0' <<<"$info")"
	progress="$(jq -r '.verificationprogress // 0' <<<"$info")"

	# Best effort; never fail the probe because the peer count was unavailable.
	peers="$(rpc_call "$rpc_url" "$RPC_USER" "$RPC_PASSWORD" getconnectioncount 2>/dev/null || echo 0)"
	[[ "$peers" =~ ^[0-9]+$ ]] || peers=0

	# tiptime lives on getinfo, not getblockchaininfo.
	info_general="$(rpc_call "$rpc_url" "$RPC_USER" "$RPC_PASSWORD" getinfo 2>/dev/null || echo '{}')"

	# Determining "synced" is not as simple as it looks on this daemon.
	#
	# During initial sync verusd reports verificationprogress=1 and a `headers`
	# count that can sit BELOW `blocks` — observed on mainnet at block 68,883 of
	# ~4.17M, which made the naive check declare a node ready that was four
	# million blocks behind. Two fields do stay honest:
	#
	#   tiptime                    the timestamp of our chain tip
	#   getpeerinfo startingheight what our peers' heights were when we connected
	#
	# A synced node has a recent tip and is level with its peers. Both are
	# required, and a node with no peers can never claim to be synced because it
	# has nothing to compare against.
	tolerance="${SYNCED_TOLERANCE_BLOCKS:-2}"
	max_tip_age="${SYNCED_MAX_TIP_AGE:-1800}"

	tiptime="$(jq -r '.tiptime // 0' <<<"$info_general")"
	tip_age=$(($(date -u +%s) - tiptime))
	((tip_age < 0)) && tip_age=0

	# The MEDIAN height our peers reported, not the maximum.
	#
	# startingheight comes straight out of a peer's `version` message, so it is
	# whatever that peer chose to claim. Taking the max let a single inbound
	# connection advertising an absurd height hold `behind` above the tolerance
	# forever — readiness would never pass, and Kubernetes would pull a
	# perfectly healthy node out of its Service. Every example publishes the P2P
	# port, as it should for peer health, so that is trivially reachable.
	#
	# A median needs more than half the peers lying to move, which is a much
	# harder position to reach than opening one connection.
	network_height="$(rpc_call "$rpc_url" "$RPC_USER" "$RPC_PASSWORD" getpeerinfo 2>/dev/null |
		jq -r '[.[]?.startingheight // 0] | sort | if length == 0 then 0 else .[(length / 2) | floor] end' 2>/dev/null || echo 0)"
	[[ "$network_height" =~ ^[0-9]+$ ]] || network_height=0

	behind=$((network_height - blocks))
	((behind < 0)) && behind=0

	state="syncing"
	if ((peers > 0)) && ((tiptime > 0)) && ((tip_age <= max_tip_age)) &&
		((network_height == 0 || behind <= tolerance)); then
		state="synced"
	fi

	write_health "$state" "$blocks" "$headers" "$progress" "$peers"

	if [[ "$state" == "synced" ]]; then
		say "synced: block ${blocks}, ${peers} peers"
		exit 0
	fi

	# Report against the peers' height: verusd's own header count is not a
	# dependable denominator during initial sync.
	local target="$network_height"
	((target < blocks)) && target="$blocks"
	if ((target > 0)); then
		say "syncing: block ${blocks}/${target} ($(awk -v b="$blocks" -v t="$target" 'BEGIN {printf "%.2f%%", (t ? b / t : 0) * 100}')), ${peers} peers, tip $(human_age "$tip_age") old"
	else
		say "syncing: block ${blocks}, ${peers} peers, tip $(human_age "$tip_age") old"
	fi

	if [[ "$REQUIRE_SYNCED" == true ]]; then
		exit 2
	fi

	# Alive but still catching up. That is healthy.
	exit 0
}

main "$@"

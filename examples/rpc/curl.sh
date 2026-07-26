#!/usr/bin/env bash
# Talk to a Verus node from the shell.
#
#   ./curl.sh
#
# Reads credentials from the node's data volume by default, so there is nothing
# to configure. Override any of these if your node lives elsewhere:
#
#   VERUS_CONTAINER=verus  VERUS_RPC_URL=http://127.0.0.1:18843
#   VERUS_RPC_USER=...     VERUS_RPC_PASSWORD=...
#
# Note the container does NOT publish its RPC port by default, and you should
# keep it that way. Either run this from a container on the same network, or
# publish to loopback only while you are experimenting.

set -euo pipefail

CONTAINER="${VERUS_CONTAINER:-verus}"
RPC_URL="${VERUS_RPC_URL:-http://127.0.0.1:18843}"
CREDS_PATH="${VERUS_CREDS_PATH:-/home/verus/.komodo/vrsctest/rpc-credentials}"

# --------------------------------------------------------------------------
# Credentials
#
# The entrypoint generates a random user and password on first start and writes
# them into the data volume. Pull them out rather than hardcoding anything.
# --------------------------------------------------------------------------

if [[ -z "${VERUS_RPC_USER:-}" || -z "${VERUS_RPC_PASSWORD:-}" ]]; then
	if ! creds="$(docker exec "$CONTAINER" cat "$CREDS_PATH" 2>/dev/null)"; then
		echo "Could not read credentials from container '${CONTAINER}'." >&2
		echo "Set VERUS_RPC_USER and VERUS_RPC_PASSWORD, or VERUS_CONTAINER." >&2
		exit 1
	fi
	VERUS_RPC_USER="$(awk -F= '/^RPC_USER=/  {print $2}' <<<"$creds")"
	VERUS_RPC_PASSWORD="$(awk -F= '/^RPC_PASSWORD=/ {print $2}' <<<"$creds")"
fi

# --------------------------------------------------------------------------
# One helper, used for everything below.
# --------------------------------------------------------------------------

# rpc <method> [json-params]
rpc() {
	local method="$1" params="${2:-[]}"
	curl --silent --show-error --fail-with-body \
		--user "${VERUS_RPC_USER}:${VERUS_RPC_PASSWORD}" \
		--header 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"1.0\",\"id\":\"curl\",\"method\":\"${method}\",\"params\":${params}}" \
		"$RPC_URL" | jq '.result'
}

# --------------------------------------------------------------------------

echo "== getinfo =="
rpc getinfo | jq '{version: .VRSCversion, chain: .name, blocks, connections}'

echo
echo "== getblockchaininfo =="
rpc getblockchaininfo | jq '{blocks, headers, verificationprogress}'

echo
echo "== getblock (the current tip) =="
# getblockhash takes a height; feed its result straight into getblock.
height="$(rpc getblockcount)"
hash="$(rpc getblockhash "[${height}]" | tr -d '"')"
rpc getblock "[\"${hash}\"]" | jq '{height, hash, time, size, tx: (.tx | length)}'

echo
echo "Node is at block ${height}."

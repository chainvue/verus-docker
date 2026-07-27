#!/usr/bin/env bash
# PBaaS chain support.
#
# THE THING NOBODY DOCUMENTS: a PBaaS daemon does not read its chain definition
# from disk. On startup verusd reads rpcuser/rpcpassword/rpcport/rpchost out of
# the VRSC config and issues a live `getcurrency` JSON-RPC call to the root
# chain. If that call fails the daemon exits with "Cannot find blockchain data".
#
# So running any PBaaS chain requires a reachable, sufficiently synced Verus
# root node. This module resolves it, waits for it, verifies the chain actually
# exists on it, and leaves behind the config shim the daemon expects.

# Marks a config as one we generated, so we never overwrite a real daemon's.
readonly ROOT_CONF_SHIM_MARKER="# verus-docker:root-chain-pointer"

ROOT_RPC_HOST_RESOLVED=""
ROOT_RPC_PORT_RESOLVED=""
ROOT_RPC_USER_RESOLVED=""
ROOT_RPC_PASSWORD_RESOLVED=""
PBAAS_CURRENCY_ID=""

# Parse ROOT_RPC_URL (http://user:pass@host:port) into its components.
_parse_root_rpc_url() {
	local url="$1" rest scheme creds hostport

	scheme="${url%%://*}"
	rest="${url#*://}"

	if [[ "$scheme" == "https" ]]; then
		log_error "ROOT_RPC_URL uses https://, which cannot work for PBaaS chain resolution."
		log_error ""
		log_error "verusd performs the root-chain lookup itself over plain HTTP to a"
		log_error "host:port pair — it cannot speak TLS and it cannot follow a URL path."
		log_error "A public gateway such as https://api.verus.services therefore cannot"
		log_error "serve as the root node for a PBaaS container."
		log_error ""
		log_error "Use a Verus node you can reach over plain HTTP on a private network"
		log_error "(see examples/compose.pbaas.yml), or terminate TLS in a local proxy"
		log_error "and point ROOT_RPC_URL at that proxy."
		die "unsupported ROOT_RPC_URL scheme: https"
	fi

	if [[ "$rest" == *"@"* ]]; then
		creds="${rest%%@*}"
		hostport="${rest#*@}"
		ROOT_RPC_USER_RESOLVED="${creds%%:*}"
		ROOT_RPC_PASSWORD_RESOLVED="${creds#*:}"
	else
		hostport="$rest"
	fi

	hostport="${hostport%%/*}"
	ROOT_RPC_HOST_RESOLVED="${hostport%%:*}"
	if [[ "$hostport" == *":"* ]]; then
		ROOT_RPC_PORT_RESOLVED="${hostport##*:}"
	fi
}

# Work out how to reach the root chain, in priority order:
#   1. ROOT_RPC_URL
#   2. ROOT_RPC_HOST / ROOT_RPC_PORT / ROOT_RPC_USER / ROOT_RPC_PASSWORD
#   3. an existing VRSC config in this container (the co-located pattern)
resolve_root_rpc() {
	local root_conf="${VERUS_HOME}/.komodo/VRSC/VRSC.conf"
	local default_port="$VRSC_DEFAULT_RPC"

	if [[ "${ROOT_CHAIN_CANON:-VRSC}" == "VRSCTEST" ]]; then
		default_port="$VRSCTEST_DEFAULT_RPC"
		root_conf="${VERUS_HOME}/.komodo/vrsctest/vrsctest.conf"
	fi

	if [[ -n "${ROOT_RPC_URL:-}" ]]; then
		_parse_root_rpc_url "$ROOT_RPC_URL"
	fi

	ROOT_RPC_HOST_RESOLVED="${ROOT_RPC_HOST:-$ROOT_RPC_HOST_RESOLVED}"
	ROOT_RPC_PORT_RESOLVED="${ROOT_RPC_PORT:-$ROOT_RPC_PORT_RESOLVED}"
	ROOT_RPC_USER_RESOLVED="${ROOT_RPC_USER:-$ROOT_RPC_USER_RESOLVED}"
	ROOT_RPC_PASSWORD_RESOLVED="${ROOT_RPC_PASSWORD:-$ROOT_RPC_PASSWORD_RESOLVED}"

	# Fall back to a config that is already in this container.
	if [[ -z "$ROOT_RPC_HOST_RESOLVED" && -f "$root_conf" ]]; then
		log_info "using the local ${ROOT_CHAIN_CANON:-VRSC} config as the root RPC source"
		log_warn "this resolves the root chain to 127.0.0.1, which only reaches a daemon"
		log_warn "sharing THIS container's network namespace (network_mode: service:<root>,"
		log_warn "or host networking). A root node in a separate container will not answer —"
		log_warn "set ROOT_RPC_HOST instead. See docs/pbaas.md."
		ROOT_RPC_HOST_RESOLVED="127.0.0.1"
		[[ -n "$ROOT_RPC_USER_RESOLVED" ]] ||
			ROOT_RPC_USER_RESOLVED="$(awk -F= '/^[[:space:]]*rpcuser[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$root_conf" || true)"
		[[ -n "$ROOT_RPC_PASSWORD_RESOLVED" ]] ||
			ROOT_RPC_PASSWORD_RESOLVED="$(awk -F= '/^[[:space:]]*rpcpassword[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$root_conf" || true)"
		[[ -n "$ROOT_RPC_PORT_RESOLVED" ]] ||
			ROOT_RPC_PORT_RESOLVED="$(awk -F= '/^[[:space:]]*rpcport[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$root_conf" || true)"
	fi

	ROOT_RPC_PORT_RESOLVED="${ROOT_RPC_PORT_RESOLVED:-$default_port}"

	if [[ -z "$ROOT_RPC_HOST_RESOLVED" || -z "$ROOT_RPC_USER_RESOLVED" || -z "$ROOT_RPC_PASSWORD_RESOLVED" ]]; then
		log_error "Chain '${CHAIN_NAME}' is a PBaaS chain, which needs a Verus root node."
		log_error ""
		log_error "verusd resolves the chain definition by calling getcurrency on the root"
		log_error "chain at startup. Tell this container where that node is:"
		log_error ""
		log_error "  ROOT_RPC_HOST=vrsc          # service name of your VRSC container"
		log_error "  ROOT_RPC_PORT=${default_port}"
		log_error "  ROOT_RPC_USER=<user>"
		log_error "  ROOT_RPC_PASSWORD=<password>"
		log_error ""
		log_error "Mounting the root chain's data volume here is NOT enough on its own: the"
		log_error "config it contains points at 127.0.0.1, which is this container, not the"
		log_error "root daemon. That path only works with a shared network namespace."
		log_error "A complete working example lives in examples/compose.pbaas.yml."
		die "no root chain RPC configured for PBaaS chain '${CHAIN_NAME}'"
	fi

	log_info "root chain RPC: http://${ROOT_RPC_HOST_RESOLVED}:${ROOT_RPC_PORT_RESOLVED} (chain ${ROOT_CHAIN_CANON:-VRSC})"
}

_root_url() {
	printf 'http://%s:%s/\n' "$ROOT_RPC_HOST_RESOLVED" "$ROOT_RPC_PORT_RESOLVED"
}

_root_rpc() {
	rpc_call "$(_root_url)" "$ROOT_RPC_USER_RESOLVED" "$ROOT_RPC_PASSWORD_RESOLVED" "$@"
}

# Block until the root node answers and has caught up far enough to serve a
# meaningful chain definition.
wait_for_root_chain() {
	local timeout="${ROOT_WAIT_TIMEOUT:-900}"
	local min_progress="${ROOT_MIN_PROGRESS:-0.999}"
	local deadline=$((SECONDS + timeout))
	local info progress blocks reported=0

	log_info "waiting for the root chain to become available (timeout ${timeout}s)..."

	while ((SECONDS < deadline)); do
		if info="$(_root_rpc getblockchaininfo)"; then
			progress="$(jq -r '.verificationprogress // 0' <<<"$info")"
			blocks="$(jq -r '.blocks // 0' <<<"$info")"

			if awk -v p="$progress" -v m="$min_progress" 'BEGIN {exit !(p >= m)}'; then
				log_info "root chain ready at block ${blocks} (progress $(awk -v p="$progress" 'BEGIN {printf "%.2f%%", p * 100}'))"
				return 0
			fi

			if ((reported % 6 == 0)); then
				log_info "  root chain still syncing: block ${blocks}, progress $(awk -v p="$progress" 'BEGIN {printf "%.2f%%", p * 100}')"
			fi
		elif ((reported % 6 == 0)); then
			log_info "  root chain not answering yet at $(_root_url)"
		fi

		reported=$((reported + 1))
		sleep 10
	done

	log_error "the root chain did not become ready within ${timeout}s."
	log_error "Raise ROOT_WAIT_TIMEOUT if the root node is still doing its initial sync;"
	log_error "a PBaaS chain cannot start before its root chain is usable."
	die "timed out waiting for the root chain"
}

# Confirm the chain exists before handing it to the daemon, so a typo produces a
# clear message instead of "Cannot find blockchain data".
verify_chain_exists() {
	local result

	log_info "resolving chain definition for '${CHAIN_NAME}' on the root chain..."

	if ! result="$(_root_rpc getcurrency "[\"${CHAIN_NAME}\"]")"; then
		log_error "The root chain does not know a currency called '${CHAIN_NAME}'."
		log_error "Check the spelling, or pass the chain's i-address instead."
		log_error "PBaaS chain names are VerusIDs — 'chips', 'varrr' and 'vdex' are examples."
		die "unknown chain '${CHAIN_NAME}'"
	fi

	PBAAS_CURRENCY_ID="$(jq -r '.currencyid // empty' <<<"$result")"
	if [[ -z "$PBAAS_CURRENCY_ID" ]]; then
		die "root chain returned no currencyid for '${CHAIN_NAME}'"
	fi

	log_info "  currency id: ${PBAAS_CURRENCY_ID}"
	log_info "  name:        $(jq -r '.fullyqualifiedname // .name // "unknown"' <<<"$result")"
}

# verusd looks for the root credentials in the VRSC config, so make sure one is
# there and points at the node we just validated.
write_root_conf_shim() {
	local root_conf="${VERUS_HOME}/.komodo/VRSC/VRSC.conf"
	local tmp

	[[ "${ROOT_CHAIN_CANON:-VRSC}" != "VRSCTEST" ]] ||
		root_conf="${VERUS_HOME}/.komodo/vrsctest/vrsctest.conf"

	# Only ever replace a shim we wrote ourselves. If the file has no marker it
	# belongs to a real root daemon — most likely because its data volume is
	# shared into this container — and clobbering it would strip that node's
	# rpcallowip, indexes and credentials on its next restart.
	if [[ -f "$root_conf" ]] && ! grep -q "$ROOT_CONF_SHIM_MARKER" "$root_conf" 2>/dev/null; then
		log_info "a real ${ROOT_CHAIN_CANON:-VRSC} config exists at ${root_conf}; leaving it untouched"
		if [[ -n "${ROOT_RPC_HOST:-}${ROOT_RPC_URL:-}" ]]; then
			log_banner_warning \
				"ROOT_RPC_* is set, but a real root config is mounted here." \
				"" \
				"verusd reads the root chain's host and credentials from that" \
				"config, not from ROOT_RPC_*, so your setting is ignored for the" \
				"daemon's own lookup. If that config says rpchost=127.0.0.1 and" \
				"the root daemon is in another container, the chain will fail to" \
				"start." \
				"" \
				"Either stop mounting the root config here, or give the two" \
				"containers a shared network namespace."
		fi
		return 0
	fi

	mkdir -p -- "$(dirname -- "$root_conf")"
	tmp="${root_conf}.tmp.$$"
	: >"$tmp"
	chmod 600 "$tmp"
	cat >"$tmp" <<EOF
${ROOT_CONF_SHIM_MARKER}
# Generated by verus-docker as a ROOT CHAIN POINTER for PBaaS chain ${CHAIN_NAME}.
# No ${ROOT_CHAIN_CANON:-VRSC} daemon runs in this container. verusd reads these values
# to find the root chain when it resolves the PBaaS chain definition.
rpchost=${ROOT_RPC_HOST_RESOLVED}
rpcport=${ROOT_RPC_PORT_RESOLVED}
rpcuser=${ROOT_RPC_USER_RESOLVED}
rpcpassword=${ROOT_RPC_PASSWORD_RESOLVED}
EOF
	mv -f -- "$tmp" "$root_conf"
	chmod 600 "$root_conf"
	log_debug "wrote root chain pointer to ${root_conf}"
}

# Everything a PBaaS chain needs before verusd is executed.
prepare_pbaas() {
	resolve_root_rpc
	wait_for_root_chain
	verify_chain_exists
	write_root_conf_shim
}

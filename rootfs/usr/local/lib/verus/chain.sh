#!/usr/bin/env bash
# shellcheck disable=SC2034  # these globals are consumed by the scripts that source this file
# Chain resolution: turn the CHAIN env var into paths, ports and a chain kind.
#
# There is deliberately NO whitelist of PBaaS chains. Anything that is not the
# Verus root chain or its testnet is treated as a PBaaS chain and handed to
# verusd via -chain=<name>; the daemon resolves the definition from the root
# chain at runtime. The chains/ metadata directory is a convenience cache for
# things we cannot discover (bootstrap URLs, sensible port assignments) and an
# unknown chain must degrade gracefully, never fail.

readonly CHAIN_METADATA_DIR="${CHAIN_METADATA_DIR:-/usr/local/share/verus-docker/chains}"

# Upstream defaults, verified against VerusCoin v1.2.17-2 source
# (chainparamsseeds.h for P2P; komodo_utils.h enforces RPC = P2P + 1).
readonly VRSC_DEFAULT_P2P=27485
readonly VRSC_DEFAULT_RPC=27486
readonly VRSCTEST_DEFAULT_P2P=18842
readonly VRSCTEST_DEFAULT_RPC=18843

# Populated by resolve_chain().
CHAIN_NAME=""    # canonical name passed to -chain=
CHAIN_SLUG=""    # lowercase; used for file names and metadata lookup
CHAIN_KIND=""    # root | testnet | pbaas
CHAIN_HOME=""    # the directory that should be a mounted volume
CHAIN_DATADIR="" # empty for PBaaS: the daemon derives it from a hash
CHAIN_CONF=""    # empty for PBaaS: see pbaas.sh, settings go on the CLI
CHAIN_META_FILE=""
DEFAULT_P2P_PORT=""
DEFAULT_RPC_PORT=""

resolve_chain() {
	local requested="${CHAIN:-VRSC}"
	local upper="${requested^^}"

	[[ -n "$requested" ]] || die "CHAIN must not be empty"

	CHAIN_SLUG="${requested,,}"

	case "$upper" in
	VRSC)
		CHAIN_NAME="VRSC"
		CHAIN_KIND="root"
		CHAIN_HOME="${VERUS_HOME}/.komodo"
		CHAIN_DATADIR="${CHAIN_HOME}/VRSC"
		CHAIN_CONF="${CHAIN_DATADIR}/VRSC.conf"
		DEFAULT_P2P_PORT="$VRSC_DEFAULT_P2P"
		DEFAULT_RPC_PORT="$VRSC_DEFAULT_RPC"
		;;
	VRSCTEST)
		# The data directory and the config file are both lowercase here even
		# though the chain is conventionally written VRSCTEST. Getting this
		# wrong produces a daemon that silently ignores your configuration.
		CHAIN_NAME="VRSCTEST"
		CHAIN_KIND="testnet"
		CHAIN_HOME="${VERUS_HOME}/.komodo"
		CHAIN_DATADIR="${CHAIN_HOME}/vrsctest"
		CHAIN_CONF="${CHAIN_DATADIR}/vrsctest.conf"
		DEFAULT_P2P_PORT="$VRSCTEST_DEFAULT_P2P"
		DEFAULT_RPC_PORT="$VRSCTEST_DEFAULT_RPC"
		;;
	*)
		# Any other name or i-address: a PBaaS chain. Pass the user's spelling
		# through untouched — chain names are VerusID names and we must not
		# assume a normalisation the daemon does not apply.
		CHAIN_NAME="$requested"
		CHAIN_KIND="pbaas"
		if [[ "${ROOT_CHAIN:-VRSC}" == "VRSCTEST" || "${ROOT_CHAIN:-VRSC}" == "vrsctest" ]]; then
			CHAIN_HOME="${VERUS_HOME}/.verustest"
		else
			CHAIN_HOME="${VERUS_HOME}/.verus"
		fi
		# CHAIN_DATADIR stays empty on purpose. verusd stores PBaaS chains in
		# <CHAIN_HOME>/pbaas/<hash>/ where <hash> is derived from the chain's
		# currency ID. Rather than reimplement that derivation, we mount
		# CHAIN_HOME and let the daemon create the directory itself.
		DEFAULT_P2P_PORT=""
		DEFAULT_RPC_PORT=""
		;;
	esac

	load_chain_metadata
}

# Reads chains/<slug>.json if it exists. Absence is normal and not an error.
load_chain_metadata() {
	local candidate="${CHAIN_METADATA_DIR}/${CHAIN_SLUG}.json"

	CHAIN_META_FILE=""
	if [[ -r "$candidate" ]]; then
		if jq -e . "$candidate" >/dev/null 2>&1; then
			CHAIN_META_FILE="$candidate"
			log_debug "loaded chain metadata from ${candidate}"
		else
			log_warn "chain metadata ${candidate} is not valid JSON — ignoring it"
		fi
		return 0
	fi

	log_debug "no bundled metadata for chain '${CHAIN_SLUG}' (this is fine)"
}

# chain_meta <jq-path> — echoes the value or an empty string.
chain_meta() {
	local path="$1"
	[[ -n "$CHAIN_META_FILE" ]] || return 0
	jq -r "${path} // empty" "$CHAIN_META_FILE" 2>/dev/null || true
}

# Resolve the effective ports, in order: explicit env var, bundled metadata,
# upstream default. PBaaS chains have no predictable default — the daemon
# derives the P2P port from a CRC32 of the chain definition — so we require an
# explicit value and say so clearly.
resolve_ports() {
	local meta_p2p meta_rpc

	meta_p2p="$(chain_meta '.ports.p2p')"
	meta_rpc="$(chain_meta '.ports.rpc')"

	P2P_PORT="${P2P_PORT:-${meta_p2p:-$DEFAULT_P2P_PORT}}"
	RPC_PORT="${RPC_PORT:-${meta_rpc:-$DEFAULT_RPC_PORT}}"

	if [[ -z "$P2P_PORT" || -z "$RPC_PORT" ]]; then
		log_error "No port assignment is known for chain '${CHAIN_NAME}'."
		log_error "PBaaS P2P ports are derived by the daemon from the chain definition"
		log_error "and are not predictable, so they must be pinned explicitly."
		die "set P2P_PORT and RPC_PORT for chain '${CHAIN_NAME}'"
	fi

	[[ "$P2P_PORT" =~ ^[0-9]+$ ]] || die "P2P_PORT must be numeric, got '${P2P_PORT}'"
	[[ "$RPC_PORT" =~ ^[0-9]+$ ]] || die "RPC_PORT must be numeric, got '${RPC_PORT}'"
	[[ "$P2P_PORT" != "$RPC_PORT" ]] || die "P2P_PORT and RPC_PORT must differ"
}

# The credentials file lives inside the mounted volume so it survives restarts
# and is reachable by sidecars, but never inside the image.
chain_credentials_file() {
	if [[ -n "$CHAIN_DATADIR" ]]; then
		printf '%s\n' "${CHAIN_DATADIR}/rpc-credentials"
	else
		printf '%s\n' "${CHAIN_HOME}/${CHAIN_SLUG}.rpc-credentials"
	fi
}

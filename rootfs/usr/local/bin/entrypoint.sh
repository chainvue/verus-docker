#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# verus-docker entrypoint.
#
# Prepares the data directory, configuration, Zcash parameters and (optionally)
# a verified bootstrap, then runs verusd in the foreground with clean signal
# handling.
#
# Design note on shutdown: verusd flushes its databases on exit and that can
# take a long time on a synced mainnet node. Killing it early corrupts the
# chain state and forces a multi-hour reindex. That is why this script forwards
# SIGTERM and then waits, and why every deployment example sets a generous
# grace period.

set -euo pipefail

readonly LIB_DIR="/usr/local/lib/verus"
# shellcheck source=../lib/verus/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/verus/chain.sh
source "${LIB_DIR}/chain.sh"
# shellcheck source=../lib/verus/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=../lib/verus/params.sh
source "${LIB_DIR}/params.sh"
# shellcheck source=../lib/verus/bootstrap.sh
source "${LIB_DIR}/bootstrap.sh"
# shellcheck source=../lib/verus/pbaas.sh
source "${LIB_DIR}/pbaas.sh"

readonly VERUSD_BIN="/opt/verus-cli/verusd"
VERUSD_PID=""

# ---------------------------------------------------------------------------
# Privilege handling
#
# The image runs as the unprivileged `verus` user by default and never needs
# root. Starting the container as root is supported purely so that PUID/PGID
# can be remapped to match a host bind-mount's ownership; in that case we fix
# ownership and immediately drop privileges.
# ---------------------------------------------------------------------------

maybe_drop_privileges() {
	local target_uid="${PUID:-1000}" target_gid="${PGID:-1000}"
	local current_uid current_gid

	[[ "$(id -u)" == "0" ]] || return 0

	log_info "started as root; remapping the verus user to ${target_uid}:${target_gid} and dropping privileges"

	current_gid="$(id -g verus)"
	current_uid="$(id -u verus)"

	if [[ "$current_gid" != "$target_gid" ]]; then
		groupmod -o -g "$target_gid" verus
	fi
	if [[ "$current_uid" != "$target_uid" ]]; then
		usermod -o -u "$target_uid" verus
	fi

	# Only the directories we own; a large bind mount is not chowned wholesale.
	chown "${target_uid}:${target_gid}" "$VERUS_HOME"
	local dir
	for dir in "${VERUS_HOME}/.komodo" "${VERUS_HOME}/.verus" \
		"${VERUS_HOME}/.verustest" "${VERUS_HOME}/.zcash-params"; do
		[[ -d "$dir" ]] || continue
		if [[ "$(stat -c '%u' "$dir")" != "$target_uid" ]]; then
			log_info "fixing ownership of ${dir} (this can take a moment on a large volume)"
			chown -R "${target_uid}:${target_gid}" "$dir"
		fi
	done

	exec gosu "${target_uid}:${target_gid}" "$0" "$@"
}

# ---------------------------------------------------------------------------
# Startup banner
# ---------------------------------------------------------------------------

print_banner() {
	local datadir="$1"
	cat >&2 <<EOF

  ┌───────────────────────────────────────────────────────────────┐
  │  verus-docker — production Verus nodes in containers          │
  └───────────────────────────────────────────────────────────────┘
    chain          : ${CHAIN_NAME} (${CHAIN_KIND})
    verusd version : ${VERUS_VERSION:-unknown}
    image revision : ${IMAGE_REVISION:-unknown}
    data directory : ${datadir}
    zcash params   : $(params_dir)
    rpc endpoint   : http://0.0.0.0:${RPC_PORT} (inside the container network)
    p2p port       : ${P2P_PORT}
    wallet         : $(is_true "${DISABLE_WALLET:-false}" && echo "disabled (-disablewallet)" || echo "enabled")
    staking        : $(is_true "${ENABLE_STAKING:-false}" && echo "enabled (-mint)" || echo "disabled")
    running as     : uid $(id -u), gid $(id -g)

EOF
}

warn_about_wallet() {
	is_true "${DISABLE_WALLET:-false}" && return 0
	[[ "${WALLET_WARNING:-true}" == "true" ]] || return 0

	log_banner_warning \
		"This node has a wallet enabled." \
		"" \
		"wallet.dat lives in the data volume and is the ONLY copy of your keys." \
		"Chain data can always be re-downloaded. A lost wallet.dat cannot." \
		"" \
		"Back it up before you need it, and keep the backup off this host." \
		"See docs/production.md for a safe backup procedure for a running node." \
		"" \
		"Running pure RPC infrastructure? Set DISABLE_WALLET=true and this" \
		"whole class of risk disappears."
}

# ---------------------------------------------------------------------------
# Argument assembly
# ---------------------------------------------------------------------------

build_verusd_args() {
	local -n out="$1"
	local allow extra

	out=()

	# VRSC is the daemon's own default; passing -chain for it is harmless but
	# noisy, so only non-default chains get the flag.
	[[ "$CHAIN_NAME" == "VRSC" ]] || out+=("-chain=${CHAIN_NAME}")

	# Logs must go to stdout, not debug.log, for `docker logs` to be useful.
	out+=("-printtoconsole")

	# PBaaS chains have no config file we can write ahead of time, because the
	# directory is named after a hash the daemon computes at runtime. Everything
	# therefore goes on the command line, which also takes precedence over the
	# config verusd writes for itself.
	if [[ "$CHAIN_KIND" == "pbaas" ]]; then
		out+=(
			"-server=1"
			"-rpcuser=${RPC_USER}"
			"-rpcpassword=${RPC_PASSWORD}"
			"-rpcport=${RPC_PORT}"
			"-rpcbind=0.0.0.0"
			"-port=${P2P_PORT}"
			"-txindex=${TXINDEX:-1}"
		)
		for allow in "${RPC_ALLOW_LIST[@]}"; do
			out+=("-rpcallowip=${allow}")
		done
		is_true "${DISABLE_WALLET:-false}" && out+=("-disablewallet")
		is_true "${ENABLE_STAKING:-false}" && out+=("-mint")
		[[ -n "${MAX_CONNECTIONS:-}" ]] && out+=("-maxconnections=${MAX_CONNECTIONS}")
	fi

	# EXTRA_ARGS is passed through verbatim, split on whitespace.
	if [[ -n "${EXTRA_ARGS:-}" ]]; then
		read -r -a extra <<<"$EXTRA_ARGS"
		out+=("${extra[@]}")
	fi

	# Anything after the entrypoint on the command line wins over everything.
	if (($# > 1)); then
		shift
		out+=("$@")
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

forward_signal() {
	local sig="$1"

	[[ -n "$VERUSD_PID" ]] || exit 0

	log_info "received SIG${sig}; asking verusd to shut down cleanly"
	log_info "verusd flushes its databases on exit — do NOT kill it early, that is how"
	log_info "chain state gets corrupted. Allow at least 120s (more on a synced mainnet)."
	kill -TERM "$VERUSD_PID" 2>/dev/null || true
}

run_verusd() {
	local -a args=("$@")
	local -a shown=()
	local rc=0 arg

	# Never let the RPC password reach the logs.
	for arg in "${args[@]}"; do
		case "$arg" in
		-rpcpassword=*) shown+=("-rpcpassword=<redacted>") ;;
		*) shown+=("$arg") ;;
		esac
	done
	log_info "starting: verusd ${shown[*]}"

	"$VERUSD_BIN" "${args[@]}" &
	VERUSD_PID=$!

	trap 'forward_signal TERM' TERM
	trap 'forward_signal INT' INT

	# `wait` is interrupted by a trapped signal and returns >128; in that case
	# we go around again and keep waiting for the real exit.
	while kill -0 "$VERUSD_PID" 2>/dev/null; do
		rc=0
		wait "$VERUSD_PID" || rc=$?
		((rc > 128)) && continue
		break
	done

	if ((rc == 0)); then
		log_info "verusd exited cleanly"
	else
		log_warn "verusd exited with status ${rc}"
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
	local datadir creds_file
	local -a verusd_args=()

	maybe_drop_privileges "$@"

	require_cmd curl jq awk tar sha256sum

	resolve_chain
	resolve_ports

	creds_file="$(chain_credentials_file)"
	mkdir -p -- "$CHAIN_HOME"

	if [[ "$CHAIN_KIND" == "pbaas" ]]; then
		# The daemon owns the directory name, so there is no config file for us
		# to write. Credentials still need to be stable across restarts.
		resolve_rpc_allow_ip
		setup_credentials "$creds_file"
		datadir="${CHAIN_HOME}/pbaas/<hash derived by verusd at runtime>"
	else
		datadir="$CHAIN_DATADIR"
		mkdir -p -- "$datadir"
		ensure_config "$CHAIN_CONF" "$creds_file"
	fi

	ensure_params

	# A no-op for PBaaS chains, which have no directory to extract into yet.
	maybe_bootstrap "$CHAIN_DATADIR"

	if [[ "$CHAIN_KIND" == "pbaas" ]]; then
		prepare_pbaas
	fi

	warn_about_wallet
	print_banner "$datadir"

	build_verusd_args verusd_args "$@"
	run_verusd "${verusd_args[@]}"
}

main "$@"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
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

	[[ "$target_uid" =~ ^[0-9]+$ && "$target_gid" =~ ^[0-9]+$ ]] ||
		die "PUID and PGID must be numeric (got PUID='${target_uid}' PGID='${target_gid}')"

	# Dropping to uid 0 is not dropping anything, and re-execing would loop
	# forever because this function would run again and find itself root.
	if [[ "$target_uid" == "0" ]]; then
		die "PUID=0 would run the daemon as root. This image never needs root; unset PUID or set it to a non-zero uid."
	fi

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
	local dir sentinel
	for dir in "${VERUS_HOME}/.komodo" "${VERUS_HOME}/.verus" \
		"${VERUS_HOME}/.verustest" "${VERUS_HOME}/.zcash-params"; do
		[[ -d "$dir" ]] || continue

		# Written only after a chown -R has run to completion. Testing the
		# directory's own owner is not enough: chown -R walks pre-order, so a
		# run killed partway through a 200 GB volume leaves the top directory
		# already correct and every file below it still owned by the old uid.
		sentinel="${dir}/.verus-owned-by-${target_uid}-${target_gid}"
		[[ -f "$sentinel" ]] && continue

		log_info "fixing ownership of ${dir} (this can take a moment on a large volume)"
		chown -R "${target_uid}:${target_gid}" "$dir"
		: >"$sentinel"
		chown "${target_uid}:${target_gid}" "$sentinel"
	done

	exec gosu "${target_uid}:${target_gid}" "$0" "$@"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Combinations that are contradictory or that upstream documents as invalid.
# Checked before any expensive work, so the operator finds out in seconds
# rather than after a multi-hour download.
validate_env_combinations() {
	# Checked here as well as during argument assembly, because assembly happens
	# after the parameter and bootstrap downloads — far too late to be told the
	# container was never going to be allowed to start.
	if [[ -n "${EXTRA_ARGS:-}" ]]; then
		local -a early=()
		read -r -a early <<<"$EXTRA_ARGS"
		reject_destructive_args "${early[@]}"
	fi

	# Staking needs a wallet to stake from. init.cpp only starts the staking
	# thread when a wallet is loaded (or -mineraddress is set), so this pair
	# produces a node that looks configured for staking and never stakes.
	if is_true "${ENABLE_STAKING:-false}" && is_true "${DISABLE_WALLET:-false}"; then
		log_banner_warning \
			"ENABLE_STAKING and DISABLE_WALLET are both set." \
			"" \
			"Staking requires a wallet — there is nothing to stake without one." \
			"The daemon would start, report no error, and never stake." \
			"" \
			"Pick one: DISABLE_WALLET=true for pure RPC infrastructure, or" \
			"ENABLE_STAKING=true for a staking node."
		die "ENABLE_STAKING and DISABLE_WALLET cannot both be true"
	fi

	# Upstream's option list marks both of these "Activating requires
	# reindexing, not compatible with bootstrap". A bootstrap hands you chain
	# data built without the index, so the daemon has to reindex the whole
	# thing afterwards — which is exactly the work the bootstrap was meant to
	# avoid. Warn rather than refuse: it does eventually work.
	if is_true "${USE_BOOTSTRAP:-false}"; then
		local idx
		for idx in IDINDEX TIMESTAMPINDEX; do
			is_true "${!idx:-false}" || continue
			log_banner_warning \
				"${idx}=true together with USE_BOOTSTRAP=true." \
				"" \
				"Upstream documents this index as 'not compatible with bootstrap'." \
				"A bootstrap gives you chain data built without it, so the daemon" \
				"must then reindex from scratch — hours of work that cancels out" \
				"most of what the bootstrap saved you." \
				"" \
				"Consider syncing from the network instead, or enabling the index" \
				"later once the bootstrap has been ingested."
		done
	fi

	# timestampindex is forced to equal insightexplorer every time the block
	# index is loaded (main.cpp LoadBlockIndexDB). Setting it on its own buys a
	# reindex on first start and then reports the index disabled from the
	# second start onward. Upstream's own option list says as much:
	# "-insightexplorer ... If disabled, forces timestampindex to disabled".
	if is_true "${TIMESTAMPINDEX:-false}" && ! is_true "${INSIGHT_EXPLORER:-false}"; then
		log_banner_warning \
			"TIMESTAMPINDEX=true without INSIGHT_EXPLORER=true has no effect." \
			"" \
			"The daemon forces timestampindex to match insightexplorer whenever" \
			"it loads the block index. You would pay for a full reindex on the" \
			"first start and still find the index disabled on the second." \
			"" \
			"Set INSIGHT_EXPLORER=true as well if you need timestamp queries."
	fi
}

# The failure mode this replaces was a bare "mkdir: Permission denied" with no
# indication of which uid was expected or how to fix it — the shape you get from
# an OpenShift-style runAsUser override or a host bind mount owned by someone
# else.
preflight_writable() {
	local dir="$1" probe owner
	local check="$dir"

	# Walk up to the nearest directory that exists; that is the one that has to
	# be writable for the mkdir below to succeed.
	while [[ ! -d "$check" && "$check" != "/" ]]; do
		check="$(dirname -- "$check")"
	done

	probe="${check}/.verus-write-probe.$$"
	if (: >"$probe") 2>/dev/null; then
		rm -f -- "$probe"
		return 0
	fi

	owner="$(stat -c '%u:%g' "$check" 2>/dev/null || echo 'unknown')"
	log_banner_warning \
		"The data volume is not writable by this container." \
		"" \
		"directory:   ${check}" \
		"owned by:    uid:gid ${owner}" \
		"running as:  uid:gid $(id -u):$(id -g)" \
		"" \
		"Two ways to fix it:" \
		"  * Start the container as root with PUID/PGID set to the owning uid," \
		"    and it will remap the verus user and drop privileges itself." \
		"  * Or chown the volume on the host to match the uid above." \
		"" \
		"On Kubernetes, setting spec.securityContext.fsGroup usually does this" \
		"for you. See docs/troubleshooting.md."
	die "cannot write to ${check}"
}

# Held for the lifetime of the process, so the lock is released on exit however
# we exit.
DATADIR_LOCK_FD=""

# verusd takes its own .lock, but only once it is running — by which time this
# script may already have run the bootstrap recovery path, including its
# rm -rf of blocks/ and chainstate/, against a healthy node's data.
acquire_datadir_lock() {
	local lock="${CHAIN_HOME}/.verus-docker.lock"

	exec {DATADIR_LOCK_FD}>"$lock" || return 0
	if ! flock --nonblock "$DATADIR_LOCK_FD"; then
		log_banner_warning \
			"Another container is already using this data volume." \
			"" \
			"volume: ${CHAIN_HOME}" \
			"" \
			"Two nodes cannot share one chain directory. Give this container its" \
			"own volume, or stop the other one first." \
			"" \
			"If you are certain no other node is running, a stale lock can be" \
			"cleared by removing ${lock}."
		die "data volume ${CHAIN_HOME} is locked by another container"
	fi
}

# ---------------------------------------------------------------------------
# Startup banner
# ---------------------------------------------------------------------------

# Effective, not requested. For chains with a config file the file wins over
# the environment, so reading the env var here would cheerfully report
# "staking: enabled" on a node that is not going to stake.
effective_flag() {
	local flag="$1" env_value="$2"
	if [[ -n "${CHAIN_CONF:-}" && -f "${CHAIN_CONF:-}" ]]; then
		conf_flag_enabled "$CHAIN_CONF" "$flag" && return 0
		return 1
	fi
	is_true "$env_value"
}

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
    wallet         : $(effective_flag disablewallet "${DISABLE_WALLET:-false}" && echo "disabled (-disablewallet)" || echo "enabled")
    staking        : $(effective_flag mint "${ENABLE_STAKING:-false}" && echo "enabled (-mint)" || echo "disabled")
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
		# PBAAS_TESTMODE is set from the chain name only for the literal string
		# "vrsctest" (komodo_utils.h). For any other chain name -testnet is the
		# ONLY thing that turns it on, and without it the daemon reads the
		# MAINNET root config and looks for the chain under ~/.verus — while we
		# have written the shim to ~/.komodo/vrsctest and mounted ~/.verustest.
		# The result is either an immediate exit or, worse, a testnet chain
		# resolved against mainnet VRSC.
		#
		# Safe to pass: NetworkIdFromCommandLine() returns MAIN unconditionally,
		# so this flips testmode without adding a testnet3/ path component.
		if [[ "$ROOT_CHAIN_CANON" == "VRSCTEST" ]]; then
			out+=("-testnet")
		fi
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

	reject_destructive_args "${out[@]}"
	return 0
}

# The daemon has flags that destroy data on every single start. Someone who
# read the upstream option list rather than ours can reasonably think passing
# one through EXTRA_ARGS is how you request a bootstrap. It is not: -bootstrap
# wipes blocks/, chainstate/, notarisations/, peers.dat and komodostate EVERY
# time the container starts, and forces -zappwallettxes=2, which discards the
# wallet's transaction metadata.
reject_destructive_args() {
	local arg
	for arg in "$@"; do
		case "${arg%%=*}" in
		-bootstrap | -bootstrapinstall)
			log_banner_warning \
				"Refusing to start: ${arg} was passed to the daemon." \
				"" \
				"This flag is destructive on EVERY start, not just the first." \
				"It deletes blocks/, chainstate/, notarisations/, peers.dat and" \
				"komodostate, and forces -zappwallettxes=2, which discards your" \
				"wallet's transaction history metadata." \
				"" \
				"Use USE_BOOTSTRAP=true instead. It only runs when there is no" \
				"chain data yet, verifies the archive's published SHA-256 before" \
				"extracting, and never touches wallet.dat."
			die "refusing to pass ${arg} to verusd"
			;;
		-zappwallettxes)
			log_banner_warning \
				"Refusing to start: ${arg} was passed to the daemon." \
				"" \
				"This rewrites the wallet's transaction metadata. If you really" \
				"need it, run it deliberately as a one-off against a backed-up" \
				"wallet.dat — not as a standing container argument that applies" \
				"on every restart."
			die "refusing to pass ${arg} to verusd"
			;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

forward_signal() {
	local sig="$1"

	# Before the daemon exists the long-running work is a download, a hash or an
	# extraction. Those run as interruptible children precisely so this handler
	# can stop them; partial work is left on disk and resumed on the next start.
	if [[ -z "$VERUSD_PID" ]]; then
		if [[ -n "$VERUS_CHILD_PID" ]]; then
			log_info "received SIG${sig} during setup; stopping the current step"
			kill -TERM "$VERUS_CHILD_PID" 2>/dev/null || true
		fi
		log_info "received SIG${sig} before the daemon started; exiting"
		# 128+15. Exiting 0 here told `restart: on-failure` and Kubernetes that
		# an aborted setup was a successful run.
		exit 143
	fi

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

	# Installed before any long-running work, not just before exec. Note that
	# the downloads, hashes and extractions this covers all run through
	# run_interruptible — a trap handler does not fire while a foreground
	# command is still running, so without that they would sit through the
	# entire container grace period and then be SIGKILLed.
	trap 'forward_signal TERM' TERM
	trap 'forward_signal INT' INT

	require_cmd curl jq awk tar sha256sum flock df stat mktemp

	validate_env_combinations

	resolve_chain
	resolve_ports

	creds_file="$(chain_credentials_file)"
	preflight_writable "$CHAIN_HOME"
	mkdir -p -- "$CHAIN_HOME"
	acquire_datadir_lock

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

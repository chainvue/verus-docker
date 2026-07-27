#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Configuration and credential handling.
#
# Why we write our own config at all: when the config file is missing, verusd
# generates one containing `rpcallowip=127.0.0.1` and `rpchost=127.0.0.1`. That
# makes the RPC endpoint unreachable from any other container, which is the
# opposite of what anyone running this image wants. So we write the config
# first — but only ever once.

# ---------------------------------------------------------------------------
# RPC access control
# ---------------------------------------------------------------------------

# Convert an address/prefix such as 172.17.0.2/16 into its network address,
# 172.17.0.0/16, so we authorise the container network rather than one host.
_cidr_network() {
	local cidr="$1"
	local addr prefix a b c d ip mask net

	addr="${cidr%/*}"
	prefix="${cidr#*/}"

	[[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) || return 1
	IFS=. read -r a b c d <<<"$addr" || return 1
	[[ "$a$b$c$d" =~ ^[0-9]+$ ]] || return 1

	ip=$(((a << 24) | (b << 16) | (c << 8) | d))
	if ((prefix == 0)); then
		mask=0
	else
		mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
	fi
	net=$((ip & mask))

	printf '%d.%d.%d.%d/%d\n' \
		$(((net >> 24) & 255)) $(((net >> 16) & 255)) \
		$(((net >> 8) & 255)) $((net & 255)) "$prefix"
}

# Determine which networks may reach the RPC port.
#
# The default is the container's own network, never 0.0.0.0/0. 127.0.0.1 is
# always included so that `docker exec <container> verus ...` works.
resolve_rpc_allow_ip() {
	local requested="${RPC_ALLOW_IP:-auto}"
	local -a allow=("127.0.0.1")
	local cidr network

	if [[ "$requested" != "auto" ]]; then
		if [[ "$requested" == *"0.0.0.0/0"* ]]; then
			log_banner_warning \
				"RPC_ALLOW_IP contains 0.0.0.0/0." \
				"The RPC interface is now reachable from ANY address that can" \
				"route to this container. Verus RPC has no rate limiting and" \
				"controls the wallet. Never do this on a public interface." \
				"See docs/production.md for safe exposure patterns."
		fi
		# Accept comma- or space-separated lists.
		read -r -a RPC_ALLOW_LIST <<<"${requested//,/ }"
		RPC_ALLOW_LIST=("127.0.0.1" "${RPC_ALLOW_LIST[@]}")
		return 0
	fi

	cidr="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}' || true)"
	if [[ -n "$cidr" ]] && network="$(_cidr_network "$cidr")"; then
		allow+=("$network")
		log_info "RPC access restricted to the container network: ${network}"
	else
		# Detection failed (unusual network plugin, no iproute2). Fall back to
		# the private ranges rather than opening up to the world.
		allow+=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
		log_warn "could not detect the container network; falling back to RFC1918 ranges"
	fi

	RPC_ALLOW_LIST=("${allow[@]}")
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

# Populates RPC_USER / RPC_PASSWORD, generating them when unset, and persists
# them to a 0600 file inside the data volume. The values are never logged.
setup_credentials() {
	local creds_file="$1"
	local generated=false

	if [[ -z "${RPC_USER:-}" ]]; then
		RPC_USER="verus_$(random_hex 4)"
		generated=true
	fi
	if [[ -z "${RPC_PASSWORD:-}" ]]; then
		RPC_PASSWORD="$(random_hex 32)"
		generated=true
	fi

	write_credentials_file "$creds_file"

	if [[ "$generated" == true ]]; then
		log_info "Generated random RPC credentials."
		log_info "They are stored in the data volume at: ${creds_file}"
		log_info "Read them with: docker exec <container> cat ${creds_file}"
	fi
}

write_credentials_file() {
	local creds_file="$1"
	local tmp

	mkdir -p -- "$(dirname -- "$creds_file")"
	tmp="${creds_file}.tmp.$$"

	# Create with restrictive permissions before writing any secret material.
	: >"$tmp"
	chmod 600 "$tmp"
	cat >"$tmp" <<EOF
# verus-docker RPC credentials for chain ${CHAIN_NAME}
# Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Treat this file as a secret.
RPC_USER=${RPC_USER:-}
RPC_PASSWORD=${RPC_PASSWORD:-}
RPC_PORT=${RPC_PORT:-}
RPC_URL=http://127.0.0.1:${RPC_PORT:-}
CHAIN=${CHAIN_NAME}
EOF
	mv -f -- "$tmp" "$creds_file"
	chmod 600 "$creds_file"
}

# Re-read credentials out of an existing config file so that the CLI wrapper,
# the healthcheck and the exporter keep working when an operator supplied their
# own hand-tuned config.
load_credentials_from_conf() {
	local conf="$1"
	local user pass port

	user="$(awk -F= '/^[[:space:]]*rpcuser[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$conf" || true)"
	pass="$(awk -F= '/^[[:space:]]*rpcpassword[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$conf" || true)"
	port="$(awk -F= '/^[[:space:]]*rpcport[[:space:]]*=/ {sub(/^[^=]*=/, ""); print; exit}' "$conf" || true)"

	[[ -n "$user" ]] && RPC_USER="$user"
	[[ -n "$pass" ]] && RPC_PASSWORD="$pass"
	[[ -n "$port" ]] && RPC_PORT="$port"

	if [[ -z "${RPC_USER:-}" || -z "${RPC_PASSWORD:-}" ]]; then
		log_warn "existing config has no rpcuser/rpcpassword; the CLI wrapper may need explicit flags"
	fi
}

# ---------------------------------------------------------------------------
# Config file generation
# ---------------------------------------------------------------------------

# write_config <conf-path>
# Only ever called when the file does not exist.
write_config() {
	local conf="$1"
	local tmp allow

	mkdir -p -- "$(dirname -- "$conf")"
	tmp="${conf}.tmp.$$"
	: >"$tmp"
	chmod 600 "$tmp"

	{
		echo "# Generated by verus-docker on $(date -u '+%Y-%m-%dT%H:%M:%SZ')."
		echo "# This file is NEVER regenerated. Edit it freely: on the next start"
		echo "# verus-docker will detect it and leave it alone."
		echo "server=1"
		echo "rpcuser=${RPC_USER}"
		echo "rpcpassword=${RPC_PASSWORD}"
		echo "rpcport=${RPC_PORT}"
		echo "rpcbind=0.0.0.0"
		for allow in "${RPC_ALLOW_LIST[@]}"; do
			echo "rpcallowip=${allow}"
		done
		echo "rpcworkqueue=256"
		# An explicit port= matters: without it verusd falls back to compiled-in
		# defaults and can end up on a different port after a restart.
		echo "port=${P2P_PORT}"
		echo "bind=0.0.0.0"
		echo "txindex=${TXINDEX:-1}"

		# Indexes that are off by default upstream. Changing any of these on an
		# existing chain requires a full -reindex, so we only ever write them at
		# creation time.
		is_true "${IDINDEX:-false}" && echo "idindex=1"
		is_true "${TIMESTAMPINDEX:-false}" && echo "timestampindex=1"
		is_true "${INSIGHT_EXPLORER:-false}" && echo "insightexplorer=1"

		is_true "${DISABLE_WALLET:-false}" && echo "disablewallet=1"
		is_true "${ENABLE_STAKING:-false}" && echo "mint=1"

		[[ -n "${MAX_CONNECTIONS:-}" ]] && echo "maxconnections=${MAX_CONNECTIONS}"

		# The conditional lines above are `test && echo` pairs. Without a
		# guaranteed-successful final command the whole group would return the
		# status of the last test, which `set -e` would treat as a failure.
		true
	} >>"$tmp"

	mv -f -- "$tmp" "$conf"
	chmod 600 "$conf"
	log_info "wrote a new configuration file: ${conf}"
}

# conf_flag_enabled <conf> <name> — true when the config turns <name> on.
conf_flag_enabled() {
	grep -qE "^[[:space:]]*${2}[[:space:]]*=[[:space:]]*1[[:space:]]*$" "$1" 2>/dev/null
}

# Say so out loud when an env var the operator set is being ignored because the
# config already exists.
#
# The trap: run an RPC node for a month, decide to stake, set ENABLE_STAKING and
# restart. The config was written before that variable existed, so nothing
# changes — and the startup banner used to print "staking: enabled" anyway,
# because it read the env var rather than the file the daemon actually uses.
warn_ignored_env_vars() {
	local conf="$1"
	local -a ignored=()

	if is_true "${ENABLE_STAKING:-false}" && ! conf_flag_enabled "$conf" mint; then
		ignored+=("ENABLE_STAKING=true, but the config has no 'mint=1'."
			"  This node will NOT stake. Add 'mint=1' to the config and restart.")
	fi
	if is_true "${DISABLE_WALLET:-false}" && ! conf_flag_enabled "$conf" disablewallet; then
		ignored+=("DISABLE_WALLET=true, but the config has no 'disablewallet=1'."
			"  The wallet stays enabled.")
	fi
	if is_true "${IDINDEX:-false}" && ! conf_flag_enabled "$conf" idindex; then
		ignored+=("IDINDEX=true, but the config has no 'idindex=1'."
			"  Enabling it later also requires a full -reindex.")
	fi
	if is_true "${INSIGHT_EXPLORER:-false}" && ! conf_flag_enabled "$conf" insightexplorer; then
		ignored+=("INSIGHT_EXPLORER=true, but the config has no 'insightexplorer=1'."
			"  Enabling it later also requires a full -reindex.")
	fi

	((${#ignored[@]} > 0)) || return 0

	log_banner_warning \
		"Some settings you asked for are NOT in effect." \
		"" \
		"${ignored[@]}" \
		"" \
		"Env vars only build the config the first time it is written. After" \
		"that the file is the source of truth, because overwriting it would" \
		"destroy hand-tuned production settings."
}

# Ensure a config exists for chains that have a predictable config path,
# honouring the "never overwrite" rule.
ensure_config() {
	local conf="$1" creds_file="$2"

	if [[ -f "$conf" ]]; then
		log_info "existing configuration found at ${conf}"
		log_info "  -> These env vars only apply when the config is first created,"
		log_info "     and are IGNORED this run:"
		log_info "       RPC_USER, RPC_PASSWORD, RPC_PORT, RPC_ALLOW_IP, P2P_PORT,"
		log_info "       TXINDEX, IDINDEX, TIMESTAMPINDEX, INSIGHT_EXPLORER,"
		log_info "       DISABLE_WALLET, ENABLE_STAKING, MAX_CONNECTIONS"
		log_info "  -> Edit ${conf} directly to change any of them."
		warn_ignored_env_vars "$conf"
		load_credentials_from_conf "$conf"
		RPC_PORT="${RPC_PORT:-$DEFAULT_RPC_PORT}"
		# An operator's hand-written config may legitimately carry no
		# credentials. Writing a half-empty file would only mislead the
		# healthcheck and the exporter, so skip it and say why.
		if [[ -n "${RPC_USER:-}" && -n "${RPC_PASSWORD:-}" ]]; then
			write_credentials_file "$creds_file"
		else
			log_warn "existing config has no rpcuser/rpcpassword — not writing a credentials file"
			log_warn "  the healthcheck and exporter will need RPC_USER/RPC_PASSWORD passed explicitly"
		fi
		return 0
	fi

	resolve_rpc_allow_ip
	setup_credentials "$creds_file"
	write_config "$conf"
}

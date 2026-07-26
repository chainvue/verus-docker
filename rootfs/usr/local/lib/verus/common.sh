#!/usr/bin/env bash
# Shared helpers for the verus-docker entrypoint and its libraries.
#
# This file is sourced, never executed. It deliberately does not set shell
# options: the caller owns `set -euo pipefail`.

# bootstrap.verus.io and verus.io answer 403 to curl's default User-Agent.
# Without a browser-ish UA we would silently download an HTML error page and,
# in the worst case, write it into a checksum file.
readonly VERUS_HTTP_UA="Mozilla/5.0 (X11; Linux x86_64) verus-docker"

# ---------------------------------------------------------------------------
# Logging. Everything goes to stderr so that stdout stays reserved for values
# that callers capture via command substitution.
# ---------------------------------------------------------------------------

_log() {
	local level="$1"
	shift
	printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

log_info() { _log "INFO " "$@"; }
log_warn() { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

log_debug() {
	[[ "${DEBUG:-false}" == "true" ]] || return 0
	_log "DEBUG" "$@"
}

# Print a prominent, hard-to-miss warning block.
log_banner_warning() {
	local line
	printf '\n' >&2
	printf '  ############################################################\n' >&2
	for line in "$@"; do
		printf '  # %s\n' "$line" >&2
	done
	printf '  ############################################################\n\n' >&2
}

die() {
	log_error "$@"
	exit 1
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 ||
			die "required command not found in image: ${cmd}"
	done
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# http_get_to_stdout <url> [extra curl args...]
# Fails on HTTP errors rather than writing an error page to stdout.
http_get_to_stdout() {
	local url="$1"
	shift
	curl --fail --silent --show-error --location \
		--user-agent "$VERUS_HTTP_UA" \
		--retry 3 --retry-delay 5 --retry-connrefused \
		--connect-timeout 30 \
		"$@" "$url"
}

# http_download <url> <dest> [extra curl args...]
# Downloads to <dest>.part first so an interrupted transfer can never be
# mistaken for a complete file, then moves it into place.
http_download() {
	local url="$1" dest="$2"
	shift 2
	local part="${dest}.part"

	rm -f -- "$part"
	if ! curl --fail --silent --show-error --location \
		--user-agent "$VERUS_HTTP_UA" \
		--retry 3 --retry-delay 5 --retry-connrefused \
		--connect-timeout 30 \
		--output "$part" \
		"$@" "$url"; then
		rm -f -- "$part"
		return 1
	fi

	mv -f -- "$part" "$dest"
}

# ---------------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------------

# sha256_of <file>
sha256_of() {
	sha256sum -- "$1" | cut -d' ' -f1
}

# verify_sha256 <file> <expected-hex> <human-readable-label>
# Deletes the file and aborts on mismatch: a file that failed verification must
# never be left behind where a later run could mistake it for valid.
verify_sha256() {
	local file="$1" expected="$2" label="$3"
	local actual

	[[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
		die "${label}: expected checksum is not a 64-character hex string: '${expected}'"

	actual="$(sha256_of "$file")"
	if [[ "$actual" != "$expected" ]]; then
		rm -f -- "$file"
		log_error "${label}: SHA-256 MISMATCH — refusing to continue"
		log_error "  expected: ${expected}"
		log_error "  actual:   ${actual}"
		die "integrity check failed for ${label}"
	fi

	log_info "${label}: SHA-256 verified (${expected})"
}

# extract_sha256_from_sidecar <file>
# Verus bootstrap hosts publish `<sha256> *<filename>` sidecars. If the host
# served an HTML error page instead (403 on a bad User-Agent), the content will
# not match and we abort loudly rather than compare against garbage.
extract_sha256_from_sidecar() {
	local file="$1"
	local first_token

	first_token="$(head -c 4096 -- "$file" | tr -d '\r' | awk 'NF {print $1; exit}')"

	if [[ ! "$first_token" =~ ^[0-9a-f]{64}$ ]]; then
		log_error "checksum sidecar did not contain a SHA-256 line."
		log_error "This usually means the server returned an error page (HTTP 403 on a"
		log_error "default User-Agent is a known behaviour of bootstrap.verus.io)."
		log_error "First bytes were: $(head -c 200 -- "$file" | tr -d '\n')"
		return 1
	fi

	printf '%s\n' "$first_token"
}

# ---------------------------------------------------------------------------
# JSON-RPC
# ---------------------------------------------------------------------------

# rpc_call <url> <user> <password> <method> [params-json]
# On success prints the `result` member. On failure prints the daemon's error
# message to stderr and returns non-zero.
rpc_call() {
	local url="$1" user="$2" pass="$3" method="$4" params="${5:-[]}"
	local response

	response="$(curl --fail-with-body --silent --show-error \
		--connect-timeout 10 --max-time "${RPC_TIMEOUT:-60}" \
		--user "${user}:${pass}" \
		--header 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"1.0\",\"id\":\"verus-docker\",\"method\":\"${method}\",\"params\":${params}}" \
		"$url" 2>/dev/null)" || {
		# A non-2xx response still carries a JSON body with the real reason.
		if [[ -n "${response:-}" ]]; then
			log_debug "RPC ${method} failed: $(jq -r '.error.message // .' <<<"$response" 2>/dev/null || printf '%s' "$response")"
		fi
		return 1
	}

	if ! jq -e 'has("result")' <<<"$response" >/dev/null 2>&1; then
		log_debug "RPC ${method} returned no result: ${response}"
		return 1
	fi

	jq -c '.result' <<<"$response"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# Cryptographically random hex string. Length is in bytes (output is 2x).
random_hex() {
	local bytes="${1:-32}"
	od -An -tx1 -N "$bytes" /dev/urandom | tr -d ' \n'
}

# is_true <value> — tolerant boolean parsing for env vars.
is_true() {
	case "${1,,}" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

# dir_has_chain_data <datadir>
# The daemon considers a chain "installed" when both blocks/ and chainstate/
# exist; we use the same test to decide whether a bootstrap is still useful.
dir_has_chain_data() {
	local datadir="$1"
	[[ -d "${datadir}/blocks" && -d "${datadir}/chainstate" ]]
}

# human_bytes <bytes>
human_bytes() {
	local bytes="${1:-0}"
	awk -v b="$bytes" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), b, u[i]
	}'
}

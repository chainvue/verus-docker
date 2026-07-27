#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
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
# Interruptible work
# ---------------------------------------------------------------------------

# PID of the long-running helper currently in the foreground, so a trapped
# signal can interrupt it. Empty when nothing is running.
VERUS_CHILD_PID=""

# run_interruptible <cmd> [args...]
# Bash does not run a trap handler until the foreground command in progress
# returns. A 22 GiB `tar` or a multi-hundred-megabyte `curl` therefore swallows
# SIGTERM for minutes, and the container is SIGKILLed at the end of its grace
# period instead of stopping when asked. Running the command in the background
# and waiting on it lets the handler fire immediately.
run_interruptible() {
	local rc=0

	"$@" &
	VERUS_CHILD_PID=$!

	# `wait` is itself interrupted by a trapped signal and returns >128; go
	# around again so we keep waiting for the command's real exit status.
	while kill -0 "$VERUS_CHILD_PID" 2>/dev/null; do
		rc=0
		wait "$VERUS_CHILD_PID" || rc=$?
		((rc > 128)) && continue
		break
	done

	VERUS_CHILD_PID=""
	return "$rc"
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
#
# The params volume is deliberately shared between containers, so two nodes can
# reach this function for the same file at the same time. An earlier version
# tried to separate them by putting $$ in the temp name; that does nothing,
# because PIDs are namespaced and every container's entrypoint is PID 1. A lock
# on the destination actually separates them, and it also lets the .part file
# be reused rather than re-downloaded from zero after an interrupted start.
http_download() {
	local url="$1" dest="$2"
	shift 2
	local part="${dest}.part"
	local rc=0 lock_fd

	# Left behind by images that used the $$-suffixed name. One per interrupted
	# start, never collected, on a volume provisioned at 2Gi.
	rm -f -- "${dest}".part.[0-9]*

	exec {lock_fd}>"${dest}.lock" || return 1
	if ! flock --wait "${DOWNLOAD_LOCK_TIMEOUT:-3600}" "$lock_fd"; then
		exec {lock_fd}>&-
		log_error "timed out waiting for another container to finish downloading $(basename -- "$dest")"
		return 1
	fi

	# Another container may have finished it while we were waiting on the lock.
	if [[ -s "$dest" ]]; then
		log_info "    (another container finished this one while we waited)"
		exec {lock_fd}>&-
		return 0
	fi

	# --continue-at resumes a partial file and is a no-op on a complete or
	# absent one (verified against the params host, which sends Accept-Ranges).
	run_interruptible curl --fail --silent --show-error --location \
		--user-agent "$VERUS_HTTP_UA" \
		--retry 3 --retry-delay 5 --retry-connrefused \
		--connect-timeout 30 \
		--continue-at - \
		--output "$part" \
		"$@" "$url" || rc=$?

	if ((rc != 0)); then
		# Keep the partial file: the next start resumes it. It can never be
		# mistaken for the real thing, which only exists once the mv below runs.
		exec {lock_fd}>&-
		return "$rc"
	fi

	mv -f -- "$part" "$dest"
	exec {lock_fd}>&-
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

# sha256_matches_interruptible <file> <expected-hex>
# True when the file hashes to the expected value. Hashing several GB takes
# minutes, so the work runs as an interruptible child.
#
# Deliberately not written as `[[ "$(sha256_of ...)" == ... ]]`: command
# substitution runs in a subshell, and the child PID recorded there is invisible
# to the entrypoint's signal handler in the parent.
sha256_matches_interruptible() {
	local file="$1" expected="$2"
	local tmp actual rc=0

	tmp="$(mktemp)"
	run_interruptible sha256sum -- "$file" >"$tmp" || rc=$?
	if ((rc != 0)); then
		rm -f -- "$tmp"
		return 1
	fi
	actual="$(cut -d' ' -f1 <"$tmp")"
	rm -f -- "$tmp"

	[[ "$actual" == "$expected" ]]
}

# verify_sha256_interruptible <file> <expected-hex> <label>
# Same contract as verify_sha256 — deletes the file and aborts on mismatch —
# but suitable for the multi-GB bootstrap archive.
verify_sha256_interruptible() {
	local file="$1" expected="$2" label="$3"

	[[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
		die "${label}: expected checksum is not a 64-character hex string: '${expected}'"

	if ! sha256_matches_interruptible "$file" "$expected"; then
		rm -f -- "$file"
		log_error "${label}: SHA-256 MISMATCH — refusing to continue"
		log_error "  expected: ${expected}"
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

# rpc_call <url> <user> <password> <method> [param...]
# On success prints the `result` member. On failure prints the daemon's error
# message to stderr and returns non-zero.
#
# Parameters are passed individually and the body is assembled with jq, so a
# value containing a quote or a backslash stays one JSON string instead of
# reshaping the request.
rpc_call() {
	local url="$1" user="$2" pass="$3" method="$4"
	local response body
	shift 4

	body="$(jq -n --arg m "$method" '$ARGS.positional as $p |
		{jsonrpc: "1.0", id: "verus-docker", method: $m, params: $p}' --args "$@")" || return 1

	# Credentials go in via --config on stdin, never --user: this runs every 30
	# seconds from the healthcheck, and argv is world-readable through
	# /proc/<pid>/cmdline to any user on the host.
	#
	# curl's config parser interprets \ and " inside a quoted value, so both have
	# to be escaped or a password containing either authenticates as something
	# other than what the operator set — which on a staking node shows up as a
	# failing liveness probe and a restart loop, not as an obvious auth error.
	local esc_user="${user//\\/\\\\}" esc_pass="${pass//\\/\\\\}"
	esc_user="${esc_user//\"/\\\"}"
	esc_pass="${esc_pass//\"/\\\"}"

	response="$(printf 'user = "%s:%s"\n' "$esc_user" "$esc_pass" |
		curl --fail-with-body --silent --show-error \
			--connect-timeout 10 --max-time "${RPC_TIMEOUT:-60}" \
			--config - \
			--header 'Content-Type: application/json' \
			--data "$body" \
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
# Credentials
# ---------------------------------------------------------------------------

# read_credentials_file <path>
# Populates RPC_USER / RPC_PASSWORD / RPC_PORT from a KEY=VALUE file.
#
# Parsed, never sourced. The file lives in a volume the operator owns, so
# `source` would execute its contents as shell code — anything able to write
# that volume would get code execution inside the container every time the
# healthcheck runs. It would also mangle any password containing shell
# metacharacters, which fails in a confusing, silent way.
# shellcheck disable=SC2034  # RPC_* are consumed by the scripts that source this
read_credentials_file() {
	local file="$1" line key value

	[[ -r "$file" ]] || return 1

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ -z "$line" || "$line" == \#* || "$line" != *=* ]]; then
			continue
		fi
		key="${line%%=*}"
		value="${line#*=}"
		case "$key" in
		RPC_USER) RPC_USER="$value" ;;
		RPC_PASSWORD) RPC_PASSWORD="$value" ;;
		RPC_PORT) RPC_PORT="$value" ;;
		*) ;;
		esac
	done <"$file"

	return 0
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

# free_bytes <dir> — bytes available to an unprivileged writer, or empty if it
# cannot be determined (df output varies; never guess).
free_bytes() {
	local dir="$1" avail
	avail="$(df -PB1 -- "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')" || return 1
	[[ "$avail" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$avail"
}

# human_age <seconds> — compact age for log lines ("14m", "3h", "8y").
human_age() {
	local s="${1:-0}"
	if ((s < 3600)); then
		printf '%dm\n' $((s / 60))
	elif ((s < 86400)); then
		printf '%dh\n' $((s / 3600))
	elif ((s < 31536000)); then
		printf '%dd\n' $((s / 86400))
	else
		printf '%dy\n' $((s / 31536000))
	fi
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

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Smoke test for the verus-docker image. Run by CI, and useful locally:
#
#   scripts/smoke-test.sh                       # builds nothing, uses IMAGE
#   IMAGE=verus-docker:dev scripts/smoke-test.sh
#
# What this deliberately does NOT do: sync a chain or download a multi-GB
# bootstrap. Neither is feasible in CI, and a test that pretends otherwise is
# worse than an honest smaller one.
#
# What it does prove, in about two minutes:
#   - the container runs unprivileged
#   - configuration is generated correctly and safely
#   - credentials are written with restrictive permissions
#   - the RPC answers and the CLI wrapper needs no arguments
#   - liveness and readiness genuinely disagree while syncing
#   - SIGTERM produces a clean shutdown
#   - a restart resumes without reindexing or re-downloading anything

set -euo pipefail

IMAGE="${IMAGE:-verus-docker:dev}"
CHAIN="${CHAIN:-VRSCTEST}"
CONTAINER="${CONTAINER:-verus-smoke-$$}"
RPC_TIMEOUT_SECONDS="${RPC_TIMEOUT_SECONDS:-300}"

# Point this at a cached directory in CI: the Zcash parameters are ~740 MB and
# downloading them on every run dominates the job time.
PARAMS_DIR="${PARAMS_DIR:-}"
DATA_DIR=""
CLEANUP_DATA=true

PASSED=0
FAILED=0

# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------

log() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }

ok() {
	printf '   \033[32mPASS\033[0m %s\n' "$*"
	PASSED=$((PASSED + 1))
}

fail() {
	printf '   \033[31mFAIL\033[0m %s\n' "$*"
	FAILED=$((FAILED + 1))
}

assert_eq() {
	local actual="$1" expected="$2" what="$3"
	if [[ "$actual" == "$expected" ]]; then
		ok "$what"
	else
		fail "${what} (expected '${expected}', got '${actual}')"
	fi
}

assert_contains() {
	local haystack="$1" needle="$2" what="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		ok "$what"
	else
		fail "${what} (missing '${needle}')"
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" what="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		ok "$what"
	else
		fail "${what} (unexpectedly found '${needle}')"
	fi
}

cleanup() {
	local status=$?
	log "Cleaning up"
	if docker inspect "$CONTAINER" >/dev/null 2>&1; then
		docker logs "$CONTAINER" >"/tmp/${CONTAINER}-final.log" 2>&1 || true
		docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
	fi
	if [[ "$CLEANUP_DATA" == true && -n "$DATA_DIR" && -d "$DATA_DIR" ]]; then
		# The daemon writes as uid 1000. On Linux the CI runner is a different
		# user and cannot remove those files, so fall back to deleting them
		# from inside a container that can. (On macOS, Docker Desktop maps
		# ownership and the plain rm succeeds, which is why this only ever
		# shows up in CI.)
		if ! rm -rf -- "$DATA_DIR" 2>/dev/null; then
			docker run --rm -v "${DATA_DIR}:/target" alpine:3 \
				sh -c 'rm -rf -- /target/* /target/.[!.]* 2>/dev/null || true' >/dev/null 2>&1 || true
			rm -rf -- "$DATA_DIR" 2>/dev/null || true
		fi
	fi
	exit "$status"
}
trap cleanup EXIT

# verusd's own output, with this project's log lines filtered out. Necessary
# because the entrypoint's shutdown warning legitimately contains the words
# "corrupted" and "reindex", which would otherwise match every grep below.
daemon_logs() {
	docker logs "$CONTAINER" 2>&1 | grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ \[(INFO|WARN|ERROR|DEBUG)' || true
}

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

log "verus-docker smoke test"
echo "   image:  ${IMAGE}"
echo "   chain:  ${CHAIN}"

docker image inspect "$IMAGE" >/dev/null 2>&1 ||
	{
		echo "image ${IMAGE} not found; build it first (make build)" >&2
		exit 1
	}

DATA_DIR="$(mktemp -d)"
if [[ -z "$PARAMS_DIR" ]]; then
	PARAMS_DIR="${DATA_DIR}/params"
fi
mkdir -p -- "$DATA_DIR/data" "$PARAMS_DIR"
# The container runs as uid 1000 and must be able to write to both.
chmod 777 "$DATA_DIR/data" "$PARAMS_DIR"

log "Starting container"
docker run -d --name "$CONTAINER" \
	-e CHAIN="$CHAIN" \
	-e USE_BOOTSTRAP=false \
	-e MAX_CONNECTIONS=4 \
	-v "${DATA_DIR}/data:/home/verus/.komodo" \
	-v "${PARAMS_DIR}:/home/verus/.zcash-params" \
	"$IMAGE" >/dev/null

# --------------------------------------------------------------------------
# Wait for RPC
# --------------------------------------------------------------------------

log "Waiting for the RPC to answer (up to ${RPC_TIMEOUT_SECONDS}s)"
rpc_up=false
for ((i = 0; i < RPC_TIMEOUT_SECONDS / 5; i++)); do
	if docker exec "$CONTAINER" verus getinfo >/dev/null 2>&1; then
		rpc_up=true
		echo "   RPC answered after ~$((i * 5))s"
		break
	fi
	if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
		echo "   container exited early; logs follow:" >&2
		docker logs "$CONTAINER" 2>&1 | tail -40 >&2
		fail "container stayed running"
		exit 1
	fi
	sleep 5
done

if [[ "$rpc_up" != true ]]; then
	docker logs "$CONTAINER" 2>&1 | tail -40 >&2
	fail "RPC answered within ${RPC_TIMEOUT_SECONDS}s"
	exit 1
fi
ok "RPC answers"

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

log "Security posture"
assert_eq "$(docker exec "$CONTAINER" id -u)" "1000" "runs as uid 1000, not root"
assert_eq "$(docker exec "$CONTAINER" id -g)" "1000" "runs as gid 1000"

conf_path="/home/verus/.komodo/vrsctest/vrsctest.conf"
conf="$(docker exec "$CONTAINER" cat "$conf_path" 2>/dev/null || true)"
assert_contains "$conf" "server=1" "config was generated"
assert_contains "$conf" "rpcallowip=127.0.0.1" "config allows loopback"
assert_not_contains "$conf" "rpcallowip=0.0.0.0/0" "config does NOT open RPC to the world"
assert_contains "$conf" "port=18842" "config pins the P2P port"
assert_contains "$conf" "rpcport=18843" "config pins the RPC port"

creds_mode="$(docker exec "$CONTAINER" stat -c '%a' /home/verus/.komodo/vrsctest/rpc-credentials 2>/dev/null || echo missing)"
assert_eq "$creds_mode" "600" "credentials file is mode 600"

log "CLI wrapper"
info="$(docker exec "$CONTAINER" verus getinfo 2>/dev/null || true)"
assert_contains "$info" '"VRSCversion"' "verus getinfo works with zero arguments"
assert_contains "$info" 'VRSCTEST' "the wrapper selected the right chain"

log "Health probes"
set +e
docker exec "$CONTAINER" healthcheck.sh --quiet
liveness=$?
set -e
assert_eq "$liveness" "0" "liveness passes while syncing"

set +e
docker exec "$CONTAINER" healthcheck.sh --require-synced --quiet
readiness=$?
set -e
assert_eq "$readiness" "2" "readiness reports 'not synced' (exit 2), so the probes differ"

health="$(docker exec "$CONTAINER" cat /tmp/health.json 2>/dev/null || true)"
assert_contains "$health" '"state"' "health.json is written"
assert_contains "$health" 'VRSCTEST' "health.json carries the chain"

docker_health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)"
if [[ "$docker_health" == "healthy" || "$docker_health" == "starting" ]]; then
	ok "docker HEALTHCHECK is '${docker_health}' (a syncing node must not be unhealthy)"
else
	fail "docker HEALTHCHECK is '${docker_health}'"
fi

# --------------------------------------------------------------------------
# Graceful shutdown
# --------------------------------------------------------------------------

log "Graceful shutdown"
start_ts=$(date +%s)
docker stop -t 120 "$CONTAINER" >/dev/null
stop_seconds=$(($(date +%s) - start_ts))
echo "   stop took ${stop_seconds}s"

exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")"
assert_eq "$exit_code" "0" "container exited cleanly (exit 0)"

shutdown_logs="$(daemon_logs)"
assert_contains "$shutdown_logs" "Shutdown: done" "verusd completed its shutdown sequence"

if ((stop_seconds >= 120)); then
	fail "shutdown hit the 120s grace period (it was killed, not stopped)"
else
	ok "shutdown finished inside the grace period"
fi

# --------------------------------------------------------------------------
# Restart
# --------------------------------------------------------------------------

log "Restart resumes cleanly"
docker start "$CONTAINER" >/dev/null
restart_ok=false
for ((i = 0; i < 40; i++)); do
	docker exec "$CONTAINER" verus getinfo >/dev/null 2>&1 && {
		restart_ok=true
		break
	}
	sleep 5
done
if [[ "$restart_ok" == true ]]; then
	ok "RPC answers again after restart"
else
	docker logs --since 5m "$CONTAINER" 2>&1 | tail -30 >&2
	fail "RPC answered after restart"
fi

restart_logs="$(docker logs --since 5m "$CONTAINER" 2>&1 || true)"
assert_contains "$restart_logs" "existing configuration found" "existing config was left untouched"
assert_contains "$restart_logs" "parameters present" "Zcash parameters were reused, not re-downloaded"

# Only verusd's own output can tell us about corruption; our shutdown warning
# mentions the word too.
assert_not_contains "$(daemon_logs)" "Corruption" "no database corruption reported"

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

log "Result: ${PASSED} passed, ${FAILED} failed"
if ((FAILED > 0)); then
	echo
	echo "Container logs (tail):" >&2
	docker logs "$CONTAINER" 2>&1 | tail -60 >&2
	exit 1
fi
echo "   All assertions passed."

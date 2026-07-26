#!/usr/bin/env bash
# Host-side convenience wrapper around the in-container `verus` CLI.
#
#   ./scripts/verus-cli.sh getinfo
#   ./scripts/verus-cli.sh getblockcount
#   VERUS_CONTAINER=verus-mainnet ./scripts/verus-cli.sh getpeerinfo
#
# It prefers `docker compose exec` when a compose project is present, and falls
# back to plain `docker exec`. Both paths end up calling the same wrapper inside
# the container, so the -chain flag is handled for you.

set -euo pipefail

readonly DEFAULT_CONTAINER="verus"
readonly DEFAULT_SERVICE="verus"

usage() {
	cat <<'EOF'
Usage: verus-cli.sh [options] <verus-command> [args...]

Options:
  -c, --container NAME   Target a container by name (default: $VERUS_CONTAINER or "verus")
  -s, --service NAME     Target a docker compose service (default: $VERUS_SERVICE or "verus")
  -f, --file FILE        Compose file to use (default: $COMPOSE_FILE)
  -h, --help             Show this help

Examples:
  verus-cli.sh getinfo
  verus-cli.sh -f examples/compose.testnet.yml getblockcount
  verus-cli.sh -c verus-mainnet getpeerinfo
EOF
}

die() {
	printf 'verus-cli: %s\n' "$*" >&2
	exit 1
}

main() {
	local container="${VERUS_CONTAINER:-$DEFAULT_CONTAINER}"
	local service="${VERUS_SERVICE:-$DEFAULT_SERVICE}"
	local compose_file="${COMPOSE_FILE:-}"
	local explicit_container=false

	while (($# > 0)); do
		case "$1" in
		-c | --container)
			[[ $# -ge 2 ]] || die "--container needs a value"
			container="$2"
			explicit_container=true
			shift 2
			;;
		-s | --service)
			[[ $# -ge 2 ]] || die "--service needs a value"
			service="$2"
			shift 2
			;;
		-f | --file)
			[[ $# -ge 2 ]] || die "--file needs a value"
			compose_file="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			# Anything else is meant for the verus client, not for us.
			break
			;;
		*) break ;;
		esac
	done

	(($# > 0)) || {
		usage >&2
		exit 64
	}

	command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"

	# A named container that is actually running always wins.
	if docker ps --format '{{.Names}}' | grep -qx "$container"; then
		exec docker exec -i "$container" verus "$@"
	fi

	if [[ "$explicit_container" == true ]]; then
		die "container '${container}' is not running"
	fi

	if [[ -n "$compose_file" ]]; then
		exec docker compose -f "$compose_file" exec -T "$service" verus "$@"
	fi

	# Last resort: let compose resolve the project from the working directory.
	if docker compose ps --services >/dev/null 2>&1; then
		exec docker compose exec -T "$service" verus "$@"
	fi

	die "no running container '${container}' and no compose project found.
Start a node first, or point at one:
  VERUS_CONTAINER=<name> $0 $*
  $0 -f examples/compose.testnet.yml $*"
}

main "$@"

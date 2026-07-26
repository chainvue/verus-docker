#!/usr/bin/env bash
# Runs once after the devcontainer is created.
set -euo pipefail

printf '\n=== verus-docker devcontainer ===\n\n'

if command -v docker >/dev/null 2>&1; then
	printf 'Docker: %s\n' "$(docker --version)"
else
	printf 'WARNING: docker is not available; make lint and make smoke will not work.\n'
fi

cat <<'EOF'

A testnet node is running as a sibling container, reachable at
http://verus-dev:18843 — no configuration needed.

Try it:

  cd examples/rpc && ./curl.sh          # or: node node.mjs / python3 python.py
  docker exec verus-dev verus getinfo
  docker exec verus-dev healthcheck.sh

Repository verbs:

  make help             list everything
  make lint             every linter (containerised, nothing to install)
  make smoke            23-assertion smoke test
  make build            build the image for this architecture

The node starts empty and syncs from genesis; it answers RPC immediately, so
you do not have to wait for it. See docs/development.md.

EOF

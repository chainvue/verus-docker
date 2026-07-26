#!/usr/bin/env python3
"""Talk to a Verus node from Python.

    python3 python.py

Standard library only — no pip install. Requires Python 3.9+.

Credentials are read from the node's data volume by default, so there is
nothing to configure. Override with environment variables:

    VERUS_RPC_URL, VERUS_RPC_USER, VERUS_RPC_PASSWORD, VERUS_CONTAINER
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

CONTAINER = os.environ.get("VERUS_CONTAINER", "verus")
RPC_URL = os.environ.get("VERUS_RPC_URL", "http://127.0.0.1:18843")
CREDS_PATH = os.environ.get(
    "VERUS_CREDS_PATH", "/home/verus/.komodo/vrsctest/rpc-credentials"
)


# ---------------------------------------------------------------------------
# Credentials
#
# The entrypoint generates a random user and password on first start and writes
# them into the data volume, so read them from there rather than hardcoding.
# ---------------------------------------------------------------------------


def load_credentials() -> tuple[str, str]:
    user = os.environ.get("VERUS_RPC_USER")
    password = os.environ.get("VERUS_RPC_PASSWORD")
    if user and password:
        return user, password

    try:
        raw = subprocess.run(
            ["docker", "exec", CONTAINER, "cat", CREDS_PATH],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise SystemExit(
            f"Could not read credentials from container '{CONTAINER}'. "
            "Set VERUS_RPC_USER and VERUS_RPC_PASSWORD, or VERUS_CONTAINER."
        ) from exc

    values = dict(
        line.split("=", 1)
        for line in raw.splitlines()
        if "=" in line and not line.startswith("#")
    )
    return values["RPC_USER"].strip(), values["RPC_PASSWORD"].strip()


# ---------------------------------------------------------------------------
# A minimal client. Verus speaks Bitcoin-style JSON-RPC 1.0 over HTTP basic auth.
# ---------------------------------------------------------------------------


class VerusError(Exception):
    pass


class VerusClient:
    def __init__(self, url: str, user: str, password: str) -> None:
        self.url = url
        token = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
        self._auth = f"Basic {token}"

    def call(self, method: str, params: list | None = None):
        body = json.dumps(
            {"jsonrpc": "1.0", "id": "python", "method": method, "params": params or []}
        ).encode()

        request = urllib.request.Request(  # noqa: S310 - fixed http:// endpoint
            self.url,
            data=body,
            headers={"Content-Type": "application/json", "Authorization": self._auth},
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
                payload = json.load(response)
        except urllib.error.HTTPError as exc:
            # A non-2xx still carries a JSON body explaining the real problem.
            detail = exc.read().decode("utf-8", "replace")[:200]
            raise VerusError(f"{method}: HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise VerusError(f"{method}: cannot reach {self.url}: {exc.reason}") from exc

        if payload.get("error"):
            raise VerusError(f"{method}: {payload['error']}")
        return payload["result"]


# ---------------------------------------------------------------------------


def main() -> int:
    user, password = load_credentials()
    verus = VerusClient(RPC_URL, user, password)

    try:
        info = verus.call("getinfo")
        print("== getinfo ==")
        print(
            {
                "version": info["VRSCversion"],
                "chain": info.get("name"),
                "blocks": info["blocks"],
                "connections": info["connections"],
            }
        )

        chain = verus.call("getblockchaininfo")
        print("\n== getblockchaininfo ==")
        print(
            {
                "blocks": chain["blocks"],
                "headers": chain["headers"],
                "progress": f"{chain['verificationprogress'] * 100:.2f}%",
            }
        )

        # getblockhash takes a height and returns the hash getblock wants.
        height = verus.call("getblockcount")
        block_hash = verus.call("getblockhash", [height])
        block = verus.call("getblock", [block_hash])

        print("\n== getblock (the current tip) ==")
        print(
            {
                "height": block["height"],
                "hash": block["hash"],
                "time": dt.datetime.fromtimestamp(
                    block["time"], dt.timezone.utc
                ).isoformat(),
                "size": block["size"],
                "transactions": len(block["tx"]),
            }
        )

        print(f"\nNode is at block {height}.")
    except VerusError as exc:
        print(exc, file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Prometheus exporter for a Verus (verusd) node.

Why this exists rather than a fork of an existing exporter: verusd descends
from Zcash, which descends from Bitcoin ~0.11, and the widely used
bitcoin-prometheus-exporter calls five RPCs that verusd simply does not
implement (getrpcinfo, uptime, getmemoryinfo, getchaintxstats,
estimatesmartfee). It issues them unguarded, so it dies on the first one.

Every RPC here is one verusd actually implements, and each call is guarded
individually: an unsupported or failing method costs you that method's metrics
and nothing else. A partially answering node still produces a useful scrape.

Standard library only, by design — no pip install, no dependency updates, no
supply-chain surface on a host that sits next to a wallet.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

DEFAULT_PORT = 9838  # not a registered Prometheus port; override if it clashes


def _read_credentials_file(path: str) -> dict[str, str]:
    """Parse the KEY=VALUE credentials file the entrypoint writes."""
    values: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    except OSError as exc:
        print(f"warning: cannot read credentials file {path}: {exc}", file=sys.stderr)
    return values


class Config:
    def __init__(self) -> None:
        creds: dict[str, str] = {}
        creds_file = os.environ.get("VERUS_CREDENTIALS_FILE", "")
        if creds_file:
            creds = _read_credentials_file(creds_file)

        self.host = os.environ.get("VERUS_RPC_HOST", "127.0.0.1")
        self.port = os.environ.get("VERUS_RPC_PORT") or creds.get("RPC_PORT", "27486")
        self.user = os.environ.get("VERUS_RPC_USER") or creds.get("RPC_USER", "")
        self.password = os.environ.get("VERUS_RPC_PASSWORD") or creds.get("RPC_PASSWORD", "")
        self.chain = os.environ.get("CHAIN") or creds.get("CHAIN", "VRSC")

        self.timeout = float(os.environ.get("VERUS_RPC_TIMEOUT", "15"))
        self.listen_addr = os.environ.get("EXPORTER_ADDR", "0.0.0.0")  # noqa: S104
        self.listen_port = int(os.environ.get("EXPORTER_PORT", str(DEFAULT_PORT)))

        # Wallet balances are omitted by default: a metrics endpoint is usually
        # less protected than the RPC it reads from, and balance is the one
        # value worth hiding. Opt in explicitly.
        self.expose_balances = os.environ.get("EXPORTER_EXPOSE_BALANCES", "false").lower() in (
            "1",
            "true",
            "yes",
            "on",
        )

        # Do not hammer the daemon when several Prometheus servers scrape us.
        self.cache_seconds = float(os.environ.get("EXPORTER_CACHE_SECONDS", "5"))

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.port}/"


# --------------------------------------------------------------------------
# RPC
# --------------------------------------------------------------------------


class RpcError(Exception):
    pass


class VerusRpc:
    def __init__(self, config: Config) -> None:
        self._config = config
        token = base64.b64encode(
            f"{config.user}:{config.password}".encode()
        ).decode("ascii")
        self._auth_header = f"Basic {token}"
        self.error_counts: dict[str, int] = {}

    def call(self, method: str, params: list[Any] | None = None) -> Any:
        payload = json.dumps(
            {"jsonrpc": "1.0", "id": "verus-exporter", "method": method, "params": params or []}
        ).encode()

        request = urllib.request.Request(  # noqa: S310 - fixed http:// scheme
            self._config.url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": self._auth_header,
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=self._config.timeout) as response:  # noqa: S310
                body = json.load(response)
        except urllib.error.HTTPError as exc:
            # A non-2xx still carries a JSON body explaining the real problem.
            detail = exc.read().decode("utf-8", "replace")[:200]
            self._record_error(method)
            raise RpcError(f"{method}: HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
            self._record_error(method)
            raise RpcError(f"{method}: {exc}") from exc

        if body.get("error"):
            self._record_error(method)
            raise RpcError(f"{method}: {body['error']}")
        return body.get("result")

    def try_call(self, method: str, params: list[Any] | None = None) -> Any | None:
        """Call without propagating failure. This is the whole point."""
        try:
            return self.call(method, params)
        except RpcError as exc:
            print(f"rpc: {exc}", file=sys.stderr)
            return None

    def _record_error(self, method: str) -> None:
        self.error_counts[method] = self.error_counts.get(method, 0) + 1


# --------------------------------------------------------------------------
# Metric rendering
# --------------------------------------------------------------------------


class MetricWriter:
    def __init__(self, chain: str) -> None:
        self._chain = chain
        self._lines: list[str] = []
        self._declared: set[str] = set()

    def add(
        self,
        name: str,
        value: float | int | bool | None,
        help_text: str,
        metric_type: str = "gauge",
        labels: dict[str, str] | None = None,
    ) -> None:
        if value is None:
            return

        if name not in self._declared:
            self._lines.append(f"# HELP {name} {help_text}")
            self._lines.append(f"# TYPE {name} {metric_type}")
            self._declared.add(name)

        all_labels = {"chain": self._chain}
        if labels:
            all_labels.update(labels)
        rendered = ",".join(f'{k}="{_escape(v)}"' for k, v in all_labels.items())

        if isinstance(value, bool):
            value = int(value)
        self._lines.append(f"{name}{{{rendered}}} {value}")

    def render(self) -> str:
        return "\n".join(self._lines) + "\n"


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def _number(source: Any, key: str) -> float | None:
    """Pull a numeric field out of an RPC result, tolerating anything odd."""
    if not isinstance(source, dict):
        return None
    value = source.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


# --------------------------------------------------------------------------
# Collection
# --------------------------------------------------------------------------


def collect(rpc: VerusRpc, config: Config) -> str:
    started = time.monotonic()

    chain_info = rpc.try_call("getblockchaininfo")
    info = rpc.try_call("getinfo")

    # Label precedence matters. getblockchaininfo reports the Bitcoin-style
    # network name ("main"/"test"), which is useless for telling VRSC apart
    # from a PBaaS chain. The configured CHAIN is authoritative; getinfo.name
    # is the next best thing; the network name is only a last resort.
    chain_label = config.chain
    if not chain_label:
        if isinstance(info, dict) and info.get("name"):
            chain_label = str(info["name"])
        elif isinstance(chain_info, dict) and chain_info.get("chain"):
            chain_label = str(chain_info["chain"])
        else:
            chain_label = "unknown"

    out = MetricWriter(chain_label)

    # `verus_up` is the one metric that must always be present, so an alert can
    # distinguish "node is down" from "exporter is down" (the latter makes the
    # whole scrape disappear).
    out.add("verus_up", chain_info is not None, "1 if the daemon answered getblockchaininfo.")

    if chain_info is None:
        out.add(
            "verus_scrape_duration_seconds",
            round(time.monotonic() - started, 4),
            "Time taken to collect all metrics.",
        )
        _add_error_counters(out, rpc)
        return out.render()

    blocks = _number(chain_info, "blocks")
    headers = _number(chain_info, "headers")
    progress = _number(chain_info, "verificationprogress")

    out.add("verus_blocks", blocks, "Number of validated blocks in the local chain.")
    out.add("verus_headers", headers, "Number of block headers known.")
    out.add(
        "verus_verification_progress",
        progress,
        "Estimated sync progress, 0 to 1.",
    )
    out.add("verus_difficulty", _number(chain_info, "difficulty"), "Current chain difficulty.")
    out.add(
        "verus_size_on_disk_bytes",
        _number(chain_info, "size_on_disk"),
        "Chain data size on disk in bytes.",
    )

    # Mirrors healthcheck.sh --require-synced so dashboards and readiness probes
    # cannot disagree about what "synced" means.
    #
    # Deliberately does NOT use verificationprogress or the header count: during
    # initial sync verusd reports progress=1 and a header count that can sit
    # below the block count, which made both this and the readiness probe call a
    # node synced when it was four million blocks behind. Tip age and the
    # heights our peers reported are the fields that stay honest.
    peers_info = rpc.try_call("getpeerinfo")
    network_height = 0
    if isinstance(peers_info, list):
        heights = [
            p.get("startingheight", 0)
            for p in peers_info
            if isinstance(p, dict) and isinstance(p.get("startingheight"), (int, float))
        ]
        network_height = int(max(heights)) if heights else 0

    tiptime = _number(info, "tiptime") if isinstance(info, dict) else None
    tip_age = max(0, int(time.time() - tiptime)) if tiptime else None
    peer_count = len(peers_info) if isinstance(peers_info, list) else 0

    out.add("verus_network_height", network_height or None,
            "Highest chain height reported by any connected peer.")
    out.add("verus_tip_age_seconds", tip_age,
            "Age of the local chain tip. A synced node's tip is minutes old, not years.")

    if blocks is not None:
        tolerance = float(os.environ.get("SYNCED_TOLERANCE_BLOCKS", "2"))
        max_tip_age = float(os.environ.get("SYNCED_MAX_TIP_AGE", "1800"))
        synced = (
            peer_count > 0
            and tip_age is not None
            and tip_age <= max_tip_age
            and (network_height == 0 or (network_height - blocks) <= tolerance)
        )
        out.add("verus_sync_complete", synced, "1 when the node is fully caught up.")

    if isinstance(info, dict):
        version = str(info.get("VRSCversion") or info.get("version") or "unknown")
        out.add(
            "verus_version_info",
            1,
            "Daemon version, carried as a label.",
            labels={"version": version},
        )
        out.add(
            "verus_connections_total",
            _number(info, "connections"),
            "Total peer connections.",
        )

    _collect_peers(out, rpc, peers_info)
    _collect_mempool(out, rpc)
    _collect_mining(out, rpc)
    _collect_network(out, rpc)
    _collect_wallet(out, rpc, config)

    out.add(
        "verus_scrape_duration_seconds",
        round(time.monotonic() - started, 4),
        "Time taken to collect all metrics.",
    )
    _add_error_counters(out, rpc)
    return out.render()


def _collect_peers(out: MetricWriter, rpc: VerusRpc, peers: Any = None) -> None:
    if peers is None:
        peers = rpc.try_call("getpeerinfo")
    if not isinstance(peers, list):
        # Fall back to the cheaper call; better a total than nothing.
        count = rpc.try_call("getconnectioncount")
        if isinstance(count, (int, float)):
            out.add("verus_peers", count, "Connected peers.", labels={"direction": "all"})
        return

    inbound = sum(1 for peer in peers if isinstance(peer, dict) and peer.get("inbound"))
    out.add("verus_peers", inbound, "Connected peers.", labels={"direction": "inbound"})
    out.add(
        "verus_peers",
        len(peers) - inbound,
        "Connected peers.",
        labels={"direction": "outbound"},
    )


def _collect_mempool(out: MetricWriter, rpc: VerusRpc) -> None:
    mempool = rpc.try_call("getmempoolinfo")
    if not isinstance(mempool, dict):
        return
    out.add("verus_mempool_txs", _number(mempool, "size"), "Transactions in the mempool.")
    out.add("verus_mempool_bytes", _number(mempool, "bytes"), "Mempool size in bytes.")
    out.add("verus_mempool_usage_bytes", _number(mempool, "usage"), "Mempool memory usage.")


def _collect_mining(out: MetricWriter, rpc: VerusRpc) -> None:
    mining = rpc.try_call("getmininginfo")
    if not isinstance(mining, dict):
        return
    out.add(
        "verus_network_hashps",
        _number(mining, "networkhashps"),
        "Estimated network hashes per second.",
    )
    # Verus is a hybrid PoW/PoS chain; stakingsupply is what a staker watches.
    out.add(
        "verus_staking_supply",
        _number(mining, "stakingsupply"),
        "Coin supply currently participating in staking.",
    )


def _collect_network(out: MetricWriter, rpc: VerusRpc) -> None:
    totals = rpc.try_call("getnettotals")
    if not isinstance(totals, dict):
        return
    out.add(
        "verus_net_bytes_received_total",
        _number(totals, "totalbytesrecv"),
        "Bytes received from peers.",
        metric_type="counter",
    )
    out.add(
        "verus_net_bytes_sent_total",
        _number(totals, "totalbytessent"),
        "Bytes sent to peers.",
        metric_type="counter",
    )


def _collect_wallet(out: MetricWriter, rpc: VerusRpc, config: Config) -> None:
    wallet = rpc.try_call("getwalletinfo")
    if not isinstance(wallet, dict):
        # Expected and fine on a -disablewallet node.
        out.add("verus_wallet_enabled", 0, "1 when the daemon has a wallet loaded.")
        return

    out.add("verus_wallet_enabled", 1, "1 when the daemon has a wallet loaded.")
    out.add("verus_wallet_txcount", _number(wallet, "txcount"), "Wallet transaction count.")

    # unlocked_until is absent on an unencrypted wallet, 0 when locked, and a
    # unix timestamp when temporarily unlocked.
    if "unlocked_until" not in wallet:
        unlocked = 1
    else:
        until = wallet.get("unlocked_until")
        unlocked = int(isinstance(until, (int, float)) and until > time.time())
    out.add(
        "verus_wallet_unlocked",
        unlocked,
        "1 when the wallet can sign (unencrypted, or unlocked right now).",
    )

    if config.expose_balances:
        out.add("verus_wallet_balance", _number(wallet, "balance"), "Confirmed wallet balance.")
        out.add(
            "verus_wallet_immature_balance",
            _number(wallet, "immature_balance"),
            "Immature (staking/mining reward) balance.",
        )


def _add_error_counters(out: MetricWriter, rpc: VerusRpc) -> None:
    for method, count in sorted(rpc.error_counts.items()):
        out.add(
            "verus_rpc_errors_total",
            count,
            "Failed RPC calls since exporter start.",
            metric_type="counter",
            labels={"method": method},
        )


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Collector:
    """Caches a scrape briefly so many Prometheus servers cost one RPC round."""

    def __init__(self, rpc: VerusRpc, config: Config) -> None:
        self._rpc = rpc
        self._config = config
        self._lock = threading.Lock()
        self._cached = ""
        self._cached_at = 0.0

    def metrics(self) -> str:
        with self._lock:
            age = time.monotonic() - self._cached_at
            if self._cached and age < self._config.cache_seconds:
                return self._cached
            self._cached = collect(self._rpc, self._config)
            self._cached_at = time.monotonic()
            return self._cached


class Handler(BaseHTTPRequestHandler):
    collector: Collector

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if self.path.startswith("/metrics"):
            self._respond(200, self.collector.metrics(), "text/plain; version=0.0.4")
        elif self.path.startswith("/healthz"):
            self._respond(200, "ok\n")
        elif self.path in ("/", "/index.html"):
            self._respond(
                200,
                "verus-exporter\n\n  /metrics   Prometheus metrics\n  /healthz   liveness\n",
            )
        else:
            self._respond(404, "not found\n")

    def _respond(self, status: int, body: str, content_type: str = "text/plain") -> None:
        payload = body.encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            # Prometheus timed out and hung up mid-write. Normal under load,
            # and not worth a traceback on every occurrence.
            pass

    def log_message(self, fmt: str, *args: Any) -> None:
        # Default logging writes one line per scrape, which is pure noise.
        if os.environ.get("DEBUG", "").lower() in ("1", "true", "yes", "on"):
            super().log_message(fmt, *args)


def main() -> int:
    config = Config()

    if not config.user or not config.password:
        print(
            "error: no RPC credentials. Set VERUS_CREDENTIALS_FILE to the "
            "rpc-credentials file in the node's data volume, or pass "
            "VERUS_RPC_USER and VERUS_RPC_PASSWORD.",
            file=sys.stderr,
        )
        return 1

    rpc = VerusRpc(config)
    Handler.collector = Collector(rpc, config)

    server = ThreadingHTTPServer((config.listen_addr, config.listen_port), Handler)
    print(
        f"verus-exporter listening on {config.listen_addr}:{config.listen_port}, "
        f"scraping {config.url} (chain {config.chain})",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

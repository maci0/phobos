#!/usr/bin/env python3
"""Conformance replay harness — replays golden requests against phobos.

Reads a golden capture file produced by ``capture.py``, starts phobos with
equivalent configuration, replays the identical request sequence, captures
phobos' responses and notifications, and asserts **normalized equality**
against the golden stream per the §8a normalization manifest.

The normalization rules are a Python port of ``src/oracle/normalize.zig``
(the authoritative implementation).  Keep them in sync.

Usage:
  zig build -Dwith_lmdb=false
  python3 conformance/replay.py --phobos ./zig-out/bin/phobos --golden conformance/golden/capture.json
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Set

# ---------------------------------------------------------------------------
# Dependencies (checked lazily)
# ---------------------------------------------------------------------------
try:
    import httpx
except ImportError:
    print("httpx required: pip install httpx", file=sys.stderr)
    sys.exit(1)

try:
    import websockets
    from websockets.asyncio.client import connect as ws_connect
except ImportError:
    print("websockets required: pip install websockets", file=sys.stderr)
    sys.exit(1)


# ===========================================================================
# §8a Normalization manifest (Python port of src/oracle/normalize.zig)
# ===========================================================================

MANIFEST: List[Dict[str, Any]] = [
    # --- server.connection.identify ---
    {"method": "server.connection.identify", "field": "connection_id", "rule": "mask"},
    # --- server.websocket.id ---
    {"method": "server.websocket.id", "field": "websocket_id", "rule": "mask"},
    # --- server.info ---
    {"method": "server.info", "field": "moonraker_version", "rule": "version_pin"},
    {"method": "server.info", "field": "software_version", "rule": "version_pin"},
    {"method": "server.info", "field": "components", "rule": "sort_array"},
    {"method": "server.info", "field": "failed_components", "rule": "sort_array"},
    {"method": "server.info", "field": "registered_directories", "rule": "path_relativize"},
    {"method": "server.info", "field": "warnings", "rule": "structure_compare"},
    # --- server.config ---
    {"method": "server.config", "field": "config_file", "rule": "path_relativize"},
    # --- wildcards ---
    {"method": "*", "field": "*_id", "rule": "mask"},
    {"method": "*", "field": "*_time", "rule": "mask"},
    {"method": "*", "field": "*_timestamp", "rule": "mask"},
    {"method": "*", "field": "*_uptime", "rule": "mask"},
]


def _method_matches(pattern: str, method: str) -> bool:
    return pattern == "*" or pattern == method


def _field_matches(pattern: str, field: str) -> bool:
    if pattern == field:
        return True
    if pattern.startswith("*") and len(pattern) > 1:
        return field.endswith(pattern[1:])
    return False


def _should_apply(field_path: str, method: str, rule: str) -> bool:
    for entry in MANIFEST:
        if entry["rule"] != rule:
            continue
        if not _method_matches(entry["method"], method):
            continue
        if _field_matches(entry["field"], field_path):
            return True
    return False


def _norm_mask(value: Any) -> Any:
    if isinstance(value, bool):
        return False
    if isinstance(value, int) and not isinstance(value, bool):
        return -1
    if isinstance(value, float):
        return -1.0
    if isinstance(value, str):
        return "MASKED"
    return value  # null, array, object — leave as-is


def _norm_version_pin(value: Any) -> Any:
    if isinstance(value, str):
        return "__VERSION__"
    return value


def _norm_path_relativize(value: Any) -> Any:
    if isinstance(value, str):
        markers = ["phobos/", "moonraker/"]
        for marker in markers:
            idx = value.find(marker)
            if idx >= 0:
                return "<DATADIR>/" + value[idx + len(marker):]
        # Fall back to basename.
        base = os.path.basename(value) if "/" in value or "\\" in value else value
        return "<DATADIR>/" + base
    return value


def _norm_sort_array(value: Any) -> Any:
    if isinstance(value, list):
        try:
            return sorted(value, key=lambda x: json.dumps(x, sort_keys=True))
        except (TypeError, ValueError):
            return value
    return value


def _norm_structure_compare(value: Any) -> Any:
    """For warnings arrays: keep count and per-element keys, mask all string values."""
    if not isinstance(value, list):
        return value
    result = []
    for item in value:
        if isinstance(item, dict):
            new_item = {}
            for k, v in item.items():
                if isinstance(v, str):
                    new_item[k] = "MASKED"
                elif isinstance(v, (int, float)):
                    new_item[k] = v
                elif isinstance(v, bool):
                    new_item[k] = v
                elif v is None:
                    new_item[k] = None
                elif isinstance(v, list):
                    new_item[k] = _norm_structure_compare(v)
                elif isinstance(v, dict):
                    new_item[k] = _norm_structure_compare([v])[0]
                else:
                    new_item[k] = "MASKED"
            result.append(new_item)
        else:
            result.append(item)
    return result


def normalize(obj: Any, method: str, path: str = "") -> Any:
    """Recursively normalize `obj` according to the manifest for `method`."""
    if isinstance(obj, dict):
        result = {}
        for key, val in obj.items():
            child_path = f"{path}.{key}" if path else key
            result[key] = normalize(val, method, child_path)
        return result

    if isinstance(obj, list):
        # Check for structure_compare at this path.
        if _should_apply(path, method, "structure_compare"):
            return _norm_structure_compare(obj)
        # Check for sort_array.
        if _should_apply(path, method, "sort_array"):
            result = [normalize(item, method, path) for item in obj]
            return _norm_sort_array(result)
        return [normalize(item, method, path) for item in obj]

    if isinstance(obj, str):
        if _should_apply(path, method, "mask"):
            return _norm_mask(obj)
        if _should_apply(path, method, "version_pin"):
            return _norm_version_pin(obj)
        if _should_apply(path, method, "path_relativize"):
            return _norm_path_relativize(obj)
        return obj

    if isinstance(obj, bool):
        if _should_apply(path, method, "mask"):
            return _norm_mask(obj)
        return obj

    if isinstance(obj, int):
        if _should_apply(path, method, "mask"):
            return _norm_mask(obj)
        return obj

    if isinstance(obj, float):
        if _should_apply(path, method, "mask"):
            return _norm_mask(obj)
        return obj

    return obj  # null, etc.


def normalized_equal(golden: Any, phobos: Any, method: str) -> bool:
    """Return True if `golden` and `phobos` are normalized-equal for `method`."""
    try:
        a = normalize(copy.deepcopy(golden), method)
        b = normalize(copy.deepcopy(phobos), method)
        return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
    except Exception:
        return False


def _extract_method(req: Dict) -> str:
    """Extract the JSON-RPC method name from a request dict."""
    if "method" in req:
        return req["method"]
    # For HTTP REST, derive from path.
    path = req.get("path", "")
    return path.lstrip("/").replace("/", ".")


# ===========================================================================
# Phobos process management
# ===========================================================================
class PhobosRunner:
    """Manage a phobos subprocess."""

    def __init__(self, binary: pathlib.Path, port: int, workdir: pathlib.Path):
        self.binary = binary
        self.port = port
        self.workdir = workdir
        self.proc: Optional[subprocess.Popen] = None

    def start(self) -> None:
        """Write config, start phobos, wait for it to accept."""
        cfg_path = self.workdir / "phobos.conf"
        cfg_path.write_text(
            f"[server]\n"
            f"host: 127.0.0.1\n"
            f"port: {self.port}\n"
            f"klippy_uds_address: /tmp/phobos-oracle-nonexistent-klippy.sock\n"
        )

        self.proc = subprocess.Popen(
            [str(self.binary), "-c", str(cfg_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Wait for phobos to accept connections.
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                import socket
                s = socket.create_connection(("127.0.0.1", self.port), timeout=1)
                s.close()
                return
            except Exception:
                time.sleep(0.2)
        raise RuntimeError("phobos did not become ready within 10s")

    def stop(self) -> None:
        """Terminate phobos."""
        if self.proc is None:
            return
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


# ===========================================================================
# Replay engine
# ===========================================================================
class ReplayEngine:
    """Replays a golden capture stream against phobos and asserts equality."""

    def __init__(self, port: int, golden_stream: List[Dict], verbose: bool = False):
        self.port = port
        self.golden_stream = golden_stream
        self.verbose = verbose
        self.failures: List[str] = []

    async def replay(self) -> bool:
        """Replay all events; return True if all pass."""
        ws_conn = None
        ws_connected = False
        ws_notify_task: Optional[asyncio.Task] = None
        ws_notifications: List[Dict] = []

        async def ws_listener(ws):
            nonlocal ws_notifications
            try:
                while True:
                    raw = await asyncio.wait_for(ws.recv(), timeout=30)
                    assert isinstance(raw, str)
                    msg = json.loads(raw)
                    if "method" in msg and "id" not in msg:
                        ws_notifications.append(msg)
            except Exception:
                pass

        idx = 0
        for event in self.golden_stream:
            idx += 1
            kind = event["kind"]
            req = event.get("request", {})
            golden_resp = event.get("response", {})
            method = _extract_method(req)

            if kind == "http_get":
                path = req["path"]
                try:
                    async with httpx.AsyncClient() as cli:
                        resp = await cli.get(
                            f"http://127.0.0.1:{self.port}{path}",
                            timeout=5,
                        )
                        phobos_resp = resp.json()
                except Exception as e:
                    self.failures.append(f"[{idx}] http_get {path}: {e}")
                    continue

                if not normalized_equal(golden_resp, phobos_resp, method):
                    self.failures.append(
                        f"[{idx}] http_get {path}: not normalized-equal\n"
                        f"  method: {method}\n"
                        f"  golden: {json.dumps(golden_resp)[:200]}\n"
                        f"  phobos: {json.dumps(phobos_resp)[:200]}"
                    )
                elif self.verbose:
                    print(f"  ✓ [{idx}] http_get {path}")

            elif kind == "http_jsonrpc":
                try:
                    async with httpx.AsyncClient() as cli:
                        resp = await cli.post(
                            f"http://127.0.0.1:{self.port}/server/jsonrpc",
                            json=req,
                            timeout=5,
                        )
                        phobos_resp = resp.json()
                except Exception as e:
                    self.failures.append(f"[{idx}] http_jsonrpc {method}: {e}")
                    continue

                # For JSON-RPC, compare the "result" field.
                gr = golden_resp.get("result", golden_resp)
                pr = phobos_resp.get("result", phobos_resp)
                if not normalized_equal(gr, pr, method):
                    self.failures.append(
                        f"[{idx}] http_jsonrpc {method}: not normalized-equal\n"
                        f"  golden: {json.dumps(gr)[:200]}\n"
                        f"  phobos: {json.dumps(pr)[:200]}"
                    )
                elif self.verbose:
                    print(f"  ✓ [{idx}] http_jsonrpc {method}")

            elif kind == "ws_jsonrpc":
                if not ws_connected:
                    ws_conn = await ws_connect(f"ws://127.0.0.1:{self.port}/websocket")
                    ws_notify_task = asyncio.create_task(ws_listener(ws_conn))
                    ws_connected = True

                try:
                    await ws_conn.send(json.dumps(req))
                    raw = await asyncio.wait_for(ws_conn.recv(), timeout=5)
                    assert isinstance(raw, str)
                    phobos_resp = json.loads(raw)
                except Exception as e:
                    self.failures.append(f"[{idx}] ws_jsonrpc {method}: {e}")
                    continue

                gr = golden_resp.get("result", golden_resp)
                pr = phobos_resp.get("result", phobos_resp)
                if not normalized_equal(gr, pr, method):
                    self.failures.append(
                        f"[{idx}] ws_jsonrpc {method}: not normalized-equal\n"
                        f"  golden: {json.dumps(gr)[:200]}\n"
                        f"  phobos: {json.dumps(pr)[:200]}"
                    )
                elif self.verbose:
                    print(f"  ✓ [{idx}] ws_jsonrpc {method}")

            elif kind == "ws_notification":
                # Notifications are batch-compared at the end.
                pass

        # --- Compare notifications ---
        # Give phobos a moment to flush any final notifications.
        await asyncio.sleep(0.5)
        if ws_conn is not None:
            await ws_conn.close()
        if ws_notify_task is not None:
            ws_notify_task.cancel()
            try:
                await ws_notify_task
            except asyncio.CancelledError:
                pass

        golden_notifs = [e["response"] for e in self.golden_stream
                         if e["kind"] == "ws_notification"]
        if golden_notifs or ws_notifications:
            if self.verbose:
                print(f"  Comparing notifications: "
                      f"golden={len(golden_notifs)} phobos={len(ws_notifications)}")
            # Compare notification names only (content is volatile).
            golden_names = [n.get("method", "") for n in golden_notifs]
            phobos_names = [n.get("method", "") for n in ws_notifications]
            if golden_names != phobos_names:
                self.failures.append(
                    f"Notification names differ:\n"
                    f"  golden: {golden_names}\n"
                    f"  phobos: {phobos_names}"
                )
            elif self.verbose:
                print(f"  ✓ notifications match ({len(golden_names)} events)")

        return len(self.failures) == 0


# ===========================================================================
# Main
# ===========================================================================
async def main() -> None:
    parser = argparse.ArgumentParser(description="phobos conformance replay")
    parser.add_argument("--phobos", required=True, help="Path to phobos binary")
    parser.add_argument("--golden", required=True, help="Path to golden capture.json")
    parser.add_argument("--port", type=int, default=7021,
                        help="Port for phobos to listen on")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    phobos_bin = pathlib.Path(args.phobos)
    if not phobos_bin.is_file():
        print(f"phobos binary not found: {phobos_bin}", file=sys.stderr)
        sys.exit(1)

    golden_path = pathlib.Path(args.golden)
    if not golden_path.is_file():
        print(f"golden file not found: {golden_path}", file=sys.stderr)
        sys.exit(1)

    golden_data = json.loads(golden_path.read_text())
    golden_stream = golden_data.get("stream", [])
    print(f"Loaded {len(golden_stream)} events from golden capture.")

    with tempfile.TemporaryDirectory(prefix="phobos-replay-") as tmpdir:
        workdir = pathlib.Path(tmpdir)
        runner = PhobosRunner(phobos_bin, args.port, workdir)

        print(f"Starting phobos on port {args.port}...")
        runner.start()
        print("phobos ready. Replaying...")

        try:
            engine = ReplayEngine(args.port, golden_stream, verbose=args.verbose)
            ok = await engine.replay()
        finally:
            print("Stopping phobos...")
            runner.stop()

        if engine.failures:
            print(f"\nFAILURES ({len(engine.failures)}):")
            for f in engine.failures:
                print(f)
            sys.exit(1)
        else:
            print(f"\n✓ All {len(golden_stream)} events passed normalized equality.")
            sys.exit(0)


if __name__ == "__main__":
    asyncio.run(main())

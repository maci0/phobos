#!/usr/bin/env python3
"""Conformance replay harness — replays golden requests against phobos.

Reads a golden capture file produced by ``capture.py``, starts phobos with
equivalent configuration, replays the identical request sequence, captures
phobos' responses and notifications, and asserts **normalized equality**
against the golden stream per the §8a normalization manifest.

The normalization rules are a Python port of ``src/oracle/normalize.zig``
(the authoritative implementation).  Keep them in sync.

Usage:
  zig build
  python3 conformance/replay.py --phobos ./zig-out/bin/phobos --golden conformance/golden/capture.json
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import glob
import json
import os
import pathlib
import shutil
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
    {"method": "server.info", "field": "klippy_state", "rule": "mask"},
    {"method": "server.info", "field": "klippy_connected", "rule": "mask"},
    {"method": "server.info", "field": "websocket_count", "rule": "mask"},
    # --- server.config ---
    {"method": "server.config", "field": "config_file", "rule": "path_relativize"},
    {"method": "server.config", "field": "config", "rule": "structure_compare"},
    {"method": "server.config", "field": "orig", "rule": "structure_compare"},
    {"method": "server.config", "field": "files", "rule": "files_compare"},
    {"method": "server.config", "field": "filename", "rule": "path_relativize"},
    # --- server.files.list ---
    {"method": "server.files.list", "field": "path", "rule": "path_relativize"},
    {"method": "server.files.list", "field": "", "rule": "sort_array"},
    # --- server.files.roots ---
    {"method": "server.files.roots", "field": "path", "rule": "path_relativize"},
    {"method": "server.files.roots", "field": "", "rule": "sort_array"},
    # --- server.files.directory ---
    {"method": "server.files.directory", "field": "files", "rule": "sort_array"},
    {"method": "server.files.directory", "field": "dirs", "rule": "sort_array"},
    {"method": "server.files.directory", "field": "files.path", "rule": "path_relativize"},
    {"method": "server.files.directory", "field": "files.filename", "rule": "path_relativize"},
    {"method": "server.files.directory", "field": "root_info.path", "rule": "path_relativize"},
    {"method": "server.files.directory", "field": "dirs.dirname", "rule": "path_relativize"},
    {"method": "server.files.directory", "field": "dirs.path", "rule": "path_relativize"},
    {"method": "server.files.directory", "field": "disk_usage", "rule": "structure_compare"},
    # --- server.database.list ---
    {"method": "server.database.list", "field": "", "rule": "mask"},
    # --- access.info ---
    {"method": "access.info", "field": "trusted", "rule": "mask"},
    # --- access.user ---
    {"method": "*", "field": "created_on", "rule": "mask"},
    # --- machine.proc_stats ---
    {"method": "machine.proc_stats", "field": "", "rule": "mask"},
    # --- machine.system_info ---
    {"method": "machine.system_info", "field": "", "rule": "mask"},
    # --- machine.peripherals.serial ---
    {"method": "machine.peripherals.serial", "field": "serial_devices", "rule": "structure_compare"},
    # --- machine.peripherals.usb ---
    {"method": "machine.peripherals.usb", "field": "usb_devices", "rule": "structure_compare"},
    # --- machine.peripherals.video ---
    {"method": "machine.peripherals.video", "field": "v4l2_devices", "rule": "mask"},
    # --- wildcards ---
    {"method": "*", "field": "*_id", "rule": "mask"},
    {"method": "*", "field": "*_time", "rule": "mask"},
    {"method": "*", "field": "*_timestamp", "rule": "mask"},
    {"method": "*", "field": "*_uptime", "rule": "mask"},
]


def _method_matches(pattern: str, method: str) -> bool:
    if pattern == "*":
        return True
    if pattern == method:
        return True
    # Strip query string from method (e.g. "server.files.directory?path=gcodes")
    if "?" in method:
        base = method.split("?", 1)[0]
        if pattern == base:
            return True
    return False


def _field_matches(pattern: str, field: str) -> bool:
    if pattern == field:
        return True
    if pattern.startswith("*") and len(pattern) > 1 and "*" not in pattern[1:]:
        return field.endswith(pattern[1:])
    # Support wildcard segments like "result.*.path" matching "result.foo.path"
    if "*" in pattern:
        import re
        regex = re.escape(pattern).replace(r"\*", r"[^.]+")
        if re.fullmatch(regex, field):
            return True
    # Match by last component of a dotted path (e.g. "result.klippy_state" matches "klippy_state")
    if "." in field:
        last = field.rsplit(".", 1)[-1]
        if pattern == last:
            return True
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
    """For container values: keep count and structure, mask all leaf values.

    Arrays: each element's dict keys are preserved, leaf values → sentinel.
    Sorted by serialized original before masking for deterministic order.
    Numbers → 0, strings → "MASKED", bools → false, null → "MASKED".
    """
    if not isinstance(value, list):
        return value
    # Sort first for deterministic comparison (device lists, namespace lists).
    try:
        items = sorted(value, key=lambda x: json.dumps(x, sort_keys=True))
    except (TypeError, ValueError):
        items = value
    result = []
    for item in items:
        if isinstance(item, dict):
            new_item = {}
            for k, v in item.items():
                if isinstance(v, dict):
                    new_item[k] = _norm_object_compare(v)
                elif isinstance(v, list):
                    new_item[k] = _norm_structure_compare(v)
                elif v is None:
                    new_item[k] = "MASKED"
                elif isinstance(v, bool):
                    new_item[k] = False
                elif isinstance(v, (int, float)):
                    new_item[k] = 0
                elif isinstance(v, str):
                    new_item[k] = "MASKED"
                else:
                    new_item[k] = "MASKED"
            result.append(new_item)
        elif item is None:
            result.append("MASKED")
        elif isinstance(item, bool):
            result.append(False)
        elif isinstance(item, (int, float)):
            result.append(0)
        elif isinstance(item, str):
            result.append("MASKED")
        else:
            result.append("MASKED")
    return result


def _norm_files_compare(value: Any) -> Any:
    """For server.config files: keep filenames (path-relativized), mask sections."""
    if not isinstance(value, list):
        return value
    result = []
    for item in value:
        if isinstance(item, dict):
            new_item = {}
            for k, v in item.items():
                if k == "filename":
                    new_item[k] = _norm_path_relativize(v)
                elif isinstance(v, list):
                    new_item[k] = sorted(v)
                else:
                    new_item[k] = "MASKED"
            result.append(new_item)
    return sorted(result, key=lambda x: json.dumps(x, sort_keys=True))


# Fields within structure_compare objects whose numeric values should be masked
# (non-deterministic integers/floats like port numbers, PIDs, etc.).
_STRUCT_MASKED_NUMERIC = {"port", "ssl_port"}


def _norm_object_compare(value: Any) -> Any:
    """For object values: keep structure (keys + nesting), mask all leaf values.

    Numbers → 0, strings → "MASKED", bools → false, null → "MASKED".  Lists
    and dicts are recursed into.  The goal is structural identity: same keys at
    every level, same nesting, but no value-dependent comparison.
    """
    if isinstance(value, dict):
        result = {}
        for k, v in value.items():
            if isinstance(v, dict):
                result[k] = _norm_object_compare(v)
            elif isinstance(v, list):
                result[k] = _norm_structure_compare(v)
            elif v is None:
                result[k] = "MASKED"
            elif isinstance(v, bool):
                result[k] = False
            elif isinstance(v, (int, float)):
                result[k] = 0
            elif isinstance(v, str):
                result[k] = "MASKED"
            else:
                result[k] = "MASKED"
        return result
    return value


def normalize(obj: Any, method: str, path: str = "") -> Any:
    """Recursively normalize `obj` according to the manifest for `method`."""
    # mask on container replaces whole value with sentinel.
    if isinstance(obj, (dict, list)):
        if _should_apply(path, method, "mask"):
            return "MASKED"

    if isinstance(obj, dict):
        # Check for structure_compare at this path (for object-level masking).
        if _should_apply(path, method, "structure_compare"):
            return _norm_object_compare(obj)
        result = {}
        for key, val in obj.items():
            child_path = f"{path}.{key}" if path else key
            result[key] = normalize(val, method, child_path)
        return result

    if isinstance(obj, list):
        # Check for files_compare at this path.
        if _should_apply(path, method, "files_compare"):
            return _norm_files_compare(obj)
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


def _coerce_ints_to_floats(obj: Any) -> Any:
    """Recursively convert all int values to float.

    Zig's std.json.Stringify serializes `.float = 20.0` as `20` (integer form)
    while Python's json.dumps preserves the int/float type distinction.  This
    causes spurious inequality when a value like `default_metadata_parser_timeout`
    is `20.0` in the golden (parsed as float) but `20` from phobos (serialized
    from `.float` without fractional part → parsed as int).  Normalizing to float
    everywhere makes the comparison type-agnostic for numbers.
    """
    if isinstance(obj, int) and not isinstance(obj, bool):
        return float(obj)
    if isinstance(obj, dict):
        return {k: _coerce_ints_to_floats(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_coerce_ints_to_floats(v) for v in obj]
    return obj


def normalized_equal(golden: Any, phobos: Any, method: str) -> bool:
    """Return True if `golden` and `phobos` are normalized-equal for `method`."""
    try:
        a = normalize(copy.deepcopy(golden), method)
        b = normalize(copy.deepcopy(phobos), method)
        a = _coerce_ints_to_floats(a)
        b = _coerce_ints_to_floats(b)
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
        """Write config, start phobos, wait for it to accept and stabilize."""
        # Clean stale data dirs from previous runs (phobos uses /tmp/phobos-data-*).
        import glob
        for d in glob.glob("/tmp/phobos-data-*"):
            try:
                shutil.rmtree(d)
            except Exception:
                pass

        cfg_path = self.workdir / "moonraker.conf"
        cfg_path.write_text(
            f"[server]\n"
            f"host: 127.0.0.1\n"
            f"port: {self.port}\n"
            f"klippy_uds_address: /tmp/phobos-oracle-nonexistent-klippy.sock\n"
            f"\n"
            f"[authorization]\n"
            f"trusted_clients: 127.0.0.1\n"
            f"\n"
            f"[data_store]\n"
            f"gcode_store_size: 0\n"
            f"temperature_store_size: 0\n"
            f"\n"
            f"[machine]\n"
            f"provider: none\n"
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
                break
            except Exception:
                time.sleep(0.2)
        else:
            raise RuntimeError("phobos did not become ready within 10s")

        # Wait for klippy_state to stabilize (KlippyCtx.start() may briefly
        # show "connecting" before settling on "disconnected").
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            try:
                import urllib.request
                resp = urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/server/info", timeout=2
                )
                import json as _json
                body = _json.loads(resp.read())
                state = body.get("result", body).get("klippy_state", "")
                if state == "disconnected":
                    break
            except Exception:
                pass
            time.sleep(0.3)

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
        ws_notifications: List[Dict] = []

        async def ws_recv_response(ws):
            """Recv from ws until we get a JSON-RPC response (has "id").
            Notifications (has "method", no "id") are accumulated."""
            nonlocal ws_notifications
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=5)
                assert isinstance(raw, str)
                msg = json.loads(raw)
                if "id" in msg:
                    return msg
                if "method" in msg:
                    ws_notifications.append(msg)

        async def ws_drain_notifications(ws, timeout: float = 0.5):
            """Drain any remaining notifications after the main loop."""
            nonlocal ws_notifications
            deadline = asyncio.get_event_loop().time() + timeout
            while asyncio.get_event_loop().time() < deadline:
                try:
                    raw = await asyncio.wait_for(
                        ws.recv(), timeout=deadline - asyncio.get_event_loop().time()
                    )
                    assert isinstance(raw, str)
                    msg = json.loads(raw)
                    if "method" in msg and "id" not in msg:
                        ws_notifications.append(msg)
                except (asyncio.TimeoutError, Exception):
                    break

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

                gr = golden_resp.get("result", golden_resp)
                pr = phobos_resp.get("result", phobos_resp)
                if not normalized_equal(gr, pr, method):
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
                if ws_conn is None:
                    ws_conn = await ws_connect(f"ws://127.0.0.1:{self.port}/websocket")
                    # Give the proc_stat timer thread time to emit its first
                    # notification (fires every 1s; first is immediate after
                    # setIo but may have been lost before WS connect).
                    await asyncio.sleep(1.1)

                try:
                    await ws_conn.send(json.dumps(req))
                    phobos_resp = await ws_recv_response(ws_conn)
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
        # Drain any remaining notifications before closing.
        if ws_conn is not None:
            await ws_drain_notifications(ws_conn, timeout=0.5)
            await ws_conn.close()

        golden_notifs = [e["response"] for e in self.golden_stream
                         if e["kind"] == "ws_notification"]
        if golden_notifs or ws_notifications:
            if self.verbose:
                print(f"  Comparing notifications: "
                      f"golden={len(golden_notifs)} phobos={len(ws_notifications)}")
            # Compare notification names only (content is volatile, count is timing-dependent).
            # Check that golden events are a subset (phobos may emit extra
            # notifications that were not captured in the golden window, e.g.
            # notify_klippy_disconnected).
            golden_names = sorted(set(n.get("method", "") for n in golden_notifs))
            phobos_names = sorted(set(n.get("method", "") for n in ws_notifications))
            missing = [n for n in golden_names if n not in phobos_names]
            if missing:
                self.failures.append(
                    f"Missing golden notifications (not in phobos):\n"
                    f"  missing: {missing}\n"
                    f"  golden:  {golden_names}\n"
                    f"  phobos:  {phobos_names}"
                )
            elif self.verbose:
                extra = [n for n in phobos_names if n not in golden_names]
                print(f"  ✓ notifications ok ({len(golden_names)} golden events"
                      f"{f', +{len(extra)} extra: {extra}' if extra else ''})")

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

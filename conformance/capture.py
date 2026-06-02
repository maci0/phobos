#!/usr/bin/env python3
"""Golden capture harness for the phobos conformance oracle.

Boots stock Moonraker (vendored, commit 9008485) **without Klippy**, sends a
scripted sequence of HTTP REST + HTTP JSON-RPC + WebSocket JSON-RPC requests,
captures the ordered response+notification stream, and writes the result as
JSON golden files under ``conformance/golden/``.

Usage:
  cd vendor/moonraker
  uv run --with httpx --with websockets \
    python ../../conformance/capture.py --config ../../conformance/golden/moonraker.conf

The script starts Moonraker as a subprocess, waits for it to become ready, then
runs the request sequence.  It does NOT import any Moonraker code — it is a
pure black-box client, so the capture is independent of Moonraker internals.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Dependencies (checked lazily)
# ---------------------------------------------------------------------------
try:
    import httpx
except ImportError:
    print("httpx required: uv run --with httpx ...", file=sys.stderr)
    sys.exit(1)

try:
    import websockets
    from websockets.asyncio.client import connect as ws_connect
except ImportError:
    print("websockets required: uv run --with websockets ...", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Minimal Moonraker config (no Klippy, no database persistence)
# ---------------------------------------------------------------------------
MINIMAL_CONFIG = """\
[server]
host: 127.0.0.1
port: {port}
klippy_uds_address: /tmp/phobos-oracle-nonexistent-klippy.sock

[authorization]
trusted_clients:
  127.0.0.1

[machine]
provider: none

[data_store]
temperature_store_size: 0
gcode_store_size: 0
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
class OracleCapture:
    """Manages a single Moonraker process and records its observable output."""

    def __init__(self, port: int, workdir: pathlib.Path, moonraker_dir: pathlib.Path):
        self.port = port
        self.workdir = workdir
        self.moonraker_dir = moonraker_dir
        self.proc: Optional[subprocess.Popen] = None
        self.stream: List[Dict[str, Any]] = []  # ordered capture log
        self._ws_notifications: List[Dict[str, Any]] = []  # from WS listener

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    async def start(self) -> None:
        """Write config, start Moonraker subprocess, wait for it to accept."""
        cfg = MINIMAL_CONFIG.format(port=self.port)
        cfg_path = self.workdir / "moonraker.conf"
        cfg_path.write_text(cfg)

        env = os.environ.copy()
        env["PYTHONPATH"] = str(self.moonraker_dir)
        # Ensure Moonraker writes its log somewhere isolated.
        log_path = self.workdir / "moonraker.log"

        self.proc = subprocess.Popen(
            [
                sys.executable, "-m", "moonraker",
                "-c", str(cfg_path),
                "-l", str(log_path),
            ],
            cwd=str(self.moonraker_dir),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        await self._wait_ready(timeout=15.0)

    async def stop(self) -> None:
        """Terminate the Moonraker process."""
        if self.proc is None:
            return
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()

    async def _wait_ready(self, timeout: float) -> None:
        """Poll /server/info until Moonraker responds."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                async with httpx.AsyncClient() as cli:
                    resp = await cli.get(
                        f"http://127.0.0.1:{self.port}/server/info",
                        timeout=2,
                    )
                    if resp.status_code == 200:
                        return
            except Exception:
                pass
            await asyncio.sleep(0.3)
        raise RuntimeError(f"Moonraker did not become ready within {timeout}s")

    # ------------------------------------------------------------------
    # Request helpers
    # ------------------------------------------------------------------
    def _record(self, kind: str, request: Dict, response: Any) -> None:
        self.stream.append({
            "kind": kind,
            "request": request,
            "response": response,
        })

    async def http_get(self, path: str) -> httpx.Response:
        """REST GET, captured."""
        async with httpx.AsyncClient() as cli:
            resp = await cli.get(
                f"http://127.0.0.1:{self.port}{path}",
                timeout=5,
            )
            body = resp.json()
            self._record("http_get", {"path": path}, body)
            return resp

    async def http_post_jsonrpc(self, method: str, params: Any = None, req_id: int = 1) -> Dict:
        """JSON-RPC over HTTP POST /server/jsonrpc, captured."""
        payload: Dict[str, Any] = {
            "jsonrpc": "2.0",
            "method": method,
            "id": req_id,
        }
        if params is not None:
            payload["params"] = params

        async with httpx.AsyncClient() as cli:
            resp = await cli.post(
                f"http://127.0.0.1:{self.port}/server/jsonrpc",
                json=payload,
                timeout=5,
            )
            body = resp.json()
            self._record("http_jsonrpc", payload, body)
            return body

    async def ws_request(self, method: str, params: Any = None, req_id: int = 1) -> Dict:
        """Single JSON-RPC request over WebSocket, captured."""
        payload: Dict[str, Any] = {
            "jsonrpc": "2.0",
            "method": method,
            "id": req_id,
        }
        if params is not None:
            payload["params"] = params

        async with ws_connect(f"ws://127.0.0.1:{self.port}/websocket") as ws:
            await ws.send(json.dumps(payload))
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
            assert isinstance(raw, str)
            body = json.loads(raw)
            self._record("ws_jsonrpc", payload, body)
            return body

    async def ws_capture_notifications(self, duration: float) -> None:
        """Connect a WebSocket and capture all notifications for `duration` seconds."""
        captured: List[Dict] = []

        async def listener():
            async with ws_connect(f"ws://127.0.0.1:{self.port}/websocket") as ws:
                # Identify so we get subscribed to notifications.
                await ws.send(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "server.connection.identify",
                    "params": {
                        "client_name": "oracle-capture",
                        "version": "1.0",
                        "type": "web",
                        "url": "http://localhost",
                    },
                    "id": 9999,
                }))
                # Discard the identify response.
                await asyncio.wait_for(ws.recv(), timeout=5)

                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    try:
                        raw = await asyncio.wait_for(ws.recv(), timeout=1.0)
                        assert isinstance(raw, str)
                        msg = json.loads(raw)
                        if "method" in msg and "id" not in msg:
                            captured.append(msg)
                    except asyncio.TimeoutError:
                        continue
                    except Exception:
                        break

        await asyncio.wait_for(listener(), timeout=duration + 5)
        self._ws_notifications = captured
        for n in captured:
            self._record("ws_notification", {}, n)

    # ------------------------------------------------------------------
    # Golden serialization
    # ------------------------------------------------------------------
    def write_golden(self, outdir: pathlib.Path) -> None:
        """Write the capture stream as a golden JSON file."""
        outdir.mkdir(parents=True, exist_ok=True)
        golden = {
            "moonraker_commit": "9008485",
            "port": self.port,
            "stream": self.stream,
        }
        outfile = outdir / "capture.json"
        outfile.write_text(json.dumps(golden, indent=2, sort_keys=True))


# ---------------------------------------------------------------------------
# Request sequence
# ---------------------------------------------------------------------------
async def run_sequence(cap: OracleCapture) -> None:
    """Execute the spine request sequence against the running Moonraker."""

    # --- HTTP REST ---
    await cap.http_get("/server/info")
    await cap.http_get("/server/config")

    # --- HTTP JSON-RPC ---
    await cap.http_post_jsonrpc("server.info")
    await cap.http_post_jsonrpc("server.config")

    # --- WebSocket JSON-RPC ---
    await cap.ws_request("server.info", req_id=101)
    await cap.ws_request("server.connection.identify", {
        "client_name": "oracle",
        "version": "1.0",
        "type": "web",
        "url": "http://localhost",
    }, req_id=102)
    await cap.ws_request("server.websocket.id", req_id=103)

    # --- Notifications ---
    # Let the WS listener run for a few seconds to capture notify_proc_stat_update.
    await cap.ws_capture_notifications(3.5)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def main() -> None:
    parser = argparse.ArgumentParser(description="Moonraker golden capture")
    parser.add_argument("--moonraker-dir", default=None,
                        help="Path to vendored Moonraker checkout")
    parser.add_argument("--port", type=int, default=7020,
                        help="Port for Moonraker to listen on")
    parser.add_argument("--outdir", default="conformance/golden",
                        help="Output directory for golden files")
    args = parser.parse_args()

    moonraker_dir = pathlib.Path(args.moonraker_dir) if args.moonraker_dir else (
        pathlib.Path(__file__).resolve().parent.parent / "vendor" / "moonraker"
    )
    if not moonraker_dir.is_dir():
        print(f"Moonraker dir not found: {moonraker_dir}", file=sys.stderr)
        sys.exit(1)

    outdir = pathlib.Path(args.outdir).resolve()
    if not outdir.is_absolute():
        outdir = pathlib.Path(__file__).resolve().parent.parent / args.outdir

    with tempfile.TemporaryDirectory(prefix="phobos-oracle-") as tmpdir:
        workdir = pathlib.Path(tmpdir)
        cap = OracleCapture(args.port, workdir, moonraker_dir)

        print(f"Starting Moonraker on port {args.port}...")
        await cap.start()
        print("Moonraker ready. Running request sequence...")

        try:
            await run_sequence(cap)
        finally:
            print("Stopping Moonraker...")
            await cap.stop()

        cap.write_golden(outdir)
        print(f"Golden written to {outdir / 'capture.json'} "
              f"({len(cap.stream)} events)")


if __name__ == "__main__":
    asyncio.run(main())

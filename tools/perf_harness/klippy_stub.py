#!/usr/bin/env python3
"""Minimal Klipper API-server stub for performance benchmarking.

Speaks the real Klipper unix-socket protocol (JSON-RPC 2.0 frames delimited by
\\x03) and answers instantly from canned data, so a Moonraker-compatible server's
OWN request handling can be measured without a live Klipper in the loop. Both
phobos and stock Moonraker connect to it identically.

Responds to: info, objects/list, objects/query, objects/subscribe,
gcode/subscribe_output, register_remote_method, gcode/script, and anything else
with an empty result. No status pushes (benchmarks hit request/response paths).

Usage: python klippy_stub.py /tmp/klippy_stub.sock
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time

ETX = b"\x03"

OBJECTS = [
    "webhooks", "configfile", "mcu", "gcode_move", "toolhead", "extruder",
    "heater_bed", "fan", "print_stats", "virtual_sdcard", "gcode", "gcode_macro M117",
    "idle_timeout", "display_status", "pause_resume", "system_stats",
]


def _status_for(name: str):
    if name == "webhooks":
        return {"state": "ready", "state_message": "Printer is ready"}
    if name == "configfile":
        return {"config": {"printer": {"kinematics": "cartesian"}},
                "settings": {"printer": {"kinematics": "cartesian", "max_velocity": 300.0}},
                "save_config_pending": False, "warnings": [], "save_config_pending_items": {}}
    if name in ("heater_bed", "extruder"):
        return {"temperature": 24.31, "target": 0.0, "power": 0.0}
    if name == "toolhead":
        return {"position": [0.0, 0.0, 0.0, 0.0], "homed_axes": "",
                "axis_minimum": [0, 0, 0, 0], "axis_maximum": [300, 300, 300, 0],
                "max_velocity": 300.0, "max_accel": 3000.0, "estimated_print_time": 0.0}
    if name == "print_stats":
        return {"filename": "", "state": "standby", "total_duration": 0.0,
                "print_duration": 0.0, "filament_used": 0.0, "info": {"total_layer": None, "current_layer": None}}
    if name == "virtual_sdcard":
        return {"is_active": False, "progress": 0.0, "file_position": 0}
    if name == "display_status":
        return {"progress": 0.0, "message": None}
    if name == "idle_timeout":
        return {"state": "Idle", "printing_time": 0.0}
    if name == "gcode_move":
        return {"speed_factor": 1.0, "speed": 1500.0, "extrude_factor": 1.0,
                "absolute_coordinates": True, "absolute_extrude": True,
                "homing_origin": [0, 0, 0, 0], "position": [0, 0, 0, 0], "gcode_position": [0, 0, 0, 0]}
    return {}


def _handle(method: str, params: dict):
    if method == "info":
        return {"state": "ready", "state_message": "Printer is ready",
                "hostname": "perfbench", "klipper_path": "/opt/klipper",
                "python_path": "/usr/bin/python3", "log_file": "/tmp/klippy.log",
                "config_file": "/tmp/printer.cfg", "software_version": "v0.12.0-stub",
                "cpu_info": "stub", "app": "Klipper", "protocol_version": "1"}
    if method == "objects/list":
        return {"objects": OBJECTS}
    if method in ("objects/query", "objects/subscribe"):
        req = (params or {}).get("objects") or {}
        names = list(req.keys()) if isinstance(req, dict) else OBJECTS
        return {"eventtime": time.monotonic(), "status": {n: _status_for(n) for n in names}}
    if method == "gcode/help":
        return {}
    # gcode/script, gcode/subscribe_output, register_remote_method, etc.
    return {}


def serve_conn(conn: socket.socket):
    buf = bytearray()
    conn.settimeout(None)
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            buf.extend(data)
            while True:
                idx = buf.find(ETX)
                if idx < 0:
                    break
                frame = bytes(buf[:idx])
                del buf[:idx + 1]
                try:
                    msg = json.loads(frame)
                except Exception:
                    continue
                mid = msg.get("id")
                method = msg.get("method", "")
                params = msg.get("params") or {}
                if mid is None:
                    continue  # notification / no reply expected
                result = _handle(method, params)
                reply = json.dumps({"id": mid, "result": result}, separators=(",", ":")).encode() + ETX
                conn.sendall(reply)
    except OSError:
        return
    finally:
        conn.close()


def main(argv=None):
    argv = argv or sys.argv[1:]
    path = argv[0] if argv else "/tmp/klippy_stub.sock"
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(128)
    print(f"klippy stub listening on {path}", flush=True)
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=serve_conn, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        if os.path.exists(path):
            os.unlink(path)


if __name__ == "__main__":
    raise SystemExit(main())

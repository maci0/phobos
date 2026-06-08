"""Tests for the `table` subcommand (per-call API coverage table generator)."""

from __future__ import annotations

from api_scanner import table as table_module
from api_scanner.table import generate, classify_extra, S_FULL, S_NOOP, S_PARTIAL, S_MISSING


BASELINE = {
    "summary": {
        "moonraker_version": "0.10.1.test",
        "moonraker_commit": "abc123def4567890",
        "endpoint_count": 4,
        "jsonrpc_method_count": 4,
        "notification_count": 2,
        "remote_method_count": 1,
    },
    "endpoints": [
        {"path": "/server/info", "request_types": ["GET"], "transports": ["HTTP", "WEBSOCKET"],
         "component": "application", "jsonrpc_methods": ["server.info"]},
        {"path": "/machine/reboot", "request_types": ["POST"], "transports": ["HTTP", "WEBSOCKET"],
         "component": "machine", "jsonrpc_methods": ["machine.reboot"]},
        {"path": "/server/analysis/status", "request_types": ["GET"], "transports": ["HTTP"],
         "component": "analysis", "jsonrpc_methods": ["server.analysis.status"]},
        {"path": "<dynamic>", "request_types": ["GET"], "transports": ["HTTP"],
         "component": "klippy_connection", "jsonrpc_methods": ["<dynamic>"]},
    ],
    "jsonrpc_methods": [
        {"method": "server.info", "transports": ["HTTP"], "component": "application"},
        {"method": "machine.reboot", "transports": ["HTTP"], "component": "machine"},
        {"method": "server.analysis.status", "transports": ["HTTP"], "component": "analysis"},
        {"method": "server.missing", "transports": ["HTTP"], "component": "server"},
    ],
    "notifications": [
        {"name": "notify_klippy_ready", "component": "klippy_connection"},
        {"name": "notify_status_update", "component": "klippy_connection"},
    ],
    "remote_methods": [
        {"name": "set_wled", "component": "wled"},
    ],
}

PHOBOS = {
    "endpoints": [
        {"path": "/server/info"},
        {"path": "/machine/reboot"},
        {"path": "/server/analysis/status"},
    ],
    # server.missing absent → ❌; plus two extras (a remote method + a printer.* proxy)
    "jsonrpc_methods": ["server.info", "machine.reboot", "server.analysis.status",
                        "set_wled", "printer.info"],
    "notifications": ["notify_klippy_ready", "notify_status_update"],
    "router_routes": [],
}


def test_generate_marks_status_and_deltas():
    md = generate(BASELINE, PHOBOS)
    # No-op delta for reboot.
    assert "machine.reboot" in md and S_NOOP in md
    # Partial delta for analysis.
    assert S_PARTIAL in md
    # Missing method gets ❌ Missing.
    assert "`server.missing`" in md and S_MISSING in md
    # Dynamic endpoint is not reported missing.
    assert "Dynamic endpoint registration" in md
    # Full + matches for the plain endpoint.
    assert S_FULL in md


def test_extension_classification():
    # set_wled is a baseline remote method (also exposed as JSON-RPC).
    assert "remote method" in classify_extra("set_wled", {"set_wled"})
    # printer.* is the is_remote proxied path.
    assert "is_remote" in classify_extra("printer.info", set())
    # anything else is a genuine phobos shim.
    assert "shim" in classify_extra("server.weird_internal", set())


def test_extensions_section_lists_extras():
    md = generate(BASELINE, PHOBOS)
    assert "beyond the static baseline" in md
    assert "`set_wled`" in md
    assert "`printer.info`" in md


def test_no_crash_on_empty_inputs():
    md = generate({"summary": {}, "endpoints": [], "jsonrpc_methods": [],
                   "notifications": [], "remote_methods": []},
                  {"endpoints": [], "jsonrpc_methods": [], "notifications": []})
    assert "phobos API Coverage" in md

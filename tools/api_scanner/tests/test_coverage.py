"""Tests for the coverage subcommand and compute_coverage logic."""

from __future__ import annotations

import json
import os
import sys

import pytest

from api_scanner import coverage as cov_module
from api_scanner.coverage import compute_coverage, format_summary, format_missing
from api_scanner import __main__ as cli


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

BASELINE_FIXTURE = {
    "endpoints": [
        {"path": "/server/info", "request_types": ["GET"], "jsonrpc_methods": ["server.info"]},
        {"path": "/server/config", "request_types": ["GET"], "jsonrpc_methods": ["server.config"]},
        {"path": "/machine/update", "request_types": ["GET", "POST"], "jsonrpc_methods": ["machine.get_update", "machine.post_update"]},
    ],
    "jsonrpc_methods": [
        {"method": "server.info"},
        {"method": "server.config"},
        {"method": "machine.get_update"},
        {"method": "machine.post_update"},
    ],
    "notifications": [
        {"name": "notify_klippy_ready"},
        {"name": "notify_klippy_shutdown"},
        {"name": "notify_gcode_response"},
    ],
    "router_routes": [
        {"path": "/server/jsonrpc", "kind": "http"},
        {"path": "/websocket", "kind": "ws"},
        {"path": "<dynamic>", "kind": "dynamic"},
    ],
}

# Phobos dump with partial coverage: only server.info and server.config.
PHOBOS_PARTIAL_FIXTURE = {
    "endpoints": [
        {"path": "/server/info", "methods": ["GET"], "jsonrpc_method": "server.info"},
        {"path": "/server/config", "methods": ["GET"], "jsonrpc_method": "server.config"},
    ],
    "jsonrpc_methods": ["server.info", "server.config", "server.connection.identify", "server.websocket.id"],
    "notifications": [
        "notify_klippy_ready",
        "notify_klippy_shutdown",
        "notify_gcode_response",
    ],
    "router_routes": ["/server/jsonrpc", "/websocket"],
}

# Phobos dump with full coverage of the baseline fixture.
PHOBOS_FULL_FIXTURE = {
    "endpoints": [
        {"path": "/server/info", "methods": ["GET"], "jsonrpc_method": "server.info"},
        {"path": "/server/config", "methods": ["GET"], "jsonrpc_method": "server.config"},
        {"path": "/machine/update", "methods": ["GET", "POST"], "jsonrpc_method": ""},
    ],
    "jsonrpc_methods": ["server.info", "server.config", "machine.get_update", "machine.post_update"],
    "notifications": ["notify_klippy_ready", "notify_klippy_shutdown", "notify_gcode_response"],
    "router_routes": ["/server/jsonrpc", "/websocket"],
}


# ---------------------------------------------------------------------------
# Unit tests for compute_coverage
# ---------------------------------------------------------------------------

def test_remote_registration_uses_its_mounted_printer_path():
    for path in ("objects/list", "/objects/list/"):
        baseline = {
            "endpoints": [
                {"path": path, "is_remote": True},
                {"path": "<dynamic>", "is_remote": True},
            ],
        }
        report = compute_coverage(baseline, {
            "endpoints": [{"path": "/printer/objects/list"}],
        })
        assert report["endpoints"] == {
            "total": 1, "covered": 1, "missing": [],
        }


def test_partial_coverage_counts():
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_PARTIAL_FIXTURE)

    # Endpoints: baseline has 3 paths; phobos has 2 (/server/info, /server/config)
    assert report["endpoints"]["total"] == 3
    assert report["endpoints"]["covered"] == 2
    assert "/machine/update" in report["endpoints"]["missing"]

    # JSON-RPC: baseline has 4; phobos has server.info + server.config covered (2/4)
    assert report["jsonrpc_methods"]["total"] == 4
    assert report["jsonrpc_methods"]["covered"] == 2
    assert "machine.get_update" in report["jsonrpc_methods"]["missing"]
    assert "machine.post_update" in report["jsonrpc_methods"]["missing"]

    # Notifications: all 3 covered
    assert report["notifications"]["total"] == 3
    assert report["notifications"]["covered"] == 3
    assert report["notifications"]["missing"] == []

    # Router routes: baseline has /server/jsonrpc + /websocket (dynamic excluded)
    assert report["router_routes"]["total"] == 2
    assert report["router_routes"]["covered"] == 2
    assert report["router_routes"]["missing"] == []


def test_full_coverage_exit_zero():
    """Full coverage: covered == total."""
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_FULL_FIXTURE)
    assert report["endpoints"]["covered"] == report["endpoints"]["total"]
    assert report["jsonrpc_methods"]["covered"] == report["jsonrpc_methods"]["total"]
    assert report["notifications"]["covered"] == report["notifications"]["total"]
    assert report["router_routes"]["covered"] == report["router_routes"]["total"]
    assert report["covered"] == report["total"]


def test_partial_coverage_not_100():
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_PARTIAL_FIXTURE)
    assert report["covered"] < report["total"]
    assert report["overall_pct"] < 100.0


def test_format_summary_partial():
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_PARTIAL_FIXTURE)
    s = format_summary(report)
    assert "Coverage:" in s
    assert "endpoints" in s
    assert "methods" in s
    assert "notifications" in s
    assert "OVERALL" in s


def test_format_missing_lists_missing_items():
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_PARTIAL_FIXTURE)
    m = format_missing(report)
    assert "machine.get_update" in m or "machine.post_update" in m
    assert "/machine/update" in m


def test_format_missing_empty_when_full():
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_FULL_FIXTURE)
    m = format_missing(report)
    assert m == "" or "MISSING" not in m


def test_dynamic_route_excluded():
    """<dynamic> paths in baseline are not counted as a required route."""
    report = compute_coverage(BASELINE_FIXTURE, PHOBOS_PARTIAL_FIXTURE)
    assert "<dynamic>" not in str(report["router_routes"]["missing"])


def test_trailing_slash_normalization():
    """Paths with trailing slashes in either dump match the normalized version."""
    baseline_with_slash = {
        **BASELINE_FIXTURE,
        "endpoints": [{"path": "/server/info/", "request_types": ["GET"], "jsonrpc_methods": ["server.info"]}],
        "jsonrpc_methods": [],
        "notifications": [],
        "router_routes": [],
    }
    phobos_no_slash = {
        "endpoints": [{"path": "/server/info", "methods": ["GET"], "jsonrpc_method": "server.info"}],
        "jsonrpc_methods": [],
        "notifications": [],
        "router_routes": [],
    }
    report = compute_coverage(baseline_with_slash, phobos_no_slash)
    assert report["endpoints"]["covered"] == 1


def test_empty_phobos_gives_zero_coverage():
    empty_phobos: dict = {"endpoints": [], "jsonrpc_methods": [], "notifications": [], "router_routes": []}
    report = compute_coverage(BASELINE_FIXTURE, empty_phobos)
    assert report["covered"] == 0
    assert report["notifications"]["covered"] == 0


# ---------------------------------------------------------------------------
# CLI integration tests
# ---------------------------------------------------------------------------

def test_cli_coverage_partial(tmp_path):
    baseline_f = tmp_path / "baseline.json"
    phobos_f = tmp_path / "phobos.json"
    baseline_f.write_text(json.dumps(BASELINE_FIXTURE), encoding="utf-8")
    phobos_f.write_text(json.dumps(PHOBOS_PARTIAL_FIXTURE), encoding="utf-8")

    rc = cli.main(["coverage", "--baseline", str(baseline_f), "--phobos", str(phobos_f)])
    assert rc == 1  # not 100% covered


def test_cli_coverage_full(tmp_path, capsys):
    baseline_f = tmp_path / "baseline.json"
    phobos_f = tmp_path / "phobos.json"
    baseline_f.write_text(json.dumps(BASELINE_FIXTURE), encoding="utf-8")
    phobos_f.write_text(json.dumps(PHOBOS_FULL_FIXTURE), encoding="utf-8")

    rc = cli.main(["coverage", "--baseline", str(baseline_f), "--phobos", str(phobos_f)])
    assert rc == 0  # 100% covered
    out = capsys.readouterr().out
    assert "Coverage:" in out


def test_cli_coverage_missing_baseline(tmp_path):
    phobos_f = tmp_path / "phobos.json"
    phobos_f.write_text("{}", encoding="utf-8")
    rc = cli.main(["coverage",
                   "--baseline", str(tmp_path / "nope.json"),
                   "--phobos", str(phobos_f)])
    assert rc == 2


def test_cli_coverage_missing_phobos(tmp_path):
    baseline_f = tmp_path / "baseline.json"
    baseline_f.write_text("{}", encoding="utf-8")
    rc = cli.main(["coverage",
                   "--baseline", str(baseline_f),
                   "--phobos", str(tmp_path / "nope.json")])
    assert rc == 2


def test_cli_coverage_output_contains_summary(tmp_path, capsys):
    baseline_f = tmp_path / "baseline.json"
    phobos_f = tmp_path / "phobos.json"
    baseline_f.write_text(json.dumps(BASELINE_FIXTURE), encoding="utf-8")
    phobos_f.write_text(json.dumps(PHOBOS_PARTIAL_FIXTURE), encoding="utf-8")

    cli.main(["coverage", "--baseline", str(baseline_f), "--phobos", str(phobos_f)])
    out = capsys.readouterr().out
    assert "Coverage:" in out
    assert "endpoints" in out
    assert "OVERALL" in out

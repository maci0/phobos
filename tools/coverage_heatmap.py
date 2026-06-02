"""Per-component API coverage heatmap and progress calculation.

Reads the Moonraker baseline and phobos --dump-api output, groups endpoints
and methods by component, and produces a markdown table with per-component
coverage and implementation depth.
"""

from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple


# --- Implementation depth scores per component (0.0–1.0) ---
# These reflect how much of the component's internals are actually implemented,
# not just the API surface shapes.
DEPTH_SCORES: Dict[str, float] = {
    # Fully implemented — real internals, production-ready
    "authorization": 0.95,
    "database": 0.95,
    "data_store": 0.95,
    "notifier": 0.95,
    "analysis": 0.95,
    "extensions": 0.95,
    "octoprint_compat": 0.95,
    "server": 0.95,
    "websockets": 0.95,
    "proc_stats": 0.95,
    "application": 0.95,
    "loghelper": 0.95,
    "zeroconf": 0.95,
    # Mostly complete — minor depth remaining
    "file_manager": 0.85,   # correct shapes + path safety; deep gcode parsing partial
    "history": 0.85,        # correct shapes + notify; live Klippy job tracking remaining
    "announcements": 0.80,  # correct shapes + notify; RSS fetch stubbed
    "webcam": 0.80,         # correct shapes + notify; real webcam control stubbed
    # Klippy bridge — connection/handshake/printer proxy done; status processing remaining
    "job_queue": 0.70,      # correct shapes + notify; print dispatch remaining
    "klippy_connection": 0.65,
    "klippy_apis": 0.65,
    # Surface only — correct shapes, stubbed internals
    "machine": 0.30,        # real /proc /sys parsers; reboot/shutdown stubbed
    "update_manager": 0.25, # correct shapes + notify; git/pip/apt stubbed
    "power": 0.25,          # state tracked; GPIO stubbed
    "wled": 0.25,           # state tracked; network control stubbed
    "td1": 0.25,            # state tracked; device control stubbed
    "spoolman": 0.25,       # stored data; HTTP fetch stubbed
    # Not configured / deferred
    "mqtt": 0.15,           # returns "not configured"
    "sensor": 0.05,         # SensorCtx empty struct; deferred
    # Notification-only components (no endpoints, just emit notifications)
    "button": 0.30,
    "common": 0.95,
}


def load_json(path: str) -> Dict[str, Any]:
    with open(path) as f:
        return json.load(f)


def norm_path(path: str) -> str:
    return path.rstrip("/") if path not in ("/", "") else path


def phobos_endpoint_set(phobos: Dict[str, Any]) -> Set[str]:
    return {norm_path(e["path"]) for e in phobos.get("endpoints", [])}


def phobos_method_set(phobos: Dict[str, Any]) -> Set[str]:
    raw = phobos.get("jsonrpc_methods", [])
    if raw and isinstance(raw[0], str):
        return set(raw)
    return {m["method"] for m in raw}


def phobos_notification_set(phobos: Dict[str, Any]) -> Set[str]:
    raw = phobos.get("notifications", [])
    if raw and isinstance(raw[0], str):
        return set(raw)
    return {n["name"] for n in raw}


def build_component_report(
    baseline: Dict[str, Any],
    phobos: Dict[str, Any],
) -> List[Dict[str, Any]]:
    """Build per-component coverage + depth report."""
    p_ep = phobos_endpoint_set(phobos)
    p_methods = phobos_method_set(phobos)
    p_notifs = phobos_notification_set(phobos)

    # Group baseline data by component
    comps: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
        "endpoints": [],
        "methods": set(),
        "notifications": [],
    })

    # Collect endpoints from baseline
    for ep in baseline.get("endpoints", []):
        c = ep["component"]
        path = norm_path(ep["path"])
        if not path.startswith("<"):  # skip dynamic
            comps[c]["endpoints"].append(path)
            for m in ep.get("jsonrpc_methods", []):
                comps[c]["methods"].add(m)

    # Collect methods from baseline (standalone, not attached to endpoints)
    for m in baseline.get("jsonrpc_methods", []):
        comps[m.get("component", "unknown")]["methods"].add(m["method"])

    # Collect notifications
    for n in baseline.get("notifications", []):
        c = n.get("component", "unknown")
        comps[c]["notifications"].append(n["name"])

    # Compute coverage per component
    report: List[Dict[str, Any]] = []
    for cname in sorted(comps.keys()):
        c = comps[cname]
        total_ep = len(c["endpoints"])
        covered_ep = sum(1 for ep in c["endpoints"] if ep in p_ep)

        total_methods = len(c["methods"])
        covered_methods = sum(1 for m in c["methods"] if m in p_methods)

        total_notifs = len(c["notifications"])
        covered_notifs = sum(1 for n in c["notifications"] if n in p_notifs)

        total_items = total_ep + total_methods + total_notifs
        covered_items = covered_ep + covered_methods + covered_notifs
        surface_pct = (covered_items / total_items * 100) if total_items > 0 else 100.0

        depth = DEPTH_SCORES.get(cname, 0.30)  # default to surface-only
        # Combined score: surface coverage is prerequisite, depth scales it
        combined_pct = (surface_pct / 100.0) * depth * 100.0

        report.append({
            "component": cname,
            "endpoints": f"{covered_ep}/{total_ep}",
            "methods": f"{covered_methods}/{total_methods}",
            "notifications": f"{covered_notifs}/{total_notifs}",
            "surface_pct": surface_pct,
            "depth_score": depth,
            "combined_pct": combined_pct,
            "total_items": total_items,
            "covered_items": covered_items,
        })

    return report


def compute_weighted_progress(report: List[Dict[str, Any]]) -> float:
    """Weighted average: each component weighted by its item count from baseline."""
    total_weight = sum(r["total_items"] for r in report)
    if total_weight == 0:
        return 0.0
    weighted_sum = sum(r["total_items"] * r["depth_score"] for r in report)
    return (weighted_sum / total_weight) * 100.0


def format_heatmap_markdown(report: List[Dict[str, Any]], overall_pct: float) -> str:
    """Generate a markdown heatmap table."""
    lines = []
    lines.append("## API Coverage Heatmap\n")
    lines.append(
        "| Component | Endpoints | Methods | Notifications | Surface | Depth | Combined |"
    )
    lines.append(
        "|-----------|-----------|---------|---------------|---------|-------|----------|"
    )

    # Sort by combined_pct ascending (least complete first) then by component name
    sorted_report = sorted(report, key=lambda r: (r["combined_pct"], r["component"]))

    for r in sorted_report:
        # Visual indicator based on combined_pct
        if r["combined_pct"] >= 85:
            bar = "🟢"
        elif r["combined_pct"] >= 60:
            bar = "🟡"
        elif r["combined_pct"] >= 30:
            bar = "🟠"
        else:
            bar = "🔴"

        lines.append(
            f"| {bar} {r['component']} "
            f"| {r['endpoints']} "
            f"| {r['methods']} "
            f"| {r['notifications']} "
            f"| {r['surface_pct']:.0f}% "
            f"| {int(r['depth_score'] * 100)}% "
            f"| {r['combined_pct']:.0f}% |"
        )

    lines.append("")
    lines.append(f"> **Overall weighted progress: {overall_pct:.1f}%**")
    lines.append(">")
    lines.append("> - **Surface**: API endpoint/method/notification shape coverage")
    lines.append("> - **Depth**: how much of the internal implementation is real (not stubbed)")
    lines.append("> - **Combined**: Surface × Depth — the effective completeness of each component")
    lines.append("> - **Overall**: weighted by API item count per component")
    return "\n".join(lines)


def compute_progress(report: List[Dict[str, Any]]) -> float:
    return compute_weighted_progress(report)


def main() -> None:
    baseline_path = sys.argv[1] if len(sys.argv) > 1 else "api/api_surface.json"
    phobos_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/d.json"

    baseline = load_json(baseline_path)
    phobos = load_json(phobos_path)

    report = build_component_report(baseline, phobos)
    overall = compute_progress(report)

    print(format_heatmap_markdown(report, overall))


if __name__ == "__main__":
    main()

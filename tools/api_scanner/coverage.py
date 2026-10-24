"""Coverage: compare phobos --dump-api output against the Moonraker baseline."""

from __future__ import annotations

import re
from typing import Any, Dict, List, Set, Tuple


def _norm_path(path: str) -> str:
    """Normalize a path for comparison: strip trailing slashes."""
    return path.rstrip("/") if path not in ("/", "") else path


def _baseline_endpoint_paths(baseline: Dict[str, Any]) -> Set[str]:
    # Skip <dynamic> entries: runtime-registered variable paths (Klippy-proxied)
    # that cannot be matched statically; they are not part of the achievable surface.
    return {
        _norm_path("/printer/" + e["path"].strip("/")
                   if e.get("is_remote") else e["path"])
        for e in baseline.get("endpoints", [])
        if not _norm_path(e["path"]).startswith("<")
    }


def _baseline_jsonrpc_methods(baseline: Dict[str, Any]) -> Set[str]:
    return {m["method"] for m in baseline.get("jsonrpc_methods", [])}


def _baseline_notification_names(baseline: Dict[str, Any]) -> Set[str]:
    return {n["name"] for n in baseline.get("notifications", [])}


def _baseline_router_routes(baseline: Dict[str, Any]) -> Set[str]:
    return {
        _norm_path(r["path"])
        for r in baseline.get("router_routes", [])
        if not _norm_path(r["path"]).startswith("<")  # skip <dynamic>
    }


def _phobos_endpoint_paths(phobos: Dict[str, Any]) -> Set[str]:
    return {_norm_path(e["path"]) for e in phobos.get("endpoints", [])}


def _phobos_jsonrpc_methods(phobos: Dict[str, Any]) -> Set[str]:
    # phobos dump has a flat list of method name strings
    raw = phobos.get("jsonrpc_methods", [])
    if raw and isinstance(raw[0], str):
        return set(raw)
    # fallback: list of dicts with "method" key
    return {m["method"] for m in raw}


def _phobos_notification_names(phobos: Dict[str, Any]) -> Set[str]:
    raw = phobos.get("notifications", [])
    if raw and isinstance(raw[0], str):
        return set(raw)
    return {n["name"] for n in raw}


def _phobos_router_routes(phobos: Dict[str, Any]) -> Set[str]:
    raw = phobos.get("router_routes", [])
    if raw and isinstance(raw[0], str):
        return {_norm_path(r) for r in raw}
    return {_norm_path(r["path"]) for r in raw}


def compute_coverage(
    baseline: Dict[str, Any],
    phobos: Dict[str, Any],
) -> Dict[str, Any]:
    """Return a coverage report dict.

    Keys:
      endpoints:    {total, covered, missing}
      jsonrpc_methods: {total, covered, missing}
      notifications: {total, covered, missing}
      router_routes: {total, covered, missing}
      overall_pct:  float  (covered across all categories / total across all)
    """
    b_ep = _baseline_endpoint_paths(baseline)
    b_jrpc = _baseline_jsonrpc_methods(baseline)
    b_notif = _baseline_notification_names(baseline)
    b_routes = _baseline_router_routes(baseline)

    p_ep = _phobos_endpoint_paths(phobos)
    p_jrpc = _phobos_jsonrpc_methods(phobos)
    p_notif = _phobos_notification_names(phobos)
    p_routes = _phobos_router_routes(phobos)

    def cat(b: Set[str], p: Set[str]) -> Dict[str, Any]:
        covered = b & p
        missing = sorted(b - p)
        return {
            "total": len(b),
            "covered": len(covered),
            "missing": missing,
        }

    ep = cat(b_ep, p_ep)
    jrpc = cat(b_jrpc, p_jrpc)
    notif = cat(b_notif, p_notif)
    routes = cat(b_routes, p_routes)

    total_items = ep["total"] + jrpc["total"] + notif["total"] + routes["total"]
    covered_items = ep["covered"] + jrpc["covered"] + notif["covered"] + routes["covered"]
    overall_pct = (covered_items / total_items * 100) if total_items > 0 else 0.0

    return {
        "endpoints": ep,
        "jsonrpc_methods": jrpc,
        "notifications": notif,
        "router_routes": routes,
        "overall_pct": overall_pct,
        "total": total_items,
        "covered": covered_items,
    }


def format_summary(report: Dict[str, Any]) -> str:
    """One-line summary like the spec."""
    ep = report["endpoints"]
    jrpc = report["jsonrpc_methods"]
    notif = report["notifications"]
    routes = report["router_routes"]

    def pct(cat: Dict[str, Any]) -> str:
        t = cat["total"]
        c = cat["covered"]
        p = (c / t * 100) if t > 0 else 0.0
        return f"{c}/{t} ({p:.1f}%)"

    return (
        f"Coverage: endpoints {pct(ep)}, "
        f"methods {jrpc['covered']}/{jrpc['total']}, "
        f"notifications {notif['covered']}/{notif['total']}, "
        f"OVERALL {report['overall_pct']:.0f}%"
    )


def format_missing(report: Dict[str, Any]) -> str:
    """Multi-line MISSING section."""
    lines: List[str] = []
    for category, key in (
        ("endpoints", "endpoints"),
        ("jsonrpc_methods", "jsonrpc_methods"),
        ("notifications", "notifications"),
        ("router_routes", "router_routes"),
    ):
        missing = report[key]["missing"]
        if missing:
            lines.append(f"\nMISSING {category} ({len(missing)}):")
            for item in missing:
                lines.append(f"  - {item}")
    return "\n".join(lines)

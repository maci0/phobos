"""Diff two API-surface scans and render a human-readable drift report."""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Tuple

# Fields compared when deciding whether an endpoint "changed".  Source location
# is intentionally excluded so that moving a registration does not register as
# behavioural drift.
_ENDPOINT_CMP_FIELDS = (
    "request_types", "transports", "wrap_result", "content_type",
    "auth_required", "is_remote", "debug_only", "jsonrpc_methods", "multi_verb",
)


def _index(items: List[Dict[str, Any]], key: Callable[[Dict[str, Any]], str]) \
        -> Dict[str, Dict[str, Any]]:
    out: Dict[str, Dict[str, Any]] = {}
    for it in items:
        out[key(it)] = it
    return out


def _endpoint_key(e: Dict[str, Any]) -> str:
    return f"{e['path']} [{','.join(e['request_types'])}]"


def _diff_section(
    old_items: List[Dict[str, Any]],
    new_items: List[Dict[str, Any]],
    key: Callable[[Dict[str, Any]], str],
    cmp_fields: Tuple[str, ...] = (),
) -> Dict[str, List[Any]]:
    old = _index(old_items, key)
    new = _index(new_items, key)
    added = sorted(k for k in new if k not in old)
    removed = sorted(k for k in old if k not in new)
    changed: List[Dict[str, Any]] = []
    for k in sorted(set(old) & set(new)):
        if not cmp_fields:
            continue
        diffs = {}
        for f in cmp_fields:
            if old[k].get(f) != new[k].get(f):
                diffs[f] = {"old": old[k].get(f), "new": new[k].get(f)}
        if diffs:
            changed.append({"key": k, "fields": diffs})
    return {"added": added, "removed": removed, "changed": changed}


def diff(baseline: Dict[str, Any], current: Dict[str, Any]) -> Dict[str, Any]:
    """Return a structured diff of two scan objects."""
    return {
        "endpoints": _diff_section(
            baseline["endpoints"], current["endpoints"],
            _endpoint_key, _ENDPOINT_CMP_FIELDS),
        "jsonrpc_methods": _diff_section(
            baseline["jsonrpc_methods"], current["jsonrpc_methods"],
            lambda m: m["method"]),
        "remote_methods": _diff_section(
            baseline["remote_methods"], current["remote_methods"],
            lambda m: m["name"]),
        "notifications": _diff_section(
            baseline["notifications"], current["notifications"],
            lambda n: n["name"]),
        "router_routes": _diff_section(
            baseline.get("router_routes", []), current.get("router_routes", []),
            lambda r: f"{r['kind']}:{r['path']}"),
        "static_handlers": _diff_section(
            baseline["static_handlers"], current["static_handlers"],
            lambda s: f"{s['kind']}:{s['pattern']}"),
    }


def has_drift(d: Dict[str, Any]) -> bool:
    for section in d.values():
        if section["added"] or section["removed"] or section["changed"]:
            return True
    return False


def render(d: Dict[str, Any]) -> str:
    lines: List[str] = []
    titles = {
        "endpoints": "HTTP/RPC ENDPOINTS",
        "jsonrpc_methods": "JSON-RPC METHODS",
        "remote_methods": "REMOTE METHODS",
        "notifications": "NOTIFICATIONS",
        "router_routes": "ROUTER ROUTES",
        "static_handlers": "STATIC HANDLERS",
    }
    any_drift = False
    for section_key, title in titles.items():
        sec = d[section_key]
        if not (sec["added"] or sec["removed"] or sec["changed"]):
            continue
        any_drift = True
        lines.append(f"== {title} ==")
        for k in sec["added"]:
            lines.append(f"  ADDED    {k}")
        for k in sec["removed"]:
            lines.append(f"  REMOVED  {k}")
        for ch in sec["changed"]:
            lines.append(f"  CHANGED  {ch['key']}")
            for fname, fv in ch["fields"].items():
                lines.append(f"             {fname}: {fv['old']!r} -> {fv['new']!r}")
        lines.append("")
    if not any_drift:
        lines.append("No API drift: scan matches baseline.")
    return "\n".join(lines).rstrip() + "\n"

"""Walk a Moonraker source tree and assemble the deterministic API surface."""

from __future__ import annotations

import ast
import os
import subprocess
from typing import Any, Dict, List

from . import extractor as ex


def _read_version_literal(ver_path: str) -> Any:
    """Parse ``__version__ = "..."`` from a file without importing it."""
    try:
        with open(ver_path, "r", encoding="utf-8") as fh:
            tree = ast.parse(fh.read(), filename=ver_path)
    except (OSError, SyntaxError):
        return None
    for stmt in tree.body:
        if isinstance(stmt, ast.Assign):
            for tgt in stmt.targets:
                if isinstance(tgt, ast.Name) and tgt.id == "__version__":
                    if isinstance(stmt.value, ast.Constant):
                        return stmt.value.value
    return None


def discover_version(source_root: str) -> Dict[str, Any]:
    """Best-effort Moonraker version/commit discovery.

    Reads ``__version__.py`` and the git HEAD of the source tree (or its
    parents, when ``source_root`` is ``vendor/moonraker/moonraker``).
    """
    info: Dict[str, Any] = {"version": None, "commit": None}
    ver_path = os.path.join(source_root, "__version__.py")
    if os.path.isfile(ver_path):
        info["version"] = _read_version_literal(ver_path)

    candidate = source_root
    for _ in range(3):
        try:
            out = subprocess.run(
                ["git", "-C", candidate, "rev-parse", "HEAD"],
                capture_output=True, text=True, timeout=10,
            )
            if out.returncode == 0 and out.stdout.strip():
                info["commit"] = out.stdout.strip()
                break
        except Exception:
            pass
        candidate = os.path.dirname(candidate.rstrip("/"))
        if not candidate:
            break
    return info


def _iter_py_files(source_root: str) -> List[str]:
    files: List[str] = []
    for dirpath, dirnames, filenames in os.walk(source_root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for name in filenames:
            if name.endswith(".py"):
                files.append(os.path.join(dirpath, name))
    return sorted(files)


def scan(source_root: str) -> Dict[str, Any]:
    """Scan ``source_root`` and return the deterministic API-surface object."""
    source_root = os.path.abspath(source_root)
    endpoints: List[Dict[str, Any]] = []
    remote_methods: List[Dict[str, Any]] = []
    static_handlers: List[Dict[str, Any]] = []
    notifications: List[Dict[str, Any]] = []
    router_routes: List[Dict[str, Any]] = []

    for path in _iter_py_files(source_root):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                source = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        v = ex.extract_from_source(source, path, source_root)
        endpoints.extend(e.to_dict() for e in v.endpoints)
        remote_methods.extend(r.to_dict() for r in v.remote_methods)
        static_handlers.extend(s.to_dict() for s in v.static_handlers)
        notifications.extend(n.to_dict() for n in v.notifications)
        router_routes.extend(r.to_dict() for r in v.router_routes)

    # JSON-RPC methods: flatten every rpc method from every endpoint.
    rpc_seen: Dict[str, Dict[str, Any]] = {}
    for e in endpoints:
        for m in e["jsonrpc_methods"]:
            if m in ("", ex.DYNAMIC):
                continue
            if m not in rpc_seen:
                rpc_seen[m] = {
                    "method": m,
                    "path": e["path"],
                    "component": e["component"],
                    "source": e["source"],
                    "debug_only": e["debug_only"],
                    "is_remote": e["is_remote"],
                }
    jsonrpc_methods = sorted(rpc_seen.values(), key=lambda x: x["method"])

    endpoints.sort(key=lambda e: (e["path"], ",".join(e["request_types"]),
                                  e["source"]))
    remote_methods.sort(key=lambda x: (x["name"], x["source"]))
    static_handlers.sort(key=lambda x: (x["kind"], x["pattern"], x["source"]))
    notifications = _dedup_notifications(notifications)
    router_routes = _dedup_router_routes(router_routes)

    version = discover_version(source_root)

    summary = {
        "moonraker_version": version["version"],
        "moonraker_commit": version["commit"],
        "endpoint_count": len(endpoints),
        "http_endpoint_count": sum(
            1 for e in endpoints if "HTTP" in e["transports"]),
        "jsonrpc_method_count": len(jsonrpc_methods),
        "remote_method_count": len(remote_methods),
        "notification_count": len(notifications),
        "router_route_count": len(router_routes),
        "static_handler_count": len(static_handlers),
    }

    return {
        "summary": summary,
        "endpoints": endpoints,
        "jsonrpc_methods": jsonrpc_methods,
        "remote_methods": remote_methods,
        "notifications": notifications,
        "router_routes": router_routes,
        "static_handlers": static_handlers,
    }


def _dedup_notifications(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen: Dict[str, Dict[str, Any]] = {}
    for n in items:
        if n["name"] not in seen:
            seen[n["name"]] = n
    return sorted(seen.values(), key=lambda x: x["name"])


def _dedup_router_routes(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen: Dict[str, Dict[str, Any]] = {}
    for r in items:
        key = f"{r['kind']}:{r['path']}"
        if key not in seen:
            seen[key] = r
    return sorted(seen.values(), key=lambda x: (x["kind"], x["path"]))

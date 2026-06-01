"""Moonraker API-surface scanner.

Extracts Moonraker's HTTP/JSON-RPC/notification surface from its source tree
into a deterministic, diffable JSON artifact so phobos can track API drift when
the vendored Moonraker is bumped.
"""

from .scanner import scan  # noqa: F401
from .differ import diff, has_drift, render  # noqa: F401

__all__ = ["scan", "diff", "has_drift", "render"]

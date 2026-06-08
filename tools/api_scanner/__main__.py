"""CLI entry point: ``python3 -m api_scanner <mode> [options]``.

Run from the ``tools/`` directory, or with ``tools`` on PYTHONPATH, e.g.::

    PYTHONPATH=tools python3 -m api_scanner scan --source vendor/moonraker/moonraker
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict

from . import coverage as cov_module, differ, scanner, table as table_module

DEFAULT_SOURCE = "vendor/moonraker/moonraker"
DEFAULT_BASELINE = "api/api_surface.json"


def _dump(obj: Dict[str, Any]) -> str:
    # sort_keys for stable key order; the lists are already sorted by scanner.
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _load(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def cmd_scan(args: argparse.Namespace) -> int:
    result = scanner.scan(args.source)
    sys.stdout.write(_dump(result))
    return 0


def cmd_baseline(args: argparse.Namespace) -> int:
    result = scanner.scan(args.source)
    out_path = args.baseline
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(_dump(result))
    s = result["summary"]
    sys.stderr.write(
        f"wrote {out_path}: {s['endpoint_count']} endpoints, "
        f"{s['jsonrpc_method_count']} rpc methods, "
        f"{s['remote_method_count']} remote methods, "
        f"{s['notification_count']} notifications\n"
    )
    return 0


def cmd_coverage(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.baseline):
        sys.stderr.write(f"baseline not found: {args.baseline}\n")
        return 2
    if not os.path.isfile(args.phobos):
        sys.stderr.write(f"phobos dump not found: {args.phobos}\n")
        return 2

    baseline = _load(args.baseline)
    phobos_dump = _load(args.phobos)

    report = cov_module.compute_coverage(baseline, phobos_dump)
    sys.stdout.write(cov_module.format_summary(report) + "\n")
    missing_text = cov_module.format_missing(report)
    if missing_text:
        sys.stdout.write(missing_text + "\n")

    return 0 if report["covered"] == report["total"] else 1


def cmd_table(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.baseline):
        sys.stderr.write(f"baseline not found: {args.baseline}\n")
        return 2
    if not os.path.isfile(args.phobos):
        sys.stderr.write(f"phobos dump not found: {args.phobos}\n")
        return 2
    sys.stdout.write(table_module.generate(_load(args.baseline), _load(args.phobos)))
    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.baseline):
        sys.stderr.write(f"baseline not found: {args.baseline}\n")
        return 2
    baseline = _load(args.baseline)
    current = scanner.scan(args.source)
    d = differ.diff(baseline, current)
    sys.stdout.write(differ.render(d))
    return 1 if differ.has_drift(d) else 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="api_scanner",
        description="Extract and diff Moonraker's API surface.",
    )
    sub = p.add_subparsers(dest="mode", required=True)

    for name, func in (("scan", cmd_scan), ("baseline", cmd_baseline),
                       ("diff", cmd_diff)):
        sp = sub.add_parser(name)
        sp.add_argument("--source", default=DEFAULT_SOURCE,
                        help="Moonraker source root (default: %(default)s)")
        sp.add_argument("--baseline", default=DEFAULT_BASELINE,
                        help="baseline JSON path (default: %(default)s)")
        sp.set_defaults(func=func)

    cov = sub.add_parser(
        "coverage",
        help="Compare phobos --dump-api output against the Moonraker baseline.",
    )
    cov.add_argument(
        "--baseline", default=DEFAULT_BASELINE,
        help="Moonraker baseline JSON (default: %(default)s)",
    )
    cov.add_argument(
        "--phobos", required=True,
        help="Path to phobos --dump-api JSON output",
    )
    cov.set_defaults(func=cmd_coverage)

    tbl = sub.add_parser(
        "table",
        help="Generate the per-call API coverage table (Markdown) to stdout.",
    )
    tbl.add_argument("--baseline", default=DEFAULT_BASELINE,
                     help="Moonraker baseline JSON (default: %(default)s)")
    tbl.add_argument("--phobos", required=True,
                     help="Path to phobos --dump-api JSON output")
    tbl.set_defaults(func=cmd_table)

    return p


def main(argv: Any = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build the client-vs-server API coverage matrix.

Cross-references four sources of JSON-RPC method names and emits a deterministic
Markdown matrix + a JSON artifact:

  * moonraker — the upstream API surface (tools/api_scanner output)
  * phobos    — what phobos actually registers (`phobos --dump-api`)
  * fluidd    — methods the Fluidd UI calls (tools/client_api_scanner/scan.py)
  * mainsail  — methods the Mainsail UI calls

The point: every method a UI calls MUST be registered by phobos, or that UI
breaks. The matrix makes a "UI calls it, phobos lacks it" gap impossible to miss,
and — because all inputs are checked in and regenerated — a UI or Moonraker
version bump shows up as a reviewable diff.

Usage:
    python coverage.py \
        --moonraker api/moonraker_api.json \
        --phobos    api/phobos_methods.json \
        --fluidd    docs/api/client/fluidd.json \
        --mainsail  docs/api/client/mainsail.json \
        --md docs/api/CLIENT_API_COVERAGE.md --json docs/api/client/coverage.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _load_methods(path: str) -> set:
    """Load a method-name set from any of the artifact shapes we produce."""
    data = json.loads(Path(path).read_text())
    out = set()
    if isinstance(data, dict):
        if isinstance(data.get("methods"), list):  # client scanner
            out.update(m for m in data["methods"] if isinstance(m, str))
        if isinstance(data.get("jsonrpc_methods"), list):  # moonraker / phobos dump
            for e in data["jsonrpc_methods"]:
                if isinstance(e, str):
                    out.add(e)
                elif isinstance(e, dict) and isinstance(e.get("method"), str):
                    out.add(e["method"])
    elif isinstance(data, list):
        out.update(m for m in data if isinstance(m, str))
    return out


def build(moonraker, phobos, fluidd, mainsail):
    methods = sorted(moonraker | phobos | fluidd | mainsail)
    rows = []
    for m in methods:
        rows.append({
            "method": m,
            "moonraker": m in moonraker,
            "phobos": m in phobos,
            "fluidd": m in fluidd,
            "mainsail": m in mainsail,
        })
    # The gap that matters: a UI calls it but phobos does not register it.
    ui = fluidd | mainsail
    gaps = sorted(ui - phobos)
    return rows, gaps


def _tick(b):
    return "yes" if b else "—"


def to_markdown(rows, gaps, counts):
    out = []
    out.append("# Client API coverage matrix\n")
    out.append(
        "Every JSON-RPC method, cross-referenced across upstream Moonraker, phobos, "
        "and the two reference web UIs (Fluidd, Mainsail). Regenerate with "
        "`tools/client_api_scanner/` after bumping any source; the diff is the "
        "changelog.\n"
    )
    out.append(
        f"- Moonraker: **{counts['moonraker']}** · phobos: **{counts['phobos']}** · "
        f"Fluidd calls: **{counts['fluidd']}** · Mainsail calls: **{counts['mainsail']}**\n"
    )
    if gaps:
        out.append(f"\n## ⚠ UI-called methods phobos does NOT register ({len(gaps)})\n")
        for g in gaps:
            out.append(f"- `{g}`")
        out.append("")
    else:
        out.append("\n## ✓ Every method either UI calls is registered by phobos\n")
    out.append("\n## Matrix\n")
    out.append("| Method | Moonraker | phobos | Fluidd | Mainsail |")
    out.append("|---|---|---|---|---|")
    for r in rows:
        out.append(
            f"| `{r['method']}` | {_tick(r['moonraker'])} | {_tick(r['phobos'])} | "
            f"{_tick(r['fluidd'])} | {_tick(r['mainsail'])} |"
        )
    out.append("")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--moonraker", required=True)
    ap.add_argument("--phobos", required=True)
    ap.add_argument("--fluidd", required=True)
    ap.add_argument("--mainsail", required=True)
    ap.add_argument("--md")
    ap.add_argument("--json")
    args = ap.parse_args(argv)

    moonraker = _load_methods(args.moonraker)
    phobos = _load_methods(args.phobos)
    fluidd = _load_methods(args.fluidd)
    mainsail = _load_methods(args.mainsail)

    rows, gaps = build(moonraker, phobos, fluidd, mainsail)
    counts = {
        "moonraker": len(moonraker), "phobos": len(phobos),
        "fluidd": len(fluidd), "mainsail": len(mainsail),
    }

    if args.json:
        Path(args.json).write_text(
            json.dumps({"counts": counts, "ui_gaps": gaps, "matrix": rows}, indent=2) + "\n"
        )
    md = to_markdown(rows, gaps, counts)
    if args.md:
        Path(args.md).write_text(md)
        print(f"coverage: {len(rows)} methods, {len(gaps)} UI gaps -> {args.md}", file=sys.stderr)
    else:
        sys.stdout.write(md)
    return 1 if gaps else 0


if __name__ == "__main__":
    raise SystemExit(main())

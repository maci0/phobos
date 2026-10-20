#!/usr/bin/env python3
"""Build the client-vs-server API coverage matrix.

Cross-references the JSON-RPC method sets of every reference Moonraker client
against upstream Moonraker and phobos, and emits a deterministic Markdown matrix
+ JSON artifact.

Inputs (all under docs/api/client/ by default):
  * moonraker_methods.json   upstream Moonraker surface (tools/api_scanner)
  * phobos_methods.json      what phobos registers (`phobos --dump-api`)
  * <client>.json            one per UI from scan.py (has "ui" + "methods")

The matrix lists client calls whose method names phobos does not register.
It does not test client fallback behavior or the method implementations.
Checked-in inputs make client and server version changes reviewable.

Usage:
    python coverage.py --dir docs/api/client \
        --md docs/api/CLIENT_API_COVERAGE.md --json docs/api/client/coverage.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SERVER_FILES = {"moonraker_methods.json", "phobos_methods.json", "coverage.json"}


def _methods(data) -> set:
    out = set()
    if isinstance(data, dict):
        for key in ("methods", "jsonrpc_methods"):
            v = data.get(key)
            if isinstance(v, list):
                for e in v:
                    if isinstance(e, str):
                        out.add(e)
                    elif isinstance(e, dict) and isinstance(e.get("method"), str):
                        out.add(e["method"])
    elif isinstance(data, list):
        out.update(m for m in data if isinstance(m, str))
    return out


def _load(path: Path) -> set:
    return _methods(json.loads(path.read_text()))


def _gap_note(method: str) -> str:
    """Explain why a client-only method is legitimately absent from phobos."""
    if method.startswith("machine.timelapse."):
        return ": `moonraker-timelapse` plugin (3rd-party)"
    if method.startswith("server.helix."):
        return ": HelixScreen's own Moonraker plugin"
    if method == "server.files.get_file":
        return ": non-standard (not a core Moonraker JSON-RPC method; file download is HTTP)"
    return ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", default="docs/api/client")
    ap.add_argument("--md")
    ap.add_argument("--json")
    args = ap.parse_args(argv)
    d = Path(args.dir)

    moonraker = _load(d / "moonraker_methods.json")
    phobos = _load(d / "phobos_methods.json")
    clients = {}  # ui name -> (version, set)
    for f in sorted(d.glob("*.json")):
        if f.name in SERVER_FILES:
            continue
        doc = json.loads(f.read_text())
        if isinstance(doc, dict) and "methods" in doc:
            clients[doc.get("ui", f.stem)] = (doc.get("version", "?"), _methods(doc))

    client_names = sorted(clients)
    all_client_methods = set().union(*[m for _, m in clients.values()]) if clients else set()
    methods = sorted(moonraker | phobos | all_client_methods)
    gaps = sorted(all_client_methods - phobos)

    rows = []
    for m in methods:
        row = {"method": m, "moonraker": m in moonraker, "phobos": m in phobos}
        for c in client_names:
            row[c] = m in clients[c][1]
        rows.append(row)

    if args.json:
        Path(args.json).write_text(json.dumps({
            "clients": {c: {"version": clients[c][0], "count": len(clients[c][1])} for c in client_names},
            "moonraker_count": len(moonraker), "phobos_count": len(phobos),
            "client_gaps": gaps, "matrix": rows,
        }, indent=2) + "\n")

    tick = lambda b: "✅" if b else "·"
    out = ["# Client API coverage matrix\n"]
    out.append("Every JSON-RPC method registered by upstream Moonraker or phobos, or called by a "
               "reference client (web UIs and touchscreens). Regenerate with "
               "`tools/client_api_scanner/` after bumping any source; the diff is the changelog.\n")
    out.append(f"- Moonraker: **{len(moonraker)}** · phobos: **{len(phobos)}**")
    for c in client_names:
        ver, ms = clients[c]
        out.append(f"- {c} ({ver}): **{len(ms)}** calls")
    out.append("")
    if gaps:
        out.append(f"## Client-called methods phobos does not register ({len(gaps)})\n")
        out.append("These method names are absent from the checked-in phobos method set. "
                   "The matrix shows whether upstream Moonraker registers them; notes identify "
                   "known plugin calls. Client fallback behavior is not tested here.\n")
        for g in gaps:
            who = ", ".join(c for c in client_names if g in clients[c][1])
            note = _gap_note(g)
            out.append(f"- `{g}`, called by {who}{note}")
        out.append("")
    else:
        out.append("## ✅ Every method any client calls is registered by phobos\n")
    out.append("## Matrix\n")
    header = ["Method", "Moonraker", "phobos"] + client_names
    out.append("| " + " | ".join(header) + " |")
    out.append("|" + "---|" * len(header))
    for r in rows:
        cells = [f"`{r['method']}`", tick(r["moonraker"]), tick(r["phobos"])] + [tick(r[c]) for c in client_names]
        out.append("| " + " | ".join(cells) + " |")
    out.append("")
    md = "\n".join(out)
    if args.md:
        Path(args.md).write_text(md)
        print(f"coverage: {len(rows)} methods, {len(client_names)} clients, {len(gaps)} gaps -> {args.md}", file=sys.stderr)
    else:
        sys.stdout.write(md)
    return 1 if gaps else 0


if __name__ == "__main__":
    raise SystemExit(main())

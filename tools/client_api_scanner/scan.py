#!/usr/bin/env python3
"""Client API scanner — extract every Moonraker JSON-RPC method the Mainsail and
Fluidd web UIs call, straight from their TypeScript/Vue source.

phobos is a drop-in Moonraker backend, so the two reference web UIs are a second
source of truth for the API surface (alongside vendored Moonraker): if a UI calls
a method phobos does not register, that UI breaks. This tool produces a
deterministic, diffable JSON artifact of those calls so a UI version bump shows
up as a reviewable diff — the same idea as tools/api_scanner for Moonraker.

Parsing uses tree-sitter (tree-sitter-typescript) — no regex over source. Both
UIs funnel their calls through a websocket `emit(method, params, {action})`:

    Vue.$socket.emit('server.database.get_item', {...}, { action: 'gui/initStore' })   # Mainsail
    baseEmit('machine.services.restart', {...})                                         # Fluidd

We find every call whose callee is `emit`/`baseEmit` (bare or as `X.emit`), take
the first string-literal argument as the RPC method, and — when present — the
`action:` property of a trailing object argument as the UI-side response handler
(useful for pinpointing which UI store init breaks on a bad response shape).

Vue single-file components: the <script> block is sliced out by byte offset
(located via tree-sitter-typescript's tolerance of the surrounding markup is not
relied upon) and parsed as TypeScript.

Usage:
    python scan.py <ui_src_dir> --ui fluidd --version v1.37.1 [-o out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import tree_sitter as ts
import tree_sitter_typescript as ts_ts

_LANG = ts.Language(ts_ts.language_typescript())
_PARSER = ts.Parser(_LANG)

# Callee identifiers that send a JSON-RPC request to Moonraker.
EMIT_NAMES = {"emit", "baseEmit", "request", "socketEmit"}


def _script_blocks(text: str):
    """Yield (offset, code) for each <script> block in a .vue file. The offset is
    the byte index of the code start so reported line numbers stay accurate."""
    low = text.lower()
    i = 0
    while True:
        s = low.find("<script", i)
        if s < 0:
            return
        gt = low.find(">", s)
        if gt < 0:
            return
        end = low.find("</script", gt)
        if end < 0:
            return
        yield gt + 1, text[gt + 1 : end]
        i = end + 8


def _string_value(node, src: bytes):
    """Return the literal text of a tree-sitter `string` node, or None."""
    if node is None or node.type != "string":
        return None
    # string -> ( '"', string_fragment, '"' ) ; fragment may be absent for ''
    for ch in node.named_children:
        if ch.type == "string_fragment":
            return ch.text.decode("utf8", "replace")
    return ""  # empty string literal


def _find_action(arg_node, src: bytes):
    """Given an object argument, return its `action:` string property, or None."""
    if arg_node is None or arg_node.type != "object":
        return None
    for pair in arg_node.named_children:
        if pair.type != "pair":
            continue
        key = pair.child_by_field_name("key")
        val = pair.child_by_field_name("value")
        kname = None
        if key is not None and key.type in ("property_identifier", "string"):
            kname = key.text.decode() if key.type == "property_identifier" else _string_value(key, src)
        if kname == "action":
            return _string_value(val, src)
    return None


def _callee_name(fn_node):
    """The simple name of a call's callee: `emit` for `x.y.emit`, `baseEmit` for
    a bare identifier. None for anything we can't name."""
    if fn_node is None:
        return None
    if fn_node.type == "identifier":
        return fn_node.text.decode()
    if fn_node.type == "member_expression":
        prop = fn_node.child_by_field_name("property")
        if prop is not None:
            return prop.text.decode()
    return None


def _scan_code(code: str, base_line: int, file_rel: str, out: list):
    tree = _PARSER.parse(code.encode("utf8"))
    src = code.encode("utf8")
    # Walk the whole tree iteratively; collect call_expressions.
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "call_expression":
            fn = node.child_by_field_name("function")
            name = _callee_name(fn)
            if name in EMIT_NAMES:
                args = node.child_by_field_name("arguments")
                pos_args = [a for a in args.named_children] if args else []
                method = _string_value(pos_args[0], src) if pos_args else None
                if method and ("." in method) and method.split(".")[0] in (
                    "server", "printer", "machine", "access",
                ):
                    action = None
                    for a in pos_args[1:]:
                        action = _find_action(a, src)
                        if action:
                            break
                    out.append({
                        "method": method,
                        "action": action,
                        "file": file_rel,
                        "line": base_line + node.start_point[0],
                    })
        stack.extend(node.children)


def scan_tree(root: Path):
    calls: list = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in (".ts", ".js", ".vue"):
            continue
        if "node_modules" in path.parts:
            continue
        rel = str(path.relative_to(root))
        try:
            text = path.read_text(encoding="utf8", errors="replace")
        except OSError:
            continue
        if path.suffix == ".vue":
            for off, code in _script_blocks(text):
                base_line = text[:off].count("\n")
                _scan_code(code, base_line, rel, calls)
        else:
            _scan_code(text, 0, rel, calls)
    return calls


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src", help="UI source root (the repo's src/ dir or repo root)")
    ap.add_argument("--ui", required=True, help="UI name, e.g. fluidd / mainsail")
    ap.add_argument("--version", default="unknown", help="UI version/tag")
    ap.add_argument("-o", "--out", help="write JSON here (default: stdout)")
    args = ap.parse_args(argv)

    root = Path(args.src)
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2

    calls = scan_tree(root)
    methods = sorted({c["method"] for c in calls})
    # Map each method to the distinct UI-side actions that consume its response.
    actions: dict = {}
    for c in calls:
        if c["action"]:
            actions.setdefault(c["method"], set()).add(c["action"])

    doc = {
        "ui": args.ui,
        "version": args.version,
        "method_count": len(methods),
        "methods": methods,
        "actions": {m: sorted(a) for m, a in sorted(actions.items())},
    }
    text = json.dumps(doc, indent=2, sort_keys=False) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        print(f"{args.ui} {args.version}: {len(methods)} methods -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

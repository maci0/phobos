#!/usr/bin/env python3
"""Client API scanner — extract every Moonraker JSON-RPC method a UI calls,
straight from its source, for any of the reference clients:

    Mainsail, Fluidd            TypeScript / Vue   Vue.$socket.emit('m', ...)
                                                   baseEmit('m', ...)
    KlipperScreen               Python (GTK)       self._ws.send_method('m', ...)
                                                   self._send_action(w, 'm', ...)
    GuppyScreen, HelixScreen    C++  (LVGL)        ws.send_jsonrpc("m", ...)

phobos is a drop-in Moonraker backend, so these clients are extra sources of
truth for the API surface (alongside vendored Moonraker): a method a client calls
that phobos does not register breaks that client. This tool produces a
deterministic, diffable JSON artifact of those calls so a client version bump is a
reviewable diff — the same idea as tools/api_scanner for Moonraker.

Parsing is tree-sitter — tree-sitter-typescript / -python / -cpp, no regex over
source. For each language we look for calls whose callee is a known "send" method
and take the method-name string literal at that callee's known argument index.

Usage:
    python scan.py <src_dir> --ui guppyscreen --version v1.0 [-o out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import tree_sitter as ts


def _lang(modname, attr="language"):
    mod = __import__(modname)
    return ts.Language(getattr(mod, attr)())


# Per-language parsing spec. `callees` maps a send-method name to the positional
# index of its method-name string argument (KlipperScreen's _send_action takes a
# widget first, so its method is arg 1).
class Spec:
    def __init__(self, lang, exts, call_types, args_field, str_types, str_child, callees):
        self.parser = ts.Parser(lang)
        self.exts = exts
        self.call_types = call_types
        self.args_field = args_field
        self.str_types = str_types
        self.str_child = str_child
        self.callees = callees


def _build_specs():
    specs = []
    try:
        specs.append(Spec(_lang("tree_sitter_typescript", "language_typescript"),
                          {".ts", ".js", ".vue"}, {"call_expression"}, "arguments",
                          {"string"}, "string_fragment",
                          {"emit": 0, "baseEmit": 0, "request": 0, "socketEmit": 0}))
    except Exception:
        pass
    try:
        specs.append(Spec(_lang("tree_sitter_python"),
                          {".py"}, {"call"}, "arguments",
                          {"string"}, "string_content",
                          {"send_method": 0, "send_request": 0, "_send_action": 1, "send_action": 1}))
    except Exception:
        pass
    try:
        specs.append(Spec(_lang("tree_sitter_cpp"),
                          {".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx"}, {"call_expression"}, "arguments",
                          {"string_literal"}, "string_content",
                          {"send_jsonrpc": 0, "send_method": 0}))
    except Exception:
        pass
    by_ext = {}
    for s in specs:
        for e in s.exts:
            by_ext[e] = s
    return by_ext


SPECS = _build_specs()
RPC_PREFIXES = ("server", "printer", "machine", "access")


def _string_value(node, str_types, child_type):
    if node is None or node.type not in str_types:
        return None
    for ch in node.named_children:
        if ch.type == child_type:
            return ch.text.decode("utf8", "replace")
    return ""  # empty literal "" / ''


def _callee_name(fn):
    """Simple name of a call's callee across grammars: the trailing identifier of
    member_expression (TS) / attribute (Py) / field_expression (C++), or a bare
    identifier."""
    if fn is None:
        return None
    if fn.type == "identifier":
        return fn.text.decode()
    if fn.type in ("member_expression", "field_expression"):
        prop = fn.child_by_field_name("property") or fn.child_by_field_name("field")
        if prop is not None:
            return prop.text.decode()
        # field_expression (C++) keeps the member as the last named child
        if fn.named_children:
            return fn.named_children[-1].text.decode()
    if fn.type == "attribute":  # Python a.b.c -> c
        attr = fn.child_by_field_name("attribute")
        if attr is not None:
            return attr.text.decode()
        if fn.named_children:
            return fn.named_children[-1].text.decode()
    return None


def _args(call, args_field):
    a = call.child_by_field_name(args_field)
    if a is None:
        for ch in call.children:
            if ch.type in ("arguments", "argument_list"):
                a = ch
                break
    return [c for c in a.named_children] if a else []


def _scan(spec, code, base_line, file_rel, out):
    tree = spec.parser.parse(code.encode("utf8"))
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type in spec.call_types:
            name = _callee_name(node.child_by_field_name("function"))
            idx = spec.callees.get(name) if name else None
            if idx is not None:
                args = _args(node, spec.args_field)
                if len(args) > idx:
                    method = _string_value(args[idx], spec.str_types, spec.str_child)
                    # Require a well-formed dotted method in a known namespace.
                    # Skip concatenation bases like "machine.update." (trailing or
                    # empty segment) — those are <prefix> + dynamic, not a method.
                    parts = method.split(".") if method else []
                    if (len(parts) >= 2 and parts[0] in RPC_PREFIXES and all(parts)):
                        out.append({"method": method, "file": file_rel, "line": base_line + node.start_point[0]})
        stack.extend(node.children)


def _script_blocks(text):
    """<script> blocks of a .vue file, with the byte offset of the code start."""
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
        yield gt + 1, text[gt + 1:end]
        i = end + 8


def scan_tree(root: Path):
    calls = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or "node_modules" in path.parts:
            continue
        spec = SPECS.get(path.suffix)
        if spec is None:
            continue
        rel = str(path.relative_to(root))
        try:
            text = path.read_text(encoding="utf8", errors="replace")
        except OSError:
            continue
        if path.suffix == ".vue":
            for off, code in _script_blocks(text):
                _scan(spec, code, text[:off].count("\n"), rel, calls)
        else:
            _scan(spec, text, 0, rel, calls)
    return calls


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src")
    ap.add_argument("--ui", required=True)
    ap.add_argument("--version", default="unknown")
    ap.add_argument("-o", "--out")
    args = ap.parse_args(argv)

    root = Path(args.src)
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2

    calls = scan_tree(root)
    methods = sorted({c["method"] for c in calls})
    doc = {"ui": args.ui, "version": args.version, "method_count": len(methods), "methods": methods}
    text = json.dumps(doc, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        print(f"{args.ui} {args.version}: {len(methods)} methods -> {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

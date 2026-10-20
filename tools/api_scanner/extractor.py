"""tree-sitter extraction of Moonraker's API surface.

Walks Python source and pulls out endpoint, JSON-RPC method, remote method,
static/upload handler and notification registrations.  All extraction is done
with tree-sitter (tree-sitter-python) so the result is robust to formatting and
does not depend on importing Moonraker.  The same grammar backs the sibling
TypeScript scanner, which is why we parse with tree-sitter here too rather than
the stdlib :mod:`ast`.

Non-literal / dynamic arguments are recorded as the sentinel string
``"<dynamic>"`` rather than raising, so the scanner never fails on source it
cannot fully reason about statically.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

import tree_sitter as ts
import tree_sitter_python as tspy

_LANGUAGE = ts.Language(tspy.language())
_PARSER = ts.Parser(_LANGUAGE)

DYNAMIC = "<dynamic>"

# Endpoint prefixes Moonraker permits for HTTP transports (mirrors
# common.py::ENDPOINT_PREFIXES).  Informational only; never used to reject input.
ENDPOINT_PREFIXES = [
    "access", "api", "debug", "machine", "printer", "server",
]


@dataclass
class Endpoint:
    path: str
    request_types: list[str]
    transports: list[str]
    wrap_result: bool | None
    content_type: str | None
    auth_required: bool | None
    is_remote: bool
    debug_only: bool
    component: str
    source: str
    jsonrpc_methods: list[str] = field(default_factory=list)
    multi_verb: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "request_types": self.request_types,
            "transports": self.transports,
            "wrap_result": self.wrap_result,
            "content_type": self.content_type,
            "auth_required": self.auth_required,
            "is_remote": self.is_remote,
            "debug_only": self.debug_only,
            "component": self.component,
            "source": self.source,
            "jsonrpc_methods": self.jsonrpc_methods,
            "multi_verb": self.multi_verb,
        }


@dataclass
class RemoteMethod:
    name: str
    component: str
    source: str

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "component": self.component,
                "source": self.source}


@dataclass
class StaticHandler:
    kind: str  # "static" | "upload"
    pattern: str
    component: str
    source: str

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "pattern": self.pattern,
                "component": self.component, "source": self.source}


@dataclass
class Notification:
    name: str  # the wire name, e.g. "notify_status_update"
    event_name: str | None
    component: str
    source: str

    def to_dict(self) -> dict[str, Any]:
        return {"name": self.name, "event_name": self.event_name,
                "component": self.component, "source": self.source}


@dataclass
class RouterRoute:
    kind: str   # "router_route" | "websocket_route"
    path: str
    handler: str
    component: str
    source: str

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "path": self.path, "handler": self.handler,
                "component": self.component, "source": self.source}


def component_from_path(path: str, source_root: str) -> str:
    """Derive a component name from a file path.

    ``components/file_manager/file_manager.py`` -> ``file_manager``
    ``components/machine.py``                   -> ``machine``
    ``server.py``                               -> ``server``
    """
    rel = os.path.relpath(path, source_root)
    parts = rel.split(os.sep)
    if parts and parts[0] == "components":
        parts = parts[1:]
    if not parts:
        return os.path.splitext(os.path.basename(path))[0]
    # A nested component dir (e.g. file_manager/file_manager.py) is named by its
    # directory; a flat module by its filename.
    if len(parts) >= 2:
        return parts[0]
    return os.path.splitext(parts[0])[0]


# --- node helpers ----------------------------------------------------------
# tree-sitter exposes a Concrete Syntax Tree, so the helpers below skip the
# punctuation children (commas, parens, ``=``) and work off the node ``type``.

def _text(node: ts.Node) -> str:
    text = node.text
    assert text is not None
    return text.decode("utf-8")


def _decode_string(node: ts.Node) -> str | None:
    """Return the Python value of a ``string`` node, or None if it is not a
    plain ``str`` literal (bytes prefix, or a value we cannot reduce).

    tree-sitter splits literal runs (``string_content``) from escapes
    (``escape_sequence``), so the literal text is taken verbatim and only the
    escape tokens are decoded.  A raw (``r``) prefix keeps escapes literal.
    """
    prefix = ""
    out = ""
    for child in node.children:
        if child.type == "string_start":
            prefix = _text(child).rstrip("'\"").lower()
            out = ""
        elif child.type == "string_content":
            out += _text(child)
        elif child.type == "escape_sequence":
            out += _text(child) if "r" in prefix else _unescape(_text(child))
        elif child.type == "interpolation":
            # An f-string with a substitution is not a plain literal.
            return None
    if "b" in prefix:
        return None
    return out


def _unescape(escape: str) -> str:
    """Decode a single ``escape_sequence`` token (e.g. ``\\n``) the way the
    parser would, without depending on ``ast``.  Non-ASCII codepoints survive
    intact; an unrecognised escape is left verbatim."""
    try:
        return (escape.encode("utf-8")
                      .decode("unicode_escape")
                      .encode("latin-1", "backslashreplace")
                      .decode("utf-8", "replace"))
    except (UnicodeDecodeError, ValueError):
        return escape


def _string_value(node: ts.Node | None) -> Any:
    """Best-effort literal value of a string-bearing node.

    Plain ``str`` literals decode to their value.  f-strings return the trailing
    run of literal characters (so ``f"{prefix}/server/redirect"`` surfaces as
    ``/server/redirect``); when no constant suffix exists the result is DYNAMIC.
    Concatenated adjacent literals are joined.
    """
    if node is None:
        return None
    if node.type == "string":
        if _has_interpolation(node):
            return _fstring_suffix(node)
        val = _decode_string(node)
        return val if val is not None else DYNAMIC
    if node.type == "concatenated_string":
        out = ""
        for child in node.named_children:
            part = _string_value(child)
            if not isinstance(part, str) or part == DYNAMIC:
                return DYNAMIC
            out += part
        return out
    return DYNAMIC


def _has_interpolation(node: ts.Node) -> bool:
    return any(c.type == "interpolation" for c in node.children)


def _fstring_suffix(node: ts.Node) -> Any:
    """Mirror the ``ast.JoinedStr`` handling: keep the trailing literal run.

    Walk the f-string segments and accumulate the longest suffix made purely of
    literal characters, dropping anything after a variable substitution.
    """
    suffix = ""
    for child in node.children:
        if child.type == "string_content":
            suffix += _text(child)
        elif child.type == "escape_sequence":
            suffix += _unescape(_text(child))
        elif child.type == "interpolation":
            suffix = ""  # a substitution resets the literal run
    if suffix:
        return suffix
    return DYNAMIC


def _flag_names(node: ts.Node) -> list[str]:
    """Collect the leaf attribute names of an OR-chain of ``X.NAME`` accesses.

    ``RequestType.GET | RequestType.POST`` yields ``["GET", "POST"]``.
    Unknown / dynamic operands are recorded as DYNAMIC.
    """
    names: list[str] = []

    def visit(n: ts.Node) -> None:
        if n.type == "binary_operator":
            op = n.child_by_field_name("operator")
            left = n.child_by_field_name("left")
            right = n.child_by_field_name("right")
            if op is not None and _text(op) == "|" and left and right:
                visit(left)
                visit(right)
            else:
                names.append(DYNAMIC)
        elif n.type == "attribute":
            attr = n.child_by_field_name("attribute")
            # X.NAME -> NAME (X is not verified, to tolerate import aliases)
            names.append(_text(attr) if attr is not None else DYNAMIC)
        elif n.type == "parenthesized_expression":
            inner = [c for c in n.named_children]
            if len(inner) == 1:
                visit(inner[0])
            else:
                names.append(DYNAMIC)
        elif n.type == "call":
            # RequestType.all() expands to every HTTP verb, so the endpoint is
            # multi-verb and its JSON-RPC names are verb-prefixed (get_/post_/
            # delete_). Moonraker's RequestType has exactly GET|POST|DELETE.
            fn = n.child_by_field_name("function")
            meth = fn.child_by_field_name("attribute") if fn is not None and fn.type == "attribute" else None
            if meth is not None and _text(meth) == "all":
                names.extend(["GET", "POST", "DELETE"])
            else:
                names.append(DYNAMIC)
        else:
            names.append(DYNAMIC)

    visit(node)
    return names


def _bool_value(node: ts.Node | None) -> Any:
    """Return the Python bool for a ``True``/``False`` node, else DYNAMIC/None."""
    if node is None:
        return None
    if node.type == "true":
        return True
    if node.type == "false":
        return False
    return DYNAMIC


def derive_rpc_methods(
    path: str, request_types: list[str], transports: list[str], is_remote: bool
) -> tuple[list[str], bool]:
    """Replicate common.py::APIDefinition.create rpc-method derivation.

    Returns ``(methods, multi_verb)``.  ``multi_verb`` is True when the endpoint
    exposes more than one HTTP verb (and therefore verb-prefixed method names).
    """
    if is_remote:
        # Remote endpoints mount under /printer and accept GET|POST; the rpc
        # method is the dotted http path.
        if path == DYNAMIC:
            return [DYNAMIC], False
        http_path = "/printer/" + path.strip("/")
        return [http_path[1:].replace("/", ".")], False

    if path == DYNAMIC:
        return [DYNAMIC], len(request_types) > 1

    # HTTP-only definitions expose no rpc methods.
    norm_transports = [t for t in transports if t != DYNAMIC]
    if norm_transports and all(t == "HTTP" for t in norm_transports):
        return [], False

    name_parts = path.strip("/").split("/")
    concrete_verbs = [r for r in request_types if r != DYNAMIC]
    multi_verb = len(request_types) > 1
    if multi_verb:
        # Sort verbs into the canonical Moonraker enum order so that source
        # written as POST | GET yields the same method list as GET | POST.
        _VERB_ORDER = {"GET": 0, "POST": 1, "DELETE": 2}
        concrete_verbs = sorted(
            concrete_verbs, key=lambda v: _VERB_ORDER.get(v, 99))
        methods: list[str] = []
        for rtype in concrete_verbs:
            func_name = rtype.lower() + "_" + name_parts[-1]
            methods.append(".".join(name_parts[:-1] + [func_name]))
        if not methods:
            return [".".join(name_parts)], True
        return methods, True
    return [".".join(name_parts)], False


def _call_args(call: ts.Node) -> list[ts.Node]:
    """Positional argument nodes of a ``call`` (keyword args excluded)."""
    arglist = call.child_by_field_name("arguments")
    if arglist is None:
        return []
    args: list[ts.Node] = []
    for child in arglist.named_children:
        if child.type in ("keyword_argument", "comment"):
            continue
        args.append(child)
    return args


def _kw(call: ts.Node, name: str) -> ts.Node | None:
    arglist = call.child_by_field_name("arguments")
    if arglist is None:
        return None
    for child in arglist.named_children:
        if child.type != "keyword_argument":
            continue
        key = child.child_by_field_name("name")
        if key is not None and _text(key) == name:
            return child.child_by_field_name("value")
    return None


def _bool_kw(call: ts.Node, name: str, default: Any) -> Any:
    node = _kw(call, name)
    if node is None:
        return default
    val = _bool_value(node)
    if isinstance(val, bool):
        return val
    return DYNAMIC


def _attr_name(node: ts.Node) -> str | None:
    """``register_endpoint`` from a ``X.Y.register_endpoint`` call target."""
    if node.type == "attribute":
        attr = node.child_by_field_name("attribute")
        return _text(attr) if attr is not None else None
    return None


class _Visitor:
    """Recursive descent over the tree-sitter CST collecting API records."""

    def __init__(self, path: str, source_root: str, str_consts: dict[str, str]):
        self.path = path
        self.source_root = source_root
        self.component = component_from_path(path, source_root)
        self.str_consts = str_consts
        self.endpoints: list[Endpoint] = []
        self.remote_methods: list[RemoteMethod] = []
        self.static_handlers: list[StaticHandler] = []
        self.notifications: list[Notification] = []
        self.router_routes: list[RouterRoute] = []
        # add_handler Call nodes already unpacked via a for-loop, so the plain
        # call visit doesn't produce a duplicate <dynamic> entry for them.
        self._handled_call_ids: set = set()

    # -- traversal ----------------------------------------------------------
    def visit(self, node: ts.Node) -> None:
        node_type = node.type
        if node_type == "call":
            self._visit_call(node)
        elif node_type == "for_statement":
            self._try_unpack_router_for_loop(node)
        elif node_type == "string":
            self._visit_string(node)
        for child in node.children:
            self.visit(child)

    def _src(self, node: ts.Node) -> str:
        rel = os.path.relpath(self.path, self.source_root)
        return f"{rel}:{node.start_point[0] + 1}"

    def _resolve_str(self, node: ts.Node | None) -> Any:
        """Literal parse, also resolving module-level string constants by name."""
        if node is not None and node.type == "identifier":
            name = _text(node)
            if name in self.str_consts:
                return self.str_consts[name]
            return DYNAMIC
        return _string_value(node)

    def _visit_call(self, node: ts.Node) -> None:
        func = node.child_by_field_name("function")
        attr = _attr_name(func) if func is not None else None

        if attr == "register_endpoint":
            self._handle_register_endpoint(node, debug_only=False)
        elif attr == "register_debug_endpoint":
            self._handle_register_endpoint(node, debug_only=True)
        elif attr == "register_remote_method":
            self._handle_remote_method(node)
        elif attr == "register_static_file_handler":
            self._handle_static(node, "static")
        elif attr == "register_upload_handler":
            self._handle_static(node, "upload")
        elif attr == "register_notification":
            self._handle_notification(node)
        elif attr == "send_notification":
            self._handle_send_notification(node)
        elif attr == "add_handler":
            if id(node) not in self._handled_call_ids:
                self._handle_add_handler(node)
        elif attr == "register_websocket_handler":
            self._handle_websocket_handler(node)

    def _try_unpack_router_for_loop(self, node: ts.Node) -> None:
        """Detect ``for (ptrn, hdlr) in (...): router.add_handler(ptrn, hdlr, ...)``
        and unpack the tuple pairs directly for static extraction."""
        target = node.child_by_field_name("left")
        iterable = node.child_by_field_name("right")
        body = node.child_by_field_name("body")
        if target is None or iterable is None or body is None:
            return

        # Target must be a 2-tuple of names.
        if target.type != "tuple_pattern":
            return
        target_names = [c for c in target.named_children if c.type == "identifier"]
        if len(target_names) != 2:
            return
        ptrn_var = _text(target_names[0])
        hdlr_var = _text(target_names[1])

        # Iter must be a tuple of 2-element tuples (the pairs).
        if iterable.type != "tuple":
            return
        pairs = [c for c in iterable.named_children if c.type == "tuple"]

        # Body must contain exactly one add_handler call using those variables.
        body_calls = [
            c for c in _statement_calls(body)
            if ((function := c.child_by_field_name("function")) is not None and
                _attr_name(function) == "add_handler")
        ]
        if len(body_calls) != 1:
            return
        call = body_calls[0]
        args = _call_args(call)
        if len(args) < 2:
            return
        arg0, arg1 = args[0], args[1]
        if not (arg0.type == "identifier" and _text(arg0) == ptrn_var):
            return
        if not (arg1.type == "identifier" and _text(arg1) == hdlr_var):
            return

        # Mark the inner call as already-handled so the call visit skips it.
        self._handled_call_ids.add(id(call))

        # Unpack each (path, handler) pair from the tuple literal.
        for pair in pairs:
            elts = pair.named_children
            if len(elts) != 2:
                continue
            path = self._resolve_str(elts[0])
            if not isinstance(path, str):
                path = DYNAMIC
            handler_elt = elts[1]
            if handler_elt.type == "identifier":
                handler = _text(handler_elt)
            elif handler_elt.type == "attribute":
                handler = _attr_name(handler_elt) or DYNAMIC
            else:
                handler = DYNAMIC
            self.router_routes.append(RouterRoute(
                kind="router_route", path=path, handler=handler,
                component=self.component, source=self._src(call)))

    def _visit_string(self, node: ts.Node) -> None:
        # Capture hard-coded wire names such as the printer status push
        # ('method': "notify_status_update" in common.py) that are emitted
        # without going through register_notification / send_notification.
        if _has_interpolation(node):
            return
        val = _decode_string(node)
        if isinstance(val, str) and val.startswith("notify_") and len(val) > 7:
            self.notifications.append(Notification(
                name=val, event_name=None, component=self.component,
                source=self._src(node)))

    # -- endpoint -----------------------------------------------------------
    def _handle_register_endpoint(self, node: ts.Node, debug_only: bool) -> None:
        args = _call_args(node)
        # positional: endpoint, request_types, callback, [transports]
        path = self._resolve_str(args[0]) if len(args) >= 1 else DYNAMIC
        if not isinstance(path, str):
            path = DYNAMIC

        request_types: list[str] = []
        if len(args) >= 2:
            request_types = _flag_names(args[1])

        transports_node: ts.Node | None = None
        if len(args) >= 4:
            transports_node = args[3]
        kw_transports = _kw(node, "transports")
        if kw_transports is not None:
            transports_node = kw_transports
        if transports_node is not None:
            transports = _flag_names(transports_node)
        else:
            # default TransportType.all() -> HTTP + WEBSOCKET + INTERNAL
            transports = ["HTTP", "WEBSOCKET", "INTERNAL"]

        wrap_result = _bool_kw(node, "wrap_result", default=True)
        content_type = self._resolve_str(_kw(node, "content_type"))

        auth_required = _bool_kw(node, "auth_required", default=True)
        auth_alt = _kw(node, "auth")
        if auth_alt is not None:
            v = _bool_value(auth_alt)
            auth_required = v if isinstance(v, bool) else DYNAMIC

        is_remote = _bool_kw(node, "is_remote", default=False)
        is_remote_b = bool(is_remote) if is_remote != DYNAMIC else False

        rpc_methods, multi_verb = derive_rpc_methods(
            path, request_types, transports, is_remote_b,
        )

        self.endpoints.append(Endpoint(
            path=path,
            request_types=request_types,
            transports=transports,
            wrap_result=wrap_result,
            content_type=content_type,
            auth_required=auth_required,
            is_remote=is_remote_b,
            debug_only=debug_only,
            component=self.component,
            source=self._src(node),
            jsonrpc_methods=rpc_methods,
            multi_verb=multi_verb,
        ))

    # -- remote method ------------------------------------------------------
    def _handle_remote_method(self, node: ts.Node) -> None:
        args = _call_args(node)
        name = self._resolve_str(args[0]) if args else DYNAMIC
        if not isinstance(name, str):
            name = DYNAMIC
        self.remote_methods.append(RemoteMethod(
            name=name, component=self.component, source=self._src(node)))

    # -- static / upload ----------------------------------------------------
    def _handle_static(self, node: ts.Node, kind: str) -> None:
        args = _call_args(node)
        pattern = self._resolve_str(args[0]) if args else DYNAMIC
        if not isinstance(pattern, str):
            pattern = DYNAMIC
        self.static_handlers.append(StaticHandler(
            kind=kind, pattern=pattern, component=self.component,
            source=self._src(node)))

    # -- notification (register_notification) -------------------------------
    def _handle_notification(self, node: ts.Node) -> None:
        args = _call_args(node)
        event = self._resolve_str(args[0]) if args else DYNAMIC
        notify_name: Any = None
        if len(args) >= 2:
            notify_name = self._resolve_str(args[1])
        kw_nn = _kw(node, "notify_name")
        if kw_nn is not None:
            notify_name = self._resolve_str(kw_nn)

        if isinstance(notify_name, str) and notify_name != DYNAMIC:
            wire = "notify_" + notify_name
        elif isinstance(event, str) and event != DYNAMIC:
            wire = "notify_" + event.split(":")[-1]
        else:
            # fully dynamic forwarding call (e.g. the server.py wrapper); skip.
            return
        self.notifications.append(Notification(
            name=wire,
            event_name=event if isinstance(event, str) else None,
            component=self.component,
            source=self._src(node)))

    # -- send_notification("name", ...) -> notify_name ----------------------
    def _handle_send_notification(self, node: ts.Node) -> None:
        args = _call_args(node)
        name = self._resolve_str(args[0]) if args else DYNAMIC
        if not isinstance(name, str) or name == DYNAMIC:
            return
        self.notifications.append(Notification(
            name="notify_" + name, event_name=None, component=self.component,
            source=self._src(node)))

    # -- mutable_router.add_handler(path, HandlerClass, ...) ----------------
    def _handle_add_handler(self, node: ts.Node) -> None:
        """Capture direct Tornado router registrations (router_route kind)."""
        args = _call_args(node)
        if len(args) < 2:
            return
        path = self._resolve_str(args[0])
        if not isinstance(path, str):
            path = DYNAMIC
        handler_node = args[1]
        if handler_node.type == "identifier":
            handler = _text(handler_node)
        elif handler_node.type == "attribute":
            handler = _attr_name(handler_node) or DYNAMIC
        else:
            handler = DYNAMIC
        self.router_routes.append(RouterRoute(
            kind="router_route", path=path, handler=handler,
            component=self.component, source=self._src(node)))

    # -- app.register_websocket_handler(path, HandlerClass) -----------------
    def _handle_websocket_handler(self, node: ts.Node) -> None:
        """Capture websocket transport route registrations."""
        args = _call_args(node)
        if len(args) < 1:
            return
        path = self._resolve_str(args[0])
        if not isinstance(path, str):
            path = DYNAMIC
        handler = DYNAMIC
        if len(args) >= 2:
            handler_node = args[1]
            if handler_node.type == "identifier":
                handler = _text(handler_node)
            elif handler_node.type == "attribute":
                handler = _attr_name(handler_node) or DYNAMIC
        self.router_routes.append(RouterRoute(
            kind="websocket_route", path=path, handler=handler,
            component=self.component, source=self._src(node)))


def _statement_calls(block: ts.Node) -> list[ts.Node]:
    """``call`` nodes that are the sole expression of a statement in ``block``."""
    calls: list[ts.Node] = []
    for stmt in block.named_children:
        if stmt.type != "expression_statement":
            continue
        exprs = stmt.named_children
        if len(exprs) == 1 and exprs[0].type == "call":
            calls.append(exprs[0])
    return calls


def _collect_str_consts(root: ts.Node) -> dict[str, str]:
    """Module-level ``NAME = "literal"`` assignments, for resolving constants."""
    consts: dict[str, str] = {}
    for stmt in root.named_children:
        if stmt.type != "expression_statement":
            continue
        for expr in stmt.named_children:
            if expr.type != "assignment":
                continue
            target = expr.child_by_field_name("left")
            value = expr.child_by_field_name("right")
            if target is None or value is None:
                continue
            if target.type != "identifier" or value.type != "string":
                continue
            if _has_interpolation(value):
                continue
            val = _decode_string(value)
            if val is not None:
                consts[_text(target)] = val
    return consts


def extract_from_source(
    source: str, path: str = "<memory>", source_root: str = ""
) -> _Visitor:
    """Parse ``source`` and return a visitor holding the extracted records.

    Malformed source still parses (tree-sitter is error-tolerant); the visitor
    simply yields whatever could be recovered rather than raising.
    """
    root_dir = source_root or os.path.dirname(path)
    tree = _PARSER.parse(source.encode("utf-8"))
    root = tree.root_node
    consts = _collect_str_consts(root)
    visitor = _Visitor(path, root_dir, consts)
    visitor.visit(root)
    return visitor

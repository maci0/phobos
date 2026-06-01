"""AST-based extraction of Moonraker's API surface.

Walks Python source and pulls out endpoint, JSON-RPC method, remote method,
static/upload handler and notification registrations.  All extraction is done
with the :mod:`ast` module so the result is robust to formatting and does not
depend on importing Moonraker.

Non-literal / dynamic arguments are recorded as the sentinel string
``"<dynamic>"`` rather than raising, so the scanner never fails on source it
cannot fully reason about statically.
"""

from __future__ import annotations

import ast
import os
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# ast.literal_eval safely parses Python literals only (no code execution).
_safe_parse_literal = ast.literal_eval

DYNAMIC = "<dynamic>"

# Endpoint prefixes Moonraker permits for HTTP transports (mirrors
# common.py::ENDPOINT_PREFIXES).  Informational only; never used to reject input.
ENDPOINT_PREFIXES = [
    "access", "api", "debug", "machine", "printer", "server",
]


@dataclass
class Endpoint:
    path: str
    request_types: List[str]
    transports: List[str]
    wrap_result: Optional[bool]
    content_type: Optional[str]
    auth_required: Optional[bool]
    is_remote: bool
    debug_only: bool
    component: str
    source: str
    jsonrpc_methods: List[str] = field(default_factory=list)
    multi_verb: bool = False

    def to_dict(self) -> Dict[str, Any]:
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

    def to_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "component": self.component,
                "source": self.source}


@dataclass
class StaticHandler:
    kind: str  # "static" | "upload"
    pattern: str
    component: str
    source: str

    def to_dict(self) -> Dict[str, Any]:
        return {"kind": self.kind, "pattern": self.pattern,
                "component": self.component, "source": self.source}


@dataclass
class Notification:
    name: str  # the wire name, e.g. "notify_status_update"
    event_name: Optional[str]
    component: str
    source: str

    def to_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "event_name": self.event_name,
                "component": self.component, "source": self.source}


@dataclass
class RouterRoute:
    kind: str   # "router_route" | "websocket_route"
    path: str
    handler: str
    component: str
    source: str

    def to_dict(self) -> Dict[str, Any]:
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


def _flag_names(node: ast.AST) -> List[str]:
    """Collect the leaf attribute names of an OR-chain of ``X.NAME`` accesses.

    ``RequestType.GET | RequestType.POST`` yields ``["GET", "POST"]``.
    Unknown / dynamic operands are recorded as DYNAMIC.
    """
    names: List[str] = []

    def visit(n: ast.AST) -> None:
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.BitOr):
            visit(n.left)
            visit(n.right)
        elif isinstance(n, ast.Attribute):
            # X.NAME -> NAME (X is not verified, to tolerate import aliases)
            names.append(n.attr)
        else:
            names.append(DYNAMIC)

    visit(node)
    return names


def _literal(node: Optional[ast.AST]) -> Any:
    """Return a Python literal for ``node`` or DYNAMIC if not statically known.

    For f-strings (``ast.JoinedStr``) the constant suffix (the last run of
    literal characters) is returned so that paths like
    ``f"{prefix}/server/redirect"`` still surface as ``/server/redirect``.
    When no constant segments exist the result is DYNAMIC.
    """
    if node is None:
        return None
    # f-strings: collect the literal constant parts in order
    if isinstance(node, ast.JoinedStr):
        parts = []
        for v in node.values:
            if isinstance(v, ast.Constant) and isinstance(v.value, str):
                parts.append(v.value)
            else:
                parts.append(None)  # variable placeholder
        # Build the best static approximation: drop leading variable segments,
        # keep any trailing literal run that looks like a path.
        literal_suffix = ""
        for p in reversed(parts):
            if p is None:
                break
            literal_suffix = p + literal_suffix
        if literal_suffix:
            return literal_suffix
        return DYNAMIC
    try:
        return _safe_parse_literal(node)
    except (ValueError, TypeError, SyntaxError):
        return DYNAMIC


def derive_rpc_methods(
    path: str, request_types: List[str], transports: List[str], is_remote: bool
) -> Tuple[List[str], bool]:
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
        methods: List[str] = []
        for rtype in concrete_verbs:
            func_name = rtype.lower() + "_" + name_parts[-1]
            methods.append(".".join(name_parts[:-1] + [func_name]))
        if not methods:
            return [".".join(name_parts)], True
        return methods, True
    return [".".join(name_parts)], False


def _kw(call: ast.Call, name: str) -> Optional[ast.AST]:
    for kw in call.keywords:
        if kw.arg == name:
            return kw.value
    return None


def _bool_kw(call: ast.Call, name: str, default: Any) -> Any:
    node = _kw(call, name)
    if node is None:
        return default
    val = _literal(node)
    if isinstance(val, bool):
        return val
    return DYNAMIC


class _Visitor(ast.NodeVisitor):
    def __init__(self, path: str, source_root: str, str_consts: Dict[str, str]):
        self.path = path
        self.source_root = source_root
        self.component = component_from_path(path, source_root)
        self.str_consts = str_consts
        self.endpoints: List[Endpoint] = []
        self.remote_methods: List[RemoteMethod] = []
        self.static_handlers: List[StaticHandler] = []
        self.notifications: List[Notification] = []
        self.router_routes: List[RouterRoute] = []
        # AST node ids of add_handler Call nodes already unpacked via visit_For,
        # so visit_Call doesn't produce a duplicate <dynamic> entry for them.
        self._handled_call_ids: set = set()

    def _src(self, node: ast.AST) -> str:
        rel = os.path.relpath(self.path, self.source_root)
        return f"{rel}:{node.lineno}"

    def _resolve_str(self, node: Optional[ast.AST]) -> Any:
        """Literal parse, also resolving module-level string constants by name."""
        if isinstance(node, ast.Name) and node.id in self.str_consts:
            return self.str_consts[node.id]
        return _literal(node)

    def visit_Call(self, node: ast.Call) -> None:  # noqa: N802
        func = node.func
        attr = func.attr if isinstance(func, ast.Attribute) else None

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

        self.generic_visit(node)

    def visit_For(self, node: ast.For) -> None:  # noqa: N802
        """Detect `for (ptrn, hdlr) in (...): router.add_handler(ptrn, hdlr, ...)`
        and unpack the tuple pairs directly for static extraction."""
        self._try_unpack_router_for_loop(node)
        self.generic_visit(node)

    def _try_unpack_router_for_loop(self, node: ast.For) -> None:
        """If the For loop matches the add_handler pattern, extract each pair."""
        # Target must be a 2-tuple of Names
        if not (isinstance(node.target, ast.Tuple) and
                len(node.target.elts) == 2 and
                all(isinstance(e, ast.Name) for e in node.target.elts)):
            return
        ptrn_var = node.target.elts[0].id  # type: ignore[attr-defined]
        hdlr_var = node.target.elts[1].id  # type: ignore[attr-defined]

        # Iter must be a Tuple of 2-element Tuples (the pairs)
        if not isinstance(node.iter, ast.Tuple):
            return
        pairs = node.iter.elts

        # Body must contain exactly one add_handler call using those variables
        body_calls = [
            s.value for s in node.body
            if isinstance(s, ast.Expr) and isinstance(s.value, ast.Call)
        ]
        if len(body_calls) != 1:
            return
        call = body_calls[0]
        func = call.func
        if not (isinstance(func, ast.Attribute) and func.attr == "add_handler"):
            return
        if len(call.args) < 2:
            return
        arg0, arg1 = call.args[0], call.args[1]
        if not (isinstance(arg0, ast.Name) and arg0.id == ptrn_var):
            return
        if not (isinstance(arg1, ast.Name) and arg1.id == hdlr_var):
            return

        # Mark the inner call as already-handled so visit_Call skips it.
        self._handled_call_ids.add(id(call))

        # Unpack each (path, handler) pair from the tuple literal
        for pair in pairs:
            if not (isinstance(pair, ast.Tuple) and len(pair.elts) == 2):
                continue
            path = self._resolve_str(pair.elts[0])
            if not isinstance(path, str):
                # Try module-level str consts; resolve returns DYNAMIC if unknown
                path = DYNAMIC
            handler_elt = pair.elts[1]
            if isinstance(handler_elt, ast.Name):
                handler = handler_elt.id
            elif isinstance(handler_elt, ast.Attribute):
                handler = handler_elt.attr
            else:
                handler = DYNAMIC
            self.router_routes.append(RouterRoute(
                kind="router_route", path=path, handler=handler,
                component=self.component, source=self._src(call)))

    def visit_Constant(self, node: ast.Constant) -> None:  # noqa: N802
        # Capture hard-coded wire names such as the printer status push
        # ('method': "notify_status_update" in common.py) that are emitted
        # without going through register_notification / send_notification.
        val = node.value
        if isinstance(val, str) and val.startswith("notify_") and len(val) > 7:
            self.notifications.append(Notification(
                name=val, event_name=None, component=self.component,
                source=self._src(node)))
        self.generic_visit(node)

    # -- endpoint -----------------------------------------------------------
    def _handle_register_endpoint(self, node: ast.Call, debug_only: bool) -> None:
        args = node.args
        # positional: endpoint, request_types, callback, [transports]
        path = self._resolve_str(args[0]) if len(args) >= 1 else DYNAMIC
        if not isinstance(path, str):
            path = DYNAMIC

        request_types: List[str] = []
        if len(args) >= 2:
            request_types = _flag_names(args[1])

        transports_node: Optional[ast.AST] = None
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
            v = _literal(auth_alt)
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
    def _handle_remote_method(self, node: ast.Call) -> None:
        name = self._resolve_str(node.args[0]) if node.args else DYNAMIC
        if not isinstance(name, str):
            name = DYNAMIC
        self.remote_methods.append(RemoteMethod(
            name=name, component=self.component, source=self._src(node)))

    # -- static / upload ----------------------------------------------------
    def _handle_static(self, node: ast.Call, kind: str) -> None:
        pattern = self._resolve_str(node.args[0]) if node.args else DYNAMIC
        if not isinstance(pattern, str):
            pattern = DYNAMIC
        self.static_handlers.append(StaticHandler(
            kind=kind, pattern=pattern, component=self.component,
            source=self._src(node)))

    # -- notification (register_notification) -------------------------------
    def _handle_notification(self, node: ast.Call) -> None:
        event = self._resolve_str(node.args[0]) if node.args else DYNAMIC
        notify_name: Any = None
        if len(node.args) >= 2:
            notify_name = self._resolve_str(node.args[1])
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
    def _handle_send_notification(self, node: ast.Call) -> None:
        name = self._resolve_str(node.args[0]) if node.args else DYNAMIC
        if not isinstance(name, str) or name == DYNAMIC:
            return
        self.notifications.append(Notification(
            name="notify_" + name, event_name=None, component=self.component,
            source=self._src(node)))

    # -- mutable_router.add_handler(path, HandlerClass, ...) ----------------
    def _handle_add_handler(self, node: ast.Call) -> None:
        """Capture direct Tornado router registrations (router_route kind)."""
        if len(node.args) < 2:
            return
        path = self._resolve_str(node.args[0])
        if not isinstance(path, str):
            path = DYNAMIC
        handler_node = node.args[1]
        if isinstance(handler_node, ast.Name):
            handler = handler_node.id
        elif isinstance(handler_node, ast.Attribute):
            handler = handler_node.attr
        else:
            handler = DYNAMIC
        self.router_routes.append(RouterRoute(
            kind="router_route", path=path, handler=handler,
            component=self.component, source=self._src(node)))

    # -- app.register_websocket_handler(path, HandlerClass) -----------------
    def _handle_websocket_handler(self, node: ast.Call) -> None:
        """Capture websocket transport route registrations."""
        if len(node.args) < 1:
            return
        path = self._resolve_str(node.args[0])
        if not isinstance(path, str):
            path = DYNAMIC
        handler = DYNAMIC
        if len(node.args) >= 2:
            handler_node = node.args[1]
            if isinstance(handler_node, ast.Name):
                handler = handler_node.id
            elif isinstance(handler_node, ast.Attribute):
                handler = handler_node.attr
        self.router_routes.append(RouterRoute(
            kind="websocket_route", path=path, handler=handler,
            component=self.component, source=self._src(node)))


def _collect_str_consts(tree: ast.AST) -> Dict[str, str]:
    """Module-level ``NAME = "literal"`` assignments, for resolving constants."""
    consts: Dict[str, str] = {}
    for stmt in getattr(tree, "body", []):
        if isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Constant) \
                and isinstance(stmt.value.value, str):
            for tgt in stmt.targets:
                if isinstance(tgt, ast.Name):
                    consts[tgt.id] = stmt.value.value
    return consts


def extract_from_source(
    source: str, path: str = "<memory>", source_root: str = ""
) -> _Visitor:
    """Parse ``source`` and return a visitor holding the extracted records.

    On a syntax error the visitor is returned empty (the scanner skips the
    file) rather than raising.
    """
    root = source_root or os.path.dirname(path)
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError:
        return _Visitor(path, root, {})
    consts = _collect_str_consts(tree)
    visitor = _Visitor(path, root, consts)
    visitor.visit(tree)
    return visitor

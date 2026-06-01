"""Unit tests for the AST extractor."""

from api_scanner import extractor as ex
from api_scanner.extractor import DYNAMIC, derive_rpc_methods, extract_from_source


def _one_endpoint(src):
    v = extract_from_source(src, "components/sample.py", source_root=".")
    assert len(v.endpoints) == 1
    return v.endpoints[0]


# --- register_endpoint -----------------------------------------------------

def test_simple_get_endpoint_and_method():
    src = (
        "class C:\n"
        "    def init(self):\n"
        "        self.server.register_endpoint(\n"
        "            '/server/info', RequestType.GET, cb, wrap_result=True\n"
        "        )\n"
    )
    e = _one_endpoint(src)
    assert e.path == "/server/info"
    assert e.request_types == ["GET"]
    assert e.wrap_result is True
    assert e.auth_required is True
    assert e.is_remote is False
    assert e.debug_only is False
    assert e.multi_verb is False
    # default transports include WEBSOCKET -> rpc method derived
    assert e.jsonrpc_methods == ["server.info"]


def test_component_derived_from_path():
    e = _one_endpoint(
        "self.server.register_endpoint('/server/info', RequestType.GET, cb)\n"
    )
    assert e.component == "sample"


def test_nested_component_name():
    src = "self.server.register_endpoint('/server/files', RequestType.GET, cb)\n"
    v = extract_from_source(
        src, "components/file_manager/file_manager.py", source_root=".")
    assert v.endpoints[0].component == "file_manager"


def test_multi_verb_endpoint_prefixes_methods():
    src = (
        "self.server.register_endpoint(\n"
        "    '/server/history/job', RequestType.GET | RequestType.DELETE, cb\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.multi_verb is True
    assert e.request_types == ["GET", "DELETE"]
    assert e.jsonrpc_methods == [
        "server.history.get_job", "server.history.delete_job"]


def test_http_only_endpoint_has_no_rpc_method():
    src = (
        "self.server.register_endpoint(\n"
        "    '/access/login', RequestType.POST, cb,\n"
        "    transports=TransportType.HTTP, wrap_result=False\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.transports == ["HTTP"]
    assert e.wrap_result is False
    assert e.jsonrpc_methods == []


def test_transports_positional_fourth_arg():
    src = (
        "self.server.register_endpoint(\n"
        "    '/server/x', RequestType.GET, cb, TransportType.WEBSOCKET\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.transports == ["WEBSOCKET"]
    assert e.jsonrpc_methods == ["server.x"]


def test_auth_required_false_and_content_type():
    src = (
        "self.server.register_endpoint(\n"
        "    '/server/x', RequestType.GET, cb,\n"
        "    auth_required=False, content_type='text/plain'\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.auth_required is False
    assert e.content_type == "text/plain"


def test_combined_transports_or_chain():
    src = (
        "self.server.register_endpoint(\n"
        "    '/server/x', RequestType.GET, cb,\n"
        "    transports=TransportType.HTTP | TransportType.WEBSOCKET\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.transports == ["HTTP", "WEBSOCKET"]


def test_is_remote_endpoint():
    src = (
        "self.server.register_endpoint(\n"
        "    ep, RequestType.GET | RequestType.POST, self.request, is_remote=True\n"
        ")\n"
    )
    e = _one_endpoint(src)
    # endpoint is a Name -> dynamic path
    assert e.path == DYNAMIC
    assert e.is_remote is True


def test_is_remote_literal_path_method_derivation():
    methods, multi = derive_rpc_methods(
        "gcode/script", [], [], is_remote=True)
    assert methods == ["printer.gcode.script"]
    assert multi is False


# --- debug endpoint --------------------------------------------------------

def test_debug_endpoint_marked():
    src = (
        "self.server.register_debug_endpoint(\n"
        "    '/debug/x', RequestType.GET, cb\n"
        ")\n"
    )
    e = _one_endpoint(src)
    assert e.debug_only is True
    assert e.path == "/debug/x"


# --- remote / static / upload ---------------------------------------------

def test_remote_method():
    src = "self.server.register_remote_method('reboot_machine', self.reboot)\n"
    v = extract_from_source(src, "components/machine.py", source_root=".")
    assert len(v.remote_methods) == 1
    assert v.remote_methods[0].name == "reboot_machine"
    assert v.remote_methods[0].component == "machine"


def test_static_and_upload_handlers():
    src = (
        "self.register_static_file_handler('klippy.log', path)\n"
        "self.register_upload_handler('/server/files/upload')\n"
    )
    v = extract_from_source(src, "components/application.py", source_root=".")
    kinds = sorted((h.kind, h.pattern) for h in v.static_handlers)
    assert kinds == [("static", "klippy.log"),
                     ("upload", "/server/files/upload")]


# --- notifications ---------------------------------------------------------

def test_register_notification_default_name():
    src = "self.server.register_notification('machine:sudo_alert')\n"
    v = extract_from_source(src, "components/machine.py", source_root=".")
    assert v.notifications[0].name == "notify_sudo_alert"
    assert v.notifications[0].event_name == "machine:sudo_alert"


def test_register_notification_explicit_positional_name():
    src = (
        "self.server.register_notification(\n"
        "    'announcements:dismissed', 'announcement_dismissed'\n"
        ")\n"
    )
    v = extract_from_source(src, "components/announcements.py", source_root=".")
    assert v.notifications[0].name == "notify_announcement_dismissed"


def test_notification_from_module_constant():
    src = (
        "SENSOR_EVENT_NAME = 'sensors:sensor_update'\n"
        "class C:\n"
        "    def init(self):\n"
        "        self.server.register_notification(SENSOR_EVENT_NAME)\n"
    )
    v = extract_from_source(src, "components/sensor.py", source_root=".")
    names = [n.name for n in v.notifications]
    assert "notify_sensor_update" in names


def test_status_update_literal_captured():
    src = "msg = {'method': 'notify_status_update'}\n"
    v = extract_from_source(src, "common.py", source_root=".")
    assert any(n.name == "notify_status_update" for n in v.notifications)


def test_send_notification_call():
    src = "conn.send_notification('agent_event', [evt])\n"
    v = extract_from_source(src, "components/extensions.py", source_root=".")
    assert any(n.name == "notify_agent_event" for n in v.notifications)


def test_dynamic_notification_forwarding_skipped():
    # the server.py wrapper forwards Name args; must not yield notify_<dynamic>
    src = "self.wsm.register_notification(event_name, notify_name)\n"
    v = extract_from_source(src, "server.py", source_root=".")
    assert v.notifications == []


# --- flag parsing helpers --------------------------------------------------

def test_flag_names_dynamic_operand():
    import ast
    node = ast.parse("RequestType.GET | foo()", mode="eval").body
    assert ex._flag_names(node) == ["GET", DYNAMIC]

"""Tests for the multi-language tree-sitter client API scanner."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import scan  # noqa: E402


def _calls(ext, code):
    spec = scan.SPECS[ext]
    out = []
    scan._scan(spec, code, 0, "x" + ext, out)
    return [c["method"] for c in out]


def test_typescript_mainsail_and_fluidd_forms():
    code = ("Vue.$socket.emit('server.database.get_item', {}, { action: 'gui/initStore' });"
            "baseEmit('machine.services.restart', {});")
    assert sorted(_calls(".ts", code)) == ["machine.services.restart", "server.database.get_item"]


def test_python_klipperscreen_send_method_and_send_action():
    # send_method: method is arg 0; _send_action: method is arg 1 (widget first)
    code = ("self._ws.send_method('printer.emergency_stop')\n"
            "self.screen._send_action(None, 'printer.gcode.script', {'script': 'G28'})\n")
    assert sorted(_calls(".py", code)) == ["printer.emergency_stop", "printer.gcode.script"]


def test_cpp_guppy_helix_send_jsonrpc():
    code = ('ws.send_jsonrpc("server.database.post_item", h);\n'
            'client_.send_jsonrpc("printer.objects.query", {{"objects", q}});\n')
    assert sorted(_calls(".cpp", code)) == ["printer.objects.query", "server.database.post_item"]


def test_skips_non_rpc_and_malformed():
    # not an rpc namespace; trailing-dot concatenation base; dynamic (non-literal)
    code = ("emit('foo.bar', {}); emit('machine.update.', {}); emit(methodVar, {}); "
            "emit('printer.objects.subscribe', {})")
    assert _calls(".ts", code) == ["printer.objects.subscribe"]


def test_all_namespaces():
    code = ('s.send_jsonrpc("server.info"); s.send_jsonrpc("printer.info"); '
            's.send_jsonrpc("machine.system_info"); s.send_jsonrpc("access.login");')
    assert sorted(_calls(".cpp", code)) == [
        "access.login", "machine.system_info", "printer.info", "server.info"]


def test_vue_script_block():
    vue = "<template><div/></template>\n<script lang='ts'>\nemit('server.config', {})\n</script>\n"
    out = []
    spec = scan.SPECS[".vue"]
    for off, code in scan._script_blocks(vue):
        scan._scan(spec, code, vue[:off].count("\n"), "c.vue", out)
    assert [c["method"] for c in out] == ["server.config"]
    assert out[0]["line"] >= 2

"""Tests for the tree-sitter client API scanner."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import scan  # noqa: E402


def _calls(code):
    out = []
    scan._scan_code(code, 0, "x.ts", out)
    return out


def test_mainsail_emit_with_action():
    code = "Vue.$socket.emit('server.database.get_item', { namespace: 'mainsail' }, { action: 'gui/initStore' })"
    calls = _calls(code)
    assert len(calls) == 1
    assert calls[0]["method"] == "server.database.get_item"
    assert calls[0]["action"] == "gui/initStore"


def test_fluidd_baseemit():
    code = "baseEmit('machine.services.restart', { params: { service } })"
    calls = _calls(code)
    assert [c["method"] for c in calls] == ["machine.services.restart"]
    assert calls[0]["action"] is None


def test_ignores_non_rpc_strings_and_dynamic_method():
    # not an rpc namespace, and a non-literal (variable) method are both skipped
    code = "emit('foo.bar', {}); emit(methodVar, {}); emit('printer.gcode.script', {})"
    methods = [c["method"] for c in _calls(code)]
    assert methods == ["printer.gcode.script"]


def test_all_four_namespaces():
    code = """
      emit('server.info', {})
      emit('printer.objects.subscribe', {})
      emit('machine.system_info', {})
      emit('access.login', {})
    """
    methods = sorted(c["method"] for c in _calls(code))
    assert methods == ["access.login", "machine.system_info", "printer.objects.subscribe", "server.info"]


def test_vue_script_block_extraction():
    vue = "<template><div/></template>\n<script lang='ts'>\nemit('server.config', {})\n</script>\n"
    out = []
    for off, code in scan._script_blocks(vue):
        base = vue[:off].count("\n")
        scan._scan_code(code, base, "c.vue", out)
    assert [c["method"] for c in out] == ["server.config"]
    assert out[0]["line"] >= 2  # line number offset into the .vue file

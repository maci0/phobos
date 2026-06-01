"""End-to-end CLI / scanner tests over a synthetic mini source tree."""

import json
import os

from api_scanner import __main__ as cli
from api_scanner import scanner

MINI = {
    "server.py": (
        "class S:\n"
        "    def init(self):\n"
        "        self.register_endpoint('/server/info', RequestType.GET, cb)\n"
        "        self.register_notification('server:klippy_ready')\n"
    ),
    "components/machine.py": (
        "class M:\n"
        "    def init(self):\n"
        "        self.server.register_endpoint(\n"
        "            '/machine/update', RequestType.GET | RequestType.POST, cb)\n"
        "        self.server.register_remote_method('reboot_machine', self.r)\n"
    ),
    "__version__.py": "__version__ = '9.9.9-test'\n",
}


def _build_tree(root):
    for rel, content in MINI.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path) or root, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)


def test_scan_over_tree(tmp_path):
    _build_tree(str(tmp_path))
    result = scanner.scan(str(tmp_path))
    s = result["summary"]
    assert s["endpoint_count"] == 2
    assert s["remote_method_count"] == 1
    assert s["notification_count"] == 1
    assert s["moonraker_version"] == "9.9.9-test"
    methods = [m["method"] for m in result["jsonrpc_methods"]]
    assert "server.info" in methods
    assert "machine.get_update" in methods
    assert "machine.post_update" in methods


def test_scan_is_deterministic(tmp_path):
    _build_tree(str(tmp_path))
    a = json.dumps(scanner.scan(str(tmp_path)), sort_keys=True)
    b = json.dumps(scanner.scan(str(tmp_path)), sort_keys=True)
    assert a == b


def test_cli_baseline_and_diff_exit_codes(tmp_path, capsys):
    src = str(tmp_path / "src")
    os.makedirs(src)
    _build_tree(src)
    baseline = str(tmp_path / "api" / "api_surface.json")

    # baseline -> 0, writes file
    rc = cli.main(["baseline", "--source", src, "--baseline", baseline])
    assert rc == 0
    assert os.path.isfile(baseline)

    # diff against identical tree -> 0
    rc = cli.main(["diff", "--source", src, "--baseline", baseline])
    assert rc == 0
    out = capsys.readouterr().out
    assert "No API drift" in out

    # mutate source, diff -> 1
    with open(os.path.join(src, "components", "machine.py"), "a",
              encoding="utf-8") as fh:
        fh.write(
            "        self.server.register_endpoint(\n"
            "            '/machine/extra', RequestType.GET, cb)\n")
    rc = cli.main(["diff", "--source", src, "--baseline", baseline])
    assert rc == 1
    out = capsys.readouterr().out
    assert "ADDED" in out
    assert "/machine/extra" in out


def test_cli_diff_missing_baseline(tmp_path):
    src = str(tmp_path)
    _build_tree(src)
    rc = cli.main(["diff", "--source", src,
                   "--baseline", str(tmp_path / "nope.json")])
    assert rc == 2

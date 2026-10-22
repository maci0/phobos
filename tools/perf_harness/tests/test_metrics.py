import http.server
import io
import json
import shutil
import socket
import subprocess
import threading
from pathlib import Path

import pytest

from tools.perf_harness import klippy_stub, report


@pytest.mark.skipif(shutil.which("vegeta") is None, reason="requires Vegeta")
def test_loadtest_drains_large_responses_without_retaining_their_bodies() -> None:
    root = next(
        path
        for path in Path(__file__).resolve().parents
        if (path / "build.zig.zon").is_file()
    )
    payload = b"x" * (128 * 1024)
    sent: list[int] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            sent.append(len(payload))

        def log_message(self, _format: str, *args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        result = subprocess.run(
            [
                "bash",
                str(root / "tools/perf_harness/loadtest.sh"),
                f"127.0.0.1:{server.server_port}",
                "bounded-body",
                "50",
                "1s",
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        directory = root / next(
            line.removeprefix("captures: ")
            for line in result.stdout.splitlines()
            if line.startswith("captures: ")
        )
        assert directory.is_relative_to(root / ".scratch")
        capture = directory / "results.bin"
        measured = json.loads(
            subprocess.check_output(
                ["vegeta", "report", "-type=json", str(capture)], timeout=5
            )
        )
        assert measured["success"] == 1 and measured["requests"] >= 49
        assert len(sent) == measured["requests"]
        assert sum(sent) >= 49 * len(payload)
        assert measured["bytes_in"]["total"] == 0
        assert capture.stat().st_size < 100_000
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        assert not worker.is_alive()


def test_report_formats_observed_metrics(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    data = {
        "throughput": 12,
        "success": 0.5,
        "latencies": {"50th": 1_000_000, "99th": 2_000_000},
    }
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(data)))
    report.main()
    assert capsys.readouterr().out == "thru=12 succ=50.0% p50=1.00ms p99=2.00ms\n"


def test_report_does_not_turn_missing_measurements_into_zero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    with pytest.raises(KeyError):
        report.main()


def test_stub_advertises_query_endpoints() -> None:
    endpoints = klippy_stub._handle("list_endpoints", {})["endpoints"]
    assert isinstance(endpoints, list)
    assert "objects/query" in endpoints
    assert "objects/subscribe" in endpoints
    status = klippy_stub._handle("objects/query", {"objects": {"heater_bed": None}})
    assert status["status"] == {
        "heater_bed": {"temperature": 24.31, "target": 0.0, "power": 0.0}
    }


def test_stub_requires_an_explicit_socket_path() -> None:
    assert klippy_stub.main([]) == 2


def test_stub_does_not_replace_existing_paths(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.chdir(tmp_path)
    occupied = Path("occupied.sock")
    occupied.write_text("keep me")
    with pytest.raises(OSError):
        klippy_stub.main([str(occupied)])
    assert occupied.read_text() == "keep me"


@pytest.mark.parametrize("invalid", [b"{", b"\xff", b"[]", b"null", b"1"])
def test_stub_keeps_connection_after_invalid_frames(invalid: bytes) -> None:
    server, client = socket.socketpair()
    with server, client:
        client.settimeout(1)
        worker = threading.Thread(target=klippy_stub.serve_conn, args=(server,))
        worker.start()
        try:
            client.sendall(invalid + b'\x03{"id":1,"method":"objects/list"}\x03')
            response = bytearray()
            while b"\x03" not in response and len(response) < 1024:
                data = client.recv(1024)
                assert data
                response.extend(data)
            assert json.loads(response.split(b"\x03")[0]) == {
                "id": 1,
                "result": {"objects": klippy_stub.OBJECTS},
            }
        finally:
            client.shutdown(socket.SHUT_WR)
            worker.join(timeout=1)
        assert not worker.is_alive()

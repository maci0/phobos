import io
import json
import socket
import threading
from pathlib import Path

import pytest

from tools.perf_harness import klippy_stub, report


def test_report_formats_observed_metrics(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    data = {
        "throughput": 12,
        "success": 0.5,
        "latencies": {"50": 1_000_000, "99": 2_000_000},
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

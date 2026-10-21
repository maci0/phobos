import copy
import json
from pathlib import Path

import pytest

from tools.perf_harness import plot_perf


def measured_trial(backend: str) -> dict[str, object]:
    return {
        "backend": backend,
        "workload": "info-5000",
        "repetition": 1,
        "requested_rate": 5000,
        "duration_seconds": 10,
        "vegeta": {
            "throughput": 4999,
            "success": 1,
            "latencies": {"50th": 50000, "99th": 100000},
        },
        "process": {"cpu_percent_one_core": 20, "rss_kib_max": 4096},
    }


def write_trials(tmp_path: Path, values: object) -> Path:
    path = tmp_path / "summary.json"
    path.write_text(json.dumps(values))
    return path


def test_plot_reads_observed_values_and_converts_units(tmp_path: Path) -> None:
    path = write_trials(
        tmp_path, [measured_trial("phobos"), measured_trial("moonraker")]
    )
    rows = plot_perf.load_trials(path)
    assert rows[0].throughput == 4999
    assert rows[0].p99_ms == 0.1
    assert rows[0].rss_mib == 4


def test_plot_rejects_missing_measurements(tmp_path: Path) -> None:
    values = [measured_trial("phobos"), measured_trial("moonraker")]
    values[0]["vegeta"] = {}
    with pytest.raises(ValueError, match="missing measurement"):
        plot_perf.load_trials(write_trials(tmp_path, values))


@pytest.mark.parametrize(
    "key,value", [("duration_seconds", 11), ("requested_rate", 1000), ("repetition", 2)]
)
def test_plot_rejects_unmatched_trials(tmp_path: Path, key: str, value: int) -> None:
    values = [measured_trial("phobos"), measured_trial("moonraker")]
    values[1][key] = value
    with pytest.raises(ValueError, match="unmatched"):
        plot_perf.load_trials(write_trials(tmp_path, values))


def test_plot_rejects_duplicate_or_absent_comparators(tmp_path: Path) -> None:
    first = measured_trial("phobos")
    for values in ([first], [first, copy.deepcopy(first), measured_trial("moonraker")]):
        with pytest.raises(ValueError):
            plot_perf.load_trials(write_trials(tmp_path, values))


@pytest.mark.parametrize("value", [True, -1, float("nan"), float("inf"), "100"])
def test_plot_rejects_invalid_numeric_measurements(value: object) -> None:
    with pytest.raises((TypeError, ValueError)):
        plot_perf.number({"metric": value}, "metric")


def test_plot_renders_only_explicit_capture_outputs(tmp_path: Path) -> None:
    pytest.importorskip("matplotlib")
    path = write_trials(
        tmp_path, [measured_trial("phobos"), measured_trial("moonraker")]
    )
    for backend in plot_perf.BACKENDS:
        directory = tmp_path / backend
        directory.mkdir()
        (directory / "idle.json").write_text(
            json.dumps({"rss_kib_median": 2048, "cpu_percent_one_core": 0})
        )
    output = tmp_path / "plots"
    plot_perf.render(path, output, "fixture")
    assert {item.name for item in output.iterdir()} == {
        "throughput.png",
        "latency.png",
        "memory.png",
        "cpu.png",
        "plot-inputs.json",
    }
    assert all(
        (output / f"{name}.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        for name in ("throughput", "latency", "memory", "cpu")
    )
    assert set(json.loads((output / "plot-inputs.json").read_text())) == {
        "summary.json",
        "phobos/idle.json",
        "moonraker/idle.json",
    }

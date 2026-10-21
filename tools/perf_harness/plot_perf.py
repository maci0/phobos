# /// script
# dependencies = ["matplotlib"]
# ///
"""Plot matched trials from measured Vegeta and process samples."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path

BACKENDS = ("phobos", "moonraker")
COLORS = ("#2563eb", "#dc2626")


@dataclass(frozen=True)
class Trial:
    backend: str
    workload: str
    repetition: int
    requested_rate: float
    duration_seconds: float
    throughput: float
    success: float
    p99_ms: float
    cpu_percent: float
    rss_mib: float


def field(value: object, key: str) -> object:
    if not isinstance(value, dict) or key not in value:
        raise ValueError(f"missing measurement: {key}")
    return value[key]


def number(value: object, key: str) -> float:
    item = field(value, key)
    if isinstance(item, bool) or not isinstance(item, (int, float)):
        raise TypeError(f"measurement must be numeric: {key}")
    result = float(item)
    if not math.isfinite(result) or result < 0:
        raise ValueError(f"measurement must be finite and nonnegative: {key}")
    return result


def text(value: object, key: str) -> str:
    item = field(value, key)
    if not isinstance(item, str) or not item:
        raise ValueError(f"measurement must be a nonempty string: {key}")
    return item


def load_trials(path: Path) -> list[Trial]:
    values = json.loads(path.read_text())
    if not isinstance(values, list) or not values:
        raise ValueError("summary must contain measured trials")
    trials = []
    for value in values:
        report = field(value, "vegeta")
        latencies = field(report, "latencies")
        process = field(value, "process")
        repetition = number(value, "repetition")
        duration = number(value, "duration_seconds")
        success = number(report, "success")
        if (
            repetition != int(repetition)
            or repetition < 1
            or duration == 0
            or success > 1
        ):
            raise ValueError("invalid repetition, duration or success fraction")
        trials.append(
            Trial(
                backend=text(value, "backend"),
                workload=text(value, "workload"),
                repetition=int(repetition),
                requested_rate=number(value, "requested_rate"),
                duration_seconds=duration,
                throughput=number(report, "throughput"),
                success=success,
                p99_ms=number(latencies, "99th") / 1e6,
                cpu_percent=number(process, "cpu_percent_one_core"),
                rss_mib=number(process, "rss_kib_max") / 1024,
            )
        )
    if {trial.backend for trial in trials} != set(BACKENDS):
        raise ValueError("both phobos and moonraker measurements are required")
    seen: set[tuple[str, str, int]] = set()
    for trial in trials:
        key = (trial.backend, trial.workload, trial.repetition)
        if key in seen:
            raise ValueError("duplicate measured trial")
        seen.add(key)
    for workload in {trial.workload for trial in trials}:
        rows = [trial for trial in trials if trial.workload == workload]
        if len({(trial.requested_rate, trial.duration_seconds) for trial in rows}) != 1:
            raise ValueError(f"unmatched rate or duration: {workload}")
        repetitions = [
            {trial.repetition for trial in rows if trial.backend == backend}
            for backend in BACKENDS
        ]
        if not repetitions[0] or repetitions[0] != repetitions[1]:
            raise ValueError(f"unmatched repetitions: {workload}")
    return trials


def render(input_path: Path, output: Path, title: str) -> None:
    trials = load_trials(input_path)
    idle_paths = [input_path.parent / backend / "idle.json" for backend in BACKENDS]
    idle_values = [json.loads(path.read_text()) for path in idle_paths]
    idle_rss = [number(value, "rss_kib_median") / 1024 for value in idle_values]
    idle_cpu = [number(value, "cpu_percent_one_core") for value in idle_values]

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    output.mkdir(parents=True, exist_ok=True)
    workloads = sorted({trial.workload for trial in trials})
    counts = sorted(
        {
            sum(
                trial.backend == "phobos" and trial.workload == workload
                for trial in trials
            )
            for workload in workloads
        }
    )
    repetitions = "/".join(str(count) for count in counts)
    success = min(trial.success for trial in trials)
    footer = f"Median of {repetitions} trials; bars show trial min/max. Minimum request success: {success:.2%}."
    specs = (
        (
            "throughput",
            "throughput",
            "Successful requests / second",
            "Throughput",
            None,
        ),
        ("latency", "p99_ms", "p99 latency (ms)", "Tail latency", None),
        ("memory", "rss_mib", "Resident memory (MiB)", "Process RSS", idle_rss),
        (
            "cpu",
            "cpu_percent",
            "Process CPU (100% = one core)",
            "Process CPU",
            idle_cpu,
        ),
    )
    for filename, attribute, ylabel, heading, idle in specs:
        labels = (["idle"] if idle is not None else []) + workloads
        fig, ax = plt.subplots(figsize=(11, 5.5))
        for index, (backend, color) in enumerate(zip(BACKENDS, COLORS, strict=True)):
            medians, lower, upper = [], [], []
            if idle is not None:
                medians.append(idle[index])
                lower.append(0)
                upper.append(0)
            for workload in workloads:
                values = [
                    getattr(trial, attribute)
                    for trial in trials
                    if trial.backend == backend and trial.workload == workload
                ]
                median = statistics.median(values)
                medians.append(median)
                lower.append(median - min(values))
                upper.append(max(values) - median)
            xs = [position + (index - 0.5) * 0.38 for position in range(len(labels))]
            ax.bar(
                xs,
                medians,
                width=0.38,
                color=color,
                label="Moonraker" if backend == "moonraker" else backend,
                yerr=[lower, upper],
                capsize=3,
            )
        ax.set_xticks(
            range(len(labels)),
            [label.replace("-", "\n", 1) for label in labels],
            fontsize=9,
        )
        ax.set_ylabel(ylabel)
        ax.set_title(f"{heading}: {title}")
        ax.spines[["top", "right"]].set_visible(False)
        ax.set_axisbelow(True)
        ax.grid(axis="y", alpha=0.25)
        ax.legend(frameon=False)
        fig.text(
            0.5,
            0.015,
            footer + (" Idle uses each recorded baseline." if idle is not None else ""),
            ha="center",
            fontsize=8,
        )
        fig.tight_layout(rect=(0, 0.045, 1, 1))
        fig.savefig(output / f"{filename}.png", dpi=150)
        plt.close(fig)
    inputs = [input_path, *idle_paths]
    manifest = {
        path.relative_to(input_path.parent).as_posix(): hashlib.sha256(
            path.read_bytes()
        ).hexdigest()
        for path in inputs
    }
    (output / "plot-inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        required=True,
        help="measured summary.json with Vegeta and process metrics",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--title", default="host loopback, Klippy stub")
    args = parser.parse_args()
    render(args.input, args.output_dir, args.title)


if __name__ == "__main__":
    main()

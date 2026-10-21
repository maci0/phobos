"""Format one vegeta JSON report from stdin."""

import json
import sys


def main() -> None:
    report = json.load(sys.stdin)
    latency = report["latencies"]
    print(
        f"thru={report['throughput']:.0f} succ={report['success'] * 100:.1f}% "
        f"p50={latency['50th'] / 1e6:.2f}ms p99={latency['99th'] / 1e6:.2f}ms"
    )


if __name__ == "__main__":
    main()

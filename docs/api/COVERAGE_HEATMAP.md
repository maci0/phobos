# API coverage and verification limits

The [per-call API table](API_COVERAGE.md) is generated from the Moonraker baseline,
the current phobos API dump, and reviewed deltas in `tools/api_scanner/table.py`.
It distinguishes registered methods from behavior that is partial or missing.

Run `tools/coverage.sh` for endpoint, JSON-RPC method, notification and router name
coverage. A passing gate proves registration, including names whose implementation
is partial. It does not prove response fidelity, notification timing, hardware
control or safety under load.

The previous heatmap used hand-assigned depth scores. Those scores and their
weighted total were not measured implementation coverage and are no longer used.
The historical image and renderer remain available for reproducing old reports
from a matching historical table. They are not a status source for the current
checkout; this document no longer supplies depth scores to the renderer.

Use [TODO.md](../../TODO.md) for specific remaining differences,
[PROVENANCE.md](../PROVENANCE.md) for verified changes and commands, and
[MEMORY.md](../MEMORY.md) and [PERFORMANCE.md](../PERFORMANCE.md) for historical
measurements and their limits. Physical drivers and the real Klippy bridge need
separate checks on their target hardware; local doubles cannot prove those paths.

# Change and verification ledger

Append dated entries. Record the request, change, source evidence, verification
and unperformed checks. Corrections are new entries; do not rewrite an earlier
result as if it had been measured differently.

## 2026-10-20: source review and documentation reconciliation

Requested by the user: finish the whole-codebase review and the unfinished
implementation and documentation work. The source at `2ab11b8` contains 69
commits after released `db010e3` (`git rev-list --count db010e3..2ab11b8`).
That range includes native I/O and ownership changes; its commit log records
the individual changes. This entry does not retrospectively certify every
earlier verification claim.

The documentation now separates API-name registration from behavior, removes
unmeasured implementation-completeness grades and stale server-spine plans,
keeps the newer per-call deltas, and identifies historical measurements and
their limits. Source evidence: `src/main.zig`, `src/oracle/replay.zig`,
`conformance/replay.py`, `tools/api_scanner/table.py`,
`src/components/{analysis,extensions,file_manager,mqtt}.zig`, and Moonraker
`900848584374`. The deleted Zig normalizer stays deleted; the Python replay
manifest remains the normalization implementation. Client scanner prose no
longer claims to have tested missing-plugin fallback behavior.

Verification on the `2ab11b8` source with the documentation candidate:

- `zig build test-artifact -Doptimize=Debug`, then the newly built standalone
  artifact with `--cache-dir=./.zig-cache`: 1283 passed, 1 skipped, 0 failed;
  226 fuzz tests. The skipped case requires a real Klippy socket.
- `zig build -Doptimize=Debug`: native daemon built.
- `phobos --dump-api`, followed by `api_scanner coverage` against
  `api/api_surface.json`: endpoints 123/123, methods 130/130 and notifications
  27/27. Reviewed prose changes in the API table generator were regenerated;
  no delta classifications changed.
- Both scanner test directories, run with pytest, tree-sitter and the Python,
  TypeScript and C++ grammars: 78 passed. Regenerating the client matrix from
  checked-in inputs reports 9 known unregistered method names and exits 1 as
  designed. The matrix rows did not change.
- `git diff --check`: clean.

No physical printer, live database, service deployment, privileged profiling,
fresh memory measurement or external update source was used for this entry.
Further implementation commits need their own verification entries.

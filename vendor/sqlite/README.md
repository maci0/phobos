# SQLite amalgamation

The build compiles these upstream SQLite 3.54.1 sources into the static binary.
They are required in a fresh checkout. Moonraker's reference checkout is separate
and is not a build dependency.

Upstream source ID:
`2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76`.
Local patches: none. Build defines are listed in `build.zig:addVendoredSqlite`.

Source: [official amalgamation archive](https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip),
the latest stable version listed on the [download page](https://www.sqlite.org/download.html)
when checked on 2026-10-21. Its SHA3-256 is
`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`.
The amalgamation's SHA3-256 also matches the
[release history](https://www.sqlite.org/changes.html):
`e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81`.

SHA-256:

```text
0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52  vendor/sqlite/sqlite3.c
d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c  vendor/sqlite/sqlite3.h
```

Both files retain the upstream copyright disclaimer and blessing. The header's
opening notice disclaims copyright; the amalgamation retains the same notices
for its constituent files.

CI verifies the tracked `SHA256SUMS` before building. Recheck it locally with
`cd vendor/sqlite && sha256sum --check SHA256SUMS`.

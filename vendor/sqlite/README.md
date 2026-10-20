# SQLite amalgamation

The build compiles these upstream SQLite 3.47.0 sources into the static binary.
They are required in a fresh checkout. Moonraker's reference checkout is separate
and is not a build dependency.

Upstream source ID:
`2024-10-21 16:30:22 03a9703e27c44437c39363d0baf82db4ebc94538a0f28411c85dda156f82636e`.
Local patches: none. Build defines are listed in `build.zig:addVendoredSqlite`.

SHA-256:

```text
0a830d5ab8a0a24be25b795869b8986231be90102bcb9b164da4f02d6958a2f7  vendor/sqlite/sqlite3.c
9bcec02d51f4328941ba24b8fac7afcf78e4f0ff2148cfc1a63329fca9d0b766  vendor/sqlite/sqlite3.h
```

Both files retain the upstream copyright disclaimer and blessing. The header's
opening notice disclaims copyright; the amalgamation retains the same notices
for its constituent files.

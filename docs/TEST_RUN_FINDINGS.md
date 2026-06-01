# Moonraker Test-Run Findings

Vendored commit: `9008485` ("build: bump pillow to 12.2.0").
Host: Python 3.14 system / tests executed under uv-provisioned CPython 3.12.12.
Date: 2026-06-01.

## TL;DR

The upstream Moonraker test suite **does not run out of the box and is not a usable
parity oracle as-is.** Of **473 collected tests: 1 passed, 6 failed, 466 errored**
(all at fixture setup). The suite is not wired into CI and has bit-rotted against
the current source layout and its own pinned dependencies.

## How tests are (not) run in CI

`.github/workflows/test_code.yaml` is the only workflow. It runs **flake8 + mypy
only** (`weibullguy/python-lint-plus`). **`pytest` is never invoked in CI.** Nothing
guards the test suite against rot, which explains everything below.

## What it took to even collect the tests

`pytest.ini` declares `pythonpath = moonraker scripts` and depends on an editable
install. On a fresh checkout this is broken in several independent ways:

1. **Package-shadow.** `pythonpath = moonraker` puts the inner package dir first on
   `sys.path`, so `import moonraker` resolves to `moonraker/moonraker.py` (a module)
   instead of the `moonraker/` package → `'moonraker' is not a package`.
2. **Mixed legacy/new imports in the same files.** Test modules mix
   `import confighelper` / `from utils import ServerError` (legacy top-level layout)
   with `from moonraker.confighelper import ConfigError` (current package layout).
   The bare modules use relative imports internally (`from .utils import ...`), so
   they only resolve when bound as package submodules — the two import styles are
   mutually exclusive under any single `sys.path` ordering.
3. **Moved module.** `tests/test_klippy_connection.py` imports
   `from moonraker.klippy_connection import KlippyRequest`, but the module now lives
   at `moonraker.components.klippy_connection`.
4. **Missing test deps.** `lmdb` (used by `scripts/dbtool.py`) and the pytest plugins
   (`pytest-asyncio`, `pytest-timeout`) are not in any dependency group, only named
   in `required_plugins`.

### Workaround applied (documented, non-invasive)

Added `vendor/moonraker/conftest.py` (clearly marked **PHOBOS VENDOR PATCH**, not
upstream) that aliases the legacy bare names to package submodules:

- `confighelper` → `moonraker.confighelper`
- `utils` → `moonraker.utils`
- `moonraker.klippy_connection` → `moonraker.components.klippy_connection`

Run command that collects all 473 tests:

```
cd vendor/moonraker
uv run --with pytest --with 'pytest-asyncio==0.21.2' --with 'pytest-timeout>=2.1.0' \
  --with lmdb pytest -o "pythonpath=scripts tests"
```

No source logic is modified. Delete `conftest.py` to reproduce the broken state.

## Why 466/473 still error: source/test semantic drift

Even after collection succeeds, nearly every test errors at **fixture setup** with:

```
RuntimeError: no running event loop
  moonraker/eventloop.py:52 in reset
    self.aioloop = asyncio.get_running_loop()
  tests/conftest.py:198 in base_server
    evtloop = EventLoop()
```

Root cause is a genuine incompatibility, not just a dependency pin:

- `tests/conftest.py` builds the server from a **synchronous, class-scoped**
  `base_server` fixture that constructs `EventLoop()` outside any running loop, and
  relies on a custom `event_loop` fixture (the pre-0.23 pytest-asyncio pattern).
- Current source `EventLoop.reset()` calls `asyncio.get_running_loop()`, which
  **requires** an already-running loop. When the suite was written, this almost
  certainly used `asyncio.get_event_loop()` (returns/creates a loop even when none is
  running). The source moved on; the fixtures did not.
- Pinning `pytest-asyncio==0.21.2` (honors the custom `event_loop` fixture) does not
  help, because the sync fixture still constructs `EventLoop` with no loop *running*.

Making these pass would require rewriting `conftest.py` to construct the server inside
a running loop. **Deliberately not done** — this is a faithful-behavior study; we do
not want to perturb source or fabricate green by changing test semantics.

### Error signature breakdown (full-suite run)

| Signature | Count |
|---|---|
| `RuntimeError: no running event loop` (fixture setup) | 460 |
| `TypeError: argument should be a str or os.PathLike ...` | ~16 |
| `AttributeError` | 8 |
| `AssertionError` (real assertion reached) | 5 |
| reported `FAILED` | 6 |
| **passed** | **1** |

The single pass + the 5 `AssertionError`s are the only tests that get far enough to
exercise real assertions; everything else dies before the test body runs.

## Per-file result

| Test file | Tests | Result |
|---|---|---|
| `test_config.py` | 79 | 1 passed, 1 failed, 77 error |
| `test_database.py` | 310 | 310 error |
| `test_klippy_connection.py` | 24 | 24 error |
| `test_server.py` | 60 | 5 failed, 55 error |

## Implications for phobos (the Zig reimplementation)

1. **The upstream suite cannot be the parity oracle.** It is abandoned, unguarded by
   CI, and incompatible with its own current source. We cannot "make the Python tests
   pass against Zig."
2. **Parity must be established empirically.** Build a black-box conformance suite
   that drives a *running* stock Moonraker (golden capture) and replays the same
   HTTP/WebSocket/JSON-RPC requests against phobos, asserting byte/JSON-equal
   responses and identical notification streams. The existing `tests/fixtures`
   (`KlippyProcess`, `HttpClient`, `WebsocketClient`) and `tests/assets` configs are
   reusable scaffolding for that capture harness.
3. **The real spec is the code + `docs/`, not the tests.** See
   [`api/API_SURFACE.md`](api/API_SURFACE.md) (full endpoint/JSON-RPC/notification
   inventory) and [`TEST_COVERAGE.md`](TEST_COVERAGE.md) (what is nominally tested vs
   the large untested surface).

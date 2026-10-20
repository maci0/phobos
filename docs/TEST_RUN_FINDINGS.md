# Moonraker test-run findings

Vendored commit: `9008485` ("build: bump pillow to 12.2.0").
Host: system Python 3.14; tests ran under uv-provisioned CPython 3.12.12.
Date: 2026-06-01.

## Result

The upstream Moonraker test suite does not run out of the box and cannot serve
as a parity oracle. Of 473 collected tests, 1 passed, 6 failed and 466 errored,
all at fixture setup. CI does not run the suite, and it no longer matches the
current source layout or its own pinned dependencies.

## CI

`.github/workflows/test_code.yaml` is the only workflow. It runs flake8 and mypy
(`weibullguy/python-lint-plus`) and never invokes `pytest`, so nothing catches
test-suite breakage.

## Collecting the tests

`pytest.ini` declares `pythonpath = moonraker scripts` and assumes an editable
install. A fresh checkout breaks in four independent ways:

1. **Package shadowing.** `pythonpath = moonraker` puts the inner package
   directory first on `sys.path`, so `import moonraker` resolves to the module
   `moonraker/moonraker.py` instead of the `moonraker/` package and fails with
   `'moonraker' is not a package`.
2. **Mixed import layouts in one file.** Test modules mix legacy top-level
   imports (`import confighelper`, `from utils import ServerError`) with package
   imports (`from moonraker.confighelper import ConfigError`). The bare modules
   use relative imports (`from .utils import ...`) and resolve only as package
   submodules, so no single `sys.path` order satisfies both styles.
3. **Moved module.** `tests/test_klippy_connection.py` imports
   `from moonraker.klippy_connection import KlippyRequest`; the module now lives
   at `moonraker.components.klippy_connection`.
4. **Missing test dependencies.** `pytest-asyncio` and `pytest-timeout` appear
   only in `required_plugins`, not in any dependency group.

### Local patch

`vendor/moonraker/conftest.py` (marked `PHOBOS VENDOR PATCH`, not upstream)
aliases the legacy bare names to package submodules:

- `confighelper` → `moonraker.confighelper`
- `utils` → `moonraker.utils`
- `moonraker.klippy_connection` → `moonraker.components.klippy_connection`

It changes no source logic. `vendor/` is gitignored, so the patch exists only in
a local checkout; delete it to reproduce the broken state. This command
collects all 473 tests:

```
cd vendor/moonraker
uv run --with pytest --with 'pytest-asyncio==0.21.2' --with 'pytest-timeout>=2.1.0' \
  pytest -o "pythonpath=scripts tests"
```

## Why 466 tests still error

After collection, nearly every test fails at fixture setup:

```
RuntimeError: no running event loop
  moonraker/eventloop.py:52 in reset
    self.aioloop = asyncio.get_running_loop()
  tests/conftest.py:198 in base_server
    evtloop = EventLoop()
```

The fixtures and the source disagree:

- `tests/conftest.py` builds the server in a synchronous, class-scoped
  `base_server` fixture that constructs `EventLoop()` outside a running loop,
  and supplies a custom `event_loop` fixture (the pytest-asyncio pattern before
  0.23).
- `EventLoop.reset()` calls `asyncio.get_running_loop()`, which requires a
  running loop. The fixtures were not updated when the source changed.
- Pinning `pytest-asyncio==0.21.2`, which honors the custom `event_loop`
  fixture, does not help: the synchronous fixture still has no running loop.

Passing tests would need `conftest.py` rewritten to construct the server inside
a running loop. That was deliberately not done, so the run reflects upstream
behavior without changed test semantics.

### Error signatures (full-suite run)

| Signature | Count |
|---|---|
| `RuntimeError: no running event loop` (fixture setup) | 460 |
| `TypeError: argument should be a str or os.PathLike ...` | ~16 |
| `AttributeError` | 8 |
| `AssertionError` (real assertion reached) | 5 |
| reported `FAILED` | 6 |
| passed | 1 |

Only the one pass and the five `AssertionError`s reach a test body.

## Per-file result

| Test file | Tests | Result |
|---|---|---|
| `test_config.py` | 79 | 1 passed, 1 failed, 77 error |
| `test_database.py` | 310 | 310 error |
| `test_klippy_connection.py` | 24 | 24 error |
| `test_server.py` | 60 | 5 failed, 55 error |

## Consequences for phobos

1. The upstream suite cannot be the parity oracle: CI does not run it and it is
   incompatible with its own source.
2. Parity comes from a black-box oracle instead. `conformance/capture.py` drives
   a running stock Moonraker and records golden responses and notification
   streams; `conformance/replay.py` replays them against phobos and asserts
   normalized equality using the manifest in `conformance/replay.py`.
3. The API contract is the Moonraker source plus
   [`api/API_SURFACE.md`](api/API_SURFACE.md) (endpoint, JSON-RPC and
   notification inventory). [`TEST_COVERAGE.md`](TEST_COVERAGE.md) maps what
   upstream nominally tests.

# Moonraker test coverage map

Source root: `vendor/moonraker/moonraker/`
Test root: `vendor/moonraker/tests/`

Line counts are `wc -l` at vendored commit `9008485`.

## Status

- The upstream suite collects 473 tests across 4 files (`test_config.py`,
  `test_database.py`, `test_klippy_connection.py`, `test_server.py`).
- CI does not run it: `.github/workflows/test_code.yaml` runs only flake8 and mypy.
- 1 test passes and ~466 error at fixture setup, because `conftest.py`'s
  `event_loop` fixture and `EventLoop` usage no longer match the asyncio API the
  source calls. See [`TEST_RUN_FINDINGS.md`](TEST_RUN_FINDINGS.md).
- The failed run does not measure behavioral coverage. The tables record what
  the suite nominally targets, not what runs green.

## Classification

- **Direct**: a test file imports the module and references its symbols.
- **Indirect**: no test imports the module, but a test server instantiates it,
  either because it is in `CORE_COMPONENTS` (`moonraker/server.py:61`) or
  because `assets/moonraker/base_server.conf` declares its section (`[database]
  [machine] [file_manager] [secrets]`). It runs only through construction,
  `component_init` and `close`, with no behavioral assertions.
- **Untested**: no test loads or references it.

`CORE_COMPONENTS` (always loaded by `load_components()`):
`dbus_manager, database, file_manager, authorization, klippy_apis, machine, data_store,
shell_command, proc_stats, job_state, job_queue, history, http_client, announcements,
webcam, extensions`.

---

## Top-level modules (`moonraker/`)

| Module | LOC | Tested? | By which test | Notes |
|---|---|---|---|---|
| `server.py` | 735 | Direct | test_server, test_config, test_database, test_klippy_connection | Core target of test_server: instantiation, `load_component`/`lookup_component`, `CORE_COMPONENTS`, `API_VERSION`, event registration/dispatch, remote methods, `main`, config backup/restore. Imported everywhere. |
| `confighelper.py` | 1126 | Direct | test_config, test_server | `ConfigError`, `ConfigHelper` getters (str/int/float/bool/list/dict/template/gpio), deprecation warnings, supplemental config, backup config. Heaviest unit coverage in the suite. |
| `common.py` | 1299 | Indirect | (via server) | Loaded transitively (RequestType, WebRequest, JsonRPC, BaseRemoteConnection, etc.). No direct assertions. |
| `eventloop.py` | 222 | Direct | test_server, conftest | Imported by conftest `event_loop` fixture and test_server; the API drift here is what breaks the suite. |
| `loghelper.py` | 214 | Indirect | (via server `main`/`LogManager`) | `LogManager` constructed in conftest server bootstrap; test_server `test_file_logger`. |
| `moonraker.py` | 17 | Untested |  | Thin entry shim. |
| `__main__.py` | 9 | Untested |  | Entry shim. |
| `__init__.py` | 5 | Untested |  |  |
| `__version__.py` | 1 | Untested |  |  |

### `moonraker/utils/` subpackage

| Module | LOC | Tested? | By which test | Notes |
|---|---|---|---|---|
| `utils/__init__.py` | 277 | Direct | all 4 tests import `ServerError` / `utils` | `ServerError` is referenced widely; broader util fns only indirectly. |
| `utils/exceptions.py` | 18 | Indirect | (via utils) | `ServerError` lives here / re-exported. |
| `utils/source_info.py` | 193 | Indirect | (via server init) |  |
| `utils/json_wrapper.py` | 33 | Indirect | (via server/db) |  |
| `utils/async_serial.py` | 157 | Untested |  | Serial transport (paneldue/td1). |
| `utils/cansocket.py` | 198 | Untested |  | CAN bus. |
| `utils/filelock.py` | 111 | Untested |  |  |
| `utils/ioctl_macros.py` | 77 | Untested |  |  |
| `utils/pip_utils.py` | 309 | Untested |  | Used by update_manager python_deploy. |
| `utils/sysdeps_parser.py` | 185 | Untested |  | Used by update_manager/machine. |
| `utils/sysfs_devs.py` | 467 | Untested |  |  |
| `utils/versions.py` | 420 | Untested |  | Git/version parsing for update_manager. |

---

## Components (`moonraker/components/`)

| Component | LOC | Tested? | By which test | Notes |
|---|---|---|---|---|
| `database.py` | 1743 | **Direct** | test_database | Most thorough behavioral suite: insert/get/update/delete/batch, nested keys, namespaces, threaded variants, encode/decode errors, drop. `MoonrakerDatabase` exercised heavily (also configured in base_server.conf). |
| `klippy_connection.py` | 852 | **Direct** | test_klippy_connection, test_server | `KlippyRequest`, connect/reconnect/shutdown, UDS access errors, read/write errors+cancel, process unknown/invalid request, remote method call, missing requirements. Strong nominal coverage. |
| `klippy_apis.py` | 302 | Direct | test_server, test_klippy_connection | `KlippyAPI` imported directly; used via `klippy_connection.klippy_apis` for status updates. |
| `gpio.py` | 275 | Direct | test_config | Imported directly; gpio-out config parsing tested against `MockGpiod`. |
| `websockets.py` | 498 | Direct | test_server | `lookup_component("websockets")`, endpoint registration check, websocket server.info/server.config requests via WebsocketClient fixture. |
| `application.py` | 1185 | Direct (lookup) | test_server | `lookup_component("application")`, http/ssl server presence, endpoint registration (`/server/info`, `/server/config`). Not in CORE list but loaded as the HTTP app. |
| `authorization.py` | 941 | Indirect | (CORE) | Loaded as core; no auth behavior asserted. |
| `machine.py` | 2172 | Indirect | (CORE + configured) | Loaded; no behavior asserted. |
| `file_manager/file_manager.py` | 2649 | Indirect | (CORE + configured) | Loaded; **no file ops, upload, metadata, or roots tested**. |
| `file_manager/metadata.py` | 1467 | Untested |  | Slicer metadata parser, never invoked by tests. |
| `secrets.py` | 90 | Indirect | (configured) | `[secrets]` in base_server.conf; assets `secrets.ini`/`secrets.json` present but no assertions. |
| `data_store.py` | 174 | Indirect | (CORE) |  |
| `shell_command.py` | 440 | Indirect | (CORE) |  |
| `proc_stats.py` | 418 | Indirect | (CORE) |  |
| `job_state.py` | 135 | Indirect | (CORE) |  |
| `job_queue.py` | 357 | Indirect | (CORE) | Loaded; queue behavior untested. |
| `history.py` | 654 | Indirect | (CORE) | Loaded; job history logic untested. |
| `http_client.py` | 531 | Indirect | (CORE) | Loaded; the test `HttpClient` fixture is a separate tornado client, not this component. |
| `announcements.py` | 556 | Indirect | (CORE) |  |
| `webcam.py` | 466 | Indirect | (CORE) |  |
| `extensions.py` | 257 | Indirect | (CORE) |  |
| `dbus_manager.py` | 150 | Indirect | (CORE) |  |
| `analysis.py` | 546 | Untested |  |  |
| `button.py` | 125 | Untested |  |  |
| `ldap.py` | 147 | Untested |  | Non-goal: phobos does not implement the LDAP auth source. |
| `mqtt.py` | 883 | Untested |  | Entire MQTT transport untested. |
| `notifier.py` | 217 | Untested |  |  |
| `octoprint_compat.py` | 413 | Untested |  | OctoPrint API shim. |
| `paneldue.py` | 742 | Untested |  |  |
| `power.py` | 1693 | Untested |  | Large device-control surface, untested. |
| `sensor.py` | 345 | Untested |  |  |
| `simplyprint.py` | 1671 | Untested |  |  |
| `spoolman.py` | 427 | Untested |  |  |
| `td1.py` | 309 | Untested |  |  |
| `template.py` | 113 | Untested* |  | Jinja templates exercised indirectly through confighelper `get_template` tests, but the component file itself isn't loaded by tests. |
| `wled.py` | 635 | Untested |  |  |
| `zeroconf.py` | 420 | Untested |  |  |

### `update_manager/` subpackage (all untested)

| Module | LOC | Tested? | Notes |
|---|---|---|---|
| `update_manager/update_manager.py` | 756 | Untested |  |
| `update_manager/git_deploy.py` | 1307 | Untested |  |
| `update_manager/system_deploy.py` | 558 | Untested |  |
| `update_manager/net_deploy.py` | 502 | Untested |  |
| `update_manager/app_deploy.py` | 470 | Untested |  |
| `update_manager/python_deploy.py` | 437 | Untested |  |
| `update_manager/base_deploy.py` | 119 | Untested |  |
| `update_manager/common.py` | 113 | Untested |  |

---

## Per-test-file summary

### `test_config.py` (496 LOC, 79 tests)
Targets `confighelper.ConfigHelper` and `confighelper.ConfigError`. Exercises:
- Generic accessors: section lookup, `get_name`, `has_option`, `__contains__`, get_hash.
- Typed getters with full pass/fail/default/min-max/deprecation matrices:
  string, int, float, boolean, list, int-list, float-list, multi-list, dict.
- Template getters (`get_template`, async render, render-fail, `load_template`, deprecation).
- GPIO-out parsing (`TestGetGpioOut`) against the `MockGpiod` mock: chip/invert/initial-value/invalid.
- Supplemental config loading (`supplemental.conf`, prefix sections), missing/error handling.
- `get_configuration` no-exist / no-access / no-server paths.
- Config backup: find/create/skip backup file (`.moonraker.conf.bkp`).
Directly imports `moonraker.components.gpio` and `moonraker.server.Server`.

### `test_database.py` (1461 LOC, 310 tests)
Targets `MoonrakerDatabase` (database component). Class hierarchy with threaded and
non-threaded variants (`ThreadedTest`/`BaseTest`). Exercises CRUD end-to-end:
- Instantiation/initial state, invalid namespace wrap, encode/decode errors, nonetype insert.
- Insert: record, nested, nested-invalid-assign, reduce-failure, overwrite, batch, batch-overwrite.
- Get: record, namespace (+fail/default), nested (+no-key/default), key-list, invalid key/type.
- Update: record, nested, replace-nested, replace-nested-dict, namespace/record/key fail paths.
- Delete: nested item, nested dict, record, last-nested, drop-db, fail paths.
- Core-server-loaded vs preloaded state, unallowed-method registration guard, namespace wrapping.
The fixtures include legacy lmdb assets. The pinned Moonraker source uses SQLite
and includes lmdb migration; phobos supports SQLite and its file backend.

### `test_klippy_connection.py` (260 LOC, 24 tests)
Targets `klippy_connection.KlippyConnection` + `KlippyRequest`, against a **real Klipper
subprocess** (`KlippyProcess` fixture). Exercises:
- Startup, gcode response, shutdown, reconnect, status updates (via `klippy_apis`).
- Klippy error state, missing-requirements detection.
- Connection close idempotency, init error, connect/wait-connect failure.
- UDS socket missing / no-access (`_do_connect`).
- Write paths: not-connected, write error, cancellation.
- Read paths: read error, cancellation, decode error.
- Process: unknown method, unknown request, invalid request, remote-method call.

### `test_server.py` (518 LOC, 60 tests)
Targets `server.Server` lifecycle + `application` (HTTP) + `websockets`. Exercises:
- Bad-config and config/log warning handling; unparsed config items.
- File logger, signal handler.
- `TestInstantiation`: app args, API version, pending tasks, klippy info/state/host info,
  klippy_connection presence, loaded component list, endpoint-registered check, notification dispatch.
- `TestLoadComponent`: load/lookup success+fail, defaults, failed-component set, component_attr.
- `TestCoreServer` / `TestServerInit`: http servers up, warnings, failed components,
  lookups across all core/loaded components, remote-method registration.
- `TestServerStart` / `TestSecureServerStart`: plain and SSL server start (uses generated
  `ssl_certs` fixture + `base_server_ssl.conf`).
- `TestEndpoints`: `/server/info`, `/server/config` over both HTTP (`HttpClient`) and
  WebSocket (`WebsocketClient`); server.info/server.config JSON-RPC.
- `main` entry: normal, config-error, restore-config (`.moonraker.conf.bkp`).
- Event system: register sync/async event, send sync/async event, remote method running.
- Server restart and websocket restart.

---

## Gaps: important components with no behavioral coverage

Ranked by importance for a faithful reimplementation (API surface area × client
reliance × logic complexity). "Indirect-load only" means a test server constructs
the module but asserts no behavior, so it is a conformance gap.

1. **`file_manager/file_manager.py` (2649)**: file/dir CRUD, uploads, gcode roots,
   inotify, move/copy. Central to every UI client. *Indirect-load only; zero behavior tested.*
2. **`file_manager/metadata.py` (1467)**: slicer metadata extraction (thumbnails,
   print time, filament). Output is consumed verbatim by clients. *Untested.*
3. **`update_manager/*` (4277 total)**: git/app/python/system/net deploy + orchestrator.
   Large, stateful, security-sensitive. *Untested.*
4. **`power.py` (1693)**: device power control (many backends: gpio, tasmota, shelly,
   http, mqtt, etc.). Big API surface, high client usage. *Untested.*
5. **`machine.py` (2172)**: system/service control, shutdown/reboot, sudo, provider
   detection. *Indirect-load only.*
6. **`authorization.py` (941)**: API-key/JWT/trusted-network auth, the security gate
   for every endpoint. *Indirect-load only; no auth flows tested.*
7. **`mqtt.py` (883)**: MQTT transport + bridge; whole alternative API path. *Untested.*
8. **`history.py` (654)**: job history persistence and totals. *Indirect-load only.*
9. **`job_queue.py` (357)**: print queue ordering/transitions. *Indirect-load only.*
10. **`http_client.py` (531)**: outbound HTTP used by many components; note the test
    `HttpClient` fixture is unrelated (it's a tornado test client). *Indirect-load only.*
11. **`websockets.py` (498)**: only `server.info`/`server.config` round-trips covered;
    subscription/notification/connection-management logic untested.
12. **`announcements.py` (556)**, **`webcam.py` (466)**, **`extensions.py` (257)**:
    core-loaded but behavior untested.
13. **`spoolman.py` (427)**, **`sensor.py` (345)**, **`notifier.py` (217)**,
    **`octoprint_compat.py` (413)**, **`simplyprint.py` (1671)**, **`wled.py` (635)**,
    **`zeroconf.py` (420)**, **`ldap.py` (147)**, **`paneldue.py` (742)**,
    **`td1.py` (309)**, **`analysis.py` (546)**, **`button.py` (125)**: fully untested
    optional integrations.

Nominal behavioral coverage exists only for `database`, `klippy_connection`/`klippy_apis`,
`confighelper`, `server` lifecycle, `application`/`websockets` (server.info/config only),
`gpio` parsing. Everything else is indirect-load-only or untested.

---

## Test fixtures and mocks (`tests/`)

### `tests/conftest.py` (244 lines)
- `ssl_certs` (session, autouse): generates self-signed cert/key for SSL server tests.
- `event_loop` (class): provides the asyncio loop; the cause of the mass
  fixture errors.
- `session_args` (session): copies config assets into a tmp tree, returns path map
  (`moonraker.conf`, `moonraker.log`, db path, etc.).
- `klippy_session` (session) / `klippy` (class): start a real `KlippyProcess`.
- `path_args` (class): per-class path map, honors `@pytest.mark.run_paths(...)`.
- `base_server` (class): constructs a `Server` without loading components.
- `full_server` (class): `base_server` + `load_components()`.
- `ready_server` (class): `full_server` + connected `klippy`.
- `http_client` / `websocket_client` (async): provide the client fixtures below.
- Also `core_server` (in test_server) loads only CORE_COMPONENTS.

### `tests/fixtures/`
- `klippy_process.py`, **`KlippyProcess`**: launches a real Klipper instance against
  `assets/klipper/*.cfg` + `klipper.dict`; `start/stop/restart/send_gcode/get_paths`.
  Requires a Klipper checkout/venv to run.
- `http_client.py`, **`HttpClient`**: tornado `AsyncHTTPClient` wrapper with
  `get/post/delete/_do_request`, captures response headers. (Test client, not the
  `http_client` component.)
- `websocket_client.py`, **`WebsocketClient`**: JSON-RPC-over-WS client;
  `connect(token)`, `request(method, params)`, notify-callback registration,
  `WebsocketError` decoding. Used for the `server.info`/`server.config` WS tests.

### `tests/mocks/`
- `mock_gpio.py`, **`MockGpiod`** + `MockChip`/`MockLine`/`MockLineEvent`/`MockChipWrapper`:
  in-memory libgpiod replacement (request/release/set/get value, simulate line events).
  Enables `gpio`/config gpio-out tests without hardware.

### `tests/assets/`
- `klipper/`: `base_printer.cfg`, `error_printer.cfg`, `missing_reqs.cfg`, `klipper.dict`.
- `moonraker/`: `base_server.conf`, `base_server_ssl.conf`, `invalid_config.conf`,
  `unparsed_server.conf`, `supplemental.conf`, `secrets.ini`, `secrets.json`,
  plus the lmdb store assets (`data.mdb`, `lock.mdb`, `bare_db.cdb`).

---

## Totals

Counts of the module rows in the tables above. The tables omit the
package `__init__.py` files of `components/`, `file_manager/` and
`update_manager/`, so the vendored tree has 69 `.py` files and the tables list 66.

| Classification | Modules |
|---|---|
| Direct | 10: `server`, `confighelper`, `eventloop`, `utils/__init__`, `database`, `klippy_connection`, `klippy_apis`, `gpio`, `websockets`, `application` |
| Indirect | 20: the `CORE_COMPONENTS` set not directly tested, configured `secrets`, `common`, `loghelper`, and three `utils/` modules |
| Untested | 36: the whole `update_manager/` subpackage, `file_manager/metadata`, `power`, `mqtt`, and most optional integrations |

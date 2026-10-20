# phobos API Coverage

Per-call implementation status of every Moonraker API surface element, with any behavioural difference. **Auto-generated** (`python3 -m api_scanner table`) from the Moonraker baseline (`api/api_surface.json`) × phobos `--dump-api` × curated deltas. do not hand-edit; update the deltas in `tools/api_scanner/table.py`.

- Moonraker baseline: `0.10.1.dev20+g9008485` (commit `900848584374`).
- Endpoints: 125 · JSON-RPC methods: 130 · notifications: 27 · remote methods: 14.

Status: ✅ Full (matches Moonraker) · ⚠️ Partial (shape matches; behaviour differs/stubbed) · 🚫 No-op (deliberate, host-safety) · ❌ Missing.

## HTTP endpoints

| Path | Verbs | Transports | Component | Status | Notes |
|---|---|---|---|---|---|
| `/access/api_key` | GET, POST | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/info` | GET | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/login` | POST | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/logout` | POST | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/oneshot_token` | GET | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/refresh_jwt` | POST | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/user` | GET, POST, DELETE | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/user/password` | POST | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/access/users/list` | GET | HTTP, WEBSOCKET | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `/api/currentuser` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/files/moonraker/(?P<relative_path>.+)` | POST | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/job` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/login` | POST | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/printer` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/printer/command` | POST | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/printerprofiles` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/server` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/settings` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/api/version` | GET | HTTP | octoprint_compat | ✅ Full | Matches Moonraker. |
| `/connection/register_remote_method` | POST | WEBSOCKET | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `/connection/send_event` | POST | WEBSOCKET | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `/debug/database/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/debug/database/list` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/debug/database/table` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/debug/notifiers/test` | POST | HTTP, WEBSOCKET, INTERNAL | notifier | ⚠️ Partial | List records come from `[notifier <name>]`. Sending is `AppriseNotAvailable` because apprise is not linked. |
| `/machine/device_power/device` | GET, POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `/machine/device_power/devices` | GET | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `/machine/device_power/off` | POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `/machine/device_power/on` | POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `/machine/device_power/status` | GET | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `/machine/peripherals/canbus` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | Returns an empty `can_uuids` list; no SocketCAN query. |
| `/machine/peripherals/serial` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Matches Moonraker. |
| `/machine/peripherals/usb` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | No usb.ids database: class, subclass and protocol are null, and names come only from Moonraker's built-in 1d50 (Klipper, Katapult) entries. |
| `/machine/peripherals/video` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | `modes` is always [] (no format enumeration) and `libcamera_devices` is always []. |
| `/machine/proc_stats` | GET | HTTP, WEBSOCKET, INTERNAL | proc_stats | ✅ Full | Matches Moonraker. |
| `/machine/reboot` | POST | HTTP, WEBSOCKET, INTERNAL | machine | 🚫 No-op | Deliberate no-op: returns Moonraker's ok shape but never reboots the host (printer boards lack systemd; a stray call must not power-cycle the box). |
| `/machine/services/restart` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | See machine.services.start. |
| `/machine/services/start` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | Dispatches to the configured [machine] provider: systemctl (systemd_dbus/systemd_cli), supervisorctl (supervisord_cli), `<script_path>/<service>` (simple), or in-memory (none). A name outside Moonraker's allow-list returns 403 "Forbidden" (Moonraker: 400 "Service '<name>' not allowed"); an allowed but undiscovered service is not refused as "not installed". |
| `/machine/services/stop` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | See machine.services.start. |
| `/machine/shutdown` | POST | HTTP, WEBSOCKET, INTERNAL | machine | 🚫 No-op | Deliberate no-op: returns ok but never shuts the host down. |
| `/machine/sudo/info` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Matches Moonraker. |
| `/machine/sudo/password` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Matches Moonraker. |
| `/machine/system_info` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Matches Moonraker. |
| `/machine/td1/data` | GET | HTTP, WEBSOCKET, INTERNAL | td1 | ⚠️ Partial | Discovery and CSV readings work; the errors.txt and reboot handshakes are not sent, so `error` is null and reboot only forgets the device (TODO.md). |
| `/machine/td1/reboot` | POST | HTTP, WEBSOCKET, INTERNAL | td1 | ⚠️ Partial | Discovery and CSV readings work; the errors.txt and reboot handshakes are not sent, so `error` is null and reboot only forgets the device (TODO.md). |
| `/machine/update/client` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/full` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ⚠️ Partial | Runs only package steps (apt-get, pip) through an injected shell; the daemon installs none, so it is refused while the system updater is enabled. Git sources only report progress lines; web/zip installation is unimplemented. |
| `/machine/update/klipper` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/moonraker` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/recover` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/refresh` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/rollback` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/status` | GET | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/update/system` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ⚠️ Partial | Builds apt-get commands for an injected shell. The daemon installs none, so the update is refused with NoPackageProvider before it starts. |
| `/machine/update/upgrade` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | Matches Moonraker. |
| `/machine/wled/off` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/machine/wled/on` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/machine/wled/status` | GET | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/machine/wled/strip` | GET, POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/machine/wled/strips` | GET | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/machine/wled/toggle` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | Matches Moonraker. |
| `/printer/firmware_restart` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/printer/print/cancel` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/printer/print/pause` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/printer/print/resume` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/printer/print/start` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/printer/restart` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | Matches Moonraker. |
| `/server/analysis/dump_config` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `/server/analysis/estimate` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `/server/analysis/process` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `/server/analysis/status` | GET | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `/server/announcements/dismiss` | POST | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Matches Moonraker. |
| `/server/announcements/feed` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Matches Moonraker. |
| `/server/announcements/feeds` | GET | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Matches Moonraker. |
| `/server/announcements/list` | GET | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Matches Moonraker. |
| `/server/announcements/update` | POST | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Matches Moonraker. |
| `/server/config` | GET | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | Matches Moonraker. |
| `/server/connection/identify` | POST | WEBSOCKET | websockets | ✅ Full | Matches Moonraker. |
| `/server/database/backup` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/server/database/compact` | POST | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/server/database/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/server/database/list` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/server/database/restore` | POST | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | Matches Moonraker. |
| `/server/extensions/list` | GET | HTTP, WEBSOCKET, INTERNAL | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `/server/extensions/request` | POST | HTTP, WEBSOCKET, INTERNAL | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `/server/files/copy` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/delete_file` | DELETE | WEBSOCKET | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/directory` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/list` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/metadata` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/metascan` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/move` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/roots` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/files/thumbnails` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ⚠️ Partial | Returns base64 `data` from the gcode header; no `.thumbs/*.png` files, so `relative_path`/`thumbnail_path` are missing (TODO.md). |
| `/server/files/zip` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Matches Moonraker. |
| `/server/gcode_store` | GET | HTTP, WEBSOCKET, INTERNAL | data_store | ✅ Full | Matches Moonraker. |
| `/server/history/job` | GET, DELETE | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | Matches Moonraker. |
| `/server/history/list` | GET | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | Matches Moonraker. |
| `/server/history/reset_totals` | POST | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | Matches Moonraker. |
| `/server/history/totals` | GET | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | Matches Moonraker. |
| `/server/info` | GET | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | Matches Moonraker. |
| `/server/job_queue/job` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | Matches Moonraker. |
| `/server/job_queue/jump` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | Matches Moonraker. |
| `/server/job_queue/pause` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | Matches Moonraker. |
| `/server/job_queue/start` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | Matches Moonraker. |
| `/server/job_queue/status` | GET | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | Matches Moonraker. |
| `/server/logs/rollover` | POST | HTTP, WEBSOCKET, INTERNAL | loghelper | ✅ Full | Matches Moonraker. |
| `/server/mqtt/publish` | POST | <dynamic> | mqtt | ✅ Full | Matches Moonraker. |
| `/server/mqtt/subscribe` | POST | <dynamic> | mqtt | ✅ Full | Matches Moonraker. |
| `/server/notifiers/list` | GET | HTTP, WEBSOCKET, INTERNAL | notifier | ⚠️ Partial | List records come from `[notifier <name>]`. Sending is `AppriseNotAvailable` because apprise is not linked. |
| `/server/restart` | POST | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | Matches Moonraker. |
| `/server/sensors/info` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `/server/sensors/list` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `/server/sensors/measurements` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `/server/spoolman/proxy` | POST | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | Per-request HTTP forwarder to the configured Spoolman server (no server-side response cache; Moonraker doesn't cache proxied responses either). Live WebSocket maintained for connection state + spool-deleted. |
| `/server/spoolman/spool_id` | GET, POST | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | Matches Moonraker. |
| `/server/spoolman/status` | GET | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | Matches Moonraker. |
| `/server/temperature_store` | GET | HTTP, WEBSOCKET, INTERNAL | data_store | ✅ Full | Matches Moonraker. |
| `/server/webcams/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | Matches Moonraker. |
| `/server/webcams/list` | GET | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | Matches Moonraker. |
| `/server/webcams/test` | POST | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | Matches Moonraker. |
| `/server/websocket/id` | GET | WEBSOCKET | websockets | ✅ Full | Matches Moonraker. |
| `/server/zeroconf/ssdp` | GET | HTTP | zeroconf | ✅ Full | Matches Moonraker. |
| `<dynamic>` | <dynamic> | <dynamic> | application | ✅ Full | Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route. |
| `<dynamic>` | GET, POST | HTTP, WEBSOCKET, INTERNAL | klippy_connection | ✅ Full | Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route. |

_Endpoints: 97 full, 26 partial, 2 no-op, 0 missing._

## JSON-RPC methods

| Method | Transports | Component | Status | Notes |
|---|---|---|---|---|
| `access.delete_user` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.get_api_key` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.get_user` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.info` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.login` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.logout` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.oneshot_token` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.post_api_key` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.post_user` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.refresh_jwt` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.user.password` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `access.users.list` |  | authorization | ✅ Full | JWT + oneshot + API-key + trusted-client all enforced. The `ldap` auth source is unsupported (moonraker source only); the user `source` field is kept for shape parity. |
| `connection.register_remote_method` |  | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `connection.send_event` |  | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `debug.database.delete_item` |  | database | ✅ Full | Matches Moonraker. |
| `debug.database.get_item` |  | database | ✅ Full | Matches Moonraker. |
| `debug.database.list` |  | database | ✅ Full | Matches Moonraker. |
| `debug.database.post_item` |  | database | ✅ Full | Matches Moonraker. |
| `debug.database.table` |  | database | ✅ Full | Matches Moonraker. |
| `debug.notifiers.test` |  | notifier | ⚠️ Partial | List records come from `[notifier <name>]`. Sending is `AppriseNotAvailable` because apprise is not linked. |
| `machine.device_power.devices` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.device_power.get_device` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.device_power.off` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.device_power.on` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.device_power.post_device` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.device_power.status` |  | power | ⚠️ Partial | http / gpio (sysfs `pin`) / tasmota / shelly devices do real I/O with Core released. tplink_smartplug and homeseer track state in-memory only. Shutdown/queue hooks, bound services, timers and http templates are not implemented (TODO.md). |
| `machine.peripherals.canbus` |  | machine | ⚠️ Partial | Returns an empty `can_uuids` list; no SocketCAN query. |
| `machine.peripherals.serial` |  | machine | ✅ Full | Matches Moonraker. |
| `machine.peripherals.usb` |  | machine | ⚠️ Partial | No usb.ids database: class, subclass and protocol are null, and names come only from Moonraker's built-in 1d50 (Klipper, Katapult) entries. |
| `machine.peripherals.video` |  | machine | ⚠️ Partial | `modes` is always [] (no format enumeration) and `libcamera_devices` is always []. |
| `machine.proc_stats` |  | proc_stats | ✅ Full | Matches Moonraker. |
| `machine.reboot` |  | machine | 🚫 No-op | Deliberate no-op: returns Moonraker's ok shape but never reboots the host (printer boards lack systemd; a stray call must not power-cycle the box). |
| `machine.services.restart` |  | machine | ⚠️ Partial | See machine.services.start. |
| `machine.services.start` |  | machine | ⚠️ Partial | Dispatches to the configured [machine] provider: systemctl (systemd_dbus/systemd_cli), supervisorctl (supervisord_cli), `<script_path>/<service>` (simple), or in-memory (none). A name outside Moonraker's allow-list returns 403 "Forbidden" (Moonraker: 400 "Service '<name>' not allowed"); an allowed but undiscovered service is not refused as "not installed". |
| `machine.services.stop` |  | machine | ⚠️ Partial | See machine.services.start. |
| `machine.shutdown` |  | machine | 🚫 No-op | Deliberate no-op: returns ok but never shuts the host down. |
| `machine.sudo.info` |  | machine | ✅ Full | Matches Moonraker. |
| `machine.sudo.password` |  | machine | ✅ Full | Matches Moonraker. |
| `machine.system_info` |  | machine | ✅ Full | Matches Moonraker. |
| `machine.td1.data` |  | td1 | ⚠️ Partial | Discovery and CSV readings work; the errors.txt and reboot handshakes are not sent, so `error` is null and reboot only forgets the device (TODO.md). |
| `machine.td1.reboot` |  | td1 | ⚠️ Partial | Discovery and CSV readings work; the errors.txt and reboot handshakes are not sent, so `error` is null and reboot only forgets the device (TODO.md). |
| `machine.update.client` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.full` |  | update_manager | ⚠️ Partial | Runs only package steps (apt-get, pip) through an injected shell; the daemon installs none, so it is refused while the system updater is enabled. Git sources only report progress lines; web/zip installation is unimplemented. |
| `machine.update.klipper` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.moonraker` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.recover` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.refresh` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.rollback` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.status` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.update.system` |  | update_manager | ⚠️ Partial | Builds apt-get commands for an injected shell. The daemon installs none, so the update is refused with NoPackageProvider before it starts. |
| `machine.update.upgrade` |  | update_manager | ✅ Full | Matches Moonraker. |
| `machine.wled.get_strip` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.off` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.on` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.post_strip` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.status` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.strips` |  | wled | ✅ Full | Matches Moonraker. |
| `machine.wled.toggle` |  | wled | ✅ Full | Matches Moonraker. |
| `printer.firmware_restart` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `printer.print.cancel` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `printer.print.pause` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `printer.print.resume` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `printer.print.start` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `printer.restart` |  | klippy_apis | ✅ Full | Matches Moonraker. |
| `server.analysis.dump_config` |  | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `server.analysis.estimate` |  | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `server.analysis.process` |  | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `server.analysis.status` |  | analysis | ⚠️ Partial | Estimator execution requires an injected shell. No download or daemon runner is provided; status reports binary/config presence. |
| `server.announcements.delete_feed` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.announcements.dismiss` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.announcements.feeds` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.announcements.list` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.announcements.post_feed` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.announcements.update` |  | announcements | ✅ Full | Matches Moonraker. |
| `server.config` |  | server | ✅ Full | Matches Moonraker. |
| `server.connection.identify` |  | websockets | ✅ Full | Matches Moonraker. |
| `server.database.compact` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.delete_backup` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.delete_item` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.get_item` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.list` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.post_backup` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.post_item` |  | database | ✅ Full | Matches Moonraker. |
| `server.database.restore` |  | database | ✅ Full | Matches Moonraker. |
| `server.extensions.list` |  | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `server.extensions.request` |  | extensions | ⚠️ Partial | No agent registry: `identify` does not register agent clients, so the list is empty, requests fail with AgentNotConnected, and remote methods and events go nowhere (TODO.md). |
| `server.files.copy` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.delete_directory` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.delete_file` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.get_directory` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.list` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.metadata` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.metascan` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.move` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.post_directory` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.roots` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.files.thumbnails` |  | file_manager | ⚠️ Partial | Returns base64 `data` from the gcode header; no `.thumbs/*.png` files, so `relative_path`/`thumbnail_path` are missing (TODO.md). |
| `server.files.zip` |  | file_manager | ✅ Full | Matches Moonraker. |
| `server.gcode_store` |  | data_store | ✅ Full | Matches Moonraker. |
| `server.history.delete_job` |  | history | ✅ Full | Matches Moonraker. |
| `server.history.get_job` |  | history | ✅ Full | Matches Moonraker. |
| `server.history.list` |  | history | ✅ Full | Matches Moonraker. |
| `server.history.reset_totals` |  | history | ✅ Full | Matches Moonraker. |
| `server.history.totals` |  | history | ✅ Full | Matches Moonraker. |
| `server.info` |  | server | ✅ Full | Matches Moonraker. |
| `server.job_queue.delete_job` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.job_queue.jump` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.job_queue.pause` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.job_queue.post_job` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.job_queue.start` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.job_queue.status` |  | job_queue | ✅ Full | Matches Moonraker. |
| `server.logs.rollover` |  | loghelper | ✅ Full | Matches Moonraker. |
| `server.mqtt.publish` |  | mqtt | ✅ Full | Matches Moonraker. |
| `server.mqtt.subscribe` |  | mqtt | ✅ Full | Matches Moonraker. |
| `server.notifiers.list` |  | notifier | ⚠️ Partial | List records come from `[notifier <name>]`. Sending is `AppriseNotAvailable` because apprise is not linked. |
| `server.restart` |  | server | ✅ Full | Matches Moonraker. |
| `server.sensors.info` |  | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `server.sensors.list` |  | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `server.sensors.measurements` |  | sensor | ✅ Full | MQTT sensors with state_response_template via an in-tree Jinja subset (sensor_template.zig): set/if/for, operators, ~20 filters, is-tests, set_result. Not a full Jinja2 engine (no macros/inheritance). |
| `server.spoolman.get_spool_id` |  | spoolman | ✅ Full | Matches Moonraker. |
| `server.spoolman.post_spool_id` |  | spoolman | ✅ Full | Matches Moonraker. |
| `server.spoolman.proxy` |  | spoolman | ✅ Full | Per-request HTTP forwarder to the configured Spoolman server (no server-side response cache; Moonraker doesn't cache proxied responses either). Live WebSocket maintained for connection state + spool-deleted. |
| `server.spoolman.status` |  | spoolman | ✅ Full | Matches Moonraker. |
| `server.temperature_store` |  | data_store | ✅ Full | Matches Moonraker. |
| `server.webcams.delete_item` |  | webcam | ✅ Full | Matches Moonraker. |
| `server.webcams.get_item` |  | webcam | ✅ Full | Matches Moonraker. |
| `server.webcams.list` |  | webcam | ✅ Full | Matches Moonraker. |
| `server.webcams.post_item` |  | webcam | ✅ Full | Matches Moonraker. |
| `server.webcams.test` |  | webcam | ✅ Full | Matches Moonraker. |
| `server.websocket.id` |  | websockets | ✅ Full | Matches Moonraker. |

## Notifications

| Notification | Component | Status | Notes |
|---|---|---|---|
| `notify_active_spool_set` | spoolman | ✅ Full | Matches Moonraker. |
| `notify_agent_event` | extensions | ❌ Missing | Never emitted: no agent clients are registered (TODO.md). |
| `notify_announcement_dismissed` | announcements | ✅ Full | Matches Moonraker. |
| `notify_announcement_update` | announcements | ✅ Full | Matches Moonraker. |
| `notify_announcement_wake` | announcements | ✅ Full | Matches Moonraker. |
| `notify_button_event` | button | ❌ Missing | Never emitted: `[button]` sections and templates are not implemented (TODO.md). |
| `notify_cpu_throttled` | proc_stats | ✅ Full | Matches Moonraker. |
| `notify_filelist_changed` | file_manager | ✅ Full | Matches Moonraker. |
| `notify_gcode_response` | server | ✅ Full | Matches Moonraker. |
| `notify_history_changed` | history | ✅ Full | Matches Moonraker. |
| `notify_job_queue_changed` | job_queue | ✅ Full | Matches Moonraker. |
| `notify_klippy_disconnected` | server | ✅ Full | Matches Moonraker. |
| `notify_klippy_ready` | server | ✅ Full | Matches Moonraker. |
| `notify_klippy_shutdown` | server | ✅ Full | Matches Moonraker. |
| `notify_power_changed` | power | ✅ Full | Matches Moonraker. |
| `notify_proc_stat_update` | proc_stats | ✅ Full | Matches Moonraker. |
| `notify_sensor_update` | sensor | ✅ Full | Matches Moonraker. |
| `notify_service_state_changed` | machine | ⚠️ Partial | Sent after API service actions only; Moonraker also sends it from its periodic service-state poll. |
| `notify_spoolman_status_changed` | spoolman | ✅ Full | Matches Moonraker. |
| `notify_status_update` | common | ✅ Full | Matches Moonraker. |
| `notify_sudo_alert` | machine | ✅ Full | Matches Moonraker. |
| `notify_update_refreshed` | update_manager | ✅ Full | Matches Moonraker. |
| `notify_update_response` | update_manager | ✅ Full | Matches Moonraker. |
| `notify_user_created` | authorization | ✅ Full | Matches Moonraker. |
| `notify_user_deleted` | authorization | ✅ Full | Matches Moonraker. |
| `notify_user_logged_out` | authorization | ✅ Full | Matches Moonraker. |
| `notify_webcams_changed` | webcam | ✅ Full | Matches Moonraker. |

## phobos methods/notifications beyond the static baseline

Calls phobos registers that the static baseline lists don't enumerate. Most are Moonraker functionality registered via remote methods or the dynamic is_remote path; genuine phobos-only items are marked "phobos-internal shim".

| JSON-RPC method | Classification |
|---|---|
| `pause_job_queue` | Klipper remote method (also exposed as JSON-RPC) |
| `printer.emergency_stop` | Klipper-proxied (is_remote) endpoint |
| `printer.gcode.help` | Klipper-proxied (is_remote) endpoint |
| `printer.gcode.script` | Klipper-proxied (is_remote) endpoint |
| `printer.info` | Klipper-proxied (is_remote) endpoint |
| `printer.objects.list` | Klipper-proxied (is_remote) endpoint |
| `printer.objects.query` | Klipper-proxied (is_remote) endpoint |
| `printer.objects.subscribe` | Klipper-proxied (is_remote) endpoint |
| `printer.query_endstops.status` | Klipper-proxied (is_remote) endpoint |
| `server.mqtt.publish_mqtt_topic` | Klipper remote method (also exposed as JSON-RPC) |
| `set_wled` | Klipper remote method (also exposed as JSON-RPC) |
| `set_wled_state` | Klipper remote method (also exposed as JSON-RPC) |
| `spoolman_set_active_spool` | Klipper remote method (also exposed as JSON-RPC) |
| `start_job_queue` | Klipper remote method (also exposed as JSON-RPC) |

## Klipper→Moonraker remote methods

| Remote method | Component | Status | Notes |
|---|---|---|---|
| `<dynamic>` | server | ✅ Full | Matches Moonraker. |
| `notify` | notifier | ✅ Full | Matches Moonraker. |
| `paneldue_beep` | paneldue | ❌ Missing | No PanelDue serial device, so the beep is never sent (TODO.md). |
| `pause_job_queue` | job_queue | ✅ Full | Matches Moonraker. |
| `process_gcode_response` | klippy_connection | ✅ Full | Matches Moonraker. |
| `process_status_update` | klippy_connection | ✅ Full | Matches Moonraker. |
| `publish_mqtt_topic` | mqtt | ✅ Full | Matches Moonraker. |
| `reboot_machine` | machine | ✅ Full | Matches Moonraker. |
| `set_device_power` | power | ⚠️ Partial | Registered with Klippy and run off the Klippy reader; `force` is ignored, so `locked_while_printing` still applies (TODO.md). |
| `set_wled` | wled | ✅ Full | Matches Moonraker. |
| `set_wled_state` | wled | ✅ Full | Matches Moonraker. |
| `shutdown_machine` | machine | ✅ Full | Matches Moonraker. |
| `spoolman_set_active_spool` | spoolman | ✅ Full | Matches Moonraker. |
| `start_job_queue` | job_queue | ✅ Full | Matches Moonraker. |


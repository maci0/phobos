# phobos API Coverage

Per-call implementation status of every Moonraker API surface element, with any behavioural difference. **Auto-generated** (`PYTHONPATH=tools uv run python -m api_scanner table`) from the Moonraker baseline (`api/api_surface.json`) × phobos `--dump-api` × curated deltas. Do not hand-edit; update the deltas in `tools/api_scanner/table.py`.

- Moonraker baseline: `0.10.1.dev20+g9008485` (commit `900848584374`).
- Endpoints: 125 · JSON-RPC methods: 130 · notifications: 27 · remote methods: 14.

Status: ✅ Full (no recorded delta) · ⚠️ Partial (known behavior differences) · 🚫 No-op (deliberate, host-safety) · ❌ Missing. These labels summarize curated differences; name coverage does not prove behavioral conformance.

## HTTP endpoints

| Path | Verbs | Transports | Component | Status | Notes |
|---|---|---|---|---|---|
| `/access/api_key` | GET, POST | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/info` | GET | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/login` | POST | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/logout` | POST | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/oneshot_token` | GET | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/refresh_jwt` | POST | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/user` | GET, POST, DELETE | HTTP, WEBSOCKET | authorization | ⚠️ Partial | Creates users with non-empty, dot-free names. Dotted usernames return 400 because dots denote nested DataStore keys; Moonraker can store those names. Names are not rewritten. |
| `/access/user/password` | POST | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/access/users/list` | GET | HTTP, WEBSOCKET | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `/api/currentuser` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/files/moonraker/(?P<relative_path>.+)` | POST | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/job` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/login` | POST | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/printer` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/printer/command` | POST | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/printerprofiles` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/server` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/settings` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/api/version` | GET | HTTP | octoprint_compat | ✅ Full | No recorded behavior difference. |
| `/connection/register_remote_method` | POST | WEBSOCKET | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `/connection/send_event` | POST | WEBSOCKET | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `/debug/database/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/debug/database/list` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/debug/database/table` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/debug/notifiers/test` | POST | HTTP, WEBSOCKET, INTERNAL | notifier | ⚠️ Partial | Lists configured notifier records. Sending fails with AppriseNotAvailable; Apprise and full Jinja2 are outside scope. |
| `/machine/device_power/device` | GET, POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `/machine/device_power/devices` | GET | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `/machine/device_power/off` | POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `/machine/device_power/on` | POST | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `/machine/device_power/status` | GET | HTTP, WEBSOCKET, INTERNAL | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `/machine/peripherals/canbus` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | Queries unassigned Klipper/Katapult CAN nodes with a two-second deadline. Unavailable interfaces deliberately return an empty list instead of a missing-device 500. |
| `/machine/peripherals/serial` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | No recorded behavior difference. |
| `/machine/peripherals/usb` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Streams vendor, product and class names from the owned usb.ids cache, with built-in OpenMoko/Klipper fallback entries. The daemon starts a bounded, atomic cache download. |
| `/machine/peripherals/video` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | Enumerates V4L2 formats and discrete resolutions. libcamera_devices remains empty. |
| `/machine/proc_stats` | GET | HTTP, WEBSOCKET, INTERNAL | proc_stats | ✅ Full | No recorded behavior difference. |
| `/machine/reboot` | POST | HTTP, WEBSOCKET, INTERNAL | machine | 🚫 No-op | Deliberate no-op: returns ok without rebooting the host. |
| `/machine/services/restart` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | See machine.services.start. |
| `/machine/services/start` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | Dispatches through the configured provider and allowed-service validation. Systemd/supervisord polling refreshes state; simple/none preserve their fixed-name behavior. See docs/MACHINE.md. |
| `/machine/services/stop` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | See machine.services.start. |
| `/machine/shutdown` | POST | HTTP, WEBSOCKET, INTERNAL | machine | 🚫 No-op | Deliberate no-op: returns ok without shutting down the host. |
| `/machine/sudo/info` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | No recorded behavior difference. |
| `/machine/sudo/password` | POST | HTTP, WEBSOCKET, INTERNAL | machine | ✅ Full | No recorded behavior difference. |
| `/machine/system_info` | GET | HTTP, WEBSOCKET, INTERNAL | machine | ⚠️ Partial | Collects native host information. Python version fields remain a stub; phobos does not claim to run CPython. |
| `/machine/td1/data` | GET | HTTP, WEBSOCKET, INTERNAL | td1 | ✅ Full | Owned persistent readers retrieve errors.txt, expose nullable initial readings and UTC scan times, and perform the device settings/reboot handshake. Physical device timing remains unverified. |
| `/machine/td1/reboot` | POST | HTTP, WEBSOCKET, INTERNAL | td1 | ✅ Full | Owned persistent readers retrieve errors.txt, expose nullable initial readings and UTC scan times, and perform the device settings/reboot handshake. Physical device timing remains unverified. |
| `/machine/update/client` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/full` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ⚠️ Partial | Runs configured Git and Web/ZIP updates, including managed-service restarts. Package steps require an injected runner and are refused before starting when it is absent. See docs/UPDATES.md. |
| `/machine/update/klipper` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/moonraker` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/recover` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/refresh` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/rollback` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/update/status` | GET | HTTP, WEBSOCKET, INTERNAL | update_manager | ⚠️ Partial | Reads Git and release caches and installed state. github_rate_limit, github_requests_remaining and github_limit_reset_time remain null because release requests do not retain those headers. |
| `/machine/update/system` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ⚠️ Partial | Package commands require an injected runner. The daemon installs none and refuses them with NoPackageProvider before execution. |
| `/machine/update/upgrade` | POST | HTTP, WEBSOCKET, INTERNAL | update_manager | ✅ Full | No recorded behavior difference. |
| `/machine/wled/off` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/machine/wled/on` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/machine/wled/status` | GET | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/machine/wled/strip` | GET, POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/machine/wled/strips` | GET | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/machine/wled/toggle` | POST | HTTP, WEBSOCKET, INTERNAL | wled | ✅ Full | No recorded behavior difference. |
| `/printer/firmware_restart` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/printer/print/cancel` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/printer/print/pause` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/printer/print/resume` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/printer/print/start` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/printer/restart` | POST | HTTP, WEBSOCKET, INTERNAL | klippy_apis | ✅ Full | No recorded behavior difference. |
| `/server/analysis/dump_config` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `/server/analysis/estimate` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `/server/analysis/process` | POST | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `/server/analysis/status` | GET | HTTP, WEBSOCKET, INTERNAL | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `/server/announcements/dismiss` | POST | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | No recorded behavior difference. |
| `/server/announcements/feed` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | No recorded behavior difference. |
| `/server/announcements/feeds` | GET | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | No recorded behavior difference. |
| `/server/announcements/list` | GET | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | No recorded behavior difference. |
| `/server/announcements/update` | POST | HTTP, WEBSOCKET, INTERNAL | announcements | ✅ Full | Refreshes RSS with conditional requests. Development mode reads <data_path>/development/announcements/<feed>.xml. |
| `/server/config` | GET | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | No recorded behavior difference. |
| `/server/connection/identify` | POST | WEBSOCKET | websockets | ✅ Full | No recorded behavior difference. |
| `/server/database/backup` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/server/database/compact` | POST | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/server/database/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/server/database/list` | GET | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/server/database/restore` | POST | HTTP, WEBSOCKET, INTERNAL | database | ✅ Full | No recorded behavior difference. |
| `/server/extensions/list` | GET | HTTP, WEBSOCKET, INTERNAL | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `/server/extensions/request` | POST | HTTP, WEBSOCKET, INTERNAL | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `/server/files/copy` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/delete_file` | DELETE | WEBSOCKET | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/directory` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/list` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/metadata` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/metascan` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/move` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/roots` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | No recorded behavior difference. |
| `/server/files/thumbnails` | GET | HTTP, WEBSOCKET, INTERNAL | file_manager | ✅ Full | Extracts embedded PNGs to .thumbs files; metadata and thumbnail_path name downloadable files under the gcodes root. |
| `/server/files/zip` | POST | HTTP, WEBSOCKET, INTERNAL | file_manager | ⚠️ Partial | Writes atomic ZIP32 archives with DEFLATE or stored entries. ZIP64 is rejected; source lists are bounded to 4096 files, 1 MiB of retained paths and 65536 examined directory entries. See docs/FILE_MANAGEMENT.md. |
| `/server/gcode_store` | GET | HTTP, WEBSOCKET, INTERNAL | data_store | ✅ Full | No recorded behavior difference. |
| `/server/history/job` | GET, DELETE | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | No recorded behavior difference. |
| `/server/history/list` | GET | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | No recorded behavior difference. |
| `/server/history/reset_totals` | POST | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | No recorded behavior difference. |
| `/server/history/totals` | GET | HTTP, WEBSOCKET, INTERNAL | history | ✅ Full | No recorded behavior difference. |
| `/server/info` | GET | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | Reports compatibility API 1.5.0 and phobos software identity by default. These are implementation identity fields, rather than Forge-X's older API/version values. |
| `/server/job_queue/job` | POST, DELETE | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | No recorded behavior difference. |
| `/server/job_queue/jump` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | No recorded behavior difference. |
| `/server/job_queue/pause` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | No recorded behavior difference. |
| `/server/job_queue/start` | POST | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | No recorded behavior difference. |
| `/server/job_queue/status` | GET | HTTP, WEBSOCKET, INTERNAL | job_queue | ✅ Full | No recorded behavior difference. |
| `/server/logs/rollover` | POST | HTTP, WEBSOCKET, INTERNAL | loghelper | ✅ Full | No recorded behavior difference. |
| `/server/mqtt/publish` | POST | <dynamic> | mqtt | ⚠️ Partial | Supports MQTT 3.1/3.1.1/5, TLS, reconnect, QoS acknowledgements, temporary subscription cleanup and Klippy status publishing. Credential templates use a bounded subset rather than full Jinja2. See docs/MQTT.md. |
| `/server/mqtt/subscribe` | POST | <dynamic> | mqtt | ⚠️ Partial | Supports MQTT 3.1/3.1.1/5, TLS, reconnect, QoS acknowledgements, temporary subscription cleanup and Klippy status publishing. Credential templates use a bounded subset rather than full Jinja2. See docs/MQTT.md. |
| `/server/notifiers/list` | GET | HTTP, WEBSOCKET, INTERNAL | notifier | ⚠️ Partial | Lists configured notifier records. Sending fails with AppriseNotAvailable; Apprise and full Jinja2 are outside scope. |
| `/server/restart` | POST | HTTP, WEBSOCKET, INTERNAL | server | ✅ Full | No recorded behavior difference. |
| `/server/sensors/info` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `/server/sensors/list` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `/server/sensors/measurements` | GET | HTTP, WEBSOCKET, INTERNAL | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `/server/spoolman/proxy` | POST | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | HTTP forwarding has a ten-second deadline. V1 preserves upstream status and reason text; v2 uses the JSON message field. Text and depth are validated. WebSocket state tracks connectivity and spool deletion. |
| `/server/spoolman/spool_id` | GET, POST | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | No recorded behavior difference. |
| `/server/spoolman/status` | GET | HTTP, WEBSOCKET, INTERNAL | spoolman | ✅ Full | Reports connection state, active spool and pending filament use. Extrusion accounting retains failed reports and retries at sync_rate; the active spool is checked on reconnect. |
| `/server/temperature_store` | GET | HTTP, WEBSOCKET, INTERNAL | data_store | ✅ Full | No recorded behavior difference. |
| `/server/webcams/item` | GET, POST, DELETE | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | No recorded behavior difference. |
| `/server/webcams/list` | GET | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | No recorded behavior difference. |
| `/server/webcams/test` | POST | HTTP, WEBSOCKET, INTERNAL | webcam | ✅ Full | Resolves relative URLs against the routed public address, rewrites local wildcard listeners to loopback, and probes only the snapshot URL. DNS and snapshot requests use joined two-second deadlines outside Core. |
| `/server/websocket/id` | GET | WEBSOCKET | websockets | ✅ Full | No recorded behavior difference. |
| `/server/zeroconf/ssdp` | GET | HTTP | zeroconf | ✅ Full | No recorded behavior difference. |
| `<dynamic>` | <dynamic> | <dynamic> | application | ✅ Full | Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route. |
| `<dynamic>` | GET, POST | HTTP, WEBSOCKET, INTERNAL | klippy_connection | ✅ Full | Dynamic endpoint registration: Klipper-registered endpoints are proxied via the is_remote path, not a fixed route. |

_Endpoints: 91 full, 32 partial, 2 no-op, 0 missing._

## JSON-RPC methods

| Method | Transports | Component | Status | Notes |
|---|---|---|---|---|
| `access.delete_user` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.get_api_key` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.get_user` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.info` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.login` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.logout` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.oneshot_token` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.post_api_key` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.post_user` |  | authorization | ⚠️ Partial | Creates users with non-empty, dot-free names. Dotted usernames return 400 because dots denote nested DataStore keys; Moonraker can store those names. Names are not rewritten. |
| `access.refresh_jwt` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.user.password` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `access.users.list` |  | authorization | ⚠️ Partial | JWT, oneshot tokens, API keys and trusted IP/CIDR clients are enforced. LDAP and reverse-DNS trusted_domains are not implemented. |
| `connection.register_remote_method` |  | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `connection.send_event` |  | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `debug.database.delete_item` |  | database | ✅ Full | No recorded behavior difference. |
| `debug.database.get_item` |  | database | ✅ Full | No recorded behavior difference. |
| `debug.database.list` |  | database | ✅ Full | No recorded behavior difference. |
| `debug.database.post_item` |  | database | ✅ Full | No recorded behavior difference. |
| `debug.database.table` |  | database | ✅ Full | No recorded behavior difference. |
| `debug.notifiers.test` |  | notifier | ⚠️ Partial | Lists configured notifier records. Sending fails with AppriseNotAvailable; Apprise and full Jinja2 are outside scope. |
| `machine.device_power.devices` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.device_power.get_device` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.device_power.off` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.device_power.on` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.device_power.post_device` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.device_power.status` |  | power | ⚠️ Partial | HTTP, GPIO, Tasmota and Shelly perform device I/O with shutdown/queue hooks, service bindings, timers and HTTP templates. Other backends, including tplink_smartplug and homeseer, keep state in memory unless explicit HTTP URLs are configured. Templates use a bounded subset; see docs/POWER_BUTTONS.md. |
| `machine.peripherals.canbus` |  | machine | ⚠️ Partial | Queries unassigned Klipper/Katapult CAN nodes with a two-second deadline. Unavailable interfaces deliberately return an empty list instead of a missing-device 500. |
| `machine.peripherals.serial` |  | machine | ✅ Full | No recorded behavior difference. |
| `machine.peripherals.usb` |  | machine | ✅ Full | Streams vendor, product and class names from the owned usb.ids cache, with built-in OpenMoko/Klipper fallback entries. The daemon starts a bounded, atomic cache download. |
| `machine.peripherals.video` |  | machine | ⚠️ Partial | Enumerates V4L2 formats and discrete resolutions. libcamera_devices remains empty. |
| `machine.proc_stats` |  | proc_stats | ✅ Full | No recorded behavior difference. |
| `machine.reboot` |  | machine | 🚫 No-op | Deliberate no-op: returns ok without rebooting the host. |
| `machine.services.restart` |  | machine | ✅ Full | See machine.services.start. |
| `machine.services.start` |  | machine | ✅ Full | Dispatches through the configured provider and allowed-service validation. Systemd/supervisord polling refreshes state; simple/none preserve their fixed-name behavior. See docs/MACHINE.md. |
| `machine.services.stop` |  | machine | ✅ Full | See machine.services.start. |
| `machine.shutdown` |  | machine | 🚫 No-op | Deliberate no-op: returns ok without shutting down the host. |
| `machine.sudo.info` |  | machine | ✅ Full | No recorded behavior difference. |
| `machine.sudo.password` |  | machine | ✅ Full | No recorded behavior difference. |
| `machine.system_info` |  | machine | ⚠️ Partial | Collects native host information. Python version fields remain a stub; phobos does not claim to run CPython. |
| `machine.td1.data` |  | td1 | ✅ Full | Owned persistent readers retrieve errors.txt, expose nullable initial readings and UTC scan times, and perform the device settings/reboot handshake. Physical device timing remains unverified. |
| `machine.td1.reboot` |  | td1 | ✅ Full | Owned persistent readers retrieve errors.txt, expose nullable initial readings and UTC scan times, and perform the device settings/reboot handshake. Physical device timing remains unverified. |
| `machine.update.client` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.full` |  | update_manager | ⚠️ Partial | Runs configured Git and Web/ZIP updates, including managed-service restarts. Package steps require an injected runner and are refused before starting when it is absent. See docs/UPDATES.md. |
| `machine.update.klipper` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.moonraker` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.recover` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.refresh` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.rollback` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.update.status` |  | update_manager | ⚠️ Partial | Reads Git and release caches and installed state. github_rate_limit, github_requests_remaining and github_limit_reset_time remain null because release requests do not retain those headers. |
| `machine.update.system` |  | update_manager | ⚠️ Partial | Package commands require an injected runner. The daemon installs none and refuses them with NoPackageProvider before execution. |
| `machine.update.upgrade` |  | update_manager | ✅ Full | No recorded behavior difference. |
| `machine.wled.get_strip` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.off` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.on` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.post_strip` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.status` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.strips` |  | wled | ✅ Full | No recorded behavior difference. |
| `machine.wled.toggle` |  | wled | ✅ Full | No recorded behavior difference. |
| `printer.firmware_restart` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `printer.print.cancel` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `printer.print.pause` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `printer.print.resume` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `printer.print.start` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `printer.restart` |  | klippy_apis | ✅ Full | No recorded behavior difference. |
| `server.analysis.dump_config` |  | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `server.analysis.estimate` |  | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `server.analysis.process` |  | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `server.analysis.status` |  | analysis | ⚠️ Partial | Estimator execution requires an injected runner; the daemon provides no runner or download. See docs/ANALYSIS.md for execution, file-safety and lifecycle limits. |
| `server.announcements.delete_feed` |  | announcements | ✅ Full | No recorded behavior difference. |
| `server.announcements.dismiss` |  | announcements | ✅ Full | No recorded behavior difference. |
| `server.announcements.feeds` |  | announcements | ✅ Full | No recorded behavior difference. |
| `server.announcements.list` |  | announcements | ✅ Full | No recorded behavior difference. |
| `server.announcements.post_feed` |  | announcements | ✅ Full | No recorded behavior difference. |
| `server.announcements.update` |  | announcements | ✅ Full | Refreshes RSS with conditional requests. Development mode reads <data_path>/development/announcements/<feed>.xml. |
| `server.config` |  | server | ✅ Full | No recorded behavior difference. |
| `server.connection.identify` |  | websockets | ✅ Full | No recorded behavior difference. |
| `server.database.compact` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.delete_backup` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.delete_item` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.get_item` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.list` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.post_backup` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.post_item` |  | database | ✅ Full | No recorded behavior difference. |
| `server.database.restore` |  | database | ✅ Full | No recorded behavior difference. |
| `server.extensions.list` |  | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `server.extensions.request` |  | extensions | ✅ Full | WebSocket agent registration, bounded bidirectional RPC, owned Klippy methods and agent events are implemented. Disconnect removes registrations and wakes pending callers. |
| `server.files.copy` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.delete_directory` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.delete_file` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.get_directory` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.list` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.metadata` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.metascan` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.move` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.post_directory` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.roots` |  | file_manager | ✅ Full | No recorded behavior difference. |
| `server.files.thumbnails` |  | file_manager | ✅ Full | Extracts embedded PNGs to .thumbs files; metadata and thumbnail_path name downloadable files under the gcodes root. |
| `server.files.zip` |  | file_manager | ⚠️ Partial | Writes atomic ZIP32 archives with DEFLATE or stored entries. ZIP64 is rejected; source lists are bounded to 4096 files, 1 MiB of retained paths and 65536 examined directory entries. See docs/FILE_MANAGEMENT.md. |
| `server.gcode_store` |  | data_store | ✅ Full | No recorded behavior difference. |
| `server.history.delete_job` |  | history | ✅ Full | No recorded behavior difference. |
| `server.history.get_job` |  | history | ✅ Full | No recorded behavior difference. |
| `server.history.list` |  | history | ✅ Full | No recorded behavior difference. |
| `server.history.reset_totals` |  | history | ✅ Full | No recorded behavior difference. |
| `server.history.totals` |  | history | ✅ Full | No recorded behavior difference. |
| `server.info` |  | server | ✅ Full | Reports compatibility API 1.5.0 and phobos software identity by default. These are implementation identity fields, rather than Forge-X's older API/version values. |
| `server.job_queue.delete_job` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.job_queue.jump` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.job_queue.pause` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.job_queue.post_job` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.job_queue.start` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.job_queue.status` |  | job_queue | ✅ Full | No recorded behavior difference. |
| `server.logs.rollover` |  | loghelper | ✅ Full | No recorded behavior difference. |
| `server.mqtt.publish` |  | mqtt | ⚠️ Partial | Supports MQTT 3.1/3.1.1/5, TLS, reconnect, QoS acknowledgements, temporary subscription cleanup and Klippy status publishing. Credential templates use a bounded subset rather than full Jinja2. See docs/MQTT.md. |
| `server.mqtt.subscribe` |  | mqtt | ⚠️ Partial | Supports MQTT 3.1/3.1.1/5, TLS, reconnect, QoS acknowledgements, temporary subscription cleanup and Klippy status publishing. Credential templates use a bounded subset rather than full Jinja2. See docs/MQTT.md. |
| `server.notifiers.list` |  | notifier | ⚠️ Partial | Lists configured notifier records. Sending fails with AppriseNotAvailable; Apprise and full Jinja2 are outside scope. |
| `server.restart` |  | server | ✅ Full | No recorded behavior difference. |
| `server.sensors.info` |  | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `server.sensors.list` |  | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `server.sensors.measurements` |  | sensor | ⚠️ Partial | Loads parameter/history metadata, replaces readings per message, samples and notifies every second, and records MQTT disconnect errors. Templates implement a bounded subset rather than full Jinja2. |
| `server.spoolman.get_spool_id` |  | spoolman | ✅ Full | No recorded behavior difference. |
| `server.spoolman.post_spool_id` |  | spoolman | ✅ Full | No recorded behavior difference. |
| `server.spoolman.proxy` |  | spoolman | ✅ Full | HTTP forwarding has a ten-second deadline. V1 preserves upstream status and reason text; v2 uses the JSON message field. Text and depth are validated. WebSocket state tracks connectivity and spool deletion. |
| `server.spoolman.status` |  | spoolman | ✅ Full | Reports connection state, active spool and pending filament use. Extrusion accounting retains failed reports and retries at sync_rate; the active spool is checked on reconnect. |
| `server.temperature_store` |  | data_store | ✅ Full | No recorded behavior difference. |
| `server.webcams.delete_item` |  | webcam | ✅ Full | No recorded behavior difference. |
| `server.webcams.get_item` |  | webcam | ✅ Full | No recorded behavior difference. |
| `server.webcams.list` |  | webcam | ✅ Full | No recorded behavior difference. |
| `server.webcams.post_item` |  | webcam | ✅ Full | No recorded behavior difference. |
| `server.webcams.test` |  | webcam | ✅ Full | Resolves relative URLs against the routed public address, rewrites local wildcard listeners to loopback, and probes only the snapshot URL. DNS and snapshot requests use joined two-second deadlines outside Core. |
| `server.websocket.id` |  | websockets | ✅ Full | No recorded behavior difference. |

## Notifications

| Notification | Component | Status | Notes |
|---|---|---|---|
| `notify_active_spool_set` | spoolman | ✅ Full | No recorded behavior difference. |
| `notify_agent_event` | extensions | ✅ Full | Agent connection, disconnection and custom events are emitted to other connections. |
| `notify_announcement_dismissed` | announcements | ✅ Full | Dismissal schedules an owned notification after 50 ms. |
| `notify_announcement_update` | announcements | ✅ Full | Handler updates schedule an owned notification after 50 ms. |
| `notify_announcement_wake` | announcements | ✅ Full | No recorded behavior difference. |
| `notify_button_event` | button | ✅ Full | GPIO button templates emit the configured button name, event fields and auxiliary value, at most once per rendered template. |
| `notify_cpu_throttled` | proc_stats | ✅ Full | No recorded behavior difference. |
| `notify_filelist_changed` | file_manager | ✅ Full | No recorded behavior difference. |
| `notify_gcode_response` | server | ✅ Full | No recorded behavior difference. |
| `notify_history_changed` | history | ✅ Full | No recorded behavior difference. |
| `notify_job_queue_changed` | job_queue | ✅ Full | No recorded behavior difference. |
| `notify_klippy_disconnected` | server | ✅ Full | No recorded behavior difference. |
| `notify_klippy_ready` | server | ✅ Full | No recorded behavior difference. |
| `notify_klippy_shutdown` | server | ✅ Full | No recorded behavior difference. |
| `notify_power_changed` | power | ✅ Full | No recorded behavior difference. |
| `notify_proc_stat_update` | proc_stats | ✅ Full | No recorded behavior difference. |
| `notify_sensor_update` | sensor | ✅ Full | No recorded behavior difference. |
| `notify_service_state_changed` | machine | ✅ Full | Emitted for successful API actions and changes found by periodic provider polling. |
| `notify_spoolman_status_changed` | spoolman | ✅ Full | No recorded behavior difference. |
| `notify_status_update` | common | ✅ Full | No recorded behavior difference. |
| `notify_sudo_alert` | machine | ✅ Full | No recorded behavior difference. |
| `notify_update_refreshed` | update_manager | ✅ Full | No recorded behavior difference. |
| `notify_update_response` | update_manager | ✅ Full | No recorded behavior difference. |
| `notify_user_created` | authorization | ✅ Full | No recorded behavior difference. |
| `notify_user_deleted` | authorization | ✅ Full | No recorded behavior difference. |
| `notify_user_logged_out` | authorization | ✅ Full | No recorded behavior difference. |
| `notify_webcams_changed` | webcam | ✅ Full | No recorded behavior difference. |

## phobos methods/notifications beyond the static baseline

Calls phobos registers that the static baseline lists don't enumerate. Most are Moonraker functionality registered via remote methods or the dynamic is_remote path; genuine phobos-only items are marked "phobos-internal shim".

| JSON-RPC method | Classification |
|---|---|
| `notify` | Klipper remote method (also exposed as JSON-RPC) |
| `paneldue_beep` | Klipper remote method (also exposed as JSON-RPC) |
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
| `set_device_power` | Klipper remote method (also exposed as JSON-RPC) |
| `set_wled` | Klipper remote method (also exposed as JSON-RPC) |
| `set_wled_state` | Klipper remote method (also exposed as JSON-RPC) |
| `spoolman_set_active_spool` | Klipper remote method (also exposed as JSON-RPC) |
| `start_job_queue` | Klipper remote method (also exposed as JSON-RPC) |

## Klipper→Moonraker remote methods

| Remote method | Component | Status | Notes |
|---|---|---|---|
| `<dynamic>` | server | ✅ Full | No recorded behavior difference. |
| `notify` | notifier | ⚠️ Partial | Resolves configured notifier names, then returns AppriseNotAvailable. Apprise delivery is outside scope. |
| `paneldue_beep` | paneldue | ✅ Full | Forwards the beep to the configured PanelDue serial worker. |
| `pause_job_queue` | job_queue | ✅ Full | No recorded behavior difference. |
| `process_gcode_response` | klippy_connection | ✅ Full | No recorded behavior difference. |
| `process_status_update` | klippy_connection | ✅ Full | No recorded behavior difference. |
| `publish_mqtt_topic` | mqtt | ✅ Full | No recorded behavior difference. |
| `reboot_machine` | machine | 🚫 No-op | Host reboot is deliberately disabled; the remote call executes no host action. |
| `set_device_power` | power | ✅ Full | The internal-only remote method accepts force. Public endpoints cannot bypass the printing lock; failed calls name the resolved state. |
| `set_wled` | wled | ✅ Full | No recorded behavior difference. |
| `set_wled_state` | wled | ✅ Full | No recorded behavior difference. |
| `shutdown_machine` | machine | 🚫 No-op | Host shutdown is deliberately disabled; the remote call executes no host action. |
| `spoolman_set_active_spool` | spoolman | ✅ Full | No recorded behavior difference. |
| `start_job_queue` | job_queue | ✅ Full | No recorded behavior difference. |


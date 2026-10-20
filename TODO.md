# phobos: status and open work

phobos is a Zig 0.17 Moonraker reimplementation for a static musl binary on
32-bit ARM Cortex-A7 hosts. Workflow and coding rules live in
[DEVELOPMENT.md](DEVELOPMENT.md) and [AGENTS.md](AGENTS.md).

## What the checks prove

`tools/coverage.sh` compares registered endpoint, JSON-RPC method and notification
names with `api/api_surface.json`, pinned to Moonraker `900848584374`. The gate
requires full name coverage; a registered name can still have partial behavior.
The generated [per-call table](docs/api/API_COVERAGE.md) records those differences.
No implementation-completeness percentage is assigned.

`src/oracle/replay.zig` sends requests through the App dispatcher and checks
response keys and error codes. `conformance/replay.py` holds the normalization
rules and replays `conformance/golden/capture.json` against a running server.
The captured stream depends on its component configuration and host hardware;
it is not a portable proof of byte-identical behavior. The last recorded run
before this review passed 49/54 events: three component-list differences and
two USB-device differences remained. See the ledger for later verification.

Build the full suite with `zig build test-artifact -Doptimize=Debug` and run the
newest standalone artifact under a timeout. The real-Klippy test skips when its
socket is absent. Test totals belong with the verified commit in
[docs/PROVENANCE.md](docs/PROVENANCE.md), rather than an unversioned overview.

## Deliberate limits

- `machine.reboot`, `machine.shutdown`, apt and pip remain no-ops.
- The Python-version fields remain a stub; phobos does not claim to run CPython.
- CAN discovery returns an empty list when unavailable rather than copying a
  printer-specific missing-device 500 error.
- Full Jinja2, LDAP and Apprise are outside the project scope. Analysis does not
  download or run the estimator; execution would require an injected runner.
- The API version remains 1.5.0 from the vendored Moonraker pin, and the default
  software version is `phobos`. These identify the implementation rather than
  imitating Forge-X's older API 1.4.0 and unknown software version.
- User creation requires a non-empty username without dots. `POST /access/user`
  returns 400 for a dotted name that Moonraker can store; phobos's generic store
  reserves dots for nested key paths. No username is silently renamed.
- Optional component implementations stay available when registered, even when
  a particular Forge-X configuration does not load them.

Release notes: [v0.1.1](docs/releases/v0.1.1.md),
[v0.1.2](docs/releases/v0.1.2.md), [v0.1.3](docs/releases/v0.1.3.md),
[v0.1.4](docs/releases/v0.1.4.md). Historical footprint and load measurements live
in [MEMORY.md](docs/MEMORY.md) and [PERFORMANCE.md](docs/PERFORMANCE.md).

## Known Moonraker gaps (2026-10-20 audit)

- `[announcements] dev_mode` skips fetching; Moonraker reads `<data_path>/development/announcements/<feed>.xml` (`src/components/announcements.zig` `refreshFeeds`).
- Announcement handlers emit `notify_announcement_update` and `notify_announcement_dismissed` before the response; Moonraker sends them 50 ms later (`announcements.py` `delay_callback(.05, ...)`, `src/components/announcements.zig`).
- `[sensor]` `parameter_*` and `history_field_*` options are not read, so `extended` info has no `parameter_info`/`history_fields` (`src/components/sensor.zig` `getSensorInfo`).
- Sensors append to history and notify per MQTT message and merge `last_measurements`; Moonraker replaces `last_measurements` per message, samples history and notifies from a 1 Hz timer, and sets `error_state` "MQTT Disconnected" on disconnect (`src/components/sensor.zig` `ingestMqttMessage`).
- MQTT Klipper status publishing (`status_objects`, `status_interval`, `publish_split_status`, `{instance}/klipper/status`, `{instance}/klipper/state/...`) is not implemented; the options are ignored. It needs a Klippy status hook in `src/components/klippy_connection.zig` (`src/components/mqtt.zig`).
- MQTT speaks 3.1.1 only; `mqtt_protocol: v3.1` or `v5` logs a warning and connects with 3.1.1. `username`/`password` are used verbatim (no Jinja rendering) and `password_file` is not read (`src/app.zig` `applyMqttConfig`).
- `server.mqtt.publish` replies after the socket write, not after PUBACK/PUBCOMP, so `timeout` has no effect; `server.mqtt.subscribe` does not UNSUBSCRIBE when it returns (`src/components/mqtt.zig`).
- Spoolman filament-use reporting (`sync_rate`, `report_extrusion`, `pending_reports`) and the active-spool existence check on connect are not implemented; `pending_reports` is always `[]` (`src/components/spoolman.zig`).
- Web/zip update installation remains unimplemented. Git updates restart their configured managed services after successful changes; package steps require an injected shell (`src/components/update_manager.zig` `runFullUpdate`, `updateSource`).
- `usb.ids` is neither downloaded nor parsed, so USB class fields are null and names cover only Moonraker's built-in 1d50 entries (`src/components/machine.zig` `buildUsbDevice`).
- button: `[button]` sections, `on_press`/`on_release` templates and their `notify_button_event` are not implemented (vendor `components/button.py`); only the notification name exists (`src/server/notify.zig`).
- power: `off_when_shutdown`, `on_when_job_queued`, `bound_services`, `restart_klipper_when_powered`, `restrict_action_processing` and `timer` are not parsed or acted on (`src/components/power.zig`).
- power: generic `http` devices have no `request_template`/`response_template`; status replies use a fixed on/off heuristic (`power.parseStatus`).
- wled: startup sends the initial state once; Moonraker first queries `{"v":true}` and retries failed strips for 120 s. HTTP sends make one attempt (Moonraker 3), and serial strips open the port per command without reading replies (`src/components/wled.zig`).
- td1: the `retrieve file` errors.txt handshake is not sent, so `error` is always null and a device is listed only after its first parsed line (Moonraker lists it with `td: null` once the handshake ends) (`src/components/td1.zig`).
- td1: `scan_time` is `YYYY-MM-DDTHH:MM:SSZ`; Moonraker's `datetime.now(tz=utc).isoformat() + "Z"` is `...SS.ffffff+00:00Z` (`src/components/td1.zig`).
- td1: `machine.td1.reboot` forgets the device without the `change settings` reboot handshake, and each scan reopens the port instead of keeping one reader per device (`src/components/td1.zig`).
- power and wled: a failed device request reports "Error Setting Device Status: <device> to <action>" (the requested action, where Moonraker names the resolved state) and "WLED: Error" without the exception text (`src/jsonrpc.zig` `errorReply`).
- power: the Klipper remote method `set_device_power` ignores `force`, so a locked device stays locked; Klipper remote calls run in order on one worker with a 16-call queue, where Moonraker runs each as its own task (`src/app.zig` `remoteMethodRequest`).
- Extension agents: `server.connection.identify` does not register `agent` clients, `server.extensions.list` is always empty, `server.extensions.request` is always `AgentNotConnected`, and `connection.register_remote_method`/`send_event` register nothing and emit no `notify_agent_event` (`src/components/extensions.zig`).
- klipper_estimator is never run: `server.analysis.estimate` and `process` check the gcodes file, then fail with `EstimatorNotAvailable`, as does `dump_config`; status reports `estimator_ready: false`. A runner must execute off the Core lock with a timeout (`src/components/analysis.zig`).
- PanelDue: no serial device, gcode queue or panel responses; `[paneldue]` only sets `enable_checksum` on the line parser, which nothing outside tests calls (`src/components/paneldue.zig`).
- File system observer: `[file_manager] file_system_observer` is ignored; changes made outside the API emit no `notify_filelist_changed` (`src/components/file_manager.zig`).
- `server.files.zip` writes no archive: it validates `dest` and returns the `zip_files` response shape; `std.zip` only extracts (`src/components/file_manager.zig` `handleZip`).
- OctoPrint select with `print=true` does not queue a job while printing: phobos has no `[file_manager] queue_gcode_uploads`, so it answers 409 Conflict like Moonraker with the upload queue disabled (`src/components/octoprint_compat.zig` `handleSelectFile`).

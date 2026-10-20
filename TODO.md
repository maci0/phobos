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

- `machine.reboot` and `machine.shutdown` remain no-ops. The daemon does not
  execute apt or pip.
- The Python-version fields remain a stub; phobos does not claim to run CPython.
- CAN discovery returns an empty list when unavailable rather than copying a
  printer-specific missing-device 500 error.
- Full Jinja2, LDAP and Apprise are outside the project scope. Estimator and
  package execution require injected runners; the daemon installs none.
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

## Implemented review work

The former audit items are implemented in the source below. These entries describe
code and fixture coverage, not a new physical-printer conformance run.

| Area | Implemented behavior and source |
| --- | --- |
| Announcements | Local development feeds and delayed handler notifications in [`announcements.zig`](src/components/announcements.zig). |
| Sensors | Parameter and history metadata, per-message replacement, one-second sampling and disconnect errors in [`sensor.zig`](src/components/sensor.zig). |
| MQTT | MQTT 3.1, 3.1.1 and 5, QoS acknowledgements, temporary subscription cleanup, credential templates and Klippy status publishing. See [MQTT](docs/MQTT.md). |
| Spoolman | Extrusion accounting, retained failed reports, configured sync intervals and active-spool validation on reconnect in [`spoolman.zig`](src/components/spoolman.zig). |
| Updates | Staged Web/ZIP installation, rollback and managed-service restarts. See [updates](docs/UPDATES.md). |
| Machine | Cached `usb.ids` lookup/download, V4L2 mode enumeration, CAN queries and provider polling. See [machine providers and peripherals](docs/MACHINE.md). |
| Power and buttons | Shutdown/queue hooks, services, timers, HTTP templates, forced internal calls and GPIO button actions. See [power and buttons](docs/POWER_BUTTONS.md). |
| WLED | State queries, startup retries, three HTTP attempts and retained serial connections in [`wled.zig`](src/components/wled.zig). |
| TD-1 | Persistent readers, errors-file and device-reboot handshakes, nullable initial readings and UTC timestamps in [`td1.zig`](src/components/td1.zig). |
| Device errors | Resolved power states and WLED error details in [`power.zig`](src/components/power.zig), [`wled.zig`](src/components/wled.zig) and [`jsonrpc.zig`](src/jsonrpc.zig). |
| Remote calls and agents | Independent owned remote tasks with 16 active calls and a 16-request queue; agent registration, bidirectional requests, remote methods and events in [`app.zig`](src/app.zig) and [`extensions.zig`](src/components/extensions.zig). |
| PanelDue | Serial I/O, bounded command queues, Klippy state and panel responses in [`paneldue.zig`](src/components/paneldue.zig). |
| Analysis | Manual estimate, post-process and config-dump operations through an injected runner, with private snapshots and joined deadlines. See [analysis](docs/ANALYSIS.md). |
| Files | Thumbnail files, atomic ZIP creation, external-change observation and upload/OctoPrint print queueing. See [file management](docs/FILE_MANAGEMENT.md). |
| Startup and webcams | One parsed configuration transferred to App; routed public-address URL resolution and local-listener conversion in [`main.zig`](src/main.zig), [`app.zig`](src/app.zig) and [`webcam.zig`](src/components/webcam.zig). |

## Remaining behavior limits

- `machine.peripherals.video` enumerates V4L2 modes, but `libcamera_devices` stays empty.
- `machine.update.status` leaves GitHub rate-limit telemetry null; the release
  request helper does not expose those response headers.
- Power backends without a native driver, including `tplink_smartplug` and
  `homeseer`, keep state in memory unless explicit HTTP URLs are configured.
- Authorization supports trusted IPs and CIDRs, but does not load
  reverse-DNS `trusted_domains` entries.
- Analysis has no default runner/download, automatic metadata post-processing
  or automatic ready-triggered config dump. See [analysis](docs/ANALYSIS.md).
- The template engine implements a bounded subset. See [MQTT](docs/MQTT.md) and
  [power and buttons](docs/POWER_BUTTONS.md) for the supported contexts and limits.

Hardware-specific behavior still needs verification on the configured devices.
Unit, loopback, pseudo-terminal and temporary-filesystem fixtures do not replace
that check. Historical measurements and printer captures retain their original
scope; this review does not refresh them.

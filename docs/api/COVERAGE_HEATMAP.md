## API Coverage Heatmap

| Component | Endpoints | Methods | Notifications | Surface | Depth | Combined |
|-----------|-----------|---------|---------------|---------|-------|----------|
| 🟢 announcements | 5/5 | 6/6 | 3/3 | 100% | 90% | 90% |
| 🟢 analysis | 4/4 | 4/4 | 0/0 | 100% | 95% | 95% |
| 🟢 authorization | 9/9 | 10/10 | 3/3 | 100% | 95% | 95% |
| 🟢 button | 0/0 | 0/0 | 1/1 | 100% | 85% | 85% |
| 🟢 common | 0/0 | 0/0 | 1/1 | 100% | 95% | 95% |
| 🟢 data_store | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 database | 8/8 | 9/9 | 0/0 | 100% | 95% | 95% |
| 🟢 extensions | 4/4 | 4/4 | 1/1 | 100% | 95% | 95% |
| 🟢 file_manager | 10/10 | 10/10 | 1/1 | 100% | 90% | 90% |
| 🟢 gcode_metadata | 0/0 | 0/0 | 0/0 | 100% | 95% | 95% |
| 🟢 history | 4/4 | 5/5 | 1/1 | 100% | 85% | 85% |
| 🟢 job_queue | 5/5 | 8/8 | 1/1 | 100% | 95% | 95% |
| 🟢 klippy_apis | 13/13 | 13/13 | 0/0 | 100% | 95% | 95% |
| 🟢 loghelper | 1/1 | 1/1 | 0/0 | 100% | 95% | 95% |
| 🟢 machine | 12/12 | 12/12 | 2/2 | 100% | 90% | 90% |
| 🟢 mqtt | 2/2 | 3/3 | 0/0 | 100% | 95% | 95% |
| 🟢 notifier | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 octoprint_compat | 10/10 | 0/0 | 0/0 | 100% | 95% | 95% |
| 🟢 power | 5/5 | 6/6 | 1/1 | 100% | 85% | 85% |
| 🟢 proc_stats | 1/1 | 1/1 | 2/2 | 100% | 95% | 95% |
| 🟢 sensor | 3/3 | 3/3 | 1/1 | 100% | 85% | 85% |
| 🟢 server | 3/3 | 3/3 | 4/4 | 100% | 95% | 95% |
| 🟡 spoolman | 3/3 | 4/4 | 2/2 | 100% | 60% | 60% |
| 🟢 td1 | 2/2 | 2/2 | 0/0 | 100% | 85% | 85% |
| 🟢 update_manager | 10/10 | 10/10 | 2/2 | 100% | 75% | 75% |
| 🟢 webcam | 3/3 | 3/3 | 1/1 | 100% | 90% | 90% |
| 🟢 websockets | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 wled | 6/6 | 7/7 | 0/0 | 100% | 90% | 90% |
| 🟢 zeroconf | 1/1 | 0/0 | 0/0 | 100% | 95% | 95% |

> **Overall weighted progress: ~94%**
>
> - **Surface**: API endpoint/method/notification shape coverage
> - **Depth**: how much of the internal implementation is real (not stubbed)
> - **Combined**: Surface × Depth — the effective completeness of each component
> - **Overall**: weighted by API item count per component
> - **Conformance**: 54/54 events pass normalized equality against vendored Moonraker 9008485
> - **Memory**: phobos daemon idle RSS ~1.4 MB (ReleaseSmall + LTO + stripped,
>   2 threads, binary ~1.2 MB). VmSize ~23 MB is reserved-but-uncommitted thread
>   stacks/arenas, not real RAM. vs stock Moonraker ~80-150 MB (Python/asyncio) —
>   roughly 50-90x less. (Measured via /proc/<pid>/status; down from a prior
>   5.4 MB after removing the eager 20 MiB Klippy ReadBuf, the proc_stat per-tick
>   leak, the sensor-ring memset, and building ReleaseSmall.)
> - **Tests**: 1185 pass / 2 skip / 0 fail (~205 fuzz)
> - **Fuzz**: every public JSON-RPC handler has both a unit test and a fuzz test
>
> Depth key:
> - **95%** — Fully implemented, matches Moonraker's real behavior exactly
> - **90%** — Fully implemented with edge-case coverage
> - **85%** — Fully functional, minor edge cases
> - **80%** — Mostly real, some stubs (e.g. webcam test endpoint)
> - **75%** — Core real, secondary integration stubbed (e.g. machine host-mutating actions are no-ops)
> - **70%** — Real I/O for main paths, secondary paths stubbed (e.g. machine peripherals)
> - **65%** — Real core logic, external integration deferred
> - **60%** — Real HTTP/parsing, protocol-specific stubs (e.g. spoolman websocket)
>
> P3 blockers (require hardware/external services):
> - power: DONE — HTTP-URL devices send real GET requests; `type: gpio` devices
>   drive the line via the sysfs GPIO driver (`gpio_sysfs.zig`, active-low aware),
>   unit-tested against a temp-dir controller root. Other vendor types remain in-memory.
> - td1: DONE (serial) — `serial.zig` + `parseTd1Line` (CSV, matches td1.py
>   `_parse_line`) read TD/color over the UART via `pollSerialOnce`. Parser
>   unit-tested; on-hardware USB hotplug/timing unverified (no device).
> - announcements: ETag conditional GET DONE — http_get.zig uses the lower-level
>   std.http.Client.request API to read the ETag response header and send
>   If-None-Match, so the 30-min RSS refresh skips unchanged feeds (304). The old
>   "FetchResult header limitation" no longer blocks this.
> - spoolman: proxy is a per-request user-driven forwarder (no server-side cache),
>   so ETag does not apply; the shared http_get helper is available if a cached
>   path is added later
> - sensor: DONE — MQTT source. ingestMqttMessage parses a JSON payload into
>   measurements (Moonraker's only built-in sensor type is MQTT). Live path:
>   MqttClient reader → MqttCtx.on_message → app bridge → core.run → sensor
>   ingest (under the Core lock); topics subscribed on connect. Hook firing
>   validated over a real socket. (Direct JSON-field mapping, not Jinja
>   state_response_template.)
> - mqtt: DONE — real MQTT 3.1.1 TCP client (mqtt_proto codec + mqtt_client),
>   CONNECT/CONNACK/PUBLISH/SUBSCRIBE/PUBACK/PING, LWT, live publish wired into
>   MqttCtx (connectBroker + background reader), connects at startup when a
>   broker is configured. Validated over a real socket against an in-tree broker
>   double. Remaining P3: TLS, automatic reconnect/backoff, JSON-RPC-over-MQTT
>   request dispatch.
> - klippy_apis: DONE — real Klippy handshake (info/poll/subscribe with
>   response_template), is_remote proxied endpoints (printer.info, objects.*,
>   gcode.script/help, query_endstops.status), validated end-to-end against a
>   live Klippy (native linux host MCU) via the gated integration test
> - wled: DONE — address strips use HTTP POST to the WLED JSON API; serial strips
>   write newline-terminated JSON to the character device via `serial.zig`
>   (setStripSerial), unit-tested against a temp file.
>
> Non-goals (intentionally not implemented — not counted against parity):
> - **LDAP auth source** (`ldap.py`): out of scope. phobos supports only the
>   `moonraker` auth source. `source: "ldap"` logins are unsupported; the auth DB
>   keeps the `source` field for shape parity only.
> - **machine.reboot / machine.shutdown host action**: deliberate no-ops (return
>   the "ok" shape without touching the host) — printer boards lack systemd and a
>   stray call must never power-cycle the box.
> - **apt/pip system package updates** (update_manager non-git sources): emit
>   notifications but never invoke the host package manager.

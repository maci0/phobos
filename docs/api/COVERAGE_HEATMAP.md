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
| 🟢 gcode_metadata | 0/0 | 0/0 | 0/0 | 100% | 90% | 90% |
| 🟢 history | 4/4 | 5/5 | 1/1 | 100% | 85% | 85% |
| 🟢 job_queue | 5/5 | 8/8 | 1/1 | 100% | 90% | 90% |
| 🟢 klippy_apis | 13/13 | 13/13 | 0/0 | 100% | 90% | 90% |
| 🟢 loghelper | 1/1 | 1/1 | 0/0 | 100% | 95% | 95% |
| 🟢 machine | 12/12 | 12/12 | 2/2 | 100% | 75% | 75% |
| 🟢 mqtt | 2/2 | 3/3 | 0/0 | 100% | 90% | 90% |
| 🟢 notifier | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 octoprint_compat | 10/10 | 0/0 | 0/0 | 100% | 95% | 95% |
| 🟡 power | 5/5 | 6/6 | 1/1 | 100% | 70% | 70% |
| 🟢 proc_stats | 1/1 | 1/1 | 2/2 | 100% | 95% | 95% |
| 🟡 sensor | 3/3 | 3/3 | 1/1 | 100% | 65% | 65% |
| 🟢 server | 3/3 | 3/3 | 4/4 | 100% | 95% | 95% |
| 🟡 spoolman | 3/3 | 4/4 | 2/2 | 100% | 60% | 60% |
| 🟡 td1 | 2/2 | 2/2 | 0/0 | 100% | 50% | 50% |
| 🟢 update_manager | 10/10 | 10/10 | 2/2 | 100% | 65% | 65% |
| 🟡 webcam | 3/3 | 3/3 | 1/1 | 100% | 80% | 80% |
| 🟢 websockets | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 wled | 6/6 | 7/7 | 0/0 | 100% | 80% | 80% |
| 🟢 zeroconf | 1/1 | 0/0 | 0/0 | 100% | 95% | 95% |

> **Overall weighted progress: 88% → ~92%**
>
> - **Surface**: API endpoint/method/notification shape coverage
> - **Depth**: how much of the internal implementation is real (not stubbed)
> - **Combined**: Surface × Depth — the effective completeness of each component
> - **Overall**: weighted by API item count per component
> - **Conformance**: 54/54 events pass normalized equality against vendored Moonraker 9008485
> - **Memory**: phobos daemon RSS ~5.4 MB vs stock Moonraker ~80-150 MB (1 thread, VmSize 7992 kB)
> - **Tests**: 1104 pass / 2 skip / 0 fail (lmdb), 1089 pass / 5 skip / 0 fail (no-lmdb)
> - **Fuzz**: every public JSON-RPC handler has both a unit test and a fuzz test
>
> Depth key:
> - **95%** — Fully implemented, matches Moonraker's real behavior exactly
> - **90%** — Fully implemented with edge-case coverage
> - **85%** — Fully functional, minor edge cases
> - **80%** — Mostly real, some stubs (e.g. webcam test endpoint)
> - **75%** — Core real, major integration stubbed (e.g. MQTT client, Klippy bridge)
> - **70%** — Real I/O for main paths, secondary paths stubbed (e.g. WLED serial, machine peripherals)
> - **65%** — Real core logic, external integration deferred
> - **60%** — Real HTTP/parsing, protocol-specific stubs
> - **50%** — In-memory state tracking with notification emission, all hardware I/O stubbed
>
> P3 blockers (require hardware/external services):
> - power: GPIO device control (HTTP URLs send real GET requests via `std.http.Client`; GPIO still stubbed pending platform driver)
> - td1: UART communication
> - announcements: ETag conditional GET DONE — http_get.zig uses the lower-level
>   std.http.Client.request API to read the ETag response header and send
>   If-None-Match, so the 30-min RSS refresh skips unchanged feeds (304). The old
>   "FetchResult header limitation" no longer blocks this.
> - spoolman: proxy is a per-request user-driven forwarder (no server-side cache),
>   so ETag does not apply; the shared http_get helper is available if a cached
>   path is added later
> - sensor: MQTT/Klippy sensor integration
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
> - wled: serial-only strip communication (HTTP POST to WLED JSON API is real for address-based strips)

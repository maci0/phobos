# MQTT

`[mqtt]` connects to `address`, using `mqtt_protocol: v3.1.1` by default.
`v3.1` and `v5` select those wire protocols. Invalid versions disable the
component with a startup warning. MQTT 3.1 requires an alphanumeric client ID
of 1 to 23 bytes; an omitted or empty `client_id` gets a generated 22-byte ID.
The ID remains stable across reconnects in that process. TLS uses the system
certificate bundle and verifies the broker host name.

`server.mqtt.publish` waits for PUBACK at QoS 1 and PUBCOMP at QoS 2. An omitted
`timeout` waits until completion or disconnect. A nonpositive timeout expires
immediately. A finite timeout covers the write and acknowledgement; expiry
closes that session before its packet ID can be reused. QoS 0 completes after
the write. `server.mqtt.subscribe` removes its broker subscription after its
last request returns, including timeout and cancellation. Sensor subscriptions
and the API request subscription remain active.

The client bounds its acknowledgement window to 32 packets and inbound packets
to 8 MiB. MQTT 5 also enforces the broker's receive maximum, maximum QoS,
retain availability and maximum packet size, and uses its server keepalive.
Shutdown gives retained offline publication and DISCONNECT a one-second budget,
then cancels pending requests and closes the socket. The offline Last Will
covers an interrupted close.

## Credentials

`username` and `password` render through the same bounded template subset used
by sensor templates. For example:

```ini
[mqtt]
address: broker.lan
username: {secrets.mqtt.username}
password: {secrets.mqtt.password}
```

Secrets come from `<data_path>/moonraker.secrets`. If that is not a regular
file, `[secrets] secrets_path` provides a fallback. JSON objects and INI sections
are supported. INI keys are lowercase, default values inherit from `[DEFAULT]`,
and inline `#` and `;` characters remain literal. Object lookup also supports
`secrets.get('key', default)`. Rendered credentials are stripped of surrounding
whitespace. Full Jinja2 remains outside the template subset.

The deprecated `password_file` reads and strips a UTF-8 file. When both options
exist, the file is checked first and the `password` template takes precedence.
A password without a username is not sent in CONNECT. `~` and `~/...` expand
from the startup HOME directory; named-user home paths are rejected.

Credential files are limited to 1 MiB. INI default expansion is limited to
4,096 entries and 1 MiB of copied key/value text. Invalid secrets formats
produce a warning and empty secrets, matching Moonraker; read, size and
allocation failures disable MQTT rather than silently dropping credentials.

## Klippy status

```ini
[mqtt]
address: broker.lan
status_objects:
  extruder=temperature,target
  heater_bed
status_interval: 0.5
publish_split_status: false
```

Each line selects an object. An omitted equals sign selects all fields; an
empty value after equals selects no fields. `status_interval` defaults to zero
for immediate updates; an explicitly configured interval must exceed 0.25
seconds. Timed updates merge changed fields and keep the last event time.
The initial subscribed snapshot is included. A physical Klippy disconnect
flushes pending status; shutdown and error states continue to publish while
Klippy remains connected. Updates received while MQTT is disconnected drop.

The default topic is `<instance>/klipper/status` with
`{"eventtime": ..., "status": {...}}`, without retention. With
`publish_split_status: true`, each field uses the retained topic
`<instance>/klipper/state/<object>/<field>` and
`{"eventtime": ..., "value": ...}`. Both modes use `default_qos`.

Status handlers copy selected fields into a queue; a joined worker performs
broker I/O outside Core. Each snapshot and merged cache is limited to 64 KiB.
The pending queue holds up to 32 updates and 256 KiB, plus a disconnect marker.
Rejected updates are logged. Persistent sensor filters are limited to 128
filters and 64 KiB of topic text. Concurrent one-shot subscription waits are
limited to 16. Finite request timeouts above one day are capped to keep
platform deadlines representable.

Loopback broker tests cover all protocol versions, QoS acknowledgement and
timeout behavior, shared subscription cleanup, retained status topics,
initial snapshots, timed merges, disconnect flushes and bounded shutdown.

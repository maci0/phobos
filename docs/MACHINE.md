# Machine providers and peripherals

Service operations use the configured provider and its discovered allow-list.
`machine.reboot` and `machine.shutdown` remain no-ops.

The daemon calls `MachineCtx.startServicePolling` after runtime I/O is wired.
The existing proc-stat worker polls systemd and supervisord every two ticks,
invalidates cached system information on a change, and emits
`notify_service_state_changed` with one service object in the params array.
Tests call `pollServices` synchronously with an injected command runner.

`MachineCtx.serviceAction` acquires Core for callers outside the dispatcher.
`serviceActionLocked` requires its caller to hold Core after runtime starts.
Provider commands release Core while waiting. A separate provider mutex orders
actions and polls; acquiring it also releases Core so another action can finish.
Both APIs accept the typed `ServiceAction` enum and enforce the same service
validation as the HTTP endpoints.

The supervisord provider preserves lowercased sub-state names. `running` is
active, `stopping` is deactivating, and other reported states are inactive.
`supervisorctl status` exit code 3 is accepted for stopped programs.

Video devices enumerate formats and discrete resolutions with typed
`VIDIOC_ENUM_FMT` and `VIDIOC_ENUM_FRAMESIZES` structures through
`std.Io.operate(.device_io_control)`. Each list is capped at Moonraker's 128
entries. Modes with no discrete resolutions are omitted. Descriptions must be
UTF-8; the fourcc decoder drops non-ASCII bytes like Moonraker.

CAN discovery sends Klipper's unassigned-node query (admin ID `0x3f0`, command
`0x00`) and collects replies for two seconds. It returns UUIDs and Klipper,
Katapult, or Unknown application names, up to 256 replies. Calls are serialized
and run outside Core. Unavailable interfaces still return an empty list.

`std.Io.net.Interface.Name.resolve` finds the interface index. Zig 0.17 exposes
no SocketCAN constructor or address variant, so only socket creation and bind
use libc with the typed Linux `sockaddr_can` layout. Reads, writes, deadlines,
and close use `std.Io`. Unit tests exchange the native CAN frames over loopback
datagrams; no test opens a hardware CAN interface.

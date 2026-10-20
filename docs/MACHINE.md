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

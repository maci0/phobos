# Software updates

Update commands run outside Core and serialize through the update manager's
command mutex. Printing or an existing update rejects a new mutation. Git fetches
and local commands have complete process deadlines.

Git and zip sources read `managed_services`; accepted values are the updater's
own name, `klipper`, and `moonraker`. Without that option, an allowed own service
is managed unless `is_system_service: false`. Web clients manage no services.
Successful Git changes, recovery and rollback restart managed services through
the machine provider after releasing the command mutex. An unchanged Git update
does not restart services. Provider failures reach the update caller.

The daemon installs no package runner. Apt and pip commands require an injected
runner and are never executed by default. Machine reboot and shutdown remain
deliberate no-ops.

Automatic refresh windows use the host's local timezone, including DST rules
beyond the final TZif transition. The C `localtime_r` adapter owns the platform
time types; see [standard library choices](STDLIB.md).

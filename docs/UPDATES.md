# Software updates

Update commands run outside Core and serialize through the update manager's
command mutex. Printing or an existing update rejects a new mutation. Git fetches
and local commands have complete process deadlines.

Git and zip sources read `managed_services`; accepted values are the updater's
own name, `klipper`, and `moonraker`. Without that option, an allowed own service
is managed unless `is_system_service: false`. Web clients manage no services.
Successful Git or ZIP changes, recovery and rollback restart managed services through
the machine provider after releasing the command mutex. An unchanged Git update
does not restart services. Provider failures reach the update caller.

Web and ZIP sources read their installed `release_info.json`. Fluidd and Mainsail
web installs can instead use `.version` with their manifest. The configured repo
must match the bundle identity. Refresh selects a GitHub release ZIP, respecting
the installed `asset_name` when present. Updates first use Moonraker's cached
`remote_version` and `dl_info`, so an existing cached asset needs no API refresh.

Downloads stream to a private sibling directory with a two-minute deadline and
a 128 MiB compressed-size limit. Extraction uses `std.zip`, verifies CRC32, and
limits output to 512 MiB and 16,384 entries. Absolute paths, traversal, backslashes,
Git directories, duplicate files, links and special file types are rejected.
Regular-file permission bits retain executability and discard special bits.
`persistent_files` accepts relative paths; existing regular files and directories
are copied without following links. Release metadata cannot be preserved over
the new bundle. Missing persistent files keep the bundle's defaults.

The complete staged directory replaces the installed directory with same-parent
renames. A failed publish restores the current install and its prior backup.
The previous install remains at `.<directory>.phobos-rollback`; rollback swaps
the two validated versions without downloading or contacting GitHub. Service
failure leaves the installed version and backup available and returns an error.
This is a directory replacement with a brief rename gap, not a filesystem
transaction across power loss. An unrecoverable rename failure retains the
private staging directory for repair rather than deleting an original copy.

All download, extraction, install, rollback and service tests use loopback HTTP,
owned temporary directories, temporary Git repositories, or injected callbacks.

The daemon installs no package runner. Apt and pip commands require an injected
runner and are never executed by default. Machine reboot and shutdown remain
deliberate no-ops.

Automatic refresh windows use the host's local timezone, including DST rules
beyond the final TZif transition. The C `localtime_r` adapter owns the platform
time types; see [standard library choices](STDLIB.md).

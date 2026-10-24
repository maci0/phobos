<p align="center">
  <img src="assets/logo.svg" alt="phobos" width="520">
</p>

# phobos

A Zig 0.17 reimplementation of [Moonraker](https://github.com/Arksine/moonraker), the API
server for [Klipper](https://www.klipper3d.org/) 3D printers. It aims to match Moonraker's
API exactly while idling in a few megabytes of RAM on 32-bit ARM printer hosts.

> phobos is the smaller, faster of Mars' two moons.

## Why

Moonraker is about 36k lines of Python on asyncio and Tornado. On a printer-class host it
brings the Python runtime, an event loop, and a heap that grows with load. phobos serves the
same HTTP, WebSocket, and JSON-RPC endpoints and notifications from one static musl binary
with bounded buffers, sized for a Cortex-A7.

## Status

The coverage gate checks registered endpoint paths, JSON-RPC method names and
notification names against Moonraker `900848584374`. It does not prove behavioral
parity. The [per-call API table](docs/api/API_COVERAGE.md) records implemented,
partial and missing behavior; [TODO.md](TODO.md) records completed work and
remaining limits.

The live paths include the Klippy bridge, SQLite persistence, HTTP and WebSocket
transports, MQTT 3.1/3.1.1/5, Spoolman accounting, RSS feeds, GPIO buttons,
PanelDue, extension agents, and selected power, WLED and TD-1 drivers. Git and
Web/ZIP updates can replace configured installations. Host reboot and shutdown
remain no-ops; package execution requires an injected runner. Full Jinja2, LDAP
and Apprise are out of scope.

Use `--compat forge-x` to enable Forge-X upload conversion, stock print macros
and update behavior. Native [timelapse](docs/TIMELAPSE.md) and Feather support
load from their configuration sections. The separate [Forge-X tracker](docs/api/FORGE_X.md)
records implemented behavior and hardware checks still needed. The default
profile remains `moonraker`; existing installations are not switched automatically.

[Memory measurements](docs/MEMORY.md) and [load-test results](docs/PERFORMANCE.md)
compare v0.2.3 with Moonraker in fresh Forge-X
printer probes and an isolated KVM guest, with metric directions, trial ranges
and measured scheduling limits. Published-release captures remain archived.
The latest release is
[v0.3.0](docs/releases/v0.3.0.md).

## Architecture

Networking is `std.Io.net` on the `std.Io.Threaded` backend, the only standard I/O backend
available on 32-bit ARM. The listener spawns a task per connection, and `std.http` handles
HTTP and WebSocket on those streams. Every transport feeds one JSON-RPC dispatcher backed by
a runtime method table. The Core mutex serializes shared state and notification fan-out.
Blocking network and process work runs outside Core; concurrent read paths use component
locks. Persistence defaults to a vendored SQLite database in Moonraker's
`moonraker-sql.db` format; a pure-Zig file backend is selectable with
`[database] backend`. See [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Repository layout

```
build.zig                 build graph (musl by default, cross-target options)
src/
  main.zig                entry point, --dump-api, schema
  app.zig                 App: wires components; registerAll() registers methods
  io.zig                  std.Io.Threaded listener and accept loop
  jsonrpc.zig             JSON-RPC 2.0 dispatcher and error codes
  http_transport.zig      HTTP/REST and /server/jsonrpc over std.http
  transport/ws.zig        WebSocket transport over std.http
  server/                 serialized core, connections, notify bus, registry
  config/                 confighelper-compatible parser
  store/                  DataStore interface, SQLite and atomic-rename file backends
  core/methods.zig        server.info, server.config
  components/             one module per Moonraker component
  oracle/                 in-process response-key and error-code checks
  testutil/               TestServer, HTTP and WebSocket test clients
vendor/sqlite/            pinned SQLite amalgamation
vendor/moonraker/         gitignored Moonraker reference checkout
api/api_surface.json      generated Moonraker API baseline
conformance/              golden captures, normalization and replay against Moonraker
tools/api_scanner/        Moonraker API extractor, drift and coverage checks
tools/client_api_scanner/ client call scanner (Mainsail, Fluidd, KlipperScreen, GuppyScreen, HelixScreen)
tools/perf_harness/       phobos vs Moonraker load tests and profiling
scripts/                  release matrix and memory measurement
docs/                     API surface, coverage, memory, performance, release notes
TODO.md                   status and remaining work
```

## Quick start

Requires Zig 0.17.0, plus `uv` for the Python tooling. The default build compiles
SQLite 3.54.1 from the verified amalgamation in `vendor/sqlite/`.

```sh
# Test suite (musl-static by default)
scripts/test.sh Debug

# Print the API surface phobos registers
zig build && zig-out/bin/phobos --data-path "$PWD/.scratch/api-dump-data" --dump-api | less
zig-out/bin/phobos schema

# API coverage against the Moonraker baseline (exit 0 means 100%)
tools/coverage.sh

# Static binary for the Cortex-A7 target
zig build -Dtarget=arm-linux-musleabihf -Dcpu=cortex_a7 -Doptimize=ReleaseFast

# Build and validate the Linux release matrix in isolated scratch prefixes
scripts/build-release.sh
```

Some hosts, the deploy target included, cannot link their system glibc with Zig 0.17, so
the build targets musl. Do not run a glibc `zig build`.
The [build guide](docs/BUILDS.md) lists ARMv6, ARMv7 floating-point variants,
Cortex-A7, AArch64, x86-64 and AD5X MIPS assets, their CPU requirements and verification scope.

## Printer installation

Start with an existing firmware installation and keep its Klipper and web UI.
Choose the guide for your firmware and model:

| Firmware and printer | Status | Guide |
| --- | --- | --- |
| Forge-X, AD5M / AD5M Pro | Production deployment and API service startup checked on a real AD5M | [Install and select phobos at boot](#run-on-a-forge-x-printer) |
| Z-Mod, AD5M / AD5M Pro | Experimental read-only trial; production compatibility incomplete | [Isolated Z-Mod trial](#try-on-a-z-mod-ad5m-printer) |
| Z-Mod, AD5X | Experimental MIPS build; hardware and production compatibility unverified | [Build the AD5X binary](#build-for-a-z-mod-ad5x) |

Other models need their CPU/kernel and firmware integration checked separately.
Native camera/parking/print-macro workflows retain the limits in the
[Forge-X tracker](docs/api/FORGE_X.md).

### Download the AD5M binary

For the FlashForge Adventurer 5M/5M Pro in either guide, use the Cortex-A7
asset `phobos-v0.3.0-arm-linux-musleabihf`. Other Klipper hosts should select
their architecture from the [build guide](docs/BUILDS.md). The binary includes
SQLite and needs no Zig compiler or Python runtime on the printer. Native
timelapse rendering needs an installed FFmpeg; see [timelapse](docs/TIMELAPSE.md).

Download and verify the release on your computer, then follow your firmware's
transfer instructions below. Keep files on persistent storage; `/tmp` is a
small RAM filesystem on these printers.

```sh
set -eu
mkdir -p .scratch/install-v0.3.0
cd .scratch/install-v0.3.0
curl -fLO https://github.com/maci0/phobos/releases/download/v0.3.0/phobos-v0.3.0-arm-linux-musleabihf
curl -fLO https://github.com/maci0/phobos/releases/download/v0.3.0/SHA256SUMS
grep '  phobos-v0.3.0-arm-linux-musleabihf$' SHA256SUMS | sha256sum --check -
```

### Run on a Forge-X printer

From the directory containing the [verified download](#download-the-ad5m-binary),
copy it to the printer. Replace the example SSH address with your printer's
address.

```sh
cat phobos-v0.3.0-arm-linux-musleabihf | ssh root@192.168.0.150 \
  'test ! -e /data/phobos-v0.3.0 && cat > /data/phobos-v0.3.0.new && chmod 755 /data/phobos-v0.3.0.new && mv /data/phobos-v0.3.0.new /data/phobos-v0.3.0'
```

Wait until printing and calibration finish and heater targets are zero. Stop
the existing API daemon before using port 7125 or its database. On an unmodified
Forge-X installation, stop only Moonraker with
`chroot /data/.mod/.forge-x /opt/config/mod/.root/S65moonraker stop`.
For an existing phobos installation, stop its supervisor or send SIGTERM to its
verified daemon PID and wait for it to exit. Confirm the old listener has stopped.
Never use `.root/forge-x restart`: it reboots the board.

With the API daemon stopped, preserve its executable and launcher, and copy
`moonraker-sql.db` plus any `-wal` and `-shm` files from
`/root/printer_data/database/` inside the chroot to a new backup directory on
persistent storage. Keep the configuration backup private because it may
contain credentials. Do not run two daemons against this database.

Run phobos from an SSH session on the printer:

```sh
chroot /data/.mod/.forge-x /data/phobos-v0.3.0 \
  --compat forge-x -d /root/printer_data
```

This loads `/root/printer_data/config/moonraker.conf`, follows its includes,
opens `/root/printer_data/database/moonraker-sql.db` and uses the configured
host and port. Preserve Forge-X's `[file_manager] file_system_observer: none`:
its kernel lacks inotify. Keep the existing authorization settings. Fluidd
continues to use `http://<printer-address>:7125`.

For the existing `/data/phobos-run.sh` installation, its launcher body is:

```sh
#!/bin/sh
exec /data/phobos-v0.3.0 --compat forge-x -d /root/printer_data >> /data/logFiles/phobos.log 2>&1
```

Run that launcher with
`nohup chroot /data/.mod/.forge-x /data/phobos-run.sh </dev/null >/data/phobos-start.log 2>&1 &`
after stopping the foreground instance. This command starts phobos for the
current boot; it does not install a boot service.
Check `/server/info` for `klippy_state: "ready"`, no failed components and no
warnings, then check Fluidd's temperatures, files and console. Logs are in
`/data/logFiles/phobos.log`; `-o json --version` reports the package version.

Forge-X's stock `/opt/config/mod/.root/S65moonraker` still launches Moonraker
after a reboot. Updating `/data/phobos-run.sh` alone does not change that.
To select phobos at boot, first back up `S65moonraker`, then replace its
`start-stop-daemon` launch line inside `start()` with:

```sh
start-stop-daemon -S -o -b -m -p "$PID_FILE" -O /data/logFiles/phobos.log --exec /data/phobos-v0.3.0 -- --compat forge-x -d "$PRINTER_DATA"
```

Keep the surrounding Forge-X configuration setup and stop/PID-file handling.
The daemon helper must match the binary directly: a shell launcher replaces
itself with phobos, so matching the launcher path would miss a running daemon.
`-o` makes an already-running daemon a successful no-op. After stopping any
manually started instance, activate the service with
`chroot /data/.mod/.forge-x /opt/config/mod/.root/S65moonraker start`.
Update the versioned path in both the service and manual launcher on future
upgrades. Forge-X updates may restore the stock service; check the boot selection
after updating Forge-X. This service starts the API daemon without rebooting
the printer board.

To roll back, stop phobos, restore the saved launcher/executable and restart
the previous API daemon. If database rollback is needed, first preserve the
failed installation's database files, then restore the stopped backup and its
matching WAL/SHM files together. Never restore a database while a daemon uses it.

### Try on a Z-Mod AD5M printer

This is an isolated read-only installation for **AD5M / AD5M Pro**, based on
inspection of [Z-Mod 1.7.4](https://github.com/ghzserg/zmod/releases/tag/1.7.4).
It has not been run on Z-Mod hardware. The [official chroot instructions](https://wiki.zmod.link/Plugin/#example-installing-led_effect)
use `/data/.mod/.zmod` on AD5M, rather than Forge-X's `.forge-x` directory.
AD5X uses a different path and MIPS binaries; do not install an ARM asset there.

Production replacement is not supported yet. Z-Mod selects `_PRINT_FILE` or
`_ZSDCARD_PRINT_FILE` according to its screen mode; phobos v0.3.0 has different
print-start selection. `--compat forge-x` does not implement Z-Mod behavior,
and there is no `--compat zmod` profile. Its plugin, timelapse, update and
service integrations also need separate validation. Existing in-process
Moonraker Python components cannot be loaded by phobos.

Wait for printing/calibration to finish and heater targets to reach zero. Keep
Z-Mod's Moonraker running on 7125. The trial uses loopback 7126 and a new private
database; do not point it at `/root/printer_data` or the live database. Do not
start a print, move axes, heat, update firmware or use printer power actions
through the trial.

Complete the shared [download and checksum step](#download-the-ad5m-binary).
From the directory containing that verified file, use this Z-Mod transfer
command:

```sh
cat phobos-v0.3.0-arm-linux-musleabihf | ssh root@192.168.0.150 '
  set -eu
  case "$(uname -m)" in armv7l) ;; *) echo "AD5M ARMv7 required" >&2; exit 1 ;; esac
  trial=/data/.mod/.zmod/root/phobos-trial-v0.3.0
  test -x /data/.mod/.zmod/bin/sh
  test ! -e "$trial"
  mkdir -m 700 "$trial"
  cat > "$trial/phobos"
  chmod 700 "$trial/phobos"
'
```

Replace the SSH address with your printer's address. Check free disk space
first; this uses persistent chroot storage rather than the printer's small
`/tmp` RAM filesystem. In an SSH session on the printer, create the private
configuration and run the trial in the foreground:

```sh
set -eu
zmod_root=/data/.mod/.zmod
trial=/root/phobos-trial-v0.3.0
cat > "$zmod_root$trial/probe.cfg" <<'CFG'
[server]
host: 127.0.0.1
port: 7126
klippy_uds_address: /tmp/uds

[file_manager]
file_system_observer: none

[authorization]
trusted_clients: 127.0.0.1

[database]
path: /root/phobos-trial-v0.3.0/database/moonraker-sql.db
CFG
chroot "$zmod_root" "$trial/phobos" --compat moonraker \
  -c "$trial/probe.cfg" -d "$trial"
```

From a second terminal on your computer, make read-only requests through SSH
(the printer needs `wget`):

```sh
ssh root@192.168.0.150 'wget -q -T 5 -O - http://127.0.0.1:7126/server/info'
ssh root@192.168.0.150 'wget -q -T 5 -O - "http://127.0.0.1:7126/printer/objects/query?print_stats=state&extruder=target&heater_bed=target"'
```

Check that Klippy is ready, the status matches the production UI, and there are
no failed components or warnings. Stop with Ctrl+C in the foreground session
and wait for phobos to exit. Confirm 7126 no longer responds and production
Moonraker still works on 7125. The private trial directory can then be removed;
no production configuration or database restore is needed.

Do not copy the Forge-X boot-service edit to Z-Mod. Its service path and startup
work differ, including SQLite setup. Z-Mod's [configuration guidance](https://wiki.zmod.link/FAQ/#configuration-storage)
also warns that edits to vendor/plugin files can break updates. Keep its boot
service and live database untouched until the missing compatibility work is
implemented and verified.

### Build for a Z-Mod AD5X

The `ad5x-mipsel` profile targets little-endian MIPS32r5 with the o32 hard-float
ABI, 64-bit FPU registers and NaN2008. These requirements match the ELF ABI
attributes of Z-Mod 1.7.4's AD5X executables. Build from the current source with
Zig 0.17.0:

```sh
scripts/build-release.sh --output .scratch/ad5x-build ad5x-mipsel
scripts/build-release.sh --verify-only --output .scratch/ad5x-build ad5x-mipsel
```

The output is `.scratch/ad5x-build/phobos-v0.3.0-mipsel-linux-musleabihf`, with
`SHA256SUMS` and `profiles.tsv`. CI includes this profile; the published v0.3.0
release predates it and has no MIPS asset. See the [build guide](docs/BUILDS.md#ad5x-mips)
for a direct Zig command and verification limits.

No AD5X hardware run has been performed. The Z-Mod print-macro and integration
gaps above still apply. Its chroot is `/usr/data/.mod/.zmod`, so the AD5M trial
paths and ARM download commands do not apply. Keep its production Moonraker,
boot service and live database unchanged until an isolated hardware trial passes.

## Tracking Moonraker

phobos tracks Moonraker 9008485, checked out in `vendor/moonraker` (gitignored). After
bumping that checkout, the drift check exits 1 if the API changed:

```sh
git clone https://github.com/Arksine/moonraker vendor/moonraker
git -C vendor/moonraker checkout 900848584374
PYTHONPATH=tools uv run --with tree-sitter --with tree-sitter-python \
  python -m api_scanner diff --source vendor/moonraker/moonraker --baseline api/api_surface.json
```

## Documentation

Change and verification history: [`docs/PROVENANCE.md`](docs/PROVENANCE.md).

- [`TODO.md`](TODO.md): implemented work and remaining behavior limits.
- [`DEVELOPMENT.md`](DEVELOPMENT.md): building, testing, adding a component.
- [`docs/BUILDS.md`](docs/BUILDS.md): static Linux release profiles and host selection.
- [`docs/CI.md`](docs/CI.md): automated tests, native/cross builds and tag-based releases.
- [`docs/api/API_SURFACE.md`](docs/api/API_SURFACE.md): the Moonraker API phobos must match.
- [`docs/api/COVERAGE_HEATMAP.md`](docs/api/COVERAGE_HEATMAP.md): coverage method and verification limits.
- [`docs/MEMORY.md`](docs/MEMORY.md), [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md): measurements and how to reproduce them.
- [`docs/STDLIB.md`](docs/STDLIB.md): Zig 0.17 std APIs in use and where local code remains.
- [`docs/FILE_MANAGEMENT.md`](docs/FILE_MANAGEMENT.md): file and thumbnail contracts.
- [`docs/MACHINE.md`](docs/MACHINE.md): service providers and peripheral queries.
- [`docs/UPDATES.md`](docs/UPDATES.md): managed services, release installation and rollback.
- [`docs/MQTT.md`](docs/MQTT.md): protocols, credentials, QoS and Klippy status topics.
- [`docs/POWER_BUTTONS.md`](docs/POWER_BUTTONS.md): power hooks, HTTP templates and GPIO buttons.
- [`docs/ANALYSIS.md`](docs/ANALYSIS.md): injected estimator execution, ownership and file safety.
- [`docs/TEST_RUN_FINDINGS.md`](docs/TEST_RUN_FINDINGS.md): why Moonraker's own test suite cannot be the parity oracle.

## License

[GPL-3.0-only](LICENSE), matching Moonraker. SQLite is public domain.

For private vulnerability reports, see [SECURITY.md](SECURITY.md).

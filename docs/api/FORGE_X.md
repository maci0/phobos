# Forge-X compatibility tracker

Forge-X has a separate source baseline in
[`api/forge_x_surface.json`](../../api/forge_x_surface.json). The upstream
baseline stays [`api/api_surface.json`](../../api/api_surface.json), and its
coverage gate still requires 100% registered-name coverage. Neither baseline
proves matching request validation, responses, side effects or event ordering.

## Compared revisions

Initial comparison date: 2026-10-24. Phobos source and API dump: v0.2.3,
`0f21ca77c7c1e8375c97cc5872a451b68b6a23c6`.
The implementation and runtime coverage below ship in v0.3.0; profile-specific
behavior requires `--compat forge-x` where noted.

| Source | Revision | Scope |
| --- | --- | --- |
| Upstream Moonraker | [`9008485843740c93e0154ccbdac1fc2b02b03aaa`](https://github.com/Arksine/moonraker/tree/9008485843740c93e0154ccbdac1fc2b02b03aaa/moonraker) | Phobos's existing vendor pin, API 1.5.0. |
| Forge-X | [`f2c3f272d6e27400818a514d9d31d754eeb1b5e3`](https://github.com/DrA1ex/ff5m/tree/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker) | The `1.4.2` branch, `.root/moonraker`, API 1.4.0. `main` is a different release line. |
| Historical upstream reference | [`d4d2074466c834532b46c965beb233f6341e493a`](https://github.com/Arksine/moonraker/tree/d4d2074466c834532b46c965beb233f6341e493a/moonraker) | Upstream at 2025-01-24, the date Forge-X first tracked `.root/moonraker/server.py`. This is a dated reference, not a proven fork point. |

The Forge-X source archive SHA256 is
`9816949151eac0b7ae69843a8000dc3ea73950337bde6e7d58747fdaf828f75a`.
The historical upstream archive SHA256 is
`0d4db0005107ec1f76f0032dadfd47aade95bb19f0075ddcd4de504de188257a`.
Archive URLs use the full revisions above on `codeload.github.com`.
The Forge-X baseline includes its repository, revision, source directory and
archive hash. The scanner's enclosing-git discovery is not source provenance
for an archive extracted inside another repository; its commit was set to the
downloaded Forge-X revision explicitly.

The local Forge-X checkout remains at `95d1771d8161df5e93eacdf3ec501861e607e202`
(`1.4.2-beta-4`). It was not updated. The downloaded branch has additional 3MF
preparation/error dialogs, so that local beta alone is an incomplete reference.

Ignoring bytecode, caches and generated `__version__.py`, the pinned upstream
source has 74 files and Forge-X has 73. There are 55 differing paths. Against
the dated upstream reference there are 19 differing paths, with 71 versus 73
files. The larger first diff includes upstream version drift, not just
Forge-X patches. Older serial implementations and dependency substitutions
must not be classified as new API features without further history checks.

## Registered API differences

The Forge-X scan has 123 endpoint registration records, 121 distinct literal
mounted paths, 129 endpoint-derived RPC names, 21 remote-method registrations,
28 notification names, five router routes and six static/upload registrations.
Two endpoint records have dynamic paths. These are source registrations across
all components, not the endpoints enabled by a particular configuration.

| Added HTTP path | Requests | Added RPC names |
| --- | --- | --- |
| `/machine/timelapse/render` | POST | `machine.timelapse.render` |
| `/machine/timelapse/saveframes` | POST | `machine.timelapse.saveframes` |
| `/machine/timelapse/settings` | GET, POST | `machine.timelapse.get_settings`, `machine.timelapse.post_settings` |
| `/machine/timelapse/lastframeinfo` | GET | `machine.timelapse.lastframeinfo` |

Forge-X explicitly registers `objects/list` as remote. Its mounted path is
`/printer/objects/list` and its RPC name is `printer.objects.list`. Upstream
registers it dynamically from Klippy. This changes ownership and filtering,
not the external path. Phobos already registers the mounted API.

The additional notification is `notify_timelapse_event`. Additional Klippy
remote methods are:

- `feather_request_forge_x_update_status`
- `feather_start_forge_x_update`
- `feather_reset_forge_x_update`
- `timelapse_newframe`
- `timelapse_saveFrames`
- `timelapse_render`
- `timelapse_cancel_render`

Phobos implements all seven Feather and timelapse names.
The existing coverage command does not score Klippy remote-method coverage.

The Forge-X snapshot lacks the four `/server/analysis/*` routes, two
`/machine/td1/*` routes and `/machine/update/upgrade` present in the newer
upstream baseline. Their absence is version/component drift. Keep those
Phobos implementations; a Forge-X profile must not delete them to reduce its
API surface.

The current dump covers 121/121 Forge-X endpoint paths, 129/129 RPC names and
28/28 notifications. Upstream coverage remains 123/123 paths, 130/130 RPC names
and 27/27 notifications. All four literal router paths match; the fifth router
registration has a dynamic path and is not scored. These counts measure names,
not behavioral completeness. CI checks the two baselines separately.

## Behavior tracker

Source links refer to the pinned Forge-X tree. Implementation checks use native,
loopback, temporary-filesystem and injected-service fixtures. New print macros,
camera captures and service/update actions have not been exercised on hardware.

| Area | Forge-X behavior | Phobos status and acceptance work |
| --- | --- | --- |
| Timelapse | [`timelapse.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/timelapse.py) limits frames/disk use, restores frames, handles parked-frame acknowledgements, final frames, rendering/export cancellation and printer transitions. | Native implementation in `timelapse.zig`. Fixtures cover capture, finalization, generation cancellation, macro acknowledgements, ZIP export, settings persistence and output collisions. A real FFmpeg test encodes and decodes a video and produces a transformed preview. See [timelapse](../TIMELAPSE.md). |
| Packaged G-code | [`gcode_3mf.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/file_manager/gcode_3mf.py) accepts `.gcode.3mf`, selects `Metadata/plate_N.gcode` using `plateindex`, checks optional MD5 and publishes through a temporary destination file. | Implemented for `--compat forge-x`. Streaming stored/deflated extraction validates CRC, MD5 and plate selection before replacement. HTTP fixtures cover fields after the archive, metadata, malformed uploads and preservation. See [file management](../FILE_MANAGEMENT.md). |
| Upload dialogs | [`GCode3MFUploadPrompt`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/file_manager/file_manager.py#L66) reports extraction, processing and failures through Klippy prompts, without command history. Prompt failure must not fail the upload. | Extraction/processing/start/error dialogs use sanitized quiet scripts. Preparation closes its prompt before starting a print. Errors are dismissible; unavailable prompts do not fail the upload. Physical prompt rendering remains unverified. |
| Stock-mode print start | [`klippy_apis.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/klippy_apis.py) checks the stock-config include and `print_leveling`, selecting `LEVELING_PRINT_FILE` or `NOLEVELING_PRINT_FILE`; otherwise `SDCARD_PRINT_FILE`. | The Forge-X profile shares one builder across printer, upload/OctoPrint and queue starts. It rereads the config root's `printer.cfg` and `mod_data/variables.cfg`. Builder and queue fixtures cover macro selection and escaping. PanelDue retains its reference protocol translation. No real print command was sent. |
| Hidden objects | Forge-X filters configured objects from `objects/list`. Its query/subscription paths remain Klippy proxies. | Paired profile tests preserve the existing query filtering in the default profile and return queried hidden objects in the Forge-X profile. Lists remain filtered. WebSocket subscriptions continue their existing proxy behavior. |
| Excluded files | Forge-X filters configured `root/relative` entries from directory and recursive listings. | Existing `[file_manager] excludes` behavior and list/ZIP/ownership tests are retained. Phobos also filters descendants. Excludes are listing rules; root/path checks remain separate. |
| Service permissions | [`moonraker.asvc`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker.asvc) grants `forge-x` and `guppyscreen`; Moonraker loads the data-path allowlist. | Both profiles load `<data>/moonraker.asvc`, normalize `.service` suffixes and validate bounded names. Missing files retain defaults. Invalid replacements preserve the previous list; allocation-failure and fuzz tests cover ownership. |
| Simple service provider | Forge-X invokes `<script_path>/<service> <action>` with a configurable timeout. | Configured allowed services use the existing bounded simple runner. Internal `verify` is separate from public start/stop/restart verbs. Tests inject commands; no board restart script was executed. |
| Update preflight | Forge-X [`git_deploy.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/update_manager/git_deploy.py) calls `verify` on the first managed service before pulling; failure aborts the update. | The Forge-X profile verifies the first managed service before Git mutation. Tests cover rejection before Git and successful verification/restart ordering in an owned local repository. |
| Update refresh cache | `base_deploy.py` recognizes a stored `last_cfg_hash` of `***skip***` and suppresses refresh. | The Forge-X profile honors the marker on automatic refresh. Explicit refresh remains available. SQLite fixtures cover profile selection and missing markers. |
| Feather status | [`feather_updates.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/feather_updates.py) refreshes the configured source before answering a status request. | Remote status requests now refresh that source, preserve tokens and report refresh/admission errors. Existing version/revision and idle guards remain. |
| Feather progress | Forge-X forwards intermediate `update_manager:update_response` events, failure/conflict details and the restart message to Feather. | Active source/token progress is forwarded, including the restart message. Bounded Git failure details deduplicate conflict paths. Fixtures cover tokens, busy errors, terminal failures and progress filtering. |
| History `exists` | Forge-X checks filename presence without comparing stored metadata mtime. | Phobos currently also checks presence. Upstream's mtime-sensitive behavior remains a separate compatibility difference for imported jobs containing metadata. |
| ZIP installation | Forge-X validates nonempty ZIP/CRC before removing the current installation. | Phobos already extracts/validates into a separate stage before replacing an install. Retain that stronger preservation behavior; fixture tests cover archives and failures in `update_net.zig`. |
| Serial components | PanelDue and WLED differ substantially from the dated reference; Forge-X substitutes older serial/HTTP plumbing and removes `utils/async_serial.py`. | Source differences alone do not establish wire incompatibility. Compare externally visible commands/errors before adding profile branches. Physical accessory tests remain outstanding. |
| Dependencies and platform | Forge-X uses `dbus_next`, alters pip requirement flags and system-dependency processing. | Python implementation/dependency choices do not belong in Phobos. Port only an observed external requirement; retain explicit platform runners and current package-operation limits. |

External clients and in-process Python components need separate integration
tests. A compatibility profile cannot load Python components. A future WASM
host can provide extension hooks, but does not automatically port Obico,
OctoEverywhere, Telegram Bot or other integrations.

## Startup profile

Use `--compat forge-x` for packaged G-code conversion, stock print macros,
query-filter scope, update preflight and automatic-refresh skip markers.
`--compat moonraker` is the default. The API dump reports the selected profile.
Timelapse and Feather load from explicit `[timelapse]` and `[feather_updates]`
configuration in either profile. Standard `moonraker.asvc` loading is shared.
Preserve Forge-X's `[file_manager] file_system_observer: none` on printer kernels
without inotify; profile selection does not override explicit component config.

Path checks, archive limits, authorization and idle/update guards remain active.
Host reboot/shutdown remain no-ops. Software identity stays `phobos`, API version
1.5.0 and the documented Python-version stub. Unavailable CAN still returns an
empty list. These choices and optional components are not Forge-X bugs.

## Rechecking

Set `FORGE_X_SOURCE` to `.root/moonraker` in the Forge-X source tree being
reviewed. Check its repository revision separately. These commands neither
import Moonraker nor contact a printer:

```sh
PYTHONPATH=tools uv run --locked python -m api_scanner diff \
  --source "$FORGE_X_SOURCE" --baseline api/forge_x_surface.json
mkdir -p .scratch
zig-out/bin/phobos --compat forge-x -d "$PWD/.scratch/forge-x-api-data" --dump-api > .scratch/forge-x-api.json
PYTHONPATH=tools uv run --locked python -m api_scanner coverage \
  --baseline api/forge_x_surface.json --phobos .scratch/forge-x-api.json
```

`diff` returns 0 for the pinned source's declarations. Both coverage gates
return 0. Review behavior and provenance before accepting a new baseline.

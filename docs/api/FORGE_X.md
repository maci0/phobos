# Forge-X compatibility tracker

Forge-X has a separate source baseline in
[`api/forge_x_surface.json`](../../api/forge_x_surface.json). The upstream
baseline stays [`api/api_surface.json`](../../api/api_surface.json), and its
coverage gate still requires 100% registered-name coverage. Neither baseline
proves matching request validation, responses, side effects or event ordering.

## Compared revisions

Comparison date: 2026-10-24. Phobos source and API dump: v0.2.3,
`0f21ca77c7c1e8375c97cc5872a451b68b6a23c6`.

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

Phobos implements the three Feather names; the four timelapse names are absent.
The existing coverage command does not score Klippy remote-method coverage.

The Forge-X snapshot lacks the four `/server/analysis/*` routes, two
`/machine/td1/*` routes and `/machine/update/upgrade` present in the newer
upstream baseline. Their absence is version/component drift. Keep those
Phobos implementations; a Forge-X profile must not delete them to reduce its
API surface.

The v0.2.3 dump covers 117/121 Forge-X endpoint paths, 124/129 RPC names and
27/28 notifications. The missing names are exactly the four timelapse paths,
five timelapse RPC names and its notification. All four literal router paths
match; the fifth router registration has a dynamic path and is not scored.
These counts are registered-name coverage, not behavioral completeness.

## Behavior tracker

Source links below refer to the pinned Forge-X tree. Status describes source
inspection, not a new live-printer conformance run.

| Area | Forge-X behavior | Phobos status and acceptance work |
| --- | --- | --- |
| Timelapse | [`timelapse.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/timelapse.py) limits frames/disk use, restores frames, handles parked-frame acknowledgements, final frames, rendering/export cancellation and printer transitions. | Missing component. Test the complete capture/finalization lifecycle, not just the API names. Keep camera and FFmpeg work bounded and off Core. |
| Packaged G-code | [`gcode_3mf.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/file_manager/gcode_3mf.py) accepts `.gcode.3mf`, selects `Metadata/plate_N.gcode` using `plateindex`, checks optional MD5 and publishes through a temporary destination file. | Missing upload conversion. Test one/multiple/missing plates, invalid indices/ZIP/MD5, bounded extraction, destination preservation, metadata, file events and queued-print results through the normal upload path. |
| Upload dialogs | [`GCode3MFUploadPrompt`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/file_manager/file_manager.py#L66) reports extraction, processing and failures through Klippy prompts, without command history. Prompt failure must not fail the upload. | Missing. Test prompt ordering, cancellation, sanitization and ownership when a print opens another prompt. |
| Stock-mode print start | [`klippy_apis.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/klippy_apis.py) checks the stock-config include and `print_leveling`, selecting `LEVELING_PRINT_FILE` or `NOLEVELING_PRINT_FILE`; otherwise `SDCARD_PRINT_FILE`. | Phobos always uses `SDCARD_PRINT_FILE`. A profile-specific command builder needs fixture coverage for all three cases and every print-start caller, including uploaded/queued files. Do not send print commands during source comparison. |
| Hidden objects | Forge-X filters configured objects from `objects/list`. Its query/subscription paths remain Klippy proxies. | Phobos also filters query/initial-subscription responses in `printer.zig`. Record and test the intended scope before choosing profile behavior; do not silently change the existing deployment. |
| Excluded files | Forge-X filters configured `root/relative` entries from directory and recursive listings. | Implemented through `[file_manager] excludes`; Phobos additionally treats descendants as excluded. Test direct traversal into an excluded directory separately from recursive listing. |
| Service permissions | [`moonraker.asvc`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker.asvc) grants `forge-x` and `guppyscreen`; Moonraker loads the data-path allowlist. | Phobos has a fixed default allowlist and rejects these names. Loading the standard `moonraker.asvc` mechanism belongs in shared behavior, with validated names and injected service tests. Avoid a Forge-X-only hardcoded exemption. |
| Simple service provider | Forge-X invokes `<script_path>/<service> <action>` with a configurable timeout. | Phobos supports `simple`, but the allowlist gap blocks the configured Forge-X services. Test argument construction and errors through an injected runner. Never invoke the board-rebooting `.root/forge-x restart` in these tests. |
| Update preflight | Forge-X [`git_deploy.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/update_manager/git_deploy.py) calls `verify` on the first managed service before pulling; failure aborts the update. | No equivalent preflight found in Phobos. This is an internal provider operation, not permission to expose arbitrary actions through the public restart API. Test failure before repository mutation. |
| Update refresh cache | `base_deploy.py` recognizes a stored `last_cfg_hash` of `***skip***` and suppresses refresh. | No equivalent marker found. Determine which Forge-X sources rely on it; test copied database fixtures and local repositories only. Keep remote refresh explicit. |
| Feather status | [`feather_updates.py`](https://github.com/DrA1ex/ff5m/blob/f2c3f272d6e27400818a514d9d31d754eeb1b5e3/.root/moonraker/components/feather_updates.py) refreshes the configured source before answering a status request. | Phobos uses the existing update status. Test fresh versus cached status, busy-state errors, offer revisions and response tokens. |
| Feather progress | Forge-X forwards intermediate `update_manager:update_response` events, failure/conflict details and the restart message to Feather. | Phobos sends accepted/completion/failure states but lacks that event-forwarding flow. Test intermediate ordering, terminal failure and stale-token handling with injected updates. |
| History `exists` | Forge-X checks filename presence without comparing stored metadata mtime. | Phobos currently also checks presence. Upstream's mtime-sensitive behavior remains a separate compatibility difference for imported jobs containing metadata. |
| ZIP installation | Forge-X validates nonempty ZIP/CRC before removing the current installation. | Phobos already extracts/validates into a separate stage before replacing an install. Retain that stronger preservation behavior; fixture tests cover archives and failures in `update_net.zig`. |
| Serial components | PanelDue and WLED differ substantially from the dated reference; Forge-X substitutes older serial/HTTP plumbing and removes `utils/async_serial.py`. | Source differences alone do not establish wire incompatibility. Compare externally visible commands/errors before adding profile branches. Physical accessory tests remain outstanding. |
| Dependencies and platform | Forge-X uses `dbus_next`, alters pip requirement flags and system-dependency processing. | Python implementation/dependency choices do not belong in Phobos. Port only an observed external requirement; retain explicit platform runners and current package-operation limits. |

External clients and in-process Python components need separate integration
tests. A compatibility profile cannot load Python components. A future WASM
host can provide extension hooks, but does not automatically port Obico,
OctoEverywhere, Telegram Bot or other integrations.

## Proposed startup profile

Not implemented. Use one validated selection, proposed spelling
`--compat moonraker|forge-x`, with `moonraker` as the default. Parse it once and
pass an immutable enum into App/component initialization. Do not infer the
profile from hostname, CPU architecture, a version string or an update source's
name, and do not scatter global string checks through request handlers.

The profile should select verified conflicting behavior, such as print-start
macro selection and history existence semantics. Missing shared Moonraker
behavior, such as loading `moonraker.asvc`, should be fixed for both profiles.
Configured additions such as timelapse and Feather should load explicitly,
whether implemented natively or through a future WASM extension host. Preserve
existing explicit configuration during any migration to profile selection.

A profile is not a security-policy switch. It must not weaken path checks,
archive limits, authorization, input validation or idle/update guards, enable
real reboot/shutdown, or copy an older implementation's incidental failures.
Keep Phobos software identity, its documented Python-version stub, and the
intentional missing-CAN empty result. API version 1.5.0 stays unchanged.

Before shipping a profile, add paired tests for each changed request, result,
event and side effect. Make the API dump identify the selected profile and
keep separate upstream and Forge-X checks. Do not ship an empty flag that
implies the missing timelapse/upload/update behavior is present.

## Rechecking

Set `FORGE_X_SOURCE` to `.root/moonraker` in the Forge-X source tree being
reviewed. Check its repository revision separately. These commands neither
import Moonraker nor contact a printer:

```sh
PYTHONPATH=tools uv run --locked python -m api_scanner diff \
  --source "$FORGE_X_SOURCE" --baseline api/forge_x_surface.json
mkdir -p .scratch
zig-out/bin/phobos -d "$PWD/.scratch/forge-x-api-data" --dump-api > .scratch/forge-x-api.json
PYTHONPATH=tools uv run --locked python -m api_scanner coverage \
  --baseline api/forge_x_surface.json --phobos .scratch/forge-x-api.json
```

`diff` returns 0 for the pinned source's API declarations. `coverage` currently
returns 1 for the ten missing timelapse names above. Keep this visible rather
than weakening the upstream gate or marking incomplete Forge-X coverage green.
Review behavior and provenance before accepting a new Forge-X baseline.

# G-code analysis

Analysis execution requires an embedding to call `App.setAnalysisRunner` before
serving requests. The daemon installs no runner, downloads no estimator and has
no CLI option that enables execution. Without a runner, status reports
`estimator_ready: false`, and execution endpoints return `EstimatorNotAvailable`.

`[analysis] platform` selects `auto`, `linux`, `rpi` or `osx`; `auto` selects
`rpi` on ARM and `linux` otherwise. The executable path is
`<data_path>/tools/klipper_estimator/klipper_estimator_<platform>`.
`estimator_config` optionally names a file under the config root; otherwise the
default is `tools/klipper_estimator/default_estimator_cfg.json` under the data
path. `estimator_timeout` is a positive integer in seconds, defaulting to 600.

## Runner ownership

[`analysis.Runner`](../src/components/analysis.zig) contains an embedding-owned
context and a callback receiving `std.Io`, an allocator and an argv slice.
The callback must return allocator-owned stdout, honor cancellation and join any
child process before returning. It receives the stable `smp_allocator`, never a
request allocator. Stdout is limited to `analysis.max_output_bytes` (1 MiB), must
be UTF-8, and is copied into request storage only after the callback finishes.
The embedding owns backend URLs and authentication; neither is added to argv.

Commands serialize through an analysis mutex while Core is released. A joined
native timer bounds estimator calls. Version and config probes have ten-second
deadlines; estimate and post-process use `estimator_timeout`. A runner that
ignores cancellation cannot satisfy that deadline or shutdown requirement.

## Endpoints and files

Status probes `--version` once and caches readiness and version until the runner
is replaced. `server.analysis.estimate` accepts a filename under gcodes and an
optional `estimator_config` under config. It returns the first object in the
estimator's `sequences` array.

Estimate and process copy their input and config into a private workspace under
`<data_path>/tools/klipper_estimator`. That directory must be outside every
API-writable root; otherwise the request returns `Forbidden`. Files open through
checked directory handles. The estimator receives snapshot paths, rather than
the API paths.

`server.analysis.process` checks the final 64 KiB for an existing processed
version. It reports `prev_processed`, `version` and `bypassed`; `force: true`
runs processing again. A processed file replaces the original atomically only
after rechecking its identity, size, timestamps, parent and loaded-print guard
under Core. Failure preserves the original file.

`server.analysis.dump_config` requires Klippy ready, validates an object response
and atomically writes the requested config destination or the default tools
config. Its response contains `dest_root`, `dest_config_path` and
`klipper_estimator_config`.

These are manual API operations. Automatic metadata post-processing and an
automatic ready-triggered config dump are absent. Native fixture executables
exercise execution, paths, cancellation and replacement; no real estimator or
physical printer was used for this review.

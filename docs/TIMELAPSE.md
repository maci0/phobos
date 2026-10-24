# Timelapse

`[timelapse]` enables the native Forge-X timelapse component. It requires the
corresponding Forge-X Klipper macros. It does not load Python components.
Capture uses native HTTP, frame export uses the native ZIP writer, and video
encoding uses an installed FFmpeg executable with H.264 support.

```ini
[timelapse]
frame_path: /tmp/timelapse
output_path: ~/timelapse
ffmpeg_binary_path: /usr/bin/ffmpeg
render_timeout: 3600
```

These are the defaults. Relative paths resolve under the data directory; `~/`
uses the startup home directory. On a printer where `/tmp` is RAM-backed,
choose a persistent frame directory if snapshots would consume too much RAM.
The output and frame directories must differ. The file manager exposes
`timelapse` with write access and `timelapse_frames` with read access.

The component restores existing `frameNNNNNN.jpg` files on startup. Selecting
a file preserves old frames until that print begins. Completing a print waits
for an active capture, optionally captures the final frame, saves a frame ZIP
and renders a video according to settings. Finalization retains the completed
print's filename while another file is selected. Cancellation invalidates the
generation before waking workers, so canceled work cannot publish an output.

## API and macros

| Request | RPC | Result |
| --- | --- | --- |
| GET `/machine/timelapse/settings` | `machine.timelapse.get_settings` | Settings and `blockedsettings`. |
| POST `/machine/timelapse/settings` | `machine.timelapse.post_settings` | Validated, persisted settings. |
| GET `/machine/timelapse/lastframeinfo` | `machine.timelapse.lastframeinfo` | `framecount`, `lastframefile`, `rendering`, `busy`. |
| POST `/machine/timelapse/saveframes` | `machine.timelapse.saveframes` | Action/status and `zipfile` on completion. |
| POST `/machine/timelapse/render` | `machine.timelapse.render` | Action/status, then `filename` and `printfile` on success. |

`notify_timelapse_event` carries one result in its params array. Render emits
`started` with frame count and encoder settings, followed by a terminal result.
Busy operations return `running`; missing frames return `skipped`; failures
return `error` with a message. Failed FFmpeg exits include bounded command/output
details. Existing destination files are preserved, with numbered output names
chosen for collisions. Finished video and preview candidates are synced before
publication; temporary duplicates and failed candidates are removed.

Klippy remote methods are `timelapse_newframe`, `timelapse_saveFrames`,
`timelapse_render` and `timelapse_cancel_render`. Capture accepts `parked` and
`hyperlapse` flags, including boolean strings, and the older `macropark` payload.
Only parked captures acknowledge `TIMELAPSE_TAKE_FRAME.takingframe`; declined
parked requests release it immediately. A canceled generation cannot acknowledge
a later capture. Rendering with `byrendermacro=true` releases
`TIMELAPSE_RENDER.render` on every result path. Setup/hyperlapse/acknowledgement
scripts use quiet Klippy requests and do not enter command history.

## Settings

GET returns the fields defined by `Settings` in
[`timelapse.zig`](../src/components/timelapse.zig). Defaults include enabled
layer-macro capture, 0.05-second stream compensation, no head parking,
30-second hyperlapse cycles, automatic rendering, CRF 23, 30 FPS, `yuv420p`,
five duplicated final frames, preview images and no frame ZIP on completion.
Variable FPS divides frame count by `targetlength` and clamps it to the
configured minimum/maximum. Rotation and horizontal/vertical flips apply to
the video and preview.

Settings persist in database namespace `timelapse`, key `config`. Explicit
`[timelapse]` settings override stored values and appear in `blockedsettings`;
POST cannot change them. `snapshoturl` is configuration-only. Camera selection
uses the named configured webcam, or the first webcam, unless snapshot URL,
rotation or flips are explicitly fixed in `[timelapse]`. Relative webcam URLs
resolve against localhost. Without a webcam, the snapshot default is
`http://localhost:8080/?action=snapshot`.

`extraoutputparams` is parsed into bounded, quote-aware FFmpeg arguments without
a shell. Treat encoder configuration as trusted administrative configuration.
The component does not download or install FFmpeg; missing FFmpeg disables
automatic rendering. Manual render failures remain visible.

## Bounds and verification

There are at most 1,000 frames, each snapshot at most 8 MiB. Capture reserves
128 MiB of free space, with additional room for a maximum snapshot. Export
checks frame sizes and output space; rendering also checks duplicate-frame
space. ZIP32 limits apply to frame archives. HTTP capture has a three-second
budget after stream compensation. FFmpeg has a configurable deadline, at most
24 hours, and uses one encoder thread. App owns and joins all queued workers;
subprocess cancellation kills and reaps the child.

Tests use temporary directories, an HTTP peer and injected Klippy/encoder
runners. A native FFmpeg test encodes and decodes an MP4 and checks a rotated
JPEG preview; it skips when `/usr/bin/ffmpeg` is absent. CI installs FFmpeg.
Camera optics, parked motion, real macro/UI behavior and on-printer encoding
still require hardware verification. No production deployment is implied.

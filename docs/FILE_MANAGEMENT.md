# File management

File operations open registered roots through `Resolved` checked directory
handles. Root escapes, including symlinked thumbnail directories, are rejected.
Uploads and generated files use atomic replacement after syncing the data.

Embedded `thumbnail begin` PNG blocks are decoded into
`<gcode directory>/.thumbs/<gcode stem>-<width>x<height>.png`. Metadata returns
`width`, `height`, decoded `size` and `relative_path`; `server.files.thumbnails`
returns `thumbnail_path` relative to the gcodes root. Clients download those
paths through `/server/files/gcodes/...`, with `image/png` content type. Invalid
base64, size mismatches and non-positive dimensions are omitted.

Metadata parsing and image decoding use a per-file scratch arena backed by the
stable file-manager allocator. Only result fields reach the request arena and
metadata cache. Thumbnail bytes stay on disk rather than in cached JSON.

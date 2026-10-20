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

`server.files.zip` writes an atomic ZIP32 archive, with DEFLATE by default and
stored entries when `store_only` is true. Entries retain the root prefix, CRC32
and ordinary Unix permissions. Selected directories include their immediate
files, matching the pinned Moonraker version. Excluded paths and `.git` are
omitted; canonical file aliases deduplicate. Escaping links are rejected for
explicit selections and omitted while listing a selected directory.

Archives run outside Core and serialize independently. The source list is
bounded to 4096 files, 1 MiB of retained paths and 65536 examined directory
entries; ZIP64 extents are rejected. Failed requests preserve an existing
destination and remove the temporary file. The loaded-file guard is checked
again under Core before replacement. Successful creation emits `create_file`.

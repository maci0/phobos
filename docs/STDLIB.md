# Standard library choices

Use the installed Zig 0.17.0 sources when choosing an API. Prefer `std.Io` for
I/O, standard containers and codecs for primitives, and builtins for typed
conversions and memory operations. Keep Moonraker protocol rules at their callers.
These choices apply to first-party Zig modules, build code and `disk_usage.c`;
vendored libraries keep their upstream implementations.

| Operation | Implementation |
| --- | --- |
| Files, directories, copies, atomic replacement | `std.Io.File` and `std.Io.Dir` |
| Root-contained paths and symlinks | `Dir.realPathFile` for link resolution, followed by directory-relative opens with `follow_symlinks = false` |
| Virtual files with a zero stat size | `File.readerStreaming` and bounded `Reader.allocRemaining` |
| TCP, Unix sockets, DNS, peer addresses | `std.Io.net` |
| HTTP and server WebSockets | `std.http` |
| TLS and certificate validation | `std.crypto.tls.Client` and `std.crypto.Certificate.Bundle` |
| Clocks, deadlines and cancellation | `std.Io.Clock`, `Event`, `Future`, `operateTimeout` |
| Secret entropy and cryptography | `io.randomSecure`, `std.crypto` |
| Process arguments and execution | `std.mem.concat`, `std.process.run` and `std.Io.Select` cancellation, without shell interpolation |
| Bounded temperature and G-code stores | `std.Deque.initCapacity` with eviction before `pushBackAssumeCapacity` |
| Klippy message delimiters | `Reader.streamDelimiterLimit` and `Writer.writeByte` |
| MQTT remaining lengths | `Reader.takeLeb128` and `Writer.writeLeb128`, with the four-byte MQTT limit |
| HTTP percent decoding | `std.Uri.Component.toRawMaybeAlloc`; form queries also replace `+` with a space |
| Calendar rules and UTC formatting | `std.time.epoch` and `std.fmt` |
| JSON parsing and serialization | `std.json` |
| Request arguments | `json/params.zig` over standard numeric parsers and ASCII helpers |
| Text searches, case conversion, hex and Base64 | `std.mem`, `std.ascii`, `std.fmt`, `std.base64` |
| Test directories and allocation failures | `std.testing.tmpDir` and `checkAllAllocationFailures` |

An I/O reader's internal buffer must not alias the output buffer of a read.
Use `File.readStreaming` for a one-shot byte read. Keep persistent network
readers alive across messages so pipelined bytes remain available.

`File.reader` defaults to positional reads. An allocating writer can use the
file's stat size, so it can mistake `/proc` or `/sys` content for an empty file.
`readerStreaming` explicitly disables that size assumption. Bound the read and
return an owned slice rather than returning an `ArrayList.items` allocation.

The standard LEB128 reader permits extended encodings. MQTT restricts a remaining
length to four bytes; the limited reader uses one byte of lookahead so packet
data cannot be consumed into a discarded temporary buffer.

`std.process.run` applies its timeout while draining output, then waits for the
child without a deadline. `util/process.zig` cancels the whole operation at the
deadline so closing stdout and stderr cannot leave a service or Git command hung.
Service actions require a discovered unit for systemd and supervisord. Simple
and none providers accept only fixed allowed names; requests cannot add arbitrary
service names or script paths.
Failed commands and expired deadlines reach the service caller before state or
notifications change. Timeout conversion leaves timestamp headroom for large
finite configuration values; the native duration is capped at i64 nanoseconds.

Device and snapshot HTTP requests use `Client.request`, native body writers and
response readers. `Client.fetch` assumes a failed body reader always has a
specific `bodyErr`, which can be null after cancellation. The shared
`http_get.requestToWriter` helper preserves a generic read failure in that case.
Requests negotiate identity encoding and reject encoded responses; their owning
future joins before the client, buffers or request storage are released.

## Platform adapters

These operations have no equivalent higher-level API in the installed library.
Keep their declarations local and typed. Replace them when a suitable standard
API becomes available and passes both host and ARM checks.

| Adapter | Reason |
| --- | --- |
| Serial configuration in `serial.zig` | `std.Io` has no termios configuration operation. Use `std.posix.tcgetattr` and `tcsetattr`, including Linux baud bits. |
| System identity in `machine.zig` | No higher-level uname or effective-UID operation. `process.getUserInfo` resolves names to IDs, not IDs to names. |
| Video capability layout in `machine.zig` | No V4L2 declaration. Use a local `extern struct`, `std.os.linux.IOCTL.IOR` and `io.operate(.device_io_control)`. |
| Disk capacity in `disk_usage.c` | No `std.Io` filesystem-capacity operation. ARM C translation produces an opaque `statvfs` type because its platform header has a bitfield. The C header owns its ABI. |
| SQLite bindings in `sqlite_c.zig` | No standard SQLite driver. The translated `SQLITE_TRANSIENT` function-pointer sentinel fails ARM alignment checks; the local opaque-pointer declaration preserves the C sentinel. |
| Network address enumeration | `std.Io.net.Interface` maps names and indices but does not enumerate addresses. The `ip -json` fallback remains. |
| WebSocket client frames | The standard server codec requires masked input and writes unmasked output. Client masking and bounded frame validation remain local. |

Zig 0.17.0 has `std.Build.addTranslateC`; it does not have `@cImport`. Translation
does not remove the ARM header and sentinel limitations above.

File operations retain an open root handle and check every path component.
Native canonicalization handles nested links and `..`; an in-root target is
reopened relative to the retained root without following unchecked links. The
`resolve_beneath` option alone is insufficient because the installed Linux
backend ignores it. The private root walker uses `Dir.Iterator`: `Dir.Walker`
reopens directories with symlink following enabled and cannot accept a checked
child handle. The private walker follows checked in-root directory links.
Listings visit each canonical directory once; copies expand each alias and
reject ancestor cycles or links into the output tree. Traversal permits 4096
directory visits, including the root, then returns a parameter error. Canonical
paths do not identify bind-mount aliases; those remain subject to the visit
limit because `File.Stat` exposes no device ID. Disk capacity uses `fstatvfs`
on the checked directory handle.
Unlink, rename and atomic replacement operate on the final entry itself rather
than following its link target.

```mermaid
flowchart TD
    Root[Open configured root] --> Component[Check next component without following links]
    Component -->|directory| Open[Open directory without following links]
    Open --> Component
    Component -->|link| Resolve[Resolve with Dir.realPathFile]
    Resolve -->|outside root| Reject[Reject request]
    Resolve -->|inside root| Root
    Component -->|leaf| Operation[Read or mutate through checked parent]
```

Copies and uploads use `File.Atomic` replacement. A truncated upload file part
discards its temporary file and preserves the existing destination. Each file
part commits when its separator arrives; the multipart form is not a transaction.
Directory copies also preserve completed entries if a later entry fails. A
loaded gcode file is protected from mutation only while Klippy is ready and
print_stats is printing or paused. Listed linked files have read-only permissions.

Metadata parsing uses a per-file arena backed by the stable file-manager
allocator, then copies the resulting JSON into the response allocator. Extended
directory listings retain metadata and thumbnail data, without retaining each
file's 256 KiB header and 32 KiB footer buffers. A scratch arena backed by the
response arena would retain those buffers until the whole request ended.

## Protocol and ownership code

HTTP query and JSON-RPC handlers share `json/params.zig`. Optional readers use
defaults only for absent keys; present invalid values, including null, return
400. Boolean arguments accept booleans or case-insensitive `true`/`false`
strings. Numeric arguments follow Moonraker's decimal conversions, including
integer truncation and boolean numbers. Text arguments require strings rather
than Python representations of objects. String lists accept arrays of strings
or trimmed comma-separated text. Handler-specific validation follows conversion.
Raw JSON readers preserve null, including database values and an optional read
key. Spool clearing through HTTP uses an absent `spool_id`; explicit null is a
conversion error. The Klipper remote method separately accepts an integer or
null. Usernames must be non-empty single DataStore keys without dots; creating
a dotted username returns 400 instead of writing a nested user record.

Keep application grammars that have no standard implementation: Moonraker
configuration, RSS/XML and RFC 2822 syntax, G-code comments, multipart
separators, PanelDue checksums, the supported template language, and MQTT packet
fields. Use standard tokenizers, numeric parsers, searches, writers and calendar
rules inside those grammars.
RSS input must be valid UTF-8 before any feed fields are captured. Opaque ETag
bytes that are not UTF-8 are omitted from the JSON-backed cache; their response
body remains usable and later requests fetch without that conditional tag.

Configuration globs support `*` and `?` through a local matcher; `std.Io.Dir`
provides iteration but no glob operation. Template title casing keeps its own
word-start rules over `std.ascii`; case-insensitive searches use
`std.ascii.findIgnoreCase`.

Sensor templates evaluate with `std.heap.FixedBufferAllocator`: temporary state
uses at most 64 KiB on the handler stack, and nested execution shares a
10,000-step budget. Exceeding either limit fails the render without publishing
partial measurements. Only successful numeric results and their copied keys
enter the caller's arena. Power batch responses copy each device's state before
the next device request can release Core and change that state.
Template replacements check size growth with `std.math` before
`std.mem.replaceOwned`, whose size calculation can overflow on 32-bit targets.

TD-1 scans use `std.Io.Clock` to share one serial-timeout budget across reads;
their final in-flight read can add at most one further serial timeout. Polling
checks its stop event before opening each device.
Announcement refreshes check their stop event before starting the next feed
download, so shutdown does not wait through every configured feed timeout.

Update tests create native temporary repositories whose `origin` points to the
same local fixture. Refresh assertions check the resulting tracking ref; the
test suite does not fetch the project's remote.

Spoolman HTTP requests race a native `Io.Select` timer, cancelling and joining
the request after ten seconds. Response data is copied out only after the task
finishes. Bodies, reason text and headers must be UTF-8; invalid text returns
the unavailable response. External JSON passes the depth guard before
serialization. The v1 proxy preserves upstream status and HTTP reason text;
v2 prefers the JSON `message` field. WebSocket keepalive uses `Io.operateTimeout` on the underlying
reader and writer, including TLS, with a ping every twenty seconds and one
interval to receive a matching pong. Startup status emission takes Core; active
spool changes emit while Core is held, and repeated selections do not emit.

Notifier records validate ASCII word-character service URL prefixes and the
case-insensitive `text`, `html` and `markdown` body formats before registration.
Klipper's `notify` method resolves configured names through the notifier handler. Delivery still
fails with `AppriseNotAvailable`; the transport and full template rendering are
not implemented.

Update, recovery, rollback and Feather Git commands serialize through an owned
`std.Io.Mutex` outside Core. An atomic busy flag rejects competing mutations and
refreshes; the printing flag blocks refresh and mutations. Status requests
suppress requested refreshes while busy or printing and throttle them to one per
minute. Notifications take Core only after releasing the command mutex.

The daemon copies its startup environment once for Git commands, excluding every
`GIT_*` override while retaining HOME, proxy and SSH-agent settings. Fixture Git
commands use an explicit empty environment. Inherited `GIT_DIR`, `GIT_WORK_TREE`
and index/config overrides cannot redirect a fixture command into another checkout.
Git text used in JSON must pass `std.unicode.utf8ValidateSlice`; invalid version
or log output uses the existing unavailable-status fallback.

Base32, UUID layout and CIDR prefix matching remain small local codecs. The
standard library has no matching complete API. Address comparison for trusted
clients intentionally ignores ports; `IpAddress.eql` also compares the port.
Webcam UUID5 hashing streams the namespace, prefix and name through
`std.crypto.hash.Sha1.update`. Power URL credentials use
`std.Uri.Component.formatEscaped`, and URL constructors free partial results
when a later allocation fails.

Owned JSON snapshots still require a recursive copy and matching cleanup.
`std.json.Value.jsonParseFromValue` returns its source unchanged, so it cannot
detach a snapshot from a request arena. Inputs must pass the existing depth
guard before copying or serialization.

HTTP and JSON-RPC serialize handler results before releasing Core, because
results can borrow mutable component strings. Transport screening runs after
method, transport, argument and authentication checks for each request, including
batch items. A failed upstream request can replace the reserved `_method` value
with an owned status/message object immediately before returning
`UpstreamRequestFailed`; client-supplied reserved values are always replaced.

WebSocket authentication state is initialized before registry insertion and
published atomically. Notification fan-out excludes unauthenticated sessions.
Listener capacity waits remain cancellable and close the accepted stream if
canceled before a handler starts.

Klippy requests release Core before writing as well as waiting for a reply.
Socket writes use a native stream writer with one absolute five-second deadline
for the complete ETX frame. Each bridge shuts down the client socket when its
Klippy connection ends, without waiting for the client's close response.
Remote-method queues close and drain even when their worker could not start.

WebSocket batches dispatch connection-bound methods per item. Status subscriptions
replace the connection's previous object/field map; initial responses and pushes
are pruned to it. Klippy's aggregate is rebuilt from active connections and
internal heater objects. Subscription requests serialize separately from Core
and use a twenty-second deadline. Handshake ids are read with the JSON parser,
so whitespace and nested unrelated `id` fields cannot change response matching.

Successful persisted logout and deletion revoke matching WebSocket sessions.
User strings remain owned by the serve loop; registry comparison and replacement
hold its mutex, while the authentication gate is atomic. Revoked callers expose
no authenticated user. Upgrade authentication, registry insertion and identify
run under Core, ordered with credential changes; network writes happen afterward.
Klippy method frames and parsed results pass the JSON depth bound before they
can reach handlers or serializers.

WebSocket responses, notifications, pongs and bridge close frames use one absolute
five-second write budget per complete frame. Native `net_write` consumes buffered
headers, payload vectors and repeated slices without resetting that deadline.
Each frame starts its budget under the session's write mutex, including the first
frame after an idle period. A timeout shuts down both socket directions.

Inbound WebSocket frames use the native server codec with a lazily grown input
buffer capped at 10 MiB. The announced length is checked before allocation;
consuming a large message restores the original small buffer when the remaining
buffered input fits. Pongs are discarded before checking the following frame's
capacity because the native reader otherwise skips them internally.

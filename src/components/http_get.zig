//! Conditional HTTP GET helper built on the lower-level `std.http.Client.request`
//! API so response headers (notably `ETag`) are observable; `Client.fetch`
//! returns only the status. Announcements (RSS) use it for `If-None-Match`
//! conditional fetches that skip unchanged downloads (304).
//!
//! Requests ask for `identity` encoding: `Response.reader` returns encoded
//! bytes as-is, so an encoded reply fails with `HttpContentEncodingUnsupported`
//! instead of handing compressed data to a parser.
//! `requestToWriter` also streams plain or JSON request responses into a
//! caller-owned writer; callers own deadlines and cancellation.

const std = @import("std");
const http = std.http;
const Io = std.Io;

/// Request headers that advertise only the identity encoding.
pub const identity_headers: http.Client.Request.Headers = .{ .accept_encoding = .{ .override = "identity" } };

/// `Request.accept_encoding` value that rejects any encoded response body.
pub const identity_only = blk: {
    var accepted: @TypeOf(http.Client.Request.default_accept_encoding) = @splat(false);
    accepted[@backingInt(http.ContentEncoding.identity)] = true;
    break :blk accepted;
};

/// Send one request and stream its identity-encoded response to `writer`.
/// All arguments borrow for the call; the caller keeps the client alive until
/// any concurrent invocation has joined.
pub fn requestToWriter(client: *http.Client, method: http.Method, url: []const u8, payload: ?[]const u8, headers: []const http.Header, writer: *Io.Writer) !http.Status {
    var req = try client.request(method, try std.Uri.parse(url), .{
        .headers = identity_headers,
        .extra_headers = headers,
        .keep_alive = false,
        .redirect_behavior = if (payload == null) @fromBackingInt(3) else .unhandled,
    });
    defer req.deinit();
    req.accept_encoding = identity_only;
    if (payload) |data| {
        req.transfer_encoding = .{ .content_length = data.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(data);
        try body.end();
        try req.connection.?.flush();
    } else try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(if (payload == null) &redirect_buf else &.{});
    var transfer_buf: [1024]u8 = undefined;
    _ = response.reader(&transfer_buf).streamRemaining(writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    return response.head.status;
}

pub const Result = struct {
    status: u16,
    /// Response body (gpa-owned). Empty on 304.
    body: []u8,
    /// Value of the response `ETag` header (gpa-owned), if present.
    etag: ?[]u8,
    /// True when the server returned 304 Not Modified.
    not_modified: bool,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        if (self.etag) |e| gpa.free(e);
    }
};

/// Perform a GET on `url`. When `if_none_match` is non-null it is sent as the
/// `If-None-Match` request header; a 304 response sets `not_modified=true` with
/// an empty body. Captures the response `ETag` for the caller to persist.
pub fn getConditional(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    if_none_match: ?[]const u8,
) !Result {
    const uri = try std.Uri.parse(url);

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var extra_storage: [1]http.Header = undefined;
    var extra: []const http.Header = &.{};
    if (if_none_match) |etag| {
        extra_storage[0] = .{ .name = "If-None-Match", .value = etag };
        extra = extra_storage[0..1];
    }

    var req = try client.request(.GET, uri, .{ .headers = identity_headers, .extra_headers = extra });
    defer req.deinit();
    req.accept_encoding = identity_only;
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status: u16 = @backingInt(response.head.status);

    // Capture the ETag header (case-insensitive).
    var etag_out: ?[]u8 = null;
    errdefer if (etag_out) |e| gpa.free(e);
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
            etag_out = try gpa.dupe(u8, h.value);
            break;
        }
    }

    if (status == 304) {
        return .{ .status = status, .body = try gpa.alloc(u8, 0), .etag = etag_out, .not_modified = true };
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(gpa, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.ReadFailed => return error.HttpBodyReadFailed,
        else => |err| return err,
    };
    return .{ .status = status, .body = body, .etag = etag_out, .not_modified = false };
}

// ===========================================================================
// Tests — against a local raw-HTTP server double (no gzip; identity body).
// ===========================================================================

const testing = std.testing;
const net = std.Io.net;

const EtagServer = struct {
    io: Io,
    server: net.Server,

    fn bind(io: Io) !EtagServer {
        var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .io = io, .server = try ip.listen(io, .{ .reuse_address = true }) };
    }
    fn port(self: *const EtagServer) u16 {
        return self.server.socket.address.getPort();
    }
    fn deinit(self: *EtagServer) void {
        self.server.deinit(self.io);
    }

    /// Serve one request: 304 when the request carries `If-None-Match: "v1"`,
    /// otherwise 200 with an ETag and a small body.
    fn serveOne(self: *EtagServer) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        // Read request headers up to the blank line.
        const head = r.interface.takeDelimiterInclusive('\n') catch return;
        _ = head;
        var has_inm = false;
        while (true) {
            const line = r.interface.takeDelimiterInclusive('\n') catch break;
            if (line.len <= 2) break; // blank line terminates headers
            if (line.len >= 13 and std.ascii.eqlIgnoreCase(line[0..13], "if-none-match") and
                std.mem.indexOf(u8, line, "\"v1\"") != null) has_inm = true;
        }
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        if (has_inm) {
            w.interface.writeAll("HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\nContent-Length: 0\r\n\r\n") catch return;
        } else {
            w.interface.writeAll("HTTP/1.1 200 OK\r\nETag: \"v1\"\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello") catch return;
        }
        w.interface.flush() catch return;
    }
};

test "getConditional: 200 returns body + ETag; conditional re-fetch returns 304" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var srv = try EtagServer.bind(io);
    defer srv.deinit();
    const p = srv.port();
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/feed", .{p});
    defer testing.allocator.free(url);

    // First fetch: no validator → 200 with body + ETag.
    var f1 = io.async(EtagServer.serveOne, .{&srv});
    defer f1.cancel(io);
    var r1 = try getConditional(testing.allocator, io, url, null);
    f1.await(io);
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expectEqualStrings("hello", r1.body);
    try testing.expect(r1.etag != null);
    try testing.expectEqualStrings("\"v1\"", r1.etag.?);

    // Second fetch with the ETag → 304 Not Modified, empty body.
    var f2 = io.async(EtagServer.serveOne, .{&srv});
    defer f2.cancel(io);
    var r2 = try getConditional(testing.allocator, io, url, r1.etag.?);
    f2.await(io);
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 304), r2.status);
    try testing.expect(r2.not_modified);
    try testing.expectEqual(@as(usize, 0), r2.body.len);
}

test "getConditional asks for identity and rejects a gzip body" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var srv = try EtagServer.bind(io);
    defer srv.deinit();
    const Gzip = struct {
        fn serve(s: *EtagServer, accept: *[64]u8, accept_len: *usize) void {
            const stream = s.server.accept(s.io) catch return;
            defer stream.close(s.io);
            var rbuf: [4096]u8 = undefined;
            var r = stream.reader(s.io, &rbuf);
            while (true) {
                const line = r.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
                if (std.ascii.startsWithIgnoreCase(line, "accept-encoding:")) {
                    const value = std.mem.trim(u8, line["accept-encoding:".len..], " \r\n");
                    @memcpy(accept[0..value.len], value);
                    accept_len.* = value.len;
                }
            }
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(s.io, &wbuf);
            // gzip of "hello".
            const body = [_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0, 0x86, 0xa6, 0x10, 0x36, 5, 0, 0, 0 };
            w.interface.print("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
            w.interface.writeAll(&body) catch return;
            w.interface.flush() catch return;
        }
    };
    var accept: [64]u8 = undefined;
    var accept_len: usize = 0;
    var server_task = io.async(Gzip.serve, .{ &srv, &accept, &accept_len });
    defer server_task.cancel(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/feed", .{srv.port()});
    defer testing.allocator.free(url);
    try testing.expectError(error.HttpContentEncodingUnsupported, getConditional(testing.allocator, io, url, null));
    server_task.await(io);
    try testing.expectEqualStrings("identity", accept[0..accept_len]);
}

test "fuzz getConditional url parsing: never crashes on arbitrary urls" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            // Fuzz only the target after a fixed loopback authority so no
            // input can resolve or connect to another host.
            const prefix = "http://127.0.0.1:9/";
            var buf: [prefix.len + 48]u8 = undefined;
            @memcpy(buf[0..prefix.len], prefix);
            smith.bytesWithHash(buf[prefix.len..], 0);
            // Bad/unreachable URLs must return an error, never crash.
            var result = getConditional(testing.allocator, io, &buf, null) catch return;
            defer result.deinit(testing.allocator);
        }
    }.run, .{});
}

test "requestToWriter streams a bounded response through the native request API" {
    const Task = struct {
        fn run(client: *http.Client, url: []const u8, writer: *Io.Writer, done: *Io.Event) !http.Status {
            defer done.set(client.io);
            return requestToWriter(client, .GET, url, null, &.{}, writer);
        }
    };
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var server = try EtagServer.bind(aio);
    defer server.deinit();
    var serving = try aio.concurrent(EtagServer.serveOne, .{&server});
    defer serving.cancel(aio);
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.port()});
    var buffer: [16]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    var client: http.Client = .{ .allocator = std.heap.smp_allocator, .io = aio };
    defer client.deinit();
    var done: Io.Event = .unset;
    var fetching = try aio.concurrent(Task.run, .{ &client, url, &writer, &done });
    defer _ = fetching.cancel(aio) catch {};
    try done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqual(http.Status.ok, try fetching.await(aio));
    try testing.expectEqualStrings("hello", writer.buffered());
}

test "fuzz requestToWriter validates unsupported URLs without network access" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const prefix = "unsupported://127.0.0.1/";
            var url: [prefix.len + 32]u8 = undefined;
            @memcpy(url[0..prefix.len], prefix);
            smith.bytesWithHash(url[prefix.len..], 0);
            var client: http.Client = .{ .allocator = testing.allocator, .io = testing.io };
            defer client.deinit();
            var body: [64]u8 = undefined;
            var writer = Io.Writer.fixed(&body);
            _ = requestToWriter(&client, .GET, &url, null, &.{}, &writer) catch return;
        }
    }.run, .{});
}

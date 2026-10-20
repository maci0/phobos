//! Conditional HTTP GET helper built on the lower-level `std.http.Client.request`
//! API so response headers (notably `ETag`) are observable — `Client.fetch` does
//! not expose them in Zig 0.16. Used by announcements (RSS) and spoolman to do
//! `If-None-Match` conditional fetches and skip unchanged downloads (304).

const std = @import("std");
const http = std.http;
const Io = std.Io;

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

    var req = try client.request(.GET, uri, .{ .extra_headers = extra });
    defer req.deinit();
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
    var r1 = try getConditional(testing.allocator, io, url, null);
    f1.await(io);
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r1.status);
    try testing.expectEqualStrings("hello", r1.body);
    try testing.expect(r1.etag != null);
    try testing.expectEqualStrings("\"v1\"", r1.etag.?);

    // Second fetch with the ETag → 304 Not Modified, empty body.
    var f2 = io.async(EtagServer.serveOne, .{&srv});
    var r2 = try getConditional(testing.allocator, io, url, r1.etag.?);
    f2.await(io);
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 304), r2.status);
    try testing.expect(r2.not_modified);
    try testing.expectEqual(@as(usize, 0), r2.body.len);
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
            _ = getConditional(testing.allocator, io, &buf, null) catch return;
        }
    }.run, .{});
}

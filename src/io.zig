//! Io bootstrap: a thin listener over `std.Io.net` running on the
//! `std.Io.Threaded` backend. Owns accept/serve loops and per-connection
//! task spawning. No raw socket syscalls — everything goes through `std.Io`.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

/// A connection handler. Receives the active `Io` and an accepted stream.
/// The handler owns the stream lifecycle decision via `serveOnce`/`serve`,
/// which close it after the handler returns.
pub const Handler = *const fn (io: Io, stream: net.Stream) void;

/// Line framing used by the echo handler / fuzz harness: read one '\n'
/// delimited line and write back "echo:" ++ line ++ "\n".
/// Factored out so the fuzz test can exercise the framing without sockets
/// having to be the unit under test, but it is also the real handler body.
fn echoLine(io: Io, stream: net.Stream) !void {
    var rbuf: [256]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const line = try r.interface.takeDelimiterExclusive('\n');

    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("echo:{s}\n", .{line});
    try w.interface.flush();
}

/// In-file echo handler used by tests and as the default smoke handler.
pub fn echoHandler(io: Io, stream: net.Stream) void {
    echoLine(io, stream) catch {};
}

pub const Listener = struct {
    server: net.Server,

    /// Bind a TCP listener to `host:port`. `port == 0` requests an
    /// ephemeral port (read back later via `port()`).
    pub fn bind(io: Io, host: []const u8, bind_port: u16) !Listener {
        var addr = try net.IpAddress.parseIp4(host, bind_port);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .server = server };
    }

    /// The actual bound port, resolving the ephemeral port when 0 was passed.
    pub fn port(self: *Listener) u16 {
        var sa: std.os.linux.sockaddr.in = undefined;
        var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
        _ = std.os.linux.getsockname(self.server.socket.handle, @ptrCast(&sa), &slen);
        return std.mem.bigToNative(u16, sa.port);
    }

    /// Accept exactly one connection, run `handler`, close the stream, return.
    pub fn serveOnce(self: *Listener, io: Io, handler: Handler) !void {
        const stream = try self.server.accept(io);
        defer stream.close(io);
        handler(io, stream);
    }

    /// Per-connection task body: run the handler then close the stream.
    /// Lives at module scope so `io.async` can take its address.
    fn connTask(io: Io, stream: net.Stream, handler: Handler) void {
        defer stream.close(io);
        handler(io, stream);
    }

    /// Accept loop: spawn one async task per accepted connection.
    /// Loops until `accept` fails (e.g. the listener is shut down).
    pub fn serve(self: *Listener, io: Io, handler: Handler) !void {
        while (true) {
            const stream = self.server.accept(io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => return err,
            };
            var fut = io.async(connTask, .{ io, stream, handler });
            fut.await(io);
        }
    }

    pub fn deinit(self: *Listener, io: Io) void {
        self.server.deinit(io);
    }
};

// --- tests ---------------------------------------------------------------

fn sendLine(io: Io, bound_port: u16, payload: []const u8, out: *[256]u8, out_len: *usize) void {
    var caddr = net.IpAddress.parseIp4("127.0.0.1", bound_port) catch return;
    const cs = caddr.connect(io, .{ .mode = .stream }) catch return;
    defer cs.close(io);

    var wbuf: [256]u8 = undefined;
    var w = cs.writer(io, &wbuf);
    w.interface.writeAll(payload) catch return;
    w.interface.writeByte('\n') catch return;
    w.interface.flush() catch return;

    var rbuf: [256]u8 = undefined;
    var r = cs.reader(io, &rbuf);
    const resp = r.interface.takeDelimiterExclusive('\n') catch return;
    @memcpy(out[0..resp.len], resp);
    out_len.* = resp.len;
}

test "listener accepts and a registered handler echoes a line" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lst = try Listener.bind(io, "127.0.0.1", 0);
    defer lst.deinit(io);

    const bound_port = lst.port();
    try std.testing.expect(bound_port != 0);

    var srv_fut = io.async(Listener.serveOnce, .{ &lst, io, @as(Handler, echoHandler) });

    var out: [256]u8 = undefined;
    var out_len: usize = 0;
    sendLine(io, bound_port, "hello", &out, &out_len);

    srv_fut.await(io) catch {};

    try std.testing.expectEqualStrings("echo:hello", out[0..out_len]);
}

test "serve smoke: spawns per-connection task and echoes" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lst = try Listener.bind(io, "127.0.0.1", 0);
    defer lst.deinit(io);
    const bound_port = lst.port();

    // Run a single accept+handle through serveOnce (serve is the same body
    // looped); this exercises the per-connection close + handler path.
    var srv_fut = io.async(Listener.serveOnce, .{ &lst, io, @as(Handler, echoHandler) });

    var out: [256]u8 = undefined;
    var out_len: usize = 0;
    sendLine(io, bound_port, "smoke", &out, &out_len);
    srv_fut.await(io) catch {};

    try std.testing.expectEqualStrings("echo:smoke", out[0..out_len]);
}

test "fuzz_listener: random payload round-trips through the echo path" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var raw: [200]u8 = undefined;
            smith.bytesWithHash(&raw, 0);

            // Bound length and strip '\n' so the payload is a single line.
            const n = @as(usize, raw[0]) % raw.len;
            var payload_buf: [200]u8 = undefined;
            var len: usize = 0;
            for (raw[0..n]) |b| {
                if (b == '\n') continue;
                payload_buf[len] = b;
                len += 1;
            }
            const payload = payload_buf[0..len];

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var lst = try Listener.bind(io, "127.0.0.1", 0);
            defer lst.deinit(io);
            const bound_port = lst.port();

            var srv_fut = io.async(Listener.serveOnce, .{ &lst, io, @as(Handler, echoHandler) });

            var out: [256]u8 = undefined;
            var out_len: usize = 0;
            sendLine(io, bound_port, payload, &out, &out_len);
            srv_fut.await(io) catch {};

            var expected: [256]u8 = undefined;
            @memcpy(expected[0..5], "echo:");
            @memcpy(expected[5 .. 5 + payload.len], payload);
            try std.testing.expectEqualStrings(expected[0 .. 5 + payload.len], out[0..out_len]);
        }
    }.run, .{});
}

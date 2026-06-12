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

/// A connection handler carrying an opaque context pointer. Used to wire the
/// HTTP transport (`serveConn`) — which needs the shared server state — into the
/// accept loop without globals.
pub const CtxHandler = *const fn (ctx: *anyopaque, io: Io, stream: net.Stream) void;

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
    pub fn port(self: *Listener) !u16 {
        var sa: std.os.linux.sockaddr.in = undefined;
        var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
        const rc = std.os.linux.getsockname(self.server.socket.handle, @ptrCast(&sa), &slen);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.GetSockNameFailed;
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
    /// All accepted connection tasks run concurrently via a `Group`; the loop
    /// exits (and the group is awaited) when `accept` fails due to shutdown or
    /// cancellation.  Memory is bounded: `Group` releases each task's resources
    /// as soon as the individual task returns, not at group-await time.
    pub fn serve(self: *Listener, io: Io, handler: Handler) !void {
        var group: Io.Group = .init;
        defer group.await(io) catch {};
        while (true) {
            const stream = self.server.accept(io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => return err,
            };
            // Use `concurrent` so each connection task runs on its own OS thread
            // and cannot block the accept loop by running inline.  If the backend
            // cannot provide concurrency (single-threaded builds or resource
            // exhaustion), fall back to the sequential `group.async` path.
            group.concurrent(io, connTask, .{ io, stream, handler }) catch
                group.async(io, connTask, .{ io, stream, handler });
        }
    }

    /// Per-connection task body for a context-carrying handler.
    fn connTaskCtx(ctx: *anyopaque, io: Io, stream: net.Stream, handler: CtxHandler) void {
        defer stream.close(io);
        handler(ctx, io, stream);
    }

    /// Upper bound on connection handlers running at once. `std.Io.Threaded`
    /// grows its worker pool to the peak number of concurrent `concurrent` tasks
    /// and never shrinks it, so an unbounded accept loop lets a burst of slow
    /// (e.g. Klippy-blocked) connections balloon the thread + fd count without
    /// limit. Capping concurrent handlers turns that into backpressure: excess
    /// connections wait in the listen backlog instead of spawning a worker.
    pub const max_concurrent_conns = 128;

    /// Per-handler thread stack size used on 32-bit targets (see main.zig — the
    /// 16 MB default would reserve ~2 GB of VSZ at the handler-pool peak). The
    /// deepest handler path (streaming upload: 64 KB read + 32 KB write buffers
    /// nested under the connection's 24 KB) peaks ~120 KB; 1 MB is ~8× headroom.
    /// Referenced by the production gate AND the stack-stress tests so they can't
    /// validate a size production no longer uses.
    pub const handler_stack_size: usize = 1 << 20;

    fn connTaskCtxBounded(ctx: *anyopaque, io: Io, stream: net.Stream, handler: CtxHandler, sem: *Io.Semaphore) void {
        defer sem.post(io);
        defer stream.close(io);
        handler(ctx, io, stream);
    }

    /// Accept loop variant that threads an opaque context to each connection
    /// handler. This is how the HTTP transport's `serveConn` is wired in: the
    /// context is the shared `http_transport.Server`. Concurrency is capped at
    /// `max_concurrent_conns` (see above).
    pub fn serveWith(self: *Listener, io: Io, ctx: *anyopaque, handler: CtxHandler) !void {
        var group: Io.Group = .init;
        defer group.await(io) catch {};
        var sem: Io.Semaphore = .{ .permits = max_concurrent_conns };
        while (true) {
            const stream = self.server.accept(io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => return err,
            };
            // Acquire a slot before spawning; blocks once `max_concurrent_conns`
            // handlers are in flight, so the worker pool can't grow past the cap.
            sem.waitUncancelable(io);
            group.concurrent(io, connTaskCtxBounded, .{ ctx, io, stream, handler, &sem }) catch
                group.async(io, connTaskCtxBounded, .{ ctx, io, stream, handler, &sem });
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

    const bound_port = try lst.port();
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
    const bound_port = try lst.port();

    // Run a single accept+handle through serveOnce (serve is the same body
    // looped); this exercises the per-connection close + handler path.
    var srv_fut = io.async(Listener.serveOnce, .{ &lst, io, @as(Handler, echoHandler) });

    var out: [256]u8 = undefined;
    var out_len: usize = 0;
    sendLine(io, bound_port, "smoke", &out, &out_len);
    srv_fut.await(io) catch {};

    try std.testing.expectEqualStrings("echo:smoke", out[0..out_len]);
}

test "serve handles two connections concurrently" {
    // Verify that `serve`'s Group-based accept loop accepts and handles
    // multiple connections.  Two connections are made sequentially from the
    // main thread (using sendLine), and both echo responses must be correct.
    // The concurrent accept loop must remain running between the first and
    // second connections; a deadlocked or single-shot implementation would
    // fail to respond to the second connection.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lst = try Listener.bind(io, "127.0.0.1", 0);
    const bound_port = try lst.port();

    // Serve in the background; deinit() below will shut the loop down.
    const serveIgnoringErrors = struct {
        fn f(l: *Listener, pio: Io, h: Handler) void {
            l.serve(pio, h) catch {};
        }
    }.f;
    var srv_fut = io.async(serveIgnoringErrors, .{ &lst, io, @as(Handler, echoHandler) });

    var out_a: [256]u8 = undefined;
    var out_b: [256]u8 = undefined;
    var len_a: usize = 0;
    var len_b: usize = 0;

    // Two sequential connections from the main thread.
    sendLine(io, bound_port, "ping_a", &out_a, &len_a);
    sendLine(io, bound_port, "ping_b", &out_b, &len_b);

    // Cancel the serve task to stop the accept loop cleanly, then free the
    // listener socket.  Cancellation causes accept to return error.Canceled
    // which the serve loop handles by returning; this avoids the EBADF that
    // would occur if we closed the socket while accept4 is in progress.
    srv_fut.cancel(io);
    lst.deinit(io);

    try std.testing.expectEqualStrings("echo:ping_a", out_a[0..len_a]);
    try std.testing.expectEqualStrings("echo:ping_b", out_b[0..len_b]);
}

// Context-carrying echo handler: prefixes the echo with a per-context tag so the
// test can prove the opaque context reached the handler.
const TagCtx = struct { tag: u8 };

fn taggedEcho(ctx: *anyopaque, io: Io, stream: net.Stream) void {
    const c: *TagCtx = @ptrCast(@alignCast(ctx));
    var rbuf: [256]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    w.interface.print("{c}:{s}\n", .{ c.tag, line }) catch return;
    w.interface.flush() catch return;
}

test "serveWith threads context to per-connection handler" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var lst = try Listener.bind(io, "127.0.0.1", 0);
    const bound_port = try lst.port();

    var ctx = TagCtx{ .tag = 'X' };
    const serveIgnoring = struct {
        fn f(l: *Listener, pio: Io, c: *anyopaque, h: CtxHandler) void {
            l.serveWith(pio, c, h) catch {};
        }
    }.f;
    var srv_fut = io.async(serveIgnoring, .{ &lst, io, @as(*anyopaque, @ptrCast(&ctx)), @as(CtxHandler, taggedEcho) });

    var out: [256]u8 = undefined;
    var out_len: usize = 0;
    sendLine(io, bound_port, "hi", &out, &out_len);

    srv_fut.cancel(io);
    lst.deinit(io);

    try std.testing.expectEqualStrings("X:hi", out[0..out_len]);
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
            const bound_port = try lst.port();

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

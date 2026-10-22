//! Io bootstrap: a thin listener over `std.Io.net` running on the
//! `std.Io.Threaded` backend. Owns the accept loop and per-connection task
//! spawning. Socket I/O uses `std.Io`; TCP_NODELAY uses typed libc because
//! `std.Io.net` has no socket-option setter.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

pub fn initThreaded(alloc: std.mem.Allocator, environ: std.process.Environ) std.Io.Threaded {
    return .init(alloc, .{ .stack_size = Listener.handler_stack_size, .environ = environ });
}

/// A connection handler carrying an opaque context pointer. Used to wire the
/// HTTP transport (`serveConn`) — which needs the shared server state — into the
/// accept loop without globals.
pub const CtxHandler = *const fn (ctx: *anyopaque, io: Io, stream: net.Stream) void;

/// Wait after an accept failure caused by descriptor or memory exhaustion, so
/// the loop does not spin while connections close and free resources.
const accept_retry_delay: Io.Duration = .fromSeconds(1);

fn tcpNoDelay(socket: net.Socket) error{SocketOptionFailed}!void {
    const enabled: c_int = 1;
    if (std.c.setsockopt(socket.handle, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enabled, @sizeOf(c_int)) != 0)
        return error.SocketOptionFailed;
}

pub const Listener = struct {
    server: net.Server,

    /// Bind a TCP listener to `host:port`. `port == 0` requests an
    /// ephemeral port (read back later via `port()`).
    pub fn bind(io: Io, host: []const u8, bind_port: u16) !Listener {
        var addr = try net.IpAddress.parse(host, bind_port);
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        // Linux inherits this flag on accept, including after WebSocket upgrade.
        try tcpNoDelay(server.socket);
        return .{ .server = server };
    }

    /// The actual bound port, resolving the ephemeral port when 0 was passed.
    pub fn port(self: *const Listener) u16 {
        return self.server.socket.address.getPort();
    }

    /// Upper bound on connection handlers running at once. `std.Io.Threaded`
    /// grows its worker pool to the peak number of concurrent `concurrent` tasks
    /// and never shrinks it, so an unbounded accept loop lets a burst of slow
    /// (e.g. Klippy-blocked) connections balloon the thread + fd count without
    /// limit. Capping concurrent handlers turns that into backpressure: excess
    /// connections wait in the listen backlog instead of spawning a worker.
    pub const max_concurrent_conns = 128;

    /// Per-handler stack size used by the daemon's owned Threaded backend. The
    /// deepest handler path (streaming upload: 64 KB read + 32 KB write buffers
    /// nested under the connection's 24 KB) peaks ~120 KB; 1 MB is ~8× headroom.
    /// Referenced by runtime initialization and stack-stress tests so they can't
    /// validate a size production no longer uses.
    pub const handler_stack_size: usize = 1 << 20;

    fn connTaskCtxBounded(ctx: *anyopaque, io: Io, stream: net.Stream, handler: CtxHandler, sem: *Io.Semaphore) void {
        defer sem.post(io);
        defer stream.close(io);
        handler(ctx, io, stream);
    }

    /// Accept loop: run `handler` with `ctx` for each connection on its own
    /// task, at most `max_concurrent_conns` at once. A failed accept of one
    /// connection does not stop the loop; descriptor or memory exhaustion
    /// waits `accept_retry_delay` first. Returns when the listener shuts down
    /// or the loop is canceled, after canceling and joining live connections.
    pub fn serveWith(self: *Listener, io: Io, ctx: *anyopaque, handler: CtxHandler) !void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        var sem: Io.Semaphore = .{ .permits = max_concurrent_conns };
        while (true) {
            const stream = self.server.accept(io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                error.ConnectionAborted, error.ProtocolFailure, error.BlockedByFirewall => continue,
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => {
                    try io.sleep(accept_retry_delay, .awake);
                    continue;
                },
                error.NetworkDown, error.WouldBlock, error.Unexpected => return err,
            };
            // Acquire a slot before spawning; blocks once `max_concurrent_conns`
            // handlers are in flight, so the worker pool can't grow past the cap.
            sem.wait(io) catch |err| {
                stream.close(io);
                return err;
            };
            group.concurrent(io, connTaskCtxBounded, .{ ctx, io, stream, handler, &sem }) catch
                group.async(io, connTaskCtxBounded, .{ ctx, io, stream, handler, &sem });
        }
    }

    pub fn deinit(self: *Listener, io: Io) void {
        self.server.deinit(io);
    }
};

// --- tests ---------------------------------------------------------------

test "accepted TCP sockets inherit NODELAY on both IP families" {
    const io = std.testing.io;
    for ([_][]const u8{ "127.0.0.1", "::1" }) |host| {
        var listener = try Listener.bind(io, host, 0);
        defer listener.deinit(io);
        const client = try listener.server.socket.address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const accepted = try listener.server.accept(io);
        defer accepted.close(io);
        var enabled: c_int = 0;
        var len: std.c.socklen_t = @sizeOf(c_int);
        try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(accepted.socket.handle, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enabled, &len));
        try std.testing.expectEqual(@as(c_int, 1), enabled);
    }
    try std.testing.expectError(error.SocketOptionFailed, tcpNoDelay(.{ .handle = -1, .address = try net.IpAddress.parse("127.0.0.1", 0) }));
}

test "fuzz TCP listeners preserve NODELAY across repeated accepts" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            const host = if (smith.value(bool)) "127.0.0.1" else "::1";
            var listener = try Listener.bind(io, host, 0);
            defer listener.deinit(io);
            const count = smith.valueRangeAtMostWithHash(u8, 1, 4, 1);
            for (0..count) |_| {
                const client = try listener.server.socket.address.connect(io, .{ .mode = .stream });
                defer client.close(io);
                const accepted = try listener.server.accept(io);
                defer accepted.close(io);
                var enabled: c_int = 0;
                var len: std.c.socklen_t = @sizeOf(c_int);
                try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(accepted.socket.handle, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enabled, &len));
                try std.testing.expectEqual(@as(c_int, 1), enabled);
            }
        }
    }.run, .{});
}

fn sendLine(io: Io, address: net.IpAddress, payload: []const u8, out: *[256]u8) ![]const u8 {
    const cs = try address.connect(io, .{ .mode = .stream });
    defer cs.close(io);

    var wbuf: [256]u8 = undefined;
    var w = cs.writer(io, &wbuf);
    try w.interface.writeAll(payload);
    try w.interface.writeByte('\n');
    try w.interface.flush();

    var r = cs.reader(io, out);
    return r.interface.takeDelimiterExclusive('\n');
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

fn serveIgnoring(l: *Listener, io: Io, c: *anyopaque, h: CtxHandler) void {
    l.serveWith(io, c, h) catch {};
}

test "serveWith threads context to per-connection handlers on both IP families" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for ([_][]const u8{ "127.0.0.1", "::1" }) |host| {
        var lst = try Listener.bind(io, host, 0);
        try std.testing.expect(lst.port() != 0);
        var ctx = TagCtx{ .tag = 'X' };
        var srv_fut = io.async(serveIgnoring, .{ &lst, io, @as(*anyopaque, @ptrCast(&ctx)), @as(CtxHandler, taggedEcho) });
        const address = try net.IpAddress.parse(host, lst.port());
        var out_a: [256]u8 = undefined;
        var out_b: [256]u8 = undefined;
        // Two sequential connections: the loop keeps accepting.
        const a = sendLine(io, address, "hi", &out_a);
        const b = sendLine(io, address, "again", &out_b);
        srv_fut.cancel(io);
        lst.deinit(io);
        try std.testing.expectEqualStrings("X:hi", try a);
        try std.testing.expectEqualStrings("X:again", try b);
    }
}

/// Handler that blocks until the peer closes, like an idle WebSocket session.
fn holdOpen(_: *anyopaque, io: Io, stream: net.Stream) void {
    var rbuf: [16]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    _ = r.interface.discardRemaining() catch {};
}

test "canceling serveWith cancels live connections instead of waiting for them" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lst = try Listener.bind(io, "127.0.0.1", 0);
    defer lst.deinit(io);
    var ctx = TagCtx{ .tag = 'X' };
    var srv_fut = io.async(serveIgnoring, .{ &lst, io, @as(*anyopaque, @ptrCast(&ctx)), @as(CtxHandler, holdOpen) });
    const client = try (try net.IpAddress.parse("127.0.0.1", lst.port())).connect(io, .{ .mode = .stream });
    defer client.close(io);
    // Let the server accept the connection and start the handler.
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = Io.Clock.Timestamp.now(io, .awake);
    srv_fut.cancel(io);
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 1000);
}

test "canceling a saturated listener releases the accepted connection" {
    const Ctx = struct {
        io: Io,
        listener: *Listener,
        accepted: std.atomic.Value(usize) = .init(0),
        canceled: Io.Event = .unset,
        future: ?Io.Future(void) = null,
        fn handler(raw: *anyopaque, io: Io, stream: net.Stream) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.accepted.fetchAdd(1, .release);
            holdOpen(raw, io, stream);
        }
        fn serve(self: *@This()) void {
            self.listener.serveWith(self.io, self, handler) catch {};
        }
        fn cancel(self: *@This()) void {
            self.future.?.cancel(self.io);
            self.canceled.set(self.io);
        }
    };
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = Listener.handler_stack_size });
    defer threaded.deinit();
    const io = threaded.io();
    var listener = try Listener.bind(io, "127.0.0.1", 0);
    defer listener.deinit(io);
    var ctx: Ctx = .{ .io = io, .listener = &listener };
    ctx.future = try io.concurrent(Ctx.serve, .{&ctx});
    defer if (!ctx.canceled.isSet()) ctx.future.?.cancel(io);
    var clients: [Listener.max_concurrent_conns + 1]net.Stream = undefined;
    var count: usize = 0;
    defer for (clients[0..count]) |client| client.close(io);
    const address = try net.IpAddress.parse("127.0.0.1", listener.port());
    for (&clients) |*client| {
        client.* = try address.connect(io, .{ .mode = .stream });
        count += 1;
    }
    const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (ctx.accepted.load(.acquire) != Listener.max_concurrent_conns) {
        if (deadline.nanoseconds <= Io.Clock.awake.now(io).nanoseconds) return error.Timeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // Let accept consume the extra connection before canceling the slot wait.
    try io.sleep(.fromMilliseconds(30), .awake);
    var canceler = try io.concurrent(Ctx.cancel, .{&ctx});
    const timely = if (ctx.canceled.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } })) |_| true else |_| false;
    // A regression must fail rather than leave uncancelable workers wedged.
    for (clients[0..count]) |client| client.shutdown(io, .both) catch {};
    canceler.await(io);
    try std.testing.expect(timely);
}

test "fuzz_listener: random payload round-trips through serveWith" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lst = try Listener.bind(io, "127.0.0.1", 0);
    var ctx = TagCtx{ .tag = 'F' };
    var srv_fut = io.async(serveIgnoring, .{ &lst, io, @as(*anyopaque, @ptrCast(&ctx)), @as(CtxHandler, taggedEcho) });
    defer {
        srv_fut.cancel(io);
        lst.deinit(io);
    }
    const Ctx = struct { io: Io, address: net.IpAddress };
    try std.testing.fuzz(Ctx{ .io = io, .address = try net.IpAddress.parse("127.0.0.1", lst.port()) }, struct {
        fn run(c: Ctx, smith: *std.testing.Smith) anyerror!void {
            var payload: [200]u8 = undefined;
            const n = smith.valueRangeAtMostWithHash(u8, 0, payload.len, 0);
            smith.bytesWithHash(payload[0..n], 1);
            // A single line: no '\n' in the payload.
            std.mem.replaceScalar(u8, payload[0..n], '\n', ' ');
            var out: [256]u8 = undefined;
            const echoed = try sendLine(c.io, c.address, payload[0..n], &out);
            try std.testing.expectEqualStrings("F:", echoed[0..2]);
            try std.testing.expectEqualStrings(payload[0..n], echoed[2..]);
        }
    }.run, .{});
}

fn expectChildEnvironment(marker: []const u8) !void {
    const alloc = std.heap.smp_allocator;
    var entry_buffer: [128]u8 = undefined;
    const entry = try std.fmt.bufPrintSentinel(&entry_buffer, "PHOBOS_IO_TEST={s}", .{marker}, 0);
    const block = [_:null]?[*:0]const u8{ entry.ptr, "PATH=/usr/bin:/bin" };
    var threaded = initThreaded(alloc, .{ .block = .{ .slice = &block } });
    defer threaded.deinit();
    const aio = threaded.io();
    const output = try @import("util/process.zig").run(alloc, aio, .{
        .argv = &.{ "printenv", "PHOBOS_IO_TEST" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = .{ .deadline = .fromNow(aio, .{ .raw = .fromSeconds(3), .clock = .awake }) },
    });
    defer alloc.free(output.stdout);
    defer alloc.free(output.stderr);
    var expected_buffer: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{s}\n", .{marker});
    try std.testing.expectEqualStrings(expected, output.stdout);
    try std.testing.expect(output.term == .exited and output.term.exited == 0);
}

test "runtime I/O preserves the environment passed to child processes" {
    try expectChildEnvironment("retained");
}

test "fuzz runtime I/O child environment retains variable values" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var marker_buffer: [32]u8 = undefined;
            const marker = try std.fmt.bufPrint(&marker_buffer, "{d}", .{smith.value(u32)});
            try expectChildEnvironment(marker);
        }
    }.run, .{});
}

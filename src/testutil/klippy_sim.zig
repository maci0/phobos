//! Minimal Klippy simulator for integration-testing the phobos Klippy bridge.
//!
//! Runs as an owned task with a `std.Io.Threaded` backend, creates a
//! Unix-domain socket, accepts a single connection, and speaks the
//! \x03-delimited JSON-RPC 2.0 protocol that the real Klippy uses.  The
//! simulator answers the bridge handshake (`info` polls, `objects/subscribe`,
//! `objects/query`, `gcode/subscribe_output`), then answers gcode, print and
//! query requests with fixed results. It never pushes unsolicited status.
//!
//! Usage:
//!   var sim = try KlippySim.init(alloc, ".zig-cache/tmp/<sub_path>/klippy.sock");
//!   defer sim.deinit();
//!   try sim.start();
//!   try sim.waitReady();

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const framing = @import("../util/klippy_frame.zig");

pub const KlippySim = struct {
    const Self = @This();

    const ready_polls = 200;
    const ready_poll_ns = 10 * std.time.ns_per_ms;

    alloc: std.mem.Allocator,
    socket_path: []const u8,

    /// Owned IO backend (created by start, referenced by the simulator thread).
    threaded: ?*std.Io.Threaded = null,
    io: ?Io = null,

    /// Listener socket (created by start, closed after the task is joined).
    listener: ?net.Server = null,
    read_buffer: [4096]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    task: ?Io.Future(void) = null,

    /// Atomic flags for synchronisation with the test thread.
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// How many server.info polls return "startup" before switching to
    /// "ready" (default 2).
    startup_polls: u32 = 2,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .socket_path = try alloc.dupe(u8, socket_path),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);
    }

    /// Start the simulator as a concurrent task. Returns immediately.
    /// On error the simulator is left stopped, with no I/O backend.
    pub fn start(self: *Self) !void {
        const threaded = try self.alloc.create(std.Io.Threaded);
        errdefer self.alloc.destroy(threaded);
        threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
        errdefer threaded.deinit();
        const io = threaded.io();

        // Remove a stale socket file from an earlier run.
        std.Io.Dir.cwd().deleteFile(io, self.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const addr = try net.UnixAddress.init(self.socket_path);
        var listener = try addr.listen(io, .{});
        errdefer {
            listener.deinit(io);
            std.Io.Dir.cwd().deleteFile(io, self.socket_path) catch {};
        }

        // runTask reads these, so publish them before spawning it.
        self.threaded = threaded;
        self.io = io;
        self.listener = listener;
        self.stop_flag.store(false, .release);
        self.ready.store(false, .release);
        self.running.store(true, .release);
        errdefer {
            self.running.store(false, .release);
            self.threaded = null;
            self.io = null;
            self.listener = null;
        }
        self.task = try io.concurrent(runTask, .{self});
    }

    /// Wait up to `ready_polls` x `ready_poll_ns` for the handshake. Fails
    /// when the simulator stops or the bridge never completes it.
    pub fn waitReady(self: *Self) !void {
        var polls: u32 = 0;
        while (!self.ready.load(.acquire)) : (polls += 1) {
            if (polls == ready_polls or !self.running.load(.acquire)) return error.KlippySimNotReady;
            std.Io.sleep(self.io.?, .{ .nanoseconds = ready_poll_ns }, .awake) catch {};
        }
    }

    /// Cancel and join pending accept, read or write operations. Idempotent.
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.stop_flag.store(true, .release);
        if (self.task) |*task| {
            task.cancel(self.io.?);
            self.task = null;
        }
        if (self.listener) |l| l.socket.close(self.io.?);
        self.listener = null;
        // Clean up the socket file.
        if (self.io) |sio| {
            std.Io.Dir.cwd().deleteFile(sio, self.socket_path) catch {};
        }
        if (self.threaded) |thr| {
            thr.deinit();
            self.alloc.destroy(thr);
            self.threaded = null;
            self.io = null;
        }
    }

    // -----------------------------------------------------------------------
    // Internal: concurrent task
    // -----------------------------------------------------------------------

    fn runTask(self: *Self) void {
        defer self.running.store(false, .release);
        var task_gpa: std.heap.DebugAllocator(.{}) = .init;
        defer if (task_gpa.deinit() == .leak) std.log.err("KlippySim: the task leaked memory", .{});
        const alloc = task_gpa.allocator();

        const io = self.io.?;

        // Check stop flag before blocking on accept.
        if (self.stop_flag.load(.acquire)) return;

        // Use Io-based accept so the non-blocking listener socket works
        // correctly with the Threaded backend.
        const stream = self.listener.?.accept(io) catch return;
        defer stream.close(io);
        self.reader = stream.reader(io, &self.read_buffer);

        // ----- Handshake -----
        if (!self.doHandshake(io, stream, alloc)) return;

        self.ready.store(true, .release);

        // ----- Ready: read/respond loop -----
        self.readLoop(io, stream, alloc);
    }

    // -----------------------------------------------------------------------
    // Handshake
    // -----------------------------------------------------------------------

    fn doHandshake(self: *Self, io: Io, stream: net.Stream, alloc: std.mem.Allocator) bool {
        var poll_count: u32 = 0;
        var ready_sent: bool = false;
        var sub_done: bool = false;
        var gcode_done: bool = false;

        while (!self.stop_flag.load(.acquire)) {
            const payload = self.readFrame(alloc) catch {
                return false;
            };
            defer alloc.free(payload);

            const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch {
                return false;
            };
            defer parsed.deinit();
            const frame = parsed.value;

            const method = if (frame.object.get("method")) |m| m.string else "";
            const id = if (frame.object.get("id")) |id_val| id_val else null;

            // Real Klippy handshake: `info` (identify + state polls), then
            // `objects/subscribe` and `gcode/subscribe_output` (each with a
            // response_template). No `server.connection.identify` exists.
            if (std.mem.eql(u8, method, "info")) {
                const is_ready = poll_count >= self.startup_polls;
                const state_str: []const u8 = if (is_ready) "ready" else "startup";
                const id_str: []const u8 = idStrVal(id);
                var buf: [512]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{{\"state\":\"{s}\",\"state_message\":\"Printer is ready\",\"software_version\":\"v0.12.0-sim\",\"hostname\":\"sim\"}}}}",
                    .{ id_str, state_str },
                ) catch return false;
                self.writeFrame(io, stream, resp) catch return false;
                poll_count += 1;
                if (is_ready) ready_sent = true;
            } else if (std.mem.eql(u8, method, "objects/subscribe")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{{\"eventtime\":0.0,\"status\":{{}}}}}}",
                    .{id_str},
                ) catch return false;
                self.writeFrame(io, stream, resp) catch return false;
                sub_done = true;
            } else if (std.mem.eql(u8, method, "objects/query")) {
                // Handshake asks heaters for the temperature store. No sensors
                // here: the client skips the second subscribe and stays ready.
                const id_str: []const u8 = idStrVal(id);
                var buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{{\"eventtime\":1.0,\"status\":{{\"heaters\":{{\"available_sensors\":[],\"available_monitors\":[]}}}}}}}}",
                    .{id_str},
                ) catch return false;
                self.writeFrame(io, stream, resp) catch return false;
            } else if (std.mem.eql(u8, method, "gcode/subscribe_output")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{{}}}}",
                    .{id_str},
                ) catch return false;
                self.writeFrame(io, stream, resp) catch return false;
                gcode_done = true;
            } else {
                return false;
            }

            // Handshake complete once Klippy is ready and both subscriptions
            // have been acknowledged.
            if (ready_sent and sub_done and gcode_done) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Read/respond loop (post-handshake)
    // -----------------------------------------------------------------------

    fn readLoop(self: *Self, io: Io, stream: net.Stream, alloc: std.mem.Allocator) void {
        var resp_id: u32 = 1000;

        while (!self.stop_flag.load(.acquire)) {
            // Read and handle one frame.
            const payload = self.readFrame(alloc) catch {
                return;
            };
            defer alloc.free(payload);

            const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch continue;
            defer parsed.deinit();
            const frame = parsed.value;

            const method = if (frame.object.get("method")) |m| m.string else "";
            const id = if (frame.object.get("id")) |id_val| id_val else null;

            if (std.mem.eql(u8, method, "gcode/script")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":\"ok\"}}",
                    .{id_str},
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;

                resp_id += 1;
                var gr_buf: [256]u8 = undefined;
                const gr = std.fmt.bufPrint(
                    &gr_buf,
                    "{{\"jsonrpc\":\"2.0\",\"method\":\"process_gcode_response\",\"id\":\"{d}\",\"params\":\"ok\"}}",
                    .{resp_id},
                ) catch continue;
                self.writeFrame(io, stream, gr) catch return;

                // Real Klippy restarts its connection after RESTART / FIRMWARE_RESTART.
                const script = if (frame.object.get("params")) |p|
                    if (p.object.get("script")) |s| s.string else ""
                else
                    "";
                if (std.mem.eql(u8, script, "RESTART") or std.mem.eql(u8, script, "FIRMWARE_RESTART")) {
                    // Let the buffered result drain before the restart closes the socket.
                    std.Io.sleep(io, .{ .nanoseconds = 50_000_000 }, .real) catch {};
                    self.stop_flag.store(true, .release);
                    return;
                }
            } else if (std.mem.eql(u8, method, "emergency_stop")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":\"ok\"}}",
                    .{id_str},
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;
            } else if (std.mem.startsWith(u8, method, "pause_resume/")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":\"ok\"}}",
                    .{id_str},
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;
            } else if (std.mem.eql(u8, method, "server.info")) {
                const id_str: []const u8 = idStrVal(id);
                var buf: [512]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{{\"state\":\"ready\",\"state_message\":\"sim\",\"version\":\"v0.12.0-sim\",\"hostname\":\"sim\"}}}}",
                    .{id_str},
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;
            } else if (std.mem.eql(u8, method, "objects/subscribe") or
                std.mem.eql(u8, method, "objects/query") or
                std.mem.eql(u8, method, "register_remote_method"))
            {
                const id_str: []const u8 = idStrVal(id);
                const result = if (std.mem.eql(u8, method, "objects/subscribe"))
                    "{\"eventtime\":1,\"status\":{}}"
                else
                    "null";
                var buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{s}}}",
                    .{ id_str, result },
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Wire helpers
    // -----------------------------------------------------------------------

    fn readFrame(self: *Self, alloc: std.mem.Allocator) ![]const u8 {
        if (self.stop_flag.load(.acquire)) return error.SimulatorStopped;
        return framing.read(alloc, &self.reader.?.interface);
    }

    fn writeFrame(self: *Self, io: Io, stream: net.Stream, payload: []const u8) !void {
        _ = self;
        var wbuf: [4096]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try framing.write(&w.interface, payload);
        try w.interface.flush();
    }

    fn idStrVal(id: ?std.json.Value) []const u8 {
        return if (id) |i| switch (i) {
            .string => |s| s,
            else => "0",
        } else "0";
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `name` inside `tmp`, relative to the cwd (short enough for `sun_path`).
fn tmpSocketPath(buf: []u8, tmp: *const testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path, name });
}

test "KlippySim: init/deinit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const path = try tmpSocketPath(&buf, &tmp, "sim.sock");
    const sim = try KlippySim.init(testing.allocator, path);
    defer sim.deinit();
    try testing.expectEqualStrings(path, sim.socket_path);
    try testing.expect(sim.socket_path.ptr != path.ptr);
    try testing.expect(!sim.running.load(.acquire));
    try testing.expect(sim.io == null);
}

test "KlippySim: start/stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const sim = try KlippySim.init(testing.allocator, try tmpSocketPath(&buf, &tmp, "sim.sock"));
    defer sim.deinit();
    try sim.start();
    try testing.expect(sim.running.load(.acquire));
    try tmp.dir.access(sim.io.?, "sim.sock", .{});
    sim.stop();
    try testing.expect(!sim.running.load(.acquire));
    try testing.expect(sim.io == null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "sim.sock", .{}));
}

test "KlippySim: failed start leaves the simulator stopped" {
    // Longer than sun_path, so listen fails after the I/O backend exists.
    const path: [200]u8 = @splat('s');
    const sim = try KlippySim.init(testing.allocator, &path);
    defer sim.deinit();
    try testing.expectError(error.NameTooLong, sim.start());
    try testing.expect(!sim.running.load(.acquire));
    try testing.expect(sim.io == null);
    try testing.expect(sim.threaded == null);
    try testing.expect(sim.listener == null);
}

test "KlippySim: stop wakes a thread blocked in accept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const sim = try KlippySim.init(testing.allocator, try tmpSocketPath(&buf, &tmp, "sim.sock"));
    defer sim.deinit();
    try sim.start();
    // Give the sim thread time to block in accept before stopping it.
    try std.Io.sleep(sim.io.?, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake);
    sim.stop();
    try testing.expect(!sim.running.load(.acquire));
}

test "KlippySim: stop interrupts an accepted silent peer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const sim = try KlippySim.init(testing.allocator, try tmpSocketPath(&buf, &tmp, "sim.sock"));
    defer sim.deinit();
    try sim.start();
    const io = testing.io;
    const stream = try (try net.UnixAddress.init(sim.socket_path)).connect(io);
    defer stream.close(io);
    var write_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("{\"method\":\"info\",\"id\":\"1\"}\x03");
    try writer.interface.flush();
    var read_buf: [512]u8 = undefined;
    var data = [_][]u8{&read_buf};
    const response = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    const read_result = try response.net_read;
    try testing.expect(read_result.data_len != 0);
    var release = try io.concurrent(struct {
        fn later(pio: Io, peer: net.Stream) !void {
            try pio.sleep(.fromMilliseconds(500), .awake);
            try peer.shutdown(pio, .both);
        }
    }.later, .{ io, stream });
    defer release.cancel(io) catch {};
    const start = Io.Clock.Timestamp.now(io, .awake);
    sim.stop();
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 250);
    try testing.expect(!sim.running.load(.acquire));
}

test "KlippySim: waitReady fails when no bridge connects" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [128]u8 = undefined;
    const sim = try KlippySim.init(testing.allocator, try tmpSocketPath(&buf, &tmp, "sim.sock"));
    defer sim.deinit();
    try sim.start();
    try testing.expectError(error.KlippySimNotReady, sim.waitReady());
}

test "KlippySim: fuzz init/start/stop never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var path_buf: [64]u8 = undefined;
            smith.bytesWithHash(&path_buf, 0);
            var safe: [32]u8 = undefined;
            var len: usize = 0;
            for (path_buf[0..@min(path_buf.len, 30)]) |b| {
                const c: u8 = 'a' + (b % 26);
                safe[len] = c;
                len += 1;
            }
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [128]u8 = undefined;
            const sim = try KlippySim.init(testing.allocator, try tmpSocketPath(&buf, &tmp, safe[0..len]));
            defer sim.deinit();
            try sim.start();
            try testing.expect(sim.running.load(.acquire));
            const peer = if (smith.valueWithHash(bool, 1)) try (try net.UnixAddress.init(sim.socket_path)).connect(testing.io) else null;
            defer if (peer) |stream| stream.close(testing.io);
            if (peer) |stream| {
                var write_buf: [128]u8 = undefined;
                var writer = stream.writer(testing.io, &write_buf);
                try writer.interface.writeAll("{\"method\":\"info\"");
                try writer.interface.flush();
            }
            sim.stop();
            try testing.expect(!sim.running.load(.acquire));
        }
    }.run, .{});
}

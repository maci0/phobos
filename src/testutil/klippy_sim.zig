//! Minimal Klippy simulator for integration-testing the phobos Klippy bridge.
//!
//! Runs on its own thread with a `std.Io.Threaded` backend, creates a
//! Unix-domain socket, accepts a single connection, and speaks the
//! \x03-delimited JSON-RPC 2.0 protocol that the real Klippy uses.  The
//! simulator handles the full handshake (identify, server.info polling,
//! objects/subscribe, register_remote_method) and then enters a controlled
//! read/respond loop where the test thread can inject status updates, gcode
//! responses, and trigger shutdown/disconnect.
//!
//! Usage:
//!   var sim = try KlippySim.init(alloc, "/tmp/phobos_test_klippy");
//!   defer sim.deinit();
//!   try sim.start();
//!   defer sim.stop();
//!   sim.waitReady();
//!   sim.pushStatus(.printing, "test.gcode");
//!   sim.pushShutdown();

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const framing = @import("../util/klippy_frame.zig");

// ---------------------------------------------------------------------------
// Shared control state (test thread writes, simulator thread reads)
// ---------------------------------------------------------------------------

pub const PrintState = enum {
    standby,
    printing,
    paused,
    complete,
    @"error",
    cancelled,
};

pub const Command = union(enum) {
    none,
    status: struct {
        state: PrintState,
        filename: []const u8,
    },
    gcode_response: []const u8,
    shutdown,
    disconnect,
};

pub const KlippySim = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    socket_path: []const u8,

    /// Owned IO backend (created by start, referenced by the simulator thread).
    threaded: ?*std.Io.Threaded = null,
    io: ?Io = null,

    /// Listener socket (created by start, closed by stop to unblock accept).
    listener: ?net.Server = null,
    read_buffer: [4096]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    thread: ?std.Thread = null,

    /// Atomic flags for synchronisation with the test thread.
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Pending command from the test thread.  cmd_ready acts as a lock:
    /// test thread writes cmd, then sets cmd_ready (release);
    /// simulator thread loads cmd_ready (acquire), reads cmd, then clears.
    cmd: Command = .none,
    cmd_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// How many server.info polls return "startup" before switching to
    /// "ready" (default 2).
    startup_polls: u32 = 2,

    /// Returns monotonic time in milliseconds (for eventtime).
    fn nowMs(io: Io) i64 {
        return Io.Clock.awake.now(io).toMilliseconds();
    }

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

    /// Start the simulator on a background thread.  Returns immediately.
    pub fn start(self: *Self) !void {
        self.stop_flag.store(false, .release);
        self.running.store(true, .release);

        self.threaded = try self.alloc.create(std.Io.Threaded);
        errdefer {
            self.alloc.destroy(self.threaded.?);
            self.threaded = null;
        }
        self.threaded.?.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        self.io = self.threaded.?.io();

        // Remove any stale socket file.
        const io = self.io.?;
        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};

        const addr = try net.UnixAddress.init(self.socket_path);
        self.listener = try addr.listen(io, .{});

        self.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, runThread, .{self}) catch |e| {
            self.listener.?.deinit(io);
            self.listener = null;
            std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
            self.threaded.?.deinit();
            self.alloc.destroy(self.threaded.?);
            self.threaded = null;
            self.io = null;
            return e;
        };
    }

    /// Block until the handshake completes (or the simulator stops).
    pub fn waitReady(self: *Self) void {
        while (!self.ready.load(.acquire) and self.running.load(.acquire)) {
            std.Thread.yield() catch {};
        }
    }

    /// Signal the simulator to stop and join its thread.  Idempotent.
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.stop_flag.store(true, .release);
        // Close the listener socket to unblock a pending accept.
        if (self.listener) |*l| {
            l.socket.close(self.io.?);
        }
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
        // Now safe to null the listener (socket already closed).
        self.listener = null;
        // Clean up the socket file.
        if (self.io) |sio| {
            std.Io.Dir.deleteFileAbsolute(sio, self.socket_path) catch {};
        }
        if (self.threaded) |thr| {
            thr.deinit();
            self.alloc.destroy(thr);
            self.threaded = null;
            self.io = null;
        }
    }

    /// Push a status update with the given print_stats state and filename.
    pub fn pushStatus(self: *Self, state: PrintState, filename: []const u8) void {
        self.cmd = .{ .status = .{ .state = state, .filename = filename } };
        self.cmd_ready.store(true, .release);
    }

    /// Push a gcode_response notification.
    pub fn pushGcodeResponse(self: *Self, response: []const u8) void {
        self.cmd = .{ .gcode_response = response };
        self.cmd_ready.store(true, .release);
    }

    /// Push a shutdown status (webhooks.state: "shutdown") and disconnect.
    pub fn pushShutdown(self: *Self) void {
        self.cmd = .shutdown;
        self.cmd_ready.store(true, .release);
    }

    /// Disconnect without sending shutdown.
    pub fn pushDisconnect(self: *Self) void {
        self.cmd = .disconnect;
        self.cmd_ready.store(true, .release);
    }

    pub fn isRunning(self: *Self) bool {
        return self.running.load(.acquire);
    }

    // -----------------------------------------------------------------------
    // Internal: background thread
    // -----------------------------------------------------------------------

    fn runThread(self: *Self) void {
        defer self.running.store(false, .release);

        const io = self.io.?;

        // Check stop flag before blocking on accept.
        if (self.stop_flag.load(.acquire)) return;

        // Use Io-based accept so the non-blocking listener socket works
        // correctly with the Threaded backend.
        const stream = self.listener.?.accept(io) catch return;
        defer stream.close(io);
        self.reader = stream.reader(io, &self.read_buffer);

        // ----- Handshake -----
        if (!self.doHandshake(io, stream)) return;

        self.ready.store(true, .release);

        // ----- Ready: read/respond loop -----
        self.readLoop(io, stream);
    }

    // -----------------------------------------------------------------------
    // Handshake
    // -----------------------------------------------------------------------

    fn doHandshake(self: *Self, io: Io, stream: net.Stream) bool {
        var poll_count: u32 = 0;
        var ready_sent: bool = false;
        var sub_done: bool = false;
        var gcode_done: bool = false;

        while (!self.stop_flag.load(.acquire)) {
            const payload = self.readFrame() catch {
                return false;
            };
            defer self.alloc.free(payload);

            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch {
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

    fn readLoop(self: *Self, io: Io, stream: net.Stream) void {
        var resp_id: u32 = 1000;

        while (!self.stop_flag.load(.acquire)) {
            // Process any pending command from the test thread.
            self.processCommand(io, stream, &resp_id);

            // Read and handle one frame.
            const payload = self.readFrame() catch {
                return;
            };
            defer self.alloc.free(payload);

            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch continue;
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
                    // Real Klippy keeps running for a moment after sending the
                    // gcode response before the restart tears down the socket.
                    // Settle briefly so the client reliably drains the buffered
                    // `result:"ok"` frame above before it observes EOF from the
                    // `defer stream.close()` in runThread — otherwise the close
                    // races the response and the pending request fails flakily.
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
                var buf: [128]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":null}}",
                    .{id_str},
                ) catch continue;
                self.writeFrame(io, stream, resp) catch return;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Command dispatch (called from readLoop)
    // -----------------------------------------------------------------------

    fn processCommand(self: *Self, io: Io, stream: net.Stream, resp_id: *u32) void {
        if (!self.cmd_ready.load(.acquire)) return;
        const cmd = self.cmd;
        self.cmd = .none;
        self.cmd_ready.store(false, .release);

        switch (cmd) {
            .none => {},
            .shutdown => {
                resp_id.* += 1;
                const eventtime: f64 = @floatFromInt(nowMs(io));
                var buf: [512]u8 = undefined;
                const payload = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"method\":\"process_status_update\",\"id\":\"{d}\",\"params\":[{d:.3},{{\"webhooks\":{{\"state\":\"shutdown\"}}}}]}}",
                    .{ resp_id.*, eventtime / 1000.0 },
                ) catch return;
                self.writeFrame(io, stream, payload) catch {};
                self.stop_flag.store(true, .release);
            },
            .disconnect => {
                self.stop_flag.store(true, .release);
            },
            .status => |s| {
                resp_id.* += 1;
                const state_str: []const u8 = switch (s.state) {
                    .standby => "standby",
                    .printing => "printing",
                    .paused => "paused",
                    .complete => "complete",
                    .@"error" => "error",
                    .cancelled => "cancelled",
                };
                const eventtime: f64 = @floatFromInt(nowMs(io));
                var buf: [1024]u8 = undefined;
                const payload = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"method\":\"process_status_update\",\"id\":\"{d}\",\"params\":[{d:.3},{{\"webhooks\":{{\"state\":\"ready\"}},\"print_stats\":{{\"state\":\"{s}\",\"filename\":\"{s}\",\"total_duration\":10.0,\"print_duration\":5.0,\"filament_used\":1.0}}}}]}}",
                    .{ resp_id.*, eventtime / 1000.0, state_str, s.filename },
                ) catch return;
                self.writeFrame(io, stream, payload) catch {};
            },
            .gcode_response => |r| {
                resp_id.* += 1;
                var buf: [512]u8 = undefined;
                const payload = std.fmt.bufPrint(
                    &buf,
                    "{{\"jsonrpc\":\"2.0\",\"method\":\"process_gcode_response\",\"id\":\"{d}\",\"params\":\"{s}\"}}",
                    .{ resp_id.*, r },
                ) catch return;
                self.writeFrame(io, stream, payload) catch {};
            },
        }
    }

    // -----------------------------------------------------------------------
    // Wire helpers
    // -----------------------------------------------------------------------

    fn readFrame(self: *Self) ![]const u8 {
        if (self.stop_flag.load(.acquire)) return error.SimulatorStopped;
        return framing.read(self.alloc, &self.reader.?.interface);
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

test "KlippySim: init/deinit" {
    const sim = try KlippySim.init(testing.allocator, "/tmp/phobos_test_sim_init");
    defer sim.deinit();
}

test "KlippySim: start/stop" {
    const sim = try KlippySim.init(testing.allocator, "/tmp/phobos_test_sim_start");
    defer sim.deinit();
    try sim.start();
    try testing.expect(sim.isRunning());
    sim.stop();
    try testing.expect(!sim.isRunning());
}

test "KlippySim: start/stop with no client — stops cleanly" {
    const sim = try KlippySim.init(testing.allocator, "/tmp/phobos_test_sim_noclient");
    defer sim.deinit();
    try sim.start();
    sim.stop();
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
            const path = try std.fmt.allocPrint(testing.allocator, "/tmp/phobos_sim_fuzz_{s}", .{safe[0..len]});
            defer testing.allocator.free(path);
            const sim = KlippySim.init(testing.allocator, path) catch return;
            defer sim.deinit();
            sim.start() catch return;
            sim.stop();
        }
    }.run, .{});
}

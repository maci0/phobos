//! server.gcode_store + server.temperature_store API components.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/data_store.py` (DataStore):
//!
//!   GET /server/gcode_store       → server.gcode_store
//!   GET /server/temperature_store → server.temperature_store
//!
//! GCode Store:
//!   Bounded ring-buffer of recent gcode responses / commands.
//!   Entries: {message: str, time: float, type: "response"|"command"}
//!   GET param: count (int, optional) — limit to last N entries
//!   Response: {"gcode_store": [...]}
//!   Default capacity: 1000 (matches data_store.py gcode_store_size default)
//!
//! Temperature Store:
//!   Per-sensor ring-buffer of temperature/target/power/speed readings.
//!   Without Klippy there are no sensors → empty object is correct.
//!   GET param: include_monitors (bool, false) — include temperature monitors
//!   Response: {"<sensor_name>": {"temperatures": [...], "targets": [...], ...}}
//!   (field names are pluralised: "temperature" → "temperatures", etc.)
//!   Default capacity: 1200 (matches data_store.py temperature_store_size default)
//!
//! NOTE: Without Klippy there are no live sensors. The temperature store always
//! returns an empty object. The gcode ring buffer accumulates entries pushed via
//! `GcodeStoreCtx.push`; with no Klippy it starts empty (which is correct).

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Gcode Store entry (matches data_store.py GCodeStore deque element)
// ---------------------------------------------------------------------------

pub const GcodeEntryType = enum { response, command };

pub const GcodeEntry = struct {
    message: []const u8,
    time: f64,
    type: GcodeEntryType,
};

// ---------------------------------------------------------------------------
// Bounded ring-buffer for gcode entries
// ---------------------------------------------------------------------------

/// Bounded ring-buffer of GcodeEntry. Entries are heap-allocated (message
/// strings duplicated). Evicts oldest when full, matching Python's deque(maxlen=N).
pub const GcodeRingBuffer = struct {
    alloc: std.mem.Allocator,
    buf: []GcodeEntry,
    head: usize, // next write position
    count: usize, // number of valid entries (0..capacity)
    capacity: usize,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !GcodeRingBuffer {
        const buf = try alloc.alloc(GcodeEntry, capacity);
        return .{
            .alloc = alloc,
            .buf = buf,
            .head = 0,
            .count = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *GcodeRingBuffer) void {
        const n = self.count;
        const start = if (self.count < self.capacity) 0 else self.head;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.alloc.free(self.buf[(start + i) % self.capacity].message);
        }
        self.alloc.free(self.buf);
    }

    /// Push a new entry. Evicts oldest if at capacity. Duplicates message string.
    pub fn push(self: *GcodeRingBuffer, message: []const u8, time: f64, entry_type: GcodeEntryType) !void {
        const msg_dup = try self.alloc.dupe(u8, message);
        if (self.count == self.capacity) {
            // Evict oldest: free its message and overwrite slot
            self.alloc.free(self.buf[self.head].message);
            self.buf[self.head] = .{ .message = msg_dup, .time = time, .type = entry_type };
            self.head = (self.head + 1) % self.capacity;
            // count stays at capacity
        } else {
            const slot = (self.head + self.count) % self.capacity;
            self.buf[slot] = .{ .message = msg_dup, .time = time, .type = entry_type };
            self.count += 1;
        }
    }

    /// Copy all entries in FIFO order into `out_slice` (caller provides it).
    /// Returns the number of entries written.
    pub fn copyAll(self: *const GcodeRingBuffer, out_slice: []GcodeEntry) usize {
        const n = @min(self.count, out_slice.len);
        const start = if (self.count < self.capacity) 0 else self.head;
        for (0..n) |i| {
            out_slice[i] = self.buf[(start + i) % self.capacity];
        }
        return n;
    }

    /// Return the last `count` entries (or all if count >= self.count).
    pub fn copyLast(self: *const GcodeRingBuffer, count: usize, out_slice: []GcodeEntry) usize {
        const actual = @min(count, self.count);
        const skip = self.count - actual;
        const start = if (self.count < self.capacity) 0 else self.head;
        for (0..actual) |i| {
            out_slice[i] = self.buf[(start + skip + i) % self.capacity];
        }
        return actual;
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const DataStoreCtx = struct {
    gcode_ring: GcodeRingBuffer,
    // Temperature store: always empty (no Klippy). Registered for correct shape.

    pub fn init(alloc: std.mem.Allocator) !DataStoreCtx {
        return .{
            .gcode_ring = try GcodeRingBuffer.init(alloc, 1000),
        };
    }

    pub fn deinit(self: *DataStoreCtx) void {
        self.gcode_ring.deinit();
    }

    /// Push a gcode response entry (type="response"). Called when Klippy sends
    /// a gcode response. Currently not wired to a live source (no Klippy),
    /// but the ring buffer is available for future integration.
    pub fn pushGcodeResponse(self: *DataStoreCtx, message: []const u8, time: f64) !void {
        try self.gcode_ring.push(message, time, .response);
    }

    /// Push a gcode command entry (type="command").
    pub fn pushGcodeCommand(self: *DataStoreCtx, message: []const u8, time: f64) !void {
        if (std.mem.trim(u8, message, " \t\r\n").len == 0) return;
        try self.gcode_ring.push(message, time, .command);
    }
};

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

fn getOptInt(params: std.json.Value, field: []const u8) ?i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
                else => null,
            };
        },
        else => return null,
    }
}

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/gcode_store → {"gcode_store": [...]}
pub fn handleGcodeStore(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DataStoreCtx = @ptrCast(@alignCast(ctx));
    const ring = &c.gcode_ring;

    var tmp_buf = try alloc.alloc(GcodeEntry, ring.count);
    defer alloc.free(tmp_buf);

    const n: usize = if (getOptInt(params, "count")) |cnt|
        ring.copyLast(@intCast(@max(cnt, 0)), tmp_buf)
    else
        ring.copyAll(tmp_buf);

    var arr: std.json.Array = .init(alloc);
    for (tmp_buf[0..n]) |entry| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "message", .{ .string = entry.message });
        try obj.put(alloc, "time", .{ .float = entry.time });
        try obj.put(alloc, "type", .{ .string = switch (entry.type) {
            .response => "response",
            .command => "command",
        } });
        try arr.append(.{ .object = obj });
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "gcode_store", .{ .array = arr });
    return .{ .object = result };
}

/// GET /server/temperature_store → {"<sensor>": {"temperatures": [...], ...}}
/// Without Klippy there are no sensors; always returns an empty object.
pub fn handleTempStore(_: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    _ = getOptBool(params, "include_monitors", false); // parameter accepted, no-op
    return .{ .object = .empty };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerDataStore(reg: *Registry, ctx: *DataStoreCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/gcode_store", .methods = &.{.GET} },
        c,
        handleGcodeStore,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/temperature_store", .methods = &.{.GET} },
        c,
        handleTempStore,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// --- Ring buffer unit tests ---

test "GcodeRingBuffer: empty ring returns no entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 5);
    defer ring.deinit();

    var out: [5]GcodeEntry = undefined;
    try testing.expectEqual(@as(usize, 0), ring.copyAll(&out));
    try testing.expectEqual(@as(usize, 0), ring.copyLast(3, &out));
}

test "GcodeRingBuffer: push and retrieve all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 5);
    defer ring.deinit();

    try ring.push("a", 1.0, .response);
    try ring.push("b", 2.0, .command);
    try ring.push("c", 3.0, .response);

    var out: [5]GcodeEntry = undefined;
    const n = ring.copyAll(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("a", out[0].message);
    try testing.expectEqualStrings("b", out[1].message);
    try testing.expectEqualStrings("c", out[2].message);
    try testing.expectEqual(GcodeEntryType.response, out[0].type);
    try testing.expectEqual(GcodeEntryType.command, out[1].type);
}

test "GcodeRingBuffer: bounded eviction evicts oldest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 3);
    defer ring.deinit();

    try ring.push("a", 1.0, .response);
    try ring.push("b", 2.0, .response);
    try ring.push("c", 3.0, .response);
    // Ring is full; next push evicts "a"
    try ring.push("d", 4.0, .response);

    var out: [4]GcodeEntry = undefined;
    const n = ring.copyAll(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("b", out[0].message);
    try testing.expectEqualStrings("c", out[1].message);
    try testing.expectEqualStrings("d", out[2].message);
}

test "GcodeRingBuffer: evicts multiple times correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 3);
    defer ring.deinit();

    try ring.push("a", 1.0, .response);
    try ring.push("b", 2.0, .response);
    try ring.push("c", 3.0, .response);
    try ring.push("d", 4.0, .response);
    try ring.push("e", 5.0, .response);
    try ring.push("f", 6.0, .response);

    var out: [3]GcodeEntry = undefined;
    const n = ring.copyAll(&out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("d", out[0].message);
    try testing.expectEqualStrings("e", out[1].message);
    try testing.expectEqualStrings("f", out[2].message);
}

test "GcodeRingBuffer: copyLast(N) returns last N entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 10);
    defer ring.deinit();

    try ring.push("a", 1.0, .response);
    try ring.push("b", 2.0, .response);
    try ring.push("c", 3.0, .response);
    try ring.push("d", 4.0, .response);
    try ring.push("e", 5.0, .response);

    var out: [10]GcodeEntry = undefined;
    const n = ring.copyLast(2, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("d", out[0].message);
    try testing.expectEqualStrings("e", out[1].message);
}

test "GcodeRingBuffer: copyLast count > actual returns all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ring = try GcodeRingBuffer.init(arena.allocator(), 10);
    defer ring.deinit();

    try ring.push("x", 1.0, .response);

    var out: [10]GcodeEntry = undefined;
    const n = ring.copyLast(100, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("x", out[0].message);
}

// --- Handler tests ---

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleGcodeStore: empty store returns empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    const result = try handleGcodeStore(@ptrCast(&ctx), .null, a);
    const arr = result.object.get("gcode_store").?.array;
    try testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "handleGcodeStore: entries appear with correct shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    try ctx.pushGcodeResponse("OK", 100.0);
    try ctx.pushGcodeCommand("G28", 101.0);

    const result = try handleGcodeStore(@ptrCast(&ctx), .null, a);
    const arr = result.object.get("gcode_store").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("OK", arr.items[0].object.get("message").?.string);
    try testing.expectEqualStrings("response", arr.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("G28", arr.items[1].object.get("message").?.string);
    try testing.expectEqualStrings("command", arr.items[1].object.get("type").?.string);
}

test "handleGcodeStore: count param limits entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    try ctx.pushGcodeResponse("msg1", 1.0);
    try ctx.pushGcodeResponse("msg2", 2.0);
    try ctx.pushGcodeResponse("msg3", 3.0);

    const params = try mkParams(a, "{\"count\":2}");
    const result = try handleGcodeStore(@ptrCast(&ctx), params, a);
    const arr = result.object.get("gcode_store").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("msg2", arr.items[0].object.get("message").?.string);
    try testing.expectEqualStrings("msg3", arr.items[1].object.get("message").?.string);
}

test "handleTempStore: returns empty object (no Klippy)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    const result = try handleTempStore(@ptrCast(&ctx), .null, a);
    try testing.expect(result == .object);
    try testing.expectEqual(@as(usize, 0), result.object.count());
}

test "handleTempStore: include_monitors param accepted without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"include_monitors\":true}");
    const result = try handleTempStore(@ptrCast(&ctx), params, a);
    try testing.expect(result == .object);
}

test "pushGcodeCommand: empty/whitespace-only message is not stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();

    try ctx.pushGcodeCommand("   ", 1.0);
    try ctx.pushGcodeCommand("\n\t", 2.0);

    const result = try handleGcodeStore(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), result.object.get("gcode_store").?.array.items.len);
}

test "registerDataStore: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = try DataStoreCtx.init(alloc);
    defer ctx.deinit();

    try registerDataStore(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/gcode_store") != null);
    try testing.expect(reg.lookup(.GET, "/server/temperature_store") != null);
    try testing.expect(d.methods.get("server.gcode_store") != null);
    try testing.expect(d.methods.get("server.temperature_store") != null);
}

// --- Fuzz tests ---

test "fuzz GcodeRingBuffer: arbitrary push/copyAll/copyLast never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const cap = 1 + (@as(usize, buf[0]) % 8);
            var ring = GcodeRingBuffer.init(a, cap) catch return;
            defer ring.deinit();

            const n_ops = @as(usize, buf[1]) % 20;
            for (0..n_ops) |i| {
                const msg_choices = [_][]const u8{ "ok", "G28", "M104 S200", "", "echo:busy" };
                const msg = msg_choices[buf[i % buf.len] % msg_choices.len];
                const t: f64 = @floatFromInt(i);
                const et: GcodeEntryType = if (buf[i % buf.len] & 1 == 0) .response else .command;
                ring.push(msg, t, et) catch {};
            }

            var out: [16]GcodeEntry = undefined;
            _ = ring.copyAll(&out);
            _ = ring.copyLast(3, &out);
        }
    }.run, .{});
}

test "fuzz handleGcodeStore: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var ctx = DataStoreCtx.init(a) catch return;
            defer ctx.deinit();

            ctx.pushGcodeResponse("ok", 1.0) catch {};
            ctx.pushGcodeCommand("G28", 2.0) catch {};

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"count\":0}",
                "{\"count\":1}",
                "{\"count\":9999}",
                "{\"count\":-1}",
                "1",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleGcodeStore(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleTempStore: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var ctx = DataStoreCtx.init(a) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"include_monitors\":true}",
                "{\"include_monitors\":false}",
                "{\"include_monitors\":\"yes\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleTempStore(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

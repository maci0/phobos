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
//!   Per-sensor ring-buffer of temperature/target/power/speed readings, fed a
//!   once-per-second sample of cached Klippy readings. Status updates replace
//!   readings without adding samples. Empty until Klippy sends temperatures.
//!   GET param: include_monitors (bool, false) — include temperature monitors
//!   Response: {"<sensor_name>": {"temperatures": [...], "targets": [...], ...}}
//!   (field names are pluralised: "temperature" → "temperatures", etc.)
//!   Default capacity: 1200 (matches data_store.py temperature_store_size default)

const std = @import("std");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const sleep = @import("../util/sleep.zig");
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
    entries: std.Deque(GcodeEntry),

    pub fn init(alloc: std.mem.Allocator, capacity: usize) !GcodeRingBuffer {
        if (capacity == 0) return error.InvalidCapacity;
        return .{ .alloc = alloc, .entries = try .initCapacity(alloc, capacity) };
    }

    pub fn deinit(self: *GcodeRingBuffer) void {
        while (self.entries.popFront()) |entry| self.alloc.free(entry.message);
        self.entries.deinit(self.alloc);
    }

    /// Duplicates the message before evicting, so allocation failure preserves the store.
    pub fn push(self: *GcodeRingBuffer, message: []const u8, time: f64, entry_type: GcodeEntryType) !void {
        const owned = try self.alloc.dupe(u8, message);
        if (self.entries.len == self.entries.buffer.len) self.alloc.free(self.entries.popFront().?.message);
        self.entries.pushBackAssumeCapacity(.{ .message = owned, .time = time, .type = entry_type });
    }

    /// Copy borrowed entries in FIFO order, bounded by the caller's output slice.
    pub fn copyAll(self: *const GcodeRingBuffer, out_slice: []GcodeEntry) usize {
        const n = @min(self.entries.len, out_slice.len);
        for (out_slice[0..n], 0..) |*entry, i| entry.* = self.entries.at(i);
        return n;
    }

    /// Copy the newest entries that fit, preserving their chronological order.
    pub fn copyLast(self: *const GcodeRingBuffer, count: usize, out_slice: []GcodeEntry) usize {
        const n = @min(count, self.entries.len, out_slice.len);
        const skip = self.entries.len - n;
        for (out_slice[0..n], 0..) |*entry, i| entry.* = self.entries.at(skip + i);
        return n;
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Capacity of each per-field temperature store (about 20 minutes at 1 Hz).
pub const temp_store_size = 1200;

/// A bounded deque of samples, allocated lazily at its exact configured capacity.
pub const FieldRing = struct {
    values: std.Deque(f64) = .empty,

    pub fn ensure(self: *FieldRing, alloc: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        if (self.values.buffer.len == capacity) return;
        const next = try std.Deque(f64).initCapacity(alloc, capacity);
        self.values.deinit(alloc);
        self.values = next;
    }

    pub fn deinit(self: *FieldRing, alloc: std.mem.Allocator) void {
        self.values.deinit(alloc);
        self.* = .{};
    }

    pub fn push(self: *FieldRing, value: f64) void {
        if (self.values.buffer.len == 0) return;
        if (self.values.len == self.values.buffer.len) _ = self.values.popFront();
        self.values.pushBackAssumeCapacity(value);
    }

    /// Copy samples chronologically, bounded by the caller's output slice.
    pub fn snapshot(self: *const FieldRing, out: []f64) usize {
        const n = @min(out.len, self.values.len);
        for (out[0..n], 0..) |*value, i| value.* = self.values.at(i);
        return n;
    }
};

/// One tracked sensor/heater. Heaters report target+power, fans report
/// target+speed, plain sensors report only temperature.
pub const SensorStore = struct {
    temperatures: FieldRing = .{},
    targets: FieldRing = .{},
    powers: FieldRing = .{},
    speeds: FieldRing = .{},
    has_target: bool = false,
    has_power: bool = false,
    has_speed: bool = false,
    temperature: f64 = 0,
    target: f64 = 0,
    power: f64 = 0,
    speed: f64 = 0,
};

pub const DataStoreCtx = struct {
    gcode_ring: GcodeRingBuffer,
    /// Per-sensor temperature history, fed from the Klippy status stream and
    /// returned by server.temperature_store. Keys are owned (duped on insert).
    sensors: std.StringHashMapUnmanaged(SensorStore) = .empty,
    /// `heaters.available_monitors`. Hidden unless `include_monitors` is set.
    /// Keys are owned.
    monitors: std.StringHashMapUnmanaged(void) = .empty,
    temp_mutex: std.Io.Mutex = .init,
    /// Live io handle (set via setIo); the temperature-store handler needs it to
    /// lock `temp_mutex`, since JSON-RPC handlers are not passed an io.
    io: ?std.Io = null,
    gpa: std.mem.Allocator,
    /// `[data_store] temperature_store_size`. Default 1200.
    temp_capacity: usize = temp_store_size,
    sampler_stop: std.Io.Event = .unset,
    sampler_thread: ?std.Thread = null,

    pub fn setIo(self: *DataStoreCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn init(alloc: std.mem.Allocator) !DataStoreCtx {
        return .{
            .gcode_ring = try GcodeRingBuffer.init(alloc, 1000),
            .gpa = alloc,
        };
    }

    /// `[data_store] gcode_store_size`. Keeps the newest entries that fit.
    pub fn setGcodeStoreSize(self: *DataStoreCtx, capacity: usize) !void {
        if (capacity == 0 or capacity == self.gcode_ring.entries.buffer.len) return;
        var next = try GcodeRingBuffer.init(self.gpa, capacity);
        errdefer next.deinit();
        const tmp = try self.gpa.alloc(GcodeEntry, self.gcode_ring.entries.len);
        defer self.gpa.free(tmp);
        const n = self.gcode_ring.copyLast(capacity, tmp);
        for (tmp[0..n]) |entry| try next.push(entry.message, entry.time, entry.type);
        self.gcode_ring.deinit();
        self.gcode_ring = next;
    }

    /// `[data_store] temperature_store_size`. Drops samples already stored.
    pub fn setTemperatureStoreSize(self: *DataStoreCtx, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        if (capacity == self.temp_capacity) return;
        var it = self.sensors.valueIterator();
        while (it.next()) |sensor| {
            sensor.temperatures.deinit(self.gpa);
            sensor.targets.deinit(self.gpa);
            sensor.powers.deinit(self.gpa);
            sensor.speeds.deinit(self.gpa);
        }
        self.temp_capacity = capacity;
    }

    fn ensureSensor(self: *DataStoreCtx, sensor: *SensorStore, target: ?f64, power: ?f64, speed: ?f64) !void {
        try sensor.temperatures.ensure(self.gpa, self.temp_capacity);
        if (sensor.has_target or target != null) try sensor.targets.ensure(self.gpa, self.temp_capacity);
        if (sensor.has_power or power != null) try sensor.powers.ensure(self.gpa, self.temp_capacity);
        if (sensor.has_speed or speed != null) try sensor.speeds.ensure(self.gpa, self.temp_capacity);
    }

    pub fn deinit(self: *DataStoreCtx) void {
        self.stopSampler();
        self.gcode_ring.deinit();
        var it = self.sensors.iterator();
        while (it.next()) |e| {
            e.value_ptr.temperatures.deinit(self.gpa);
            e.value_ptr.targets.deinit(self.gpa);
            e.value_ptr.powers.deinit(self.gpa);
            e.value_ptr.speeds.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.sensors.deinit(self.gpa);
        var mit = self.monitors.keyIterator();
        while (mit.next()) |k| self.gpa.free(k.*);
        self.monitors.deinit(self.gpa);
    }

    /// Record a heater monitor name. `server.temperature_store` omits it
    /// unless the request sets `include_monitors`.
    pub fn markTempMonitor(self: *DataStoreCtx, io: std.Io, name: []const u8) void {
        self.temp_mutex.lockUncancelable(io);
        defer self.temp_mutex.unlock(io);
        if (self.monitors.contains(name)) return;
        const key = self.gpa.dupe(u8, name) catch return;
        self.monitors.put(self.gpa, key, {}) catch {
            self.gpa.free(key);
        };
    }

    /// Cache partial status updates, seeding each field with its first sample.
    pub fn pushTemp(self: *DataStoreCtx, io: std.Io, name: []const u8, temperature: ?f64, target: ?f64, power: ?f64, speed: ?f64) void {
        self.temp_mutex.lockUncancelable(io);
        defer self.temp_mutex.unlock(io);
        if (temperature == null and !self.sensors.contains(name)) return;
        const gop = self.sensors.getOrPut(self.gpa, name) catch return;
        if (!gop.found_existing) {
            const key = self.gpa.dupe(u8, name) catch {
                _ = self.sensors.remove(name);
                return;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{};
        }
        const s = gop.value_ptr;
        self.ensureSensor(s, target, power, speed) catch return;
        if (temperature) |t| s.temperature = @round(t * 100) / 100;
        if (s.temperatures.values.len == 0) s.temperatures.push(s.temperature);
        if (target) |t| {
            s.target = @round(t * 100) / 100;
            if (!s.has_target) s.targets.push(s.target);
            s.has_target = true;
        }
        if (power) |p| {
            s.power = @round(p * 100) / 100;
            if (!s.has_power) s.powers.push(s.power);
            s.has_power = true;
        }
        if (speed) |sp| {
            s.speed = @round(sp * 100) / 100;
            if (!s.has_speed) s.speeds.push(s.speed);
            s.has_speed = true;
        }
    }

    pub fn sampleTemperatures(self: *DataStoreCtx, io: std.Io) void {
        self.temp_mutex.lockUncancelable(io);
        defer self.temp_mutex.unlock(io);
        var it = self.sensors.valueIterator();
        while (it.next()) |s| {
            s.temperatures.push(s.temperature);
            if (s.has_target) s.targets.push(s.target);
            if (s.has_power) s.powers.push(s.power);
            if (s.has_speed) s.speeds.push(s.speed);
        }
    }

    /// Only the daemon starts this worker; tests sample synchronously.
    pub fn startSampler(self: *DataStoreCtx) !void {
        if (self.sampler_thread != null) return;
        if (self.io == null) return error.IoNotSet;
        self.sampler_stop.reset();
        self.sampler_thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, samplerThread, .{self});
    }

    pub fn stopSampler(self: *DataStoreCtx) void {
        if (self.io) |stop_io| self.sampler_stop.set(stop_io) else self.sampler_stop = .is_set;
        if (self.sampler_thread) |thread| {
            thread.join();
            self.sampler_thread = null;
        }
    }

    fn samplerThread(self: *DataStoreCtx) void {
        const io = self.io.?;
        while (!self.sampler_stop.isSet()) {
            if (sleep.untilStopped(io, .fromSeconds(1), &self.sampler_stop)) break;
            self.sampleTemperatures(io);
        }
    }

    /// Record a Klippy gcode response (type="response") before notification.
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

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/gcode_store → {"gcode_store": [...]}
pub fn handleGcodeStore(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DataStoreCtx = @ptrCast(@alignCast(ctx));
    const ring = &c.gcode_ring;

    const n = ring.entries.len;
    // data_store.py returns `list(queue)[-count:]`: 0 keeps every entry and a
    // negative count drops the oldest |count|. lossyCast clamps i64 counts a
    // 32-bit usize cannot hold.
    const first: usize = if ((try webreq.optional(i64, params, "count"))) |cnt|
        if (cnt > 0) n - @min(std.math.lossyCast(usize, cnt), n) else @min(std.math.lossyCast(usize, @abs(cnt)), n)
    else
        0;

    var arr = try std.json.Array.initCapacity(alloc, n - first);
    for (first..n) |index| {
        const entry = ring.entries.at(index);
        var obj: std.json.ObjectMap = .empty;
        // The fixed schema needs no growth slack.
        try obj.entries.setCapacity(alloc, @typeInfo(GcodeEntry).@"struct".field_names.len);
        try obj.reIndex(alloc);
        obj.putAssumeCapacity("message", .{ .string = entry.message });
        obj.putAssumeCapacity("time", .{ .float = entry.time });
        obj.putAssumeCapacity("type", .{ .string = @tagName(entry.type) });
        arr.appendAssumeCapacity(.{ .object = obj });
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "gcode_store", .{ .array = arr });
    return .{ .object = result };
}

/// GET /server/temperature_store → {"<sensor>": {"temperatures": [...], ...}}
/// Snapshots the per-sensor ring buffers fed from the Klippy status stream.
/// Heaters include targets+powers; fans include targets+speeds; plain sensors
/// only temperatures — matching Moonraker's data_store.
pub fn handleTempStore(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DataStoreCtx = @ptrCast(@alignCast(ctx));
    const include_monitors = ((try webreq.optional(bool, params, "include_monitors")) orelse false);

    const io = c.io orelse return .{ .object = .empty };
    var result: std.json.ObjectMap = .empty;

    c.temp_mutex.lockUncancelable(io);
    defer c.temp_mutex.unlock(io);
    var it = c.sensors.iterator();
    while (it.next()) |entry| {
        if (!include_monitors and c.monitors.contains(entry.key_ptr.*)) continue;
        const s = entry.value_ptr;
        var obj: std.json.ObjectMap = .empty;
        try putRing(alloc, &obj, "temperatures", &s.temperatures);
        if (s.has_target) try putRing(alloc, &obj, "targets", &s.targets);
        if (s.has_power) try putRing(alloc, &obj, "powers", &s.powers);
        if (s.has_speed) try putRing(alloc, &obj, "speeds", &s.speeds);
        try result.put(alloc, try alloc.dupe(u8, entry.key_ptr.*), .{ .object = obj });
    }
    return .{ .object = result };
}

fn putRing(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, ring: *const FieldRing) !void {
    var arr = try std.json.Array.initCapacity(alloc, ring.values.len);
    for (0..ring.values.len) |i| arr.appendAssumeCapacity(.{ .float = ring.values.at(i) });
    try obj.put(alloc, key, .{ .array = arr });
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

test "GcodeRingBuffer rejects zero capacity and bounds a short output slice" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidCapacity, GcodeRingBuffer.init(alloc, 0));
    var ring = try GcodeRingBuffer.init(alloc, 3);
    defer ring.deinit();
    try ring.push("first", 1, .command);
    try ring.push("second", 2, .response);
    var out: [1]GcodeEntry = undefined;
    try testing.expectEqual(@as(usize, 1), ring.copyLast(2, &out));
    try testing.expectEqualStrings("second", out[0].message);
}

test "bounded stores preserve ownership across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var ring = try GcodeRingBuffer.init(alloc, 3);
            defer ring.deinit();
            for (0..9) |i| try ring.push("entry", @floatFromInt(i), .response);
            var entries: [3]GcodeEntry = undefined;
            try testing.expectEqual(@as(usize, 3), ring.copyAll(&entries));
            try testing.expectEqual(@as(f64, 6), entries[0].time);
            try testing.expectEqual(@as(f64, 8), entries[2].time);
            var field: FieldRing = .{};
            defer field.deinit(alloc);
            try field.ensure(alloc, 3);
            for ([_]f64{ 1, 2, 3, 4, 5 }) |value| field.push(value);
            var samples: [3]f64 = undefined;
            try testing.expectEqual(@as(usize, 3), field.snapshot(&samples));
            try testing.expectEqualSlices(f64, &.{ 3, 4, 5 }, &samples);
            try field.ensure(alloc, 1200);
            try testing.expectEqual(@as(usize, 1200), field.values.buffer.len);
            try testing.expectEqual(@as(usize, 0), field.snapshot(&samples));
        }
    }.run, .{});
}

test "fuzz bounded sample deque returns the newest window in order" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const capacity = smith.valueRangeAtMostWithHash(u8, 1, 32, 1);
            var field: FieldRing = .{};
            defer field.deinit(testing.allocator);
            try field.ensure(testing.allocator, capacity);
            for (bytes) |byte| field.push(@floatFromInt(byte));
            var samples: [32]f64 = undefined;
            const count = field.snapshot(&samples);
            try testing.expectEqual(capacity, count);
            for (bytes[bytes.len - count ..], samples[0..count]) |byte, sample|
                try testing.expectEqual(@as(f64, @floatFromInt(byte)), sample);
            try testing.expectEqual(@as(usize, 1), field.snapshot(samples[0..1]));
        }
    }.run, .{});
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

test "setGcodeStoreSize: keeps only the newest entries that fit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();
    try ctx.setGcodeStoreSize(2);
    try ctx.pushGcodeCommand("one", 1);
    try ctx.pushGcodeCommand("two", 2);
    try ctx.pushGcodeCommand("three", 3);
    const result = try handleGcodeStore(@ptrCast(&ctx), .null, a);
    const arr = result.object.get("gcode_store").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    try testing.expectEqualStrings("two", arr.items[0].object.get("message").?.string);
    try testing.expectEqualStrings("three", arr.items[1].object.get("message").?.string);
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

test "handleGcodeStore: count follows Python list[-count:] slicing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();
    try ctx.pushGcodeResponse("msg1", 1.0);
    try ctx.pushGcodeResponse("msg2", 2.0);
    try ctx.pushGcodeResponse("msg3", 3.0);

    const cases = [_]struct { params: []const u8, len: usize, first: []const u8 }{
        .{ .params = "{\"count\":0}", .len = 3, .first = "msg1" },
        .{ .params = "{\"count\":-1}", .len = 2, .first = "msg2" },
        .{ .params = "{\"count\":-9223372036854775808}", .len = 0, .first = "" },
        .{ .params = "{\"count\":9223372036854775807}", .len = 3, .first = "msg1" },
    };
    for (cases) |case| {
        const result = try handleGcodeStore(@ptrCast(&ctx), try mkParams(a, case.params), a);
        const arr = result.object.get("gcode_store").?.array;
        try testing.expectEqual(case.len, arr.items.len);
        if (case.len > 0) try testing.expectEqualStrings(case.first, arr.items[0].object.get("message").?.string);
    }
}

test "gcode snapshots allocate for the requested count and preserve wrapped order" {
    const a = testing.allocator;
    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();
    for (0..1024) |index| try ctx.pushGcodeResponse("kept", @floatFromInt(index));
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(a);
    try params.put(a, "count", .{ .integer = 1 });
    var tracked = testing.FailingAllocator.init(a, .{});
    var arena = std.heap.ArenaAllocator.init(tracked.allocator());
    defer arena.deinit();
    const result = try handleGcodeStore(&ctx, .{ .object = params }, arena.allocator());
    const entries = result.object.get("gcode_store").?.array.items;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(f64, 1023), entries[0].object.get("time").?.float);
    try testing.expectEqualStrings("kept", entries[0].object.get("message").?.string);
    try testing.expect(tracked.allocated_bytes < 8192);
    const full = try handleGcodeStore(&ctx, .null, arena.allocator());
    const all = full.object.get("gcode_store").?.array.items;
    try testing.expectEqual(@as(usize, 1000), all.len);
    for (all, 24..) |entry, index| {
        try testing.expectEqual(@as(f64, @floatFromInt(index)), entry.object.get("time").?.float);
        try testing.expectEqualStrings("response", entry.object.get("type").?.string);
    }
    try testing.expect(tracked.allocated_bytes < 512 * 1024);
}

test "gcode snapshots release partial output after every allocation failure" {
    var ctx = try DataStoreCtx.init(testing.allocator);
    defer ctx.deinit();
    for (0..3) |index| try ctx.pushGcodeCommand("kept", @floatFromInt(index));
    var no_resize = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn run(alloc: std.mem.Allocator, store: *DataStoreCtx) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const result = try handleGcodeStore(store, .null, arena.allocator());
            const entries = result.object.get("gcode_store").?.array.items;
            try testing.expectEqual(@as(usize, 3), entries.len);
            for (entries, 0..) |entry, index| try testing.expectEqual(@as(f64, @floatFromInt(index)), entry.object.get("time").?.float);
        }
    }.run, .{&ctx});
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

test "setTemperatureStoreSize: keeps only the newest samples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();
    ctx.setIo(io);
    try ctx.setTemperatureStoreSize(2);
    ctx.pushTemp(io, "heater_bed", 10.0, null, null, null);
    ctx.pushTemp(io, "heater_bed", 11.0, null, null, null);
    ctx.sampleTemperatures(io);
    ctx.pushTemp(io, "heater_bed", 12.0, null, null, null);
    ctx.sampleTemperatures(io);
    const result = try handleTempStore(@ptrCast(&ctx), .null, a);
    const temps = result.object.get("heater_bed").?.object.get("temperatures").?.array;
    try testing.expectEqual(@as(usize, 2), temps.items.len);
    try testing.expectEqual(@as(f64, 11.0), temps.items[0].float);
    try testing.expectEqual(@as(f64, 12.0), temps.items[1].float);
}

test "temperature updates cache readings without appending another sample" {
    var req_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer req_arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try DataStoreCtx.init(testing.allocator);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.pushTemp(io, "extruder", 30, 0, 0, null);
    ctx.pushTemp(io, "extruder", 31.234, null, null, null);
    const result = try handleTempStore(&ctx, .null, req_arena.allocator());
    const heater = result.object.get("extruder").?.object;
    try testing.expectEqual(@as(usize, 1), heater.get("temperatures").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), heater.get("targets").?.array.items.len);
    ctx.pushTemp(io, "extruder", null, 20, 0.1234, null);
    ctx.sampleTemperatures(io);
    ctx.sampleTemperatures(io);
    const sampled = (try handleTempStore(&ctx, .null, req_arena.allocator())).object.get("extruder").?.object;
    try testing.expectEqual(@as(usize, 3), sampled.get("temperatures").?.array.items.len);
    try testing.expectEqual(@as(f64, 31.23), sampled.get("temperatures").?.array.items[2].float);
    try testing.expectEqual(@as(f64, 20), sampled.get("targets").?.array.items[2].float);
    try testing.expectEqual(@as(f64, 0.12), sampled.get("powers").?.array.items[2].float);
    try testing.expect(ctx.sampler_thread == null);
}

test "plain temperature sensors allocate only their reported field" {
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var ctx = try DataStoreCtx.init(tracked.allocator());
    defer ctx.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ctx.setIo(io);
    const before = tracked.allocated_bytes;
    ctx.pushTemp(io, "plain", 25, null, null, null);
    const allocated = tracked.allocated_bytes - before;
    std.debug.print("plain sensor requested storage: {d} bytes\n", .{allocated});
    try testing.expect(allocated < 2 * temp_store_size * @sizeOf(f64));
    ctx.sampleTemperatures(io);
    ctx.pushTemp(io, "plain", null, 40, null, null);
    ctx.sampleTemperatures(io);
    var req_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer req_arena.deinit();
    const response = try handleTempStore(&ctx, .null, req_arena.allocator());
    const sensor = response.object.get("plain").?.object;
    try testing.expectEqual(@as(usize, 3), sensor.get("temperatures").?.array.items.len);
    try testing.expectEqual(@as(usize, 2), sensor.get("targets").?.array.items.len);
    try testing.expectEqual(@as(f64, 40), sensor.get("targets").?.array.items[1].float);
    try testing.expect(sensor.get("powers") == null and sensor.get("speeds") == null);
}

test "temperature response retains less than two full JSON windows" {
    var ctx = try DataStoreCtx.init(testing.allocator);
    defer ctx.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ctx.setIo(io);
    ctx.pushTemp(io, "plain", 0, null, null, null);
    for (1..temp_store_size + 50) |value| {
        ctx.pushTemp(io, "plain", @floatFromInt(value), null, null, null);
        ctx.sampleTemperatures(io);
    }
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var req_arena = std.heap.ArenaAllocator.init(tracked.allocator());
    defer req_arena.deinit();
    const response = try handleTempStore(&ctx, .null, req_arena.allocator());
    const values = response.object.get("plain").?.object.get("temperatures").?.array.items;
    try testing.expectEqual(temp_store_size, values.len);
    try testing.expectEqual(@as(f64, 50), values[0].float);
    try testing.expectEqual(@as(f64, temp_store_size + 49), values[values.len - 1].float);
    const retained = tracked.allocated_bytes - tracked.freed_bytes;
    std.debug.print("full temperature response request storage: {d} bytes\n", .{retained});
    try testing.expect(retained < 2 * temp_store_size * @sizeOf(std.json.Value));
}

test "temperature store: buffers heater and sensor at sampler cadence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try DataStoreCtx.init(a);
    defer ctx.deinit();
    ctx.setIo(io);

    ctx.pushTemp(io, "heater_bed", 30.0, 60.0, 0.5, null);
    ctx.pushTemp(io, "heater_bed", 31.0, 60.0, 0.6, null);
    ctx.pushTemp(io, "heater_bed", 32.0, 60.0, 0.7, null);
    ctx.sampleTemperatures(io);
    // Plain sensor: temperature only.
    ctx.pushTemp(io, "temperature_sensor chamber", 25.0, null, null, null);

    const r = try handleTempStore(@ptrCast(&ctx), .null, a);
    const obj = r.object;
    const bed = obj.get("heater_bed").?.object;
    try testing.expectEqual(@as(usize, 2), bed.get("temperatures").?.array.items.len);
    try testing.expectEqual(@as(f64, 30.0), bed.get("temperatures").?.array.items[0].float);
    try testing.expectEqual(@as(f64, 32.0), bed.get("temperatures").?.array.items[1].float);
    try testing.expect(bed.get("targets") != null);
    try testing.expect(bed.get("powers") != null);
    try testing.expect(bed.get("speeds") == null); // heater has no speed
    const cham = obj.get("temperature_sensor chamber").?.object;
    try testing.expectEqual(@as(usize, 1), cham.get("temperatures").?.array.items.len);
    try testing.expect(cham.get("targets") == null); // plain sensor: temperature only

    ctx.markTempMonitor(io, "temperature_fan exhaust");
    ctx.pushTemp(io, "temperature_fan exhaust", 40.0, null, null, null);
    const hidden = try handleTempStore(@ptrCast(&ctx), .null, a);
    try testing.expect(hidden.object.get("temperature_fan exhaust") == null);
    const shown_params = try mkParams(a, "{\"include_monitors\":true}");
    const shown = try handleTempStore(@ptrCast(&ctx), shown_params, a);
    try testing.expect(shown.object.get("temperature_fan exhaust") != null);
}

test "fuzz temperature sampling: bounded rings retain cached fields" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var ctx = try DataStoreCtx.init(testing.allocator);
            defer ctx.deinit();
            const capacity = smith.valueRangeAtMostWithHash(u8, 1, 8, 0);
            try ctx.setTemperatureStoreSize(capacity);
            ctx.pushTemp(io, "sensor", 25, 0, 0, null);
            const ticks = smith.valueRangeAtMostWithHash(u8, 0, 20, 1);
            for (0..ticks) |i| {
                ctx.pushTemp(io, "sensor", null, @floatFromInt(i), null, null);
                ctx.sampleTemperatures(io);
            }
            const s = ctx.sensors.get("sensor").?;
            try testing.expectEqual(@min(@as(usize, ticks) + 1, capacity), s.temperatures.values.len);
            try testing.expectEqual(s.temperatures.values.len, s.targets.values.len);
            try testing.expectEqual(s.temperatures.values.len, s.powers.values.len);
            try testing.expectEqual(@as(usize, 0), s.speeds.values.buffer.len);
            try testing.expect(ctx.sampler_thread == null);
            try testing.expectError(error.IoNotSet, ctx.startSampler());
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

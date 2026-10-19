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

/// Capacity of each per-field temperature ring (Moonraker default 1200 ≈ 20 min
/// at 1 Hz).
pub const temp_store_size = 1200;

/// Ring buffer of f64 samples. Empty until `ensure` allocates `capacity`.
pub const FieldRing = struct {
    buf: []f64 = &.{},
    head: usize = 0,
    count: usize = 0,

    pub fn ensure(self: *FieldRing, alloc: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        if (self.buf.len == capacity) return;
        const buf = try alloc.alloc(f64, capacity);
        if (self.buf.len > 0) alloc.free(self.buf);
        self.buf = buf;
        self.head = 0;
        self.count = 0;
    }

    pub fn deinit(self: *FieldRing, alloc: std.mem.Allocator) void {
        if (self.buf.len > 0) alloc.free(self.buf);
        self.* = .{};
    }

    pub fn push(self: *FieldRing, v: f64) void {
        const capacity = self.buf.len;
        if (capacity == 0) return;
        const slot = (self.head + self.count) % capacity;
        self.buf[slot] = v;
        if (self.count == capacity) {
            self.head = (self.head + 1) % capacity;
        } else {
            self.count += 1;
        }
    }

    /// Append samples in chronological order into `out` (len ≥ count). Returns count.
    pub fn snapshot(self: *const FieldRing, out: []f64) usize {
        const capacity = self.buf.len;
        if (capacity == 0) return 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) out[i] = self.buf[(self.head + i) % capacity];
        return self.count;
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
        if (capacity == 0 or capacity == self.gcode_ring.capacity) return;
        var next = try GcodeRingBuffer.init(self.gpa, capacity);
        errdefer next.deinit();
        const tmp = try self.gpa.alloc(GcodeEntry, self.gcode_ring.count);
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

    fn ensureSensor(self: *DataStoreCtx, sensor: *SensorStore) !void {
        try sensor.temperatures.ensure(self.gpa, self.temp_capacity);
        try sensor.targets.ensure(self.gpa, self.temp_capacity);
        try sensor.powers.ensure(self.gpa, self.temp_capacity);
        try sensor.speeds.ensure(self.gpa, self.temp_capacity);
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
        self.ensureSensor(s) catch return;
        if (temperature) |t| s.temperature = @round(t * 100) / 100;
        if (s.temperatures.count == 0) s.temperatures.push(s.temperature);
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
                .float => |f| jv.floatToInt(f),
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
/// Snapshots the per-sensor ring buffers fed from the Klippy status stream.
/// Heaters include targets+powers; fans include targets+speeds; plain sensors
/// only temperatures — matching Moonraker's data_store.
pub fn handleTempStore(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *DataStoreCtx = @ptrCast(@alignCast(ctx));
    const include_monitors = getOptBool(params, "include_monitors", false);

    const io = c.io orelse return .{ .object = .empty };
    const scratch = try alloc.alloc(f64, @max(c.temp_capacity, 1));
    defer alloc.free(scratch);
    var result: std.json.ObjectMap = .empty;

    c.temp_mutex.lockUncancelable(io);
    defer c.temp_mutex.unlock(io);
    var it = c.sensors.iterator();
    while (it.next()) |entry| {
        if (!include_monitors and c.monitors.contains(entry.key_ptr.*)) continue;
        const s = entry.value_ptr;
        var obj: std.json.ObjectMap = .empty;
        try putRing(alloc, &obj, "temperatures", &s.temperatures, scratch);
        if (s.has_target) try putRing(alloc, &obj, "targets", &s.targets, scratch);
        if (s.has_power) try putRing(alloc, &obj, "powers", &s.powers, scratch);
        if (s.has_speed) try putRing(alloc, &obj, "speeds", &s.speeds, scratch);
        try result.put(alloc, try alloc.dupe(u8, entry.key_ptr.*), .{ .object = obj });
    }
    return .{ .object = result };
}

fn putRing(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, ring: *const FieldRing, scratch: []f64) !void {
    const n = ring.snapshot(scratch);
    var arr: std.json.Array = .init(alloc);
    for (scratch[0..n]) |v| try arr.append(.{ .float = v });
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
            try testing.expectEqual(@min(@as(usize, ticks) + 1, capacity), s.temperatures.count);
            try testing.expectEqual(s.temperatures.count, s.targets.count);
            try testing.expectEqual(s.temperatures.count, s.powers.count);
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

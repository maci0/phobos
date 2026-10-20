//! MQTT Klippy status publication. Selectors and queued JSON are owned here.
//! Ingest may run under Core; only the joined worker calls the publisher.
//! Snapshots and merged caches are limited to 64 KiB; pending updates to 32
//! entries and 256 KiB. Enqueue failures return to callers; worker failures log.
const std = @import("std");
const jv = @import("../json/value.zig");
const connections = @import("../server/connections.zig");
const clock = @import("../util/clock.zig");
const mqtt_proto = @import("mqtt_proto.zig");
const Io = std.Io;

const max_status_bytes = 64 * 1024;
const max_pending_bytes = 256 * 1024;
const max_pending_updates = 32;
const shutdown_timeout: Io.Duration = .fromSeconds(1);

/// All arguments are borrowed until this call returns; called outside Core.
pub const PublishFn = *const fn (*anyopaque, []const u8, []const u8, u2, bool) anyerror!void;

pub const Options = struct {
    instance_name: []const u8,
    default_qos: u2 = 0,
    status_interval: f64 = 0,
    publish_split_status: bool = false,
    /// Object names map to null (all fields) or an array of field strings.
    status_objects: std.json.Value,
};

const Config = struct {
    arena: std.heap.ArenaAllocator,
    selectors: std.json.Value,
    topic: []const u8,
    state_prefix: []const u8,
    qos: u2,
    interval: f64,
    split: bool,
};

const Pending = union(enum) {
    update: struct { bytes: []u8, eventtime: f64, started: bool },
    disconnected,
};

pub const StatusCtx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    config: ?Config = null,
    mutex: Io.Mutex = .init,
    pending: std.Deque(Pending) = .empty,
    pending_bytes: usize = 0,
    klippy_connected: bool = false,
    initial_pending: bool = false,
    broker_connected: bool = false,
    stopping: bool = false,
    wake: Io.Event = .unset,
    done: Io.Event = .unset,
    worker: ?Io.Future(void) = null,
    publisher: ?PublishFn = null,
    publisher_ctx: ?*anyopaque = null,
    /// Worker-owned serialized cache, bounded independently from pending updates.
    cache: ?[]u8 = null,
    cache_eventtime: f64 = 0,
    next_tick: ?f64 = null,

    pub fn init(gpa: std.mem.Allocator, io: Io) StatusCtx {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *StatusCtx) void {
        self.stop();
        while (self.pending.popFront()) |item| switch (item) {
            .update => |update| self.gpa.free(update.bytes),
            .disconnected => {},
        };
        self.pending.deinit(self.gpa);
        if (self.cache) |bytes| self.gpa.free(bytes);
        if (self.config) |*cfg| cfg.arena.deinit();
        self.* = undefined;
    }

    /// Before start only. A rejected replacement leaves the previous config intact.
    pub fn setConfig(self: *StatusCtx, options: Options) !void {
        if (self.worker != null or self.pending.len != 0) return error.AlreadyStarted;
        if (!std.math.isFinite(options.status_interval) or
            (options.status_interval != 0 and options.status_interval <= 0.25)) return error.InvalidStatusInterval;
        if (options.default_qos > 2) return error.InvalidQos;
        if (options.instance_name.len != 0) try mqtt_proto.validateTopicName(options.instance_name);
        if (options.status_objects != .object or
            options.status_objects.object.count() > connections.max_subscription_objects) return error.InvalidStatusObjects;
        var iterator = options.status_objects.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.len == 0 or entry.key_ptr.len > connections.max_subscription_name_len) return error.InvalidStatusObjects;
            try mqtt_proto.validateTopicName(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .null => {},
                .array => |fields| {
                    if (fields.items.len > connections.max_subscription_objects) return error.InvalidStatusObjects;
                    for (fields.items) |field| {
                        if (field != .string or field.string.len == 0 or field.string.len > connections.max_subscription_name_len) return error.InvalidStatusObjects;
                        try mqtt_proto.validateTopicName(field.string);
                    }
                },
                else => return error.InvalidStatusObjects,
            }
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const config: Config = .{
            .arena = undefined,
            .selectors = try jv.deepCopy(alloc, options.status_objects),
            .topic = try std.fmt.allocPrint(alloc, "{s}/klipper/status", .{options.instance_name}),
            .state_prefix = try std.fmt.allocPrint(alloc, "{s}/klipper/state", .{options.instance_name}),
            .qos = options.default_qos,
            .interval = options.status_interval,
            .split = options.publish_split_status,
        };
        try mqtt_proto.validateTopicName(config.topic);
        try self.pending.ensureTotalCapacityPrecise(self.gpa, max_pending_updates + 1);
        if (self.config) |*old| old.arena.deinit();
        self.config = config;
        self.config.?.arena = arena;
    }

    /// Caller owns the selector tree. Subscription hooks must merge it with other users.
    pub fn subscription(self: *const StatusCtx, alloc: std.mem.Allocator) !std.json.Value {
        const cfg = self.config orelse return .{ .object = .empty };
        return jv.deepCopy(alloc, cfg.selectors);
    }

    pub fn enabled(self: *const StatusCtx) bool {
        return if (self.config) |cfg| cfg.selectors.object.count() != 0 else false;
    }

    pub fn setBrokerConnected(self: *StatusCtx, connected: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.broker_connected = connected;
    }

    /// The query/subscribe response starts a fresh timer, including an empty snapshot.
    pub fn klippyStarted(self: *StatusCtx, status: std.json.Value, eventtime: f64) !void {
        return self.enqueue(status, eventtime, true);
    }

    /// Copies selected fields before returning; never invokes the publisher.
    pub fn ingest(self: *StatusCtx, status: std.json.Value, eventtime: f64) !void {
        return self.enqueue(status, eventtime, false);
    }

    fn enqueue(self: *StatusCtx, status: std.json.Value, eventtime: f64, started: bool) !void {
        const cfg = self.config orelse return;
        if (!std.math.isFinite(eventtime) or status != .object or jv.exceedsDepth(status, jv.max_value_depth)) return error.InvalidStatus;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Stopped;
        if (!self.enabled() or (!started and !self.klippy_connected)) return;
        // Moonraker ignores updates while MQTT is disconnected, including the initial snapshot.
        if (!self.broker_connected and !started) {
            self.initial_pending = false;
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var objects = status.object.iterator();
        while (objects.next()) |entry| if (entry.value_ptr.* != .object) return error.InvalidStatus;
        const initial = started or self.initial_pending;
        var filtered: std.json.Value = if (self.broker_connected)
            try connections.filterStatus(arena.allocator(), cfg.selectors.object, status, initial)
        else
            .{ .object = .empty };
        if (!initial) {
            var index: usize = 0;
            while (index < filtered.object.count()) {
                if (filtered.object.values()[index].object.count() == 0) {
                    _ = filtered.object.orderedRemove(filtered.object.keys()[index]);
                } else index += 1;
            }
        }
        if (filtered.object.count() == 0 and !started) {
            self.initial_pending = false;
            return;
        }
        var buffer: [max_status_bytes]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        std.json.Stringify.value(filtered, .{}, &writer) catch return error.StatusTooLarge;
        const bytes = writer.buffered();
        if (self.pending.len >= max_pending_updates or bytes.len > max_pending_bytes - self.pending_bytes) return error.StatusQueueFull;
        const owned = try self.gpa.dupe(u8, bytes);
        self.pending.pushBackAssumeCapacity(.{ .update = .{ .bytes = owned, .eventtime = eventtime, .started = started } });
        self.pending_bytes += owned.len;
        if (started) self.klippy_connected = true;
        self.initial_pending = started and status.object.count() == 0;
        self.wake.set(self.io);
    }

    /// Queues an ordered cache flush and stops the timer. No network work under Core.
    pub fn klippyDisconnected(self: *StatusCtx) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.klippy_connected) return;
        if (self.stopping) return error.Stopped;
        // One reserved queue slot keeps disconnect ordered even when update capacity is full.
        if (self.pending.len == self.pending.buffer.len) return error.StatusQueueFull;
        self.pending.pushBackAssumeCapacity(.disconnected);
        self.klippy_connected = false;
        self.initial_pending = false;
        self.wake.set(self.io);
    }

    /// Starts only in the daemon with a thread-safe allocator. Tests call tick instead.
    pub fn start(self: *StatusCtx, publisher: PublishFn, context: *anyopaque) !void {
        if (!self.enabled() or self.worker != null) return;
        if (@import("builtin").is_test) {
            if (self.gpa.vtable == std.testing.allocator.vtable) return error.TestingAllocatorThread;
        }
        self.publisher = publisher;
        self.publisher_ctx = context;
        self.stopping = false;
        self.done.reset();
        self.worker = try self.io.concurrent(run, .{self});
    }

    /// Signals first, then cancels any stalled publish after the shutdown budget and joins.
    pub fn stop(self: *StatusCtx) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.set(self.io);
        self.mutex.unlock(self.io);
        if (self.worker) |*worker| {
            self.done.waitTimeout(self.io, .{ .duration = .{ .raw = shutdown_timeout, .clock = .awake } }) catch {};
            worker.cancel(self.io);
            self.worker = null;
        }
    }

    fn run(self: *StatusCtx) void {
        defer self.done.set(self.io);
        while (true) {
            self.tick(clock.monotonicSeconds(self.io)) catch |err| {
                if (err == error.Canceled) return;
                std.log.err("MQTT status publication failed: {s}", .{@errorName(err)});
            };
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                self.flush() catch |err| {
                    if (err == error.Canceled) return;
                    std.log.err("MQTT status shutdown flush failed: {s}", .{@errorName(err)});
                };
                return;
            }
            if (self.pending.len != 0) {
                self.mutex.unlock(self.io);
                continue;
            }
            self.wake.reset();
            self.mutex.unlock(self.io);
            if (self.next_tick) |deadline| {
                const nanos: i96 = @intFromFloat(@min(std.time.s_per_day, @max(0, deadline - clock.monotonicSeconds(self.io))) * std.time.ns_per_s);
                self.wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromNanoseconds(nanos), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return,
                };
            } else self.wake.wait(self.io) catch return;
        }
    }

    /// Worker-only, or synchronous tests with no worker. now is monotonic seconds.
    pub fn tick(self: *StatusCtx, now: f64) !void {
        const cfg = self.config orelse return;
        var remaining: usize = max_pending_updates + 1;
        while (remaining != 0) : (remaining -= 1) {
            self.mutex.lockUncancelable(self.io);
            const item = self.pending.popFront();
            if (item) |pending| if (pending == .update) {
                self.pending_bytes -= pending.update.bytes.len;
            };
            self.mutex.unlock(self.io);
            const pending = item orelse break;
            switch (pending) {
                .disconnected => {
                    self.next_tick = null;
                    try self.flush();
                },
                .update => |update| {
                    defer self.gpa.free(update.bytes);
                    if (update.started) {
                        if (self.cache) |bytes| self.gpa.free(bytes);
                        self.cache = null;
                        self.next_tick = if (cfg.interval == 0) null else now + cfg.interval;
                    }
                    if (cfg.interval == 0) {
                        if (!std.mem.eql(u8, update.bytes, "{}")) try self.publish(update.bytes, update.eventtime);
                    } else {
                        try self.merge(update.bytes);
                        self.cache_eventtime = update.eventtime;
                    }
                },
            }
        }
        if (self.next_tick) |deadline| if (now >= deadline) {
            self.next_tick = now + cfg.interval;
            try self.flush();
        };
    }

    fn merge(self: *StatusCtx, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        var merged = (try std.json.parseFromSlice(std.json.Value, alloc, self.cache orelse "{}", .{ .allocate = .alloc_always })).value;
        const incoming = (try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{})).value;
        var objects = incoming.object.iterator();
        while (objects.next()) |object| {
            const slot = try merged.object.getOrPut(alloc, object.key_ptr.*);
            if (!slot.found_existing) slot.value_ptr.* = .{ .object = .empty };
            if (object.value_ptr.* != .object) return error.InvalidStatus;
            var fields = object.value_ptr.object.iterator();
            while (fields.next()) |field| try slot.value_ptr.object.put(alloc, field.key_ptr.*, field.value_ptr.*);
        }
        var buffer: [max_status_bytes]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        std.json.Stringify.value(merged, .{}, &writer) catch return error.StatusTooLarge;
        const owned = try self.gpa.dupe(u8, writer.buffered());
        if (self.cache) |old| self.gpa.free(old);
        self.cache = owned;
    }

    fn flush(self: *StatusCtx) !void {
        const bytes = self.cache orelse return;
        self.cache = null;
        defer self.gpa.free(bytes);
        if (!std.mem.eql(u8, bytes, "{}")) try self.publish(bytes, self.cache_eventtime);
    }

    fn publish(self: *StatusCtx, bytes: []const u8, eventtime: f64) !void {
        const cfg = self.config.?;
        const publisher = self.publisher orelse return error.NoPublisher;
        const context = self.publisher_ctx orelse return error.NoPublisher;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const status = (try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{})).value;
        if (cfg.split) {
            var frame_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer frame_arena.deinit();
            var objects = status.object.iterator();
            while (objects.next()) |object| {
                if (object.value_ptr.* != .object) return error.InvalidStatus;
                var fields = object.value_ptr.object.iterator();
                while (fields.next()) |field| {
                    _ = frame_arena.reset(.retain_capacity);
                    const frame_alloc = frame_arena.allocator();
                    const topic = try std.fmt.allocPrint(frame_alloc, "{s}/{s}/{s}", .{ cfg.state_prefix, object.key_ptr.*, field.key_ptr.* });
                    try mqtt_proto.validateTopicName(topic);
                    const payload = try std.json.Stringify.valueAlloc(frame_alloc, .{ .eventtime = eventtime, .value = field.value_ptr.* }, .{});
                    try publisher(context, topic, payload, cfg.qos, true);
                }
            }
        } else {
            const payload = try std.json.Stringify.valueAlloc(alloc, .{ .eventtime = eventtime, .status = status }, .{});
            try publisher(context, cfg.topic, payload, cfg.qos, false);
        }
    }
};

const Capture = struct {
    const Message = struct { topic: []u8, payload: []u8, qos: u2, retain: bool };
    alloc: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,

    fn deinit(self: *Capture) void {
        for (self.messages.items) |message| {
            self.alloc.free(message.topic);
            self.alloc.free(message.payload);
        }
        self.messages.deinit(self.alloc);
    }

    fn publish(context: *anyopaque, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        const owned_topic = try self.alloc.dupe(u8, topic);
        errdefer self.alloc.free(owned_topic);
        const owned_payload = try self.alloc.dupe(u8, payload);
        errdefer self.alloc.free(owned_payload);
        try self.messages.append(self.alloc, .{ .topic = owned_topic, .payload = owned_payload, .qos = qos, .retain = retain });
    }
};

test "mqtt status immediate selectors own snapshots and retain every push" {
    const alloc = std.testing.allocator;
    var selectors = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"extruder":["temperature"],"toolhead":null,"empty":[]}
    , .{});
    defer selectors.deinit();
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .default_qos = 2, .status_objects = selectors.value });
    const subscription = try ctx.subscription(alloc);
    defer jv.free(alloc, subscription);
    try std.testing.expectEqual(@as(usize, 3), subscription.object.count());
    try std.testing.expectEqualStrings("temperature", subscription.object.get("extruder").?.array.items[0].string);
    try std.testing.expect(subscription.object.get("toolhead").? == .null);
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    {
        var initial = try std.json.parseFromSlice(std.json.Value, alloc,
            \\{"extruder":{"temperature":20,"target":0},"toolhead":{"position":[1,2,3]},"empty":{"omitted":1},"other":{"ignored":true}}
        , .{});
        defer initial.deinit();
        try ctx.klippyStarted(initial.value, 10);
        try ctx.ingest(initial.value, 11);
    }
    try std.testing.expectEqual(@as(usize, 0), capture.messages.items.len);
    try ctx.tick(100);
    try std.testing.expectEqual(@as(usize, 2), capture.messages.items.len);
    for (capture.messages.items, 0..) |message, index| {
        try std.testing.expectEqualStrings("forge/klipper/status", message.topic);
        try std.testing.expectEqual(@as(u2, 2), message.qos);
        try std.testing.expect(!message.retain);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, message.payload, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(10 + index)), parsed.value.object.get("eventtime").?.integer);
        const status = parsed.value.object.get("status").?.object;
        try std.testing.expectEqual(@as(usize, if (index == 0) 3 else 2), status.count());
        try std.testing.expectEqual(index == 0, status.contains("empty"));
        try std.testing.expectEqual(@as(usize, 1), status.get("extruder").?.object.count());
        try std.testing.expectEqual(@as(i64, 20), status.get("extruder").?.object.get("temperature").?.integer);
        try std.testing.expect(status.contains("toolhead"));
    }
}

test "mqtt status interval merges latest fields and disconnect flushes in order" {
    const alloc = std.testing.allocator;
    const selectors = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":null}", .{});
    defer selectors.deinit();
    const initial = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":{\"temperature\":20,\"target\":0}}", .{});
    defer initial.deinit();
    const update = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":{\"temperature\":30}}", .{});
    defer update.deinit();
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_interval = 0.5, .status_objects = selectors.value });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(initial.value, 10);
    try ctx.tick(100);
    try ctx.ingest(update.value, 11);
    try ctx.tick(100.49);
    try std.testing.expectEqual(@as(usize, 0), capture.messages.items.len);
    try ctx.tick(100.5);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
    const payload = try std.json.parseFromSlice(std.json.Value, alloc, capture.messages.items[0].payload, .{});
    defer payload.deinit();
    const fields = payload.value.object.get("status").?.object.get("extruder").?.object;
    try std.testing.expectEqual(@as(i64, 30), fields.get("temperature").?.integer);
    try std.testing.expectEqual(@as(i64, 0), fields.get("target").?.integer);
    try std.testing.expectEqual(@as(i64, 11), payload.value.object.get("eventtime").?.integer);
    try ctx.ingest(update.value, 12);
    try ctx.klippyDisconnected();
    try ctx.ingest(initial.value, 13);
    try ctx.tick(100.6);
    try std.testing.expectEqual(@as(usize, 2), capture.messages.items.len);
    try std.testing.expect(ctx.cache == null);
    try std.testing.expect(ctx.next_tick == null);
    try ctx.klippyStarted(initial.value, 14);
    try ctx.tick(101);
    try ctx.tick(101.5);
    try std.testing.expectEqual(@as(usize, 3), capture.messages.items.len);
}

test "mqtt status split topics retain each value using configured qos" {
    const alloc = std.testing.allocator;
    const selectors = try std.json.parseFromSlice(std.json.Value, alloc, "{\"temperature_sensor chamber\":null}", .{});
    defer selectors.deinit();
    const status = try std.json.parseFromSlice(std.json.Value, alloc, "{\"temperature_sensor chamber\":{\"temperature\":42,\"healthy\":true}}", .{});
    defer status.deinit();
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .default_qos = 1, .publish_split_status = true, .status_objects = selectors.value });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(status.value, 3);
    try ctx.tick(0);
    try std.testing.expectEqual(@as(usize, 2), capture.messages.items.len);
    try std.testing.expectEqualStrings("forge/klipper/state/temperature_sensor chamber/temperature", capture.messages.items[0].topic);
    try std.testing.expectEqualStrings("forge/klipper/state/temperature_sensor chamber/healthy", capture.messages.items[1].topic);
    for (capture.messages.items) |message| {
        try std.testing.expect(message.retain);
        try std.testing.expectEqual(@as(u2, 1), message.qos);
        const payload = try std.json.parseFromSlice(std.json.Value, alloc, message.payload, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(usize, 2), payload.value.object.count());
        try std.testing.expectEqual(@as(i64, 3), payload.value.object.get("eventtime").?.integer);
        try std.testing.expect(payload.value.object.contains("value"));
    }
}

test "mqtt status offline initial snapshot is dropped but timer restarts" {
    const alloc = std.testing.allocator;
    const selectors = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":null}", .{});
    defer selectors.deinit();
    const status = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":{\"temperature\":20}}", .{});
    defer status.deinit();
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_interval = 1, .status_objects = selectors.value });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    try ctx.klippyStarted(status.value, 1);
    try ctx.tick(100);
    ctx.setBrokerConnected(true);
    try ctx.tick(101);
    try std.testing.expectEqual(@as(usize, 0), capture.messages.items.len);
    try ctx.ingest(status.value, 2);
    try ctx.tick(101.5);
    try ctx.tick(102);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
}

test "mqtt status bounds queue without coalescing immediate updates" {
    const alloc = std.testing.allocator;
    const selectors = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":null}", .{});
    defer selectors.deinit();
    const status = try std.json.parseFromSlice(std.json.Value, alloc, "{\"extruder\":{\"temperature\":20}}", .{});
    defer status.deinit();
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors.value });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(status.value, 0);
    for (1..max_pending_updates) |index| try ctx.ingest(status.value, @floatFromInt(index));
    try std.testing.expectError(error.StatusQueueFull, ctx.ingest(status.value, max_pending_updates));
    try ctx.klippyDisconnected();
    try ctx.tick(0);
    try std.testing.expectEqual(max_pending_updates, capture.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_bytes);
    ctx.stop();
    try std.testing.expectError(error.Stopped, ctx.klippyStarted(status.value, 99));
}

test "mqtt status validates selectors and interval before replacing config" {
    var ctx = StatusCtx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = .{ .object = .empty } });
    for ([_]f64{ -1, 0.25, std.math.nan(f64), std.math.inf(f64) }) |interval| {
        try std.testing.expectError(error.InvalidStatusInterval, ctx.setConfig(.{ .instance_name = "forge", .status_objects = .{ .object = .empty }, .status_interval = interval }));
    }
    try std.testing.expectError(error.InvalidStatusObjects, ctx.setConfig(.{ .instance_name = "forge", .status_objects = .null }));
    try std.testing.expectError(error.InvalidQos, ctx.setConfig(.{ .instance_name = "forge", .status_objects = .{ .object = .empty }, .default_qos = 3 }));
    try std.testing.expectError(error.InvalidTopic, ctx.setConfig(.{ .instance_name = "forge/#", .status_objects = .{ .object = .empty } }));
    try std.testing.expectEqualStrings("forge/klipper/status", ctx.config.?.topic);
    try std.testing.expect(!ctx.enabled());
}

test "mqtt status oversized updates and merged cache fail without changing prior state" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_interval = 1, .status_objects = selectors });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    var fields: std.json.ObjectMap = .empty;
    var objects: std.json.ObjectMap = .empty;
    const huge = try a.alloc(u8, max_status_bytes);
    @memset(huge, 'x');
    try fields.put(a, "text", .{ .string = huge });
    try objects.put(a, "extruder", .{ .object = fields });
    try std.testing.expectError(error.StatusTooLarge, ctx.klippyStarted(.{ .object = objects }, 1));
    try std.testing.expect(!ctx.klippy_connected);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending.len);
    fields.clearRetainingCapacity();
    try fields.put(a, "a", .{ .string = huge[0 .. max_status_bytes / 2] });
    try objects.put(a, "extruder", .{ .object = fields });
    try ctx.klippyStarted(.{ .object = objects }, 1);
    try ctx.tick(0);
    fields.clearRetainingCapacity();
    try fields.put(a, "b", .{ .string = huge[0 .. max_status_bytes / 2] });
    try objects.put(a, "extruder", .{ .object = fields });
    try ctx.ingest(.{ .object = objects }, 2);
    try std.testing.expectError(error.StatusTooLarge, ctx.tick(0.1));
    try std.testing.expectEqual(@as(f64, 1), ctx.cache_eventtime);
    try ctx.tick(1);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
    try std.testing.expect(std.mem.find(u8, capture.messages.items[0].payload, "\"a\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.messages.items[0].payload, "\"b\"") == null);
}

test "mqtt status releases all partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":[\"temperature\"],\"bed\":null}", .{})).value;
            const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":20},\"bed\":{\"target\":0}}", .{})).value;
            var ctx = StatusCtx.init(alloc, std.testing.io);
            defer ctx.deinit();
            try ctx.setConfig(.{ .instance_name = "forge", .status_interval = 1, .publish_split_status = true, .status_objects = selectors });
            const subscription = try ctx.subscription(alloc);
            defer jv.free(alloc, subscription);
            var capture: Capture = .{ .alloc = alloc };
            defer capture.deinit();
            ctx.publisher = Capture.publish;
            ctx.publisher_ctx = &capture;
            ctx.setBrokerConnected(true);
            try ctx.klippyStarted(status, 1);
            try ctx.tick(0);
            try ctx.ingest(status, 2);
            try ctx.klippyDisconnected();
            try ctx.tick(0.1);
        }
    }.run, .{});
}

test "mqtt status worker publishes off ingest and joins" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    const Target = struct {
        io: Io,
        count: std.atomic.Value(u8) = .init(0),
        ready: Io.Event = .unset,
        fn publish(context: *anyopaque, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, topic, "forge/klipper/status") or qos != 1 or retain or
                std.mem.find(u8, payload, "temperature") == null) return error.UnexpectedPublication;
            if (self.count.fetchAdd(1, .release) == 1) self.ready.set(self.io);
        }
    };
    var target: Target = .{ .io = aio };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":20}}", .{})).value;
    var ctx = StatusCtx.init(std.heap.smp_allocator, aio);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .default_qos = 1, .status_objects = selectors });
    ctx.setBrokerConnected(true);
    try ctx.start(Target.publish, &target);
    try ctx.klippyStarted(.{ .object = .empty }, 0);
    try ctx.ingest(status, 1);
    try ctx.ingest(status, 2);
    try target.ready.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    ctx.stop();
    try std.testing.expectEqual(@as(u8, 2), target.count.load(.acquire));
    try std.testing.expect(ctx.worker == null);
    var forbidden = StatusCtx.init(std.testing.allocator, aio);
    defer forbidden.deinit();
    try forbidden.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    try std.testing.expectError(error.TestingAllocatorThread, forbidden.start(Target.publish, &target));
}

test "fuzz mqtt status selectors updates intervals and split payloads" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const split = smith.valueWithHash(bool, 0);
            const timed = smith.valueWithHash(bool, 1);
            const selected = smith.valueWithHash(bool, 2);
            const temperature = smith.valueRangeAtMostWithHash(i16, -100, 500, 3);
            const updates = smith.valueRangeAtMostWithHash(u8, 1, 8, 4);
            const selectors = (try std.json.parseFromSlice(std.json.Value, a, if (selected) "{\"extruder\":[\"temperature\"]}" else "{\"extruder\":null}", .{})).value;
            var fields: std.json.ObjectMap = .empty;
            try fields.put(a, "temperature", .{ .integer = temperature });
            try fields.put(a, "target", .{ .integer = 0 });
            var objects: std.json.ObjectMap = .empty;
            try objects.put(a, "extruder", .{ .object = fields });
            const status: std.json.Value = .{ .object = objects };
            var ctx = StatusCtx.init(alloc, std.testing.io);
            defer ctx.deinit();
            try ctx.setConfig(.{ .instance_name = "forge", .status_interval = if (timed) 1 else 0, .publish_split_status = split, .status_objects = selectors });
            var capture: Capture = .{ .alloc = alloc };
            defer capture.deinit();
            ctx.publisher = Capture.publish;
            ctx.publisher_ctx = &capture;
            ctx.setBrokerConnected(true);
            try ctx.klippyStarted(.{ .object = .empty }, 0);
            for (0..updates) |index| try ctx.ingest(status, @floatFromInt(index + 1));
            try ctx.tick(100);
            try ctx.klippyDisconnected();
            try ctx.tick(101);
            const fields_per_message: usize = if (split and !selected) 2 else 1;
            const expected_messages: usize = fields_per_message * if (timed) @as(usize, 1) else @as(usize, updates);
            try std.testing.expectEqual(expected_messages, capture.messages.items.len);
            for (capture.messages.items, 0..) |message, index| {
                try std.testing.expectEqual(split, message.retain);
                const payload = (try std.json.parseFromSlice(std.json.Value, a, message.payload, .{})).value;
                const eventtime: i64 = if (timed) updates else @intCast(index / fields_per_message + 1);
                try std.testing.expectEqual(eventtime, payload.object.get("eventtime").?.integer);
                if (!split) {
                    const actual = payload.object.get("status").?.object.get("extruder").?.object;
                    try std.testing.expectEqual(@as(i64, temperature), actual.get("temperature").?.integer);
                    try std.testing.expectEqual(!selected, actual.contains("target"));
                }
            }
        }
    }.run, .{});
}

test "mqtt status initial snapshot reaches loopback broker with selected fields" {
    const mqtt_client = @import("mqtt_client.zig");
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var broker = try mqtt_client.TestBroker.bind(aio);
    defer broker.deinit();
    var done: Io.Event = .unset;
    const Peer = struct {
        fn run(peer: *mqtt_client.TestBroker, complete: *Io.Event) void {
            defer complete.set(peer.io);
            peer.run(1);
        }
        fn publish(context: *anyopaque, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
            const client: *mqtt_client.MqttClient = @ptrCast(@alignCast(context));
            try client.publish(topic, payload, qos, retain);
        }
    };
    var peer = try aio.concurrent(Peer.run, .{ &broker, &done });
    defer peer.cancel(aio);
    var client = try mqtt_client.MqttClient.connect(std.heap.smp_allocator, aio, "127.0.0.1", broker.port(), .{ .client_id = "status-test" });
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":[\"temperature\"]}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":23,\"target\":0}}", .{})).value;
    var ctx = StatusCtx.init(std.heap.smp_allocator, aio);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    ctx.setBrokerConnected(true);
    try ctx.start(Peer.publish, &client);
    try ctx.klippyStarted(status, 123.5);
    try done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    peer.await(aio);
    ctx.stop();
    try std.testing.expectEqual(@as(u32, 1), broker.publishes.load(.acquire));
    try std.testing.expectEqualStrings("forge/klipper/status", broker.got_topic[0..broker.got_topic_len]);
    try std.testing.expect(!broker.got_retain);
    const payload = (try std.json.parseFromSlice(std.json.Value, a, broker.got_payload[0..broker.got_payload_len], .{})).value;
    try std.testing.expectEqual(@as(f64, 123.5), payload.object.get("eventtime").?.float);
    const fields = payload.object.get("status").?.object.get("extruder").?.object;
    try std.testing.expectEqual(@as(usize, 1), fields.count());
    try std.testing.expectEqual(@as(i64, 23), fields.get("temperature").?.integer);
}

test "mqtt status publisher errors propagate and preserve following immediate updates" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":20}}", .{})).value;
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    const Failure = struct {
        fn publish(_: *anyopaque, _: []const u8, _: []const u8, _: u2, _: bool) !void {
            return error.ConnectionClosed;
        }
    };
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Failure.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(status, 1);
    try ctx.ingest(status, 2);
    try std.testing.expectError(error.ConnectionClosed, ctx.tick(0));
    try std.testing.expectEqual(@as(usize, 1), ctx.pending.len);
    ctx.publisher = Capture.publish;
    try ctx.tick(0.1);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
    const payload = (try std.json.parseFromSlice(std.json.Value, a, capture.messages.items[0].payload, .{})).value;
    try std.testing.expectEqual(@as(i64, 2), payload.object.get("eventtime").?.integer);
}

test "fuzz mqtt status invalid selectors and update shapes are rejected" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            var bytes: [16]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const shape = smith.valueRangeAtMostWithHash(u8, 0, 5, 1);
            const selector: std.json.Value = switch (shape) {
                0 => .null,
                1 => .{ .integer = 1 },
                2 => .{ .string = &bytes },
                3 => .{ .array = .init(a) },
                4 => .{ .bool = true },
                else => .{ .float = 1 },
            };
            var selectors: std.json.ObjectMap = .empty;
            try selectors.put(a, "extruder", selector);
            var ctx = StatusCtx.init(alloc, std.testing.io);
            defer ctx.deinit();
            if (selector == .null or selector == .array) {
                try ctx.setConfig(.{ .instance_name = "forge", .status_objects = .{ .object = selectors } });
                ctx.setBrokerConnected(true);
                try std.testing.expectError(error.InvalidStatus, ctx.klippyStarted(.{ .string = &bytes }, 1));
                try std.testing.expectError(error.InvalidStatus, ctx.klippyStarted(.{ .object = .empty }, std.math.nan(f64)));
                var invalid: std.json.ObjectMap = .empty;
                try invalid.put(a, "extruder", .{ .integer = 1 });
                try std.testing.expectError(error.InvalidStatus, ctx.klippyStarted(.{ .object = invalid }, 1));
            } else try std.testing.expectError(error.InvalidStatusObjects, ctx.setConfig(.{ .instance_name = "forge", .status_objects = .{ .object = selectors } }));
            try std.testing.expectEqual(@as(usize, 0), ctx.pending.len);
        }
    }.run, .{});
}

test "mqtt status initial empty selections survive ready marker but empty pushes are omitted" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"empty\":[],\"all\":null}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"empty\":{\"ignored\":1},\"all\":{}}", .{})).value;
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    var capture: Capture = .{ .alloc = alloc };
    defer capture.deinit();
    ctx.publisher = Capture.publish;
    ctx.publisher_ctx = &capture;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(.{ .object = .empty }, 0);
    try ctx.ingest(status, 1);
    try ctx.ingest(status, 2);
    try ctx.tick(0);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
    const payload = (try std.json.parseFromSlice(std.json.Value, a, capture.messages.items[0].payload, .{})).value;
    const actual = payload.object.get("status").?.object;
    try std.testing.expectEqual(@as(usize, 2), actual.count());
    try std.testing.expectEqual(@as(usize, 0), actual.get("empty").?.object.count());
    try std.testing.expectEqual(@as(usize, 0), actual.get("all").?.object.count());
}

test "mqtt status tick bounds a continuously replenished queue" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":20}}", .{})).value;
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    const Refill = struct {
        ctx: *StatusCtx,
        status: std.json.Value,
        count: usize = 0,
        fn publish(context: *anyopaque, _: []const u8, _: []const u8, _: u2, _: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (self.count < 100) try self.ctx.ingest(self.status, @floatFromInt(self.count));
        }
    };
    var refill: Refill = .{ .ctx = &ctx, .status = status };
    ctx.publisher = Refill.publish;
    ctx.publisher_ctx = &refill;
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(status, 0);
    try ctx.tick(0);
    try std.testing.expectEqual(max_pending_updates + 1, refill.count);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending.len);
}

test "mqtt status pending byte limit rejects bursts before the update count limit" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    const text = try a.alloc(u8, max_status_bytes / 2);
    @memset(text, 'a');
    var fields: std.json.ObjectMap = .empty;
    try fields.put(a, "text", .{ .string = text });
    var objects: std.json.ObjectMap = .empty;
    try objects.put(a, "extruder", .{ .object = fields });
    const status: std.json.Value = .{ .object = objects };
    var ctx = StatusCtx.init(alloc, std.testing.io);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    ctx.setBrokerConnected(true);
    try ctx.klippyStarted(status, 0);
    for (1..7) |index| try ctx.ingest(status, @floatFromInt(index));
    try std.testing.expectError(error.StatusQueueFull, ctx.ingest(status, 7));
    try std.testing.expectEqual(@as(usize, 7), ctx.pending.len);
    try std.testing.expect(ctx.pending_bytes <= max_pending_bytes);
}

test "mqtt status shutdown cancels a stalled publisher and joins" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    const Blocked = struct {
        io: Io,
        entered: Io.Event = .unset,
        release: Io.Event = .unset,
        fn publish(context: *anyopaque, _: []const u8, _: []const u8, _: u2, _: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.set(self.io);
            try self.release.wait(self.io);
        }
    };
    var blocked: Blocked = .{ .io = aio };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selectors = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":null}", .{})).value;
    const status = (try std.json.parseFromSlice(std.json.Value, a, "{\"extruder\":{\"temperature\":20}}", .{})).value;
    var ctx = StatusCtx.init(std.heap.smp_allocator, aio);
    defer ctx.deinit();
    try ctx.setConfig(.{ .instance_name = "forge", .status_objects = selectors });
    ctx.setBrokerConnected(true);
    try ctx.start(Blocked.publish, &blocked);
    try ctx.klippyStarted(status, 0);
    try blocked.entered.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const started = clock.monotonicSeconds(aio);
    ctx.stop();
    try std.testing.expect(clock.monotonicSeconds(aio) - started < 3);
    try std.testing.expect(ctx.worker == null);
}

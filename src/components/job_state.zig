//! JobState component — tracks Klippy print_stats and fires state-change
//! events into History and JobQueue.
//!
//! Equivalent to `vendor/moonraker/moonraker/components/job_state.py`.
//!
//! This component receives `print_stats` data from Klippy status updates,
//! detects state transitions (standby→printing→paused→resumed→complete/error/
//! cancelled), and notifies History (for live job tracking) and JobQueue
//! (for auto-advance) directly.

const std = @import("std");
const jv = @import("../json/value.zig");

// ---------------------------------------------------------------------------
// JobEvent — mirrors Moonraker common.JobEvent
// ---------------------------------------------------------------------------

pub const JobEvent = enum(u3) {
    standby = 1,
    started = 2,
    paused = 3,
    resumed = 4,
    complete = 5,
    @"error" = 6,
    cancelled = 7,

    pub fn fromString(s: []const u8) JobEvent {
        return std.meta.stringToEnum(JobEvent, s) orelse .standby;
    }

    pub fn finished(self: JobEvent) bool {
        return @backingInt(self) >= 5;
    }

    pub fn aborted(self: JobEvent) bool {
        return @backingInt(self) >= 6;
    }

    pub fn isPrinting(self: JobEvent) bool {
        return self == .started or self == .resumed;
    }
};

// ---------------------------------------------------------------------------
// JobStateCtx
// ---------------------------------------------------------------------------

pub const JobStateCtx = struct {
    gpa: std.mem.Allocator,
    bus: *const @import("../server/notify.zig").NotifyBus,

    /// Owned snapshot, valid until the next update or deinit.
    last_print_stats: std.json.ObjectMap,
    stats_arenas: [2]std.heap.ArenaAllocator,
    active_arena: u1 = 0,
    active: std.atomic.Value(bool) = .init(false),
    last_event: JobEvent,

    /// Callback for job_state:layer_changed events (cur_layer, total_layer).
    /// Set by components that need layer progress tracking.
    layer_changed: ?*const fn (i64, i64) void = null,

    /// Cross-component pointers — set by App after init.
    history: ?*@import("history.zig").HistoryCtx = null,
    job_queue: ?*@import("job_queue.zig").JobQueueCtx = null,

    pub fn init(alloc: std.mem.Allocator, bus: *const @import("../server/notify.zig").NotifyBus) !JobStateCtx {
        return JobStateCtx{
            .gpa = alloc,
            .bus = bus,
            .last_print_stats = .empty,
            .stats_arenas = .{ .init(alloc), .init(alloc) },
            .last_event = .standby,
        };
    }

    pub fn deinit(self: *JobStateCtx) void {
        for (&self.stats_arenas) |*arena| arena.deinit();
    }

    /// True while printing or paused; safe for background update checks.
    pub fn isActive(self: *const JobStateCtx) bool {
        return self.active.load(.acquire);
    }

    /// Type-erased adapter for components (e.g. update_manager) that hold an
    /// opaque printing-check callback rather than importing this module.
    pub fn isActiveErased(ctx: *anyopaque) bool {
        const self: *const JobStateCtx = @ptrCast(@alignCast(ctx));
        return self.isActive();
    }

    /// Called when Klippy disconnects or shuts down while a job is active.
    /// Updates internal state to error so that getLastStats() reflects the
    /// forced error. Does NOT fire a JobEvent — the caller (klippy_connection
    /// or history) is responsible for calling the appropriate history handler
    /// (handleKlippyDisconnect / handleKlippyShutdown).
    pub fn handleDisconnect(self: *JobStateCtx) void {
        const state_val = self.last_print_stats.get("state") orelse return;
        if (state_val != .string) return;
        const state = state_val.string;
        if (!std.mem.eql(u8, state, "printing") and !std.mem.eql(u8, state, "paused")) return;

        self.last_print_stats.getPtr("state").?.* = .{ .string = "error" };
        self.active.store(false, .release);
        self.last_event = .@"error";
    }

    /// Called when Klippy delivers a status update containing print_stats.
    /// `print_stats` must be the decoded JSON object for "print_stats".
    pub fn statusUpdate(self: *JobStateCtx, print_stats: std.json.Value) void {
        self.updateStats(print_stats, true);
    }

    /// Seed a newly connected printer without replaying past job events.
    pub fn initialize(self: *JobStateCtx, print_stats: std.json.Value) void {
        self.updateStats(print_stats, false);
    }

    fn updateStats(self: *JobStateCtx, print_stats: std.json.Value, emit_events: bool) void {
        if (print_stats != .object) return;
        const ps = print_stats.object;

        if (jv.exceedsDepth(print_stats, jv.max_value_depth)) return;
        const state_val: std.json.Value = ps.get("state") orelse self.last_print_stats.get("state") orelse .{ .string = "standby" };
        if (state_val != .string) return;
        const new_state_str = state_val.string;
        const old_state_str = if (self.last_print_stats.get("state")) |s|
            if (s == .string) s.string else "standby"
        else
            "standby";
        const prev_ps = self.last_print_stats;
        const next_arena = self.active_arena ^ 1;
        const arena = &self.stats_arenas[next_arena];
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        var new_ps = (jv.deepCopy(alloc, .{ .object = prev_ps }) catch return).object;
        var it = ps.iterator();
        while (it.next()) |kv| {
            const value = jv.deepCopy(alloc, kv.value_ptr.*) catch return;
            if (new_ps.getPtr(kv.key_ptr.*)) |existing| {
                existing.* = value;
            } else {
                const key = alloc.dupe(u8, kv.key_ptr.*) catch return;
                new_ps.put(alloc, key, value) catch return;
            }
        }
        self.last_print_stats = new_ps;
        self.active_arena = next_arena;
        self.active.store(std.mem.eql(u8, new_state_str, "printing") or std.mem.eql(u8, new_state_str, "paused"), .release);

        var effective_event: JobEvent = .standby;

        if (emit_events and !std.mem.eql(u8, new_state_str, old_state_str)) {
            if (checkIdle(old_state_str)) {
                if (std.mem.eql(u8, new_state_str, "printing")) {
                    effective_event = .started;
                } else if (!std.mem.eql(u8, new_state_str, "standby")) {
                    // Send a started event prior to the detected event.
                    self.sendJobEvent(.started, prev_ps, new_ps);
                    effective_event = fromString(new_state_str);
                }
            } else if (std.mem.eql(u8, new_state_str, "printing")) {
                if (checkResumed(prev_ps, new_ps)) {
                    effective_event = .resumed;
                } else {
                    effective_event = .started;
                }
            } else {
                effective_event = fromString(new_state_str);
            }

            if (effective_event != .standby) {
                self.sendJobEvent(effective_event, prev_ps, new_ps);
            }
        }

        // Emit job_state:layer_changed when print_stats.info.current_layer
        // is present (mirrors Moonraker job_state._status_update).
        if (if (emit_events) ps.get("info") else null) |info_val| {
            if (info_val == .object) {
                if (info_val.object.get("current_layer")) |cl_val| {
                    const cur_layer: i64 = switch (cl_val) {
                        .integer => |i| i,
                        .float => |f| jv.floatToInt(f) orelse -1,
                        else => -1,
                    };
                    if (cur_layer >= 0) {
                        const total_layer: i64 = if (info_val.object.get("total_layer")) |tl| switch (tl) {
                            .integer => |i| i,
                            .float => |f| jv.floatToInt(f) orelse 0,
                            else => 0,
                        } else 0;
                        if (self.layer_changed) |cb| {
                            cb(cur_layer, total_layer);
                        }
                    }
                }
            }
        }
    }

    fn sendJobEvent(self: *JobStateCtx, event: JobEvent, prev_ps: std.json.ObjectMap, new_ps: std.json.ObjectMap) void {
        self.last_event = event;

        // Notify History for live job tracking.
        if (self.history) |h| {
            h.onJobStateChanged(event, prev_ps, new_ps);
        }

        // Notify JobQueue for auto-advance.
        if (self.job_queue) |jq| {
            jq.onJobStateChanged(event, prev_ps, new_ps);
        }
    }

    pub fn getLastStats(self: *JobStateCtx) std.json.ObjectMap {
        return self.last_print_stats;
    }

    pub fn getLastEvent(self: *JobStateCtx) JobEvent {
        return self.last_event;
    }
};

// ---------------------------------------------------------------------------
// State machine helpers (package-private)
// ---------------------------------------------------------------------------

fn checkResumed(prev_ps: std.json.ObjectMap, new_ps: std.json.ObjectMap) bool {
    const prev_state = prev_ps.get("state") orelse return false;
    if (prev_state != .string) return false;
    if (!std.mem.eql(u8, prev_state.string, "paused")) return false;

    const prev_filename = prev_ps.get("filename") orelse return false;
    const new_filename = new_ps.get("filename") orelse return false;
    if (prev_filename != .string or new_filename != .string) return false;
    if (!std.mem.eql(u8, prev_filename.string, new_filename.string)) return false;

    const prev_td = prev_ps.get("total_duration") orelse return false;
    const new_td = new_ps.get("total_duration") orelse return false;
    const prev_dur: f64 = switch (prev_td) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return false,
    };
    const new_dur: f64 = switch (new_td) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return false,
    };
    return prev_dur < new_dur;
}

fn checkIdle(state: []const u8) bool {
    return std.mem.eql(u8, state, "standby") or
        std.mem.eql(u8, state, "complete") or
        std.mem.eql(u8, state, "cancelled") or
        std.mem.eql(u8, state, "error");
}

fn fromString(s: []const u8) JobEvent {
    return JobEvent.fromString(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "JobEvent fromString" {
    try testing.expectEqual(JobEvent.standby, JobEvent.fromString("standby"));
    try testing.expectEqual(JobEvent.started, JobEvent.fromString("started"));
    try testing.expectEqual(JobEvent.paused, JobEvent.fromString("paused"));
    try testing.expectEqual(JobEvent.resumed, JobEvent.fromString("resumed"));
    try testing.expectEqual(JobEvent.complete, JobEvent.fromString("complete"));
    try testing.expectEqual(JobEvent.@"error", JobEvent.fromString("error"));
    try testing.expectEqual(JobEvent.cancelled, JobEvent.fromString("cancelled"));
    try testing.expectEqual(JobEvent.standby, JobEvent.fromString("garbage"));
}

test "JobEvent finished" {
    try testing.expect(!JobEvent.standby.finished());
    try testing.expect(!JobEvent.started.finished());
    try testing.expect(!JobEvent.paused.finished());
    try testing.expect(!JobEvent.resumed.finished());
    try testing.expect(JobEvent.complete.finished());
    try testing.expect(JobEvent.@"error".finished());
    try testing.expect(JobEvent.cancelled.finished());
}

test "JobEvent aborted" {
    try testing.expect(!JobEvent.complete.aborted());
    try testing.expect(JobEvent.@"error".aborted());
    try testing.expect(JobEvent.cancelled.aborted());
}

test "JobEvent isPrinting" {
    try testing.expect(!JobEvent.standby.isPrinting());
    try testing.expect(JobEvent.started.isPrinting());
    try testing.expect(!JobEvent.paused.isPrinting());
    try testing.expect(JobEvent.resumed.isPrinting());
    try testing.expect(!JobEvent.complete.isPrinting());
}

test "checkIdle" {
    try testing.expect(checkIdle("standby"));
    try testing.expect(checkIdle("complete"));
    try testing.expect(checkIdle("cancelled"));
    try testing.expect(checkIdle("error"));
    try testing.expect(!checkIdle("printing"));
    try testing.expect(!checkIdle("paused"));
    try testing.expect(!checkIdle(""));
}

test "checkResumed same file longer duration" {
    var prev: std.json.ObjectMap = .empty;
    defer prev.deinit(std.heap.smp_allocator);
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try prev.put(std.heap.smp_allocator, "total_duration", .{ .float = 100.0 });

    var newm: std.json.ObjectMap = .empty;
    defer newm.deinit(std.heap.smp_allocator);
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try newm.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try newm.put(std.heap.smp_allocator, "total_duration", .{ .float = 150.0 });

    try testing.expect(checkResumed(prev, newm));
}

test "checkResumed different file" {
    var prev: std.json.ObjectMap = .empty;
    defer prev.deinit(std.heap.smp_allocator);
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    var newm: std.json.ObjectMap = .empty;
    defer newm.deinit(std.heap.smp_allocator);
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try newm.put(std.heap.smp_allocator, "filename", .{ .string = "other.gcode" });

    try testing.expect(!checkResumed(prev, newm));
}

test "checkResumed not paused" {
    var prev: std.json.ObjectMap = .empty;
    defer prev.deinit(std.heap.smp_allocator);
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "standby" });

    var newm: std.json.ObjectMap = .empty;
    defer newm.deinit(std.heap.smp_allocator);
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });

    try testing.expect(!checkResumed(prev, newm));
}

test "checkResumed shorter duration" {
    var prev: std.json.ObjectMap = .empty;
    defer prev.deinit(std.heap.smp_allocator);
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try prev.put(std.heap.smp_allocator, "total_duration", .{ .float = 150.0 });

    var newm: std.json.ObjectMap = .empty;
    defer newm.deinit(std.heap.smp_allocator);
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try newm.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try newm.put(std.heap.smp_allocator, "total_duration", .{ .float = 100.0 });

    try testing.expect(!checkResumed(prev, newm));
}

test "JobStateCtx init/deinit" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();
    try testing.expectEqual(JobEvent.standby, js.last_event);
    try testing.expect(js.last_print_stats.count() == 0);
}

test "statusUpdate idle to printing emits started" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    // Initial state: standby (default).
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "standby" });
        js.statusUpdate(.{ .object = initial });
    }

    // Build print_stats as std.json.Value
    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.started, js.last_event);
}

test "isActive: true for printing/paused, false otherwise" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try testing.expect(!js.isActive()); // no state yet
    for ([_]struct { s: []const u8, active: bool }{
        .{ .s = "printing", .active = true },
        .{ .s = "paused", .active = true },
        .{ .s = "standby", .active = false },
        .{ .s = "complete", .active = false },
        .{ .s = "error", .active = false },
    }) |c| {
        {
            var initial: std.json.ObjectMap = .empty;
            defer initial.deinit(testing.allocator);
            try initial.put(testing.allocator, "state", .{ .string = c.s });
            js.statusUpdate(.{ .object = initial });
        }
        try testing.expectEqual(c.active, js.isActive());
        // isActiveErased must agree with isActive.
        try testing.expectEqual(js.isActive(), JobStateCtx.isActiveErased(&js));
    }
}

test "fuzz isActive: arbitrary state string never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const bus: @import("../server/notify.zig").NotifyBus = undefined;
            var js = try JobStateCtx.init(testing.allocator, &bus);
            defer js.deinit();
            var sbuf: [16]u8 = undefined;
            smith.bytesWithHash(&sbuf, 0);
            {
                var initial: std.json.ObjectMap = .empty;
                defer initial.deinit(testing.allocator);
                try initial.put(testing.allocator, "state", .{ .string = &sbuf });
                js.statusUpdate(.{ .object = initial });
            }
            _ = js.isActive();
        }
    }.run, .{});
}

test "statusUpdate printing to complete" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "complete" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.complete, js.last_event);
}

test "statusUpdate printing to paused" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.paused, js.last_event);
}

test "statusUpdate paused to printing resumed" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "paused" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "total_duration", .{ .float = 100.0 });
        js.statusUpdate(.{ .object = initial });
    }

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try ps_map.put(std.heap.smp_allocator, "total_duration", .{ .float = 150.0 });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.resumed, js.last_event);
}

test "statusUpdate no state change" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    const ps_val = std.json.Value{ .object = ps_map };

    js.last_event = .standby; // reset
    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.standby, js.last_event); // no event emitted
}

test "statusUpdate no print_stats" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    js.statusUpdate(.{ .object = .empty }); // no "state" key
    try testing.expectEqual(JobEvent.standby, js.last_event);
}

test "getLastStats getLastEvent" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }
    js.last_event = .started;

    const stats = js.getLastStats();
    try testing.expectEqual(JobEvent.started, js.getLastEvent());
    _ = stats;
}

test "handleDisconnect: printing to error" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.@"error", js.last_event);
    try testing.expectEqualStrings("error", js.last_print_stats.get("state").?.string);
}

test "handleDisconnect: paused to error" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "paused" });
        js.statusUpdate(.{ .object = initial });
    }
    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "filename", .{ .string = "test.gcode" });
        js.statusUpdate(.{ .object = initial });
    }

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.@"error", js.last_event);
}

test "handleDisconnect: standby no-op" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "standby" });
        js.statusUpdate(.{ .object = initial });
    }
    js.last_event = .standby;

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.standby, js.last_event); // unchanged
}

test "handleDisconnect: complete no-op" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "complete" });
        js.statusUpdate(.{ .object = initial });
    }
    js.last_event = .complete;

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.complete, js.last_event); // unchanged
}

test "handleDisconnect: no state field no-op" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    js.handleDisconnect(); // no state in last_print_stats

    try testing.expectEqual(JobEvent.standby, js.last_event);
}

// ---------------------------------------------------------------------------
// Fuzz tests
// ---------------------------------------------------------------------------

// Shared test state for layer_changed callback capture.
var test_layer_changed_cur: i64 = -1;
var test_layer_changed_total: i64 = -1;
fn testLayerChangedCb(cur: i64, total: i64) void {
    test_layer_changed_cur = cur;
    test_layer_changed_total = total;
}

test "statusUpdate emits layer_changed when info.current_layer present" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    test_layer_changed_cur = -1;
    test_layer_changed_total = -1;
    js.layer_changed = testLayerChangedCb;

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }

    var info_obj: std.json.ObjectMap = .empty;
    defer info_obj.deinit(std.heap.smp_allocator);
    try info_obj.put(std.heap.smp_allocator, "current_layer", .{ .integer = 42 });
    try info_obj.put(std.heap.smp_allocator, "total_layer", .{ .integer = 200 });

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "info", .{ .object = info_obj });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(@as(i64, 42), test_layer_changed_cur);
    try testing.expectEqual(@as(i64, 200), test_layer_changed_total);
}

test "statusUpdate layer_changed: no callback set, no crash" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "printing" });
        js.statusUpdate(.{ .object = initial });
    }

    var info_obj: std.json.ObjectMap = .empty;
    defer info_obj.deinit(std.heap.smp_allocator);
    try info_obj.put(std.heap.smp_allocator, "current_layer", .{ .integer = 10 });

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "info", .{ .object = info_obj });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val); // must not crash with null callback
}

test "statusUpdate layer_changed: no info key, no callback" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    test_layer_changed_cur = -1;
    js.layer_changed = testLayerChangedCb;

    {
        var initial: std.json.ObjectMap = .empty;
        defer initial.deinit(testing.allocator);
        try initial.put(testing.allocator, "state", .{ .string = "standby" });
        js.statusUpdate(.{ .object = initial });
    }

    var ps_map: std.json.ObjectMap = .empty;
    defer ps_map.deinit(std.heap.smp_allocator);
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try ps_map.put(std.heap.smp_allocator, "total_duration", .{ .float = 1.0 });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(@as(i64, -1), test_layer_changed_cur); // not called
}

test "fuzz job_state statusUpdate" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    // Test all valid state transitions without crashing.
    const states = [_][]const u8{ "standby", "printing", "paused", "complete", "error", "cancelled" };
    for (states) |from| {
        {
            var initial: std.json.ObjectMap = .empty;
            defer initial.deinit(testing.allocator);
            try initial.put(testing.allocator, "state", .{ .string = from });
            js.statusUpdate(.{ .object = initial });
        }
        for (states, 0..) |to, idx| {
            var ps_map: std.json.ObjectMap = .empty;
            defer ps_map.deinit(std.heap.smp_allocator);
            try ps_map.put(std.heap.smp_allocator, "state", .{ .string = to });
            try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "fuzz.gcode" });
            try ps_map.put(std.heap.smp_allocator, "total_duration", .{ .float = @floatFromInt(@backingInt(js.last_event)) });
            // Exercise layer_changed path on even iterations.
            var info_obj: std.json.ObjectMap = .empty;
            defer info_obj.deinit(std.heap.smp_allocator);
            if (idx % 2 == 0) {
                try info_obj.put(std.heap.smp_allocator, "current_layer", .{ .integer = @as(i64, @intCast(idx)) });
                try info_obj.put(std.heap.smp_allocator, "total_layer", .{ .integer = 200 });
                try ps_map.put(std.heap.smp_allocator, "info", .{ .object = info_obj });
            }
            const ps_val = std.json.Value{ .object = ps_map };
            js.statusUpdate(ps_val);
        }
    }
}

test "fuzz job_state fromString" {
    const strings = [_][]const u8{ "", "standby", "started", "paused", "resumed", "complete", "error", "cancelled", "printing", "garbage", "STANDBY", "Standby" };
    for (strings) |s| {
        _ = JobEvent.fromString(s);
    }
}

test "fuzz checkIdle" {
    const inputs = [_][]const u8{ "standby", "complete", "cancelled", "error", "printing", "paused", "", "unknown", "STANDBY" };
    for (inputs) |s| {
        _ = checkIdle(s);
    }
}

test "fuzz checkResumed" {
    // Exercise checkResumed with various state combos.
    const states = [_][]const u8{ "paused", "printing", "standby", "complete" };
    const fnames = [_][]const u8{ "a.gcode", "b.gcode", "a.gcode" };
    const durs = [_]f64{ 1.0, 100.0, 200.0, -1.0 };

    for (states) |prev_state| {
        for (states) |new_state| {
            for (fnames) |pf| {
                for (fnames) |nf| {
                    for (durs) |pd| {
                        for (durs) |nd| {
                            var prev: std.json.ObjectMap = .empty;
                            defer prev.deinit(std.heap.smp_allocator);
                            prev.put(std.heap.smp_allocator, "state", .{ .string = prev_state }) catch continue;
                            prev.put(std.heap.smp_allocator, "filename", .{ .string = pf }) catch continue;
                            prev.put(std.heap.smp_allocator, "total_duration", .{ .float = pd }) catch continue;

                            var newm: std.json.ObjectMap = .empty;
                            defer newm.deinit(std.heap.smp_allocator);
                            newm.put(std.heap.smp_allocator, "state", .{ .string = new_state }) catch continue;
                            newm.put(std.heap.smp_allocator, "filename", .{ .string = nf }) catch continue;
                            newm.put(std.heap.smp_allocator, "total_duration", .{ .float = nd }) catch continue;

                            _ = checkResumed(prev, newm);
                        }
                    }
                }
            }
        }
    }
}

test "fuzz JobEvent methods" {
    // Enumerate all enum values — finished/aborted/isPrinting must not crash.
    const events = [_]JobEvent{ .standby, .started, .paused, .resumed, .complete, .@"error", .cancelled };
    for (events) |e| {
        _ = e.finished();
        _ = e.aborted();
        _ = e.isPrinting();
    }
}

test "fuzz handleDisconnect" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    const states = [_][]const u8{ "standby", "printing", "paused", "complete", "error", "cancelled", "unknown" };
    for (states) |s| {
        var ps: std.json.ObjectMap = .empty;
        defer ps.deinit(testing.allocator);
        try ps.put(testing.allocator, "state", .{ .string = s });
        js.statusUpdate(.{ .object = ps });
        js.handleDisconnect();
        _ = js.getLastEvent();
        _ = js.getLastStats();
    }
}

test "fuzz getLastStats/getLastEvent" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    const events = [_]JobEvent{ .standby, .started, .paused, .resumed, .complete, .@"error", .cancelled };
    for (events) |e| {
        js.last_event = e;
        _ = js.getLastStats();
        _ = js.getLastEvent();
    }
}

test "print stats own partial updates after source is freed" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"state":"printing","filename":"benchy.gcode","info":{"current_layer":1},"tags":["PLA"]}
        , .{});
        defer parsed.deinit();
        js.statusUpdate(parsed.value);
    }
    for (0..100) |n| {
        var partial: std.json.ObjectMap = .empty;
        defer partial.deinit(testing.allocator);
        try partial.put(testing.allocator, "total_duration", .{ .integer = @intCast(n) });
        js.statusUpdate(.{ .object = partial });
    }
    try testing.expect(js.isActive());
    try testing.expectEqualStrings("benchy.gcode", js.getLastStats().get("filename").?.string);
    try testing.expectEqualStrings("PLA", js.getLastStats().get("tags").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 99), js.getLastStats().get("total_duration").?.integer);
    js.handleDisconnect();
    try testing.expect(!js.isActive());
    try testing.expectEqualStrings("error", js.getLastStats().get("state").?.string);
}

test "fuzz print stats copy bounded arbitrary strings" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const bus: @import("../server/notify.zig").NotifyBus = undefined;
            var js = try JobStateCtx.init(testing.allocator, &bus);
            defer js.deinit();
            var raw: [32]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            var ps: std.json.ObjectMap = .empty;
            defer ps.deinit(testing.allocator);
            try ps.put(testing.allocator, "filename", .{ .string = &raw });
            js.statusUpdate(.{ .object = ps });
            const expected = raw;
            @memset(&raw, 0);
            try testing.expectEqualSlices(u8, &expected, js.getLastStats().get("filename").?.string);
        }
    }.run, .{});
}

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
        if (std.mem.eql(u8, s, "standby")) return .standby;
        if (std.mem.eql(u8, s, "started")) return .started;
        if (std.mem.eql(u8, s, "paused")) return .paused;
        if (std.mem.eql(u8, s, "resumed")) return .resumed;
        if (std.mem.eql(u8, s, "complete")) return .complete;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        return .standby;
    }

    pub fn finished(self: JobEvent) bool {
        return @intFromEnum(self) >= 5;
    }

    pub fn aborted(self: JobEvent) bool {
        return @intFromEnum(self) >= 6;
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

    /// Latest print_stats object from Klippy. Owns keys; values may point
    /// into parsed JSON (temporary). Used only for comparison; callers should
    /// not hold references across status updates.
    last_print_stats: std.json.ObjectMap,
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
            .last_event = .standby,
        };
    }

    pub fn deinit(self: *JobStateCtx) void {
        // last_print_stats uses .empty (smp_allocator); no explicit deinit needed.
        _ = self;
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

        self.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "error" }) catch {};
        self.last_event = .@"error";
    }

    /// Called when Klippy delivers a status update containing print_stats.
    /// `print_stats` must be the decoded JSON object for "print_stats".
    pub fn statusUpdate(self: *JobStateCtx, print_stats: std.json.Value) void {
        if (print_stats != .object) return;
        const ps = print_stats.object;

        // Check for state field.
        const state_val = ps.get("state") orelse return;
        if (state_val != .string) return;

        const new_state_str = state_val.string;
        const old_state_str = if (self.last_print_stats.get("state")) |s|
            if (s == .string) s.string else "standby"
        else
            "standby";

        // Build prev_ps as a shallow clone of last_print_stats.
        var prev_ps: std.json.ObjectMap = .empty;
        {
            var it = self.last_print_stats.iterator();
            while (it.next()) |kv| {
                prev_ps.put(std.heap.smp_allocator, kv.key_ptr.*, kv.value_ptr.*) catch continue;
            }
        }

        // Build new_ps: merge ps into a copy of last_print_stats.
        var new_ps: std.json.ObjectMap = .empty;
        {
            var it = self.last_print_stats.iterator();
            while (it.next()) |kv| {
                new_ps.put(std.heap.smp_allocator, kv.key_ptr.*, kv.value_ptr.*) catch continue;
            }
            var it2 = ps.iterator();
            while (it2.next()) |kv| {
                // put updates existing keys
                new_ps.put(std.heap.smp_allocator, kv.key_ptr.*, kv.value_ptr.*) catch continue;
            }
        }

        var effective_event: JobEvent = .standby;

        if (!std.mem.eql(u8, new_state_str, old_state_str)) {
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
        if (ps.get("info")) |info_val| {
            if (info_val == .object) {
                if (info_val.object.get("current_layer")) |cl_val| {
                    const cur_layer: i64 = switch (cl_val) {
                        .integer => |i| i,
                        .float => |f| @intFromFloat(f),
                        else => -1,
                    };
                    if (cur_layer >= 0) {
                        const total_layer: i64 = if (info_val.object.get("total_layer")) |tl| switch (tl) {
                            .integer => |i| i,
                            .float => |f| @intFromFloat(f),
                            else => 0,
                        } else 0;
                        if (self.layer_changed) |cb| {
                            cb(cur_layer, total_layer);
                        }
                    }
                }
            }
        }

        // Update last_print_stats with new data.
        {
            var it = ps.iterator();
            while (it.next()) |kv| {
                self.last_print_stats.put(std.heap.smp_allocator, kv.key_ptr.*, kv.value_ptr.*) catch continue;
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
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try prev.put(std.heap.smp_allocator, "total_duration", .{ .float = 100.0 });

    var newm: std.json.ObjectMap = .empty;
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try newm.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try newm.put(std.heap.smp_allocator, "total_duration", .{ .float = 150.0 });

    try testing.expect(checkResumed(prev, newm));
}

test "checkResumed different file" {
    var prev: std.json.ObjectMap = .empty;
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    var newm: std.json.ObjectMap = .empty;
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try newm.put(std.heap.smp_allocator, "filename", .{ .string = "other.gcode" });

    try testing.expect(!checkResumed(prev, newm));
}

test "checkResumed not paused" {
    var prev: std.json.ObjectMap = .empty;
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "standby" });

    var newm: std.json.ObjectMap = .empty;
    try newm.put(std.heap.smp_allocator, "state", .{ .string = "printing" });

    try testing.expect(!checkResumed(prev, newm));
}

test "checkResumed shorter duration" {
    var prev: std.json.ObjectMap = .empty;
    try prev.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try prev.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try prev.put(std.heap.smp_allocator, "total_duration", .{ .float = 150.0 });

    var newm: std.json.ObjectMap = .empty;
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
    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "standby" });

    // Build print_stats as std.json.Value
    var ps_map: std.json.ObjectMap = .empty;
    try ps_map.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    const ps_val = std.json.Value{ .object = ps_map };

    js.statusUpdate(ps_val);

    try testing.expectEqual(JobEvent.started, js.last_event);
}

test "statusUpdate printing to complete" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    try js.last_print_stats.put(std.heap.smp_allocator, "total_duration", .{ .float = 100.0 });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });
    js.last_event = .started;

    const stats = js.getLastStats();
    try testing.expectEqual(JobEvent.started, js.getLastEvent());
    _ = stats;
}

test "handleDisconnect: printing to error" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });
    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.@"error", js.last_event);
    try testing.expectEqualStrings("error", js.last_print_stats.get("state").?.string);
}

test "handleDisconnect: paused to error" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "paused" });
    try js.last_print_stats.put(std.heap.smp_allocator, "filename", .{ .string = "test.gcode" });

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.@"error", js.last_event);
}

test "handleDisconnect: standby no-op" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "standby" });
    js.last_event = .standby;

    js.handleDisconnect();

    try testing.expectEqual(JobEvent.standby, js.last_event); // unchanged
}

test "handleDisconnect: complete no-op" {
    const bus: @import("../server/notify.zig").NotifyBus = undefined;
    var js = try JobStateCtx.init(testing.allocator, &bus);
    defer js.deinit();

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "complete" });
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });

    var info_obj: std.json.ObjectMap = .empty;
    try info_obj.put(std.heap.smp_allocator, "current_layer", .{ .integer = 42 });
    try info_obj.put(std.heap.smp_allocator, "total_layer", .{ .integer = 200 });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "printing" });

    var info_obj: std.json.ObjectMap = .empty;
    try info_obj.put(std.heap.smp_allocator, "current_layer", .{ .integer = 10 });

    var ps_map: std.json.ObjectMap = .empty;
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

    try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = "standby" });

    var ps_map: std.json.ObjectMap = .empty;
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
        try js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = from });
        for (states, 0..) |to, idx| {
            var ps_map: std.json.ObjectMap = .empty;
            try ps_map.put(std.heap.smp_allocator, "state", .{ .string = to });
            try ps_map.put(std.heap.smp_allocator, "filename", .{ .string = "fuzz.gcode" });
            try ps_map.put(std.heap.smp_allocator, "total_duration", .{ .float = @floatFromInt(@intFromEnum(js.last_event)) });
            // Exercise layer_changed path on even iterations.
            if (idx % 2 == 0) {
                var info_obj: std.json.ObjectMap = .empty;
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
                            prev.put(std.heap.smp_allocator, "state", .{ .string = prev_state }) catch continue;
                            prev.put(std.heap.smp_allocator, "filename", .{ .string = pf }) catch continue;
                            prev.put(std.heap.smp_allocator, "total_duration", .{ .float = pd }) catch continue;

                            var newm: std.json.ObjectMap = .empty;
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
        js.last_print_stats.clearRetainingCapacity();
        js.last_event = .standby;
        js.last_print_stats.put(std.heap.smp_allocator, "state", .{ .string = s }) catch continue;
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

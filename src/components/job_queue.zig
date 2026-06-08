//! server.job_queue.* API component — Moonraker-compatible print job queue.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/job_queue.py`:
//!
//!   POST   /server/job_queue/job     → server.job_queue.post_job (enqueue)
//!   DELETE /server/job_queue/job     → server.job_queue.delete_job
//!   POST   /server/job_queue/pause   → server.job_queue.pause
//!   POST   /server/job_queue/start   → server.job_queue.start
//!   GET    /server/job_queue/status  → server.job_queue.status
//!   POST   /server/job_queue/jump    → server.job_queue.jump
//!
//! Queue state is persisted in the DataStore under namespace "job_queue" with
//! key "queue". Queue items are serialized as a JSON array of job objects.
//!
//! NOTE: Without Klippy there is no print dispatch. The queue state machine
//! is implemented faithfully (paused/ready/loading/starting) but job_loaded
//! transitions (starting a print via Klippy) are never triggered. The queue
//! starts in "paused" state.
//!
//! Queued job shape (matches job_queue.py QueuedJob.as_dict):
//!   filename, job_id, time_added, time_in_queue
//!
//! notify_job_queue_changed payload (matches _send_queue_event):
//!   {"action": str, "updated_queue": [...] | null, "queue_state": str}
//!
//! POST job params: filenames (list), reset (bool, false)
//! DELETE job params: job_ids (list) OR all (bool)
//! jump params: job_id (str)
//! status → {"queued_jobs": [...], "queue_state": str}

const std = @import("std");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const clock = @import("../util/clock.zig");
const notify = @import("../server/notify.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Function signature for dispatching a gcode request to Klippy.
/// Set by app.zig after both JobQueueCtx and KlippyCtx are created.
pub const DispatchFn = *const fn (ctx: *anyopaque, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value;

pub const JobQueueCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    /// io is set after the event loop starts (via setIo). Notifications are
    /// only emitted when io is non-null (suppressed during App.init / unit tests).
    io: ?std.Io,
    /// Owned allocator for the in-memory job list (persisted on each change).
    gpa: std.mem.Allocator,
    /// In-memory ordered list of queued jobs (owned by gpa).
    jobs: std.ArrayList(QueuedJob),
    /// Current queue state string.
    queue_state: []const u8,
    /// Opaque pointer to KlippyCtx for print dispatch. Set by app.zig via
    /// setKlippyDispatch (avoids circular @import with klippy_connection.zig).
    klippy: ?*anyopaque = null,
    /// Dispatch function that calls into KlippyCtx to send gcode scripts.
    dispatchFn: ?DispatchFn = null,
    /// Gcode script injected between queued print jobs (config: job_transition_gcode).
    transition_gcode: ?[]const u8 = null,
    /// Delay in seconds between queued jobs (config: job_transition_delay).
    transition_delay: f64 = 0.0,
    /// Background thread for transition_delay timer (nil when delay is zero or
    /// no timer is active). Pattern follows proc_stat in machine.zig.
    delay_thread: ?std.Thread = null,
    /// Atomic flag that cancels any running transition_delay timer.
    delay_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Monotonic suffix for job ids — guarantees uniqueness even when two jobs
    /// are enqueued within the same clock nanosecond (a tight `post_job` loop).
    job_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Optional file-existence check (file_manager.gcodeExistsErased). When wired,
    /// post_job rejects filenames that don't exist (Moonraker check_file_exists).
    file_check: ?*const fn (*anyopaque, []const u8) bool = null,
    file_check_ctx: ?*anyopaque = null,
    /// Optional printing-state check (job_state.isActiveErased). When a print is
    /// active the queue won't dispatch the next job (Moonraker _check_can_print).
    printing_check: ?*const fn (*anyopaque) bool = null,
    printing_ctx: ?*anyopaque = null,

    fn fileExists(self: *const JobQueueCtx, filename: []const u8) bool {
        const f = self.file_check orelse return true; // no checker → don't block
        const c = self.file_check_ctx orelse return true;
        return f(c, filename);
    }

    fn isPrinting(self: *const JobQueueCtx) bool {
        const f = self.printing_check orelse return false;
        const c = self.printing_ctx orelse return false;
        return f(c);
    }

    pub fn init(alloc: std.mem.Allocator, store: DataStore, bus: *NotifyBus) !JobQueueCtx {
        var ctx = JobQueueCtx{
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .jobs = .empty,
            .queue_state = "paused",
            .klippy = null,
            .dispatchFn = null,
            .transition_gcode = null,
            .transition_delay = 0.0,
            .delay_thread = null,
            .delay_cancel = std.atomic.Value(bool).init(false),
        };
        // Load persisted queue on init
        ctx.loadFromStore() catch {};
        return ctx;
    }

    /// Supply a live io so notifications can be emitted. Called after the App's
    /// event loop is running (see app.zig httpServer).
    pub fn setIo(self: *JobQueueCtx, io: std.Io) void {
        self.io = io;
    }

    /// Wire Klippy dispatch so the queue can send gcode commands (start/pause)
    /// to Klippy. Called by app.zig after both contexts are created.
    pub fn setKlippyDispatch(self: *JobQueueCtx, klippy_ptr: *anyopaque, dispatch_fn: DispatchFn) void {
        self.klippy = klippy_ptr;
        self.dispatchFn = dispatch_fn;
    }

    /// Set the transition gcode and delay injected between queued print jobs.
    /// Called from app.zig during config parsing ([job_queue] section).
    pub fn setTransitionConfig(self: *JobQueueCtx, gcode: ?[]const u8, delay: f64) void {
        self.transition_gcode = gcode;
        self.transition_delay = delay;
    }

    /// Returns true when Klippy is wired and connected.
    pub fn canDispatch(self: *const JobQueueCtx) bool {
        return self.klippy != null and self.dispatchFn != null;
    }

    pub fn deinit(self: *JobQueueCtx) void {
        // Cancel any running delay timer and join before freeing memory.
        // Null out io / klippy state first so the timer thread can observe
        // the early-exit guard even if it already read the cancel flag.
        self.delay_cancel.store(true, .release);
        self.klippy = null;
        self.dispatchFn = null;
        self.io = null;
        if (self.delay_thread) |th| {
            th.join();
            self.delay_thread = null;
        }
        for (self.jobs.items) |*j| j.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
        self.jobs = .empty;
    }

    /// Cancel a running transition_delay timer (no-op when no timer is active).
    fn cancelDelayTimer(self: *JobQueueCtx) void {
        self.delay_cancel.store(true, .release);
        if (self.delay_thread) |th| {
            th.join();
            self.delay_thread = null;
        }
    }

    /// Called by JobStateCtx when a job state transition is detected.
    /// On complete: if automatic, pop the completed job and advance to next.
    /// On abort (error/cancelled): set state to paused.
    pub fn onJobStateChanged(self: *JobQueueCtx, event: anytype, _: std.json.ObjectMap, _: std.json.ObjectMap) void {
        switch (event) {
            .complete => {
                // Remove the completed job from the front of the queue.
                if (self.jobs.items.len > 0) {
                    self.jobs.items[0].deinit(self.gpa);
                    _ = self.jobs.orderedRemove(0);
                }
                if (self.jobs.items.len > 0) {
                    self.queue_state = "ready";
                    // Auto-advance: dispatch next job to Klippy after
                    // transition_delay (if configured) or immediately.
                    if (self.canDispatch()) {
                        self.scheduleNextJobDispatch() catch {};
                    }
                } else {
                    self.queue_state = "paused";
                }
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                self.saveToStore(arena.allocator());
                emitQueueChanged(self, arena.allocator(), "state_changed", true);
            },
            .@"error" => {
                if (self.jobs.items.len > 0) {
                    self.queue_state = "paused";
                    self.cancelDelayTimer();
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    self.saveToStore(arena.allocator());
                    emitQueueChanged(self, arena.allocator(), "state_changed", false);
                }
            },
            .cancelled => {
                if (self.jobs.items.len > 0) {
                    self.queue_state = "paused";
                    self.cancelDelayTimer();
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    self.saveToStore(arena.allocator());
                    emitQueueChanged(self, arena.allocator(), "state_changed", false);
                }
            },
            else => {},
        }
    }

    /// Schedule the next job dispatch after transition_delay (or immediately
    /// when delay is zero).  When delay > 0 a background timer thread is
    /// spawned that sleeps for delay seconds, then calls dispatchNextJob and
    /// emits a queue_changed notification once the dispatch is complete.
    /// The timer is cancelled by cancelDelayTimer (called on pause/abort/error).
    fn scheduleNextJobDispatch(self: *JobQueueCtx) !void {
        if (self.transition_delay > 0) {
            // Cancel any previously running timer.
            self.cancelDelayTimer();
            self.delay_cancel.store(false, .release);
            self.queue_state = "loading";
            self.delay_thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, transitionDelayCallback, .{self}) catch |e| {
                self.delay_thread = null;
                return e;
            };
        } else {
            // No delay — dispatch inline.
            try self.dispatchNextJob();
        }
    }

    /// Dispatch start-gcode for the front job to Klippy.
    /// When transition_gcode is configured, it is sent first (between-job gcode
    /// injection, matching Moonraker's _start_next_job → _load_next_job flow).
    fn dispatchNextJob(self: *JobQueueCtx) !void {
        if (self.jobs.items.len == 0) return;
        const front = &self.jobs.items[0];
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // Inject transition gcode if configured. On failure, pause the queue
        // rather than proceeding to start the print (Moonraker _pop_job).
        if (self.transition_gcode) |tg| {
            if (tg.len > 0) {
                self.queue_state = "loading";
                var tparams = try std.json.ObjectMap.init(a, &.{}, &.{});
                try tparams.put(a, "script", .{ .string = tg });
                _ = self.dispatchFn.?(self.klippy.?, "gcode/script", .{ .object = tparams }, a) catch {
                    self.queue_state = "paused";
                    return;
                };
                // The transition gcode may have paused the queue (e.g. an M-code
                // that triggered a pause) — don't start the print if so.
                if (!std.mem.eql(u8, self.queue_state, "loading")) return;
            }
        }

        // Build on the arena (no fixed 512B cap → no truncation, no extra dupe).
        const script = try std.fmt.allocPrint(a, "SDCARD_PRINT_FILE FILENAME=\"{s}\"", .{front.filename});

        var params_obj = try std.json.ObjectMap.init(a, &.{}, &.{});
        try params_obj.put(a, "script", .{ .string = script });
        // On start-gcode failure, pause the queue (don't silently drop the job).
        _ = self.dispatchFn.?(self.klippy.?, "gcode/script", .{ .object = params_obj }, a) catch {
            self.queue_state = "paused";
            return;
        };
    }

    /// Dispatch pause command to Klippy.
    fn dispatchPause(self: *JobQueueCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const empty = try std.json.ObjectMap.init(a, &.{}, &.{});
        _ = try self.dispatchFn.?(self.klippy.?, "pause_resume/pause", .{ .object = empty }, a);
    }

    /// Dispatch resume command to Klippy.
    fn dispatchResume(self: *JobQueueCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const empty = try std.json.ObjectMap.init(a, &.{}, &.{});
        _ = try self.dispatchFn.?(self.klippy.?, "pause_resume/resume", .{ .object = empty }, a);
    }

    /// Dispatch cancel command to Klippy.
    fn dispatchCancel(self: *JobQueueCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const empty = try std.json.ObjectMap.init(a, &.{}, &.{});
        _ = try self.dispatchFn.?(self.klippy.?, "pause_resume/cancel", .{ .object = empty }, a);
    }

    /// Persist current queue to store.
    fn saveToStore(self: *JobQueueCtx, arena: std.mem.Allocator) void {
        var arr: std.json.Array = .init(arena);
        const cur_time = nowSecs();
        for (self.jobs.items) |*j| {
            const v = j.asJson(arena, cur_time) catch continue;
            arr.append(v) catch {};
        }
        const state_obj = buildQueueObj(arena, .{ .array = arr }, self.queue_state) catch return;
        self.store.insertItem(arena, ns_queue, queue_key, state_obj) catch {};
    }

    /// Load persisted queue from store.
    fn loadFromStore(self: *JobQueueCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const val = (try self.store.getItem(a, ns_queue, queue_key)) orelse return;
        switch (val) {
            .object => |obj| {
                if (obj.get("queue_state")) |qs| {
                    if (qs == .string) {
                        // Map the persisted value to a static literal (no dupe →
                        // queue_state stays a non-owned literal everywhere, so
                        // the later literal assignments never leak a duped string).
                        for ([_][]const u8{ "ready", "paused", "loading", "standby" }) |k| {
                            if (std.mem.eql(u8, qs.string, k)) {
                                self.queue_state = k;
                                break;
                            }
                        }
                    }
                }
                if (obj.get("queued_jobs")) |qj| {
                    if (qj == .array) {
                        for (qj.array.items) |item| {
                            if (item != .object) continue;
                            const obj2 = item.object;
                            const filename = (obj2.get("filename") orelse continue).string;
                            const job_id = (obj2.get("job_id") orelse continue).string;
                            const time_added = switch (obj2.get("time_added") orelse .null) {
                                .float => |f| f,
                                .integer => |i| @as(f64, @floatFromInt(i)),
                                else => 0.0,
                            };
                            var j = QueuedJob{
                                .filename = try self.gpa.dupe(u8, filename),
                                .job_id = try self.gpa.dupe(u8, job_id),
                                .time_added = time_added,
                            };
                            errdefer j.deinit(self.gpa);
                            try self.jobs.append(self.gpa, j);
                        }
                    }
                }
            },
            else => {},
        }
    }
};

/// Background thread callback for transition_delay timer.  Sleeps in
/// 1-second intervals (or the remaining delay, whichever is shorter),
/// checking the cancel flag between each.  This ensures cancelDelayTimer
/// / deinit can join promptly (matching the proc_stat timer pattern).
/// Exits early when the cancel flag is set (pause/abort/deinit).
fn transitionDelayCallback(self: *JobQueueCtx) void {
    if (self.transition_delay <= 0) {
        self.delay_thread = null;
        return;
    }

    const io = self.io orelse {
        self.delay_thread = null;
        return;
    };
    var remaining: f64 = self.transition_delay;
    while (remaining > 0) : (remaining -= 1.0) {
        const chunk_ns: i64 = if (remaining >= 1.0)
            @as(i64, 1_000_000_000)
        else
            @intFromFloat(remaining * 1_000_000_000.0);
        io.sleep(std.Io.Duration.fromNanoseconds(@intCast(chunk_ns)), .awake) catch {};

        if (self.delay_cancel.load(.acquire)) {
            self.delay_thread = null;
            return;
        }
    }

    // Guard: if deinit nulled these fields, bail out.
    if (self.io == null or self.dispatchFn == null) {
        self.delay_thread = null;
        return;
    }

    _ = self.dispatchNextJob() catch {};
    self.delay_thread = null;
}

// ---------------------------------------------------------------------------
// Namespace constants
// ---------------------------------------------------------------------------

pub const ns_queue: [:0]const u8 = "job_queue";
pub const queue_key = "queue";

// ---------------------------------------------------------------------------
// QueuedJob
// ---------------------------------------------------------------------------

pub const QueuedJob = struct {
    filename: []u8,
    job_id: []u8,
    time_added: f64,

    fn deinit(self: *QueuedJob, alloc: std.mem.Allocator) void {
        alloc.free(self.filename);
        alloc.free(self.job_id);
    }

    fn asJson(self: *const QueuedJob, alloc: std.mem.Allocator, cur_time: f64) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "filename", .{ .string = self.filename });
        try obj.put(alloc, "job_id", .{ .string = self.job_id });
        try obj.put(alloc, "time_added", .{ .float = self.time_added });
        const time_in_queue = if (cur_time > self.time_added) cur_time - self.time_added else 0.0;
        try obj.put(alloc, "time_in_queue", .{ .float = time_in_queue });
        return .{ .object = obj };
    }
};

/// Get current time as float seconds (CLOCK_REALTIME).
fn nowSecs() f64 {
    return clock.wallSeconds();
}

/// Generate a unique job_id using monotonic time + address.
fn genJobId(alloc: std.mem.Allocator, seq: u32) ![]u8 {
    const ns = clock.monotonicNanos();
    // 16 hex ns + 4 hex seq → unique even within one nanosecond.
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{X:0>16}{X:0>4}", .{ ns, seq & 0xFFFF });
    return alloc.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) error{InvalidParams}!?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                .null => null,
                else => error.InvalidParams,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return (try getOptStr(params, field)) orelse error.InvalidParams;
}

fn getOptBool(params: std.json.Value, field: []const u8, default: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default,
            };
        },
        else => return default,
    }
}

fn getStrList(params: std.json.Value, field: []const u8) error{InvalidParams}![]const std.json.Value {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return &.{};
            return switch (v) {
                .array => |a| a.items,
                else => error.InvalidParams,
            };
        },
        else => return &.{},
    }
}

fn buildQueueObj(alloc: std.mem.Allocator, jobs_arr: std.json.Value, state: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "queued_jobs", jobs_arr);
    try obj.put(alloc, "queue_state", .{ .string = state });
    return .{ .object = obj };
}

/// Build current queue response object (queued_jobs array + queue_state).
fn buildResponse(c: *JobQueueCtx, alloc: std.mem.Allocator) !std.json.Value {
    const cur_time = nowSecs();
    var arr: std.json.Array = .init(alloc);
    for (c.jobs.items) |*j| {
        const v = try j.asJson(alloc, cur_time);
        try arr.append(v);
    }
    return buildQueueObj(alloc, .{ .array = arr }, c.queue_state);
}

/// Emit notify_job_queue_changed with the given action.
fn emitQueueChanged(c: *JobQueueCtx, alloc: std.mem.Allocator, action: []const u8, include_queue: bool) void {
    var inner: std.json.ObjectMap = .empty;
    inner.put(alloc, "action", .{ .string = action }) catch return;

    if (include_queue) {
        const cur_time = nowSecs();
        var arr: std.json.Array = .init(alloc);
        for (c.jobs.items) |*j| {
            const v = j.asJson(alloc, cur_time) catch continue;
            arr.append(v) catch {};
        }
        inner.put(alloc, "updated_queue", .{ .array = arr }) catch return;
    } else {
        inner.put(alloc, "updated_queue", .null) catch return;
    }
    inner.put(alloc, "queue_state", .{ .string = c.queue_state }) catch return;

    // Build params array (Moonraker wraps event data in a 1-element array).
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;

    // Emit via emitLocked: all callers are mutating handlers reached under the
    // held Core lock (Core.run), so plain emit would deadlock. No-op without io.
    const io = c.io orelse return;
    c.bus.emitLocked(io, notify.names.job_queue_changed, .{ .array = params }) catch {};
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/job_queue/status
pub fn handleStatus(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    return buildResponse(c, alloc);
}

/// POST /server/job_queue/job — enqueue filenames
pub fn handlePostJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const files = try getStrList(params, "filenames");
    const reset = getOptBool(params, "reset", false);

    if (reset) {
        for (c.jobs.items) |*j| j.deinit(c.gpa);
        c.jobs.clearRetainingCapacity();
    }

    for (files) |fv| {
        const filename = switch (fv) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        // Reject files that don't exist under the gcodes root (Moonraker
        // queue_job → check_file_exists). No checker wired → accept.
        if (!c.fileExists(filename)) return error.InvalidParams;
        const job_id = try genJobId(c.gpa, c.job_seq.fetchAdd(1, .monotonic));
        errdefer c.gpa.free(job_id);
        const fname_owned = try c.gpa.dupe(u8, filename);
        errdefer c.gpa.free(fname_owned);
        const time_added = nowSecs();
        try c.jobs.append(c.gpa, .{
            .filename = fname_owned,
            .job_id = job_id,
            .time_added = time_added,
        });
    }

    // Persist
    c.saveToStore(alloc);
    emitQueueChanged(c, alloc, "jobs_added", true);
    return buildResponse(c, alloc);
}

/// DELETE /server/job_queue/job — remove job(s) by job_ids or all=true
pub fn handleDeleteJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const all = getOptBool(params, "all", false);

    if (all) {
        for (c.jobs.items) |*j| j.deinit(c.gpa);
        c.jobs.clearRetainingCapacity();
        c.saveToStore(alloc);
        emitQueueChanged(c, alloc, "jobs_removed", true);
    } else {
        const job_ids = try getStrList(params, "job_ids");
        if (job_ids.len == 0) {
            // Nothing deleted — return current state without notification
            return buildResponse(c, alloc);
        }
        var i: usize = 0;
        while (i < c.jobs.items.len) {
            const j = &c.jobs.items[i];
            var found = false;
            for (job_ids) |idv| {
                const id = switch (idv) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, j.job_id, id)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                c.jobs.items[i].deinit(c.gpa);
                _ = c.jobs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        c.saveToStore(alloc);
        emitQueueChanged(c, alloc, "jobs_removed", true);
    }

    return buildResponse(c, alloc);
}

/// Multi-verb dispatch for /server/job_queue/job (POST=enqueue, DELETE=remove).
pub fn handleJobDispatch(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // The transport injects "_method" (HTTP verb or JSON-RPC method name).
    // POST is explicit; absent or anything else defaults to DELETE.
    const is_post = switch (params) {
        .object => |o| switch (o.get("_method") orelse std.json.Value{ .null = {} }) {
            .string => |s| std.ascii.eqlIgnoreCase(s, "POST"),
            else => false,
        },
        else => false,
    };
    if (is_post) return handlePostJob(ctx, params, alloc);
    return handleDeleteJob(ctx, params, alloc);
}

/// POST /server/job_queue/pause
pub fn handlePause(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    c.queue_state = "paused";
    c.cancelDelayTimer();
    // Dispatch pause gcode to Klippy when connected.
    if (c.canDispatch()) {
        c.dispatchPause() catch {};
    }
    c.saveToStore(alloc);
    emitQueueChanged(c, alloc, "state_changed", false);
    return buildResponse(c, alloc);
}

/// POST /server/job_queue/start
pub fn handleStart(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    if (c.jobs.items.len > 0) {
        c.queue_state = "ready";
        // Dispatch start gcode for the front job to Klippy (respects
        // transition_delay when configured). Skip while a print is active —
        // Moonraker defers loading until the current job finishes
        // (_check_can_print); the queue stays "ready" and loads later.
        if (c.canDispatch() and !c.isPrinting()) {
            c.scheduleNextJobDispatch() catch {};
        }
    } else {
        c.queue_state = "paused";
    }
    c.saveToStore(alloc);
    emitQueueChanged(c, alloc, "state_changed", false);
    return buildResponse(c, alloc);
}

/// POST /server/job_queue/jump — move job_id to front of queue
pub fn handleJump(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const job_id = try getStr(params, "job_id");

    // Find and remove the job
    var found_idx: ?usize = null;
    for (c.jobs.items, 0..) |*j, i| {
        if (std.mem.eql(u8, j.job_id, job_id)) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse return error.NotFound;

    if (idx != 0) {
        // Move to front
        const job = c.jobs.orderedRemove(idx);
        c.jobs.insert(c.gpa, 0, job) catch return error.OutOfMemory;
    }

    c.saveToStore(alloc);
    return buildResponse(c, alloc);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// Endpoint mapping (from job_queue.py):
//   /server/job_queue/status   GET       → "server.job_queue.status"
//   /server/job_queue/pause    POST      → "server.job_queue.pause"
//   /server/job_queue/start    POST      → "server.job_queue.start"
//   /server/job_queue/jump     POST      → "server.job_queue.jump"
//   /server/job_queue/job      POST+DELETE → "server.job_queue.post_job"
//                                            "server.job_queue.delete_job"

pub fn registerJobQueue(reg: *Registry, ctx: *JobQueueCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/job_queue/status", .methods = &.{.GET} },
        c,
        handleStatus,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/job_queue/pause", .methods = &.{.POST} },
        c,
        handlePause,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/job_queue/start", .methods = &.{.POST} },
        c,
        handleStart,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/job_queue/jump", .methods = &.{.POST} },
        c,
        handleJump,
    );
    // POST + DELETE → multi-verb → "server.job_queue.post_job" / "server.job_queue.delete_job"
    try reg.registerEndpoint(
        .{ .path = "/server/job_queue/job", .methods = &.{ .POST, .DELETE } },
        c,
        handleJobDispatch,
    );

    // Remote-only methods (no HTTP route, JSON-RPC only).
    // Moonraker: self.server.register_remote_method("pause_job_queue", ...)
    //           self.server.register_remote_method("start_job_queue", ...)
    // Names are static literals → register directly (dispatcher keys must be
    // stable-lifetime; .rodata literals are, no dupe/name_pool needed).
    try reg.dispatcher.register("pause_job_queue", c, handlePause);
    try reg.dispatcher.register("start_job_queue", c, handleStart);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// ---- In-memory store for tests ----

const MemNamespace = struct {
    name: []const u8,
    data: std.StringHashMap(std.json.Value),

    fn init(alloc: std.mem.Allocator, name: []const u8) MemNamespace {
        return .{ .name = name, .data = std.StringHashMap(std.json.Value).init(alloc) };
    }

    fn deinit(self: *MemNamespace) void {
        self.data.deinit();
    }
};

const MemStore = struct {
    alloc: std.mem.Allocator,
    namespaces: std.ArrayList(MemNamespace),

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc, .namespaces = .empty };
    }

    fn deinit(self: *MemStore) void {
        for (self.namespaces.items) |*n| n.deinit();
        self.namespaces.deinit(self.alloc);
    }

    fn getNs(self: *MemStore, name: []const u8) ?*MemNamespace {
        for (self.namespaces.items) |*n| if (std.mem.eql(u8, n.name, name)) return n;
        return null;
    }

    fn getOrCreate(self: *MemStore, name: []const u8) !*MemNamespace {
        if (self.getNs(name)) |n| return n;
        try self.namespaces.append(self.alloc, .init(self.alloc, name));
        return &self.namespaces.items[self.namespaces.items.len - 1];
    }

    fn vtGetItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!?std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return null;
        return n.data.get(key);
    }

    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getOrCreate(ns) catch return ds.Error.OutOfMemory;
        n.data.put(key, value) catch return ds.Error.OutOfMemory;
    }

    fn vtUpdateItem(ctx: *anyopaque, alloc: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        return vtInsertItem(ctx, alloc, ns, key, value);
    }

    fn vtDeleteItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.KeyNotFound;
        const v = n.data.get(key) orelse return ds.Error.KeyNotFound;
        _ = n.data.remove(key);
        return v;
    }

    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList([]const u8) = .empty;
        for (self.namespaces.items) |*n| out.append(arena, n.name) catch return ds.Error.OutOfMemory;
        return out.toOwnedSlice(arena) catch return ds.Error.OutOfMemory;
    }

    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return .{ .object = .empty };
        var obj: std.json.ObjectMap = .empty;
        var it = n.data.iterator();
        while (it.next()) |e| obj.put(arena, e.key_ptr.*, e.value_ptr.*) catch return ds.Error.OutOfMemory;
        return .{ .object = obj };
    }

    const vtable: ds.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };

    fn dataStore(self: *MemStore) DataStore {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const NullCore = @import("../server/core.zig").Core;
const NullConns = @import("../server/connections.zig").Connections;

fn mkCtx(alloc: std.mem.Allocator, mem: *MemStore) !JobQueueCtx {
    var core = NullCore.init();
    _ = &core;
    // Use a stable bus pointer via arena — unit tests don't need real emission
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(alloc, &core);
    defer conns.deinit(io);
    // NOTE: bus and conns are stack-allocated; tests must not call emit.
    // We build a minimal ctx that does not live-emit.
    var bus = NotifyBus.init(&core, &conns);
    return JobQueueCtx.init(alloc, mem.dataStore(), &bus);
}

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleStatus: empty queue returns paused state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const result = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    try testing.expectEqual(@as(usize, 0), result.object.get("queued_jobs").?.array.items.len);
}

test "handlePostJob: enqueues filenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"filenames\":[\"a.gcode\",\"b.gcode\"]}");
    const result = try handlePostJob(@ptrCast(&ctx), p, a);
    const jobs = result.object.get("queued_jobs").?.array;
    try testing.expectEqual(@as(usize, 2), jobs.items.len);
    try testing.expectEqualStrings("a.gcode", jobs.items[0].object.get("filename").?.string);
    try testing.expectEqualStrings("b.gcode", jobs.items[1].object.get("filename").?.string);
}

test "handlePostJob: reset=true clears existing queue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\"]}");
    _ = try handlePostJob(@ptrCast(&ctx), p1, a);

    const p2 = try mkParams(a, "{\"filenames\":[\"c.gcode\"],\"reset\":true}");
    const result = try handlePostJob(@ptrCast(&ctx), p2, a);
    const jobs = result.object.get("queued_jobs").?.array;
    try testing.expectEqual(@as(usize, 1), jobs.items.len);
    try testing.expectEqualStrings("c.gcode", jobs.items[0].object.get("filename").?.string);
}

test "handleDeleteJob: all=true empties queue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\",\"b.gcode\"]}");
    _ = try handlePostJob(@ptrCast(&ctx), p1, a);

    const p2 = try mkParams(a, "{\"all\":true}");
    const result = try handleDeleteJob(@ptrCast(&ctx), p2, a);
    try testing.expectEqual(@as(usize, 0), result.object.get("queued_jobs").?.array.items.len);
}

test "handleDeleteJob: by job_ids removes specific jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\",\"b.gcode\"]}");
    const enq = try handlePostJob(@ptrCast(&ctx), p1, a);
    const jobs_after_enq = enq.object.get("queued_jobs").?.array;
    const first_id = jobs_after_enq.items[0].object.get("job_id").?.string;

    // Delete first job by id
    var del_buf: [128]u8 = undefined;
    const del_str = try std.fmt.bufPrint(&del_buf, "{{\"job_ids\":[\"{s}\"]}}", .{first_id});
    const p2 = try mkParams(a, del_str);
    const result = try handleDeleteJob(@ptrCast(&ctx), p2, a);
    try testing.expectEqual(@as(usize, 1), result.object.get("queued_jobs").?.array.items.len);
    try testing.expectEqualStrings("b.gcode", result.object.get("queued_jobs").?.array.items[0].object.get("filename").?.string);
}

test "handlePause: sets queue_state to paused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    ctx.queue_state = "ready";
    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
}

test "handleStart: transitions to ready when jobs queued" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\"]}");
    _ = try handlePostJob(@ptrCast(&ctx), p1, a);

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("ready", result.object.get("queue_state").?.string);
}

test "handleStart: empty queue stays paused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
}

test "handleJump: moves job to front of queue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\",\"b.gcode\",\"c.gcode\"]}");
    const enq = try handlePostJob(@ptrCast(&ctx), p1, a);
    const jobs_init = enq.object.get("queued_jobs").?.array;
    const last_id = jobs_init.items[2].object.get("job_id").?.string;

    var jump_buf: [128]u8 = undefined;
    const jump_str = try std.fmt.bufPrint(&jump_buf, "{{\"job_id\":\"{s}\"}}", .{last_id});
    const p2 = try mkParams(a, jump_str);
    const result = try handleJump(@ptrCast(&ctx), p2, a);
    const jobs_after = result.object.get("queued_jobs").?.array;
    try testing.expectEqualStrings("c.gcode", jobs_after.items[0].object.get("filename").?.string);
}

test "handleJump: unknown job_id → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"job_id\":\"XXXXXXXXXXXXXXXX\"}");
    try testing.expectError(error.NotFound, handleJump(@ptrCast(&ctx), p, a));
}

test "registerJobQueue: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(alloc, mem.dataStore(), &bus);
    defer ctx.deinit();

    try registerJobQueue(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/job_queue/status") != null);
    try testing.expect(reg.lookup(.POST, "/server/job_queue/pause") != null);
    try testing.expect(reg.lookup(.POST, "/server/job_queue/start") != null);
    try testing.expect(reg.lookup(.POST, "/server/job_queue/jump") != null);
    try testing.expect(reg.lookup(.POST, "/server/job_queue/job") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/job_queue/job") != null);

    try testing.expect(d.methods.get("server.job_queue.status") != null);
    try testing.expect(d.methods.get("server.job_queue.pause") != null);
    try testing.expect(d.methods.get("server.job_queue.start") != null);
    try testing.expect(d.methods.get("server.job_queue.jump") != null);
    try testing.expect(d.methods.get("server.job_queue.post_job") != null);
    try testing.expect(d.methods.get("server.job_queue.delete_job") != null);
    // Remote-only methods (JSON-RPC, no HTTP route).
    try testing.expect(d.methods.get("pause_job_queue") != null);
    try testing.expect(d.methods.get("start_job_queue") != null);
}

// ---------------------------------------------------------------------------
// Transition delay timer tests
// ---------------------------------------------------------------------------

test "setTransitionConfig: stores delay and gcode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    ctx.setTransitionConfig(null, 2.5);
    try testing.expectEqual(2.5, ctx.transition_delay);
    try testing.expectEqual(null, ctx.transition_gcode);

    ctx.setTransitionConfig("G28", 0.1);
    try testing.expectEqual(0.1, ctx.transition_delay);
    try testing.expectEqualStrings("G28", ctx.transition_gcode.?);
}

test "scheduleNextJobDispatch: zero-delay dispatches immediately via capture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setTransitionConfig(null, 0.0);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    try ctx.scheduleNextJobDispatch();
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

var jq_file_exists_flag: bool = true;
fn jqFileCheckStub(_: *anyopaque, _: []const u8) bool {
    return jq_file_exists_flag;
}
var jq_printing_flag: bool = false;
fn jqPrintingStub(_: *anyopaque) bool {
    return jq_printing_flag;
}
const FailDispatch = struct {
    fn handler(_: *anyopaque, _: []const u8, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
        return error.KlippyDisconnected;
    }
};

test "handlePostJob: rejects nonexistent gcode file (G5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    var dummy: u8 = 0;
    ctx.file_check = jqFileCheckStub;
    ctx.file_check_ctx = &dummy;

    const params = (try std.json.parseFromSlice(std.json.Value, a, "{\"filenames\":[\"missing.gcode\"]}", .{})).value;
    jq_file_exists_flag = false;
    try testing.expectError(error.InvalidParams, handlePostJob(@ptrCast(&ctx), params, a));
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);

    jq_file_exists_flag = true;
    _ = try handlePostJob(@ptrCast(&ctx), params, a);
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
}

test "dispatchNextJob: pauses the queue when start-gcode dispatch fails (G6)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    var dummy: u8 = 0;
    ctx.setKlippyDispatch(&dummy, &FailDispatch.handler);

    _ = try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 1.0,
    });
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    try ctx.dispatchNextJob(); // start gcode fails → must pause, not error out
    try testing.expectEqualStrings("paused", ctx.queue_state);
}

test "handleStart: does not dispatch while a print is active (G5 can-print)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    var dummy: u8 = 0;
    ctx.printing_check = jqPrintingStub;
    ctx.printing_ctx = &dummy;

    _ = try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 1.0,
    });
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    jq_printing_flag = true;
    _ = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expect(!cap.called); // deferred while printing
    try testing.expectEqualStrings("ready", ctx.queue_state);

    jq_printing_flag = false; // reset for other tests
}

test "fuzz handlePostJob with file_check: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const tio = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(tio);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();
            var dummy: u8 = 0;
            ctx.file_check = jqFileCheckStub;
            ctx.file_check_ctx = &dummy;
            jq_file_exists_flag = smith.valueWithHash(bool, 0);
            var fn_buf: [16]u8 = undefined;
            smith.bytesWithHash(&fn_buf, 1);
            var params_map: std.json.ObjectMap = .empty;
            var arr: std.json.Array = .init(a);
            arr.append(.{ .string = &fn_buf }) catch return;
            params_map.put(a, "filenames", .{ .array = arr }) catch return;
            _ = handlePostJob(@ptrCast(&ctx), .{ .object = params_map }, a) catch {};
            jq_file_exists_flag = true;
        }
    }.run, .{});
}

test "cancelDelayTimer: safe no-op when no timer active" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Safe to call when no timer was ever started.
    ctx.cancelDelayTimer();
    try testing.expectEqual(null, ctx.delay_thread);

    // Safe to call multiple times.
    ctx.cancelDelayTimer();
    try testing.expectEqual(null, ctx.delay_thread);
}

test "transition_delay: handleStart respects delay config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    // delay=0 → immediate dispatch
    ctx.setTransitionConfig(null, 0.0);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("ready", result.object.get("queue_state").?.string);
    // Immediate dispatch since delay == 0
    try testing.expect(cap.called);
}

test "transition_delay: handlePause cancels running delay timer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    // Small delay so we can cancel mid-flight.
    ctx.setTransitionConfig(null, 0.05);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    // Start with delay → spawns timer thread.
    _ = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("loading", ctx.queue_state);

    // Pause immediately — cancel the timer.
    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
}

test "transition_delay: timer completes and dispatches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setTransitionConfig(null, 0.01);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    // Spawn the delay timer thread.
    try ctx.scheduleNextJobDispatch();

    // Wait for the timer thread to complete.
    if (ctx.delay_thread) |th| {
        th.join();
        ctx.delay_thread = null;
    }

    // The dispatch should have fired after the timer expired.
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "deinit: cancels delay timer gracefully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);

    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setTransitionConfig(null, 0.2);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    // Start timer then immediately deinit — must not hang or crash.
    ctx.scheduleNextJobDispatch() catch {};
    ctx.deinit();
}

// ---------------------------------------------------------------------------
// Dispatch tests (Klippy gcode bridge)
// ---------------------------------------------------------------------------

/// Test dispatcher that captures dispatch calls for verification.
const TestDispatchCapture = struct {
    called: bool = false,
    call_count: usize = 0,
    method: []const u8 = "",
    has_params: bool = false,

    fn handler(ctx: *anyopaque, method: []const u8, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
        const cap: *TestDispatchCapture = @ptrCast(@alignCast(ctx));
        cap.called = true;
        cap.call_count += 1;
        cap.method = method;
        cap.has_params = params != .null;
        return .null;
    }
};

test "setKlippyDispatch: canDispatch reflects wiring" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    try testing.expect(!ctx.canDispatch());

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    try testing.expect(ctx.canDispatch());
}

test "dispatchNextJob: builds correct gcode and calls dispatcher" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Add a job to the queue.
    const fname = try testing.allocator.dupe(u8, "test.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB001");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 100.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchNextJob();
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
    try testing.expect(cap.has_params);
}

test "dispatchPause: calls pause_resume/pause" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchPause();
    try testing.expect(cap.called);
    try testing.expectEqualStrings("pause_resume/pause", cap.method);
}

test "dispatchResume: calls pause_resume/resume" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchResume();
    try testing.expect(cap.called);
    try testing.expectEqualStrings("pause_resume/resume", cap.method);
}

test "dispatchCancel: calls pause_resume/cancel" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchCancel();
    try testing.expect(cap.called);
    try testing.expectEqualStrings("pause_resume/cancel", cap.method);
}

test "handleStart: dispatches next job when wired and queued" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "printme.gcode"),
        .job_id = try a.dupe(u8, "JOB002"),
        .time_added = 200.0,
    });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("ready", result.object.get("queue_state").?.string);
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "handlePause: dispatches pause when wired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    try testing.expect(cap.called);
    try testing.expectEqualStrings("pause_resume/pause", cap.method);
}

test "handleStart: does not dispatch when not wired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "printme.gcode"),
        .job_id = try a.dupe(u8, "JOB003"),
        .time_added = 300.0,
    });

    // No dispatch wired — handleStart should still work, just not dispatch.
    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("ready", result.object.get("queue_state").?.string);
}

test "setTransitionConfig: stores gcode and delay" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    try testing.expect(ctx.transition_gcode == null);
    try testing.expect(ctx.transition_delay == 0.0);

    ctx.setTransitionConfig("G28", 2.5);
    try testing.expectEqualStrings("G28", ctx.transition_gcode.?);
    try testing.expect(ctx.transition_delay == 2.5);

    ctx.setTransitionConfig(null, 0.0);
    try testing.expect(ctx.transition_gcode == null);
    try testing.expect(ctx.transition_delay == 0.0);
}

test "dispatchNextJob: injects transition gcode when configured" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB100");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 400.0 });

    ctx.setTransitionConfig("G28", 0.0);

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchNextJob();

    try testing.expect(cap.called);
    // Two dispatches: transition gcode, then print file.
    try testing.expectEqual(@as(usize, 2), cap.call_count);
    try testing.expectEqualStrings("gcode/script", cap.method); // last call = print file
    try testing.expectEqualStrings("loading", ctx.queue_state);
}

test "dispatchNextJob: no transition gcode when not configured" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB101");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 500.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchNextJob();

    try testing.expect(cap.called);
    try testing.expectEqual(@as(usize, 1), cap.call_count);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "dispatchNextJob: transition with empty gcode string is no-op" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB102");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 600.0 });

    ctx.setTransitionConfig("", 0.0);

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    try ctx.dispatchNextJob();

    try testing.expect(cap.called);
    try testing.expectEqual(@as(usize, 1), cap.call_count); // empty gcode skipped
}

test "onJobStateChanged complete: auto-advances and dispatches next" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Queue two jobs.
    const fname1 = try testing.allocator.dupe(u8, "job1.gcode");
    const jid1 = try testing.allocator.dupe(u8, "JOB010");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname1, .job_id = jid1, .time_added = 10.0 });

    const fname2 = try testing.allocator.dupe(u8, "job2.gcode");
    const jid2 = try testing.allocator.dupe(u8, "JOB011");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname2, .job_id = jid2, .time_added = 20.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    // Simulate the current job completing.
    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);

    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len); // front job removed
    try testing.expectEqualStrings("ready", ctx.queue_state);
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "onJobStateChanged complete: last job sets paused, no dispatch" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "onlyjob.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB020");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 30.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);

    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
    try testing.expectEqualStrings("paused", ctx.queue_state);
    try testing.expect(!cap.called); // No dispatch, queue is empty.
}

/// Enum mirroring JobEvent for test dispatch testing (avoid cross-component import).
const JobEvent = enum {
    standby,
    started,
    paused,
    resumed,
    complete,
    @"error",
    cancelled,
};

// ---------------------------------------------------------------------------
// Fuzz tests
// ---------------------------------------------------------------------------

test "fuzz dispatchNextJob/setKlippyDispatch/onJobStateChanged: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var cap = TestDispatchCapture{};
            ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            // Optionally add a job.
            if (buf[0] & 1 == 0) {
                const fname = a.dupe(u8, "fuzz.gcode") catch return;
                const jid = a.dupe(u8, "FUZZ01") catch return;
                ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 100.0 }) catch return;
            }

            // Exercise dispatch.
            _ = ctx.dispatchNextJob() catch {};

            // Exercise state transitions.
            const events = [_]JobEvent{ .standby, .started, .paused, .resumed, .complete, .@"error", .cancelled };
            ctx.onJobStateChanged(events[buf[1] % events.len], .empty, .empty);
        }
    }.run, .{});
}

test "fuzz handlePostJob: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"filenames\":[\"a.gcode\"]}",
                "{\"filenames\":[\"a.gcode\"],\"reset\":true}",
                "null",
                "{\"filenames\":[]}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handlePostJob(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDeleteJob: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"all\":true}",
                "{\"job_ids\":[\"AAAA\"]}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleDeleteJob(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleJump: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"job_id\":\"AAAA\"}",
                "{\"job_id\":\"0000000000000001\"}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleJump(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleStatus: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            // Optionally populate the queue.
            if (buf[0] & 1 == 0) {
                ctx.jobs.append(ctx.gpa, .{ .filename = a.dupe(u8, "fuzz.gcode") catch return, .job_id = a.dupe(u8, "FUZZ01") catch return, .time_added = 100.0 }) catch return;
            }
            _ = handleStatus(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handlePause: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            // capture dispatch calls
            var cap = TestDispatchCapture{};
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();
            ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            if (buf[0] & 1 == 0) {
                ctx.jobs.append(ctx.gpa, .{ .filename = a.dupe(u8, "fuzz.gcode") catch return, .job_id = a.dupe(u8, "FUZZ01") catch return, .time_added = 100.0 }) catch return;
            }
            _ = handlePause(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleStart: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var cap = TestDispatchCapture{};
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();
            ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            if (buf[0] & 1 == 0) {
                ctx.jobs.append(ctx.gpa, .{ .filename = a.dupe(u8, "fuzz.gcode") catch return, .job_id = a.dupe(u8, "FUZZ01") catch return, .time_added = 100.0 }) catch return;
            }
            _ = handleStart(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleJobDispatch: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = JobQueueCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"method\":\"status\"}",
                "{\"method\":\"start\"}",
                "{\"method\":\"pause\"}",
                "{\"method\":\"delete_job\"}",
                "{\"method\":\"jump\"}",
                "{\"method\":\"post_job\"}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleJobDispatch(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "genJobId: same-nanosecond calls differ by seq suffix" {
    const a = std.testing.allocator;
    const id0 = try genJobId(a, 0);
    defer a.free(id0);
    const id1 = try genJobId(a, 1);
    defer a.free(id1);
    try std.testing.expectEqual(@as(usize, 20), id0.len);
    try std.testing.expect(!std.mem.eql(u8, id0, id1));
}

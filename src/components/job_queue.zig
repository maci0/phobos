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
//! Queued jobs are persisted in the DataStore under namespace "job_queue" with
//! key "queue" (Moonraker keeps them in memory only). The queue always starts
//! "paused", like Moonraker.
//!
//! States follow job_queue.py: start or an automatic transition after a
//! completed print moves "ready"/"paused" to "loading"; the dispatch worker
//! runs the transition gcode, enters "starting", sends SDCARD_PRINT_FILE,
//! removes the loaded job, emits "job_loaded" and settles on "ready"
//! (more jobs, automatic transition) or "paused". Any failure pauses the
//! queue. `load_on_startup` loads a queued job one second after Klippy is ready;
//! shutdown pauses the queue without changing an explicit pause request.
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
const webreq = @import("../json/params.zig");
const sleep = @import("../util/sleep.zig");
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
const DispatchReason = enum { immediate, transition, startup };
const startup_delay: std.Io.Duration = .fromSeconds(1);

pub const JobQueueCtx = struct {
    clock_io: std.Io,
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
    /// Guards `jobs`, `queue_state` and `pause_requested`. They are mutated by
    /// Core-locked handlers and job-state events AND, off-Core, by the dispatch
    /// worker thread. Held only around the structural ops; NEVER across a
    /// blocking dispatchFn/scheduleNextJobDispatch/cancelDelayTimer call (the
    /// joined worker would otherwise wait on this lock → deadlock).
    /// Locked through constructor I/O even before notification I/O is set.
    mutex: std.Io.Mutex = .init,
    /// Serializes snapshots with their writes. Callers release `mutex` first.
    save_mutex: std.Io.Mutex = .init,
    /// Opaque pointer to KlippyCtx for print dispatch. Set by app.zig via
    /// setKlippyDispatch (avoids circular @import with klippy_connection.zig).
    klippy: ?*anyopaque = null,
    /// Dispatch function that calls into KlippyCtx to send gcode scripts.
    dispatchFn: ?DispatchFn = null,
    /// Gcode script injected between queued print jobs (config: job_transition_gcode).
    transition_gcode: ?[]const u8 = null,
    /// Delay in seconds between queued jobs (config: job_transition_delay).
    transition_delay: f64 = 0.0,
    /// When false (Moonraker default), the queue does NOT auto-advance to the
    /// next job after one completes (config: automatic_transition).
    automatic: bool = false,
    load_on_startup: bool = false,
    /// Set by pause, cleared by start: jobs queued during a print do not make
    /// a paused queue "ready" (job_queue.py `pause_requested`).
    pause_requested: bool = false,
    /// Background thread for transition_delay timer (nil when delay is zero or
    /// no timer is active). Pattern follows proc_stat in machine.zig.
    delay_thread: ?std.Io.Future(void) = null,
    /// Atomic flag that cancels any running transition_delay timer.
    delay_cancel: std.Io.Event = .unset,
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

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io, store: DataStore, bus: *NotifyBus) !JobQueueCtx {
        var ctx = JobQueueCtx{
            .clock_io = clock_io,
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
            .delay_cancel = .unset,
        };
        errdefer ctx.deinit();
        try ctx.loadFromStore();
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

    /// Set `[job_queue] automatic_transition` (auto-advance to the next job on
    /// completion).
    pub fn setAutomaticTransition(self: *JobQueueCtx, automatic: bool) void {
        self.automatic = automatic;
    }

    pub fn onKlippyReady(self: *JobQueueCtx) void {
        {
            self.lockJobs();
            defer self.unlockJobs();
            if (!self.load_on_startup or self.jobs.items.len == 0 or !self.canDispatch()) return;
            if (!std.mem.eql(u8, self.queue_state, "ready") and !std.mem.eql(u8, self.queue_state, "paused")) return;
        }
        self.setQueueState("loading");
        _ = self.scheduleNextJobDispatch(.startup);
    }

    pub fn onKlippyShutdown(self: *JobQueueCtx) void {
        self.setQueueState("paused");
        self.cancelDelayTimer();
    }

    /// Returns true when Klippy is wired and connected.
    pub fn canDispatch(self: *const JobQueueCtx) bool {
        return self.klippy != null and self.dispatchFn != null;
    }

    pub fn deinit(self: *JobQueueCtx) void {
        // Stop and JOIN the dispatch worker BEFORE nulling its inputs. A worker
        // already inside dispatchNextJob reads self.klippy/dispatchFn; nulling
        // those before the join would crash it with use-of-null. The cancel flag
        // breaks any in-progress transition-delay sleep so the join is prompt.
        self.delay_cancel.set(self.clock_io);
        if (self.delay_thread) |*th| {
            th.cancel(self.clock_io);
            self.delay_thread = null;
        }
        self.klippy = null;
        self.dispatchFn = null;
        self.io = null;
        for (self.jobs.items) |*j| j.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
        self.jobs = .empty;
    }

    /// Cancel a running transition_delay timer (no-op when no timer is active).
    pub fn cancelDelayTimer(self: *JobQueueCtx) void {
        self.delay_cancel.set(self.clock_io);
        if (self.delay_thread) |*th| {
            th.cancel(self.clock_io);
            self.delay_thread = null;
        }
    }

    /// Called by JobStateCtx (under Core) when a job state transition is
    /// detected (job_queue.py `_on_job_state_changed`). A completed print loads
    /// the next job only with automatic transition and a "ready" queue; an
    /// aborted print pauses a non-empty queue.
    pub fn onJobStateChanged(self: *JobQueueCtx, event: anytype, _: std.json.ObjectMap, _: std.json.ObjectMap) void {
        switch (event) {
            .complete => {
                if (!self.automatic) return;
                {
                    self.lockJobs();
                    defer self.unlockJobs();
                    if (!std.mem.eql(u8, self.queue_state, "ready") or self.jobs.items.len == 0) return;
                }
                self.setQueueState("loading");
                // Outside the lock: scheduling joins the prior worker thread.
                _ = self.scheduleNextJobDispatch(.transition);
            },
            .@"error", .cancelled => {
                const has_jobs = blk: {
                    self.lockJobs();
                    defer self.unlockJobs();
                    break :blk self.jobs.items.len > 0;
                };
                if (has_jobs) {
                    self.setQueueState("paused");
                    self.cancelDelayTimer(); // joins worker — never under the lock
                }
            },
            else => {},
        }
    }

    /// Load the front job on a dedicated worker thread. After a completed
    /// print (`after_job`) the worker first waits `transition_delay` and runs
    /// the transition gcode; a queue start loads at once. Dispatch is ALWAYS
    /// async: it makes a blocking Klippy request, and the callers (handlers and
    /// job-state events under Core) may not block on it. Cancelled by
    /// cancelDelayTimer (pause/abort/deinit). The caller sets "loading" first;
    /// a failure to start the worker pauses the queue and returns false.
    fn scheduleNextJobDispatch(self: *JobQueueCtx, reason: DispatchReason) bool {
        self.cancelDelayTimer(); // join + clear any previous timer
        self.delay_cancel.reset();
        self.delay_thread = self.clock_io.concurrent(transitionDelayCallback, .{ self, reason }) catch |err| {
            self.delay_thread = null;
            std.debug.print("phobos: warning: job queue paused, dispatch worker not started: {}\n", .{err});
            self.setQueueState("paused");
            return false;
        };
        return true;
    }

    /// Load the front job (job_queue.py `_pop_job`). A failure pauses the queue.
    fn dispatchNextJob(self: *JobQueueCtx, need_transition: bool) void {
        // The worker dereferences dispatchFn/klippy; if a concurrent teardown
        // nulled them, bail rather than unwrap null.
        if (self.dispatchFn == null or self.klippy == null) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.loadNextJob(a, need_transition) catch |err| {
            std.debug.print("phobos: warning: job queue paused, next job not loaded: {}\n", .{err});
            self.setQueueState("paused");
        };
    }

    fn loadNextJob(self: *JobQueueCtx, a: std.mem.Allocator, need_transition: bool) !void {
        // Snapshot the front job under the lock; the lock is released before
        // the blocking Klippy requests below.
        const front: QueuedJob = blk: {
            self.lockJobs();
            defer self.unlockJobs();
            if (std.mem.eql(u8, self.queue_state, "paused")) return;
            if (self.jobs.items.len == 0) return error.QueueEmpty;
            if (!std.mem.eql(u8, self.queue_state, "loading")) return error.QueueStateChanged;
            if (self.isPrinting()) return error.PrinterBusy;
            const j = self.jobs.items[0];
            break :blk .{ .filename = try a.dupe(u8, j.filename), .job_id = try a.dupe(u8, j.job_id), .time_added = j.time_added };
        };

        const transition = self.transition_gcode orelse "";
        if (need_transition and transition.len > 0) {
            try self.runScript(a, transition);
            // The transition gcode may have paused the queue.
            if (!self.queueStateEql("loading")) return error.QueueStateChanged;
        }

        self.setQueueState("starting");
        // klippy_apis.py start_print: drop a leading '/', escape double quotes.
        const name = if (std.mem.startsWith(u8, front.filename, "/")) front.filename[1..] else front.filename;
        const escaped = try std.mem.replaceOwned(u8, a, name, "\"", "\\\"");
        try self.runScript(a, try std.fmt.allocPrint(a, "SDCARD_PRINT_FILE FILENAME=\"{s}\"", .{escaped}));

        {
            self.lockJobs();
            defer self.unlockJobs();
            // Remove the loaded job by id: handlers may have reordered or
            // deleted entries during the request.
            for (self.jobs.items, 0..) |*j, i| {
                if (!std.mem.eql(u8, j.job_id, front.job_id)) continue;
                j.deinit(self.gpa);
                _ = self.jobs.orderedRemove(i);
                break;
            }
            if (std.mem.eql(u8, self.queue_state, "starting")) {
                self.queue_state = if (self.jobs.items.len > 0 and self.automatic) "ready" else "paused";
            }
        }
        self.saveToStore(a);
        emitQueueChanged(self, a, "job_loaded", true);
    }

    fn runScript(self: *JobQueueCtx, a: std.mem.Allocator, script: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "script", .{ .string = script });
        _ = try self.dispatchFn.?(self.klippy.?, "gcode/script", .{ .object = params }, a);
    }

    /// Cancellation must not interrupt a data-structure critical section.
    fn lockJobs(self: *JobQueueCtx) void {
        self.mutex.lockUncancelable(self.clock_io);
    }

    fn unlockJobs(self: *JobQueueCtx) void {
        self.mutex.unlock(self.clock_io);
    }

    /// Set `queue_state` and announce a change (job_queue.py
    /// `_set_queue_state`). Callers must NOT hold `mutex`.
    fn setQueueState(self: *JobQueueCtx, s: []const u8) void {
        {
            self.lockJobs();
            defer self.unlockJobs();
            if (std.mem.eql(u8, self.queue_state, s)) return;
            self.queue_state = s;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        emitQueueChanged(self, arena.allocator(), "state_changed", false);
    }

    /// Thread-safe compare of `queue_state`.
    fn queueStateEql(self: *JobQueueCtx, s: []const u8) bool {
        self.lockJobs();
        defer self.unlockJobs();
        return std.mem.eql(u8, self.queue_state, s);
    }

    /// Persist the queued jobs. A failure is logged: the in-memory queue stays
    /// authoritative. Callers must NOT hold `mutex`.
    fn saveToStore(self: *JobQueueCtx, arena: std.mem.Allocator) void {
        self.save_mutex.lockUncancelable(self.clock_io);
        defer self.save_mutex.unlock(self.clock_io);
        const queue = buildResponse(self, arena) catch |err| {
            std.debug.print("phobos: warning: failed to persist job queue: {} — queued jobs may be lost on restart\n", .{err});
            return;
        };
        self.store.insertItem(arena, ns_queue, queue_key, queue) catch |err|
            std.debug.print("phobos: warning: failed to persist job queue: {} — queued jobs may be lost on restart\n", .{err});
    }

    /// Load persisted jobs from store. The persisted `queue_state` is ignored:
    /// the queue starts "paused" and no load is in flight after a restart.
    fn loadFromStore(self: *JobQueueCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const val = (try self.store.getItem(a, ns_queue, queue_key)) orelse return;
        if (val != .object) return;
        const qj = val.object.get("queued_jobs") orelse return;
        if (qj != .array) return;
        for (qj.array.items) |item| {
            if (item != .object) continue;
            const obj2 = item.object;
            const filename = obj2.get("filename") orelse continue;
            const job_id = obj2.get("job_id") orelse continue;
            if (filename != .string or job_id != .string) continue;
            const time_added = switch (obj2.get("time_added") orelse .null) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => 0.0,
            };
            const owned_filename = try self.gpa.dupe(u8, filename.string);
            errdefer self.gpa.free(owned_filename);
            const owned_id = try self.gpa.dupe(u8, job_id.string);
            errdefer self.gpa.free(owned_id);
            try self.jobs.append(self.gpa, .{
                .filename = owned_filename,
                .job_id = owned_id,
                .time_added = time_added,
            });
        }
    }
};

/// Dispatch worker body. After a completed print it sleeps out the transition
/// delay, waking early when the cancel event is set (pause/abort/deinit).
/// NOTE: never null `delay_thread` from here — only the joiner
/// (cancelDelayTimer/deinit) clears it after the join, else a concurrent
/// joiner could read null, skip the join, and leak/UAF the running thread.
fn transitionDelayCallback(self: *JobQueueCtx, reason: DispatchReason) void {
    const delay: std.Io.Duration = switch (reason) {
        .immediate => .zero,
        .startup => startup_delay,
        .transition => .fromNanoseconds(std.math.lossyCast(i64, self.transition_delay * std.time.ns_per_s)),
    };
    if (sleep.untilStopped(self.clock_io, delay, &self.delay_cancel)) return;
    // Bail if cancelled or torn down. deinit nulls dispatchFn, so that check
    // alone detects teardown; io may be null in tests with a non-Klippy capture
    // dispatch (only the sleep needs io).
    if (self.delay_cancel.isSet() or self.dispatchFn == null) return;
    self.dispatchNextJob(reason == .transition);
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
        try obj.put(alloc, "filename", .{ .string = try alloc.dupe(u8, self.filename) });
        try obj.put(alloc, "job_id", .{ .string = try alloc.dupe(u8, self.job_id) });
        try obj.put(alloc, "time_added", .{ .float = self.time_added });
        const time_in_queue = if (cur_time > self.time_added) cur_time - self.time_added else 0.0;
        try obj.put(alloc, "time_in_queue", .{ .float = time_in_queue });
        return .{ .object = obj };
    }
};

/// Get current time as float seconds (CLOCK_REALTIME).
fn nowSecs(io: std.Io) f64 {
    return clock.wallSeconds(io);
}

/// Generate a unique job_id using monotonic time + address.
fn genJobId(io: std.Io, alloc: std.mem.Allocator, seq: u32) ![]u8 {
    const ns = clock.monotonicNanos(io);
    // 16 hex ns + 4 hex seq → unique even within one nanosecond.
    var buf: [20]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{X:0>16}{X:0>4}", .{ ns, seq & 0xFFFF });
    return alloc.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn buildQueueObj(alloc: std.mem.Allocator, jobs_arr: std.json.Value, state: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "queued_jobs", jobs_arr);
    try obj.put(alloc, "queue_state", .{ .string = state });
    return .{ .object = obj };
}

/// Build current queue response object (queued_jobs array + queue_state).
fn buildResponse(c: *JobQueueCtx, alloc: std.mem.Allocator) !std.json.Value {
    const cur_time = nowSecs(c.clock_io);
    var arr: std.json.Array = .init(alloc);
    c.lockJobs();
    defer c.unlockJobs();
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

    // Snapshot jobs + state under the lock (the dispatch worker mutates them
    // concurrently). emitLocked below uses conns, not the mutex, so it's fine to
    // hold the lock across it. An allocation failure drops the event rather
    // than announcing a truncated queue.
    c.lockJobs();
    defer c.unlockJobs();
    if (include_queue) {
        const cur_time = nowSecs(c.clock_io);
        var arr: std.json.Array = .init(alloc);
        for (c.jobs.items) |*j| arr.append(j.asJson(alloc, cur_time) catch return) catch return;
        inner.put(alloc, "updated_queue", .{ .array = arr }) catch return;
    } else {
        inner.put(alloc, "updated_queue", .null) catch return;
    }
    inner.put(alloc, "queue_state", .{ .string = c.queue_state }) catch return;

    // Build params array (Moonraker wraps event data in a 1-element array).
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;

    // Emit via emitLocked (which does NOT acquire Core): handlers and job-state
    // events already hold Core, so plain emit would deadlock; the dispatch
    // worker must NOT acquire Core either, because a Core holder may be joining
    // it (cancelDelayTimer). emitLocked broadcasts under per-connection write
    // locks, so it's safe from both. No-op without io.
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
    // `filenames` is required (Moonraker's get_list raises when absent) — without
    // this an empty POST silently enqueues nothing and returns 200.
    const files = (try webreq.optionalList(alloc, params, "filenames")) orelse return error.InvalidParams;
    const reset = ((try webreq.optional(bool, params, "reset")) orelse false);

    // Validate every file before touching the queue (job_queue.py queue_job):
    // a rejected request leaves the queue unchanged. Reject files that don't
    // exist under the gcodes root; no checker wired → accept.
    for (files) |filename| {
        if (!c.fileExists(filename)) return error.InvalidParams;
    }

    var pending: std.ArrayList(QueuedJob) = .empty;
    defer {
        for (pending.items) |*job| job.deinit(c.gpa);
        pending.deinit(c.gpa);
    }
    try pending.ensureTotalCapacity(c.gpa, files.len);
    for (files) |file| {
        const job_id = try genJobId(c.clock_io, c.gpa, c.job_seq.fetchAdd(1, .monotonic));
        errdefer c.gpa.free(job_id);
        const filename = try c.gpa.dupe(u8, file);
        errdefer c.gpa.free(filename);
        pending.appendAssumeCapacity(.{
            .filename = filename,
            .job_id = job_id,
            .time_added = nowSecs(c.clock_io),
        });
    }

    var set_ready = false;
    {
        c.lockJobs();
        defer c.unlockJobs();
        if (reset) {
            try c.jobs.ensureTotalCapacity(c.gpa, pending.items.len);
        } else {
            try c.jobs.ensureUnusedCapacity(c.gpa, pending.items.len);
        }
        if (reset) {
            for (c.jobs.items) |*j| j.deinit(c.gpa);
            c.jobs.clearRetainingCapacity();
        }

        c.jobs.appendSliceAssumeCapacity(pending.items);
        pending.clearRetainingCapacity();
        // Jobs queued during a print continue automatically after it.
        set_ready = c.automatic and !c.pause_requested and c.isPrinting();
    }

    // Persist
    c.saveToStore(alloc);
    emitQueueChanged(c, alloc, "jobs_added", true);
    if (set_ready) c.setQueueState("ready");
    return buildResponse(c, alloc);
}

/// DELETE /server/job_queue/job — remove job(s) by job_ids or all=true
pub fn handleDeleteJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const all = ((try webreq.optional(bool, params, "all")) orelse false);

    if (all) {
        {
            c.lockJobs();
            defer c.unlockJobs();
            for (c.jobs.items) |*j| j.deinit(c.gpa);
            c.jobs.clearRetainingCapacity();
        }
        c.saveToStore(alloc);
        emitQueueChanged(c, alloc, "jobs_removed", true);
    } else {
        const job_ids = (try webreq.optionalList(alloc, params, "job_ids")) orelse &.{};
        if (job_ids.len == 0) {
            // Nothing deleted — return current state without notification
            return buildResponse(c, alloc);
        }
        {
            c.lockJobs();
            defer c.unlockJobs();
            var i: usize = 0;
            while (i < c.jobs.items.len) {
                const j = &c.jobs.items[i];
                var found = false;
                for (job_ids) |id| {
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

/// POST /server/job_queue/pause — pauses the queue only; a running print
/// continues (job_queue.py pause_queue).
pub fn handlePause(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    c.setQueueState("paused");
    c.cancelDelayTimer(); // joins worker — never under the lock
    {
        c.lockJobs();
        defer c.unlockJobs();
        c.pause_requested = true;
    }
    return buildResponse(c, alloc);
}

/// POST /server/job_queue/start (job_queue.py start_queue). Loads the front
/// job at once when Klippy is connected and idle; otherwise the queue waits
/// "ready" with automatic transition, else stays "paused".
pub fn handleStart(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const next_state: ?[]const u8 = blk: {
        c.lockJobs();
        defer c.unlockJobs();
        if (!std.mem.eql(u8, c.queue_state, "ready") and !std.mem.eql(u8, c.queue_state, "paused")) break :blk null;
        if (c.jobs.items.len == 0) break :blk "paused";
        if (c.canDispatch() and !c.isPrinting()) break :blk "loading";
        break :blk if (c.automatic) "ready" else "paused";
    };
    // Allocate the accepted response before committing state or starting work.
    var response = try buildResponse(c, alloc);
    {
        c.lockJobs();
        defer c.unlockJobs();
        c.pause_requested = false;
    }
    if (next_state) |s| {
        c.setQueueState(s);
        response.object.getPtr("queue_state").?.* = .{ .string = s };
        // Outside the lock: scheduling joins the prior worker thread.
        if (std.mem.eql(u8, s, "loading") and !c.scheduleNextJobDispatch(.immediate)) {
            response.object.getPtr("queue_state").?.* = .{ .string = "paused" };
        }
    }
    return response;
}

/// POST /server/job_queue/jump — move job_id to front of queue
pub fn handleJump(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *JobQueueCtx = @ptrCast(@alignCast(ctx));
    const job_id = try webreq.required([]const u8, params, "job_id");

    {
        c.lockJobs();
        defer c.unlockJobs();
        // Find the job, then move it to the front if not already there.
        var found_idx: ?usize = null;
        for (c.jobs.items, 0..) |*j, i| {
            if (std.mem.eql(u8, j.job_id, job_id)) {
                found_idx = i;
                break;
            }
        }
        const idx = found_idx orelse return error.NotFound;
        if (idx != 0) {
            const job = c.jobs.orderedRemove(idx);
            c.jobs.insert(c.gpa, 0, job) catch return error.OutOfMemory;
        }
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

test "Klippy ready loads a persisted job after the startup delay" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, aio, NoopStore.store(), &bus);
    defer ctx.deinit();
    var cap = TestDispatchCapture{ .gate_io = aio };
    defer cap.release.set(aio);
    ctx.setKlippyDispatch(&cap, TestDispatchCapture.handler);
    try ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "startup.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "STARTUP"),
        .time_added = 0,
    });
    ctx.onKlippyReady();
    try testing.expect(ctx.delay_thread == null);
    ctx.load_on_startup = true;
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    ctx.onKlippyReady();
    try testing.expect(ctx.queueStateEql("loading"));
    try testing.expect(sleep.untilStopped(aio, .fromSeconds(3), &cap.entered));
    try testing.expect(start.untilNow(aio).raw.toMilliseconds() >= 900);
    cap.release.set(aio);
    if (ctx.delay_thread) |*worker| worker.await(aio);
    ctx.delay_thread = null;
    try testing.expect(cap.called);
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
}

test "Klippy shutdown cancels startup without changing a requested pause" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, aio, NoopStore.store(), &bus);
    defer ctx.deinit();
    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(&cap, TestDispatchCapture.handler);
    ctx.load_on_startup = true;
    try ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "startup.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "STARTUP"),
        .time_added = 0,
    });
    for ([_]bool{ false, true }) |requested| {
        ctx.pause_requested = requested;
        ctx.onKlippyReady();
        ctx.onKlippyShutdown();
        try testing.expect(ctx.queueStateEql("paused"));
        try testing.expectEqual(requested, ctx.pause_requested);
        try testing.expect(ctx.delay_thread == null);
        try testing.expect(!cap.called);
        try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
    }
}

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
    return JobQueueCtx.init(alloc, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    ctx.queue_state = "ready";
    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
}

test "handleStart: without Klippy a queued job waits paused, or ready with automatic transition" {
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p1 = try mkParams(a, "{\"filenames\":[\"a.gcode\"]}");
    _ = try handlePostJob(@ptrCast(&ctx), p1, a);

    // job_queue.py start_queue: the printer cannot print, so the queue only
    // waits "ready" when it may advance on its own.
    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    ctx.setAutomaticTransition(true);
    const ready = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("ready", ready.object.get("queue_state").?.string);
}

test "handlePostJob: a rejected file leaves the queue unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    _ = try handlePostJob(@ptrCast(&ctx), try mkParams(a, "{\"filenames\":[\"a.gcode\"]}"), a);
    try testing.expectError(error.InvalidParams, handlePostJob(@ptrCast(&ctx), try mkParams(a, "{\"filenames\":[\"b.gcode\",7],\"reset\":true}"), a));
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
    try testing.expectEqualStrings("a.gcode", ctx.jobs.items[0].filename);
}

test "handlePostJob: jobs queued during a print make the automatic queue ready" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    var dummy: u8 = 0;
    ctx.printing_check = jqPrintingStub;
    ctx.printing_ctx = &dummy;
    jq_printing_flag = true;
    defer jq_printing_flag = false;
    ctx.setAutomaticTransition(true);

    const params = try mkParams(a, "{\"filenames\":[\"a.gcode\"]}");
    try testing.expectEqualStrings("ready", (try handlePostJob(@ptrCast(&ctx), params, a)).object.get("queue_state").?.string);
    // An explicit pause sticks until the next start.
    _ = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", (try handlePostJob(@ptrCast(&ctx), params, a)).object.get("queue_state").?.string);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(alloc, std.testing.io, mem.dataStore(), &bus);
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

// Thread-safe no-op store: isolates the jobs/queue_state mutex under test from
// the (separately-locked) store backend. All vtable ops are stateless no-ops.
const NoopStore = struct {
    fn g(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!?std.json.Value {
        return null;
    }
    fn i(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds.Error!void {}
    fn u(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds.Error!void {}
    fn d(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!std.json.Value {
        return .null;
    }
    fn ln(_: *anyopaque, _: std.mem.Allocator) ds.Error![][]const u8 {
        return &.{};
    }
    fn gn(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds.Error!std.json.Value {
        return .null;
    }
    const vtable: ds.VTable = .{ .getItem = g, .insertItem = i, .updateItem = u, .deleteItem = d, .listNamespaces = ln, .getNamespace = gn };
    var dummy: u8 = 0;
    fn store() ds.DataStore {
        return .{ .ctx = @ptrCast(&dummy), .vtable = &vtable };
    }
};

test "queue snapshots own filename and id strings" {
    const alloc = testing.allocator;
    var job = blk: {
        const filename = try alloc.dupe(u8, "original.gcode");
        errdefer alloc.free(filename);
        const id = try alloc.dupe(u8, "ONE");
        break :blk QueuedJob{ .filename = filename, .job_id = id, .time_added = 1 };
    };
    defer job.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const snapshot = try job.asJson(arena.allocator(), 2);
    job.filename[0] = 'X';
    job.job_id[0] = 'Y';
    try testing.expectEqualStrings("original.gcode", snapshot.object.get("filename").?.string);
    try testing.expectEqualStrings("ONE", snapshot.object.get("job_id").?.string);
}

test "queue saves cannot persist older snapshots after newer changes" {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(io, ":memory:");
    defer db.deinit();
    const Fixture = struct {
        io: std.Io,
        backend: ds.DataStore,
        first_blocked: std.Io.Event = .unset,
        release_first: std.Io.Event = .unset,
        second_started: std.Io.Event = .unset,
        second_committed: std.Io.Event = .unset,
        attempts: std.atomic.Value(u32) = .init(0),
        fn insert(raw: *anyopaque, a: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const first = self.attempts.fetchAdd(1, .monotonic) == 0;
            if (first) {
                self.first_blocked.set(self.io);
                if (!sleep.untilStopped(self.io, .fromSeconds(5), &self.release_first)) return error.BackendError;
            }
            try self.backend.insertItem(a, ns, key, value);
            if (!first) self.second_committed.set(self.io);
        }
        fn save(ctx: *JobQueueCtx, started: ?*std.Io.Event) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            if (started) |event| event.set(ctx.clock_io);
            ctx.saveToStore(arena.allocator());
        }
    };
    var fixture = Fixture{ .io = io, .backend = db.dataStore() };
    var vtable = NoopStore.vtable;
    vtable.insertItem = Fixture.insert;
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(alloc, io, .{ .ctx = &fixture, .vtable = &vtable }, &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    try ctx.jobs.ensureTotalCapacity(alloc, 2);
    {
        const filename = try alloc.dupe(u8, "one.gcode");
        errdefer alloc.free(filename);
        const id = try alloc.dupe(u8, "ONE");
        errdefer alloc.free(id);
        ctx.jobs.appendAssumeCapacity(.{ .filename = filename, .job_id = id, .time_added = 1 });
    }
    var first = try io.concurrent(Fixture.save, .{ &ctx, @as(?*std.Io.Event, null) });
    defer first.cancel(io);
    defer fixture.release_first.set(io);
    try testing.expect(sleep.untilStopped(io, .fromSeconds(1), &fixture.first_blocked));
    {
        ctx.lockJobs();
        defer ctx.unlockJobs();
        const filename = try alloc.dupe(u8, "two.gcode");
        errdefer alloc.free(filename);
        const id = try alloc.dupe(u8, "TWO");
        errdefer alloc.free(id);
        ctx.jobs.appendAssumeCapacity(.{ .filename = filename, .job_id = id, .time_added = 2 });
    }
    var second = try io.concurrent(Fixture.save, .{ &ctx, @as(?*std.Io.Event, &fixture.second_started) });
    defer second.cancel(io);
    defer fixture.release_first.set(io);
    try testing.expect(sleep.untilStopped(io, .fromSeconds(1), &fixture.second_started));
    _ = sleep.untilStopped(io, .fromMilliseconds(100), &fixture.second_committed);
    fixture.release_first.set(io);
    first.await(io);
    second.await(io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stored = (try db.getItem(arena.allocator(), ns_queue, queue_key)).?;
    const jobs = stored.object.get("queued_jobs").?.array.items;
    try testing.expectEqual(ctx.jobs.items.len, jobs.len);
    for (ctx.jobs.items, jobs) |live, saved| {
        try testing.expectEqualStrings(live.filename, saved.object.get("filename").?.string);
        try testing.expectEqualStrings(live.job_id, saved.object.get("job_id").?.string);
    }
}

test "stress: concurrent handlers + reader callback don't corrupt the queue" {
    const JE = @import("job_state.zig").JobEvent;
    // smp_allocator + no-op store are both thread-safe, so any failure is the
    // jobs/queue_state race the mutex exists to prevent (ASAN/segfault would fail
    // this; without the lock the ArrayList tears under contention).
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(alloc, io, NoopStore.store(), &bus);
    defer ctx.deinit();

    // A second thread reorders the queue and changes its state while the main
    // thread appends. canDispatch is false (no Klippy wired), so no dispatch
    // worker is spawned.
    const rounds = 3000;
    const Worker = struct {
        fn run(c: *JobQueueCtx) void {
            var n: usize = 0;
            while (n < rounds) : (n += 1) {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                c.onJobStateChanged(JE.complete, .empty, .empty);
                c.onJobStateChanged(JE.@"error", .empty, .empty);
                var last: []const u8 = "";
                {
                    c.lockJobs();
                    defer c.unlockJobs();
                    if (c.jobs.items.len > 0) last = arena.allocator().dupe(u8, c.jobs.items[c.jobs.items.len - 1].job_id) catch return;
                }
                if (last.len == 0) continue;
                var params: std.json.ObjectMap = .empty;
                params.put(arena.allocator(), "job_id", .{ .string = last }) catch return;
                _ = handleJump(@ptrCast(c), .{ .object = params }, arena.allocator()) catch return;
            }
        }
    };
    {
        const th = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Worker.run, .{&ctx});
        defer th.join();
        var n: usize = 0;
        while (n < rounds) : (n += 1) {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const params = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"filenames\":[\"x.gcode\"]}", .{});
            _ = try handlePostJob(@ptrCast(&ctx), params, a);
            _ = try handleStatus(@ptrCast(&ctx), .null, a);
            _ = try handleDeleteJob(@ptrCast(&ctx), .{ .object = .empty }, a);
        }
    }
    // No append or reorder was lost: every queued job is present exactly once.
    try testing.expectEqual(@as(usize, rounds), ctx.jobs.items.len);
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    for (ctx.jobs.items) |j| try testing.expect(!(try seen.getOrPut(j.job_id)).found_existing);
    try testing.expectEqualStrings("paused", ctx.queue_state);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    ctx.setTransitionConfig(null, 2.5);
    try testing.expectEqual(2.5, ctx.transition_delay);
    try testing.expectEqual(null, ctx.transition_gcode);

    ctx.setTransitionConfig("G28", 0.1);
    try testing.expectEqual(0.1, ctx.transition_delay);
    try testing.expectEqualStrings("G28", ctx.transition_gcode.?);
}

test "scheduleNextJobDispatch: zero-delay dispatches immediately via capture" {
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(std.heap.smp_allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
    defer ctx.deinit();
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setTransitionConfig(null, 0.0);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "print.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;

    ctx.queue_state = "loading";
    _ = ctx.scheduleNextJobDispatch(.immediate);
    // Dispatch now runs on a worker thread (always-async); join it before asserting.
    if (ctx.delay_thread) |*th| {
        th.await(ctx.clock_io);
        ctx.delay_thread = null;
    }
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
    try testing.expectEqualStrings("paused", ctx.queue_state);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    var dummy: u8 = 0;
    ctx.setKlippyDispatch(&dummy, &FailDispatch.handler);

    _ = try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "print.gcode"),
        .job_id = try a.dupe(u8, "JOB001"),
        .time_added = 1.0,
    });
    defer for (ctx.jobs.items) |*j| j.deinit(ctx.gpa);

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(false); // start gcode fails → must pause and keep the job
    try testing.expectEqualStrings("paused", ctx.queue_state);
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    defer jq_printing_flag = false; // reset for other tests
    _ = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expect(!cap.called); // deferred while printing
    try testing.expectEqualStrings("paused", ctx.queue_state);
    // With automatic transition the queue waits "ready" for the print to end.
    ctx.setAutomaticTransition(true);
    _ = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expect(!cap.called);
    try testing.expectEqualStrings("ready", ctx.queue_state);
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Safe to call when no timer was ever started.
    ctx.cancelDelayTimer();
    try testing.expectEqual(null, ctx.delay_thread);

    // Safe to call multiple times.
    ctx.cancelDelayTimer();
    try testing.expectEqual(null, ctx.delay_thread);
}

test "handleStart: loads the front job without waiting for the transition delay" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(std.heap.smp_allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    // job_queue.py start_queue pops without the job transition delay or gcode.
    ctx.setTransitionConfig("G28", 60.0);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "print.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("loading", result.object.get("queue_state").?.string);
    // Dispatch runs on a worker thread now (always-async); join before asserting.
    if (ctx.delay_thread) |*th| {
        th.await(ctx.clock_io);
        ctx.delay_thread = null;
    }
    try testing.expectEqual(@as(usize, 1), cap.call_count); // print only, no transition gcode
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
}

test "transition_delay: handlePause cancels running delay timer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(std.heap.smp_allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    // Long delay so the pause lands mid-wait.
    ctx.setTransitionConfig(null, 60.0);
    ctx.setAutomaticTransition(true);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "print.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;

    // A completed print on a ready automatic queue starts the delay timer.
    ctx.queue_state = "ready";
    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);
    try testing.expectEqualStrings("loading", ctx.queue_state);

    // Pause immediately — cancel the timer.
    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    try testing.expect(!cap.called);
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
}

test "transition_delay: timer completes and dispatches" {
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(std.heap.smp_allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
    defer ctx.deinit();
    ctx.setIo(io);
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setTransitionConfig(null, 0.01);

    _ = ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "print.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "JOB001"),
        .time_added = 100.0,
    }) catch unreachable;

    // Spawn the delay timer thread.
    ctx.queue_state = "loading";
    _ = ctx.scheduleNextJobDispatch(.transition);

    // Wait for the timer thread to complete.
    if (ctx.delay_thread) |*th| {
        th.await(ctx.clock_io);
        ctx.delay_thread = null;
    }

    // The dispatch should have fired after the timer expired.
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "deinit: cancels delay timer gracefully" {
    var core = NullCore.init();
    var cap = TestDispatchCapture{};
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(std.heap.smp_allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    {
        var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
        defer ctx.deinit();
        ctx.setIo(io);
        ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
        ctx.setTransitionConfig(null, 60.0);

        try ctx.jobs.append(ctx.gpa, .{
            .filename = try ctx.gpa.dupe(u8, "print.gcode"),
            .job_id = try ctx.gpa.dupe(u8, "JOB001"),
            .time_added = 100.0,
        });
        ctx.queue_state = "loading";
        _ = ctx.scheduleNextJobDispatch(.transition);
    }
    try testing.expect(!cap.called);
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
    gate_io: ?std.Io = null,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,

    fn handler(ctx: *anyopaque, method: []const u8, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
        const cap: *TestDispatchCapture = @ptrCast(@alignCast(ctx));
        if (cap.gate_io) |io| {
            cap.entered.set(io);
            if (!sleep.untilStopped(io, .fromSeconds(5), &cap.release)) return error.TestTimeout;
        }
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
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Add a job to the queue.
    const fname = try testing.allocator.dupe(u8, "test.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB001");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 100.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(false);
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
    try testing.expect(cap.has_params);
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
}

test "dispatchNextJob: start_print strips a leading slash and escapes quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    const Script = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        fn handler(_: *anyopaque, _: []const u8, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
            const s = params.object.get("script").?.string;
            @memcpy(buf[0..s.len], s);
            len = s.len;
            return .null;
        }
    };
    var dummy: u8 = 0;
    ctx.setKlippyDispatch(&dummy, &Script.handler);
    try ctx.jobs.append(ctx.gpa, .{ .filename = try a.dupe(u8, "/a \"b\".gcode"), .job_id = try a.dupe(u8, "J1"), .time_added = 1.0 });

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(false);
    try testing.expectEqualStrings("SDCARD_PRINT_FILE FILENAME=\"a \\\"b\\\".gcode\"", Script.buf[0..Script.len]);
}

test "handleStart: dispatches next job when wired and queued" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus);
    defer ctx.deinit();

    try ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "printme.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "JOB002"),
        .time_added = 200.0,
    });

    var cap = TestDispatchCapture{ .gate_io = io };
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    defer cap.release.set(io);

    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expect(ctx.io == null);
    try testing.expect(sleep.untilStopped(io, .fromSeconds(1), &cap.entered));
    try testing.expectEqualStrings("loading", result.object.get("queue_state").?.string);
    try testing.expect(ctx.queueStateEql("starting"));
    cap.release.set(io);
    if (ctx.delay_thread) |*th| {
        th.await(ctx.clock_io);
        ctx.delay_thread = null;
    }
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
    try testing.expectEqual(@as(usize, 0), ctx.jobs.items.len);
    try testing.expectEqualStrings("printme.gcode", result.object.get("queued_jobs").?.array.items[0].object.get("filename").?.string);
}

test "handleStart: response allocation failure leaves the paused queue intact" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            var bus: NotifyBus = undefined;
            var ctx = try JobQueueCtx.init(std.heap.smp_allocator, testing.io, NoopStore.store(), &bus);
            defer ctx.deinit();
            var cap = TestDispatchCapture{};
            ctx.setKlippyDispatch(&cap, TestDispatchCapture.handler);
            ctx.pause_requested = true;
            try ctx.jobs.append(ctx.gpa, .{
                .filename = try ctx.gpa.dupe(u8, "one.gcode"),
                .job_id = try ctx.gpa.dupe(u8, "ONE"),
                .time_added = 1,
            });
            const response = handleStart(&ctx, .null, arena.allocator()) catch |err| {
                try testing.expect(ctx.delay_thread == null);
                try testing.expect(ctx.pause_requested);
                try testing.expect(ctx.queueStateEql("paused"));
                try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
                return err;
            };
            try testing.expectEqualStrings("loading", response.object.get("queue_state").?.string);
        }
    }.run, .{});
}

test "handleStart: worker scheduling failure returns paused without dropping jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, threaded.io(), NoopStore.store(), &bus);
    defer ctx.deinit();
    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(&cap, TestDispatchCapture.handler);
    try ctx.jobs.append(ctx.gpa, .{
        .filename = try ctx.gpa.dupe(u8, "one.gcode"),
        .job_id = try ctx.gpa.dupe(u8, "ONE"),
        .time_added = 1,
    });
    const response = try handleStart(&ctx, .null, arena.allocator());
    try testing.expectEqualStrings("paused", response.object.get("queue_state").?.string);
    try testing.expect(ctx.queueStateEql("paused"));
    try testing.expect(ctx.delay_thread == null);
    try testing.expect(!cap.called);
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
}

test "handlePause: pauses the queue without pausing the print" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    // job_queue.py pause_queue sends nothing to Klippy.
    const result = try handlePause(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    try testing.expect(!cap.called);
}

test "handleStart: does not dispatch when not wired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();

    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    try ctx.jobs.append(ctx.gpa, .{
        .filename = try a.dupe(u8, "printme.gcode"),
        .job_id = try a.dupe(u8, "JOB003"),
        .time_added = 300.0,
    });

    // No dispatch wired — handleStart should still work, just not dispatch.
    const result = try handleStart(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("paused", result.object.get("queue_state").?.string);
    try testing.expect(ctx.delay_thread == null);
}

test "setTransitionConfig: stores gcode and delay" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB100");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 400.0 });

    ctx.setTransitionConfig("G28", 0.0);

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(true);

    try testing.expect(cap.called);
    // Two dispatches: transition gcode, then print file.
    try testing.expectEqual(@as(usize, 2), cap.call_count);
    try testing.expectEqualStrings("gcode/script", cap.method); // last call = print file
    try testing.expectEqualStrings("paused", ctx.queue_state); // queue now empty
}

test "dispatchNextJob: no transition gcode when not configured" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB101");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 500.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(true);

    try testing.expect(cap.called);
    try testing.expectEqual(@as(usize, 1), cap.call_count);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "dispatchNextJob: transition with empty gcode string is no-op" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "job.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB102");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 600.0 });

    ctx.setTransitionConfig("", 0.0);

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

    ctx.queue_state = "loading";
    ctx.dispatchNextJob(true);

    try testing.expect(cap.called);
    try testing.expectEqual(@as(usize, 1), cap.call_count); // empty gcode skipped
}

test "onJobStateChanged complete: auto-advances and dispatches next" {
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(std.heap.smp_allocator, std.testing.io, NoopStore.store(), &bus);
    defer ctx.deinit();

    // Queue two jobs.
    const fname1 = try ctx.gpa.dupe(u8, "job1.gcode");
    const jid1 = try ctx.gpa.dupe(u8, "JOB010");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname1, .job_id = jid1, .time_added = 10.0 });

    const fname2 = try ctx.gpa.dupe(u8, "job2.gcode");
    const jid2 = try ctx.gpa.dupe(u8, "JOB011");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname2, .job_id = jid2, .time_added = 20.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setAutomaticTransition(true);
    ctx.queue_state = "ready";

    // Simulate the current job completing.
    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);
    // Auto-advance dispatch runs on a worker thread now; join before asserting.
    if (ctx.delay_thread) |*th| {
        th.await(ctx.clock_io);
        ctx.delay_thread = null;
    }
    // The front job was loaded and removed; one remains, so the queue waits ready.
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
    try testing.expectEqualStrings("job2.gcode", ctx.jobs.items[0].filename);
    try testing.expectEqualStrings("ready", ctx.queue_state);
    try testing.expect(cap.called);
    try testing.expectEqualStrings("gcode/script", cap.method);
}

test "onJobStateChanged complete: default (automatic off) does NOT auto-advance" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname1 = try testing.allocator.dupe(u8, "job1.gcode");
    const jid1 = try testing.allocator.dupe(u8, "JOB010");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname1, .job_id = jid1, .time_added = 10.0 });
    const fname2 = try testing.allocator.dupe(u8, "job2.gcode");
    const jid2 = try testing.allocator.dupe(u8, "JOB011");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname2, .job_id = jid2, .time_added = 20.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    // automatic_transition defaults to false → no dispatch on completion.

    ctx.queue_state = "ready";
    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);
    try testing.expect(ctx.delay_thread == null);
    try testing.expectEqual(@as(usize, 2), ctx.jobs.items.len); // nothing removed
    try testing.expectEqualStrings("ready", ctx.queue_state);
    try testing.expect(!cap.called); // no auto-advance dispatch
}

test "onJobStateChanged complete: a paused queue keeps its jobs after a manual print" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = try JobQueueCtx.init(testing.allocator, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const fname = try testing.allocator.dupe(u8, "queued.gcode");
    const jid = try testing.allocator.dupe(u8, "JOB020");
    try ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 30.0 });

    var cap = TestDispatchCapture{};
    ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);
    ctx.setAutomaticTransition(true);

    // The user paused the queue and printed another file by hand.
    ctx.onJobStateChanged(JobEvent.complete, .empty, .empty);

    try testing.expect(ctx.delay_thread == null);
    try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
    try testing.expectEqualStrings("paused", ctx.queue_state);
    try testing.expect(!cap.called);
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
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var bus: NotifyBus = undefined;
            var ctx = JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus) catch return;
            defer ctx.deinit();

            var cap = TestDispatchCapture{};
            ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            // Optionally add a job.
            if (buf[0] & 1 == 0) {
                const fname = ctx.gpa.dupe(u8, "fuzz.gcode") catch return;
                const jid = ctx.gpa.dupe(u8, "FUZZ01") catch return;
                ctx.jobs.append(ctx.gpa, .{ .filename = fname, .job_id = jid, .time_added = 100.0 }) catch return;
            }

            // Exercise dispatch from every state.
            const states = [_][]const u8{ "paused", "ready", "loading", "starting" };
            ctx.queue_state = states[buf[2] % states.len];
            ctx.setAutomaticTransition(buf[3] & 1 == 0);
            ctx.dispatchNextJob(buf[4] & 1 == 0);

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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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

            var cap = TestDispatchCapture{};
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var bus: NotifyBus = undefined;
            var ctx = JobQueueCtx.init(std.heap.smp_allocator, io, NoopStore.store(), &bus) catch return;
            defer ctx.deinit();
            ctx.setKlippyDispatch(@ptrCast(&cap), &TestDispatchCapture.handler);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            if (buf[0] & 1 == 0) {
                ctx.jobs.append(ctx.gpa, .{ .filename = ctx.gpa.dupe(u8, "fuzz.gcode") catch return, .job_id = ctx.gpa.dupe(u8, "FUZZ01") catch return, .time_added = 100.0 }) catch return;
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
            var ctx = JobQueueCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
    const id0 = try genJobId(std.testing.io, a, 0);
    defer a.free(id0);
    const id1 = try genJobId(std.testing.io, a, 1);
    defer a.free(id1);
    try std.testing.expectEqual(@as(usize, 20), id0.len);
    try std.testing.expect(!std.mem.eql(u8, id0, id1));
}

test "persisted queue loading cleans up partial jobs and rejects non-string fields" {
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"queued_jobs":[{"filename":"benchy.gcode","job_id":"one"},{"filename":2,"job_id":"bad"},{"filename":"bad.gcode","job_id":3}]}
    , .{});
    try db.insertItem(alloc, ns_queue, queue_key, value);
    var bus: NotifyBus = undefined;
    var baseline = testing.FailingAllocator.init(testing.allocator, .{});
    // A queue persisted mid-load restarts paused (job_queue.py starts paused).
    try db.insertItem(alloc, ns_queue, queue_key ++ ".queue_state", .{ .string = "loading" });
    var complete = try JobQueueCtx.init(baseline.allocator(), testing.io, db.dataStore(), &bus);
    try testing.expectEqualStrings("paused", complete.queue_state);
    const count = baseline.alloc_index;
    try testing.expectEqual(@as(usize, 1), complete.jobs.items.len);
    complete.deinit();
    for (0..count) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        if (JobQueueCtx.init(failing.allocator(), testing.io, db.dataStore(), &bus)) |loaded| {
            var ctx = loaded;
            ctx.deinit();
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "post_job allocation failures preserve the complete existing queue" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
            defer db.deinit();
            var bus: NotifyBus = undefined;
            var ctx = try JobQueueCtx.init(alloc, testing.io, db.dataStore(), &bus);
            defer ctx.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const first = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"filenames\":[\"original.gcode\"]}", .{});
            _ = try handlePostJob(@ptrCast(&ctx), first, a);
            const replacement = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"filenames\":[\"one.gcode\",\"two.gcode\"],\"reset\":true}", .{});
            _ = handlePostJob(@ptrCast(&ctx), replacement, a) catch |err| {
                try testing.expectEqual(@as(usize, 1), ctx.jobs.items.len);
                try testing.expectEqualStrings("original.gcode", ctx.jobs.items[0].filename);
                return err;
            };
            try testing.expectEqual(@as(usize, 2), ctx.jobs.items.len);
            try testing.expectEqualStrings("one.gcode", ctx.jobs.items[0].filename);
            try testing.expectEqualStrings("two.gcode", ctx.jobs.items[1].filename);
        }
    }.run, .{});
}

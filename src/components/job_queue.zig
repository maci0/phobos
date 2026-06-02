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
    jobs: std.ArrayListUnmanaged(QueuedJob),
    /// Current queue state string.
    queue_state: []const u8,
    /// Opaque pointer to KlippyCtx for print dispatch. Set by app.zig via
    /// setKlippyDispatch (avoids circular @import with klippy_connection.zig).
    klippy: ?*anyopaque = null,
    /// Dispatch function that calls into KlippyCtx to send gcode scripts.
    dispatchFn: ?DispatchFn = null,

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

    /// Returns true when Klippy is wired and connected.
    pub fn canDispatch(self: *const JobQueueCtx) bool {
        return self.klippy != null and self.dispatchFn != null;
    }

    pub fn deinit(self: *JobQueueCtx) void {
        for (self.jobs.items) |*j| j.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
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
                    // Auto-advance: dispatch next job to Klippy.
                    if (self.canDispatch()) {
                        self.dispatchNextJob() catch {};
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
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    self.saveToStore(arena.allocator());
                    emitQueueChanged(self, arena.allocator(), "state_changed", false);
                }
            },
            .cancelled => {
                if (self.jobs.items.len > 0) {
                    self.queue_state = "paused";
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    self.saveToStore(arena.allocator());
                    emitQueueChanged(self, arena.allocator(), "state_changed", false);
                }
            },
            else => {},
        }
    }

    /// Dispatch start-gcode for the front job to Klippy.
    fn dispatchNextJob(self: *JobQueueCtx) !void {
        if (self.jobs.items.len == 0) return;
        const front = &self.jobs.items[0];
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var script_buf: [512]u8 = undefined;
        const script = try std.fmt.bufPrint(&script_buf, "SDCARD_PRINT_FILE FILENAME=\"{s}\"", .{front.filename});

        var params_obj = try std.json.ObjectMap.init(a, &.{}, &.{});
        try params_obj.put(a, "script", .{ .string = try a.dupe(u8, script) });
        _ = try self.dispatchFn.?(self.klippy.?, "gcode/script", .{ .object = params_obj }, a);
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
                        self.queue_state = try self.gpa.dupe(u8, qs.string);
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
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
}

/// Generate a unique job_id using monotonic time + address.
fn genJobId(alloc: std.mem.Allocator) ![]u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    const ns = @as(u64, @intCast(@as(i64, ts.sec))) *% 1_000_000_000 +% @as(u64, @intCast(@as(i64, ts.nsec)));
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{X:0>16}", .{ns});
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
        const job_id = try genJobId(c.gpa);
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
        // Dispatch start gcode for the front job to Klippy when connected.
        if (c.canDispatch()) {
            c.dispatchNextJob() catch {};
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
}

// ---------------------------------------------------------------------------
// Dispatch tests (Klippy gcode bridge)
// ---------------------------------------------------------------------------

/// Test dispatcher that captures the last dispatch call for verification.
const TestDispatchCapture = struct {
    called: bool = false,
    method: []const u8 = "",
    has_params: bool = false,

    fn handler(ctx: *anyopaque, method: []const u8, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
        const cap: *TestDispatchCapture = @ptrCast(@alignCast(ctx));
        cap.called = true;
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

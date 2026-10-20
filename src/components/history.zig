//! server.history.* API component — Moonraker-compatible print job history.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/history.py`:
//!
//!   GET    /server/history/list        → server.history.list
//!   GET    /server/history/totals      → server.history.totals
//!   POST   /server/history/reset_totals → server.history.reset_totals
//!   GET    /server/history/job         → server.history.get_job  (multi-verb: get_job)
//!   DELETE /server/history/job         → server.history.delete_job
//!
//! Jobs are persisted in the DataStore under namespace "history" with key
//! format "<job_id_hex>" (6-char uppercase hex, e.g. "000001").
//! Totals are persisted under namespace "history_totals" with key "totals".
//!
//! `job_state.zig` reports print_stats transitions through `onJobStateChanged`,
//! which adds and finishes jobs. notify_history_changed is emitted when a job
//! is added, finished or deleted.
//!
//! Job record shape (matches history.py PrinterJob / _prep_requested_job):
//!   job_id, filename, status, start_time, end_time, print_duration,
//!   total_duration, filament_used, metadata, auxiliary_data, user, exists
//!
//! list params: limit(int,50), start(int,0), since(float,-1),
//!              before(float,-1), order(string,"desc")
//! → {"count": N, "jobs": [...]}
//!
//! totals → {"job_totals": {...}, "auxiliary_totals": []}
//! reset_totals → {"last_totals": {...}, "last_auxiliary_totals": []}
//! get_job (uid) → {"job": {...}}
//! delete_job (uid / all) → {"deleted_jobs": [...]}

const std = @import("std");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const clock = @import("../util/clock.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Base totals (mirrors history.py BASE_TOTALS)
// ---------------------------------------------------------------------------

pub const base_totals_keys = [_][]const u8{
    "total_jobs",
    "total_time",
    "total_print_time",
    "total_filament_used",
    "longest_job",
    "longest_print",
};

pub const base_totals_values = [_]f64{ 0, 0, 0, 0, 0, 0 };

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Reporting strategy for an auxiliary history field (Moonraker HistoryFieldData).
pub const AuxStrategy = enum {
    basic, // last value seen this job
    accumulate, // running sum of recorded values
    maximum,
    minimum,
    average, // mean of recorded values
    delta, // last - first

    pub fn fromString(s: []const u8) AuxStrategy {
        return std.meta.stringToEnum(AuxStrategy, s) orelse .basic;
    }
};

/// One sensor-provided auxiliary field tracked across a print job and totalled
/// across jobs (Moonraker `[history_field]` / sensor history_field config).
pub const AuxField = struct {
    provider: []const u8, // sensor name owning the value
    name: []const u8, // field name reported in job auxiliary_data
    field: []const u8, // parameter within the provider
    units: ?[]const u8,
    strategy: AuxStrategy,
    // Per-job accumulators (reset at job start):
    has_value: bool = false,
    count: u64 = 0,
    sum: f64 = 0,
    max: f64 = 0,
    min: f64 = 0,
    first: f64 = 0,
    last: f64 = 0,
    // Cross-job total (accumulated on each finish):
    total: f64 = 0,

    pub fn resetJob(self: *AuxField) void {
        self.has_value = false;
        self.count = 0;
        self.sum = 0;
        self.max = 0;
        self.min = 0;
        self.first = 0;
        self.last = 0;
    }

    pub fn record(self: *AuxField, value: f64) void {
        if (!self.has_value) {
            self.has_value = true;
            self.first = value;
            self.max = value;
            self.min = value;
        } else {
            if (value > self.max) self.max = value;
            if (value < self.min) self.min = value;
        }
        self.last = value;
        self.sum += value;
        self.count += 1;
    }

    /// Finalize this job's value per the strategy.
    pub fn jobValue(self: *const AuxField) f64 {
        if (!self.has_value) return 0;
        return switch (self.strategy) {
            .basic => self.last,
            .accumulate => self.sum,
            .maximum => self.max,
            .minimum => self.min,
            .average => if (self.count > 0) self.sum / @as(f64, @floatFromInt(self.count)) else 0,
            .delta => self.last - self.first,
        };
    }

    /// Fold this job's value into the cross-job total (sum, or max for the
    /// max strategy).
    pub fn accumulateTotal(self: *AuxField) void {
        const v = self.jobValue();
        switch (self.strategy) {
            .maximum => if (v > self.total) {
                self.total = v;
            },
            .minimum => if (!self.has_value) {} else if (self.total == 0 or v < self.total) {
                self.total = v;
            },
            else => self.total += v,
        }
    }
};

pub const HistoryCtx = struct {
    clock_io: std.Io,
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,
    /// Current in-progress job_id (numeric), if any. Written by addJob/finishJob
    /// (job-state events under Core; Klippy disconnect/shutdown off Core) and
    /// read by Core-locked handlers (e.g. reset_totals); guard with
    /// cur_job_mutex to avoid a torn read.
    current_job_id: ?u64,
    /// Guards `current_job_id`. No-op when io is unset — see getCurrentJobId.
    cur_job_mutex: std.Io.Mutex = .init,
    /// Guards the *values* of `aux_fields` (the list itself is registered once at
    /// config time and stable thereafter). The per-field accumulators are mutated
    /// both by the Core-locked MQTT sensor bridge (recordAuxValue) and by the
    /// off-Core Klippy reader (resetAuxJob/accumulateAux via job start/finish), so
    /// without this they race. A leaf lock — these helpers never take Core or emit.
    aux_mutex: std.Io.Mutex = .init,
    /// Username attributed to the current job.
    job_user: []const u8,
    /// Registered auxiliary fields (sensor-provided), owned by gpa.
    aux_fields: std.ArrayList(AuxField) = .empty,
    /// Allocator for aux-field registrations.
    gpa: std.mem.Allocator = std.heap.smp_allocator,
    /// Does "gcodes/<filename>" exist (file_manager.gcodeExistsErased)? Sets a
    /// job's `exists` (history.py `_prep_requested_job`); unset reports false.
    file_check: ?*const fn (*anyopaque, []const u8) bool = null,
    file_check_ctx: ?*anyopaque = null,

    fn fileExists(self: *const HistoryCtx, filename: []const u8) bool {
        const f = self.file_check orelse return false;
        return f(self.file_check_ctx orelse return false, filename);
    }

    pub fn setIo(self: *HistoryCtx, io: std.Io) void {
        self.io = io;
    }

    /// Thread-safe access to `current_job_id`. Locks no-op when io is unset
    /// (single-threaded init / unit tests have no concurrent mutator).
    fn getCurrentJobId(self: *HistoryCtx) ?u64 {
        if (self.io) |io| self.cur_job_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.cur_job_mutex.unlock(io);
        return self.current_job_id;
    }

    fn setCurrentJobId(self: *HistoryCtx, v: ?u64) void {
        if (self.io) |io| self.cur_job_mutex.lockUncancelable(io);
        defer if (self.io) |io| self.cur_job_mutex.unlock(io);
        self.current_job_id = v;
    }

    /// Serialize access to the aux-field value accumulators (no-op when io unset).
    fn lockAux(self: *HistoryCtx) void {
        if (self.io) |io| self.aux_mutex.lockUncancelable(io);
    }
    fn unlockAux(self: *HistoryCtx) void {
        if (self.io) |io| self.aux_mutex.unlock(io);
    }

    pub fn deinit(self: *HistoryCtx) void {
        for (self.aux_fields.items) |f| {
            self.gpa.free(f.provider);
            self.gpa.free(f.name);
            self.gpa.free(f.field);
            if (f.units) |u| self.gpa.free(u);
        }
        self.aux_fields.deinit(self.gpa);
    }

    /// Register a sensor-provided auxiliary history field.
    pub fn registerAuxField(self: *HistoryCtx, provider: []const u8, name: []const u8, field: []const u8, units: ?[]const u8, strategy: AuxStrategy) !void {
        const owned_provider = try self.gpa.dupe(u8, provider);
        errdefer self.gpa.free(owned_provider);
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_field = try self.gpa.dupe(u8, field);
        errdefer self.gpa.free(owned_field);
        const owned_units = if (units) |u| try self.gpa.dupe(u8, u) else null;
        errdefer if (owned_units) |u| self.gpa.free(u);
        try self.aux_fields.append(self.gpa, .{
            .provider = owned_provider,
            .name = owned_name,
            .field = owned_field,
            .units = owned_units,
            .strategy = strategy,
        });
    }

    /// Record a value for any aux field matching (provider, field).
    pub fn recordAuxValue(self: *HistoryCtx, provider: []const u8, field: []const u8, value: f64) void {
        self.lockAux();
        defer self.unlockAux();
        for (self.aux_fields.items) |*f| {
            if (std.mem.eql(u8, f.provider, provider) and std.mem.eql(u8, f.field, field)) f.record(value);
        }
    }

    fn resetAuxJob(self: *HistoryCtx) void {
        self.lockAux();
        defer self.unlockAux();
        for (self.aux_fields.items) |*f| f.resetJob();
    }

    /// Build the per-job `auxiliary_data` array (only fields that saw a value).
    fn buildAuxData(self: *HistoryCtx, alloc: std.mem.Allocator) std.json.Array {
        self.lockAux();
        defer self.unlockAux();
        var arr: std.json.Array = .init(alloc);
        for (self.aux_fields.items) |*f| {
            if (!f.has_value) continue;
            var o: std.json.ObjectMap = .empty;
            o.put(alloc, "provider", .{ .string = f.provider }) catch continue;
            o.put(alloc, "name", .{ .string = f.name }) catch continue;
            o.put(alloc, "value", .{ .float = f.jobValue() }) catch continue;
            o.put(alloc, "units", if (f.units) |u| .{ .string = u } else .null) catch continue;
            arr.append(.{ .object = o }) catch continue;
        }
        return arr;
    }

    fn accumulateAux(self: *HistoryCtx) void {
        self.lockAux();
        defer self.unlockAux();
        for (self.aux_fields.items) |*f| f.accumulateTotal();
    }

    /// Build the `auxiliary_totals` array across all registered fields.
    pub fn buildAuxTotals(self: *HistoryCtx, alloc: std.mem.Allocator) std.json.Array {
        self.lockAux();
        defer self.unlockAux();
        var arr: std.json.Array = .init(alloc);
        for (self.aux_fields.items) |*f| {
            var o: std.json.ObjectMap = .empty;
            o.put(alloc, "provider", .{ .string = f.provider }) catch continue;
            o.put(alloc, "name", .{ .string = f.name }) catch continue;
            o.put(alloc, "total", .{ .float = f.total }) catch continue;
            o.put(alloc, "units", if (f.units) |u| .{ .string = u } else .null) catch continue;
            arr.append(.{ .object = o }) catch continue;
        }
        return arr;
    }

    fn resetAuxTotals(self: *HistoryCtx) void {
        self.lockAux();
        defer self.unlockAux();
        for (self.aux_fields.items) |*f| f.total = 0;
    }

    /// Called by JobStateCtx (under Core) when a job state transition is
    /// detected. Store failures are logged: an event has no caller to report to.
    pub fn onJobStateChanged(self: *HistoryCtx, event: anytype, prev_ps: std.json.ObjectMap, new_ps: std.json.ObjectMap) void {
        switch (event) {
            .started => {
                // Finish any previous in-progress job.
                if (self.getCurrentJobId() != null) self.finishOrWarn("cancelled", prev_ps);
                self.addJob(new_ps) catch |err|
                    std.debug.print("phobos: warning: history could not add the started job: {}\n", .{err});
            },
            .complete => self.finishOrWarn("completed", new_ps),
            .@"error" => self.finishOrWarn("error", new_ps),
            .cancelled => self.finishOrWarn("cancelled", prev_ps),
            .standby => self.finishOrWarn("cancelled", prev_ps),
            else => {},
        }
    }

    /// Finish the current job, logging a failure (the job then stays
    /// "in_progress" until the next startup marks it interrupted).
    fn finishOrWarn(self: *HistoryCtx, status: []const u8, ps: std.json.ObjectMap) void {
        self.finishJob(status, ps) catch |err|
            std.debug.print("phobos: warning: history could not finish the job as {s}: {}\n", .{ status, err });
    }

    /// Called on Klippy shutdown while a job is active.
    /// Finishes the current job with status "klippy_shutdown".
    pub fn handleKlippyShutdown(self: *HistoryCtx, last_ps: std.json.ObjectMap) void {
        self.finishOrWarn("klippy_shutdown", last_ps);
    }

    /// Called on Klippy disconnect while a job is active.
    /// Finishes the current job with status "klippy_disconnect".
    pub fn handleKlippyDisconnect(self: *HistoryCtx, last_ps: std.json.ObjectMap) void {
        self.finishOrWarn("klippy_disconnect", last_ps);
    }

    /// Called on server exit while a job is active.
    /// Finishes the current job with status "server_exit".
    pub fn handleServerExit(self: *HistoryCtx, last_ps: std.json.ObjectMap) void {
        self.finishOrWarn("server_exit", last_ps);
    }

    /// On startup, mark any stale "in_progress" jobs as "interrupted".
    /// Mirrors Moonraker's component_init interrupted-job detection.
    pub fn markInterruptedJobs(self: *HistoryCtx) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const all = try loadAllJobs(self, a);
        for (all) |je| {
            if (je.val != .object) continue;
            const status_val = je.val.object.get("status") orelse continue;
            if (status_val != .string) continue;
            if (!std.mem.eql(u8, status_val.string, "in_progress")) continue;

            var updated: std.json.ObjectMap = .empty;
            var it = je.val.object.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "status")) {
                    try updated.put(a, "status", .{ .string = "interrupted" });
                } else {
                    try updated.put(a, kv.key_ptr.*, kv.value_ptr.*);
                }
            }
            // insertItem, not updateItem: a migrated job_history row has no KV
            // record to update; the KV copy shadows the row.
            try self.store.insertItem(a, ns_history, je.key, .{ .object = updated });
        }
    }

    /// Create a new job record from print_stats and persist it.
    fn addJob(self: *HistoryCtx, pstats: std.json.ObjectMap) !void {
        // Reset per-job auxiliary-field accumulators at the start of the job.
        self.resetAuxJob();
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const filename = if (pstats.get("filename")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";
        const start_time = self.nowSecs();

        // Build job record.
        var job_obj: std.json.ObjectMap = .empty;
        try job_obj.put(a, "filename", .{ .string = filename });
        try job_obj.put(a, "status", .{ .string = "in_progress" });
        try job_obj.put(a, "start_time", .{ .float = start_time });
        try job_obj.put(a, "end_time", .{ .float = 0.0 });
        try job_obj.put(a, "print_duration", .{ .float = 0.0 });
        try job_obj.put(a, "total_duration", .{ .float = 0.0 });
        try job_obj.put(a, "filament_used", .{ .float = 0.0 });
        try job_obj.put(a, "metadata", .{ .object = .empty });
        try job_obj.put(a, "auxiliary_data", .{ .array = .init(a) });
        try job_obj.put(a, "user", .{ .string = self.job_user });

        const job_id_u64 = try self.nextJobId(a);

        var id_buf: [16]u8 = undefined;
        const job_id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_u64});

        try self.store.insertItem(a, ns_history, job_id_str, .{ .object = job_obj });
        // Only track the job once it is durably stored — otherwise a failed
        // insert would leave current_job_id pointing at a record finishJob can
        // never load, silently dropping the subsequent finish.
        self.setCurrentJobId(job_id_u64);

        // Update totals.
        self.incrementTotalJobs(a) catch |err|
            std.debug.print("phobos: warning: history total_jobs update failed: {}\n", .{err});

        // Emit.
        const prepped = try prepJob(self, a, .{ .object = job_obj }, job_id_str);
        emitHistoryChanged(self, a, "added", prepped);
    }

    /// Finish the current in-progress job with the given status.
    fn finishJob(self: *HistoryCtx, status: []const u8, pstats: std.json.ObjectMap) !void {
        const job_id_u64 = self.getCurrentJobId() orelse return;
        // NB: do NOT clear current_job_id until the record is durably updated
        // below. Clearing it up-front meant a transient store error left the job
        // marked "in_progress" forever (its id already discarded) — silent loss.

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var id_buf: [16]u8 = undefined;
        const job_id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_u64});

        // A record that vanished or was overwritten with a non-object (the
        // history namespace is writable through /server/database/item) leaves
        // nothing to finish; a retry could never succeed, so drop the id.
        const stored = switch ((try self.store.getItem(a, ns_history, job_id_str)) orelse .null) {
            .object => |o| o,
            else => {
                self.setCurrentJobId(null);
                return;
            },
        };

        // Stats guard (matches Moonraker finish_job guard):
        // discard print_stats if they belong to a different job or were reset.
        var p = pstats;
        const stored_fn = if (stored.get("filename")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        const stored_td: f64 = switch (stored.get("total_duration") orelse std.json.Value{ .float = 0.0 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        };
        const pstat_fn = if (pstats.get("filename")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        const pstat_td: f64 = switch (pstats.get("total_duration") orelse std.json.Value{ .float = 0.0 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        };
        if (!std.mem.eql(u8, stored_fn, pstat_fn) or pstat_td < stored_td) {
            p = .empty;
        }

        var job_obj: std.json.ObjectMap = .empty;
        if (stored.get("start_time")) |st| {
            try job_obj.put(a, "start_time", st);
        } else {
            try job_obj.put(a, "start_time", .{ .float = 0.0 });
        }

        const end_time = self.nowSecs();
        const total_duration: f64 = switch (p.get("total_duration") orelse std.json.Value{ .float = 0.0 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        };
        const print_duration: f64 = switch (p.get("print_duration") orelse std.json.Value{ .float = 0.0 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        };
        const filament_used: f64 = switch (p.get("filament_used") orelse std.json.Value{ .float = 0.0 }) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0.0,
        };
        const filename = if (p.get("filename")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else stored_fn;

        // Update job record.
        try job_obj.put(a, "filename", .{ .string = filename });
        try job_obj.put(a, "status", .{ .string = status });
        try job_obj.put(a, "end_time", .{ .float = end_time });
        try job_obj.put(a, "print_duration", .{ .float = print_duration });
        try job_obj.put(a, "total_duration", .{ .float = total_duration });
        try job_obj.put(a, "filament_used", .{ .float = filament_used });
        try job_obj.put(a, "metadata", .{ .object = .empty });
        try job_obj.put(a, "auxiliary_data", .{ .array = self.buildAuxData(a) });
        try job_obj.put(a, "user", .{ .string = self.job_user });

        try self.store.updateItem(a, ns_history, job_id_str, .{ .object = job_obj });
        // The finished record is now durable — safe to drop the in-progress id.
        self.setCurrentJobId(null);
        // Fold this job's aux values into the cross-job totals.
        self.accumulateAux();

        // Update totals: total_time += total_duration, total_print_time += print_duration,
        // total_filament_used += filament_used, longest_job/longest_print = max.
        self.updateTotalsOnFinish(a, total_duration, print_duration, filament_used) catch |err|
            std.debug.print("phobos: warning: history totals update failed: {}\n", .{err});

        // Emit.
        const prepped = try prepJob(self, a, .{ .object = job_obj }, job_id_str);
        emitHistoryChanged(self, a, "finished", prepped);
    }

    /// Find the next available job ID (max existing + 1, or 1 if none).
    fn nextJobId(self: *HistoryCtx, alloc: std.mem.Allocator) !u64 {
        const all = try loadAllJobs(self, alloc);
        var max_id: u64 = 0;
        for (all) |je| {
            const id = std.fmt.parseInt(u64, je.key, 16) catch continue;
            if (id > max_id) max_id = id;
        }
        return max_id + 1;
    }

    /// Increment the total_jobs counter in totals.
    fn incrementTotalJobs(self: *HistoryCtx, alloc: std.mem.Allocator) !void {
        const totals = try loadTotals(self, alloc);
        if (totals == .object) {
            if (totals.object.get("total_jobs")) |v| {
                const cur: f64 = switch (v) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => 0.0,
                };
                var new_obj: std.json.ObjectMap = .empty;
                var it = totals.object.iterator();
                while (it.next()) |kv| {
                    try new_obj.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
                }
                try new_obj.put(alloc, "total_jobs", .{ .float = cur + 1.0 });
                try saveTotals(self, alloc, .{ .object = new_obj });
            }
        }
    }

    /// Update totals after a job finishes.
    fn updateTotalsOnFinish(self: *HistoryCtx, alloc: std.mem.Allocator, total_dur: f64, print_dur: f64, filament: f64) !void {
        const totals = try loadTotals(self, alloc);
        if (totals != .object) return;

        var new_obj: std.json.ObjectMap = .empty;
        var it = totals.object.iterator();
        while (it.next()) |kv| {
            try new_obj.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
        }

        // total_time
        if (new_obj.get("total_time")) |v| {
            const cur: f64 = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            };
            try new_obj.put(alloc, "total_time", .{ .float = cur + total_dur });
        }
        // total_print_time
        if (new_obj.get("total_print_time")) |v| {
            const cur: f64 = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            };
            try new_obj.put(alloc, "total_print_time", .{ .float = cur + print_dur });
        }
        // total_filament_used
        if (new_obj.get("total_filament_used")) |v| {
            const cur: f64 = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            };
            try new_obj.put(alloc, "total_filament_used", .{ .float = cur + filament });
        }
        // longest_job
        if (new_obj.get("longest_job")) |v| {
            const cur: f64 = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            };
            if (total_dur > cur) {
                try new_obj.put(alloc, "longest_job", .{ .float = total_dur });
            }
        }
        // longest_print
        if (new_obj.get("longest_print")) |v| {
            const cur: f64 = switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 0.0,
            };
            if (print_dur > cur) {
                try new_obj.put(alloc, "longest_print", .{ .float = print_dur });
            }
        }
        try saveTotals(self, alloc, .{ .object = new_obj });
    }

    fn nowSecs(self: *HistoryCtx) f64 {
        return clock.wallSeconds(self.clock_io);
    }
};

// ---------------------------------------------------------------------------
// Namespace constants
// ---------------------------------------------------------------------------

pub const ns_history: [:0]const u8 = "history";
pub const ns_totals: [:0]const u8 = "history_totals";
pub const totals_key = "totals";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a base-totals JSON object (zero-valued).
fn buildBaseTotals(alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (base_totals_keys, base_totals_values) |k, v| {
        try obj.put(alloc, k, .{ .float = v });
    }
    return .{ .object = obj };
}

/// Load totals from store, falling back to base totals on miss.
fn loadTotals(c: *HistoryCtx, alloc: std.mem.Allocator) !std.json.Value {
    const stored = try c.store.getItem(alloc, ns_totals, totals_key);
    if (stored) |v| return v;
    return buildBaseTotals(alloc);
}

/// Save totals to store.
fn saveTotals(c: *HistoryCtx, alloc: std.mem.Allocator, totals: std.json.Value) !void {
    c.store.insertItem(alloc, ns_totals, totals_key, totals) catch |err| switch (err) {
        // transient store failure: don't propagate, but surface it — otherwise
        // cumulative print stats silently stop persisting with no signal.
        ds.Error.BackendError => std.debug.print("phobos: warning: history totals persist failed: {} — cumulative stats may be stale\n", .{err}),
        else => return err,
    };
}

/// Collect all job records from the history namespace, sorted by job_id.
/// Returns slice of {hex_key, job_value} pairs, sorted ascending by integer key.
const JobEntry = struct { key: []const u8, val: std.json.Value };

/// A store error propagates: an empty list would make `nextJobId` reuse an
/// existing id and overwrite that job.
fn loadAllJobs(c: *HistoryCtx, alloc: std.mem.Allocator) ![]JobEntry {
    switch (try c.store.getNamespace(alloc, ns_history)) {
        .object => |obj| {
            var entries: std.ArrayList(JobEntry) = .empty;
            var it = obj.iterator();
            while (it.next()) |kv| {
                // only include numeric-hex keys (job records, not meta-keys)
                _ = std.fmt.parseInt(u64, kv.key_ptr.*, 16) catch continue;
                try entries.append(alloc, .{ .key = kv.key_ptr.*, .val = kv.value_ptr.* });
            }
            // sort ascending by integer key
            std.sort.pdq(JobEntry, entries.items, {}, struct {
                fn lt(_: void, a: JobEntry, b: JobEntry) bool {
                    const ia = std.fmt.parseInt(u64, a.key, 16) catch 0;
                    const ib = std.fmt.parseInt(u64, b.key, 16) catch 0;
                    return ia < ib;
                }
            }.lt);
            return entries.toOwnedSlice(alloc);
        },
        else => return &.{},
    }
}

/// Prep a stored job object for the API response (history.py
/// `_prep_requested_job`): drop instance_id, add job_id and whether the gcode
/// file still exists. Moonraker also compares `metadata.modified` with the
/// file's mtime; phobos jobs store empty metadata, so only presence is checked.
fn prepJob(c: *const HistoryCtx, alloc: std.mem.Allocator, job_val: std.json.Value, job_id: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // Copy existing fields
    switch (job_val) {
        .object => |src| {
            var it = src.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, "instance_id")) continue;
                try obj.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
            }
        },
        else => {},
    }
    const filename: []const u8 = switch (obj.get("filename") orelse .null) {
        .string => |s| s,
        else => "",
    };
    try obj.put(alloc, "job_id", .{ .string = job_id });
    try obj.put(alloc, "exists", .{ .bool = filename.len > 0 and c.fileExists(filename) });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/history/list
pub fn handleList(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));

    const limit_raw = ((try webreq.optional(i64, params, "limit")) orelse 50);
    const start = ((try webreq.optional(i64, params, "start")) orelse 0);
    const since = ((try webreq.optional(f64, params, "since")) orelse -1.0);
    const before = ((try webreq.optional(f64, params, "before")) orelse -1.0);
    const order_str_raw = ((try webreq.optional([]const u8, params, "order"))) orelse "desc";
    // Normalize: uppercase
    var order_buf: [8]u8 = undefined;
    const order_len = @min(order_str_raw.len, order_buf.len);
    const order = std.ascii.upperString(&order_buf, order_str_raw[0..order_len]);
    if (!std.mem.eql(u8, order, "ASC") and !std.mem.eql(u8, order, "DESC")) {
        return error.InvalidParams;
    }
    const ascending = std.mem.eql(u8, order, "ASC");

    const all_jobs = try loadAllJobs(c, alloc);

    // Filter by since/before
    var filtered: std.ArrayList(JobEntry) = .empty;
    for (all_jobs) |je| {
        const job_obj = switch (je.val) {
            .object => |o| o,
            else => continue,
        };
        if (since >= 0) {
            const st = switch (job_obj.get("start_time") orelse .null) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => -1.0,
            };
            if (st <= since) continue;
        }
        if (before >= 0) {
            const et = switch (job_obj.get("end_time") orelse .null) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => -1.0,
            };
            if (et < 0 or et >= before) continue;
        }
        try filtered.append(alloc, je);
    }

    // Reverse if DESC
    if (!ascending) {
        std.mem.reverse(JobEntry, filtered.items);
    }

    // Moonraker applies `start` only with a positive `limit` (history.py
    // "LIMIT ? OFFSET ?"); SQLite treats a negative OFFSET as 0. lossyCast
    // clamps i64 values that a 32-bit usize cannot hold.
    var remaining = filtered.items;
    if (limit_raw > 0) {
        remaining = remaining[@min(std.math.lossyCast(usize, start), remaining.len)..];
        remaining = remaining[0..@min(std.math.lossyCast(usize, limit_raw), remaining.len)];
    }

    var jobs_arr: std.json.Array = .init(alloc);
    for (remaining) |je| {
        const prepped = try prepJob(c, alloc, je.val, je.key);
        try jobs_arr.append(prepped);
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "count", .{ .integer = @intCast(jobs_arr.items.len) });
    try obj.put(alloc, "jobs", .{ .array = jobs_arr });
    return .{ .object = obj };
}

/// GET /server/history/totals
pub fn handleTotals(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    const totals = try loadTotals(c, alloc);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "job_totals", totals);
    try obj.put(alloc, "auxiliary_totals", .{ .array = c.buildAuxTotals(alloc) });
    return .{ .object = obj };
}

/// POST /server/history/reset_totals
pub fn handleResetTotals(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    // Refuse to reset while a job is running — otherwise the in-flight job's
    // accounting is folded into a half-cleared total (Moonraker raises
    // "Job in progress, cannot reset totals").
    if (c.getCurrentJobId() != null) return error.InvalidParams;
    const last_totals = try loadTotals(c, alloc);
    const new_totals = try buildBaseTotals(alloc);
    try saveTotals(c, alloc, new_totals);
    // Snapshot aux totals before clearing them.
    const last_aux = c.buildAuxTotals(alloc);
    c.resetAuxTotals();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "last_totals", last_totals);
    try obj.put(alloc, "last_auxiliary_totals", .{ .array = last_aux });
    return .{ .object = obj };
}

/// GET /server/history/job — get by uid
pub fn handleGetJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    const uid_raw = ((try webreq.optional([]const u8, params, "uid"))) orelse return error.InvalidParams;
    // Normalize uid to 6-char uppercase hex
    const job_id_int = std.fmt.parseInt(u64, uid_raw, 16) catch return error.InvalidParams;
    var id_buf: [16]u8 = undefined;
    const job_id_tmp = std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_int}) catch return error.InvalidParams;
    const job_id = try alloc.dupe(u8, job_id_tmp);

    const val = (try c.store.getItem(alloc, ns_history, job_id)) orelse return error.NotFound;
    const prepped = try prepJob(c, alloc, val, job_id);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "job", prepped);
    return .{ .object = obj };
}

/// Multi-verb dispatch for /server/history/job (GET vs DELETE).
/// Called for both "server.history.get_job" and "server.history.delete_job"
/// JSON-RPC methods, and for both HTTP GET/DELETE routes.
/// The transport injects "_method" so we can distinguish.
pub fn handleJobDispatch(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // The transport injects "_method" (HTTP verb or JSON-RPC method name).
    // DELETE is explicit; absent or anything else defaults to GET.
    const is_delete = switch (params) {
        .object => |o| switch (o.get("_method") orelse std.json.Value{ .null = {} }) {
            .string => |s| std.ascii.eqlIgnoreCase(s, "DELETE"),
            else => false,
        },
        else => false,
    };
    if (is_delete) return handleDeleteJob(ctx, params, alloc);
    return handleGetJob(ctx, params, alloc);
}

/// DELETE /server/history/job — delete by uid or all=true
pub fn handleDeleteJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    const all = ((try webreq.optional(bool, params, "all")) orelse false);

    var deleted: std.json.Array = .init(alloc);

    if (all) {
        const all_jobs = try loadAllJobs(c, alloc);
        for (all_jobs) |je| {
            // Capture the prepped job shape before deleting so we can emit
            // the notification with full data. A failed delete is reported,
            // never listed as deleted.
            const prepped = try prepJob(c, alloc, je.val, je.key);
            _ = try c.store.deleteItem(alloc, ns_history, je.key);
            try deleted.append(.{ .string = je.key });
            emitHistoryChanged(c, alloc, "deleted", prepped);
        }
    } else {
        const uid_raw = ((try webreq.optional([]const u8, params, "uid"))) orelse return error.InvalidParams;
        const job_id_int = std.fmt.parseInt(u64, uid_raw, 16) catch return error.InvalidParams;
        var id_buf: [16]u8 = undefined;
        const job_id_tmp = std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_int}) catch return error.InvalidParams;
        const job_id = try alloc.dupe(u8, job_id_tmp);

        // Capture the prepped job before deleting.
        const val = c.store.getItem(alloc, ns_history, job_id) catch |err| switch (err) {
            ds.Error.KeyNotFound, ds.Error.NamespaceNotFound => return error.NotFound,
            else => return err,
        };
        const job_to_emit: ?std.json.Value = if (val) |v| try prepJob(c, alloc, v, job_id) else null;

        _ = c.store.deleteItem(alloc, ns_history, job_id) catch |err| switch (err) {
            ds.Error.KeyNotFound, ds.Error.NamespaceNotFound => return error.NotFound,
            else => return err,
        };
        try deleted.append(.{ .string = job_id });
        if (job_to_emit) |job| emitHistoryChanged(c, alloc, "deleted", job);
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "deleted_jobs", .{ .array = deleted });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Notification emission
// ---------------------------------------------------------------------------

/// Emit `notify_history_changed` with the given action and job payload.
/// Uses emitLocked — handlers run under the held Core lock.
fn emitHistoryChanged(ctx: *HistoryCtx, alloc: std.mem.Allocator, action: []const u8, job: std.json.Value) void {
    const bus = ctx.bus;
    const io = ctx.io orelse return;
    var arr: std.json.Array = .init(alloc);
    var item: std.json.ObjectMap = .empty;
    item.put(alloc, "action", .{ .string = action }) catch return;
    item.put(alloc, "job", job) catch return;
    arr.append(.{ .object = item }) catch return;
    bus.emitLocked(io, notify.names.history_changed, .{ .array = arr }) catch {};
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// Endpoint mapping:
//   /server/history/list        GET only      → "server.history.list"
//   /server/history/totals      GET only      → "server.history.totals"
//   /server/history/reset_totals POST only    → "server.history.reset_totals"
//   /server/history/job         GET+DELETE    → multi-verb → "server.history.get_job"
//                                                              "server.history.delete_job"

pub fn registerHistory(reg: *Registry, ctx: *HistoryCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/history/list", .methods = &.{.GET} },
        c,
        handleList,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/history/totals", .methods = &.{.GET} },
        c,
        handleTotals,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/history/reset_totals", .methods = &.{.POST} },
        c,
        handleResetTotals,
    );
    // GET + DELETE in one call → "server.history.get_job" and
    // "server.history.delete_job"; handleJobDispatch picks the verb from the
    // transport's `_method` param.
    try reg.registerEndpoint(
        .{ .path = "/server/history/job", .methods = &.{ .GET, .DELETE } },
        c,
        handleJobDispatch,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// ---- AuxField tracker ----

test "AuxField: per-strategy job value" {
    var f: AuxField = .{ .provider = "s", .name = "n", .field = "p", .units = null, .strategy = .accumulate };
    f.record(10);
    f.record(5);
    f.record(20);
    try testing.expectEqual(@as(f64, 35), f.jobValue()); // accumulate (sum)
    f.strategy = .maximum;
    try testing.expectEqual(@as(f64, 20), f.jobValue());
    f.strategy = .minimum;
    try testing.expectEqual(@as(f64, 5), f.jobValue());
    f.strategy = .basic;
    try testing.expectEqual(@as(f64, 20), f.jobValue()); // last
    f.strategy = .average;
    try testing.expectEqual(@as(f64, 35.0 / 3.0), f.jobValue());
    f.strategy = .delta;
    try testing.expectEqual(@as(f64, 10), f.jobValue()); // last(20) - first(10)
    f.resetJob();
    try testing.expect(!f.has_value);
    try testing.expectEqual(@as(f64, 0), f.jobValue());
}

test "AuxField: total accumulation across jobs" {
    var acc: AuxField = .{ .provider = "s", .name = "n", .field = "p", .units = null, .strategy = .accumulate };
    acc.record(10);
    acc.accumulateTotal();
    acc.resetJob();
    acc.record(5);
    acc.accumulateTotal();
    try testing.expectEqual(@as(f64, 15), acc.total);

    var mx: AuxField = .{ .provider = "s", .name = "n", .field = "p", .units = null, .strategy = .maximum };
    mx.record(3);
    mx.accumulateTotal();
    mx.resetJob();
    mx.record(7);
    mx.accumulateTotal();
    mx.resetJob();
    mx.record(2);
    mx.accumulateTotal();
    try testing.expectEqual(@as(f64, 7), mx.total); // max across jobs
}

test "history aux fields: record → job auxiliary_data → totals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(tio);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "", .gpa = testing.allocator };
    defer ctx.deinit();

    try ctx.registerAuxField("chamber", "max_temp", "temperature", "C", .maximum);
    ctx.resetAuxJob();
    ctx.recordAuxValue("chamber", "temperature", 40);
    ctx.recordAuxValue("chamber", "temperature", 55);
    ctx.recordAuxValue("other", "x", 999); // no matching field → ignored

    const aux = ctx.buildAuxData(a);
    try testing.expectEqual(@as(usize, 1), aux.items.len);
    const e = aux.items[0].object;
    try testing.expectEqualStrings("chamber", e.get("provider").?.string);
    try testing.expectEqualStrings("max_temp", e.get("name").?.string);
    try testing.expectEqual(@as(f64, 55), e.get("value").?.float);
    try testing.expectEqualStrings("C", e.get("units").?.string);

    ctx.accumulateAux();
    const totals = ctx.buildAuxTotals(a);
    try testing.expectEqual(@as(usize, 1), totals.items.len);
    try testing.expectEqual(@as(f64, 55), totals.items[0].object.get("total").?.float);

    ctx.resetAuxTotals();
    try testing.expectEqual(@as(f64, 0), ctx.buildAuxTotals(a).items[0].object.get("total").?.float);
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
        // Deep-copy the key so the HashMap owns stable memory even when the
        // caller's buffer goes out of scope (e.g. addJob stack buffer).
        const owned_key = self.alloc.dupe(u8, key) catch return ds.Error.OutOfMemory;
        // Clone the value by serializing to JSON and re-parsing into MemStore-owned
        // memory, so that ObjectMap keys and string values outlive the caller's arena.
        const owned_value = cloneValue(self.alloc, value) catch return ds.Error.OutOfMemory;
        n.data.put(owned_key, owned_value) catch return ds.Error.OutOfMemory;
    }

    fn vtUpdateItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.NamespaceNotFound;
        if (!n.data.contains(key)) return ds.Error.KeyNotFound;
        const owned_value = cloneValue(self.alloc, value) catch return ds.Error.OutOfMemory;
        n.data.put(key, owned_value) catch return ds.Error.OutOfMemory;
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
        while (it.next()) |e| {
            obj.put(arena, e.key_ptr.*, e.value_ptr.*) catch return ds.Error.OutOfMemory;
        }
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

const cloneValue = jv.deepCopy;

// Null NotifyBus stub for tests (no connections needed).
const NullCore = @import("../server/core.zig").Core;
const NullConns = @import("../server/connections.zig").Connections;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn insertJob(mem: *MemStore, alloc: std.mem.Allocator, key: []const u8, job_json: []const u8) !void {
    const v = try std.json.parseFromSlice(std.json.Value, alloc, job_json, .{});
    const ns = try mem.getOrCreate(ns_history);
    try ns.data.put(key, v.value);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "handleList: empty store returns count=0 jobs=[]" {
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

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const result = try handleList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(i64, 0), result.object.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), result.object.get("jobs").?.array.items.len);
}

test "handleList: returns jobs in desc order by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"completed\",\"start_time\":1.0,\"end_time\":2.0}");
    try insertJob(&mem, a, "000002", "{\"filename\":\"b.gcode\",\"status\":\"completed\",\"start_time\":3.0,\"end_time\":4.0}");

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const result = try handleList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(i64, 2), result.object.get("count").?.integer);
    const jobs = result.object.get("jobs").?.array;
    // desc: 000002 first
    try testing.expectEqualStrings("000002", jobs.items[0].object.get("job_id").?.string);
    try testing.expectEqualStrings("000001", jobs.items[1].object.get("job_id").?.string);
}

test "handleList: limit and start params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"completed\",\"start_time\":1.0,\"end_time\":2.0}");
    try insertJob(&mem, a, "000002", "{\"filename\":\"b.gcode\",\"status\":\"completed\",\"start_time\":3.0,\"end_time\":4.0}");
    try insertJob(&mem, a, "000003", "{\"filename\":\"c.gcode\",\"status\":\"completed\",\"start_time\":5.0,\"end_time\":6.0}");

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const p = try mkParams(a, "{\"limit\":1,\"start\":1,\"order\":\"asc\"}");
    const result = try handleList(@ptrCast(&ctx), p, a);
    try testing.expectEqual(@as(i64, 1), result.object.get("count").?.integer);
    const jobs = result.object.get("jobs").?.array;
    try testing.expectEqualStrings("000002", jobs.items[0].object.get("job_id").?.string);
}

test "handleGetJob: retrieves stored job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"test.gcode\",\"status\":\"completed\"}");

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const p = try mkParams(a, "{\"uid\":\"000001\"}");
    const result = try handleGetJob(@ptrCast(&ctx), p, a);
    const job = result.object.get("job").?.object;
    try testing.expectEqualStrings("000001", job.get("job_id").?.string);
    try testing.expectEqualStrings("test.gcode", job.get("filename").?.string);
    try testing.expect(job.get("exists") != null);
}

test "handleGetJob: missing uid → NotFound" {
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

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const p = try mkParams(a, "{\"uid\":\"FFFFFF\"}");
    try testing.expectError(error.NotFound, handleGetJob(@ptrCast(&ctx), p, a));
}

test "handleDeleteJob: single uid removes job" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"x.gcode\",\"status\":\"completed\"}");

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const p = try mkParams(a, "{\"uid\":\"000001\"}");
    const result = try handleDeleteJob(@ptrCast(&ctx), p, a);
    const dj = result.object.get("deleted_jobs").?.array;
    try testing.expectEqual(@as(usize, 1), dj.items.len);
    try testing.expectEqualStrings("000001", dj.items[0].string);
}

test "handleDeleteJob: all=true clears all jobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"completed\"}");
    try insertJob(&mem, a, "000002", "{\"filename\":\"b.gcode\",\"status\":\"completed\"}");

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const p = try mkParams(a, "{\"all\":true}");
    const result = try handleDeleteJob(@ptrCast(&ctx), p, a);
    const dj = result.object.get("deleted_jobs").?.array;
    try testing.expectEqual(@as(usize, 2), dj.items.len);
}

test "handleTotals: returns base totals when none stored" {
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

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const result = try handleTotals(@ptrCast(&ctx), .null, a);
    const jt = result.object.get("job_totals").?.object;
    try testing.expect(jt.get("total_jobs") != null);
    try testing.expectEqual(@as(usize, 0), result.object.get("auxiliary_totals").?.array.items.len);
}

test "handleResetTotals: resets and returns last_totals" {
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

    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    const result = try handleResetTotals(@ptrCast(&ctx), .null, a);
    try testing.expect(result.object.get("last_totals") != null);
    try testing.expect(result.object.get("last_auxiliary_totals") != null);
}

test "handleResetTotals: refuses to reset while a job is in progress" {
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

    // A job is active → reset must be rejected (Moonraker parity), leaving totals
    // untouched so the running job's accounting isn't corrupted.
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = 7, .job_user = "" };
    try testing.expectError(error.InvalidParams, handleResetTotals(@ptrCast(&ctx), .null, a));
}

test "registerHistory: wires expected routes and JSON-RPC methods" {
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
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    try registerHistory(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/history/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/history/totals") != null);
    try testing.expect(reg.lookup(.POST, "/server/history/reset_totals") != null);
    try testing.expect(reg.lookup(.GET, "/server/history/job") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/history/job") != null);

    try testing.expect(d.methods.get("server.history.list") != null);
    try testing.expect(d.methods.get("server.history.totals") != null);
    try testing.expect(d.methods.get("server.history.reset_totals") != null);
    // Multi-verb /server/history/job derives get_job and delete_job
    try testing.expect(d.methods.get("server.history.get_job") != null);
    try testing.expect(d.methods.get("server.history.delete_job") != null);
}

// ---------------------------------------------------------------------------
// Live job tracking tests (onJobStateChanged → addJob / finishJob)
// ---------------------------------------------------------------------------

const JobEvent = enum {
    standby,
    started,
    paused,
    resumed,
    complete,
    @"error",
    cancelled,
};

test "onJobStateChanged started: creates job, sets current_job_id, emits added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "live_test.gcode" });

    ctx.onJobStateChanged(JobEvent.started, .empty, ps);

    // current_job_id should be set.
    try testing.expect(ctx.current_job_id != null);
    // The job should be stored in the history namespace.
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{ctx.current_job_id.?});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
}

test "onJobStateChanged complete: finishes job, clears current_job_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    // First start a job.
    var ps_start: std.json.ObjectMap = .empty;
    try ps_start.put(a, "filename", .{ .string = "live_test.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps_start);

    const job_id = ctx.current_job_id.?;

    // Now complete it.
    var ps_done: std.json.ObjectMap = .empty;
    try ps_done.put(a, "filename", .{ .string = "live_test.gcode" });
    try ps_done.put(a, "total_duration", .{ .float = 3600.0 });
    try ps_done.put(a, "print_duration", .{ .float = 3500.0 });
    try ps_done.put(a, "filament_used", .{ .float = 42.5 });

    ctx.onJobStateChanged(JobEvent.complete, ps_start, ps_done);

    // current_job_id should be cleared.
    try testing.expect(ctx.current_job_id == null);

    // The stored job should have status "completed".
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
    try testing.expectEqualStrings("completed", stored.?.object.get("status").?.string);
    try testing.expect(stored.?.object.get("total_duration").?.float == 3600.0);
}

test "onJobStateChanged started when previous in-progress: cancels previous, starts new" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    // Start first job.
    var ps1: std.json.ObjectMap = .empty;
    try ps1.put(a, "filename", .{ .string = "first.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps1);
    const first_id = ctx.current_job_id.?;

    // Start second job — should cancel first.
    var ps2: std.json.ObjectMap = .empty;
    try ps2.put(a, "filename", .{ .string = "second.gcode" });
    ctx.onJobStateChanged(JobEvent.started, ps1, ps2);

    // First job should now be "cancelled".
    var id_buf1: [16]u8 = undefined;
    const id_str1 = try std.fmt.bufPrint(&id_buf1, "{X:0>6}", .{first_id});
    const stored1 = try mem.dataStore().getItem(a, "history", id_str1);
    try testing.expect(stored1 != null);
    try testing.expectEqualStrings("cancelled", stored1.?.object.get("status").?.string);

    // Second job should be "in_progress" with a different job id.
    try testing.expect(ctx.current_job_id != null);
    try testing.expect(ctx.current_job_id.? != first_id);
}

test "onJobStateChanged error: finishes job with error status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "fail.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    const job_id = ctx.current_job_id.?;

    ctx.onJobStateChanged(JobEvent.@"error", ps, ps);

    try testing.expect(ctx.current_job_id == null);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expectEqualStrings("error", stored.?.object.get("status").?.string);
}

test "onJobStateChanged paused/resumed: no-op in history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "pauseme.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    const job_id = ctx.current_job_id.?;

    // Pause — should be no-op (current_job_id stays set, no new storage).
    ctx.onJobStateChanged(JobEvent.paused, ps, ps);
    try testing.expect(ctx.current_job_id != null);

    // Resume — also no-op.
    ctx.onJobStateChanged(JobEvent.resumed, ps, ps);
    try testing.expect(ctx.current_job_id != null);

    // Job is still in_progress.
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expectEqualStrings("in_progress", stored.?.object.get("status").?.string);
}

test "handleKlippyShutdown: finishes in-progress job as klippy_shutdown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "print.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    const job_id = ctx.current_job_id.?;

    var last_ps: std.json.ObjectMap = .empty;
    try last_ps.put(a, "filename", .{ .string = "print.gcode" });
    try last_ps.put(a, "total_duration", .{ .float = 300.0 });
    try last_ps.put(a, "print_duration", .{ .float = 250.0 });
    try last_ps.put(a, "filament_used", .{ .float = 12.5 });
    ctx.handleKlippyShutdown(last_ps);

    try testing.expectEqual(@as(?u64, null), ctx.current_job_id);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
    try testing.expectEqualStrings("klippy_shutdown", stored.?.object.get("status").?.string);
    try testing.expectEqual(@as(f64, 300.0), stored.?.object.get("total_duration").?.float);
}

test "handleKlippyDisconnect: finishes in-progress job as klippy_disconnect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "print.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    const job_id = ctx.current_job_id.?;

    var last_ps: std.json.ObjectMap = .empty;
    try last_ps.put(a, "filename", .{ .string = "print.gcode" });
    try last_ps.put(a, "total_duration", .{ .float = 150.0 });
    ctx.handleKlippyDisconnect(last_ps);

    try testing.expectEqual(@as(?u64, null), ctx.current_job_id);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
    try testing.expectEqualStrings("klippy_disconnect", stored.?.object.get("status").?.string);
}

test "handleServerExit: finishes in-progress job as server_exit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "print.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    const job_id = ctx.current_job_id.?;

    var last_ps: std.json.ObjectMap = .empty;
    try last_ps.put(a, "filename", .{ .string = "print.gcode" });
    try last_ps.put(a, "total_duration", .{ .float = 500.0 });
    ctx.handleServerExit(last_ps);

    try testing.expectEqual(@as(?u64, null), ctx.current_job_id);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
    try testing.expectEqualStrings("server_exit", stored.?.object.get("status").?.string);
}

test "handleKlippyShutdown with no in-progress job is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    const last_ps: std.json.ObjectMap = .empty;
    ctx.handleKlippyShutdown(last_ps);
    try testing.expectEqual(@as(?u64, null), ctx.current_job_id);
}

test "markInterruptedJobs: marks in_progress as interrupted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var job_obj: std.json.ObjectMap = .empty;
    try job_obj.put(a, "filename", .{ .string = "stale.gcode" });
    try job_obj.put(a, "status", .{ .string = "in_progress" });
    try job_obj.put(a, "start_time", .{ .float = 1000.0 });
    try job_obj.put(a, "end_time", .{ .float = 0.0 });
    try job_obj.put(a, "print_duration", .{ .float = 0.0 });
    try job_obj.put(a, "total_duration", .{ .float = 0.0 });
    try job_obj.put(a, "filament_used", .{ .float = 0.0 });
    try job_obj.put(a, "metadata", .{ .object = .empty });
    try job_obj.put(a, "auxiliary_data", .{ .array = .init(a) });
    try job_obj.put(a, "user", .{ .string = "" });
    try mem.dataStore().insertItem(a, "history", "000001", .{ .object = job_obj });

    var done_obj: std.json.ObjectMap = .empty;
    try done_obj.put(a, "filename", .{ .string = "done.gcode" });
    try done_obj.put(a, "status", .{ .string = "completed" });
    try done_obj.put(a, "start_time", .{ .float = 500.0 });
    try done_obj.put(a, "end_time", .{ .float = 1000.0 });
    try done_obj.put(a, "print_duration", .{ .float = 400.0 });
    try done_obj.put(a, "total_duration", .{ .float = 500.0 });
    try done_obj.put(a, "filament_used", .{ .float = 10.0 });
    try done_obj.put(a, "metadata", .{ .object = .empty });
    try done_obj.put(a, "auxiliary_data", .{ .array = .init(a) });
    try done_obj.put(a, "user", .{ .string = "" });
    try mem.dataStore().insertItem(a, "history", "000002", .{ .object = done_obj });

    try ctx.markInterruptedJobs();

    const stale = try mem.dataStore().getItem(a, "history", "000001");
    try testing.expect(stale != null);
    try testing.expectEqualStrings("interrupted", stale.?.object.get("status").?.string);

    const done = try mem.dataStore().getItem(a, "history", "000002");
    try testing.expect(done != null);
    try testing.expectEqualStrings("completed", done.?.object.get("status").?.string);
}

test "markInterruptedJobs: no in_progress jobs is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    try ctx.markInterruptedJobs();
}

test "finishJob: a non-object history record clears the job instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "a.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{ctx.current_job_id.?});
    // POST /server/database/item may overwrite the running job's record.
    try mem.dataStore().insertItem(a, ns_history, id_str, .{ .integer = 1 });
    ctx.onJobStateChanged(JobEvent.complete, ps, ps);
    try testing.expect(ctx.current_job_id == null);
    try testing.expectEqual(@as(i64, 1), (try mem.dataStore().getItem(a, ns_history, id_str)).?.integer);
}

test "handleList: start applies only with a positive limit and is clamped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"start_time\":1.0,\"end_time\":2.0}");
    try insertJob(&mem, a, "000002", "{\"filename\":\"b.gcode\",\"start_time\":3.0,\"end_time\":4.0}");
    try insertJob(&mem, a, "000003", "{\"filename\":\"c.gcode\",\"start_time\":5.0,\"end_time\":6.0}");
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    const cases = [_]struct { params: []const u8, count: i64 }{
        .{ .params = "{\"limit\":0,\"start\":2}", .count = 3 },
        .{ .params = "{\"limit\":-1,\"start\":2}", .count = 3 },
        .{ .params = "{\"limit\":2,\"start\":5000000000}", .count = 0 },
        .{ .params = "{\"limit\":5000000000,\"start\":-3}", .count = 3 },
    };
    for (cases) |case| {
        const result = try handleList(@ptrCast(&ctx), try mkParams(a, case.params), a);
        try testing.expectEqual(case.count, result.object.get("count").?.integer);
    }
}

test "history handlers report store failures instead of empty results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\"}");
    const failing = struct {
        fn deleteItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!std.json.Value {
            return ds.Error.BackendError;
        }
        fn getNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds.Error!std.json.Value {
            return ds.Error.BackendError;
        }
    };
    var bus: NotifyBus = undefined;

    var no_delete = MemStore.vtable;
    no_delete.deleteItem = failing.deleteItem;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = .{ .ctx = &mem, .vtable = &no_delete }, .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
    try testing.expectError(ds.Error.BackendError, handleDeleteJob(@ptrCast(&ctx), try mkParams(a, "{\"all\":true}"), a));

    var no_read = MemStore.vtable;
    no_read.getNamespace = failing.getNamespace;
    ctx.store = .{ .ctx = &mem, .vtable = &no_read };
    try testing.expectError(ds.Error.BackendError, handleList(@ptrCast(&ctx), .null, a));
    // A new job must not reuse an id while the existing ids are unreadable.
    var ps: std.json.ObjectMap = .empty;
    try ps.put(a, "filename", .{ .string = "b.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps);
    try testing.expect(ctx.current_job_id == null);
    try testing.expectEqualStrings("a.gcode", (try mem.dataStore().getItem(a, ns_history, "000001")).?.object.get("filename").?.string);
}

test "prepJob: exists reports whether the gcode file is present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertJob(&mem, a, "000001", "{\"filename\":\"here.gcode\"}");
    try insertJob(&mem, a, "000002", "{\"filename\":\"gone.gcode\"}");
    const files = struct {
        fn exists(_: *anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "here.gcode");
        }
    };
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "", .file_check = files.exists, .file_check_ctx = &mem };
    const result = try handleList(@ptrCast(&ctx), try mkParams(a, "{\"order\":\"asc\"}"), a);
    const jobs = result.object.get("jobs").?.array.items;
    try testing.expect(jobs[0].object.get("exists").?.bool);
    try testing.expect(!jobs[1].object.get("exists").?.bool);
}

test "finishJob stats guard: discards stats with wrong filename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps_start: std.json.ObjectMap = .empty;
    try ps_start.put(a, "filename", .{ .string = "original.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps_start);
    const job_id = ctx.current_job_id.?;

    var wrong_ps: std.json.ObjectMap = .empty;
    try wrong_ps.put(a, "filename", .{ .string = "different.gcode" });
    try wrong_ps.put(a, "total_duration", .{ .float = 999.0 });
    try wrong_ps.put(a, "print_duration", .{ .float = 888.0 });
    try wrong_ps.put(a, "filament_used", .{ .float = 777.0 });
    ctx.onJobStateChanged(JobEvent.complete, wrong_ps, wrong_ps);

    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    const stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(stored != null);
    try testing.expectEqualStrings("original.gcode", stored.?.object.get("filename").?.string);
    try testing.expectEqual(@as(f64, 0.0), stored.?.object.get("total_duration").?.float);
    try testing.expectEqual(@as(f64, 0.0), stored.?.object.get("print_duration").?.float);
    try testing.expectEqual(@as(f64, 0.0), stored.?.object.get("filament_used").?.float);
}

test "finishJob stats guard: discards stats when total_duration went backwards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var bus: NotifyBus = undefined;
    var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

    var ps_start: std.json.ObjectMap = .empty;
    try ps_start.put(a, "filename", .{ .string = "print.gcode" });
    ctx.onJobStateChanged(JobEvent.started, .empty, ps_start);
    const job_id = ctx.current_job_id.?;

    // Manually update the stored job to have a higher total_duration.
    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id});
    var stored = try mem.dataStore().getItem(a, "history", id_str);
    try stored.?.object.put(a, "total_duration", .{ .float = 500.0 });
    try mem.dataStore().updateItem(a, "history", id_str, stored.?);

    // Finish with stats that have lower total_duration (reset).
    var reset_ps: std.json.ObjectMap = .empty;
    try reset_ps.put(a, "filename", .{ .string = "print.gcode" });
    try reset_ps.put(a, "total_duration", .{ .float = 100.0 });
    try reset_ps.put(a, "print_duration", .{ .float = 90.0 });
    ctx.onJobStateChanged(JobEvent.complete, reset_ps, reset_ps);

    const final_stored = try mem.dataStore().getItem(a, "history", id_str);
    try testing.expect(final_stored != null);
    try testing.expectEqual(@as(f64, 0.0), final_stored.?.object.get("total_duration").?.float);
    try testing.expectEqual(@as(f64, 0.0), final_stored.?.object.get("print_duration").?.float);
}

test "fuzz handleKlippyShutdown/Disconnect/ServerExit: never panics" {
    const Runner = struct {
        fn run() void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var bus: NotifyBus = undefined;
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var ps: std.json.ObjectMap = .empty;
            ps.put(a, "filename", .{ .string = "fuzz.gcode" }) catch {};
            ctx.onJobStateChanged(JobEvent.started, .empty, ps);

            var stats: std.json.ObjectMap = .empty;
            stats.put(a, "filename", .{ .string = "fuzz.gcode" }) catch {};

            ctx.handleKlippyShutdown(stats);
            ctx.current_job_id = null;

            // Restart and try disconnect.
            ctx.onJobStateChanged(JobEvent.started, .empty, ps);
            ctx.handleKlippyDisconnect(stats);
            ctx.current_job_id = null;

            // Restart and try server exit.
            ctx.onJobStateChanged(JobEvent.started, .empty, ps);
            ctx.handleServerExit(stats);
            ctx.current_job_id = null;

            // markInterruptedJobs on empty store should not panic.
            ctx.markInterruptedJobs() catch {};
        }
    }.run;
    Runner();
}

// ---------------------------------------------------------------------------
// Fuzz tests

test "fuzz onJobStateChanged: never panics on arbitrary state transitions" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var bus: NotifyBus = undefined;
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            const events = [_]JobEvent{ .standby, .started, .paused, .resumed, .complete, .@"error", .cancelled };
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const event = events[buf[0] % events.len];

            var ps: std.json.ObjectMap = .empty;
            try ps.put(a, "filename", .{ .string = "fuzz.gcode" });
            if (buf[1] & 1 == 0) {
                try ps.put(a, "total_duration", .{ .float = @as(f64, @floatFromInt(buf[2])) });
            }
            if (buf[3] & 1 == 0) {
                try ps.put(a, "print_duration", .{ .float = @as(f64, @floatFromInt(buf[4])) });
            }
            if (buf[5] & 1 == 0) {
                try ps.put(a, "filament_used", .{ .float = @as(f64, @floatFromInt(buf[6])) });
            }

            ctx.onJobStateChanged(event, .empty, ps);
        }
    }.run, .{});
}

// ---------------------------------------------------------------------------
// Fuzz tests (handlers)
// ---------------------------------------------------------------------------

test "fuzz handleList: never panics on arbitrary params" {
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
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"limit\":10,\"start\":0,\"order\":\"asc\"}",
                "{\"limit\":0,\"order\":\"DESC\"}",
                "{\"since\":100.0,\"before\":200.0}",
                "{\"order\":\"invalid\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleList(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleGetJob: never panics on arbitrary params" {
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
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{ "null", "{}", "{\"uid\":\"000001\"}", "{\"uid\":\"ZZZZZZ\"}" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleGetJob(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDeleteJob: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"completed\"}");
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{ "null", "{}", "{\"uid\":\"000001\"}", "{\"all\":true}", "{\"uid\":\"XXXXXX\"}" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleDeleteJob(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleTotals: never panics" {
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
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleTotals(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleResetTotals: never panics" {
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
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleResetTotals(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleJobDispatch: never panics on arbitrary method" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"completed\"}");
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"method\":\"list\"}",
                "{\"method\":\"get_job\"}",
                "{\"method\":\"delete_job\"}",
                "{\"method\":\"totals\"}",
                "{\"method\":\"reset_totals\"}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleJobDispatch(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz markInterruptedJobs: never panics" {
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
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = HistoryCtx{ .clock_io = std.testing.io, .store = mem.dataStore(), .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            // Optionally insert in-progress jobs.
            if (buf[0] & 3 == 0) {
                try insertJob(&mem, a, "000001", "{\"filename\":\"a.gcode\",\"status\":\"in_progress\"}");
            }
            if (buf[1] & 3 == 0) {
                try insertJob(&mem, a, "000002", "{\"filename\":\"b.gcode\",\"status\":\"in_progress\"}");
            }
            if (buf[2] & 3 == 0) {
                try insertJob(&mem, a, "000003", "{\"filename\":\"c.gcode\",\"status\":\"completed\"}");
            }
            ctx.markInterruptedJobs() catch {};
        }
    }.run, .{});
}

test "auxiliary field registration cleans up every allocation failure" {
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
    defer db.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn register(alloc: std.mem.Allocator, store: DataStore) !void {
            var bus: NotifyBus = undefined;
            var ctx: HistoryCtx = .{ .clock_io = testing.io, .gpa = alloc, .store = store, .bus = &bus, .io = null, .current_job_id = null, .job_user = "" };
            defer ctx.deinit();
            try ctx.registerAuxField("sensor", "weight", "value", "g", .average);
        }
    }.register, .{db.dataStore()});
}

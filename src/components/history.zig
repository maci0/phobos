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
//! NOTE: Without Klippy there are no live jobs. This component operates purely
//! on stored history. The notify_history_changed notification is emitted when
//! jobs are added/deleted (no live source in this slice, but the shapes are
//! faithful to history.py).
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
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");

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

pub const HistoryCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,

    pub fn setIo(self: *HistoryCtx, io: std.Io) void {
        self.io = io;
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

fn getOptInt(params: std.json.Value, field: []const u8, default: i64) error{InvalidParams}!i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                .string => |s| std.fmt.parseInt(i64, s, 10) catch return default,
                .null => default,
                else => error.InvalidParams,
            };
        },
        else => return default,
    }
}

fn getOptFloat(params: std.json.Value, field: []const u8, default: f64) error{InvalidParams}!f64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default;
            return switch (v) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                .string => |s| std.fmt.parseFloat(f64, s) catch return default,
                .null => default,
                else => error.InvalidParams,
            };
        },
        else => return default,
    }
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
        ds.Error.BackendError => {}, // no-lmdb: silently skip
        else => return err,
    };
}

/// Collect all job records from the history namespace, sorted by job_id.
/// Returns slice of {hex_key, job_value} pairs, sorted ascending by integer key.
const JobEntry = struct { key: []const u8, val: std.json.Value };

fn loadAllJobs(c: *HistoryCtx, alloc: std.mem.Allocator) ![]JobEntry {
    const ns_obj = c.store.getNamespace(alloc, ns_history) catch |err| switch (err) {
        ds.Error.BackendError, ds.Error.NamespaceNotFound => return &.{},
        else => return err,
    };
    switch (ns_obj) {
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

/// Prep a stored job object for the API response: add job_id and exists=false.
fn prepJob(alloc: std.mem.Allocator, job_val: std.json.Value, job_id: []const u8) !std.json.Value {
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
    try obj.put(alloc, "job_id", .{ .string = job_id });
    try obj.put(alloc, "exists", .{ .bool = false }); // no file_manager in phobos
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/history/list
pub fn handleList(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));

    const limit_raw = try getOptInt(params, "limit", 50);
    const start = try getOptInt(params, "start", 0);
    const since = try getOptFloat(params, "since", -1.0);
    const before = try getOptFloat(params, "before", -1.0);
    const order_str_raw = (try getOptStr(params, "order")) orelse "desc";
    // Normalize: uppercase
    var order_buf: [8]u8 = undefined;
    const order_len = @min(order_str_raw.len, order_buf.len);
    for (order_str_raw[0..order_len], 0..) |ch, i| {
        order_buf[i] = std.ascii.toUpper(ch);
    }
    const order = order_buf[0..order_len];
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

    // Apply start offset and limit
    const total = filtered.items.len;
    const s: usize = if (start < 0) 0 else @min(@as(usize, @intCast(start)), total);
    var remaining = filtered.items[s..];
    const limit: usize = if (limit_raw <= 0) remaining.len else @min(@as(usize, @intCast(limit_raw)), remaining.len);
    remaining = remaining[0..limit];

    var jobs_arr: std.json.Array = .init(alloc);
    for (remaining) |je| {
        const prepped = try prepJob(alloc, je.val, je.key);
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
    try obj.put(alloc, "auxiliary_totals", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

/// POST /server/history/reset_totals
pub fn handleResetTotals(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    const last_totals = try loadTotals(c, alloc);
    const new_totals = try buildBaseTotals(alloc);
    try saveTotals(c, alloc, new_totals);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "last_totals", last_totals);
    try obj.put(alloc, "last_auxiliary_totals", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

/// GET /server/history/job — get by uid
pub fn handleGetJob(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *HistoryCtx = @ptrCast(@alignCast(ctx));
    const uid_raw = (try getOptStr(params, "uid")) orelse return error.InvalidParams;
    // Normalize uid to 6-char uppercase hex
    const job_id_int = std.fmt.parseInt(u64, uid_raw, 16) catch return error.InvalidParams;
    var id_buf: [16]u8 = undefined;
    const job_id_tmp = std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_int}) catch return error.InvalidParams;
    const job_id = try alloc.dupe(u8, job_id_tmp);

    const val = (try c.store.getItem(alloc, ns_history, job_id)) orelse return error.NotFound;
    const prepped = try prepJob(alloc, val, job_id);
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
    const all = getOptBool(params, "all", false);

    var deleted: std.json.Array = .init(alloc);

    if (all) {
        const all_jobs = try loadAllJobs(c, alloc);
        for (all_jobs) |je| {
            // Capture the prepped job shape before deleting so we can emit
            // the notification with full data.
            const prepped = prepJob(alloc, je.val, je.key) catch null;
            _ = c.store.deleteItem(alloc, ns_history, je.key) catch .null;
            try deleted.append(.{ .string = je.key });
            if (prepped) |job| emitHistoryChanged(c, alloc, "deleted", job);
        }
    } else {
        const uid_raw = (try getOptStr(params, "uid")) orelse return error.InvalidParams;
        const job_id_int = std.fmt.parseInt(u64, uid_raw, 16) catch return error.InvalidParams;
        var id_buf: [16]u8 = undefined;
        const job_id_tmp = std.fmt.bufPrint(&id_buf, "{X:0>6}", .{job_id_int}) catch return error.InvalidParams;
        const job_id = try alloc.dupe(u8, job_id_tmp);

        // Capture the prepped job before deleting.
        const val = c.store.getItem(alloc, ns_history, job_id) catch |err| switch (err) {
            ds.Error.KeyNotFound, ds.Error.NamespaceNotFound => return error.NotFound,
            else => return err,
        };
        const job_to_emit: ?std.json.Value = if (val) |v| prepJob(alloc, v, job_id) catch null else null;

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
    // /server/history/job registers GET and DELETE as a multi-verb pair.
    // The registry's multi=true logic derives:
    //   GET  → "server.history.get_job"
    //   DELETE → "server.history.delete_job"
    // We register both verbs pointing to the same compound handler, which
    // dispatches based on whether a "uid" or "all" param is present.
    // Since the JSON-RPC layer doesn't carry verb info, the caller must use
    // the appropriately named method which routes to this same handler.
    // For HTTP, we also register HTTP-only GET/DELETE so per-verb routes exist.
    // Strategy: register the multi-verb pair with all transports. Both JSON-RPC
    // methods and both HTTP routes point to the same handler; the handler
    // distinguishes GET vs DELETE by presence of params.
    //
    // Actually the cleanest approach matching database.zig: use the multi-verb
    // pair registration to get the two JSON-RPC names, both pointing to the same
    // handler. HTTP GET params include "uid"; DELETE params include "uid" or "all".
    // The handler checks "all" to distinguish.
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

    fn vtUpdateItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.NamespaceNotFound;
        if (!n.data.contains(key)) return ds.Error.KeyNotFound;
        n.data.put(key, value) catch return ds.Error.OutOfMemory;
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
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

    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };
    const result = try handleResetTotals(@ptrCast(&ctx), .null, a);
    try testing.expect(result.object.get("last_totals") != null);
    try testing.expect(result.object.get("last_auxiliary_totals") != null);
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
    var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };

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
// Fuzz tests
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
            var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };

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
            var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };

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
            var ctx = HistoryCtx{ .store = mem.dataStore(), .bus = &bus, .io = null };

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{ "null", "{}", "{\"uid\":\"000001\"}", "{\"all\":true}", "{\"uid\":\"XXXXXX\"}" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleDeleteJob(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

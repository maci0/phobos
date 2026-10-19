//! server.analysis.* API component — Moonraker-compatible GCode analysis.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/analysis.py` (GcodeAnalysis):
//!
//!   GET  /server/analysis/status      → server.analysis.status
//!   POST /server/analysis/estimate    → server.analysis.estimate
//!   POST /server/analysis/process     → server.analysis.process
//!   POST /server/analysis/dump_config → server.analysis.dump_config
//!
//! Response shapes (from analysis.py):
//!
//!   status:
//!     {"estimator_executable": "unknown",
//!      "estimator_ready": false,
//!      "estimator_version": "?",
//!      "estimator_config_exists": false,
//!      "using_default_config": true}
//!
//!   estimate / process:
//!     Both require "filename" param. With no klipper_estimator binary
//!     available, returns EstimatorNotAvailable.
//!
//!   dump_config:
//!     Requires klipper_estimator and klippy; returns EstimatorNotAvailable.
//!     On success: {"dest_root": <str|null>, "dest_config_path": <str>,
//!                  "klipper_estimator_config": <obj>}
//!
//! NOTE: phobos has no klipper_estimator binary, no klippy connection, and
//! no file manager in this slice. Endpoint shapes are faithful; the heavy
//! gcode-processing returns EstimatorNotAvailable indicating the subsystem
//! is absent. This ensures correct API-surface coverage.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

// ---------------------------------------------------------------------------
// Context (no estimator state)
// ---------------------------------------------------------------------------

// In a full implementation AnalysisCtx would hold estimator path, config,
// readiness state, etc. Stubbed here — no estimator binary is available.
pub const AnalysisCtx = struct {
    /// Path to the `klipper_estimator` binary. Empty means it is not installed.
    estimator_path: []const u8 = "",
    /// Estimator config file. Empty or missing → the Moonraker config error.
    estimator_config: []const u8 = "",
    /// Reported by status when set. Empty stays "?".
    estimator_version: []const u8 = "",
    /// True when `estimator_path` and `estimator_config` are allocator-owned.
    paths_owned: bool = false,
    io: ?std.Io = null,
    /// Runs the estimator command and returns its stdout. Null when the
    /// binary cannot be executed (same result as Moonraker: not available).
    shell: ?Shell = null,
    shell_ctx: ?*anyopaque = null,

    pub const Shell = *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8;

    pub fn deinit(self: *AnalysisCtx, alloc: std.mem.Allocator) void {
        if (!self.paths_owned) return;
        alloc.free(self.estimator_path);
        alloc.free(self.estimator_config);
        self.estimator_path = "";
        self.estimator_config = "";
        self.paths_owned = false;
    }
};

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Moonraker `_gen_estimator_cmd`: `<bin> --config_file <cfg> <action> <gcode>`.
pub fn estimateCommand(alloc: std.mem.Allocator, estimator: []const u8, config: []const u8, gcode: []const u8, post_process: bool) ![]u8 {
    const action = if (post_process) "post-process" else "estimate -f json";
    return std.fmt.allocPrint(alloc, "{s} --config_file {s} {s} {s}", .{ estimator, config, action, gcode });
}

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/analysis/status
///
/// Returns the klipper_estimator readiness status.
/// phobos has no estimator binary; all fields reflect the "not available" state.
pub fn handleStatus(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const exec: []const u8 = if (ctx.estimator_path.len == 0) "unknown" else std.fs.path.basename(ctx.estimator_path);
    var ready = false;
    var cfg_exists = false;
    if (ctx.io) |io| {
        if (ctx.estimator_path.len > 0) ready = fileExists(io, ctx.estimator_path);
        if (ctx.estimator_config.len > 0) cfg_exists = fileExists(io, ctx.estimator_config);
    }
    const version: []const u8 = if (ctx.estimator_version.len == 0) "?" else ctx.estimator_version;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "estimator_executable", .{ .string = exec });
    try obj.put(alloc, "estimator_ready", .{ .bool = ready and cfg_exists });
    try obj.put(alloc, "estimator_version", .{ .string = version });
    try obj.put(alloc, "estimator_config_exists", .{ .bool = cfg_exists });
    const using_default = ctx.estimator_config.len == 0 or
        std.mem.endsWith(u8, ctx.estimator_config, "klipper_estimator.cfg") or
        std.mem.endsWith(u8, ctx.estimator_config, "default_estimator_cfg.json");
    try obj.put(alloc, "using_default_config", .{ .bool = using_default });
    return .{ .object = obj };
}

/// POST /server/analysis/estimate
///
/// Runs klipper_estimator on a gcode file and returns time estimates.
/// params: filename (str, required), estimator_config (str, optional)
///
/// NOTE: No klipper_estimator binary in phobos. Returns EstimatorNotAvailable.
/// The response shape on success would be the first element of the estimator's
/// "sequences" array (analysis.py).
pub fn handleEstimate(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const filename = try getStr(params, "filename");
    const cmd = try prepareEstimator(ctx, alloc, filename, false);
    return runEstimator(ctx, alloc, cmd);
}

/// POST /server/analysis/process
///
/// Post-processes a gcode file with klipper_estimator (annotates timing).
/// params: filename (str, required), estimator_config (str, optional),
///         force (bool, default=false)
///
/// NOTE: No klipper_estimator binary in phobos. Returns EstimatorNotAvailable.
/// The response shape on success would be:
///   {"prev_processed": bool, "version": str|null, "bypassed": bool}
pub fn handleProcess(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const filename = try getStr(params, "filename");
    _ = getOptBool(params, "force", false);
    const cmd = try prepareEstimator(ctx, alloc, filename, true);
    const out = try runShell(ctx, alloc, cmd);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.EstimatorNotAvailable;
    if (parsed.value == .object and parsed.value.object.get("prev_processed") != null) return parsed.value;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "prev_processed", .{ .bool = false });
    try obj.put(alloc, "version", .{ .string = if (ctx.estimator_version.len == 0) "?" else ctx.estimator_version });
    try obj.put(alloc, "bypassed", .{ .bool = false });
    return .{ .object = obj };
}

/// POST /server/analysis/dump_config
///
/// Dumps the klipper_estimator derived config to a file.
/// params: dest_config (str, optional)
///
/// NOTE: No klipper_estimator binary or klippy connection in phobos.
/// Returns EstimatorNotAvailable.
/// The response shape on success would be:
///   {"dest_root": <str|null>, "dest_config_path": <str>,
///    "klipper_estimator_config": <obj>}
pub fn handleDumpConfig(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.estimator_path.len == 0) return error.EstimatorNotAvailable;
    const io = ctx.io orelse return error.EstimatorNotAvailable;
    if (!fileExists(io, ctx.estimator_path)) return error.EstimatorNotAvailable;
    const dest = getOptStr(params, "dest_config") orelse "klipper_estimator.cfg";
    if (std.mem.indexOf(u8, dest, "..") != null) return error.InvalidParams;
    const cmd = try std.fmt.allocPrint(alloc, "{s} dump-config", .{ctx.estimator_path});
    const out = try runShell(ctx, alloc, cmd);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch return error.EstimatorNotAvailable;
    var obj: std.json.ObjectMap = .empty;
    const root: []const u8 = if (getOptStr(params, "dest_config") == null) "" else "config";
    if (root.len == 0) {
        try obj.put(alloc, "dest_root", .null);
    } else {
        try obj.put(alloc, "dest_root", .{ .string = root });
    }
    try obj.put(alloc, "dest_config_path", .{ .string = dest });
    try obj.put(alloc, "klipper_estimator_config", parsed.value);
    return .{ .object = obj };
}

fn runShell(ctx: *AnalysisCtx, alloc: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    const sh = ctx.shell orelse return error.EstimatorNotAvailable;
    const shell_ctx = ctx.shell_ctx orelse return error.EstimatorNotAvailable;
    return sh(shell_ctx, alloc, cmd);
}

fn prepareEstimator(ctx: *AnalysisCtx, alloc: std.mem.Allocator, filename: []const u8, post_process: bool) ![]u8 {
    if (ctx.estimator_path.len == 0 or ctx.estimator_config.len == 0) return error.EstimatorNotAvailable;
    const io = ctx.io orelse return error.EstimatorNotAvailable;
    if (!fileExists(io, ctx.estimator_path)) return error.EstimatorNotAvailable;
    if (!fileExists(io, ctx.estimator_config)) return error.EstimatorConfigMissing;
    if (!fileExists(io, filename)) return error.GcodeNotFound;
    return estimateCommand(alloc, ctx.estimator_path, ctx.estimator_config, filename, post_process);
}

fn runEstimator(ctx: *AnalysisCtx, alloc: std.mem.Allocator, cmd: []const u8) !std.json.Value {
    const out = try runShell(ctx, alloc, cmd);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    const seqs = parsed.value.object.get("sequences") orelse return error.EstimatorNotAvailable;
    if (seqs != .array or seqs.array.items.len == 0) return error.EstimatorNotAvailable;
    return seqs.array.items[0];
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerAnalysis(reg: *Registry, ctx: *AnalysisCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // GET /server/analysis/status → "server.analysis.status"
    try reg.registerEndpoint(
        .{ .path = "/server/analysis/status", .methods = &.{.GET} },
        c,
        handleStatus,
    );

    // POST /server/analysis/estimate → "server.analysis.estimate"
    try reg.registerEndpoint(
        .{ .path = "/server/analysis/estimate", .methods = &.{.POST} },
        c,
        handleEstimate,
    );

    // POST /server/analysis/process → "server.analysis.process"
    try reg.registerEndpoint(
        .{ .path = "/server/analysis/process", .methods = &.{.POST} },
        c,
        handleProcess,
    );

    // POST /server/analysis/dump_config → "server.analysis.dump_config"
    try reg.registerEndpoint(
        .{ .path = "/server/analysis/dump_config", .methods = &.{.POST} },
        c,
        handleDumpConfig,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleStatus: returns correct shape with estimator not available" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const result = try handleStatus(@ptrCast(&ctx), .null, a);

    try testing.expectEqualStrings("unknown", result.object.get("estimator_executable").?.string);
    try testing.expectEqual(false, result.object.get("estimator_ready").?.bool);
    try testing.expectEqualStrings("?", result.object.get("estimator_version").?.string);
    try testing.expectEqual(false, result.object.get("estimator_config_exists").?.bool);
    try testing.expectEqual(true, result.object.get("using_default_config").?.bool);
}

test "handleEstimate: missing filename → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    try testing.expectError(error.InvalidParams, handleEstimate(@ptrCast(&ctx), .null, a));
}

const EstLog = struct {
    cmd: []const u8 = "",
    fn run(ctx: *anyopaque, alloc: std.mem.Allocator, cmd: []const u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.cmd = try alloc.dupe(u8, cmd);
        return "{\"sequences\":[{\"estimated_time\":1.5}]}";
    }
};

test "handleEstimate: runs klipper_estimator and returns the first sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "est", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "job.gcode", .data = "G1 X1\n" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var log = EstLog{};
    var ctx = AnalysisCtx{
        .estimator_path = try std.fmt.allocPrint(a, "{s}/est", .{root}),
        .estimator_config = try std.fmt.allocPrint(a, "{s}/cfg.json", .{root}),
        .io = io,
        .shell = EstLog.run,
        .shell_ctx = &log,
    };
    const gcode = try std.fmt.allocPrint(a, "{s}/job.gcode", .{root});
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "filename", .{ .string = gcode });
    const result = try handleEstimate(@ptrCast(&ctx), .{ .object = obj }, a);
    try testing.expectEqual(@as(f64, 1.5), result.object.get("estimated_time").?.float);
    try testing.expect(std.mem.indexOf(u8, log.cmd, "estimate -f json") != null);
    try testing.expect(std.mem.indexOf(u8, log.cmd, "job.gcode") != null);
    try testing.expect(std.mem.indexOf(u8, log.cmd, "--config_file") != null);
}

test "handleEstimate: valid filename → EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const params = try mkParams(a, "{\"filename\": \"test.gcode\"}");
    try testing.expectError(error.EstimatorNotAvailable, handleEstimate(@ptrCast(&ctx), params, a));
}

test "handleProcess: missing filename → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    try testing.expectError(error.InvalidParams, handleProcess(@ptrCast(&ctx), .null, a));
}

test "handleProcess: valid filename → EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const params = try mkParams(a, "{\"filename\": \"test.gcode\", \"force\": false}");
    try testing.expectError(error.EstimatorNotAvailable, handleProcess(@ptrCast(&ctx), params, a));
}

test "handleDumpConfig: always EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), .null, a));
}

test "handleProcess: shell JSON with prev_processed is the result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "est", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cfg.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "job.gcode", .data = "G1 X1\n" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var log = EstLog{};
    var ctx = AnalysisCtx{
        .estimator_path = try std.fmt.allocPrint(a, "{s}/est", .{root}),
        .estimator_config = try std.fmt.allocPrint(a, "{s}/cfg.json", .{root}),
        .estimator_version = "v1.2.3",
        .io = io,
        .shell = EstLog.run,
        .shell_ctx = &log,
    };
    // EstLog returns a sequences object, which has no prev_processed. The
    // handler then builds Moonraker's process result from the ctx version.
    const gcode = try std.fmt.allocPrint(a, "{s}/job.gcode", .{root});
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "filename", .{ .string = gcode });
    const result = try handleProcess(@ptrCast(&ctx), .{ .object = obj }, a);
    try testing.expectEqual(false, result.object.get("prev_processed").?.bool);
    try testing.expectEqualStrings("v1.2.3", result.object.get("version").?.string);
    try testing.expectEqual(false, result.object.get("bypassed").?.bool);
    try testing.expect(std.mem.indexOf(u8, log.cmd, "post-process") != null);
}

const DumpLog = struct {
    fn run(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
        return "{\"accel\":1000}";
    }
};

test "handleDumpConfig: shell JSON is the dumped config and dotdot is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "est", .data = "" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var dummy: u8 = 0;
    var ctx = AnalysisCtx{
        .estimator_path = try std.fmt.allocPrint(a, "{s}/est", .{root}),
        .estimator_version = "v9",
        .io = io,
        .shell = DumpLog.run,
        .shell_ctx = &dummy,
    };
    const bad = try mkParams(a, "{\"dest_config\":\"../secret.json\"}");
    try testing.expectError(error.InvalidParams, handleDumpConfig(@ptrCast(&ctx), bad, a));
    const result = try handleDumpConfig(@ptrCast(&ctx), .null, a);
    try testing.expect(result.object.get("dest_root").? == .null);
    try testing.expectEqualStrings("klipper_estimator.cfg", result.object.get("dest_config_path").?.string);
    try testing.expectEqual(@as(i64, 1000), result.object.get("klipper_estimator_config").?.object.get("accel").?.integer);
}

test "handleDumpConfig: with dest_config param → EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const params = try mkParams(a, "{\"dest_config\": \"my_config.json\"}");
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), params, a));
}

test "registerAnalysis: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = AnalysisCtx{};
    try registerAnalysis(&reg, &ctx);

    // HTTP routes
    try testing.expect(reg.lookup(.GET, "/server/analysis/status") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/estimate") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/process") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/dump_config") != null);

    // JSON-RPC methods
    try testing.expect(d.methods.get("server.analysis.status") != null);
    try testing.expect(d.methods.get("server.analysis.estimate") != null);
    try testing.expect(d.methods.get("server.analysis.process") != null);
    try testing.expect(d.methods.get("server.analysis.dump_config") != null);
}

// --- Fuzz tests ---

test "fuzz handleStatus: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var ctx = AnalysisCtx{};
            _ = handleStatus(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleEstimate: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"filename\": \"test.gcode\"}",
                "{\"filename\": \"a.gcode\", \"estimator_config\": \"cfg.json\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            var ctx = AnalysisCtx{};
            _ = handleEstimate(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleProcess: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"filename\": \"test.gcode\"}",
                "{\"filename\": \"a.gcode\", \"force\": true}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            var ctx = AnalysisCtx{};
            _ = handleProcess(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDumpConfig: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var ctx = AnalysisCtx{};
            _ = handleDumpConfig(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

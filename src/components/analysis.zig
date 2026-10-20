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
//! Phobos does not run klipper_estimator. `[analysis]` sets the binary and
//! config paths under the datadir; status reports their names and whether the
//! config exists, with `estimator_ready` false. estimate and process check
//! that `filename` exists under the gcodes root (GcodeNotFound otherwise) and
//! that `estimator_config` has no `..` segment, then fail with
//! EstimatorNotAvailable, Moonraker's error when the estimator is not ready.
//! dump_config validates `dest_config` the same way. See TODO.md.

const std = @import("std");
const registry = @import("../server/registry.zig");
const file_manager = @import("file_manager.zig");

const Registry = registry.Registry;

pub const AnalysisCtx = struct {
    /// Path to the `klipper_estimator` binary. Empty means `[analysis]` is absent.
    estimator_path: []const u8 = "",
    /// Estimator config file reported by status.
    estimator_config: []const u8 = "",
    /// True when `estimator_path` and `estimator_config` are allocator-owned.
    paths_owned: bool = false,
    io: ?std.Io = null,
    /// Resolves request filenames under the gcodes root. Borrowed from the App.
    files: ?*const file_manager.FileCtx = null,

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

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const v = params.object.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

/// Moonraker rejects `..` path segments in estimator_config and dest_config.
fn hasDotDot(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/analysis/status
pub fn handleStatus(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const exec: []const u8 = if (ctx.estimator_path.len == 0) "unknown" else std.fs.path.basename(ctx.estimator_path);
    const cfg_exists = if (ctx.io) |io| ctx.estimator_config.len > 0 and fileExists(io, ctx.estimator_config) else false;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "estimator_executable", .{ .string = exec });
    try obj.put(alloc, "estimator_ready", .{ .bool = false });
    try obj.put(alloc, "estimator_version", .{ .string = "?" });
    try obj.put(alloc, "estimator_config_exists", .{ .bool = cfg_exists });
    const using_default = ctx.estimator_config.len == 0 or
        std.mem.endsWith(u8, ctx.estimator_config, "klipper_estimator.cfg") or
        std.mem.endsWith(u8, ctx.estimator_config, "default_estimator_cfg.json");
    try obj.put(alloc, "using_default_config", .{ .bool = using_default });
    return .{ .object = obj };
}

/// POST /server/analysis/estimate and /server/analysis/process
/// (analysis.py `_handle_estimator_request`). params: filename (required),
/// estimator_config (optional, under the config root).
pub fn handleEstimate(ctx_ptr: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const raw = getOptStr(params, "filename") orelse return error.InvalidParams;
    const filename = std.mem.trim(u8, raw, "/");
    const files = ctx.files orelse return error.GcodeNotFound;
    if (!files.fileExists("gcodes", filename)) return error.GcodeNotFound;
    if (getOptStr(params, "estimator_config")) |cfg| {
        if (hasDotDot(cfg)) return error.InvalidParams;
    }
    return error.EstimatorNotAvailable;
}

/// POST /server/analysis/dump_config. params: dest_config (optional).
pub fn handleDumpConfig(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    if (getOptStr(params, "dest_config")) |dest| {
        if (hasDotDot(dest)) return error.InvalidParams;
    }
    return error.EstimatorNotAvailable;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerAnalysis(reg: *Registry, ctx: *AnalysisCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);
    try reg.registerEndpoint(.{ .path = "/server/analysis/status", .methods = &.{.GET} }, c, handleStatus);
    try reg.registerEndpoint(.{ .path = "/server/analysis/estimate", .methods = &.{.POST} }, c, handleEstimate);
    try reg.registerEndpoint(.{ .path = "/server/analysis/process", .methods = &.{.POST} }, c, handleEstimate);
    try reg.registerEndpoint(.{ .path = "/server/analysis/dump_config", .methods = &.{.POST} }, c, handleDumpConfig);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleStatus: estimator is never ready; config existence is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const empty = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("unknown", empty.object.get("estimator_executable").?.string);
    try testing.expectEqual(false, empty.object.get("estimator_ready").?.bool);
    try testing.expectEqualStrings("?", empty.object.get("estimator_version").?.string);
    try testing.expectEqual(false, empty.object.get("estimator_config_exists").?.bool);
    try testing.expectEqual(true, empty.object.get("using_default_config").?.bool);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "est", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "custom.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    ctx = .{
        .estimator_path = try std.fs.path.join(a, &.{ root, "est" }),
        .estimator_config = try std.fs.path.join(a, &.{ root, "custom.json" }),
        .io = testing.io,
    };
    const present = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("est", present.object.get("estimator_executable").?.string);
    try testing.expectEqual(false, present.object.get("estimator_ready").?.bool);
    try testing.expectEqual(true, present.object.get("estimator_config_exists").?.bool);
    try testing.expectEqual(false, present.object.get("using_default_config").?.bool);
}

test "handleEstimate: filename resolves under the gcodes root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "gcodes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gcodes/job.gcode", .data = "G1 X1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.gcode", .data = "G1 X1\n" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const roots = [_]file_manager.Root{.{ .name = "gcodes", .path = try std.fs.path.join(a, &.{ base, "gcodes" }), .full_access = true }};
    const files: file_manager.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = testing.io };
    var ctx = AnalysisCtx{ .files = &files };

    try testing.expectError(error.InvalidParams, handleEstimate(@ptrCast(&ctx), .null, a));
    // A path outside the gcodes root, even one that exists relative to cwd,
    // is not found.
    const outside = try std.fmt.allocPrint(a, "{{\"filename\":\"{s}/outside.gcode\"}}", .{base});
    try testing.expectError(error.GcodeNotFound, handleEstimate(@ptrCast(&ctx), try mkParams(a, outside), a));
    try testing.expectError(error.GcodeNotFound, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"../outside.gcode\"}"), a));
    try testing.expectError(error.InvalidParams, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"/job.gcode\",\"estimator_config\":\"../x.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"/job.gcode\",\"force\":true}"), a));
}

test "handleDumpConfig: dotdot is rejected, otherwise EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = AnalysisCtx{};
    try testing.expectError(error.InvalidParams, handleDumpConfig(@ptrCast(&ctx), try mkParams(a, "{\"dest_config\":\"a/../secret.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), try mkParams(a, "{\"dest_config\":\"my..config.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), .null, a));
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

    try testing.expect(reg.lookup(.GET, "/server/analysis/status") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/estimate") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/process") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/dump_config") != null);

    try testing.expect(d.methods.get("server.analysis.status") != null);
    try testing.expect(d.methods.get("server.analysis.estimate") != null);
    try testing.expect(d.methods.get("server.analysis.process") != null);
    try testing.expect(d.methods.get("server.analysis.dump_config") != null);
}

// --- Fuzz tests ---

test "fuzz hasDotDot: matches a whole-segment scan" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            const alphabet = "./a";
            for (&buf) |*c| c.* = alphabet[smith.value(u8) % alphabet.len];
            const path = buf[0 .. smith.value(u8) % (buf.len + 1)];
            const expected = std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../") or
                std.mem.endsWith(u8, path, "/..") or std.mem.indexOf(u8, path, "/../") != null;
            try testing.expectEqual(expected, hasDotDot(path));
        }
    }.run, .{});
}

test "fuzz analysis handlers: never panic on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"filename\": \"test.gcode\"}",
                "{\"filename\": 5}",
                "{\"filename\": \"a.gcode\", \"estimator_config\": \"../cfg.json\"}",
                "{\"dest_config\": \"../x\"}",
            };
            const p = try std.json.parseFromSlice(std.json.Value, a, strs[smith.value(u8) % strs.len], .{});
            var ctx = AnalysisCtx{};
            const handlers = [_]registry.HandlerFn{ handleStatus, handleEstimate, handleDumpConfig };
            const r = handlers[smith.value(u8) % handlers.len](@ptrCast(&ctx), p.value, a) catch return;
            try testing.expect(r == .object);
        }
    }.run, .{});
}

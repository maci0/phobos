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
pub const AnalysisCtx = struct {};

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
pub fn handleStatus(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // matches analysis.py _handle_status_request shape exactly
    try obj.put(alloc, "estimator_executable", .{ .string = "unknown" });
    try obj.put(alloc, "estimator_ready", .{ .bool = false });
    try obj.put(alloc, "estimator_version", .{ .string = "?" });
    try obj.put(alloc, "estimator_config_exists", .{ .bool = false });
    try obj.put(alloc, "using_default_config", .{ .bool = true });
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
pub fn handleEstimate(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const filename = try getStr(params, "filename");
    _ = filename; // validated; would be used if estimator were present
    // NOTE: klipper_estimator not available in phobos.
    return error.EstimatorNotAvailable;
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
pub fn handleProcess(_: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    const filename = try getStr(params, "filename");
    _ = filename; // validated; would be used if estimator were present
    _ = getOptBool(params, "force", false); // param consumed
    // NOTE: klipper_estimator not available in phobos.
    return error.EstimatorNotAvailable;
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
pub fn handleDumpConfig(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    // NOTE: klipper_estimator not available in phobos.
    return error.EstimatorNotAvailable;
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

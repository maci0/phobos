//! In-process conformance cases.
//!
//! Each case sends one JSON-RPC request through the App's dispatcher (no
//! Klippy connected) and checks the response against stock Moonraker: the
//! exact top-level keys of `result`, an array `result`, or the `error.code`.
//! Key sets come from `conformance/golden/capture.json` or, for methods that
//! capture lacks, the vendored Moonraker handler. Value-level normalized
//! equality against the captures is `conformance/replay.py`.

const std = @import("std");
const jsonrpc = @import("../jsonrpc.zig");
const methods_mod = @import("../core/methods.zig");
const TestServer = @import("../testutil/server.zig").TestServer;

const Dispatcher = jsonrpc.Dispatcher;

pub const Expect = union(enum) {
    /// `result` is an object with exactly these keys, sorted.
    keys: []const []const u8,
    /// `result` is an array.
    array,
    /// The response is an error envelope with this code.
    error_code: i64,
};

pub const GoldenCase = struct {
    /// JSON-RPC method name (e.g. "server.info").
    method: []const u8,
    /// JSON params object as a string (e.g. "{}") or "null" for no params.
    params_json: []const u8,
    expect: Expect,
};

/// Send `method` with `params_json` through `dispatcher`. Caller frees the
/// returned response bytes with `alloc`.
fn callEndpoint(
    alloc: std.mem.Allocator,
    dispatcher: *Dispatcher,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const request_json = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":1,"method":"{s}","params":{s}}}
    , .{ method, params_json });
    defer alloc.free(request_json);
    return try dispatcher.handle(request_json, alloc);
}

pub const goldenCases: []const GoldenCase = &.{
    .{ .method = "server.info", .params_json = "{}", .expect = .{ .keys = &.{
        "api_version",                 "api_version_string", "components",
        "failed_components",           "klippy_connected",   "klippy_state",
        "missing_klippy_requirements", "moonraker_version",  "registered_directories",
        "warnings",                    "websocket_count",
    } } },
    .{ .method = "server.config", .params_json = "{}", .expect = .{ .keys = &.{ "config", "files", "orig" } } },
    .{ .method = "server.gcode_store", .params_json = "{\"count\":10}", .expect = .{ .keys = &.{"gcode_store"} } },
    // No Klippy, so no sensors are tracked.
    .{ .method = "server.temperature_store", .params_json = "{}", .expect = .{ .keys = &.{} } },
    .{ .method = "server.sensors.list", .params_json = "{}", .expect = .{ .keys = &.{"sensors"} } },
    // klippy_connection.py: "Klippy Host not connected", 503.
    .{ .method = "printer.print.start", .params_json = "{\"filename\":\"test.gcode\"}", .expect = .{ .error_code = 503 } },
    .{ .method = "printer.restart", .params_json = "{}", .expect = .{ .error_code = 503 } },
    .{ .method = "server.files.list", .params_json = "{}", .expect = .array },
    // file_manager.py raises 404; common.py JsonRPC maps 404 to -32601.
    .{ .method = "server.files.metadata", .params_json = "{\"filename\":\"test.gcode\"}", .expect = .{ .error_code = -32601 } },
    .{ .method = "server.history.list", .params_json = "{\"limit\":10}", .expect = .{ .keys = &.{ "count", "jobs" } } },
    .{ .method = "server.job_queue.status", .params_json = "{}", .expect = .{ .keys = &.{ "queue_state", "queued_jobs" } } },
    .{ .method = "server.announcements.list", .params_json = "{}", .expect = .{ .keys = &.{ "entries", "feeds" } } },
    .{ .method = "server.webcams.list", .params_json = "{}", .expect = .{ .keys = &.{"webcams"} } },
    .{ .method = "machine.system_info", .params_json = "{}", .expect = .{ .keys = &.{"system_info"} } },
    .{ .method = "machine.proc_stats", .params_json = "{}", .expect = .{ .keys = &.{
        "cpu_temp",      "moonraker_stats", "network",         "system_cpu_usage",
        "system_memory", "system_uptime",   "throttled_state", "websocket_connections",
    } } },
    .{ .method = "machine.device_power.devices", .params_json = "{}", .expect = .{ .keys = &.{"devices"} } },
    // update_manager.py: github_api_stats() plus version_info and busy.
    .{ .method = "machine.update.status", .params_json = "{}", .expect = .{ .keys = &.{
        "busy", "github_limit_reset_time", "github_rate_limit", "github_requests_remaining", "version_info",
    } } },
    .{ .method = "server.database.list", .params_json = "{}", .expect = .{ .keys = &.{ "backups", "namespaces" } } },
    .{ .method = "machine.wled.strips", .params_json = "{}", .expect = .{ .keys = &.{"strips"} } },
    .{ .method = "server.spoolman.status", .params_json = "{}", .expect = .{ .keys = &.{ "pending_reports", "spool_id", "spoolman_connected" } } },
    .{ .method = "machine.td1.data", .params_json = "{}", .expect = .{ .keys = &.{ "devices", "status" } } },
    .{ .method = "server.extensions.list", .params_json = "{}", .expect = .{ .keys = &.{"agents"} } },
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "conformance: every golden case matches the Moonraker result keys or error code" {
    const alloc = testing.allocator;
    const ts = try TestServer.init(alloc);
    defer ts.stop();

    for (goldenCases) |case| {
        const resp = try callEndpoint(alloc, ts.app.dispatcher, case.method, case.params_json);
        defer alloc.free(resp);
        errdefer std.debug.print("conformance case {s}: {s}\n", .{ case.method, resp });
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        try testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);

        switch (case.expect) {
            .keys => |want| {
                const result = obj.get("result") orelse return error.TestUnexpectedResult;
                if (result != .object) return error.TestUnexpectedResult;
                const got = try alloc.dupe([]const u8, result.object.keys());
                defer alloc.free(got);
                std.mem.sort([]const u8, got, {}, lessThanStr);
                try testing.expectEqual(want.len, got.len);
                for (want, got) |w, g| try testing.expectEqualStrings(w, g);
            },
            .array => {
                const result = obj.get("result") orelse return error.TestUnexpectedResult;
                try testing.expect(result == .array);
            },
            .error_code => |code| {
                const err = obj.get("error") orelse return error.TestUnexpectedResult;
                try testing.expectEqual(code, err.object.get("code").?.integer);
            },
        }
    }
}

test "callEndpoint: valid method returns valid JSON-RPC" {
    const alloc = testing.allocator;
    var d = Dispatcher.init(alloc);
    defer d.deinit();

    var info: methods_mod.ServerInfo = .{};
    try d.register("server.info", info.ctx(), methods_mod.serverInfoHandler);

    const resp = try callEndpoint(alloc, &d, "server.info", "{}");
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
}

test "callEndpoint: unknown method returns -32601" {
    const alloc = testing.allocator;
    var d = Dispatcher.init(alloc);
    defer d.deinit();

    const resp = try callEndpoint(alloc, &d, "nonexistent.method", "{}");
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") != null);
    try testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "callEndpoint: invalid params returns -32602" {
    const alloc = testing.allocator;
    var d = Dispatcher.init(alloc);
    defer d.deinit();

    const Handler = struct {
        fn h(_: *anyopaque, params: std.json.Value, _al: std.mem.Allocator) anyerror!std.json.Value {
            _ = _al;
            if (params != .object) return error.InvalidParams;
            return .{ .string = "ok" };
        }
    };
    try d.register("test.echo", @ptrFromInt(0x1), Handler.h);

    const resp = try callEndpoint(alloc, &d, "test.echo", "\"not_an_object\"");
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") != null);
    try testing.expectEqual(@as(i64, -32602), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "fuzz callEndpoint: unregistered methods always return -32601" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const alloc = testing.allocator;

            var d = Dispatcher.init(alloc);
            defer d.deinit();

            const method_chars = "abcdefghijklmnopqrstuvwxyz._";
            var mn_buf: [16]u8 = undefined;
            for (&mn_buf, buf[0..mn_buf.len]) |*c, b| c.* = method_chars[b % method_chars.len];
            const method = mn_buf[0 .. 1 + buf[16] % mn_buf.len];

            const param_templates = [_][]const u8{ "{}", "null", "[]", "\"x\"" };
            const params = param_templates[buf[17] % param_templates.len];

            const resp = try callEndpoint(alloc, &d, method, params);
            defer alloc.free(resp);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
            defer parsed.deinit();
            try testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
        }
    }.run, .{});
}

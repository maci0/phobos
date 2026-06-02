//! Conformance oracle replay engine (§8).
//!
//! Replays a scripted sequence of JSON-RPC requests against a phobos dispatcher
//! and asserts normalized-equality against expected responses. Uses the
//! field-normalization rules from `normalize.zig` before comparison.
//!
//! In snapshot mode (expected_response = ""), the test accepts whatever phobos
//! returns — this validates the handler doesn't crash and returns valid JSON-RPC.
//! In parity mode (expected_response populated with Moonraker captures), the
//! test performs strict normalized comparison.
//!
//! Adding a golden case:
//!   1. Add an entry to `goldenCases` below.
//!   2. Run the test — it will fail with the actual phobos response.
//!   3. Either: copy the actual response as the expected (snapshot), or
//!      capture the equivalent response from Moonraker (parity).

const std = @import("std");
const jsonrpc = @import("../jsonrpc.zig");
const normalize = @import("normalize.zig");
const methods_mod = @import("../core/methods.zig");
const App = @import("../app.zig").App;

const Dispatcher = jsonrpc.Dispatcher;

// ---------------------------------------------------------------------------
// Golden case
// ---------------------------------------------------------------------------

pub const GoldenCase = struct {
    /// JSON-RPC method name (e.g. "server.info").
    method: []const u8,
    /// JSON params object as a string (e.g. "{}") or "null" for no params.
    params_json: []const u8,
    /// Expected JSON-RPC response. Empty string = snapshot mode (accept any valid response).
    expected_response: []const u8,
    /// If true, only validate that the response has a "result" (not an error).
    result_only: bool = false,
};

// ---------------------------------------------------------------------------
// Replay engine
// ---------------------------------------------------------------------------

pub const ReplayResult = struct {
    case: *const GoldenCase,
    passed: bool,
    actual: []const u8,
    expected: []const u8,
};

/// Replay all golden cases against `dispatcher`. Returns owned results.
pub fn replay(
    alloc: std.mem.Allocator,
    dispatcher: *Dispatcher,
    cases: []const GoldenCase,
) ![]ReplayResult {
    var results: std.ArrayList(ReplayResult) = .empty;
    errdefer results.deinit(alloc);

    for (cases) |*case| {
        const actual = try callEndpoint(alloc, dispatcher, case.method, case.params_json);
        const passed = if (case.expected_response.len == 0)
            true // snapshot mode: accept actual
        else if (case.result_only)
            try resultShapeOk(alloc, actual)
        else
            try normalize.normalizedEqual(alloc, actual, case.expected_response, case.method);

        try results.append(alloc, .{
            .case = case,
            .passed = passed,
            .actual = actual,
            .expected = if (case.expected_response.len == 0) actual else case.expected_response,
        });
    }

    return results.toOwnedSlice(alloc);
}

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

fn resultShapeOk(alloc: std.mem.Allocator, response_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, response_json, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object and parsed.value.object.get("result") != null;
}

// ---------------------------------------------------------------------------
// Golden cases
// ---------------------------------------------------------------------------
// To populate with real Moonraker responses:
//   1. Start Moonraker without Klippy
//   2. Send each request via: curl -s -X POST http://127.0.0.1:7125/printer/api -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"<method>","params":<params>}'
//   3. Paste the full response into expected_response
// ---------------------------------------------------------------------------

pub const goldenCases: []const GoldenCase = &.{
    .{ .method = "server.info", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.config", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.gcode_store", .params_json = "{\"count\":10}", .expected_response = "" },
    .{ .method = "server.temperature_store", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.sensors.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "printer.print.start", .params_json = "{\"filename\":\"test.gcode\"}", .expected_response = "" },
    .{ .method = "printer.restart", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.files.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.files.metadata", .params_json = "{\"filename\":\"test.gcode\"}", .expected_response = "" },
    .{ .method = "server.history.list", .params_json = "{\"limit\":10}", .expected_response = "" },
    .{ .method = "server.job_queue.status", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.announcements.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.webcams.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "machine.system_info", .params_json = "{}", .expected_response = "", .result_only = true },
    .{ .method = "machine.proc_stats", .params_json = "{}", .expected_response = "", .result_only = true },
    .{ .method = "machine.device_power.devices", .params_json = "{}", .expected_response = "" },
    .{ .method = "machine.update.status", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.database.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "machine.wled.strips", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.spoolman.status", .params_json = "{}", .expected_response = "" },
    .{ .method = "machine.td1.data", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.mqtt.status", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.extensions.list", .params_json = "{}", .expected_response = "" },
    .{ .method = "server.analysis.stats", .params_json = "{}", .expected_response = "" },
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "conformance: snapshots — all golden cases return valid JSON-RPC" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
    defer app.deinit(io);
    // Wire live io into components so handlers that need it (file_manager,
    // spoolman, etc.) don't crash on null-io dereference.
    _ = app.httpServer(io);

    const results = try replay(alloc, app.dispatcher, goldenCases);
    defer {
        for (results) |r| alloc.free(r.actual);
        alloc.free(results);
    }

    for (results) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, r.actual, .{}) catch {
            std.debug.print("FAIL {s}: unparseable response: {s}\n", .{ r.case.method, r.actual });
            return error.TestFailed;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            std.debug.print("FAIL {s}: response not an object: {s}\n", .{ r.case.method, r.actual });
            return error.TestFailed;
        }
        const obj = parsed.value.object;
        if (obj.get("jsonrpc") == null) {
            std.debug.print("FAIL {s}: missing jsonrpc\n", .{r.case.method});
            return error.TestFailed;
        }
        try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        if (obj.get("id") == null) {
            std.debug.print("FAIL {s}: missing id\n", .{r.case.method});
            return error.TestFailed;
        }
        if (obj.get("result") == null and obj.get("error") == null) {
            std.debug.print("FAIL {s}: missing result and error: {s}\n", .{ r.case.method, r.actual });
            return error.TestFailed;
        }
        if (!r.passed) {
            std.debug.print("FAIL {s}: response differs.\n  actual:   {s}\n  expected: {s}\n", .{ r.case.method, r.actual, r.expected });
            return error.TestFailed;
        }
    }
}

test "conformance: server.info has required fields" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
    defer app.deinit(io);

    const resp = try callEndpoint(alloc, app.dispatcher, "server.info", "{}");
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;

    try testing.expect(result.get("klippy_connected") != null);
    try testing.expect(result.get("klippy_state") != null);
    try testing.expect(result.get("components") != null);
    try testing.expect(result.get("failed_components") != null);
    try testing.expect(result.get("registered_directories") != null);
    try testing.expect(result.get("warnings") != null);
    try testing.expect(result.get("websocket_count") != null);
    try testing.expect(result.get("moonraker_version") != null);
    try testing.expect(result.get("api_version") != null);
    try testing.expect(result.get("api_version_string") != null);
}

test "conformance: server.config has required fields" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
    defer app.deinit(io);

    const resp = try callEndpoint(alloc, app.dispatcher, "server.config", "{}");
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;

    try testing.expect(result.get("config") != null);
    try testing.expect(result.get("files") != null);
    try testing.expect(result.get("orig") != null);
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

test "result_only: passes when response has result" {
    const alloc = testing.allocator;
    const resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":1}}";
    try testing.expect(try resultShapeOk(alloc, resp));
}

test "result_only: fails when response has error" {
    const alloc = testing.allocator;
    const resp = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"oops\"}}";
    try testing.expect(!try resultShapeOk(alloc, resp));
}

/// Escape a string for embedding in a Zig string literal (escapes \ and ").
fn escapeForZig(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Capture helper — run this test to print expected responses for golden cases.
// Run with: ./.zig-cache/o/*/test --cache-dir=./.zig-cache capture
// Then copy the output into the goldenCases array.
// ---------------------------------------------------------------------------

test "capture: print all golden case responses" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
    defer app.deinit(io);
    _ = app.httpServer(io);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, "/tmp/phobos_golden_captures.txt", .{});
    defer file.close(io);

    var fbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    for (goldenCases) |*gc| {
        const resp = callEndpoint(alloc, app.dispatcher, gc.method, gc.params_json) catch |err| {
            const line = try std.fmt.bufPrint(&fbuf, "// {s}: ERROR: {}\n", .{ gc.method, err });
            var w = file.writer(io, &wbuf);
            try w.interface.writeAll(line);
            continue;
        };
        defer alloc.free(resp);
        const escaped = try escapeForZig(alloc, resp);
        defer alloc.free(escaped);
        const line = try std.fmt.bufPrint(&fbuf, "{{ .method = \"{s}\", .params_json = \"{s}\", .expected_response = \"{s}\" }},\n", .{ gc.method, gc.params_json, escaped });
        var w = file.writer(io, &wbuf);
        try w.interface.writeAll(line);
    }
}

// ---------------------------------------------------------------------------
// Fuzz
// ---------------------------------------------------------------------------

test "fuzz callEndpoint: never crashes on arbitrary method/params" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var d = Dispatcher.init(a);
            defer d.deinit();

            const method_chars = "abcdefghijklmnopqrstuvwxyz._";
            var mn_buf: [32]u8 = undefined;
            var mn: usize = 0;
            for (buf[0..@min(buf.len, 16)]) |b| {
                mn_buf[mn] = method_chars[b % method_chars.len];
                mn += 1;
            }
            const method = mn_buf[0..@max(1, mn % 32)];

            const param_templates = [_][]const u8{ "{}", "null", "[]", "\"x\"" };
            const params = param_templates[buf[0] % param_templates.len];

            _ = callEndpoint(a, &d, method, params) catch {};
        }
    }.run, .{});
}

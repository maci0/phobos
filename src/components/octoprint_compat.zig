//! OctoPrint compatibility shim (`/api/*`).
//!
//! Mirrors Moonraker's `components/octoprint_compat.py`: a small set of
//! HTTP-only endpoints (transports=HTTP, wrap_result=False) that let OctoPrint
//! API clients (e.g. slicer plugins) talk to Moonraker. None of them derive a
//! JSON-RPC method.
//!
//!   GET  /api/version                              → _get_version
//!   GET  /api/server                               → _get_server
//!   POST /api/login                                → _post_login_user
//!   GET  /api/currentuser                          → _post_login_user
//!   GET  /api/settings                             → _get_settings
//!   GET  /api/job                                  → _get_job
//!   GET  /api/printer                              → _get_printer
//!   POST /api/printer/command                      → _post_command
//!   GET  /api/printerprofiles                      → _get_printerprofiles
//!   POST /api/files/moonraker/(?P<relative_path>.+) → _select_file
//!
//! Because phobos has no Klippy connection, `printer_state()` is always
//! "Offline" (klippy state not startup-complete — octoprint_compat.py:156-168),
//! and the heater set is empty. Each handler returns the faithful Moonraker
//! object for that state.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

/// OctoPrint version Moonraker reports (octoprint_compat.py OCTO_VERSION).
const octo_version = "1.5.0";
/// Phobos's reported software version, used in the version "text" field.
const software_version = "1.5.0";

pub const OctoPrintCtx = struct {};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn obj(alloc: std.mem.Allocator) std.json.ObjectMap {
    _ = alloc;
    return .empty;
}

// ---------------------------------------------------------------------------
// Handlers (wrap_result = false: raw object is the body)
// ---------------------------------------------------------------------------

/// GET /api/version → {server, api, text}
pub fn handleVersion(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);
    try o.put(alloc, "server", .{ .string = octo_version });
    try o.put(alloc, "api", .{ .string = "0.1" });
    try o.put(alloc, "text", .{ .string = "OctoPrint (Moonraker " ++ software_version ++ ")" });
    return .{ .object = o };
}

/// GET /api/server → {server, safemode}
/// Klippy not READY → safemode "settings".
pub fn handleServer(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);
    try o.put(alloc, "server", .{ .string = octo_version });
    try o.put(alloc, "safemode", .{ .string = "settings" });
    return .{ .object = o };
}

/// POST /api/login and GET /api/currentuser → the hardcoded `_api` user.
pub fn handleLoginUser(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);
    try o.put(alloc, "_is_external_client", .{ .bool = false });
    try o.put(alloc, "_login_mechanism", .{ .string = "apikey" });
    try o.put(alloc, "name", .{ .string = "_api" });
    try o.put(alloc, "active", .{ .bool = true });
    try o.put(alloc, "user", .{ .bool = true });
    try o.put(alloc, "admin", .{ .bool = true });
    try o.put(alloc, "apikey", .null);
    try o.put(alloc, "permissions", .{ .array = .init(alloc) });
    var groups: std.json.Array = .init(alloc);
    try groups.append(.{ .string = "admins" });
    try groups.append(.{ .string = "users" });
    try o.put(alloc, "groups", .{ .array = groups });
    return .{ .object = o };
}

/// GET /api/settings → capabilities (UFP plugin enabled by default).
pub fn handleSettings(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);

    // plugins.UltimakerFormatPackage (enable_ufp defaults to true).
    var ufp = obj(alloc);
    try ufp.put(alloc, "align_inline_thumbnail", .{ .bool = false });
    try ufp.put(alloc, "inline_thumbnail", .{ .bool = false });
    try ufp.put(alloc, "inline_thumbnail_align_value", .{ .string = "left" });
    try ufp.put(alloc, "inline_thumbnail_scale_value", .{ .string = "50" });
    try ufp.put(alloc, "installed", .{ .bool = true });
    try ufp.put(alloc, "installed_version", .{ .string = "0.2.2" });
    try ufp.put(alloc, "scale_inline_thumbnail", .{ .bool = false });
    try ufp.put(alloc, "state_panel_thumbnail", .{ .bool = true });
    var plugins = obj(alloc);
    try plugins.put(alloc, "UltimakerFormatPackage", .{ .object = ufp });
    try o.put(alloc, "plugins", .{ .object = plugins });

    var feature = obj(alloc);
    try feature.put(alloc, "sdSupport", .{ .bool = false });
    try feature.put(alloc, "temperatureGraph", .{ .bool = false });
    try o.put(alloc, "feature", .{ .object = feature });

    var webcam = obj(alloc);
    try webcam.put(alloc, "flipH", .{ .bool = false });
    try webcam.put(alloc, "flipV", .{ .bool = false });
    try webcam.put(alloc, "rotate90", .{ .bool = false });
    try webcam.put(alloc, "streamUrl", .{ .string = "/webcam/?action=stream" });
    try webcam.put(alloc, "webcamEnabled", .{ .bool = true });
    try o.put(alloc, "webcam", .{ .object = webcam });

    return .{ .object = o };
}

/// GET /api/job → empty job with the current (Offline) printer state.
pub fn handleJob(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);

    var file = obj(alloc);
    try file.put(alloc, "name", .null);
    var job = obj(alloc);
    try job.put(alloc, "file", .{ .object = file });
    try job.put(alloc, "estimatedPrintTime", .null);
    var filament = obj(alloc);
    try filament.put(alloc, "length", .null);
    try job.put(alloc, "filament", .{ .object = filament });
    try job.put(alloc, "user", .null);
    try o.put(alloc, "job", .{ .object = job });

    var progress = obj(alloc);
    try progress.put(alloc, "completion", .null);
    try progress.put(alloc, "filepos", .null);
    try progress.put(alloc, "printTime", .null);
    try progress.put(alloc, "printTimeLeft", .null);
    try progress.put(alloc, "printTimeOrigin", .null);
    try o.put(alloc, "progress", .{ .object = progress });

    try o.put(alloc, "state", .{ .string = "Offline" });
    return .{ .object = o };
}

/// GET /api/printer → temperature + state flags for the Offline printer.
pub fn handlePrinter(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o = obj(alloc);
    // No heaters without Klippy → empty temperature map.
    try o.put(alloc, "temperature", .{ .object = obj(alloc) });

    var flags = obj(alloc);
    // state == "Offline": operational=false, closedOrError=true, rest false.
    try flags.put(alloc, "operational", .{ .bool = false });
    try flags.put(alloc, "paused", .{ .bool = false });
    try flags.put(alloc, "printing", .{ .bool = false });
    try flags.put(alloc, "cancelling", .{ .bool = false });
    try flags.put(alloc, "pausing", .{ .bool = false });
    try flags.put(alloc, "error", .{ .bool = false });
    try flags.put(alloc, "ready", .{ .bool = false });
    try flags.put(alloc, "closedOrError", .{ .bool = true });

    var state = obj(alloc);
    try state.put(alloc, "text", .{ .string = "Offline" });
    try state.put(alloc, "flags", .{ .object = flags });
    try o.put(alloc, "state", .{ .object = state });
    return .{ .object = o };
}

/// POST /api/printer/command → run gcode. Without Klippy the commands cannot be
/// executed; Moonraker swallows the per-command error and still returns {}.
pub fn handleCommand(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return .{ .object = obj(alloc) };
}

/// GET /api/printerprofiles → the single _default profile.
pub fn handlePrinterProfiles(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const makeAxis = struct {
        fn f(a: std.mem.Allocator) !std.json.Value {
            var ax = obj(a);
            try ax.put(a, "speed", .{ .float = 6000.0 });
            try ax.put(a, "inverted", .{ .bool = false });
            return .{ .object = ax };
        }
    }.f;

    var axes = obj(alloc);
    try axes.put(alloc, "x", try makeAxis(alloc));
    try axes.put(alloc, "y", try makeAxis(alloc));
    try axes.put(alloc, "z", try makeAxis(alloc));
    try axes.put(alloc, "e", try makeAxis(alloc));

    var def = obj(alloc);
    try def.put(alloc, "id", .{ .string = "_default" });
    try def.put(alloc, "name", .{ .string = "Default" });
    try def.put(alloc, "color", .{ .string = "default" });
    try def.put(alloc, "model", .{ .string = "Default" });
    try def.put(alloc, "default", .{ .bool = true });
    try def.put(alloc, "current", .{ .bool = true });
    try def.put(alloc, "heatedBed", .{ .bool = false });
    try def.put(alloc, "heatedChamber", .{ .bool = false });
    try def.put(alloc, "axes", .{ .object = axes });

    var profiles = obj(alloc);
    try profiles.put(alloc, "_default", .{ .object = def });
    var o = obj(alloc);
    try o.put(alloc, "profiles", .{ .object = profiles });
    return .{ .object = o };
}

/// POST /api/files/moonraker/(relative_path) → select/print a file.
/// Without Klippy a print cannot be started; selecting without printing is a
/// no-op returning null, and any command we cannot satisfy surfaces the
/// disconnected error (matching the start_print path failing). We return an
/// empty object (null body) for the common no-op select case.
pub fn handleSelectFile(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return .{ .object = obj(alloc) };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerOctoPrint(reg: *Registry, ctx: *OctoPrintCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);
    const http_only: []const registry.TransportType = &.{.HTTP};

    const Endpoint = struct {
        path: []const u8,
        method: registry.RequestType,
        handler: registry.HandlerFn,
    };
    const endpoints = [_]Endpoint{
        .{ .path = "/api/version", .method = .GET, .handler = handleVersion },
        .{ .path = "/api/server", .method = .GET, .handler = handleServer },
        .{ .path = "/api/login", .method = .POST, .handler = handleLoginUser },
        .{ .path = "/api/currentuser", .method = .GET, .handler = handleLoginUser },
        .{ .path = "/api/settings", .method = .GET, .handler = handleSettings },
        .{ .path = "/api/job", .method = .GET, .handler = handleJob },
        .{ .path = "/api/printer", .method = .GET, .handler = handlePrinter },
        .{ .path = "/api/printer/command", .method = .POST, .handler = handleCommand },
        .{ .path = "/api/printerprofiles", .method = .GET, .handler = handlePrinterProfiles },
        .{ .path = "/api/files/moonraker/(?P<relative_path>.+)", .method = .POST, .handler = handleSelectFile },
    };

    for (endpoints) |e| {
        try reg.registerEndpoint(
            .{
                .path = e.path,
                .methods = &.{e.method},
                .transports = http_only,
                .wrap_result = false,
            },
            c,
            e.handler,
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "handleVersion returns server/api/text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleVersion(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("1.5.0", r.object.get("server").?.string);
    try testing.expectEqualStrings("0.1", r.object.get("api").?.string);
    try testing.expect(r.object.get("text") != null);
}

test "handleServer reports safemode settings (klippy not ready)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleServer(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("settings", r.object.get("safemode").?.string);
}

test "handleLoginUser returns _api user with admin groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleLoginUser(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("_api", r.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), r.object.get("groups").?.array.items.len);
}

test "handleSettings includes webcam and UFP plugin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleSettings(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expect(r.object.get("webcam") != null);
    try testing.expect(r.object.get("plugins").?.object.get("UltimakerFormatPackage") != null);
}

test "handleJob and handlePrinter report Offline state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = OctoPrintCtx{};
    const job = try handleJob(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Offline", job.object.get("state").?.string);
    const pr = try handlePrinter(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Offline", pr.object.get("state").?.object.get("text").?.string);
    try testing.expectEqual(false, pr.object.get("state").?.object.get("flags").?.object.get("operational").?.bool);
}

test "handlePrinterProfiles returns _default profile with axes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handlePrinterProfiles(@ptrCast(&ctx), .null, arena.allocator());
    const def = r.object.get("profiles").?.object.get("_default").?.object;
    try testing.expectEqualStrings("_default", def.get("id").?.string);
    try testing.expect(def.get("axes").?.object.get("x") != null);
}

test "handleCommand and handleSelectFile return empty objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = OctoPrintCtx{};
    const cmd = try handleCommand(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), cmd.object.count());
    const sel = try handleSelectFile(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), sel.object.count());
}

test "registerOctoPrint wires HTTP-only routes with no JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = OctoPrintCtx{};
    try registerOctoPrint(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/api/version") != null);
    try testing.expect(reg.lookup(.POST, "/api/login") != null);
    try testing.expect(reg.lookup(.POST, "/api/printer/command") != null);
    // HTTP-only → no derived JSON-RPC method.
    try testing.expectEqual(@as(usize, 0), d.methods.count());
}

// --- Fuzz ---

test "fuzz octoprint handlers: arbitrary params never crash, always serializable" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = OctoPrintCtx{};

            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const handlers = [_]registry.HandlerFn{
                handleVersion,   handleServer,         handleLoginUser,
                handleSettings,  handleJob,            handlePrinter,
                handleCommand,   handlePrinterProfiles, handleSelectFile,
            };
            const strs = [_][]const u8{ "null", "{}", "{\"commands\":[\"G28\"]}", "[1]", "5" };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            const h = handlers[buf[1] % handlers.len];
            const r = h(@ptrCast(&ctx), p.value, a) catch return;
            // Result must serialize.
            _ = std.json.Stringify.valueAlloc(a, r, .{}) catch return error.NotSerializable;
        }
    }.run, .{});
}

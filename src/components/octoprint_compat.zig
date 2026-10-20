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
//!   POST /api/files/local                          → slicer upload (streamed;
//!        handled directly in http_transport.zig, returns the OctoPrint
//!        `{files:{local:{…}},done:true}` shape)
//!
//! State tracking: `printer_state()` reports live Klippy+print_stats state.
//! When Klippy is not connected/started → "Offline"; when Klippy is started
//! but not ready → "Error"; otherwise it maps the last print_stats.state:
//! standby/complete → "Operational", printing → "Printing", paused → "Paused",
//! everything else → "Error".

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

/// OctoPrint version Moonraker reports (octoprint_compat.py OCTO_VERSION).
const octo_version = "1.5.0";
/// Phobos's reported software version, used in the version "text" field.
const software_version = "1.5.0";

pub const OctoPrintCtx = struct {
    server_info: ?*@import("../core/methods.zig").ServerInfo = null,
    temp_store: ?*@import("data_store.zig").DataStoreCtx = null,
    /// Runs `/api/printer/command` gcode. Borrowed; set by the App.
    klippy: ?*@import("klippy_connection.zig").KlippyCtx = null,
    /// Latest print_stats state from Klippy. Updated by statusUpdate()
    /// called from klippy_connection's status processing.
    print_state: PrintState = .standby,
    /// `[octoprint_compat]` options. Defaults match Moonraker.
    enable_ufp: bool = true,
    flip_h: bool = false,
    flip_v: bool = false,
    rotate_90: bool = false,
    stream_url: []const u8 = "/webcam/?action=stream",
    webcam_enabled: bool = true,
    /// True when `stream_url` was duped from config and must be freed.
    stream_url_owned: bool = false,

    pub fn deinit(self: *OctoPrintCtx, alloc: std.mem.Allocator) void {
        if (self.stream_url_owned) alloc.free(self.stream_url);
    }

    /// Called by klippy_connection when a status update contains print_stats.
    /// Extracts the state field for printer_state() queries.
    /// The status frame is freed after dispatch, so only the parsed state is kept.
    pub fn statusUpdate(self: *OctoPrintCtx, print_stats: std.json.Value) void {
        if (print_stats != .object) return;
        if (print_stats.object.get("state")) |s| {
            if (s == .string) self.print_state = std.meta.stringToEnum(PrintState, s.string) orelse .other;
        }
    }

    /// Called by klippy_connection when Klippy disconnects or shuts down.
    pub fn setKlippyDisconnected(self: *OctoPrintCtx) void {
        self.print_state = .standby;
    }

    /// Maps Klippy + print_stats state to OctoPrint printer state string.
    /// Matches octoprint_compat.py printer_state(). No `server_info` means no
    /// Klippy connection.
    fn connectionState(self: *const OctoPrintCtx) enum { offline, failed, ready } {
        const info = self.server_info orelse return .offline;
        if (info.io) |io| info.state_mutex.lockUncancelable(io);
        defer if (info.io) |io| info.state_mutex.unlock(io);
        if (!info.klippy_connected) return .offline;
        return if (std.mem.eql(u8, info.klippy_state, "ready")) .ready else .failed;
    }

    fn printerState(self: *const OctoPrintCtx) []const u8 {
        switch (self.connectionState()) {
            .offline => return "Offline",
            .failed => return "Error",
            .ready => {},
        }
        return switch (self.print_state) {
            .standby, .complete => "Operational",
            .printing => "Printing",
            .paused => "Paused",
            .other => "Error",
        };
    }
};

/// print_stats states with an OctoPrint mapping; anything else is `other`.
const PrintState = enum { standby, printing, paused, complete, other };

// ---------------------------------------------------------------------------
// Handlers (wrap_result = false: raw object is the body)
// ---------------------------------------------------------------------------

/// GET /api/version → {server, api, text}
pub fn handleVersion(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "server", .{ .string = octo_version });
    try o.put(alloc, "api", .{ .string = "0.1" });
    try o.put(alloc, "text", .{ .string = "OctoPrint (Moonraker " ++ software_version ++ ")" });
    return .{ .object = o };
}

/// GET /api/server → {server, safemode}
/// Klippy READY → safemode null; otherwise → safemode "settings".
pub fn handleServer(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "server", .{ .string = octo_version });
    try o.put(alloc, "safemode", if (ctx.connectionState() == .ready) std.json.Value.null else .{ .string = "settings" });
    return .{ .object = o };
}

/// POST /api/login and GET /api/currentuser → the hardcoded `_api` user.
pub fn handleLoginUser(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    var o: std.json.ObjectMap = .empty;
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

/// GET /api/settings → capabilities from `[octoprint_compat]`.
pub fn handleSettings(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o: std.json.ObjectMap = .empty;

    var plugins: std.json.ObjectMap = .empty;
    if (ctx.enable_ufp) {
        var ufp: std.json.ObjectMap = .empty;
        try ufp.put(alloc, "align_inline_thumbnail", .{ .bool = false });
        try ufp.put(alloc, "inline_thumbnail", .{ .bool = false });
        try ufp.put(alloc, "inline_thumbnail_align_value", .{ .string = "left" });
        try ufp.put(alloc, "inline_thumbnail_scale_value", .{ .string = "50" });
        try ufp.put(alloc, "installed", .{ .bool = true });
        try ufp.put(alloc, "installed_version", .{ .string = "0.2.2" });
        try ufp.put(alloc, "scale_inline_thumbnail", .{ .bool = false });
        try ufp.put(alloc, "state_panel_thumbnail", .{ .bool = true });
        try plugins.put(alloc, "UltimakerFormatPackage", .{ .object = ufp });
    }
    try o.put(alloc, "plugins", .{ .object = plugins });

    var feature: std.json.ObjectMap = .empty;
    try feature.put(alloc, "sdSupport", .{ .bool = false });
    try feature.put(alloc, "temperatureGraph", .{ .bool = false });
    try o.put(alloc, "feature", .{ .object = feature });

    var webcam: std.json.ObjectMap = .empty;
    try webcam.put(alloc, "flipH", .{ .bool = ctx.flip_h });
    try webcam.put(alloc, "flipV", .{ .bool = ctx.flip_v });
    try webcam.put(alloc, "rotate90", .{ .bool = ctx.rotate_90 });
    try webcam.put(alloc, "streamUrl", .{ .string = ctx.stream_url });
    try webcam.put(alloc, "webcamEnabled", .{ .bool = ctx.webcam_enabled });
    try o.put(alloc, "webcam", .{ .object = webcam });

    return .{ .object = o };
}

/// GET /api/job → empty job with the current printer state.
pub fn handleJob(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o: std.json.ObjectMap = .empty;

    var file: std.json.ObjectMap = .empty;
    try file.put(alloc, "name", .null);
    var job: std.json.ObjectMap = .empty;
    try job.put(alloc, "file", .{ .object = file });
    try job.put(alloc, "estimatedPrintTime", .null);
    var filament: std.json.ObjectMap = .empty;
    try filament.put(alloc, "length", .null);
    try job.put(alloc, "filament", .{ .object = filament });
    try job.put(alloc, "user", .null);
    try o.put(alloc, "job", .{ .object = job });

    var progress: std.json.ObjectMap = .empty;
    try progress.put(alloc, "completion", .null);
    try progress.put(alloc, "filepos", .null);
    try progress.put(alloc, "printTime", .null);
    try progress.put(alloc, "printTimeLeft", .null);
    try progress.put(alloc, "printTimeOrigin", .null);
    try o.put(alloc, "progress", .{ .object = progress });

    try o.put(alloc, "state", .{ .string = ctx.printerState() });
    return .{ .object = o };
}

/// GET /api/printer → temperature + state flags for the live printer state.
pub fn handlePrinter(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o: std.json.ObjectMap = .empty;
    var temperatures: std.json.ObjectMap = .empty;
    if (ctx.temp_store) |store| {
        if (store.io) |io| {
            store.temp_mutex.lockUncancelable(io);
            defer store.temp_mutex.unlock(io);
            var it = store.sensors.iterator();
            while (it.next()) |entry| {
                const heater = entry.key_ptr.*;
                const name = if (std.mem.eql(u8, heater, "heater_bed")) "bed" else if (std.mem.startsWith(u8, heater, "extruder")) blk: {
                    const tool = std.fmt.parseInt(u32, heater[8..], 10) catch 0;
                    break :blk try std.fmt.allocPrint(alloc, "tool{d}", .{tool});
                } else continue;
                var data: std.json.ObjectMap = .empty;
                try data.put(alloc, "actual", .{ .float = entry.value_ptr.temperature });
                try data.put(alloc, "offset", .{ .integer = 0 });
                try data.put(alloc, "target", .{ .float = entry.value_ptr.target });
                try temperatures.put(alloc, name, .{ .object = data });
            }
        }
    }
    try o.put(alloc, "temperature", .{ .object = temperatures });

    const state_str = ctx.printerState();

    var flags: std.json.ObjectMap = .empty;
    try flags.put(alloc, "operational", .{ .bool = !std.mem.eql(u8, state_str, "Error") and !std.mem.eql(u8, state_str, "Offline") });
    try flags.put(alloc, "paused", .{ .bool = std.mem.eql(u8, state_str, "Paused") });
    try flags.put(alloc, "printing", .{ .bool = std.mem.eql(u8, state_str, "Printing") });
    try flags.put(alloc, "cancelling", .{ .bool = false });
    try flags.put(alloc, "pausing", .{ .bool = false });
    try flags.put(alloc, "error", .{ .bool = std.mem.eql(u8, state_str, "Error") });
    try flags.put(alloc, "ready", .{ .bool = std.mem.eql(u8, state_str, "Operational") });
    try flags.put(alloc, "closedOrError", .{ .bool = std.mem.eql(u8, state_str, "Error") or std.mem.eql(u8, state_str, "Offline") });

    var state: std.json.ObjectMap = .empty;
    try state.put(alloc, "text", .{ .string = state_str });
    try state.put(alloc, "flags", .{ .object = flags });
    try o.put(alloc, "state", .{ .object = state });
    return .{ .object = o };
}

/// POST /api/printer/command → run each string in `commands` through Klippy's
/// gcode/script, in order. Like `_post_command`, a failing or unsendable
/// command does not stop the rest and the result is always {}.
pub fn handleCommand(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    const commands = if (params == .object) params.object.get("commands") orelse return .{ .object = .empty } else return .{ .object = .empty };
    if (commands != .array) return .{ .object = .empty };
    for (commands.array.items) |command| {
        if (command != .string) continue;
        const k = ctx.klippy orelse continue;
        if (!k.isConnected()) continue;
        var script: std.json.ObjectMap = .empty;
        try script.put(alloc, "script", .{ .string = command.string });
        // octoprint_compat.py logs the per-command ServerError and continues.
        _ = k.request("gcode/script", .{ .object = script }, alloc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.debug.print("phobos: warning: octoprint gcode '{s}' failed: {}\n", .{ command.string, err }),
        };
    }
    return .{ .object = .empty };
}

/// GET /api/printerprofiles → the single _default profile.
pub fn handlePrinterProfiles(_: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const makeAxis = struct {
        fn f(a: std.mem.Allocator, speed: f64) !std.json.Value {
            var ax: std.json.ObjectMap = .empty;
            try ax.put(a, "speed", .{ .float = speed });
            try ax.put(a, "inverted", .{ .bool = false });
            return .{ .object = ax };
        }
    }.f;

    // Moonraker reports 6000 for x/y/z and 300 for the extruder axis
    // (octoprint_compat.py _default profile).
    var axes: std.json.ObjectMap = .empty;
    try axes.put(alloc, "x", try makeAxis(alloc, 6000.0));
    try axes.put(alloc, "y", try makeAxis(alloc, 6000.0));
    try axes.put(alloc, "z", try makeAxis(alloc, 6000.0));
    try axes.put(alloc, "e", try makeAxis(alloc, 300.0));

    var def: std.json.ObjectMap = .empty;
    try def.put(alloc, "id", .{ .string = "_default" });
    try def.put(alloc, "name", .{ .string = "Default" });
    try def.put(alloc, "color", .{ .string = "default" });
    try def.put(alloc, "model", .{ .string = "Default" });
    try def.put(alloc, "default", .{ .bool = true });
    try def.put(alloc, "current", .{ .bool = true });
    try def.put(alloc, "heatedBed", .{ .bool = false });
    try def.put(alloc, "heatedChamber", .{ .bool = false });
    try def.put(alloc, "axes", .{ .object = axes });

    var profiles: std.json.ObjectMap = .empty;
    try profiles.put(alloc, "_default", .{ .object = def });
    var o: std.json.ObjectMap = .empty;
    try o.put(alloc, "profiles", .{ .object = profiles });
    return .{ .object = o };
}

/// POST /api/files/moonraker/(relative_path) → `_select_file`. Registered for
/// API coverage only: the HTTP router matches the pattern literally, so a
/// request for a real path never reaches this handler, and `print=true` does
/// not start or queue a print (TODO.md). Returns {} like a plain select.
pub fn handleSelectFile(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return .{ .object = .empty };
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

    inline for (endpoints) |e| {
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

test "handleServer: klippy not ready → safemode settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleServer(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("settings", r.object.get("safemode").?.string);
}

test "handleServer: klippy ready → safemode null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "ready" };
    var ctx = OctoPrintCtx{ .server_info = &info };
    const r = try handleServer(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expect(r.object.get("safemode").? == .null);
}

test "OctoPrint reads live connection state and cached heater temperatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temps = try @import("data_store.zig").DataStoreCtx.init(testing.allocator);
    defer temps.deinit();
    temps.setIo(io);
    temps.pushTemp(io, "heater_bed", 30.567, 0, 0, null);
    temps.pushTemp(io, "extruder", 31.123, 0, 0, null);
    temps.pushTemp(io, "extruder1", 32, 0, 0, null);
    temps.pushTemp(io, "temperature_sensor chamber", 25, null, null, null);
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "ready" };
    var ctx = OctoPrintCtx{ .server_info = &info, .temp_store = &temps };
    const server = try handleServer(&ctx, .null, a);
    try testing.expect(server.object.get("safemode").? == .null);
    const printer = try handlePrinter(&ctx, .null, a);
    try testing.expectEqualStrings("Operational", printer.object.get("state").?.object.get("text").?.string);
    const heaters = printer.object.get("temperature").?.object;
    try testing.expectEqual(@as(usize, 3), heaters.count());
    try testing.expectEqual(@as(f64, 30.57), heaters.get("bed").?.object.get("actual").?.float);
    try testing.expectEqual(@as(f64, 31.12), heaters.get("tool0").?.object.get("actual").?.float);
    try testing.expectEqual(@as(f64, 0), heaters.get("tool1").?.object.get("target").?.float);
    info.klippy_state = "shutdown";
    const failed = try handlePrinter(&ctx, .null, a);
    try testing.expectEqualStrings("Error", failed.object.get("state").?.object.get("text").?.string);
    info.klippy_connected = false;
    const disconnected = try handlePrinter(&ctx, .null, a);
    try testing.expectEqualStrings("Offline", disconnected.object.get("state").?.object.get("text").?.string);
}

test "handleLoginUser returns _api user with admin groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleLoginUser(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expectEqualStrings("_api", r.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), r.object.get("groups").?.array.items.len);
}

test "handleSettings reads octoprint_compat webcam and ufp flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{
        .enable_ufp = false,
        .flip_h = true,
        .rotate_90 = true,
        .stream_url = "http://cam/stream",
        .webcam_enabled = false,
    };
    const r = try handleSettings(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expect(r.object.get("plugins").?.object.get("UltimakerFormatPackage") == null);
    const webcam = r.object.get("webcam").?.object;
    try testing.expect(webcam.get("flipH").?.bool);
    try testing.expect(webcam.get("rotate90").?.bool);
    try testing.expect(!webcam.get("webcamEnabled").?.bool);
    try testing.expectEqualStrings("http://cam/stream", webcam.get("streamUrl").?.string);
}

test "handleSettings includes webcam and UFP plugin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handleSettings(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expect(r.object.get("webcam") != null);
    try testing.expect(r.object.get("plugins").?.object.get("UltimakerFormatPackage") != null);
}

test "handleJob and handlePrinter: offline state (no klippy)" {
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

test "handleJob and handlePrinter: operational state (klippy ready, print_stats standby)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "ready" };
    var ctx = OctoPrintCtx{ .server_info = &info };
    // default print_state is standby → "Operational"
    const job = try handleJob(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Operational", job.object.get("state").?.string);
    const pr = try handlePrinter(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Operational", pr.object.get("state").?.object.get("text").?.string);
    const flags = pr.object.get("state").?.object.get("flags").?.object;
    try testing.expectEqual(true, flags.get("operational").?.bool);
    try testing.expectEqual(true, flags.get("ready").?.bool);
    try testing.expectEqual(false, flags.get("error").?.bool);
    try testing.expectEqual(false, flags.get("closedOrError").?.bool);
}

test "handleJob and handlePrinter: printing state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "ready" };
    var ctx = OctoPrintCtx{ .server_info = &info, .print_state = .printing };
    const job = try handleJob(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Printing", job.object.get("state").?.string);
    const pr = try handlePrinter(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Printing", pr.object.get("state").?.object.get("text").?.string);
    const flags = pr.object.get("state").?.object.get("flags").?.object;
    try testing.expectEqual(true, flags.get("printing").?.bool);
    try testing.expectEqual(false, flags.get("paused").?.bool);
    try testing.expectEqual(false, flags.get("error").?.bool);
}

test "handleJob and handlePrinter: paused state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "ready" };
    var ctx = OctoPrintCtx{ .server_info = &info, .print_state = .paused };
    const pr = try handlePrinter(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Paused", pr.object.get("state").?.object.get("text").?.string);
    const flags = pr.object.get("state").?.object.get("flags").?.object;
    try testing.expectEqual(true, flags.get("paused").?.bool);
    try testing.expectEqual(false, flags.get("printing").?.bool);
}

test "handleJob and handlePrinter: error state (klippy started but not ready)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "startup" };
    var ctx = OctoPrintCtx{ .server_info = &info };
    const job = try handleJob(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Error", job.object.get("state").?.string);
    const pr = try handlePrinter(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("Error", pr.object.get("state").?.object.get("text").?.string);
    const flags = pr.object.get("state").?.object.get("flags").?.object;
    try testing.expectEqual(true, flags.get("error").?.bool);
    try testing.expectEqual(true, flags.get("closedOrError").?.bool);
    try testing.expectEqual(false, flags.get("operational").?.bool);
}

test "handlePrinterProfiles returns _default profile with axes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = OctoPrintCtx{};
    const r = try handlePrinterProfiles(@ptrCast(&ctx), .null, arena.allocator());
    const def = r.object.get("profiles").?.object.get("_default").?.object;
    try testing.expectEqualStrings("_default", def.get("id").?.string);
    const axes = def.get("axes").?.object;
    try testing.expect(axes.get("x") != null);
    // x/y/z report 6000; the extruder axis reports 300 (Moonraker parity).
    try testing.expectEqual(@as(f64, 6000.0), axes.get("x").?.object.get("speed").?.float);
    try testing.expectEqual(@as(f64, 6000.0), axes.get("z").?.object.get("speed").?.float);
    try testing.expectEqual(@as(f64, 300.0), axes.get("e").?.object.get("speed").?.float);
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

test "printerState: maps states correctly" {
    var ctx = OctoPrintCtx{};

    // No klippy → Offline
    try testing.expectEqualStrings("Offline", ctx.printerState());

    // Klippy connected but not ready → Error
    var info = @import("../core/methods.zig").ServerInfo{ .klippy_connected = true, .klippy_state = "startup" };
    ctx.server_info = &info;
    try testing.expectEqualStrings("Error", ctx.printerState());

    // Klippy ready, default state standby → Operational
    info.klippy_state = "ready";
    try testing.expectEqualStrings("Operational", ctx.printerState());

    // Various print_stats states
    ctx.print_state = .printing;
    try testing.expectEqualStrings("Printing", ctx.printerState());
    ctx.print_state = .paused;
    try testing.expectEqualStrings("Paused", ctx.printerState());
    ctx.print_state = .complete;
    try testing.expectEqualStrings("Operational", ctx.printerState());
    // Unknown state → Error
    ctx.print_state = .other;
    try testing.expectEqualStrings("Error", ctx.printerState());
}

test "statusUpdate: extracts state from print_stats JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = OctoPrintCtx{};

    // The frame that carried the state is freed before the next query.
    {
        const state = try a.dupe(u8, "printing");
        var map = try std.json.ObjectMap.init(a, &.{}, &.{});
        try map.put(a, "state", .{ .string = state });
        try map.put(a, "filename", .{ .string = "foo.gcode" });
        ctx.statusUpdate(.{ .object = map });
        @memset(state, 'x');
    }
    try testing.expectEqual(.printing, ctx.print_state);

    // No "state" key → no change
    {
        var map = try std.json.ObjectMap.init(a, &.{}, &.{});
        try map.put(a, "filename", .{ .string = "bar.gcode" });
        const ps = std.json.Value{ .object = map };
        ctx.statusUpdate(ps);
    }
    try testing.expectEqual(.printing, ctx.print_state);

    // Non-object → no change
    ctx.statusUpdate(.null);
    try testing.expectEqual(.printing, ctx.print_state);

    // Unmapped state → other
    {
        var map = try std.json.ObjectMap.init(a, &.{}, &.{});
        try map.put(a, "state", .{ .string = "cancelled" });
        ctx.statusUpdate(.{ .object = map });
    }
    try testing.expectEqual(.other, ctx.print_state);
}

test "setKlippyDisconnected resets the print state" {
    var ctx = OctoPrintCtx{ .print_state = .paused };
    ctx.setKlippyDisconnected();
    try testing.expectEqual(.standby, ctx.print_state);
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

            var info = @import("../core/methods.zig").ServerInfo{
                .klippy_connected = buf[2] % 2 == 0,
                .klippy_state = if (buf[3] % 2 == 0) "ready" else "shutdown",
            };
            ctx.server_info = &info;
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            var temps = try @import("data_store.zig").DataStoreCtx.init(testing.allocator);
            defer temps.deinit();
            try temps.setTemperatureStoreSize(1);
            temps.setIo(threaded.io());
            const names = [_][]const u8{ "extruder", "extruder1", "extruder_invalid", "heater_bed", "temperature_sensor chamber" };
            temps.pushTemp(threaded.io(), names[buf[4] % names.len], @floatFromInt(buf[5]), 0, null, null);
            ctx.temp_store = &temps;
            _ = ctx.connectionState();
            _ = try handlePrinter(&ctx, .null, a);

            const handlers = [_]registry.HandlerFn{
                handleVersion,  handleServer,          handleLoginUser,
                handleSettings, handleJob,             handlePrinter,
                handleCommand,  handlePrinterProfiles, handleSelectFile,
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

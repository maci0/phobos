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
    /// Latest print_stats state field from Klippy. Updated by statusUpdate()
    /// called from klippy_connection's status processing.
    last_state: []const u8 = "standby",

    /// True once Klippy has completed the identify handshake (startup_complete).
    klippy_started: bool = false,
    /// True once Klippy is fully connected and ready.
    klippy_ready: bool = false,

    pub fn init() OctoPrintCtx {
        return .{};
    }

    pub fn deinit(_: *OctoPrintCtx) void {}

    /// Called by klippy_connection when a status update contains print_stats.
    /// Extracts the state field for printer_state() queries.
    pub fn statusUpdate(self: *OctoPrintCtx, print_stats: std.json.Value) void {
        if (print_stats != .object) return;
        if (print_stats.object.get("state")) |s| {
            if (s == .string) self.last_state = s.string;
        }
    }

    /// Called by klippy_connection when the Klippy ready event fires.
    pub fn setKlippyReady(self: *OctoPrintCtx) void {
        self.klippy_started = true;
        self.klippy_ready = true;
    }

    /// Called by klippy_connection when Klippy disconnects or shuts down.
    pub fn setKlippyDisconnected(self: *OctoPrintCtx) void {
        self.klippy_started = false;
        self.klippy_ready = false;
        self.last_state = "standby";
    }

    /// Maps Klippy + print_stats state to OctoPrint printer state string.
    /// Matches octoprint_compat.py printer_state().
    fn printerState(self: *const OctoPrintCtx) []const u8 {
        if (!self.klippy_started) return "Offline";
        if (!self.klippy_ready) return "Error";
        return switch (std.meta.stringToEnum(enum {
            standby,
            printing,
            paused,
            complete,
        }, self.last_state) orelse return "Error") {
            .standby, .complete => "Operational",
            .printing => "Printing",
            .paused => "Paused",
        };
    }
};

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
/// Klippy READY → safemode null; otherwise → safemode "settings".
pub fn handleServer(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o = obj(alloc);
    try o.put(alloc, "server", .{ .string = octo_version });
    try o.put(alloc, "safemode", if (ctx.klippy_ready) std.json.Value.null else .{ .string = "settings" });
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

/// GET /api/job → empty job with the current printer state.
pub fn handleJob(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
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

    try o.put(alloc, "state", .{ .string = ctx.printerState() });
    return .{ .object = o };
}

/// GET /api/printer → temperature + state flags for the live printer state.
pub fn handlePrinter(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *const OctoPrintCtx = @ptrCast(@alignCast(ctx_ptr));
    var o = obj(alloc);
    // No heaters without Klippy API → empty temperature map.
    try o.put(alloc, "temperature", .{ .object = obj(alloc) });

    const state_str = ctx.printerState();

    var flags = obj(alloc);
    try flags.put(alloc, "operational", .{ .bool = !std.mem.eql(u8, state_str, "Error") and !std.mem.eql(u8, state_str, "Offline") });
    try flags.put(alloc, "paused", .{ .bool = std.mem.eql(u8, state_str, "Paused") });
    try flags.put(alloc, "printing", .{ .bool = std.mem.eql(u8, state_str, "Printing") });
    try flags.put(alloc, "cancelling", .{ .bool = false });
    try flags.put(alloc, "pausing", .{ .bool = false });
    try flags.put(alloc, "error", .{ .bool = std.mem.eql(u8, state_str, "Error") });
    try flags.put(alloc, "ready", .{ .bool = std.mem.eql(u8, state_str, "Operational") });
    try flags.put(alloc, "closedOrError", .{ .bool = std.mem.eql(u8, state_str, "Error") or std.mem.eql(u8, state_str, "Offline") });

    var state = obj(alloc);
    try state.put(alloc, "text", .{ .string = state_str });
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
    var ctx = OctoPrintCtx{};
    ctx.setKlippyReady();
    const r = try handleServer(@ptrCast(&ctx), .null, arena.allocator());
    try testing.expect(r.object.get("safemode").? == .null);
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
    var ctx = OctoPrintCtx{};
    ctx.setKlippyReady();
    // default last_state is "standby" → "Operational"
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
    var ctx = OctoPrintCtx{};
    ctx.setKlippyReady();
    ctx.last_state = "printing";
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
    var ctx = OctoPrintCtx{};
    ctx.setKlippyReady();
    ctx.last_state = "paused";
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
    var ctx = OctoPrintCtx{};
    ctx.klippy_started = true;
    // klippy_ready is false → "Error"
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

test "printerState: maps states correctly" {
    var ctx = OctoPrintCtx{};

    // No klippy → Offline
    try testing.expectEqualStrings("Offline", ctx.printerState());

    // Klippy started but not ready → Error
    ctx.klippy_started = true;
    try testing.expectEqualStrings("Error", ctx.printerState());

    // Klippy ready, default state "standby" → Operational
    ctx.klippy_ready = true;
    try testing.expectEqualStrings("Operational", ctx.printerState());

    // Various print_stats states
    ctx.last_state = "printing";
    try testing.expectEqualStrings("Printing", ctx.printerState());
    ctx.last_state = "paused";
    try testing.expectEqualStrings("Paused", ctx.printerState());
    ctx.last_state = "complete";
    try testing.expectEqualStrings("Operational", ctx.printerState());
    // Unknown state → Error
    ctx.last_state = "cancelled";
    try testing.expectEqualStrings("Error", ctx.printerState());
}

test "statusUpdate: extracts state from print_stats JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = OctoPrintCtx{};
    ctx.klippy_ready = true;

    // Build an ObjectMap through the arena
    {
        var map = try std.json.ObjectMap.init(a, &.{}, &.{});
        try map.put(a, "state", .{ .string = "printing" });
        try map.put(a, "filename", .{ .string = "foo.gcode" });
        const ps = std.json.Value{ .object = map };
        ctx.statusUpdate(ps);
    }
    try testing.expectEqualStrings("printing", ctx.last_state);

    // No "state" key → no change
    {
        var map = try std.json.ObjectMap.init(a, &.{}, &.{});
        try map.put(a, "filename", .{ .string = "bar.gcode" });
        const ps = std.json.Value{ .object = map };
        ctx.statusUpdate(ps);
    }
    try testing.expectEqualStrings("printing", ctx.last_state);

    // Non-object → no change
    ctx.statusUpdate(.null);
    try testing.expectEqualStrings("printing", ctx.last_state);
}

test "setKlippyReady / setKlippyDisconnected" {
    var ctx = OctoPrintCtx{};

    try testing.expectEqual(false, ctx.klippy_started);
    try testing.expectEqual(false, ctx.klippy_ready);

    ctx.setKlippyReady();
    try testing.expectEqual(true, ctx.klippy_started);
    try testing.expectEqual(true, ctx.klippy_ready);

    ctx.setKlippyDisconnected();
    try testing.expectEqual(false, ctx.klippy_started);
    try testing.expectEqual(false, ctx.klippy_ready);
    try testing.expectEqualStrings("standby", ctx.last_state);
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

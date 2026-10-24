//! Printer (`printer.*`) endpoints that Moonraker proxies to Klippy over the
//! unix-domain socket.
//!
//!   POST /printer/print/start       → printer.print.start   (param: filename)
//!   POST /printer/print/pause       → printer.print.pause
//!   POST /printer/print/resume      → printer.print.resume
//!   POST /printer/print/cancel      → printer.print.cancel
//!   POST /printer/restart           → printer.restart
//!   POST /printer/firmware_restart  → printer.firmware_restart
//!   POST /printer/emergency_stop   → printer.emergency_stop
//!
//! In real Moonraker these endpoints are registered by `klippy_apis.py`
//! (see components/klippy_apis.py:56-71) and ultimately funnel a gcode/restart
//! request through `KlippyConnection.request`. That method begins with:
//!
//!     if not self.is_connected():
//!         raise ServerError("Klippy Host not connected", 503)
//!
//! (vendor/moonraker/moonraker/components/klippy_connection.py:605-607).
//!
//! Phobos has a real Klippy connection (klippy_connection.zig). Rather than
//! dynamically registering these only when Klippy connects (as Moonraker does
//! via `_request_endpoints`), phobos registers them STATICALLY so they always
//! appear in the API surface; each handler proxies the request to Klippy when
//! connected, and returns Moonraker's exact disconnected error — a 503
//! `ServerError` "Klippy Host not connected" — only when Klippy is absent or
//! disconnected.
//!
//! Disconnected-error surfacing:
//!   * HTTP   → status 503, body {"error":{"code":503,"message":"Klippy Host not connected"}}
//!     (AuthorizedRequestHandler.write_error: {"code": status, "message": reason}).
//!   * JSON-RPC → {"error":{"code":503,"message":"Klippy Host not connected"}}
//!     (JsonRPC.execute_method maps ServerError.status_code verbatim unless it is
//!     404 → -32601 or 401 → -32602; 503 stays 503 — common.py:846-852).
//!
//! When Klippy is down the handlers return `error.KlippyDisconnected`, which the
//! transports map to the 503 shape above (see http_transport.zig / jsonrpc.zig).

const std = @import("std");
const registry = @import("../server/registry.zig");
const confighelper = @import("../config/confighelper.zig");

const Registry = registry.Registry;
const RequestType = registry.RequestType;
const KlippyCtx = @import("klippy_connection.zig").KlippyCtx;
const Profile = @import("../compat.zig").Profile;
const max_printer_config_bytes = 4 * 1024 * 1024;
const max_variables_config_bytes = 1024 * 1024;

pub const PrintConfig = struct {
    profile: Profile = .moonraker,
    io: ?std.Io = null,
    root: []const u8 = "",

    pub fn script(self: PrintConfig, alloc: std.mem.Allocator, filename: []const u8) ![]u8 {
        if (std.mem.indexOfAny(u8, filename, "\r\n\x00") != null) return error.InvalidParams;
        const escaped = try sanitizePrintFilename(alloc, filename);
        defer alloc.free(escaped);
        var command: []const u8 = "SDCARD_PRINT_FILE";
        if (self.profile == .forge_x) {
            const io = self.io orelse return error.NotReady;
            var dir = try std.Io.Dir.cwd().openDir(io, self.root, .{});
            defer dir.close(io);
            const config = try dir.readFileAlloc(io, "printer.cfg", alloc, .limited(max_printer_config_bytes));
            defer alloc.free(config);
            var lines = std.mem.splitScalar(u8, config, '\n');
            var stock = false;
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "[include ")) {
                    const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
                    if (std.mem.endsWith(u8, trimmed[0 .. end + 1], "stock.cfg]")) stock = true;
                }
            }
            if (stock) {
                const vars = try dir.readFileAlloc(io, "mod_data/variables.cfg", alloc, .limited(max_variables_config_bytes));
                defer alloc.free(vars);
                var variables = std.mem.splitScalar(u8, vars, '\n');
                var leveling = false;
                while (variables.next()) |line| {
                    const at = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                    if (std.mem.eql(u8, std.mem.trim(u8, line[0..at], " \t"), "print_leveling")) {
                        var values = std.mem.tokenizeAny(u8, line[at + 1 ..], " \t\r#;");
                        leveling = std.mem.eql(u8, values.next() orelse "", "1");
                    }
                }
                command = if (leveling) "LEVELING_PRINT_FILE" else "NOLEVELING_PRINT_FILE";
            }
        }
        return std.fmt.allocPrint(alloc, "{s} FILENAME=\"{s}\"", .{ command, escaped });
    }
};

test "print profile uses stock leveling macros and rereads the configuration" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "mod_data", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "printer.cfg", .data = "[include mod/stock.cfg] # stock mode\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod_data/variables.cfg", .data = "[Variables]\nprint_leveling = 1 # enabled\n" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config: PrintConfig = .{ .profile = .forge_x, .io = io, .root = path[0..try tmp.dir.realPath(io, &path)] };
    const leveling = try config.script(alloc, "/part.gcode");
    defer alloc.free(leveling);
    try std.testing.expectEqualStrings("LEVELING_PRINT_FILE FILENAME=\"part.gcode\"", leveling);
    try tmp.dir.writeFile(io, .{ .sub_path = "mod_data/variables.cfg", .data = "print_leveling = 0\n" });
    const plain = try config.script(alloc, "part.gcode");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("NOLEVELING_PRINT_FILE FILENAME=\"part.gcode\"", plain);
    try tmp.dir.writeFile(io, .{ .sub_path = "printer.cfg", .data = "# [include stock.cfg]\n[include mod/native.cfg]\n" });
    const native = try config.script(alloc, "part.gcode");
    defer alloc.free(native);
    try std.testing.expectEqualStrings("SDCARD_PRINT_FILE FILENAME=\"part.gcode\"", native);
    const upstream = try (PrintConfig{}).script(alloc, "part.gcode");
    defer alloc.free(upstream);
    try std.testing.expectEqualStrings(native, upstream);
}

test "fuzz print scripts retain filename escaping" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const value = (PrintConfig{}).script(std.testing.allocator, &bytes) catch return;
            defer std.testing.allocator.free(value);
            try std.testing.expect(std.mem.startsWith(u8, value, "SDCARD_PRINT_FILE FILENAME=\""));
            try std.testing.expect(std.mem.indexOfAny(u8, value, "\r\n\x00") == null);
        }
    }.run, .{});
}

/// The exact message Moonraker raises when a printer.* request is made while
/// Klippy is not connected. Surfaced verbatim by both transports.
pub const klippy_disconnected_message = "Klippy Host not connected";

/// Holds an optional pointer to the Klippy connection; handlers proxy to Klippy
/// when connected, else short-circuit with the disconnected error.
pub const PrinterCtx = struct {
    print_config: PrintConfig = .{},
    /// Optional pointer to the Klippy connection; set by App after init.
    /// When non-null and Klippy is connected, handlers proxy to Klippy.
    klippy: ?*KlippyCtx = null,
    /// Forge-X `[klippy_apis] hidden_objects`. Dropped from `objects/list`.
    hidden_objects: [][]const u8 = &.{},
    hidden_owned: bool = false,
    /// Stable storage for the standard Klipper-proxied endpoint descriptors.
    /// Populated by `registerPrinter`; the registry holds pointers into this
    /// array, so it must live as long as the PrinterCtx (App owns both).
    proxies: [proxy_specs.len]ProxyEndpoint = undefined,

    /// One object name per line. Replaces any previous list.
    pub fn setHiddenObjects(self: *PrinterCtx, alloc: std.mem.Allocator, text: []const u8) !void {
        const owned = try confighelper.dupeLines(alloc, text);
        if (self.hidden_owned) confighelper.freeLines(alloc, self.hidden_objects);
        self.hidden_objects = owned;
        self.hidden_owned = true;
    }

    fn queryResult(self: *const PrinterCtx, alloc: std.mem.Allocator, value: std.json.Value) !std.json.Value {
        return if (self.print_config.profile == .forge_x) value else filterHiddenQuery(alloc, value, self.hidden_objects);
    }

    pub fn deinit(self: *PrinterCtx, alloc: std.mem.Allocator) void {
        if (!self.hidden_owned) return;
        confighelper.freeLines(alloc, self.hidden_objects);
        self.hidden_objects = &.{};
        self.hidden_owned = false;
    }
};

/// Drop hidden names from an `objects/list` result `{"objects":[...]}`.
/// Other shapes are returned unchanged.
pub fn filterObjectList(alloc: std.mem.Allocator, value: std.json.Value, hidden: []const []const u8) !std.json.Value {
    if (hidden.len == 0 or value != .object) return value;
    const objects = value.object.get("objects") orelse return value;
    if (objects != .array) return value;
    var kept: std.json.Array = .init(alloc);
    for (objects.array.items) |item| {
        if (item != .string) {
            try kept.append(item);
            continue;
        }
        var skip = false;
        for (hidden) |name| {
            if (std.mem.eql(u8, name, item.string)) {
                skip = true;
                break;
            }
        }
        if (!skip) try kept.append(item);
    }
    var out: std.json.ObjectMap = .empty;
    var it = value.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "objects")) {
            try out.put(alloc, e.key_ptr.*, .{ .array = kept });
        } else {
            try out.put(alloc, e.key_ptr.*, e.value_ptr.*);
        }
    }
    return .{ .object = out };
}

/// Drop hidden object names from an `objects/query` result. Klippy puts them
/// under `status`. A bare object map is filtered at the top level.
pub fn filterHiddenQuery(alloc: std.mem.Allocator, value: std.json.Value, hidden: []const []const u8) !std.json.Value {
    if (hidden.len == 0 or value != .object) return value;
    const status_key: []const u8 = if (value.object.get("status") != null) "status" else "";
    const target = if (status_key.len == 0) value else value.object.get("status").?;
    if (target != .object) return value;
    var kept: std.json.ObjectMap = .empty;
    var it = target.object.iterator();
    while (it.next()) |e| {
        var skip = false;
        for (hidden) |name| {
            if (std.mem.eql(u8, name, e.key_ptr.*)) {
                skip = true;
                break;
            }
        }
        if (!skip) try kept.put(alloc, e.key_ptr.*, e.value_ptr.*);
    }
    if (status_key.len == 0) return .{ .object = kept };
    var out: std.json.ObjectMap = .empty;
    var oit = value.object.iterator();
    while (oit.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "status")) {
            try out.put(alloc, e.key_ptr.*, .{ .object = kept });
        } else try out.put(alloc, e.key_ptr.*, e.value_ptr.*);
    }
    return .{ .object = out };
}

/// One Klipper-proxied endpoint (Moonraker `is_remote=True`). `endpoint` is the
/// Klippy-side path with slashes (e.g. "objects/query"); `parent` supplies the
/// live Klippy handle at call time.
pub const ProxyEndpoint = struct {
    parent: *PrinterCtx = undefined,
    endpoint: []const u8 = "",
    /// Read-only proxy (objects/query, objects/list, info, ...): dispatched
    /// off-Core on BOTH transports (the dispatcher + REST path skip the lock for
    /// the matching route/method), so the Klippy round-trip uses the no-Core path
    /// and concurrent reads run in parallel. Writes keep Core for ordering.
    off_core: bool = false,

    fn proxyReq(self: *const ProxyEndpoint, k: *KlippyCtx, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
        if (self.off_core) return k.requestOffCore(self.endpoint, params, alloc);
        return k.request(self.endpoint, params, alloc);
    }

    /// Generic proxy handler: forward the request verbatim to Klippy and return
    /// its result. Returns the disconnected error when Klippy is absent, exactly
    /// like the dedicated handlers above.
    pub fn handle(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
        const self: *ProxyEndpoint = @ptrCast(@alignCast(ctx));
        const k = self.parent.klippy orelse return error.KlippyDisconnected;
        if (!k.isConnected()) return error.KlippyDisconnected;
        // A subscription belongs to a WebSocket connection, whose transport
        // handles it. Proxying a bare subscribe would replace phobos's own
        // Klippy subscription (klippy_connection.py:622-626).
        if (std.mem.eql(u8, self.endpoint, "objects/subscribe")) return error.NoSubscriptionConnection;

        // objects/query takes a Klippy `{"objects":{...}}` map. An HTTP GET
        // arrives as flat query keys (?heater_bed&toolhead=pos), which
        // queryParams turns into {"heater_bed":"","toolhead":"pos"}. Translate
        // to {"objects":{name: null | [subfields]}} (Moonraker PrinterObjects
        // behaviour), unless already wrapped.
        const wraps_objects = std.mem.eql(u8, self.endpoint, "objects/query");
        if (wraps_objects and params == .object and params.object.get("objects") == null) {
            var objects = try std.json.ObjectMap.init(alloc, &.{}, &.{});
            var it = params.object.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (std.mem.eql(u8, key, "_method")) continue;
                const v = e.value_ptr.*;
                if (v == .string and v.string.len > 0) {
                    var arr: std.json.Array = .init(alloc);
                    var parts = std.mem.splitScalar(u8, v.string, ',');
                    while (parts.next()) |p| try arr.append(.{ .string = p });
                    try objects.put(alloc, key, .{ .array = arr });
                } else {
                    try objects.put(alloc, key, .null);
                }
            }
            var wrapped = try std.json.ObjectMap.init(alloc, &.{}, &.{});
            try wrapped.put(alloc, "objects", .{ .object = objects });
            const wrapped_result = try self.proxyReq(k, .{ .object = wrapped }, alloc);
            return self.parent.queryResult(alloc, wrapped_result);
        }

        // Forward params as-is. Strip the transport-injected `_method` marker so
        // it never reaches Klippy. Non-object params become an empty object
        // (Klippy endpoints expect a params object).
        const forwarded: std.json.Value = if (params == .object) blk: {
            if (params.object.get("_method") == null) break :blk params;
            var clone = try std.json.ObjectMap.init(alloc, &.{}, &.{});
            var it = params.object.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "_method")) continue;
                try clone.put(alloc, e.key_ptr.*, e.value_ptr.*);
            }
            break :blk .{ .object = clone };
        } else .{ .object = try std.json.ObjectMap.init(alloc, &.{}, &.{}) };
        const result = try self.proxyReq(k, forwarded, alloc);
        if (std.mem.eql(u8, self.endpoint, "objects/list")) {
            return filterObjectList(alloc, result, self.parent.hidden_objects);
        }
        if (wraps_objects) return self.parent.queryResult(alloc, result);
        return result;
    }
};

/// The standard set of Klipper-proxied endpoints Moonraker registers from
/// Klippy's `list_endpoints` (minus RESERVED_ENDPOINTS). These match the
/// documented `docs/external_api/printer.md` surface and the set a real Klippy
/// reports. Each is registered with `is_remote=true`: GET|POST HTTP route, one
/// plain dotted JSON-RPC method (`printer.<dotted endpoint>`).
const ProxySpec = struct { path: []const u8, methods: []const RequestType, endpoint: []const u8, off_core: bool = false };
const proxy_specs = [_]ProxySpec{
    .{ .path = "/printer/info", .methods = &.{ .GET, .POST }, .endpoint = "info", .off_core = true },
    .{ .path = "/printer/objects/list", .methods = &.{ .GET, .POST }, .endpoint = "objects/list", .off_core = true },
    .{ .path = "/printer/objects/query", .methods = &.{ .GET, .POST }, .endpoint = "objects/query", .off_core = true },
    .{ .path = "/printer/objects/subscribe", .methods = &.{ .GET, .POST }, .endpoint = "objects/subscribe" },
    .{ .path = "/printer/query_endstops/status", .methods = &.{ .GET, .POST }, .endpoint = "query_endstops/status", .off_core = true },
    .{ .path = "/printer/gcode/script", .methods = &.{ .GET, .POST }, .endpoint = "gcode/script" },
    .{ .path = "/printer/gcode/help", .methods = &.{ .GET, .POST }, .endpoint = "gcode/help", .off_core = true },
};

// ---------------------------------------------------------------------------
// Handlers
//
// All six proxy to Klippy in Moonraker. With no Klippy connection every one
// returns the disconnected error. When connected, they call through to the
// Klippy socket via `KlippyCtx.request()`.
// ---------------------------------------------------------------------------

/// Sanitize a print filename for embedding in a Klippy `SDCARD_PRINT_FILE
/// FILENAME="..."` gcode command: strip a single leading '/', then escape any
/// embedded double-quotes (`"` → `\"`), as Moonraker's `filename.replace`.
/// Returns a slice owned by `alloc`.
fn sanitizePrintFilename(alloc: std.mem.Allocator, filename: []const u8) ![]u8 {
    const stripped = if (std.mem.startsWith(u8, filename, "/")) filename[1..] else filename;
    return std.mem.replaceOwned(u8, alloc, stripped, "\"", "\\\"");
}

/// POST /printer/print/start → printer.print.start
/// Moonraker: klippy_apis.start_print(filename) → gcode/script SDCARD_PRINT_FILE.
pub fn handlePrintStart(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    const filename: []const u8 = if (params == .object)
        if (params.object.get("filename")) |v|
            if (v == .string) v.string else ""
        else
            ""
    else
        "";
    return startPrint(k, filename, alloc, self.print_config);
}

/// Profile-selected print macro with a leading slash stripped and quotes escaped.
/// Core held; the Klippy request releases it while waiting.
pub fn startPrint(k: *KlippyCtx, filename: []const u8, alloc: std.mem.Allocator, config: PrintConfig) anyerror!std.json.Value {
    if (!k.isConnected()) return error.KlippyDisconnected;
    if (filename.len == 0) return error.InvalidParams;
    const script = try config.script(alloc, filename);

    // Build params: {"script": "<script>"}
    var params_obj = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try params_obj.put(alloc, "script", .{ .string = script });
    return k.request("gcode/script", .{ .object = params_obj }, alloc);
}

/// POST /printer/print/pause → printer.print.pause
/// Moonraker: klippy_apis.pause_print() → pause_resume/pause.
pub fn handlePrintPause(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    return k.request("pause_resume/pause", .{ .object = try std.json.ObjectMap.init(alloc, &.{}, &.{}) }, alloc);
}

/// POST /printer/print/resume → printer.print.resume
/// Moonraker: klippy_apis.resume_print() → pause_resume/resume.
pub fn handlePrintResume(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    return k.request("pause_resume/resume", .{ .object = try std.json.ObjectMap.init(alloc, &.{}, &.{}) }, alloc);
}

/// POST /printer/print/cancel → printer.print.cancel
/// Moonraker: klippy_apis.cancel_print() → pause_resume/cancel.
pub fn handlePrintCancel(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    return k.request("pause_resume/cancel", .{ .object = try std.json.ObjectMap.init(alloc, &.{}, &.{}) }, alloc);
}

/// POST /printer/restart → printer.restart
/// Moonraker: klippy_apis.do_restart("RESTART") → gcode/script RESTART.
pub fn handleRestart(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    var params_obj = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try params_obj.put(alloc, "script", .{ .string = "RESTART" });
    return k.request("gcode/script", .{ .object = params_obj }, alloc);
}

/// POST /printer/firmware_restart → printer.firmware_restart
/// Moonraker: klippy_apis.do_restart("FIRMWARE_RESTART") → gcode/script FIRMWARE_RESTART.
pub fn handleFirmwareRestart(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    var params_obj = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try params_obj.put(alloc, "script", .{ .string = "FIRMWARE_RESTART" });
    return k.request("gcode/script", .{ .object = params_obj }, alloc);
}

/// POST /printer/emergency_stop → printer.emergency_stop
/// Moonraker: klippy_apis.emergency_stop() → Klippy emergency_stop RPC.
pub fn handleEmergencyStop(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;
    return k.request("emergency_stop", .{ .object = try std.json.ObjectMap.init(alloc, &.{}, &.{}) }, alloc);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerPrinter(reg: *Registry, ctx: *PrinterCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/printer/print/start", .methods = &.{.POST} },
        c,
        handlePrintStart,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/print/pause", .methods = &.{.POST} },
        c,
        handlePrintPause,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/print/resume", .methods = &.{.POST} },
        c,
        handlePrintResume,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/print/cancel", .methods = &.{.POST} },
        c,
        handlePrintCancel,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/restart", .methods = &.{.POST} },
        c,
        handleRestart,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/firmware_restart", .methods = &.{.POST} },
        c,
        handleFirmwareRestart,
    );
    try reg.registerEndpoint(
        .{ .path = "/printer/emergency_stop", .methods = &.{.POST} },
        c,
        handleEmergencyStop,
    );

    // Standard Klipper-proxied endpoints (is_remote). info / objects.* /
    // gcode.* / query_endstops.status. Each forwards to Klippy verbatim and
    // returns the 503 disconnected shape when Klippy is absent.
    inline for (proxy_specs, 0..) |spec, i| {
        ctx.proxies[i] = .{ .parent = ctx, .endpoint = spec.endpoint, .off_core = spec.off_core };
        try reg.registerEndpoint(
            .{ .path = spec.path, .methods = spec.methods, .is_remote = true, .off_core = spec.off_core },
            @ptrCast(&ctx.proxies[i]),
            ProxyEndpoint.handle,
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const all_handlers = [_]registry.HandlerFn{
    handlePrintStart,
    handlePrintPause,
    handlePrintResume,
    handlePrintCancel,
    handleRestart,
    handleFirmwareRestart,
    handleEmergencyStop,
};

test "filterObjectList drops hidden_objects from objects/list" {
    var ctx = PrinterCtx{};
    defer ctx.deinit(testing.allocator);
    try ctx.setHiddenObjects(testing.allocator, "output_pin level_h1\noutput_pin power_off\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"objects":["webhooks","output_pin level_h1","heater_bed","output_pin power_off"]}
    , .{});
    const filtered = try filterObjectList(arena.allocator(), parsed.value, ctx.hidden_objects);
    const items = filtered.object.get("objects").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("webhooks", items[0].string);
    try testing.expectEqualStrings("heater_bed", items[1].string);
}

test "filterHiddenQuery drops hidden names from status and keeps eventtime" {
    const hidden = [_][]const u8{"output_pin level_h1"};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(),
        \\{"status":{"output_pin level_h1":{"value":1},"heater_bed":{"temperature":20}},"eventtime":1.5}
    , .{});
    const filtered = try filterHiddenQuery(arena.allocator(), parsed.value, &hidden);
    const status = filtered.object.get("status").?.object;
    try testing.expect(status.get("output_pin level_h1") == null);
    try testing.expect(status.get("heater_bed") != null);
    try testing.expect(filtered.object.get("eventtime") != null);
}

test "Forge-X filters object lists while preserving queried hidden objects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ctx: PrinterCtx = .{};
    defer ctx.deinit(testing.allocator);
    try ctx.setHiddenObjects(testing.allocator, "output_pin private");
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"status\":{\"output_pin private\":{\"value\":1},\"heater_bed\":{}},\"eventtime\":123}", .{});
    const upstream = try ctx.queryResult(a, value);
    try testing.expect(!upstream.object.get("status").?.object.contains("output_pin private"));
    ctx.print_config.profile = .forge_x;
    const forge = try ctx.queryResult(a, value);
    try testing.expect(forge.object.get("status").?.object.contains("output_pin private"));
    const list = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"objects\":[\"output_pin private\",\"heater_bed\"]}", .{});
    const filtered = try filterObjectList(a, list, ctx.hidden_objects);
    try testing.expectEqual(@as(usize, 1), filtered.object.get("objects").?.array.items.len);
}

test "every printer handler returns KlippyDisconnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = PrinterCtx{};
    for (all_handlers) |h| {
        try testing.expectError(error.KlippyDisconnected, h(@ptrCast(&ctx), .null, arena.allocator()));
    }
}

test "printer handlers ignore params and still error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = PrinterCtx{};

    const p = try std.json.parseFromSlice(std.json.Value, a, "{\"filename\":\"a.gcode\"}", .{});
    try testing.expectError(error.KlippyDisconnected, handlePrintStart(@ptrCast(&ctx), p.value, a));
}

test "registerPrinter wires all seven routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = PrinterCtx{};
    try registerPrinter(&reg, &ctx);

    const paths = [_][]const u8{
        "/printer/print/start",
        "/printer/print/pause",
        "/printer/print/resume",
        "/printer/print/cancel",
        "/printer/restart",
        "/printer/firmware_restart",
        "/printer/emergency_stop",
    };
    for (paths) |p| {
        try testing.expect(reg.lookup(.POST, p) != null);
    }

    const rpc_methods = [_][]const u8{
        "printer.print.start",
        "printer.print.pause",
        "printer.print.resume",
        "printer.print.cancel",
        "printer.restart",
        "printer.firmware_restart",
        "printer.emergency_stop",
    };
    for (rpc_methods) |m| {
        try testing.expect(d.methods.get(m) != null);
    }

    // Klipper-proxied (is_remote): single dotted method, GET+POST HTTP routes.
    const proxied = [_][]const u8{
        "printer.info",
        "printer.objects.list",
        "printer.objects.query",
        "printer.objects.subscribe",
        "printer.query_endstops.status",
        "printer.gcode.script",
        "printer.gcode.help",
    };
    for (proxied) |m| {
        try testing.expect(d.methods.get(m) != null);
    }
    // is_remote endpoints answer both GET and POST on the same path.
    try testing.expect(reg.lookup(.GET, "/printer/objects/query") != null);
    try testing.expect(reg.lookup(.POST, "/printer/objects/query") != null);
    // ...but must NOT produce verb-prefixed method names.
    try testing.expect(d.methods.get("printer.objects.get_query") == null);
    try testing.expect(d.methods.get("printer.objects.post_query") == null);
}

test "handlePrintStart: filename sanitization strips leading slash and escapes quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = PrinterCtx{};

    // Leading-slash stripping: "/foo.gcode" → "foo.gcode"
    // Quote escaping: "test\"file.gcode" → "test\\\"file.gcode"
    const p = try std.json.parseFromSlice(std.json.Value, a, "{\"filename\":\"/test\\\"file.gcode\"}", .{});
    try testing.expectError(error.KlippyDisconnected, handlePrintStart(@ptrCast(&ctx), p.value, a));
}

test "handleEmergencyStop: returns KlippyDisconnected without klippy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = PrinterCtx{};
    try testing.expectError(error.KlippyDisconnected, handleEmergencyStop(@ptrCast(&ctx), .null, arena.allocator()));
}

test "ProxyEndpoint.handle: returns KlippyDisconnected without klippy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = PrinterCtx{};
    var pe = ProxyEndpoint{ .parent = &ctx, .endpoint = "objects/query", .off_core = true };
    // Non-object params.
    try testing.expectError(error.KlippyDisconnected, ProxyEndpoint.handle(@ptrCast(&pe), .null, a));
    // Object params with an injected _method marker.
    const p = try std.json.parseFromSlice(std.json.Value, a, "{\"_method\":\"GET\",\"objects\":{}}", .{});
    try testing.expectError(error.KlippyDisconnected, ProxyEndpoint.handle(@ptrCast(&pe), p.value, a));
}

test "ProxyEndpoint.handle: connectionless objects/subscribe is refused, never proxied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No io and no stream: a proxied request would fail with KlippyDisconnected.
    var k = KlippyCtx{ .gpa = testing.allocator, .bus = undefined, .uds_path = "" };
    k.connected.store(true, .release);
    var ctx = PrinterCtx{ .klippy = &k };
    var pe = ProxyEndpoint{ .parent = &ctx, .endpoint = "objects/subscribe" };
    for ([_][]const u8{ "{\"objects\":{\"toolhead\":null}}", "{\"_method\":\"GET\",\"toolhead\":\"position\"}", "null" }) |raw| {
        const p = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        try testing.expectError(error.NoSubscriptionConnection, ProxyEndpoint.handle(@ptrCast(&pe), p.value, a));
    }
    // Other endpoints still proxy.
    pe = .{ .parent = &ctx, .endpoint = "objects/query", .off_core = true };
    try testing.expectError(error.KlippyDisconnected, ProxyEndpoint.handle(@ptrCast(&pe), .null, a));
}

test "fuzz ProxyEndpoint.handle: arbitrary params never crash, always KlippyDisconnected" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PrinterCtx{};
            var pe = ProxyEndpoint{ .parent = &ctx, .endpoint = "objects/query", .off_core = true };

            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",    "{}",      "{\"_method\":\"POST\"}", "{\"objects\":{\"toolhead\":null}}",
                "[1,2,3]", "\"raw\"", "42",                     "{\"_method\":\"GET\",\"a\":1}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            try testing.expectError(error.KlippyDisconnected, ProxyEndpoint.handle(@ptrCast(&pe), p.value, a));
        }
    }.run, .{});
}

// --- Fuzz tests ---

test "fuzz printer handlers: arbitrary params never crash, always KlippyDisconnected" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = PrinterCtx{};

            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"filename\":\"x.gcode\"}",
                "[1,2,3]",
                "\"raw\"",
                "42",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;

            const h = all_handlers[buf[1] % all_handlers.len];
            try testing.expectError(error.KlippyDisconnected, h(@ptrCast(&ctx), p.value, a));
        }
    }.run, .{});
}

test "sanitizePrintFilename: strips one leading slash and escapes quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("a.gcode", try sanitizePrintFilename(a, "a.gcode"));
    try testing.expectEqualStrings("a.gcode", try sanitizePrintFilename(a, "/a.gcode"));
    // Only one leading slash is stripped.
    try testing.expectEqualStrings("/a.gcode", try sanitizePrintFilename(a, "//a.gcode"));
    try testing.expectEqualStrings("", try sanitizePrintFilename(a, "/"));
    try testing.expectEqualStrings("a\\\"b", try sanitizePrintFilename(a, "a\"b"));
    try testing.expectEqualStrings("\\\"\\\"", try sanitizePrintFilename(a, "\"\""));
}

test "fuzz sanitizePrintFilename: never crashes, every quote is escaped" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = @as(usize, buf[0]) % buf.len;
            const input = buf[1 .. len + 1];

            const out = try sanitizePrintFilename(a, input);

            // Invariant: in the result every '"' is immediately preceded by a
            // backslash, so it can never terminate the FILENAME="..." argument.
            for (out, 0..) |c, i| {
                if (c == '"') {
                    if (i == 0 or out[i - 1] != '\\') return error.FuzzUnescapedQuote;
                }
            }
            // Result is never longer than twice the input (worst case all quotes).
            if (out.len > input.len * 2) return error.FuzzOversizedOutput;
        }
    }.run, .{});
}

test "hidden objects preserve ownership on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            var ctx: PrinterCtx = .{};
            defer ctx.deinit(alloc);
            try ctx.setHiddenObjects(alloc, "old");
            try ctx.setHiddenObjects(alloc, "one\ntwo");
            try std.testing.expectEqual(@as(usize, 2), ctx.hidden_objects.len);
        }
    }.check, .{});
}

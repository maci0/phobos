//! Printer (`printer.*`) endpoints that Moonraker proxies to Klippy over the
//! unix-domain socket.
//!
//!   POST /printer/print/start       → printer.print.start   (param: filename)
//!   POST /printer/print/pause       → printer.print.pause
//!   POST /printer/print/resume      → printer.print.resume
//!   POST /printer/print/cancel      → printer.print.cancel
//!   POST /printer/restart           → printer.restart
//!   POST /printer/firmware_restart  → printer.firmware_restart
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
//! Phobos has NO Klippy connection yet — server.info reports
//! `klippy_connected:false`. Rather than dynamically registering these only when
//! Klippy connects (as Moonraker does via `_request_endpoints`), phobos registers
//! them STATICALLY so they appear in the API surface, and every handler returns
//! Moonraker's exact disconnected error: a 503 `ServerError` carrying the message
//! "Klippy Host not connected".
//!
//! Error surfacing:
//!   * HTTP   → status 503, body {"error":{"code":503,"message":"Klippy Host not connected"}}
//!     (AuthorizedRequestHandler.write_error: {"code": status, "message": reason}).
//!   * JSON-RPC → {"error":{"code":503,"message":"Klippy Host not connected"}}
//!     (JsonRPC.execute_method maps ServerError.status_code verbatim unless it is
//!     404 → -32601 or 401 → -32602; 503 stays 503 — common.py:846-852).
//!
//! The handlers therefore all return `error.KlippyDisconnected`, which the
//! transports map to the 503 shape above (see http_transport.zig / jsonrpc.zig).

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

/// The exact message Moonraker raises when a printer.* request is made while
/// Klippy is not connected. Surfaced verbatim by both transports.
pub const klippy_disconnected_message = "Klippy Host not connected";

/// Stateless context — every handler short-circuits with the disconnected
/// error until phobos grows a real Klippy connection.
pub const PrinterCtx = struct {
    /// Optional pointer to the Klippy connection; set by App after init.
    /// When non-null and Klippy is connected, handlers proxy to Klippy.
    klippy: ?*@import("klippy_connection.zig").KlippyCtx = null,
};

// ---------------------------------------------------------------------------
// Handlers
//
// All six proxy to Klippy in Moonraker. With no Klippy connection every one
// returns the disconnected error. When connected, they call through to the
// Klippy socket via `KlippyCtx.request()`.
// ---------------------------------------------------------------------------

/// POST /printer/print/start → printer.print.start
/// Moonraker: klippy_apis.start_print(filename) → gcode/script SDCARD_PRINT_FILE.
pub fn handlePrintStart(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const self: *PrinterCtx = @ptrCast(@alignCast(ctx));
    const k = self.klippy orelse return error.KlippyDisconnected;
    if (!k.isConnected()) return error.KlippyDisconnected;

    // Extract filename from params; build the gcode command.
    const filename: []const u8 = if (params == .object)
        if (params.object.get("filename")) |v|
            if (v == .string) v.string else ""
        else
            ""
    else
        "";
    var script_buf: [512]u8 = undefined;
    const script = if (filename.len > 0)
        try std.fmt.bufPrint(&script_buf, "SDCARD_PRINT_FILE FILENAME=\"{s}\"", .{filename})
    else
        return error.InvalidParams;

    // Build params: {"script": "<script>"}
    var params_obj = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try params_obj.put(alloc, "script", .{ .string = try alloc.dupe(u8, script) });
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
};

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

test "registerPrinter wires all six routes and JSON-RPC methods" {
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
    };
    for (rpc_methods) |m| {
        try testing.expect(d.methods.get(m) != null);
    }
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

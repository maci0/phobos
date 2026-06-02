//! Core server API method handlers: `server.info` and `server.config`.
//!
//! Shapes mirror Moonraker exactly (vendor/moonraker/moonraker/server.py
//! `_handle_info_request` / `_handle_config_request`). For the spine there is no
//! Klippy connection, so the DISCONNECTED state is reported with empty dynamic
//! collections and a small known component set.

const std = @import("std");
const build_options = @import("build_options");
const registry = @import("../server/registry.zig");
const config_mod = @import("../config/confighelper.zig");
const Connections = @import("../server/connections.zig").Connections;

/// `(major, minor, patch)` returned both as the `api_version` array and the
/// `api_version_string`. Matches Moonraker `API_VERSION = (1, 5, 0)`.
pub const api_version = [3]i64{ 1, 5, 0 };
pub const api_version_string = "1.5.0";

/// Components considered "loaded" for the spine. Moonraker reports
/// `list(self.components.keys())`; we expose the full set that phobos registers
/// so the API surface matches exactly.
pub const components = [_][]const u8{
    "application",
    "websockets",
    "internal_transport",
    "klippy_connection",
    "database",
    "file_manager",
    "authorization",
    "klippy_apis",
    "shell_command",
    "machine",
    "data_store",
    "proc_stats",
    "job_state",
    "job_queue",
    "history",
    "http_client",
    "announcements",
    "webcam",
    "extensions",
    "secrets",
    "template",
    "dbus_manager",
    "jsonrpc",
};

/// Server-wide context shared by the core handlers. Owns the bits of state the
/// `server.info` payload needs (websocket count, warnings). Allocated and held
/// by the application for the lifetime of the process.
pub const ServerInfo = struct {
    /// Number of currently-connected websocket clients. Updated from the
    /// live Connections registry when available; falls back to 0 in tests.
    websocket_count: u64 = 0,
    /// Startup/runtime warning strings (may contain '\n', substituted with
    /// "<br/>" unless `raw` is requested).
    warnings: []const []const u8 = &.{},
    /// Dynamic Klippy connection state. Updated by the KlippyCtx on state
    /// transitions. Defaults match the disconnected spine.
    klippy_connected: bool = false,
    klippy_state: []const u8 = "disconnected",
    /// Parsed config (set by App after init). Null during tests/dump-api.
    cfg: ?*const config_mod.ConfigParser = null,
    /// Config file path (set by App via setConfig). Used for the `files`
    /// field in server.config response.
    config_file_path: ?[]const u8 = null,
    /// Live connection registry (set by App.httpServer). When non-null,
    /// `serverInfoHandler` queries the live websocket count.
    conns: ?*Connections = null,
    /// Live io handle (set by App.httpServer). Needed to lock the
    /// Connections mutex for count queries.
    io: ?std.Io = null,

    pub fn ctx(self: *ServerInfo) *anyopaque {
        return @ptrCast(self);
    }
};

/// Read `raw` boolean from JSON-RPC params (object form) or query-string-style
/// values. Defaults to false, matching `web_request.get_boolean("raw", False)`.
fn getRawParam(params: std.json.Value) bool {
    switch (params) {
        .object => |o| {
            const v = o.get("raw") orelse return false;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => false,
            };
        },
        else => return false,
    }
}

/// Substitute literal newlines in `w` with "<br/>" into `alloc`-owned memory.
/// Returned slice always borrows or allocates fresh; caller owns it.
fn substituteNewlines(alloc: std.mem.Allocator, w: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, w, '\n') == null) return alloc.dupe(u8, w);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (w) |c| {
        if (c == '\n') {
            try out.appendSlice(alloc, "<br/>");
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build the `server.info` payload as an `std.json.Value`. Allocations are made
/// in `alloc` (caller owns; in production this is the per-request arena).
pub fn buildServerInfo(info: *const ServerInfo, raw: bool, alloc: std.mem.Allocator) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    try obj.put(alloc, "klippy_connected", .{ .bool = info.klippy_connected });
    try obj.put(alloc, "klippy_state", .{ .string = info.klippy_state });

    var comps: std.json.Array = .init(alloc);
    for (components) |c| try comps.append(.{ .string = c });
    try obj.put(alloc, "components", .{ .array = comps });

    try obj.put(alloc, "failed_components", .{ .array = .init(alloc) });
    var dirs: std.json.Array = .init(alloc);
    for ([_][]const u8{ "config", "logs", "gcodes" }) |d| try dirs.append(.{ .string = d });
    try obj.put(alloc, "registered_directories", .{ .array = dirs });

    var warns: std.json.Array = .init(alloc);
    for (info.warnings) |w| {
        const text = if (raw) try alloc.dupe(u8, w) else try substituteNewlines(alloc, w);
        try warns.append(.{ .string = text });
    }
    try obj.put(alloc, "warnings", .{ .array = warns });

    try obj.put(alloc, "websocket_count", .{ .integer = @intCast(info.websocket_count) });
    try obj.put(alloc, "moonraker_version", .{ .string = build_options.moonraker_version });
    try obj.put(alloc, "missing_klippy_requirements", .{ .array = .init(alloc) });

    var api_arr: std.json.Array = .init(alloc);
    for (api_version) |v| try api_arr.append(.{ .integer = v });
    try obj.put(alloc, "api_version", .{ .array = api_arr });
    try obj.put(alloc, "api_version_string", .{ .string = api_version_string });

    return .{ .object = obj };
}

/// Build the `server.config` payload. Returns the full set of Moonraker
/// component config sections (with defaults matching stock Moonraker),
/// overlayed with the parsed `ConfigParser` data when available.
/// `orig` reflects the raw config-file values (strings, pre-coercion).
/// `files` lists config files and their sections when known.
/// When `cfg` is null (tests/dump-api), returns defaults only.
///
/// Mirror of Moonraker's `_handle_config_request` which returns every
/// component's config section with per-component defaults.
pub fn buildServerConfig(alloc: std.mem.Allocator, cfg: ?*const config_mod.ConfigParser, config_file_path: ?[]const u8) !std.json.Value {
    // Moonraker's exact component config defaults, extracted from the golden
    // capture of a stock Moonraker (commit 9008485) started without Klippy.
    // Each known section gets these defaults unless overridden by the parsed
    // config file.  Sorted alphabetically to match Moonraker serialization.
    var config_obj = try buildConfigDefaults(alloc);

    // Track which sections came from the parsed config file for the `files` field.
    var file_sections: std.ArrayListUnmanaged([]const u8) = .empty;

    // Overlay parsed config sections on top of defaults.
    if (cfg) |c| {
        const sections = try c.sectionNames(alloc);
        defer alloc.free(sections);
        for (sections) |sec_name| {
            try file_sections.append(alloc, try alloc.dupe(u8, sec_name));

            var sec_obj: std.json.ObjectMap = .empty;
            const opts = try c.optionNames(sec_name, alloc);
            defer alloc.free(opts);
            for (opts) |opt_name| {
                if (c.get(sec_name, opt_name)) |val| {
                    try sec_obj.put(alloc, try alloc.dupe(u8, opt_name), .{ .string = try alloc.dupe(u8, val) });
                }
            }

            // Merge: start from defaults (if any), then overlay parsed values.
            // Preserve the default's type when coercing string values from the
            // config file (matching Moonraker's get_parsed_config behaviour).
            const existing_default = config_obj.get(sec_name);
            if (existing_default != null and existing_default.? == .object) {
                var merged: std.json.ObjectMap = .empty;
                var it = existing_default.?.object.iterator();
                while (it.next()) |entry| {
                    const default_key = entry.key_ptr.*;
                    const default_val = entry.value_ptr.*;

                    // If the parsed config has this key, coerce its string
                    // value to match the default type.
                    const override_val = sec_obj.get(default_key);
                    if (override_val != null and override_val.? == .string) {
                        const final_val = try coerceStringToValue(alloc, override_val.?.string, default_val);
                        try merged.put(alloc, try alloc.dupe(u8, default_key), final_val);
                    } else {
                        try merged.put(alloc, try alloc.dupe(u8, default_key), try deepCopyValue(alloc, default_val));
                    }
                }
                // Add any parsed keys not present in defaults.
                var oit = sec_obj.iterator();
                while (oit.next()) |entry| {
                    if (!merged.contains(entry.key_ptr.*)) {
                        try merged.put(alloc, try alloc.dupe(u8, entry.key_ptr.*), try deepCopyValue(alloc, entry.value_ptr.*));
                    }
                }
                try config_obj.put(alloc, try alloc.dupe(u8, sec_name), .{ .object = merged });
            } else {
                try config_obj.put(alloc, try alloc.dupe(u8, sec_name), .{ .object = sec_obj });
            }
        }
    }

    // Build `orig`: raw config-file values as strings (pre-coercion), with
    // a `DEFAULT` section for any DEFAULT-annotated entries.
    var orig_obj: std.json.ObjectMap = .empty;
    try orig_obj.put(alloc, "DEFAULT", .{ .object = .empty });
    if (cfg) |c| {
        const sections = try c.sectionNames(alloc);
        defer alloc.free(sections);
        for (sections) |sec_name| {
            var sec_obj: std.json.ObjectMap = .empty;
            const opts = try c.optionNames(sec_name, alloc);
            defer alloc.free(opts);
            for (opts) |opt_name| {
                if (c.get(sec_name, opt_name)) |val| {
                    try sec_obj.put(alloc, try alloc.dupe(u8, opt_name), .{ .string = try alloc.dupe(u8, val) });
                }
            }
            try orig_obj.put(alloc, try alloc.dupe(u8, sec_name), .{ .object = sec_obj });
        }
    }

    // Build `files` array (matches Moonraker's `get_file_sections`).
    var files_arr: std.json.Array = .init(alloc);
    if (config_file_path) |path| {
        const basename = std.fs.path.basename(path);
        var fobj: std.json.ObjectMap = .empty;
        try fobj.put(alloc, "filename", .{ .string = try alloc.dupe(u8, basename) });
        var sarr: std.json.Array = .init(alloc);
        for (file_sections.items) |s| {
            try sarr.append(.{ .string = s });
        }
        try fobj.put(alloc, "sections", .{ .array = sarr });
        try files_arr.append(.{ .object = fobj });
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "config", .{ .object = config_obj });
    try obj.put(alloc, "orig", .{ .object = orig_obj });
    try obj.put(alloc, "files", .{ .array = files_arr });
    return .{ .object = obj };
}

/// Build the component config section defaults matching stock Moonraker.
fn buildConfigDefaults(alloc: std.mem.Allocator) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;

    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "dev_mode", .{ .bool = false });
        const subs: std.json.Array = .init(alloc);
        try sec.put(alloc, "subscriptions", .{ .array = subs });
        try obj.put(alloc, "announcements", .{ .object = sec });
    }
    {
        var sec: std.json.ObjectMap = .empty;
        const cd: std.json.Array = .init(alloc);
        try sec.put(alloc, "cors_domains", .{ .array = cd });
        try sec.put(alloc, "default_source", .{ .string = "moonraker" });
        try sec.put(alloc, "enable_api_key", .{ .bool = true });
        try sec.put(alloc, "force_logins", .{ .bool = false });
        try sec.put(alloc, "login_timeout", .{ .integer = 90 });
        try sec.put(alloc, "max_login_attempts", .null);
        var tc: std.json.Array = .init(alloc);
        try tc.append(.{ .string = "127.0.0.1" });
        try sec.put(alloc, "trusted_clients", .{ .array = tc });
        try obj.put(alloc, "authorization", .{ .object = sec });
    }
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "gcode_store_size", .{ .integer = 0 });
        try sec.put(alloc, "temperature_store_size", .{ .integer = 0 });
        try obj.put(alloc, "data_store", .{ .object = sec });
    }
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "database_path", .null);
        try sec.put(alloc, "enable_database_debug", .{ .bool = false });
        try obj.put(alloc, "database", .{ .object = sec });
    }
    try obj.put(alloc, "dbus_manager", .{ .object = .empty });
    try obj.put(alloc, "extensions", .{ .object = .empty });
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "check_klipper_config_path", .{ .bool = true });
        try sec.put(alloc, "config_path", .null);
        try sec.put(alloc, "default_metadata_parser_timeout", .{ .float = 20.0 });
        try sec.put(alloc, "enable_config_write_access", .{ .bool = true });
        try sec.put(alloc, "enable_inotify_warnings", .{ .bool = true });
        try sec.put(alloc, "enable_object_processing", .{ .bool = false });
        try sec.put(alloc, "enable_observer_warnings", .{ .bool = true });
        try sec.put(alloc, "file_system_observer", .{ .string = "inotify" });
        try sec.put(alloc, "log_path", .null);
        try sec.put(alloc, "queue_gcode_uploads", .{ .bool = false });
        try obj.put(alloc, "file_manager", .{ .object = sec });
    }
    try obj.put(alloc, "history", .{ .object = .empty });
    try obj.put(alloc, "http_client", .{ .object = .empty });
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "automatic_transition", .{ .bool = false });
        try sec.put(alloc, "job_transition_delay", .{ .float = 0.01 });
        try sec.put(alloc, "job_transition_gcode", .{ .string = "" });
        try sec.put(alloc, "load_on_startup", .{ .bool = false });
        try obj.put(alloc, "job_queue", .{ .object = sec });
    }
    try obj.put(alloc, "job_state", .{ .object = .empty });
    try obj.put(alloc, "klippy_apis", .{ .object = .empty });
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "force_validation", .{ .bool = false });
        try sec.put(alloc, "provider", .{ .string = "none" });
        try sec.put(alloc, "shutdown_action", .{ .string = "poweroff" });
        try sec.put(alloc, "sudo_password", .null);
        try sec.put(alloc, "validate_config", .{ .bool = true });
        try sec.put(alloc, "validate_service", .{ .bool = true });
        try obj.put(alloc, "machine", .{ .object = sec });
    }
    try obj.put(alloc, "proc_stats", .{ .object = .empty });
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "secrets_path", .null);
        try obj.put(alloc, "secrets", .{ .object = sec });
    }
    {
        var sec: std.json.ObjectMap = .empty;
        try sec.put(alloc, "enable_debug_logging", .{ .bool = false });
        try sec.put(alloc, "host", .{ .string = "127.0.0.1" });
        try sec.put(alloc, "klippy_uds_address", .{ .string = "/tmp/klippy_uds" });
        try sec.put(alloc, "max_upload_size", .{ .integer = 1024 });
        try sec.put(alloc, "max_websocket_connections", .{ .integer = 50 });
        try sec.put(alloc, "port", .{ .integer = 7125 });
        try sec.put(alloc, "route_prefix", .null);
        try sec.put(alloc, "ssl_certificate_path", .null);
        try sec.put(alloc, "ssl_key_path", .null);
        try sec.put(alloc, "ssl_port", .{ .integer = 7130 });
        try obj.put(alloc, "server", .{ .object = sec });
    }
    try obj.put(alloc, "shell_command", .{ .object = .empty });
    try obj.put(alloc, "template", .{ .object = .empty });
    try obj.put(alloc, "webcam", .{ .object = .empty });

    return obj;
}

fn coerceToType(value: std.json.Value, comptime T: type) ?T {
    return switch (@typeInfo(T)) {
        .Bool => switch (value) {
            .bool => |b| b,
            else => null,
        },
        .Int, .ComptimeInt => switch (value) {
            .integer => |i| @intCast(i),
            .float => |f| @intFromFloat(f),
            .number_string => |s| std.fmt.parseInt(T, s, 10) catch null,
            else => null,
        },
        .Float, .ComptimeFloat => switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .number_string => |s| std.fmt.parseFloat(T, s) catch null,
            else => null,
        },
        .Optional => |opt| switch (value) {
            .null => null,
            else => if (coerceToType(value, opt.child)) |v| v else null,
        },
        .Array => |arr| if (value == .array) {
            const len = value.array.items.len;
            if (len == 0) @compileError("coerceToType: empty array, cannot infer length for " ++ @typeName(T));
            if (len != arr.len) return null;
            var result: T = undefined;
            for (value.array.items, 0..) |elem, idx| {
                if (coerceToType(elem, arr.child)) |v| {
                    result[idx] = v;
                } else return null;
            }
            return result;
        } else null,
        .Struct => |s| if (value == .object) blk: {
            var result: T = undefined;
            for (s.fields) |field| {
                if (value.object.get(field.name)) |fv| {
                    if (coerceToType(fv, field.type)) |v| {
                        @field(result, field.name) = v;
                    } else break :blk null;
                } else if (field.default_value) |def| {
                    @field(result, field.name) = @as(*align(1) const field.type, @ptrCast(def)).*;
                } else break :blk null;
            }
            break :blk result;
        } else null,
        else => @compileError("coerceToType: unsupported type " ++ @typeName(T)),
    };
}

/// Coerce a string (parsed from config) to a JSON value matching the type of
/// `default_val`. Mirrors Moonraker's per-component config coercion rules.
fn coerceStringToValue(alloc: std.mem.Allocator, s: []const u8, default_val: std.json.Value) !std.json.Value {
    return switch (default_val) {
        .bool => .{ .bool = std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") },
        .integer => .{ .integer = std.fmt.parseInt(i64, s, 10) catch |e| {
            std.debug.print("phobos: warning: cannot coerce '{s}' to integer: {} — keeping string\n", .{ s, e });
            return .{ .string = try alloc.dupe(u8, s) };
        } },
        .float => .{ .float = std.fmt.parseFloat(f64, s) catch |e| {
            std.debug.print("phobos: warning: cannot coerce '{s}' to float: {} — keeping string\n", .{ s, e });
            return .{ .string = try alloc.dupe(u8, s) };
        } },
        .null => .null,
        .string => .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| {
            // Split config string by newline into array elements, coercing each
            // element to match the first element's type from the default array.
            var result: std.json.Array = .init(alloc);
            if (s.len > 0) {
                var lines = std.mem.splitScalar(u8, s, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                    if (trimmed.len == 0) continue;
                    // Coerce each element using the first default element as type hint.
                    const sample = if (arr.items.len > 0) arr.items[0] else null;
                    if (sample) |sample_val| {
                        try result.append(try coerceStringToValue(alloc, trimmed, sample_val));
                    } else {
                        try result.append(.{ .string = try alloc.dupe(u8, trimmed) });
                    }
                }
            }
            return .{ .array = result };
        },
        .object => |obj| if (obj.count() == 0) .{ .object = .empty } else .{ .string = try alloc.dupe(u8, s) },
        .number_string => .{ .string = try alloc.dupe(u8, s) },
    };
}

fn deepCopyObject(alloc: std.mem.Allocator, src: std.json.ObjectMap) std.mem.Allocator.Error!std.json.ObjectMap {
    var dst: std.json.ObjectMap = .empty;
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        const val = try deepCopyValue(alloc, entry.value_ptr.*);
        try dst.put(alloc, key, val);
    }
    return dst;
}

fn deepCopyValue(alloc: std.mem.Allocator, src: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (src) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| {
            var new_arr: std.json.Array = .init(alloc);
            for (arr.items) |item| {
                try new_arr.append(try deepCopyValue(alloc, item));
            }
            return .{ .array = new_arr };
        },
        .object => |o| .{ .object = try deepCopyObject(alloc, o) },
    };
}

// --- handlers (registry/dispatcher entry points) -------------------------

pub fn serverInfoHandler(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const info: *ServerInfo = @ptrCast(@alignCast(ctx));
    // Snapshot live websocket count when connections are wired.
    if (info.conns) |c| {
        if (info.io) |io| {
            info.websocket_count = @intCast(c.count(io));
        }
    }
    return buildServerInfo(info, getRawParam(params), alloc);
}

pub fn serverConfigHandler(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const info: *const ServerInfo = @ptrCast(@alignCast(ctx));
    return buildServerConfig(alloc, info.cfg, info.config_file_path);
}

/// Register the core endpoints into a `Registry`.
pub fn registerCore(reg: *registry.Registry, info: *ServerInfo) !void {
    try reg.registerEndpoint(
        .{ .path = "/server/info", .methods = &.{.GET}, .wrap_result = true },
        info.ctx(),
        serverInfoHandler,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/config", .methods = &.{.GET}, .wrap_result = true },
        info.ctx(),
        serverConfigHandler,
    );
}

// --- tests ---------------------------------------------------------------

const jsonrpc = @import("../jsonrpc.zig");

test "buildServerInfo: disconnected shape and keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var info = ServerInfo{};
    const v = try buildServerInfo(&info, false, a);
    const o = v.object;

    try std.testing.expectEqual(false, o.get("klippy_connected").?.bool);
    try std.testing.expectEqualStrings("disconnected", o.get("klippy_state").?.string);
    try std.testing.expectEqualStrings("1.5.0", o.get("api_version_string").?.string);

    // api_version is the array form [1,5,0].
    const arr = o.get("api_version").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try std.testing.expectEqual(@as(i64, 5), arr.items[1].integer);
    try std.testing.expectEqual(@as(i64, 0), arr.items[2].integer);

    // Empty dynamic collections present.
    try std.testing.expectEqual(@as(usize, 0), o.get("failed_components").?.array.items.len);
    {
        const rd = o.get("registered_directories").?.array;
        try std.testing.expectEqual(@as(usize, 3), rd.items.len);
        try std.testing.expectEqualStrings("config", rd.items[0].string);
        try std.testing.expectEqualStrings("logs", rd.items[1].string);
        try std.testing.expectEqualStrings("gcodes", rd.items[2].string);
    }
    try std.testing.expectEqual(@as(usize, 0), o.get("missing_klippy_requirements").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), o.get("warnings").?.array.items.len);

    // Components is the known set.
    try std.testing.expectEqual(components.len, o.get("components").?.array.items.len);

    try std.testing.expectEqual(@as(i64, 0), o.get("websocket_count").?.integer);
    try std.testing.expect(o.get("moonraker_version") != null);
}

test "buildServerInfo: websocket count reflected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var info = ServerInfo{ .websocket_count = 3 };
    const v = try buildServerInfo(&info, false, arena.allocator());
    try std.testing.expectEqual(@as(i64, 3), v.object.get("websocket_count").?.integer);
}

test "buildServerInfo: raw=false substitutes newlines, raw=true preserves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const warns = [_][]const u8{"line one\nline two"};
    var info = ServerInfo{ .warnings = &warns };

    const cooked = try buildServerInfo(&info, false, a);
    try std.testing.expectEqualStrings("line one<br/>line two", cooked.object.get("warnings").?.array.items[0].string);

    const rawv = try buildServerInfo(&info, true, a);
    try std.testing.expectEqualStrings("line one\nline two", rawv.object.get("warnings").?.array.items[0].string);
}

test "getRawParam: object bool/string/missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var o1: std.json.ObjectMap = .empty;
    try o1.put(a, "raw", .{ .bool = true });
    try std.testing.expect(getRawParam(.{ .object = o1 }));

    var o2: std.json.ObjectMap = .empty;
    try o2.put(a, "raw", .{ .string = "true" });
    try std.testing.expect(getRawParam(.{ .object = o2 }));

    const o3: std.json.ObjectMap = .empty;
    try std.testing.expect(!getRawParam(.{ .object = o3 }));

    try std.testing.expect(!getRawParam(.null));
}

test "buildServerConfig: shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try buildServerConfig(arena.allocator(), null, null);
    const o = v.object;
    try std.testing.expect(o.get("config").? == .object);
    try std.testing.expect(o.get("orig").? == .object);
    try std.testing.expect(o.get("files").? == .array);

    // Verify all known sections are present in the null case.
    const config_obj = o.get("config").?.object;
    const known_sections = [_][]const u8{
        "announcements", "authorization", "data_store", "database",
        "dbus_manager", "extensions", "file_manager", "history",
        "http_client", "job_queue", "job_state", "klippy_apis",
        "machine", "proc_stats", "secrets", "server",
        "shell_command", "template", "webcam",
    };
    for (known_sections) |sec| {
        try std.testing.expect(config_obj.get(sec) != null);
        try std.testing.expect(config_obj.get(sec).? == .object);
    }
}

test "serverInfoHandler is serializable and round-trips through dispatcher" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var info = ServerInfo{};
    try d.register("server.info", info.ctx(), serverInfoHandler);

    // Handlers allocate their result tree in the request allocator; in
    // production that is a per-request arena. Mirror that here so the
    // intermediate ObjectMap/Array nodes are reclaimed.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const resp = try d.handle(
        \\{"jsonrpc":"2.0","method":"server.info","id":1}
    , arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("1.5.0", result.get("api_version_string").?.string);
    try std.testing.expectEqual(false, result.get("klippy_connected").?.bool);
}

test "registerCore wires both endpoints" {
    const alloc = std.testing.allocator;
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = registry.Registry.init(alloc, &d);
    defer reg.deinit();
    var info = ServerInfo{};

    try registerCore(&reg, &info);
    try std.testing.expect(reg.lookup(.GET, "/server/info") != null);
    try std.testing.expect(reg.lookup(.GET, "/server/config") != null);
    try std.testing.expect(d.methods.get("server.info") != null);
    try std.testing.expect(d.methods.get("server.config") != null);
}

test "fuzz_methods: buildServerInfo never crashes for arbitrary warnings/raw" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var raw_bytes: [128]u8 = undefined;
            smith.bytesWithHash(&raw_bytes, 0);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const n = @as(usize, raw_bytes[0]) % raw_bytes.len;
            const warn = raw_bytes[0..n];
            const warns = [_][]const u8{warn};
            var info = ServerInfo{ .warnings = &warns, .websocket_count = raw_bytes[1] };

            const raw_flag = (raw_bytes[1] & 1) == 0;
            const v = try buildServerInfo(&info, raw_flag, a);

            // Must serialize without error.
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            try std.testing.expect(s.len > 0);
        }
    }.run, .{});
}

test "fuzz_methods: buildServerConfig always serializes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var b: [8]u8 = undefined;
            smith.bytesWithHash(&b, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const v = try buildServerConfig(a, null, null);
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            try std.testing.expect(s.len > 0);
        }
    }.run, .{});
}

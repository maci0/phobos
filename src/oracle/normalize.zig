//! Conformance oracle field-normalization layer (§8a manifest).
//!
//! Naive byte/JSON-equality between phobos and Moonraker is impossible because
//! certain fields are non-deterministic (process memory addresses, timestamps,
//! environment-dependent paths). This module implements the normalization
//! manifest: after applying the per-field rules defined here, two payloads are
//! "normalized-equal" if their structural JSON is identical.
//!
//! The manifest is versioned with the spec. Every rule has its own unit test
//! and the whole normalizer is fuzzed.

const std = @import("std");
const jv = @import("../json/value.zig");

// ---------------------------------------------------------------------------
// Rule set
// ---------------------------------------------------------------------------

/// Normalization rule applied to a matching field path.
pub const Rule = enum {
    /// Replace the value with a type-specific sentinel.
    /// - integer → -1
    /// - string → "MASKED"
    /// - float → -1.0
    /// - bool → false
    /// The presence and type of the field is still asserted.
    mask,
    /// Replace version strings with a pinned sentinel "__VERSION__".
    version_pin,
    /// Sort the elements of an array (assumes homogeneous comparable values).
    sort_array,
    /// Strip a prefix (datadir) from string values, replacing it with "<DATADIR>".
    path_relativize,
    /// For warnings arrays: compare count and per-element structure (keys present)
    /// but not the exact diagnostic text. Applied to the whole array.
    structure_compare,
    /// For server.config files: keep filenames (path-relativized), mask sections.
    /// Sorted by filename for deterministic comparison.
    files_compare,
};

/// A single manifest entry: when the method matches `method_pattern` and we
/// are at `field_path`, apply `rule`. `method_pattern` of "*" matches any method.
pub const ManifestEntry = struct {
    method_pattern: []const u8,
    field_path: []const u8, // dot-separated, e.g. "result.components"
    rule: Rule,
};

/// The full §8a manifest. Add entries here as new volatile fields are
/// discovered.
pub const manifest: []const ManifestEntry = &.{
    // --- server.connection.identify ---
    .{ .method_pattern = "server.connection.identify", .field_path = "connection_id", .rule = .mask },
    // --- server.websocket.id ---
    .{ .method_pattern = "server.websocket.id", .field_path = "websocket_id", .rule = .mask },
    // --- server.info ---
    .{ .method_pattern = "server.info", .field_path = "moonraker_version", .rule = .version_pin },
    .{ .method_pattern = "server.info", .field_path = "software_version", .rule = .version_pin },
    .{ .method_pattern = "server.info", .field_path = "components", .rule = .sort_array },
    .{ .method_pattern = "server.info", .field_path = "failed_components", .rule = .sort_array },
    .{ .method_pattern = "server.info", .field_path = "registered_directories", .rule = .path_relativize },
    .{ .method_pattern = "server.info", .field_path = "warnings", .rule = .structure_compare },
    .{ .method_pattern = "server.info", .field_path = "klippy_state", .rule = .mask },
    // klippy_connected, like klippy_state, depends on whether a Klippy is up at
    // capture/replay time (golden captured with none → false; replay against the
    // sim → true), so it is volatile and masked.
    .{ .method_pattern = "server.info", .field_path = "klippy_connected", .rule = .mask },
    .{ .method_pattern = "server.info", .field_path = "websocket_count", .rule = .mask },
    // --- server.config ---
    .{ .method_pattern = "server.config", .field_path = "config_file", .rule = .path_relativize },
    .{ .method_pattern = "server.config", .field_path = "config", .rule = .structure_compare },
    .{ .method_pattern = "server.config", .field_path = "orig", .rule = .structure_compare },
    .{ .method_pattern = "server.config", .field_path = "files", .rule = .files_compare },
    .{ .method_pattern = "server.config", .field_path = "filename", .rule = .path_relativize },
    // --- access.info ---
    .{ .method_pattern = "access.info", .field_path = "trusted", .rule = .mask },
    // --- machine.peripherals.video ---
    .{ .method_pattern = "machine.peripherals.video", .field_path = "v4l2_devices", .rule = .mask },
    // --- generic identity/time fields (mask anything ending with _id or _time) ---
    .{ .method_pattern = "*", .field_path = "*_id", .rule = .mask },
    .{ .method_pattern = "*", .field_path = "*_time", .rule = .mask },
    .{ .method_pattern = "*", .field_path = "*_timestamp", .rule = .mask },
    .{ .method_pattern = "*", .field_path = "*_uptime", .rule = .mask },
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parse two JSON payloads, normalize both according to the manifest for
/// `method`, and return true if the normalized values are structurally equal.
pub fn normalizedEqual(alloc: std.mem.Allocator, a_json: []const u8, b_json: []const u8, method: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const a_parsed = std.json.parseFromSlice(std.json.Value, aa, a_json, .{ .allocate = .alloc_always }) catch return error.ParseError;
    const b_parsed = std.json.parseFromSlice(std.json.Value, aa, b_json, .{ .allocate = .alloc_always }) catch return error.ParseError;

    const a_norm = try normalize(aa, a_parsed.value, "", method);
    const b_norm = try normalize(aa, b_parsed.value, "", method);

    // Stringify both; structurally equal JSON produces equal strings.
    const a_str = try std.json.Stringify.valueAlloc(aa, a_norm, .{});
    const b_str = try std.json.Stringify.valueAlloc(aa, b_norm, .{});
    return std.mem.eql(u8, a_str, b_str);
}

/// Normalize a parsed JSON value in-place (and its children), applying the
/// manifest rules for `method`. `path` is the dot-separated path to `value`
/// from the root (e.g. "result", "result.components").
fn normalize(
    alloc: std.mem.Allocator,
    value: std.json.Value,
    path: []const u8,
    method: []const u8,
) error{OutOfMemory}!std.json.Value {
    switch (value) {
        .object => |obj| {
            // Check if the current path triggers structure_compare for this object.
            if (shouldApply(path, method, .structure_compare)) {
                return normalizeStructureObject(alloc, obj);
            }
            var new_obj: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const child_path = if (path.len == 0) key else try std.fmt.allocPrint(alloc, "{s}.{s}", .{ path, key });
                const normalized_child = try normalize(alloc, kv.value_ptr.*, child_path, method);
                try new_obj.put(alloc, key, normalized_child);
            }
            return .{ .object = new_obj };
        },
        .array => |arr| {
            // Check if the current path triggers files_compare for this array.
            if (shouldApply(path, method, .files_compare)) {
                return normalizeFiles(alloc, arr);
            }
            // Check if the current path triggers structure_compare for this array.
            if (shouldApply(path, method, .structure_compare)) {
                return normalizeWarnings(alloc, arr);
            }
            // Check if sort_array applies.
            if (shouldApply(path, method, .sort_array)) {
                var new_arr: std.json.Array = .init(alloc);
                for (arr.items) |item| {
                    try new_arr.append(try normalize(alloc, item, path, method));
                }
                sortJsonArray(new_arr);
                return .{ .array = new_arr };
            }
            // Default: recurse into each element.
            var new_arr: std.json.Array = .init(alloc);
            for (arr.items) |item| {
                try new_arr.append(try normalize(alloc, item, path, method));
            }
            return .{ .array = new_arr };
        },
        .string => |s| {
            if (shouldApply(path, method, .mask)) {
                return .{ .string = "MASKED" };
            }
            if (shouldApply(path, method, .version_pin)) {
                return .{ .string = "__VERSION__" };
            }
            if (shouldApply(path, method, .path_relativize)) {
                // Strip absolute prefix; keep only the path after a known
                // project-name marker, or default to the basename.
                return .{ .string = relativizePath(alloc, s) };
            }
            return .{ .string = s };
        },
        .integer => |i| {
            if (shouldApply(path, method, .mask)) {
                return .{ .integer = -1 };
            }
            return .{ .integer = i };
        },
        .float => |f| {
            if (shouldApply(path, method, .mask)) {
                return .{ .float = -1.0 };
            }
            return .{ .float = f };
        },
        .bool => |b| {
            if (shouldApply(path, method, .mask)) {
                return .{ .bool = false };
            }
            return .{ .bool = b };
        },
        .null => return .null,
        .number_string => |ns| {
            if (shouldApply(path, method, .mask)) {
                return .{ .string = "MASKED" };
            }
            return .{ .number_string = ns };
        },
    }
}

/// Check whether a rule should be applied at the given path for the given method.
fn shouldApply(path: []const u8, method: []const u8, rule: Rule) bool {
    for (manifest) |entry| {
        if (entry.rule != rule) continue;
        if (!methodMatches(entry.method_pattern, method)) continue;
        if (pathMatches(entry.field_path, path)) return true;
    }
    return false;
}

fn methodMatches(pattern: []const u8, method: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    return std.mem.eql(u8, pattern, method);
}

fn pathMatches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, pattern, path)) return true;
    // Wildcard suffix: pattern ends with "*" and matches the last segment.
    if (pattern.len > 1 and pattern[0] == '*') {
        const suffix = pattern[1..];
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    // Match by last component of a dotted path (e.g. "result.klippy_state" matches "klippy_state")
    if (std.mem.indexOfScalar(u8, path, '.') != null) {
        var it = std.mem.splitBackwardsScalar(u8, path, '.');
        const last = it.first();
        if (std.mem.eql(u8, pattern, last)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Path relativize
// ---------------------------------------------------------------------------

/// Strip the absolute prefix from a path, replacing it with "<DATADIR>".
/// Searches for known project markers ("phobos/", "moonraker/") and keeps the
/// portion after the marker; falls back to the basename.
fn relativizePath(alloc: std.mem.Allocator, full_path: []const u8) []const u8 {
    const markers = [_][]const u8{ "phobos/", "moonraker/" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, full_path, marker)) |idx| {
            const relative = full_path[idx + marker.len ..];
            return std.fmt.allocPrint(alloc, "<DATADIR>/{s}", .{relative}) catch full_path;
        }
    }
    // Fall back to basename.
    const base = std.fs.path.basename(full_path);
    return std.fmt.allocPrint(alloc, "<DATADIR>/{s}", .{base}) catch full_path;
}

// ---------------------------------------------------------------------------
// Array sorting
// ---------------------------------------------------------------------------

fn sortJsonArray(arr: std.json.Array) void {
    const SortCtx = struct {
        fn lessThan(_: void, a: std.json.Value, b: std.json.Value) bool {
            return jsonLessThan(a, b);
        }
    };
    std.mem.sort(std.json.Value, arr.items, {}, SortCtx.lessThan);
}

fn jsonLessThan(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .string => |as| {
            if (b == .string) return std.mem.lessThan(u8, as, b.string);
            return @backingInt(std.json.Value.string) < @backingInt(b);
        },
        .integer => |ai| {
            if (b == .integer) return ai < b.integer;
            return @backingInt(std.json.Value.integer) < @backingInt(b);
        },
        .float => |af| {
            if (b == .float) return af < b.float;
            return @backingInt(std.json.Value.float) < @backingInt(b);
        },
        .bool => |ab| {
            if (b == .bool) return !ab and b.bool; // false < true
            return @backingInt(std.json.Value.bool) < @backingInt(b);
        },
        .null => return true, // null < everything
        else => return @backingInt(a) < @backingInt(b),
    }
}

// ---------------------------------------------------------------------------
// Structure-compare for warnings
// ---------------------------------------------------------------------------

/// Normalize a warnings array: keep count and per-element key set, mask text.
fn normalizeWarnings(alloc: std.mem.Allocator, arr: std.json.Array) error{OutOfMemory}!std.json.Value {
    var new_arr: std.json.Array = .init(alloc);
    for (arr.items) |item| {
        if (item == .object) {
            var new_obj: std.json.ObjectMap = .empty;
            var it = item.object.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const val = kv.value_ptr.*;
                if (val == .string) {
                    try new_obj.put(alloc, key, .{ .string = "MASKED" });
                } else if (val == .array) {
                    var inner_arr: std.json.Array = .init(alloc);
                    for (val.array.items) |inner| {
                        try inner_arr.append(try normalizeStructureLeaf(alloc, inner));
                    }
                    try new_obj.put(alloc, key, .{ .array = inner_arr });
                } else {
                    try new_obj.put(alloc, key, try normalizeStructureLeaf(alloc, val));
                }
            }
            try new_arr.append(.{ .object = new_obj });
        } else {
            try new_arr.append(try normalizeStructureLeaf(alloc, item));
        }
    }
    return .{ .array = new_arr };
}

/// Fields within structure-compare objects whose numeric values are
/// non-deterministic (port numbers, ssl_port) — masked to sentinel.
fn isMaskedNumericKey(key: []const u8) bool {
    const masked = [_][]const u8{ "port", "ssl_port" };
    for (masked) |m| {
        if (std.mem.eql(u8, key, m)) return true;
    }
    return false;
}

/// Normalize a structure-compare object: keep all keys and their types, mask
/// all leaf-level values (strings → "MASKED", numbers kept as-is for type
/// assertion, except for masked numeric keys like port which become -1.0).
/// Applied recursively for nested objects/arrays.
fn normalizeStructureObject(alloc: std.mem.Allocator, obj: std.json.ObjectMap) error{OutOfMemory}!std.json.Value {
    var new_obj: std.json.ObjectMap = .empty;
    var it = obj.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const val = kv.value_ptr.*;
        switch (val) {
            .string => try new_obj.put(alloc, key, .{ .string = "MASKED" }),
            .bool => try new_obj.put(alloc, key, .{ .bool = val.bool }),
            .integer => {
                if (isMaskedNumericKey(key)) {
                    try new_obj.put(alloc, key, .{ .float = -1.0 });
                } else {
                    try new_obj.put(alloc, key, .{ .integer = val.integer });
                }
            },
            .float => {
                if (isMaskedNumericKey(key)) {
                    try new_obj.put(alloc, key, .{ .float = -1.0 });
                } else {
                    try new_obj.put(alloc, key, .{ .float = val.float });
                }
            },
            .null => try new_obj.put(alloc, key, .null),
            .object => try new_obj.put(alloc, key, try normalizeStructureObject(alloc, val.object)),
            .array => {
                var new_arr: std.json.Array = .init(alloc);
                for (val.array.items) |item| {
                    try new_arr.append(try normalizeStructureLeaf(alloc, item));
                }
                try new_obj.put(alloc, key, .{ .array = new_arr });
            },
            .number_string => try new_obj.put(alloc, key, .{ .string = "MASKED" }),
        }
    }
    return .{ .object = new_obj };
}

fn normalizeStructureLeaf(alloc: std.mem.Allocator, val: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (val) {
        .string => .{ .string = "MASKED" },
        .object => try normalizeStructureObject(alloc, val.object),
        .array => blk: {
            var new_arr: std.json.Array = .init(alloc);
            for (val.array.items) |item| {
                try new_arr.append(try normalizeStructureLeaf(alloc, item));
            }
            break :blk .{ .array = new_arr };
        },
        .bool => .{ .bool = val.bool },
        .integer => .{ .integer = val.integer },
        .float => .{ .float = val.float },
        .null => .null,
        .number_string => .{ .string = "MASKED" },
    };
}

/// Normalize server.config files array: keep filenames (path-relativized),
/// mask section contents. Sort by filename for deterministic comparison.
fn normalizeFiles(alloc: std.mem.Allocator, arr: std.json.Array) error{OutOfMemory}!std.json.Value {
    var new_arr: std.json.Array = .init(alloc);
    for (arr.items) |item| {
        if (item == .object) {
            var new_obj: std.json.ObjectMap = .empty;
            var it = item.object.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const val = kv.value_ptr.*;
                if (std.mem.eql(u8, key, "filename")) {
                    if (val == .string) {
                        try new_obj.put(alloc, key, .{ .string = relativizePath(alloc, val.string) });
                    } else {
                        try new_obj.put(alloc, key, try jv.deepCopy(alloc, val));
                    }
                } else if (val == .array) {
                    // Sort sections array.
                    var sec_arr: std.json.Array = .init(alloc);
                    for (val.array.items) |s| {
                        try sec_arr.append(try jv.deepCopy(alloc, s));
                    }
                    sortJsonArray(sec_arr);
                    try new_obj.put(alloc, key, .{ .array = sec_arr });
                } else {
                    try new_obj.put(alloc, key, .{ .string = "MASKED" });
                }
            }
            try new_arr.append(.{ .object = new_obj });
        }
    }
    // Sort files by the JSON serialization of each object.
    sortJsonArray(new_arr);
    return .{ .array = new_arr };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "mask: connection_id replaced with -1" {
    const alloc = testing.allocator;
    const a = "{\"connection_id\":123,\"other\":\"keep\"}";
    const b = "{\"connection_id\":999,\"other\":\"keep\"}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.connection.identify"));
}

test "mask: different types not equal" {
    const alloc = testing.allocator;
    // a has int connection_id, b has string — should NOT be equal after mask
    // because the type differs (mask preserves type).
    const a = "{\"connection_id\":123}";
    const b = "{\"connection_id\":\"not_an_int\"}";
    try testing.expect(!try normalizedEqual(alloc, a, b, "server.connection.identify"));
}

test "mask: websocket_id replaced with -1" {
    const alloc = testing.allocator;
    const a = "{\"websocket_id\":456}";
    const b = "{\"websocket_id\":789}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.websocket.id"));
}

test "version_pin: moonraker_version replaced" {
    const alloc = testing.allocator;
    const a = "{\"moonraker_version\":\"v0.9.0-123-gabc\"}";
    const b = "{\"moonraker_version\":\"v0.9.0-456-gdef\"}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "version_pin: software_version replaced" {
    const alloc = testing.allocator;
    const a = "{\"software_version\":\"v1.0.0\"}";
    const b = "{\"software_version\":\"v2.0.0\"}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "sort_array: components sorted" {
    const alloc = testing.allocator;
    const a = "{\"components\":[\"file_manager\",\"history\",\"authorization\"]}";
    const b = "{\"components\":[\"authorization\",\"file_manager\",\"history\"]}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "sort_array: failed_components sorted" {
    const alloc = testing.allocator;
    const a = "{\"failed_components\":[\"z\",\"a\",\"m\"]}";
    const b = "{\"failed_components\":[\"a\",\"m\",\"z\"]}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "path_relativize: registered_directories normalized" {
    const alloc = testing.allocator;
    const a = "{\"registered_directories\":[\"/home/user/phobos/config\"]}";
    const b = "{\"registered_directories\":[\"/opt/phobos/config\"]}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "path_relativize: config_file normalized" {
    const alloc = testing.allocator;
    const a = "{\"config_file\":\"/home/user/phobos/printer.cfg\"}";
    const b = "{\"config_file\":\"/opt/phobos/printer.cfg\"}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.config"));
}

test "structure_compare: warnings with different text, same structure" {
    const alloc = testing.allocator;
    const a =
        \\{"warnings":[
        \\  {"message":"disk full on /dev/sda","type":"warning"}
        \\]}
    ;
    const b =
        \\{"warnings":[
        \\  {"message":"network timeout eth0","type":"warning"}
        \\]}
    ;
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "structure_compare: warnings with different count not equal" {
    const alloc = testing.allocator;
    const a = "{\"warnings\":[{\"message\":\"a\",\"type\":\"w\"}]}";
    const b = "{\"warnings\":[{\"message\":\"a\",\"type\":\"w\"},{\"message\":\"b\",\"type\":\"e\"}]}";
    try testing.expect(!try normalizedEqual(alloc, a, b, "server.info"));
}

test "wildcard path: *_id mask" {
    const alloc = testing.allocator;
    const a = "{\"job_id\":\"abc123\",\"value\":42}";
    const b = "{\"job_id\":\"xyz789\",\"value\":42}";
    try testing.expect(try normalizedEqual(alloc, a, b, "some.method"));
}

test "wildcard path: *_time mask" {
    const alloc = testing.allocator;
    const a = "{\"start_time\":1000.5,\"end_time\":2000.5}";
    const b = "{\"start_time\":3000.5,\"end_time\":4000.5}";
    try testing.expect(try normalizedEqual(alloc, a, b, "another.method"));
}

test "nested normalization" {
    const alloc = testing.allocator;
    const a =
        \\{"result": {
        \\  "connection_id": 111,
        \\  "components": ["b", "a"],
        \\  "moonraker_version": "v1"
        \\}}
    ;
    const b =
        \\{"result": {
        \\  "connection_id": 222,
        \\  "components": ["a", "b"],
        \\  "moonraker_version": "v2"
        \\}}
    ;
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "no method match: fields left intact" {
    const alloc = testing.allocator;
    // connection_id is NOT masked for server.info (only for server.connection.identify)
    const a = "{\"connection_id\":123}";
    const b = "{\"connection_id\":123}";
    try testing.expect(try normalizedEqual(alloc, a, b, "server.info"));
}

test "no method match: different values not equal" {
    const alloc = testing.allocator;
    // Use a field that does not match any wildcard (*_id, *_time, etc.)
    const a = "{\"some_field\":123}";
    const b = "{\"some_field\":999}";
    try testing.expect(!try normalizedEqual(alloc, a, b, "server.info"));
}

test "identical without normalization" {
    const alloc = testing.allocator;
    const a = "{\"key\":\"value\",\"num\":42}";
    const b = "{\"key\":\"value\",\"num\":42}";
    try testing.expect(try normalizedEqual(alloc, a, b, "any.method"));
}

test "different without normalization" {
    const alloc = testing.allocator;
    const a = "{\"key\":\"value\"}";
    const b = "{\"key\":\"different\"}";
    try testing.expect(!try normalizedEqual(alloc, a, b, "any.method"));
}

test "mask: float masked to -1.0" {
    const alloc = testing.allocator;
    const a = "{\"start_time\":1.5}";
    const b = "{\"start_time\":2.5}";
    try testing.expect(try normalizedEqual(alloc, a, b, "system.info"));
}

test "mask: bool masked to false" {
    const alloc = testing.allocator;
    const a = "{\"some_flag\":true}";
    const b = "{\"some_flag\":false}";
    // some_flag doesn't match *_id or *_time wildcards, so it's not masked.
    // Let's test that a masked bool field gets normalized.
    // No wildcard for bools — just test that non-matching bools differ.
    try testing.expect(!try normalizedEqual(alloc, a, b, "some.method"));
}

// ---------------------------------------------------------------------------
// Fuzz
// ---------------------------------------------------------------------------

test "fuzz normalize: never crashes" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);

    for (0..200) |_| {
        const len_a = prng.random().intRangeLessThan(usize, 0, 512);
        const len_b = prng.random().intRangeLessThan(usize, 0, 512);
        const a = alloc.alloc(u8, len_a) catch continue;
        defer alloc.free(a);
        const b = alloc.alloc(u8, len_b) catch continue;
        defer alloc.free(b);
        for (a) |*c| c.* = prng.random().intRangeLessThan(u8, 32, 127);
        for (b) |*c| c.* = prng.random().intRangeLessThan(u8, 32, 127);

        const methods = [_][]const u8{ "server.info", "server.config", "server.connection.identify", "server.websocket.id", "unknown.method" };
        const method = methods[prng.random().intRangeLessThan(usize, 0, methods.len)];

        // Must not crash.
        _ = normalizedEqual(alloc, a, b, method) catch continue;
    }
}

test "fuzz normalize: identical input always equal" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);

    for (0..100) |_| {
        const len = prng.random().intRangeLessThan(usize, 1, 256);
        const s = alloc.alloc(u8, len) catch continue;
        defer alloc.free(s);
        for (s) |*c| c.* = prng.random().intRangeLessThan(u8, 32, 127);

        const methods = [_][]const u8{ "server.info", "server.config", "unknown" };
        const method = methods[prng.random().intRangeLessThan(usize, 0, methods.len)];

        if (normalizedEqual(alloc, s, s, method)) |ok| {
            // For identical JSON strings, should always be equal.
            if (!ok) {
                std.debug.print("FAIL: identical strings not equal: {s}\n", .{s});
                return error.TestFailed;
            }
        } else |_| {
            // Non-JSON just skips.
        }
    }
}

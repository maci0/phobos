//! Request argument readers with Moonraker's `WebRequest` rules (common.py
//! `_get_converted_arg` and `_parse_list`). Handlers receive their arguments as
//! a JSON object: HTTP query values arrive as strings, JSON bodies and JSON-RPC
//! params keep their JSON types.
//!
//! A missing key, or params that are not an object, reads as null from the
//! `optional*` readers and fails `required` with `error.InvalidParams`. A
//! present value, JSON null included, must convert; a failed conversion is
//! `error.InvalidParams` (HTTP 400, as Moonraker's `ServerError` default).
//!
//! - `bool`: a JSON bool, or "true"/"false" in any case.
//! - `i64`: Python `int()`: an integer, a bool (0 or 1), a float truncated
//!   toward zero, or a base-10 string with an optional sign, surrounding ASCII
//!   whitespace and single `_` separators between digits. "5.0" fails. Values
//!   outside the i64 range fail.
//! - `f64`: Python `float()`: a number, a bool, or a decimal string with
//!   optional exponent, "inf", "infinity" or "nan", and surrounding ASCII
//!   whitespace. Hexadecimal strings fail.
//! - `[]const u8`: a JSON string only. Moonraker `str()`-converts any value,
//!   but every phobos caller needs text, and `str()` of the other JSON types
//!   yields Python reprs ("None", "True", "[1]") that name no file, namespace
//!   or device; phobos rejects them instead.
//! - `std.json.Value`: Moonraker `get`: any value, unconverted.
//! - `optionalList`: `get_list` with `str` items: an array of strings, or a
//!   string split on ',' with each item trimmed and empty items dropped.
const std = @import("std");
const jv = @import("value.zig");

pub const Error = error{InvalidParams};

/// The converted value at `key`, or null when the key is absent.
pub fn optional(comptime T: type, params: std.json.Value, key: []const u8) Error!?T {
    const v = lookup(params, key) orelse return null;
    return switch (T) {
        std.json.Value => v,
        []const u8 => if (v == .string) v.string else error.InvalidParams,
        bool => switch (v) {
            .bool => |b| b,
            .string => |s| if (std.ascii.eqlIgnoreCase(s, "true")) true else if (std.ascii.eqlIgnoreCase(s, "false")) false else error.InvalidParams,
            else => error.InvalidParams,
        },
        i64 => switch (v) {
            .integer => |i| i,
            .bool => |b| @intFromBool(b),
            .float => |f| jv.floatToInt(f) orelse error.InvalidParams,
            .string, .number_string => |s| try parseInt(s),
            else => error.InvalidParams,
        },
        f64 => switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .bool => |b| @floatFromInt(@intFromBool(b)),
            .string, .number_string => |s| try parseFloat(s),
            else => error.InvalidParams,
        },
        else => @compileError("unsupported parameter type " ++ @typeName(T)),
    };
}

/// The converted value at `key`; an absent key is `error.InvalidParams`.
pub fn required(comptime T: type, params: std.json.Value, key: []const u8) Error!T {
    return (try optional(T, params, key)) orelse error.InvalidParams;
}

/// Moonraker `get_list(key)` items, or null when the key is absent. Split
/// strings borrow `params`; the returned slice is allocated in `alloc`.
pub fn optionalList(alloc: std.mem.Allocator, params: std.json.Value, key: []const u8) (Error || std.mem.Allocator.Error)!?[]const []const u8 {
    const v = lookup(params, key) orelse return null;
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(alloc);
    switch (v) {
        .array => |a| {
            try items.ensureTotalCapacityPrecise(alloc, a.items.len);
            for (a.items) |item| {
                if (item != .string) return error.InvalidParams;
                items.appendAssumeCapacity(item.string);
            }
        },
        .string => |s| {
            var it = std.mem.splitScalar(u8, s, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
                if (trimmed.len > 0) try items.append(alloc, trimmed);
            }
        },
        else => return error.InvalidParams,
    }
    return try items.toOwnedSlice(alloc);
}

fn lookup(params: std.json.Value, key: []const u8) ?std.json.Value {
    return if (params == .object) params.object.get(key) else null;
}

fn parseInt(s: []const u8) Error!i64 {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    try validateSeparators(t);
    return std.fmt.parseInt(i64, t, 10) catch error.InvalidParams;
}

fn parseFloat(s: []const u8) Error!f64 {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    try validateSeparators(t);
    // std.fmt.parseFloat also reads hexadecimal floats; Python float() does not.
    if (std.mem.indexOfAny(u8, t, "xX") != null) return error.InvalidParams;
    return std.fmt.parseFloat(f64, t) catch error.InvalidParams;
}

// Python permits underscores only between decimal digits.
fn validateSeparators(text: []const u8) Error!void {
    var offset: usize = 0;
    while (std.mem.findScalarPos(u8, text, offset, '_')) |at| {
        if (at == 0 or at + 1 == text.len or !std.ascii.isDigit(text[at - 1]) or !std.ascii.isDigit(text[at + 1])) return error.InvalidParams;
        offset = at + 1;
    }
}

// --- Tests ---

const testing = std.testing;

fn testParams(alloc: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "optional and required: absent keys and non-object params" {
    const p = try testParams(testing.allocator, "{\"a\":\"x\"}");
    defer p.deinit();
    inline for (.{ std.json.Value, []const u8, bool, i64, f64 }) |T| {
        try testing.expectEqual(null, try optional(T, p.value, "missing"));
        try testing.expectEqual(null, try optional(T, .null, "a"));
        try testing.expectError(error.InvalidParams, required(T, p.value, "missing"));
        try testing.expectError(error.InvalidParams, required(T, .{ .array = .init(testing.allocator) }, "a"));
    }
    try testing.expectEqualStrings("x", try required([]const u8, p.value, "a"));
}

test "raw value: any JSON value, null included" {
    const p = try testParams(testing.allocator, "{\"n\":null,\"o\":{\"a\":1}}");
    defer p.deinit();
    try testing.expectEqual(.null, std.meta.activeTag((try optional(std.json.Value, p.value, "n")).?));
    try testing.expectEqual(1, (try required(std.json.Value, p.value, "o")).object.get("a").?.integer);
}

test "string: only JSON strings, null is present" {
    const p = try testParams(testing.allocator,
        \\{"s":"text","e":"","n":null,"i":5,"b":true,"l":["a"],"o":{}}
    );
    defer p.deinit();
    try testing.expectEqualStrings("text", (try optional([]const u8, p.value, "s")).?);
    try testing.expectEqualStrings("", (try optional([]const u8, p.value, "e")).?);
    for ([_][]const u8{ "n", "i", "b", "l", "o" }) |k|
        try testing.expectError(error.InvalidParams, optional([]const u8, p.value, k));
}

test "bool: JSON bools and case-insensitive true/false strings" {
    const p = try testParams(testing.allocator,
        \\{"t":true,"f":false,"ts":"TRUE","fs":"False","one":"1","i":1,"n":null,"y":"yes","sp":" true"}
    );
    defer p.deinit();
    try testing.expectEqual(true, try required(bool, p.value, "t"));
    try testing.expectEqual(false, try required(bool, p.value, "f"));
    try testing.expectEqual(true, try required(bool, p.value, "ts"));
    try testing.expectEqual(false, try required(bool, p.value, "fs"));
    for ([_][]const u8{ "one", "i", "n", "y", "sp" }) |k|
        try testing.expectError(error.InvalidParams, optional(bool, p.value, k));
}

test "int: Python int() conversions" {
    const p = try testParams(testing.allocator,
        \\{"i":-7,"s":"5","ws":" +12\n","us":"1_000","f":2.9,"nf":-2.9,"b":true,
        \\ "dec":"5.0","dus":"1__0","lus":"_1","hex":"0x10","e":"","n":null,"l":[1],
        \\ "big":"9223372036854775808","bigj":9223372036854775808,"inf":1e400}
    );
    defer p.deinit();
    try testing.expectEqual(-7, try required(i64, p.value, "i"));
    try testing.expectEqual(5, try required(i64, p.value, "s"));
    try testing.expectEqual(12, try required(i64, p.value, "ws"));
    try testing.expectEqual(1000, try required(i64, p.value, "us"));
    try testing.expectEqual(2, try required(i64, p.value, "f"));
    try testing.expectEqual(-2, try required(i64, p.value, "nf"));
    try testing.expectEqual(1, try required(i64, p.value, "b"));
    for ([_][]const u8{ "dec", "dus", "lus", "hex", "e", "n", "l", "big", "bigj", "inf" }) |k|
        try testing.expectError(error.InvalidParams, optional(i64, p.value, k));
}

test "float: Python float() conversions" {
    const p = try testParams(testing.allocator,
        \\{"f":2.5,"i":3,"s":"2.5","ws":"\t-1e3 ","us":"1_0.5","inf":"-Infinity","nan":"nan",
        \\ "b":false,"big":1e400,"hex":"0x1p3","e":"","n":null,"w":"1.5x","o":{}}
    );
    defer p.deinit();
    try testing.expectEqual(2.5, try required(f64, p.value, "f"));
    try testing.expectEqual(3, try required(f64, p.value, "i"));
    try testing.expectEqual(2.5, try required(f64, p.value, "s"));
    try testing.expectEqual(-1000, try required(f64, p.value, "ws"));
    try testing.expectEqual(10.5, try required(f64, p.value, "us"));
    try testing.expectEqual(-std.math.inf(f64), try required(f64, p.value, "inf"));
    try testing.expect(std.math.isNan(try required(f64, p.value, "nan")));
    try testing.expectEqual(0, try required(f64, p.value, "b"));
    try testing.expectEqual(std.math.inf(f64), try required(f64, p.value, "big"));
    for ([_][]const u8{ "hex", "e", "n", "w", "o" }) |k|
        try testing.expectError(error.InvalidParams, optional(f64, p.value, k));
}

test "optionalList: arrays of strings and comma-separated strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try testParams(a,
        \\{"arr":["a.gcode","b c"],"csv":" a.gcode, ,b c ,","empty":"","ea":[],"mixed":["a",1],"num":5,"n":null}
    );
    try testing.expectEqual(null, try optionalList(a, p.value, "missing"));
    try testing.expectEqual(null, try optionalList(a, .null, "arr"));
    for ([_][]const u8{ "arr", "csv" }) |k| {
        const items = (try optionalList(a, p.value, k)).?;
        try testing.expectEqual(2, items.len);
        try testing.expectEqualStrings("a.gcode", items[0]);
        try testing.expectEqualStrings("b c", items[1]);
    }
    try testing.expectEqual(0, (try optionalList(a, p.value, "empty")).?.len);
    try testing.expectEqual(0, (try optionalList(a, p.value, "ea")).?.len);
    for ([_][]const u8{ "mixed", "num", "n" }) |k|
        try testing.expectError(error.InvalidParams, optionalList(a, p.value, k));
}

test "optionalList releases its slice on allocation failure" {
    const p = try testParams(testing.allocator, "{\"csv\":\"a,b,c,d,e,f,g,h,i\",\"arr\":[\"a\",\"b\"]}");
    defer p.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator, params: std.json.Value) !void {
            for ([_][]const u8{ "csv", "arr" }) |k| {
                const items = (try optionalList(alloc, params, k)).?;
                alloc.free(items);
            }
        }
    }.run, .{p.value});
}

test "numeric strings reject underscores outside digit separators" {
    for ([_][]const u8{ "_1", "1_", "1__0", "1_.0", "1._0", "1_e3", "1e_3", "1e+_3" }) |text| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var fields: std.json.ObjectMap = .empty;
        try fields.put(arena.allocator(), "value", .{ .string = text });
        const params: std.json.Value = .{ .object = fields };
        try testing.expectError(error.InvalidParams, required(i64, params, "value"));
        try testing.expectError(error.InvalidParams, required(f64, params, "value"));
    }
}

/// One fuzzed argument value: a string of fuzzed bytes or a fuzzed scalar.
fn fuzzValue(smith: *testing.Smith, buf: []u8) std.json.Value {
    return switch (smith.valueRangeAtMost(u8, 0, 4)) {
        0 => .{ .string = buf[0..smith.slice(buf)] },
        1 => .{ .integer = smith.value(i64) },
        2 => .{ .float = @bitCast(smith.value(u64)) },
        3 => .{ .bool = smith.value(bool) },
        else => .null,
    };
}

test "fuzz optional and required agree and convert consistently" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var buf: [24]u8 = undefined;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var obj: std.json.ObjectMap = .empty;
            try obj.put(arena.allocator(), "k", fuzzValue(smith, &buf));
            const params: std.json.Value = .{ .object = obj };
            inline for (.{ std.json.Value, []const u8, bool, i64, f64 }) |T| {
                if (optional(T, params, "k")) |opt| {
                    const req = try required(T, params, "k");
                    switch (T) {
                        std.json.Value => try testing.expectEqual(std.meta.activeTag(params.object.get("k").?), std.meta.activeTag(req)),
                        f64 => try testing.expectEqual(@as(u64, @bitCast(opt.?)), @as(u64, @bitCast(req))),
                        else => try testing.expectEqual(opt.?, req),
                    }
                } else |_| try testing.expectError(error.InvalidParams, required(T, params, "k"));
            }
            if (optional(i64, params, "k") catch null) |i| if (params.object.get("k").? == .string) {
                // A converted string is a decimal integer: float() reads it too.
                try testing.expectEqual(@as(f64, @floatFromInt(i)), try required(f64, params, "k"));
            };
        }
    }.run, .{});
}

test "fuzz optionalList returns trimmed non-empty items" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var buf: [48]u8 = undefined;
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var obj: std.json.ObjectMap = .empty;
            try obj.put(arena.allocator(), "k", fuzzValue(smith, &buf));
            const items = (optionalList(testing.allocator, .{ .object = obj }, "k") catch |err| {
                try testing.expectEqual(error.InvalidParams, err);
                return;
            }).?;
            defer testing.allocator.free(items);
            for (items) |item| {
                try testing.expect(item.len > 0);
                try testing.expect(std.mem.indexOfScalar(u8, item, ',') == null);
                try testing.expectEqualStrings(std.mem.trim(u8, item, &std.ascii.whitespace), item);
            }
        }
    }.run, .{});
}

/// Thin helpers over std.json for building JSON-RPC responses.
/// Provides insertion-ordered object construction and allocation-backed serialization.
const std = @import("std");

/// An owned JSON serialization result. Caller must free with allocator.free().
pub const OwnedJson = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: OwnedJson) void {
        self.allocator.free(self.bytes);
    }
};

/// Serialize any std.json.Value (or Zig value) to an owned []u8.
/// Caller owns the returned slice and must free it.
pub fn serializeAlloc(alloc: std.mem.Allocator, v: anytype) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

/// Build a JSON-RPC 2.0 success response object as an owned []u8.
/// `id` should be a std.json.Value (.integer, .string, or .null).
/// `result` is any serializable value.
/// Caller must free.
pub fn successResponse(
    alloc: std.mem.Allocator,
    id: std.json.Value,
    result: std.json.Value,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("jsonrpc") catch return error.OutOfMemory;
    jw.write("2.0") catch return error.OutOfMemory;
    jw.objectField("result") catch return error.OutOfMemory;
    jw.write(result) catch return error.OutOfMemory;
    jw.objectField("id") catch return error.OutOfMemory;
    jw.write(id) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Build a JSON-RPC 2.0 error response as an owned []u8.
/// Caller must free.
pub fn errorResponse(
    alloc: std.mem.Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("jsonrpc") catch return error.OutOfMemory;
    jw.write("2.0") catch return error.OutOfMemory;
    jw.objectField("error") catch return error.OutOfMemory;
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("code") catch return error.OutOfMemory;
    jw.write(code) catch return error.OutOfMemory;
    jw.objectField("message") catch return error.OutOfMemory;
    jw.write(message) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    jw.objectField("id") catch return error.OutOfMemory;
    jw.write(id) catch return error.OutOfMemory;
    jw.endObject() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// --- Tests ---

test "serializeAlloc: string value" {
    const alloc = std.testing.allocator;
    const v: std.json.Value = .{ .string = "hello" };
    const out = try serializeAlloc(alloc, v);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"hello\"", out);
}

test "serializeAlloc: integer value" {
    const alloc = std.testing.allocator;
    const v: std.json.Value = .{ .integer = 42 };
    const out = try serializeAlloc(alloc, v);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "successResponse: builds correct envelope" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .{ .integer = 1 };
    const result: std.json.Value = .{ .string = "ok" };
    const out = try successResponse(alloc, id, result);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":"ok","id":1}
    , out);
}

test "successResponse: null id" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .null;
    const result: std.json.Value = .{ .integer = 0 };
    const out = try successResponse(alloc, id, result);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","result":0,"id":null}
    , out);
}

test "errorResponse: builds correct envelope" {
    const alloc = std.testing.allocator;
    const id: std.json.Value = .{ .integer = 7 };
    const out = try errorResponse(alloc, id, -32601, "Method not found");
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":7}
    , out);
}

test "fuzz_value_helpers: never crash on arbitrary values" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            // Build a string value from fuzz bytes (valid UTF-8 subset: just use len)
            const len = @as(usize, buf[0]) % 32;
            const v: std.json.Value = .{ .string = buf[0..len] };
            const id: std.json.Value = .{ .integer = @as(i64, @intCast(buf[1])) };

            const s = try serializeAlloc(alloc, v);
            defer alloc.free(s);

            const r = try successResponse(alloc, id, v);
            defer alloc.free(r);

            const e = try errorResponse(alloc, id, -32600, buf[0..len]);
            defer alloc.free(e);
        }
    }.run, .{});
}

//! Adversarial-input / resource-stress scenarios.
//!
//! These exist specifically to probe the cases that a *bounded* handler stack
//! (1 MB on 32-bit targets — see main.zig) or a fixed serializer make dangerous:
//! deeply-nested JSON, very wide/large values, and the depth cap that guards the
//! serializer. Each parse/serialize runs on a freshly-spawned **1 MB-stack
//! thread** so the test exercises the real production stack size regardless of
//! the (16 MB) default the test runner itself uses — if any path overflowed
//! 1 MB, the test process would crash here.

const std = @import("std");
const jv = @import("json/value.zig");

const handler_stack = @import("io.zig").Listener.handler_stack_size; // single source of truth (io.zig)

/// Build an `n`-deep nested-array JSON text ("[[[...1...]]]").
fn nestedArrayText(alloc: std.mem.Allocator, n: usize) ![]u8 {
    const buf = try alloc.alloc(u8, n * 2 + 1);
    @memset(buf[0..n], '[');
    buf[n] = '1';
    @memset(buf[n + 1 ..], ']');
    return buf;
}

fn parseWorker(payload: []const u8, ok: *bool) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload, .{}) catch {
        ok.* = false; // graceful parse error is fine — what matters is no overflow
        return;
    };
    ok.* = true;
}

fn runOn1MbStack(comptime f: anytype, args: anytype) !void {
    const t = try std.Thread.spawn(.{ .stack_size = handler_stack }, f, args);
    t.join();
}

test "1MB stack: deeply nested JSON parses iteratively, no overflow" {
    const a = std.testing.allocator;
    // 20k levels — would blow any stack if std.json recursed per level. It does
    // not (the scanner tracks nesting on a heap BitStack), so this returns
    // cleanly. Reaching the assert at all means the 1 MB stack survived.
    const payload = try nestedArrayText(a, 20_000);
    defer a.free(payload);
    var ok = false;
    try runOn1MbStack(parseWorker, .{ payload, &ok });
    try std.testing.expect(ok);
}

fn serializeWorker(v: std.json.Value, ok: *bool) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const bytes = jv.serializeAlloc(arena.allocator(), v) catch {
        ok.* = false;
        return;
    };
    ok.* = bytes.len > 0;
}

fn buildNested(alloc: std.mem.Allocator, depth: usize) !std.json.Value {
    var v: std.json.Value = .{ .integer = 1 };
    for (0..depth) |_| {
        var arr: std.json.Array = .init(alloc);
        try arr.append(v);
        v = .{ .array = arr };
    }
    return v;
}

test "1MB stack: serializing a value at the accepted depth limit is safe" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // A value exactly at max_value_depth passes the guard and must serialize
    // without tripping std.json.Stringify's fixed nesting stack or overflowing.
    const v = try buildNested(arena.allocator(), jv.max_value_depth);
    try std.testing.expect(!jv.exceedsDepth(v, jv.max_value_depth));
    var ok = false;
    try runOn1MbStack(serializeWorker, .{ v, &ok });
    try std.testing.expect(ok);
}

test "depth guard rejects values too deep to serialize (the crash the guard prevents)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // A 1000-deep value would panic std.json.Stringify (fixed 256-level stack).
    // The guard catches it first, so it is never handed to the serializer.
    const v = try buildNested(arena.allocator(), 1000);
    try std.testing.expect(jv.exceedsDepth(v, jv.max_value_depth));
}

test "1MB stack: a very wide value (1M-element array) serializes (heap, not stack)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var arr: std.json.Array = .init(al);
    for (0..1_000_000) |i| try arr.append(.{ .integer = @intCast(i % 10) });
    const v: std.json.Value = .{ .array = arr };
    // Width is unbounded (no nesting), so this must serialize fine — exercise it
    // on the small stack to prove width doesn't consume stack.
    var ok = false;
    try runOn1MbStack(serializeWorker, .{ v, &ok });
    try std.testing.expect(ok);
}

test "1MB stack: deeply nested OBJECT (not array) parses without overflow" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    const n = 10_000;
    for (0..n) |_| try buf.appendSlice(a, "{\"a\":");
    try buf.append(a, '1');
    for (0..n) |_| try buf.append(a, '}');
    var ok = false;
    try runOn1MbStack(parseWorker, .{ buf.items, &ok });
    try std.testing.expect(ok);
}

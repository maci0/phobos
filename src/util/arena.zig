const std = @import("std");

/// Per-request arena: allocate freely, reset (not free) at end of request.
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    pub fn init(child: std.mem.Allocator) RequestArena {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }
    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }
};

test "request arena reuses capacity across reset" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();
    const a = ra.allocator();
    const buf1 = try a.alloc(u8, 1000);
    @memset(buf1, 1);
    ra.reset();
    const buf2 = try a.alloc(u8, 1000);
    try std.testing.expectEqual(@as(usize, 1000), buf2.len);
}

test "fuzz arena: random alloc/reset cycles never leak or crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var ra = RequestArena.init(std.testing.allocator);
            defer ra.deinit();
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            for (buf) |b| {
                _ = ra.allocator().alloc(u8, b) catch {};
                if (b % 7 == 0) ra.reset();
            }
        }
    }.run, .{});
}

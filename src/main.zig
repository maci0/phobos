const std = @import("std");
pub const arena = @import("util/arena.zig");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    std.debug.print("phobos 0.0.0\n", .{});
}
test { std.testing.refAllDecls(@This()); }

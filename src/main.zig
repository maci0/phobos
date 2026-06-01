const std = @import("std");
pub const arena = @import("util/arena.zig");
pub const io = @import("io.zig");
pub const core = @import("server/core.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const json_value = @import("json/value.zig");
pub const registry = @import("server/registry.zig");
pub const methods = @import("core/methods.zig");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    std.debug.print("phobos 0.0.0\n", .{});
}
test { std.testing.refAllDecls(@This()); }

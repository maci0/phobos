const std = @import("std");
pub const arena = @import("util/arena.zig");
pub const io = @import("io.zig");
pub const core = @import("server/core.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const json_value = @import("json/value.zig");
pub const registry = @import("server/registry.zig");
pub const methods = @import("core/methods.zig");
pub const http_transport = @import("http_transport.zig");
pub const connections = @import("server/connections.zig");
pub const ws_transport = @import("transport/ws.zig");
pub const testutil_server = @import("testutil/server.zig");
pub const testutil_ws_client = @import("testutil/ws_client.zig");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();

    var server_core = core.Core.init();
    var dispatcher = jsonrpc.Dispatcher.init(alloc);
    defer dispatcher.deinit();
    var reg = registry.Registry.init(alloc, &dispatcher);
    defer reg.deinit();
    var info = methods.ServerInfo{};
    try methods.registerCore(&reg, &info);

    var srv = http_transport.Server{
        .io = aio,
        .core = &server_core,
        .reg = &reg,
        .dispatcher = &dispatcher,
    };

    const host = "127.0.0.1";
    const bind_port: u16 = 7125; // Moonraker's default HTTP port.
    var listener = try io.Listener.bind(aio, host, bind_port);
    defer listener.deinit(aio);

    std.debug.print("phobos listening on http://{s}:{d}\n", .{ host, bind_port });
    try listener.serveWith(aio, @ptrCast(&srv), http_transport.connHandler);
}
test { std.testing.refAllDecls(@This()); }

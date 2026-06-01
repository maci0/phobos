//! Zeroconf / SSDP discovery shim.
//!
//! Mirrors Moonraker's `components/zeroconf.py`: a single HTTP-only,
//! unauthenticated endpoint serving the UPnP/SSDP device description XML.
//!
//!   GET /server/zeroconf/ssdp → _handle_xml_request
//!     (transports=HTTP, wrap_result=False, content_type="application/xml",
//!      auth_required=False)
//!
//! In Moonraker the handler raises a 404 ("Moonraker SSDP Device not
//! registered") until the device has been advertised over the network
//! (zeroconf.py:303-305). Phobos performs no SSDP advertisement, so the device
//! is never registered and the endpoint faithfully returns Not Found. The route
//! is registered statically so it is part of the API surface.

const std = @import("std");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

pub const ZeroconfCtx = struct {};

/// GET /server/zeroconf/ssdp → 404 (device not registered).
/// Matches Moonraker raising ServerError("Moonraker SSDP Device not
/// registered", 404) when no SSDP advertisement is active.
pub fn handleSsdp(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.NotFound;
}

pub fn registerZeroconf(reg: *Registry, ctx: *ZeroconfCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);
    try reg.registerEndpoint(
        .{
            .path = "/server/zeroconf/ssdp",
            .methods = &.{.GET},
            .transports = &.{.HTTP},
            .wrap_result = false,
            .auth_required = false,
        },
        c,
        handleSsdp,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "handleSsdp returns NotFound (device not registered)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = ZeroconfCtx{};
    try testing.expectError(error.NotFound, handleSsdp(@ptrCast(&ctx), .null, arena.allocator()));
}

test "registerZeroconf wires the ssdp route (HTTP-only, no auth, no JSON-RPC)" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = ZeroconfCtx{};
    try registerZeroconf(&reg, &ctx);

    const route = reg.lookup(.GET, "/server/zeroconf/ssdp");
    try testing.expect(route != null);
    try testing.expectEqual(false, route.?.auth_required);
    try testing.expectEqual(false, route.?.wrap_result);
    try testing.expectEqual(@as(usize, 0), d.methods.count());
}

test "fuzz handleSsdp: never crashes, always NotFound" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var ctx = ZeroconfCtx{};
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            try testing.expectError(error.NotFound, handleSsdp(@ptrCast(&ctx), .null, arena.allocator()));
        }
    }.run, .{});
}

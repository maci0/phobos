//! Klipper's read-only unassigned-node query over Linux SocketCAN.
const std = @import("std");
const Io = std.Io;

const admin_id = 0x3f0;
const reply_id = admin_id + 1;
const can_id_mask = 0x1fffffff;
const max_nodes = 256;
pub const query_timeout: Io.Duration = .fromSeconds(2);

// linux/can.h; std.Io has no CAN address family or raw-socket constructor.
const CanAddress = extern struct {
    family: u16,
    interface_index: c_int,
    address: extern union {
        transport: [2]u32,
        j1939: extern struct { name: u64, pgn: u32, address: u8 },
    },
};
const Frame = extern struct {
    id: u32,
    len: u8,
    padding: [3]u8,
    data: [8]u8 align(8),
};
const Node = struct { uuid: [12]u8, application: []const u8 };
comptime {
    std.debug.assert(@sizeOf(Frame) == 16 and @offsetOf(Frame, "data") == 8);
    std.debug.assert(@sizeOf(CanAddress) == 24 and @offsetOf(CanAddress, "interface_index") == 4);
}

/// Caller closes the returned handle through std.Io. Unavailable interfaces
/// return null, preserving the empty discovery result on hosts without CAN.
pub fn open(io: Io, interface: []const u8) !?Io.File {
    if (std.mem.indexOfScalar(u8, interface, 0) != null) return error.InvalidParams;
    const name = Io.net.Interface.Name.fromSlice(interface) catch return null;
    const resolved = name.resolve(io) catch |err| switch (err) {
        error.Canceled => return err,
        else => return null,
    };
    if (resolved.isNone() or resolved.index > std.math.maxInt(c_int)) return null;
    const fd = std.c.socket(std.c.AF.CAN, std.c.SOCK.RAW | std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK, 1);
    if (fd < 0) return null;
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    var address: CanAddress = std.mem.zeroes(CanAddress);
    address.family = std.c.AF.CAN;
    address.interface_index = @intCast(resolved.index);
    if (std.c.bind(fd, @ptrCast(&address), @sizeOf(CanAddress)) != 0) {
        file.close(io);
        return null;
    }
    return file;
}

fn decode(frame: *const Frame) ?Node {
    if (frame.id & can_id_mask != reply_id or frame.len < 7 or frame.len > frame.data.len or frame.data[0] != 0x20) return null;
    return .{
        .uuid = std.fmt.bytesToHex(frame.data[1..7].*, .lower),
        .application = if (frame.len == 7) "Unknown" else switch (frame.data[7]) {
            0x01 => "Klipper",
            0x11 => "Katapult",
            else => "Unknown",
        },
    };
}

/// Sends query command 0 only, never node assignment. Result strings belong
/// to alloc (normally an arena). The caller retains ownership of file.
pub fn query(io: Io, file: Io.File, alloc: std.mem.Allocator, timeout: Io.Duration) !std.json.Array {
    const deadline: Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = timeout, .clock = .awake }) };
    var request: Frame = std.mem.zeroes(Frame);
    request.id = admin_id;
    request.len = 1;
    const sent = try (try io.operateTimeout(.{ .net_write = .{
        .socket_handle = file.handle,
        .data = &.{std.mem.asBytes(&request)},
    } }, deadline)).net_write;
    if (sent != @sizeOf(Frame)) return error.ShortWrite;
    var nodes: std.json.Array = .init(alloc);
    while (nodes.items.len < max_nodes) {
        var frame: Frame = undefined;
        var data = [_][]u8{std.mem.asBytes(&frame)};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = file.handle, .data = &data } }, deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        const read = try result.net_read;
        if (read.data_len == 0) break;
        if (read.data_len != @sizeOf(Frame)) continue;
        const node = decode(&frame) orelse continue;
        var item: std.json.ObjectMap = .empty;
        try item.put(alloc, "uuid", .{ .string = try alloc.dupe(u8, &node.uuid) });
        try item.put(alloc, "application", .{ .string = node.application });
        try nodes.append(.{ .object = item });
    }
    return nodes;
}

test "CAN reply decoding follows the Linux layout and Klipper admin protocol" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Frame, "data"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CanAddress));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CanAddress, "interface_index"));
    var frame: Frame = .{ .id = reply_id, .len = 8, .padding = @splat(0), .data = .{ 0x20, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 1 } };
    try std.testing.expectEqualStrings("123456789abc", &decode(&frame).?.uuid);
    try std.testing.expectEqualStrings("Klipper", decode(&frame).?.application);
    frame.data[7] = 0x11;
    try std.testing.expectEqualStrings("Katapult", decode(&frame).?.application);
    frame.len = 7;
    try std.testing.expectEqualStrings("Unknown", decode(&frame).?.application);
    frame.len = 9;
    try std.testing.expect(decode(&frame) == null);
    frame.len = 8;
    frame.id = admin_id;
    try std.testing.expect(decode(&frame) == null);
}

test "CAN query exchanges native frames over a local datagram fixture and ends at its deadline" {
    const io = std.testing.io;
    var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const server = try address.bind(io, .{ .mode = .dgram });
    defer server.close(io);
    const client = try server.address.connect(io, .{ .mode = .dgram });
    defer client.close(io);
    var peer = try io.concurrent(struct {
        fn serve(pio: Io, socket: Io.net.Socket) !void {
            var bytes: [64]u8 = undefined;
            const message = try socket.receiveTimeout(pio, &bytes, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
            try std.testing.expectEqual(@as(usize, @sizeOf(Frame)), message.data.len);
            var request: Frame = undefined;
            @memcpy(std.mem.asBytes(&request), message.data);
            try std.testing.expectEqual(@as(u32, admin_id), request.id);
            try std.testing.expectEqual(@as(u8, 1), request.len);
            try std.testing.expectEqual(@as(u8, 0), request.data[0]);
            var response: Frame = .{ .id = reply_id, .len = 8, .padding = @splat(0), .data = .{ 0x20, 1, 2, 3, 4, 5, 6, 0x11 } };
            try socket.send(pio, &message.from, std.mem.asBytes(&response));
            response.id = 123;
            try socket.send(pio, &message.from, std.mem.asBytes(&response));
        }
    }.serve, .{ io, server });
    defer peer.cancel(io) catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const start = Io.Clock.Timestamp.now(io, .awake);
    const nodes = try query(io, .{ .handle = client.socket.handle, .flags = .{ .nonblocking = true } }, arena.allocator(), .fromMilliseconds(50));
    try peer.await(io);
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 1000);
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqualStrings("010203040506", nodes.items[0].object.get("uuid").?.string);
    try std.testing.expectEqualStrings("Katapult", nodes.items[0].object.get("application").?.string);
}

test "fuzz CAN reply decoding ignores malformed frames" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var frame: Frame = undefined;
            smith.bytesWithHash(std.mem.asBytes(&frame), 0);
            if (decode(&frame)) |node| {
                try std.testing.expectEqual(@as(usize, 12), node.uuid.len);
                for (node.uuid) |byte| try std.testing.expect(std.ascii.isHex(byte));
            }
            _ = open(Io.failing, std.mem.asBytes(&frame)) catch |err| switch (err) {
                error.InvalidParams => return,
                else => return err,
            };
        }
    }.run, .{});
}

test "CAN socket opening keeps unavailable interfaces empty without touching hardware" {
    try std.testing.expectEqual(null, try open(Io.failing, "can0"));
    try std.testing.expectEqual(null, try open(Io.failing, "interface-name-too-long"));
    try std.testing.expectError(error.InvalidParams, open(Io.failing, "can0\x00other"));
}

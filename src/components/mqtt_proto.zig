//! MQTT 3.1.1 control-packet codec (encode/decode).
//!
//! Pure, allocation-explicit, transport-agnostic. The client (`mqtt_client.zig`)
//! and the in-tree test broker double both build on this. Implements the subset
//! Moonraker needs: CONNECT/CONNACK, PUBLISH/PUBACK (QoS 0/1), SUBSCRIBE/SUBACK,
//! PINGREQ/PINGRESP, DISCONNECT.
//!
//! Reference: MQTT Version 3.1.1, OASIS Standard (protocol level 0x04).

const std = @import("std");

/// Control packet type (high nibble of the fixed-header first byte).
pub const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    suback = 9,
    subscribe = 8,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
    _,
};

/// CONNACK return code (byte 2 of a CONNACK packet).
pub const ConnackCode = enum(u8) {
    accepted = 0,
    unacceptable_protocol = 1,
    identifier_rejected = 2,
    server_unavailable = 3,
    bad_credentials = 4,
    not_authorized = 5,
    _,
};

pub const max_remaining_length: u32 = 268_435_455; // 0xFF,0xFF,0xFF,0x7F

// ===========================================================================
// Remaining-length varint (MQTT 1.5.5)
// ===========================================================================

/// Encode a remaining-length value into `buf` (max 4 bytes). Returns the slice.
pub fn encodeVarInt(value: u32, buf: []u8) ![]const u8 {
    if (value > max_remaining_length) return error.ValueTooLarge;
    var v = value;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.NoSpaceLeft;
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        buf[i] = byte;
        i += 1;
        if (v == 0) break;
    }
    return buf[0..i];
}

pub const VarIntResult = struct { value: u32, len: usize };

/// Decode a remaining-length varint from the front of `data`. Returns null when
/// `data` does not yet hold a complete varint (needs more bytes), errors when
/// the varint is malformed (more than 4 bytes).
pub fn decodeVarInt(data: []const u8) !?VarIntResult {
    var value: u32 = 0;
    var multiplier: u32 = 1;
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        value += @as(u32, byte & 0x7F) * multiplier;
        i += 1;
        if (byte & 0x80 == 0) return VarIntResult{ .value = value, .len = i };
        multiplier *= 128;
        if (i >= 4) return error.MalformedVarInt;
    }
    return null; // incomplete
}

// ===========================================================================
// String helpers (2-byte big-endian length prefix, MQTT 1.5.3)
// ===========================================================================

fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try list.append(alloc, @intCast(v >> 8));
    try list.append(alloc, @intCast(v & 0xFF));
}

fn appendStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLong;
    try appendU16(list, alloc, @intCast(s.len));
    try list.appendSlice(alloc, s);
}

/// Read a 2-byte-length-prefixed string at `data[off..]`. Returns the string and
/// the offset past it.
fn readStr(data: []const u8, off: usize) !struct { s: []const u8, next: usize } {
    if (off + 2 > data.len) return error.Truncated;
    const len = (@as(usize, data[off]) << 8) | data[off + 1];
    const start = off + 2;
    if (start + len > data.len) return error.Truncated;
    return .{ .s = data[start .. start + len], .next = start + len };
}

// ===========================================================================
// Encoders — each returns an owned slice the caller frees.
// ===========================================================================

/// Prepend the fixed header (type|flags + remaining length) to `body`, returning
/// a fresh owned packet. Frees nothing.
fn frame(alloc: std.mem.Allocator, ptype: PacketType, flags: u4, body: []const u8) ![]u8 {
    var rl_buf: [4]u8 = undefined;
    const rl = try encodeVarInt(@intCast(body.len), &rl_buf);
    var out = try alloc.alloc(u8, 1 + rl.len + body.len);
    out[0] = (@as(u8, @intFromEnum(ptype)) << 4) | flags;
    @memcpy(out[1 .. 1 + rl.len], rl);
    @memcpy(out[1 + rl.len ..], body);
    return out;
}

pub const ConnectOptions = struct {
    client_id: []const u8,
    keepalive_s: u16 = 60,
    clean_session: bool = true,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
    will_qos: u2 = 0,
    will_retain: bool = false,
};

/// Encode a CONNECT packet.
pub fn encodeConnect(alloc: std.mem.Allocator, opts: ConnectOptions) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // Variable header: protocol name + level + flags + keepalive.
    try appendStr(&body, alloc, "MQTT");
    try body.append(alloc, 0x04); // protocol level 4 (3.1.1)

    var flags: u8 = 0;
    if (opts.clean_session) flags |= 0x02;
    const has_will = opts.will_topic != null and opts.will_payload != null;
    if (has_will) {
        flags |= 0x04;
        flags |= (@as(u8, opts.will_qos) << 3);
        if (opts.will_retain) flags |= 0x20;
    }
    if (opts.username != null) flags |= 0x80;
    if (opts.password != null) flags |= 0x40;
    try body.append(alloc, flags);
    try appendU16(&body, alloc, opts.keepalive_s);

    // Payload: client id, [will topic, will payload], [username], [password].
    try appendStr(&body, alloc, opts.client_id);
    if (has_will) {
        try appendStr(&body, alloc, opts.will_topic.?);
        try appendStr(&body, alloc, opts.will_payload.?);
    }
    if (opts.username) |u| try appendStr(&body, alloc, u);
    if (opts.password) |p| try appendStr(&body, alloc, p);

    return frame(alloc, .connect, 0, body.items);
}

/// Encode a PUBLISH packet. `packet_id` is required (and used) only for qos > 0.
pub fn encodePublish(
    alloc: std.mem.Allocator,
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
    packet_id: u16,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try appendStr(&body, alloc, topic);
    if (qos > 0) try appendU16(&body, alloc, packet_id);
    try body.appendSlice(alloc, payload);

    var flags: u4 = 0;
    flags |= (@as(u4, qos) << 1);
    if (retain) flags |= 0x1;
    return frame(alloc, .publish, flags, body.items);
}

/// Encode a SUBSCRIBE packet for a single topic filter at the given qos.
pub fn encodeSubscribe(
    alloc: std.mem.Allocator,
    packet_id: u16,
    topic_filter: []const u8,
    qos: u2,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try appendU16(&body, alloc, packet_id);
    try appendStr(&body, alloc, topic_filter);
    try body.append(alloc, qos);

    // SUBSCRIBE fixed-header flags are reserved and MUST be 0b0010.
    return frame(alloc, .subscribe, 0b0010, body.items);
}

/// Encode a PUBACK packet (QoS 1 acknowledgement).
pub fn encodePuback(alloc: std.mem.Allocator, packet_id: u16) ![]u8 {
    var body: [2]u8 = .{ @intCast(packet_id >> 8), @intCast(packet_id & 0xFF) };
    return frame(alloc, .puback, 0, &body);
}

pub fn encodePingreq(alloc: std.mem.Allocator) ![]u8 {
    return frame(alloc, .pingreq, 0, &.{});
}

pub fn encodeDisconnect(alloc: std.mem.Allocator) ![]u8 {
    return frame(alloc, .disconnect, 0, &.{});
}

// ===========================================================================
// Decoder
// ===========================================================================

pub const Packet = struct {
    ptype: PacketType,
    flags: u4,
    /// The variable-header + payload bytes (everything after the fixed header).
    /// Borrows from the input buffer — copy if it must outlive it.
    body: []const u8,
    /// Total bytes consumed from the input (fixed header + body).
    total: usize,
};

/// Try to decode one packet from the front of `data`. Returns null when `data`
/// holds an incomplete packet (need more bytes). Errors on malformed input.
pub fn decode(data: []const u8) !?Packet {
    if (data.len < 1) return null;
    const b0 = data[0];
    const ptype: PacketType = @enumFromInt(@as(u4, @intCast(b0 >> 4)));
    const flags: u4 = @intCast(b0 & 0x0F);

    const vi = (try decodeVarInt(data[1..])) orelse return null;
    const header_len = 1 + vi.len;
    const total = header_len + vi.value;
    if (data.len < total) return null; // incomplete body
    return Packet{
        .ptype = ptype,
        .flags = flags,
        .body = data[header_len..total],
        .total = total,
    };
}

pub const PublishView = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
    packet_id: u16, // 0 when qos == 0
};

/// Interpret a decoded PUBLISH packet's body + flags.
pub fn parsePublish(pkt: Packet) !PublishView {
    if (pkt.ptype != .publish) return error.NotPublish;
    const qos: u2 = @intCast((pkt.flags >> 1) & 0x3);
    const retain = (pkt.flags & 0x1) != 0;
    const t = try readStr(pkt.body, 0);
    var off = t.next;
    var packet_id: u16 = 0;
    if (qos > 0) {
        if (off + 2 > pkt.body.len) return error.Truncated;
        packet_id = (@as(u16, pkt.body[off]) << 8) | pkt.body[off + 1];
        off += 2;
    }
    return .{
        .topic = t.s,
        .payload = pkt.body[off..],
        .qos = qos,
        .retain = retain,
        .packet_id = packet_id,
    };
}

/// Extract the CONNACK return code from a decoded CONNACK packet.
pub fn parseConnack(pkt: Packet) !ConnackCode {
    if (pkt.ptype != .connack) return error.NotConnack;
    if (pkt.body.len < 2) return error.Truncated;
    return @enumFromInt(pkt.body[1]);
}

/// Extract the packet id from a PUBACK / SUBACK packet (first two body bytes).
pub fn parsePacketId(pkt: Packet) !u16 {
    if (pkt.body.len < 2) return error.Truncated;
    return (@as(u16, pkt.body[0]) << 8) | pkt.body[1];
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "encodeVarInt/decodeVarInt: boundary values round-trip" {
    const cases = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, max_remaining_length };
    for (cases) |v| {
        var buf: [4]u8 = undefined;
        const enc = try encodeVarInt(v, &buf);
        const dec = (try decodeVarInt(enc)).?;
        try testing.expectEqual(v, dec.value);
        try testing.expectEqual(enc.len, dec.len);
    }
}

test "encodeVarInt: rejects oversized value" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.ValueTooLarge, encodeVarInt(max_remaining_length + 1, &buf));
}

test "decodeVarInt: incomplete returns null, malformed errors" {
    try testing.expectEqual(@as(?VarIntResult, null), try decodeVarInt(&.{0x80}));
    try testing.expectError(error.MalformedVarInt, decodeVarInt(&.{ 0x80, 0x80, 0x80, 0x80 }));
}

test "encodeConnect: minimal clean session" {
    const pkt = try encodeConnect(testing.allocator, .{ .client_id = "phobos" });
    defer testing.allocator.free(pkt);
    const dec = (try decode(pkt)).?;
    try testing.expectEqual(PacketType.connect, dec.ptype);
    // Protocol name "MQTT", level 4, flags 0x02 (clean), keepalive 60.
    try testing.expectEqualSlices(u8, &.{ 0, 4, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0, 60 }, dec.body[0..10]);
    // Client id.
    const cid = try readStr(dec.body, 10);
    try testing.expectEqualStrings("phobos", cid.s);
}

test "encodeConnect: with will + credentials sets flags" {
    const pkt = try encodeConnect(testing.allocator, .{
        .client_id = "c",
        .username = "u",
        .password = "p",
        .will_topic = "w/t",
        .will_payload = "off",
        .will_qos = 1,
        .will_retain = true,
    });
    defer testing.allocator.free(pkt);
    const dec = (try decode(pkt)).?;
    // Flags byte at body offset 7: clean(0x02)|will(0x04)|willqos1(0x08)|willretain(0x20)|user(0x80)|pass(0x40)
    try testing.expectEqual(@as(u8, 0x02 | 0x04 | 0x08 | 0x20 | 0x80 | 0x40), dec.body[7]);
}

test "encodePublish/parsePublish: qos0 round-trips" {
    const pkt = try encodePublish(testing.allocator, "a/b", "hello", 0, false, 0);
    defer testing.allocator.free(pkt);
    const view = try parsePublish((try decode(pkt)).?);
    try testing.expectEqualStrings("a/b", view.topic);
    try testing.expectEqualStrings("hello", view.payload);
    try testing.expectEqual(@as(u2, 0), view.qos);
    try testing.expectEqual(@as(u16, 0), view.packet_id);
}

test "encodePublish/parsePublish: qos1 carries packet id + retain" {
    const pkt = try encodePublish(testing.allocator, "t", "p", 1, true, 0x1234);
    defer testing.allocator.free(pkt);
    const view = try parsePublish((try decode(pkt)).?);
    try testing.expectEqual(@as(u2, 1), view.qos);
    try testing.expect(view.retain);
    try testing.expectEqual(@as(u16, 0x1234), view.packet_id);
    try testing.expectEqualStrings("p", view.payload);
}

test "encodeSubscribe: flags are 0b0010 and body holds id+filter+qos" {
    const pkt = try encodeSubscribe(testing.allocator, 7, "x/#", 1);
    defer testing.allocator.free(pkt);
    const dec = (try decode(pkt)).?;
    try testing.expectEqual(PacketType.subscribe, dec.ptype);
    try testing.expectEqual(@as(u4, 0b0010), dec.flags);
    try testing.expectEqual(@as(u16, 7), try parsePacketId(dec));
    const f = try readStr(dec.body, 2);
    try testing.expectEqualStrings("x/#", f.s);
    try testing.expectEqual(@as(u8, 1), dec.body[f.next]);
}

test "encodePuback/encodePingreq/encodeDisconnect shapes" {
    const pa = try encodePuback(testing.allocator, 0x0102);
    defer testing.allocator.free(pa);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x02, 0x01, 0x02 }, pa);
    const pr = try encodePingreq(testing.allocator);
    defer testing.allocator.free(pr);
    try testing.expectEqualSlices(u8, &.{ 0xC0, 0x00 }, pr);
    const dc = try encodeDisconnect(testing.allocator);
    defer testing.allocator.free(dc);
    try testing.expectEqualSlices(u8, &.{ 0xE0, 0x00 }, dc);
}

test "parseConnack: accepted and rejected codes" {
    const ok = try frame(testing.allocator, .connack, 0, &.{ 0, 0 });
    defer testing.allocator.free(ok);
    try testing.expectEqual(ConnackCode.accepted, try parseConnack((try decode(ok)).?));
    const bad = try frame(testing.allocator, .connack, 0, &.{ 0, 5 });
    defer testing.allocator.free(bad);
    try testing.expectEqual(ConnackCode.not_authorized, try parseConnack((try decode(bad)).?));
}

test "decode: incomplete packet returns null" {
    // Fixed header says remaining length 10 but only 3 bytes follow.
    try testing.expectEqual(@as(?Packet, null), try decode(&.{ 0x30, 0x0A, 0x00, 0x01 }));
    try testing.expectEqual(@as(?Packet, null), try decode(&.{}));
}

test "decode: multiple packets — total advances correctly" {
    const a = try encodePingreq(testing.allocator);
    defer testing.allocator.free(a);
    const b = try encodePuback(testing.allocator, 9);
    defer testing.allocator.free(b);
    var both = try testing.allocator.alloc(u8, a.len + b.len);
    defer testing.allocator.free(both);
    @memcpy(both[0..a.len], a);
    @memcpy(both[a.len..], b);

    const p1 = (try decode(both)).?;
    try testing.expectEqual(PacketType.pingreq, p1.ptype);
    const p2 = (try decode(both[p1.total..])).?;
    try testing.expectEqual(PacketType.puback, p2.ptype);
    try testing.expectEqual(@as(u16, 9), try parsePacketId(p2));
}

// --- Fuzz tests ---

test "fuzz decode: arbitrary bytes never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            const data = buf[1 .. 1 + @min(n, buf.len - 1)];
            const pkt = decode(data) catch return;
            if (pkt) |p| {
                if (p.ptype == .publish) _ = parsePublish(p) catch {};
                if (p.ptype == .connack) _ = parseConnack(p) catch {};
                _ = parsePacketId(p) catch {};
            }
        }
    }.run, .{});
}

test "fuzz decodeVarInt: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = decodeVarInt(&buf) catch {};
        }
    }.run, .{});
}

test "fuzz encodeConnect: arbitrary ids/creds never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const split = @as(usize, buf[0]) % buf.len;
            const pkt = encodeConnect(testing.allocator, .{
                .client_id = buf[1..@max(1, split)],
                .username = buf[@max(1, split)..],
            }) catch return;
            defer testing.allocator.free(pkt);
            _ = decode(pkt) catch {};
        }
    }.run, .{});
}

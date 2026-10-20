//! MQTT 3.1, 3.1.1 and 5 control-packet codec.
//!
//! Transport-agnostic. The client (`mqtt_client.zig`) and its test broker
//! double build on this. Implements the subset Moonraker needs: CONNECT/CONNACK,
//! PUBLISH with the QoS 1 and QoS 2 acknowledgements, SUBSCRIBE/SUBACK,
//! PINGREQ/PINGRESP and DISCONNECT.
//!
//! Protocol levels 3, 4 and 5 use separate wire layouts; no version fallback.

const std = @import("std");

pub const Protocol = enum(u8) {
    v31,
    v311,
    v5,

    pub fn parse(value: []const u8) !Protocol {
        return std.StaticStringMap(Protocol).initComptime(.{ .{ "v3.1", .v31 }, .{ "v3.1.1", .v311 }, .{ "v5", .v5 } }).get(value) orelse error.InvalidProtocol;
    }
};

/// Control packet type (high nibble of the fixed-header first byte).
pub const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
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
pub const receive_maximum: u16 = 32;
pub const max_packet_length: u32 = 8 * 1024 * 1024;

/// Fixed two-byte packets (MQTT 3.12 and 3.14).
pub const pingreq = [2]u8{ 0xC0, 0x00 };
pub const disconnect = [2]u8{ 0xE0, 0x00 };

// ===========================================================================
// Remaining-length varint (MQTT 1.5.5)
// ===========================================================================

/// Encode a remaining-length value into `buf` (max 4 bytes). Returns the slice.
pub fn encodeVarInt(value: u32, buf: []u8) ![]const u8 {
    if (value > max_remaining_length) return error.ValueTooLarge;
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeLeb128(@as(u28, @intCast(value))) catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// Read MQTT's four-byte unsigned LEB128 length without consuming packet data.
pub fn readVarInt(reader: *std.Io.Reader) !u32 {
    // One byte of lookahead keeps the following packet bytes in the source reader.
    var buffer: [1]u8 = undefined;
    var limited = reader.limited(.limited(4), &buffer);
    const value = limited.interface.takeLeb128(u28) catch |err| return switch (err) {
        error.EndOfStream => if (limited.remaining == .nothing) error.MalformedVarInt else error.EndOfStream,
        error.Overflow => error.MalformedVarInt,
        error.ReadFailed => error.ReadFailed,
    };
    const count = 4 - limited.remaining.toInt().?;
    if (count > 1 and value < (@as(u28, 1) << @as(u5, @intCast(7 * (count - 1))))) return error.MalformedVarInt;
    return value;
}

// ===========================================================================
// String helpers (2-byte big-endian length prefix, MQTT 1.5.3)
// ===========================================================================

fn appendU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    var be: [2]u8 = undefined;
    std.mem.writeInt(u16, &be, v, .big);
    try list.appendSlice(alloc, &be);
}

fn appendStr(list: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    if (s.len > std.math.maxInt(u16)) return error.StringTooLong;
    try appendU16(list, alloc, @intCast(s.len));
    try list.appendSlice(alloc, s);
}

/// Read a 2-byte-length-prefixed string at `data[off..]`. Returns the string and
/// the offset past it.
fn readStr(data: []const u8, off: usize) !struct { s: []const u8, next: usize } {
    if (data.len - @min(off, data.len) < 2) return error.Truncated;
    const len: usize = std.mem.readInt(u16, data[off..][0..2], .big);
    const start = off + 2;
    if (data.len - start < len) return error.Truncated;
    return .{ .s = data[start .. start + len], .next = start + len };
}

// ===========================================================================
// Encoders — each returns an owned slice the caller frees.
// ===========================================================================

/// Prepend the fixed header (type|flags + remaining length) to `body`, returning
/// a fresh owned packet. Frees nothing.
fn frame(alloc: std.mem.Allocator, ptype: PacketType, flags: u4, body: []const u8) ![]u8 {
    if (body.len > max_remaining_length) return error.ValueTooLarge;
    var rl_buf: [4]u8 = undefined;
    const rl = try encodeVarInt(@intCast(body.len), &rl_buf);
    var out = try alloc.alloc(u8, 1 + rl.len + body.len);
    out[0] = (@as(u8, @backingInt(ptype)) << 4) | flags;
    @memcpy(out[1 .. 1 + rl.len], rl);
    @memcpy(out[1 + rl.len ..], body);
    return out;
}

pub const ConnectOptions = struct {
    protocol: Protocol = .v311,
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

/// MQTT UTF-8 strings exclude NUL and have a two-byte byte-length prefix.
fn validateString(value: []const u8) error{InvalidTopic}!void {
    if (value.len > std.math.maxInt(u16) or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidTopic;
}

pub fn validateTopicName(topic: []const u8) error{InvalidTopic}!void {
    try validateString(topic);
    if (topic.len == 0 or std.mem.indexOfAny(u8, topic, "#+") != null) return error.InvalidTopic;
}

pub fn validateTopicFilter(topic: []const u8) error{InvalidTopic}!void {
    try validateString(topic);
    if (topic.len == 0) return error.InvalidTopic;
    var levels = std.mem.splitScalar(u8, topic, '/');
    while (levels.next()) |level| {
        if (std.mem.indexOfScalar(u8, level, '#') != null and (!std.mem.eql(u8, level, "#") or levels.peek() != null)) return error.InvalidTopic;
        if (std.mem.indexOfScalar(u8, level, '+') != null and !std.mem.eql(u8, level, "+")) return error.InvalidTopic;
    }
}

/// Encode a CONNECT packet.
pub fn encodeConnect(alloc: std.mem.Allocator, opts: ConnectOptions) ![]u8 {
    try validateString(opts.client_id);
    if (opts.username) |username| try validateString(username);
    if (opts.will_qos == 3 or (opts.will_topic == null) != (opts.will_payload == null)) return error.MalformedPacket;
    if (opts.will_topic) |topic| try validateTopicName(topic);
    if (opts.protocol == .v31 and (opts.client_id.len == 0 or opts.client_id.len > 23)) return error.InvalidClientId;
    if (opts.protocol == .v31) for (opts.client_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return error.InvalidClientId;
    };
    if (!opts.clean_session and opts.client_id.len == 0) return error.InvalidClientId;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    // Variable header: protocol name + level + flags + keepalive.
    try appendStr(&body, alloc, if (opts.protocol == .v31) "MQIsdp" else "MQTT");
    try body.append(alloc, switch (opts.protocol) {
        .v31 => 3,
        .v311 => 4,
        .v5 => 5,
    });

    var flags: u8 = 0;
    if (opts.clean_session) flags |= 0x02;
    if (opts.will_topic != null and opts.will_payload != null) {
        flags |= 0x04;
        flags |= (@as(u8, opts.will_qos) << 3);
        if (opts.will_retain) flags |= 0x20;
    }
    if (opts.username != null) flags |= 0x80;
    if (opts.username != null and opts.password != null) flags |= 0x40;
    try body.append(alloc, flags);
    try appendU16(&body, alloc, opts.keepalive_s);
    if (opts.protocol == .v5) {
        try body.appendSlice(alloc, &.{ 8, 33 });
        try appendU16(&body, alloc, receive_maximum);
        try body.append(alloc, 39);
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, max_packet_length, .big);
        try body.appendSlice(alloc, &size);
    }

    // Payload: client id, [will topic, will payload], [username], [password].
    try appendStr(&body, alloc, opts.client_id);
    if (opts.will_topic) |topic| if (opts.will_payload) |payload| {
        if (opts.protocol == .v5) try body.append(alloc, 0); // Will properties.
        try appendStr(&body, alloc, topic);
        try appendStr(&body, alloc, payload);
    };
    if (opts.username) |u| try appendStr(&body, alloc, u);
    if (opts.username != null) if (opts.password) |p| try appendStr(&body, alloc, p);

    return frame(alloc, .connect, 0, body.items);
}

/// Encode a PUBLISH packet. `packet_id` is required (and used) only for qos > 0.
pub fn encodePublish(
    alloc: std.mem.Allocator,
    protocol: Protocol,
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
    packet_id: u16,
) ![]u8 {
    if (qos == 3 or (qos != 0 and packet_id == 0)) return error.MalformedPacket;
    try validateTopicName(topic);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try appendStr(&body, alloc, topic);
    if (qos > 0) try appendU16(&body, alloc, packet_id);
    if (protocol == .v5) try body.append(alloc, 0);
    try body.appendSlice(alloc, payload);

    var flags: u4 = 0;
    flags |= (@as(u4, qos) << 1);
    if (retain) flags |= 0x1;
    return frame(alloc, .publish, flags, body.items);
}

/// Encode a SUBSCRIBE packet for a single topic filter at the given qos.
pub fn encodeSubscribe(
    alloc: std.mem.Allocator,
    protocol: Protocol,
    packet_id: u16,
    topic_filter: []const u8,
    qos: u2,
) ![]u8 {
    if (qos == 3 or packet_id == 0) return error.MalformedPacket;
    try validateTopicFilter(topic_filter);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try appendU16(&body, alloc, packet_id);
    if (protocol == .v5) try body.append(alloc, 0);
    try appendStr(&body, alloc, topic_filter);
    try body.append(alloc, qos);

    // SUBSCRIBE fixed-header flags are reserved and MUST be 0b0010.
    return frame(alloc, .subscribe, 0b0010, body.items);
}

pub fn encodeUnsubscribe(alloc: std.mem.Allocator, protocol: Protocol, packet_id: u16, topic_filter: []const u8) ![]u8 {
    if (packet_id == 0) return error.MalformedPacket;
    try validateTopicFilter(topic_filter);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try appendU16(&body, alloc, packet_id);
    if (protocol == .v5) try body.append(alloc, 0);
    try appendStr(&body, alloc, topic_filter);
    return frame(alloc, .unsubscribe, 2, body.items);
}

/// A four-byte acknowledgement (PUBACK, PUBREC, PUBREL or PUBCOMP) for
/// `packet_id`. PUBREL carries the reserved flags 0b0010 (MQTT 3.6.1).
pub fn ack(ptype: PacketType, packet_id: u16) [4]u8 {
    const flags: u8 = if (ptype == .pubrel) 0b0010 else 0;
    var out: [4]u8 = .{ (@as(u8, @backingInt(ptype)) << 4) | flags, 2, 0, 0 };
    std.mem.writeInt(u16, out[2..4], packet_id, .big);
    return out;
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

    /// Split the fixed-header first byte into type and flags.
    pub fn init(b0: u8, body: []const u8) Packet {
        return .{ .ptype = @fromBackingInt(@as(u4, @intCast(b0 >> 4))), .flags = @truncate(b0), .body = body };
    }

    /// The packet identifier of a PUBACK/PUBREC/PUBREL/PUBCOMP/SUBACK.
    pub fn packetId(self: Packet) !u16 {
        if (self.body.len < 2) return error.Truncated;
        const id = std.mem.readInt(u16, self.body[0..2], .big);
        if (id == 0) return error.MalformedPacket;
        return id;
    }
};

/// Read one packet from `reader` (blocking). The body is stored in `body`,
/// which is grown with `gpa` and reused across calls; the returned packet
/// borrows it until the next read. Bodies over `max_len` are rejected before
/// any allocation.
pub fn readPacket(reader: *std.Io.Reader, gpa: std.mem.Allocator, body: *std.ArrayList(u8), max_len: u32) !Packet {
    const b0 = try reader.takeByte();
    const len = try readVarInt(reader);
    if (len > max_len) return error.PacketTooLarge;
    try body.resize(gpa, len);
    try reader.readSliceAll(body.items);
    return .init(b0, body.items);
}

pub const PublishView = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u2,
    retain: bool,
    packet_id: u16, // 0 when qos == 0
};

/// Interpret a decoded PUBLISH packet's body + flags. QoS 3 is reserved and
/// makes the packet malformed (MQTT 3.3.1.2).
pub fn parsePublish(protocol: Protocol, pkt: Packet) !PublishView {
    if (pkt.ptype != .publish) return error.NotPublish;
    const qos: u2 = @intCast((pkt.flags >> 1) & 0x3);
    if (qos == 3 or (qos == 0 and pkt.flags & 8 != 0)) return error.MalformedPacket;
    const retain = (pkt.flags & 0x1) != 0;
    const t = try readStr(pkt.body, 0);
    validateTopicName(t.s) catch return error.MalformedPacket;
    var off = t.next;
    var packet_id: u16 = 0;
    if (qos > 0) {
        if (pkt.body.len - off < 2) return error.Truncated;
        packet_id = std.mem.readInt(u16, pkt.body[off..][0..2], .big);
        if (packet_id == 0) return error.MalformedPacket;
        off += 2;
    }
    if (protocol == .v5) {
        const prop = try properties(pkt.body, off, .publish);
        off = prop.next;
        if (prop.payload_utf8 and !std.unicode.utf8ValidateSlice(pkt.body[off..])) return error.MalformedPacket;
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
pub fn parseConnack(protocol: Protocol, pkt: Packet) !ConnackCode {
    if (pkt.ptype != .connack) return error.NotConnack;
    if (pkt.body.len < 2) return error.Truncated;
    if (pkt.flags != 0 or pkt.body[0] & 0xfe != 0 or (pkt.body[1] != 0 and pkt.body[0] != 0)) return error.MalformedPacket;
    if (protocol == .v5) {
        if (!validReason(.connack, pkt.body[1])) return error.MalformedPacket;
        if ((try properties(pkt.body, 2, .connack)).next != pkt.body.len) return error.MalformedPacket;
    } else if (pkt.body.len != 2 or pkt.body[1] > 5 or (protocol == .v31 and pkt.body[0] != 0)) return error.MalformedPacket;
    return @fromBackingInt(pkt.body[1]);
}

pub const Properties = struct {
    next: usize,
    max_qos: u2 = 2,
    retain_available: bool = true,
    receive_max: u16 = std.math.maxInt(u16),
    max_packet: u32 = max_remaining_length,
    server_keepalive: ?u16 = null,
    payload_utf8: bool = false,
};

/// Validate properties before using offsets or negotiated server limits.
pub fn properties(bytes: []const u8, offset: usize, context: PacketType) !Properties {
    if (offset > bytes.len) return error.Truncated;
    var source: std.Io.Reader = .fixed(bytes[offset..]);
    const len = try readVarInt(&source);
    const start = offset + source.seek;
    if (len > bytes.len - start) return error.Truncated;
    var reader: std.Io.Reader = .fixed(bytes[start .. start + len]);
    var result: Properties = .{ .next = start + len };
    var seen: u64 = 0;
    while (reader.seek < reader.end) {
        const id = try readVarInt(&reader);
        if (id > 42) return error.MalformedPacket;
        const mask = @as(u64, 1) << @as(u6, @intCast(id));
        if (seen & mask != 0 and id != 38 and !(id == 11 and context == .publish)) return error.MalformedPacket;
        seen |= mask;
        const allowed = switch (id) {
            1, 2, 3, 8, 9, 11 => context == .publish,
            17 => context == .connack or context == .disconnect,
            18, 19, 21, 22, 26, 33, 34, 36, 37, 39, 40, 41, 42 => context == .connack,
            28 => context == .connack or context == .disconnect,
            31 => context != .publish,
            35 => context == .publish,
            38 => true,
            else => false,
        };
        if (!allowed) return error.MalformedPacket;
        switch (id) {
            1, 36, 37, 40, 41, 42 => {
                const value = try reader.takeByte();
                if (value > 1) return error.MalformedPacket;
                switch (id) {
                    1 => result.payload_utf8 = value == 1,
                    36 => result.max_qos = @intCast(value),
                    37 => result.retain_available = value == 1,
                    else => {},
                }
            },
            19, 33, 34, 35 => {
                const value = try reader.takeInt(u16, .big);
                if ((id == 33 and value == 0) or id == 35) return error.MalformedPacket; // No inbound topic aliases are advertised.
                switch (id) {
                    19 => result.server_keepalive = value,
                    33 => result.receive_max = value,
                    else => {},
                }
            },
            2, 17, 39 => {
                const value = try reader.takeInt(u32, .big);
                if (id == 39) {
                    if (value == 0) return error.MalformedPacket;
                    result.max_packet = value;
                }
            },
            11 => if (try readVarInt(&reader) == 0) return error.MalformedPacket,
            9, 22 => {
                const value = try readStr(reader.buffer, reader.seek);
                reader.seek = value.next;
            },
            3, 8, 18, 21, 26, 28, 31, 38 => {
                const value = try readStr(reader.buffer, reader.seek);
                validateString(value.s) catch return error.MalformedPacket;
                if (id == 8) validateTopicName(value.s) catch return error.MalformedPacket;
                reader.seek = value.next;
                if (id == 38) {
                    const second = try readStr(reader.buffer, reader.seek);
                    validateString(second.s) catch return error.MalformedPacket;
                    reader.seek = second.next;
                }
                // No enhanced authentication method is negotiated by CONNECT.
                if (id == 21) return error.UnsupportedAuthentication;
            },
            else => unreachable,
        }
    }
    if (seen & (@as(u64, 1) << 22) != 0 and seen & (@as(u64, 1) << 21) == 0) return error.MalformedPacket;
    return result;
}

fn validReason(kind: PacketType, reason: u8) bool {
    return switch (kind) {
        .connack => switch (reason) {
            0, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8c, 0x90, 0x95, 0x97, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9f => true,
            else => false,
        },
        .puback, .pubrec => switch (reason) {
            0, 0x10, 0x80, 0x83, 0x87, 0x90, 0x91, 0x97, 0x99 => true,
            else => false,
        },
        .pubrel, .pubcomp => reason == 0 or reason == 0x92,
        .suback => switch (reason) {
            0, 1, 2, 0x80, 0x83, 0x87, 0x8f, 0x91, 0x97, 0x9e, 0xa1, 0xa2 => true,
            else => false,
        },
        .unsuback => switch (reason) {
            0, 0x11, 0x80, 0x83, 0x87, 0x8f, 0x91 => true,
            else => false,
        },
        .disconnect => switch (reason) {
            0, 4, 0x80, 0x81, 0x82, 0x83, 0x87, 0x89, 0x8b, 0x8d, 0x8e, 0x8f, 0x90, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0, 0xa1, 0xa2 => true,
            else => false,
        },
        else => false,
    };
}

/// Validate the single-topic acknowledgement and return its reason code.
pub fn parseAck(protocol: Protocol, packet: Packet) !u8 {
    switch (packet.ptype) {
        .puback, .pubrec, .pubrel, .pubcomp, .suback, .unsuback => {},
        else => return error.MalformedPacket,
    }
    const expected_flags: u4 = if (packet.ptype == .pubrel) 2 else 0;
    if (packet.flags != expected_flags) return error.MalformedPacket;
    _ = try packet.packetId();
    const multi = packet.ptype == .suback or packet.ptype == .unsuback;
    if (protocol != .v5) {
        if (packet.body.len != (if (packet.ptype == .suback) @as(usize, 3) else 2)) return error.MalformedPacket;
        if (packet.ptype == .suback) {
            const code = packet.body[2];
            if (code != 0 and code != 1 and code != 2 and code != 0x80) return error.MalformedPacket;
            return code;
        }
        return 0;
    }
    if (multi) {
        const prop = try properties(packet.body, 2, packet.ptype);
        if (packet.body.len - prop.next != 1) return error.MalformedPacket;
        const reason = packet.body[prop.next];
        if (!validReason(packet.ptype, reason)) return error.MalformedPacket;
        return reason;
    }
    const reason = if (packet.body.len == 2) 0 else packet.body[2];
    if (!validReason(packet.ptype, reason)) return error.MalformedPacket;
    if (packet.body.len > 3 and (try properties(packet.body, 3, packet.ptype)).next != packet.body.len) return error.MalformedPacket;
    return reason;
}

pub fn validateDisconnect(protocol: Protocol, packet: Packet) !void {
    if (packet.flags != 0 or packet.ptype != .disconnect) return error.MalformedPacket;
    if (protocol != .v5) {
        if (packet.body.len != 0) return error.MalformedPacket;
        return;
    }
    if (packet.body.len == 0) return;
    if (!validReason(.disconnect, packet.body[0])) return error.MalformedPacket;
    if (packet.body.len > 1 and (try properties(packet.body, 1, .disconnect)).next != packet.body.len) return error.MalformedPacket;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "all protocols encode CONNECT, PUBLISH, SUBSCRIBE and UNSUBSCRIBE without fallback" {
    inline for (std.meta.tags(Protocol)) |protocol| {
        const connect = try encodeConnect(testing.allocator, .{ .protocol = protocol, .client_id = "testclient", .will_topic = "status", .will_payload = "offline" });
        defer testing.allocator.free(connect);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        const packet = try decodeAll(connect, &body);
        const name = try readStr(packet.body, 0);
        try testing.expectEqualStrings(if (protocol == .v31) "MQIsdp" else "MQTT", name.s);
        try testing.expectEqual(@as(u8, switch (protocol) {
            .v31 => 3,
            .v311 => 4,
            .v5 => 5,
        }), packet.body[name.next]);
        var cursor = name.next + 4;
        if (protocol == .v5) {
            try testing.expectEqualSlices(u8, &.{ 8, 33, 0, 32, 39, 0, 128, 0, 0 }, packet.body[cursor..][0..9]);
            cursor += 9;
        }
        const id = try readStr(packet.body, cursor);
        try testing.expectEqualStrings("testclient", id.s);
        cursor = id.next;
        if (protocol == .v5) {
            try testing.expectEqual(@as(u8, 0), packet.body[cursor]);
            cursor += 1;
        }
        try testing.expectEqualStrings("status", (try readStr(packet.body, cursor)).s);
        const publish = try encodePublish(testing.allocator, protocol, "a/b", "hello", 2, true, 7);
        defer testing.allocator.free(publish);
        const view = try parsePublish(protocol, try decodeAll(publish, &body));
        try testing.expectEqualStrings("hello", view.payload);
        try testing.expectEqual(@as(u16, 7), view.packet_id);
        const sub = try encodeSubscribe(testing.allocator, protocol, 8, "a/#", 1);
        defer testing.allocator.free(sub);
        const sp = try decodeAll(sub, &body);
        try testing.expectEqualStrings("a/#", (try readStr(sp.body, if (protocol == .v5) 3 else 2)).s);
        const unsub = try encodeUnsubscribe(testing.allocator, protocol, 9, "a/#");
        defer testing.allocator.free(unsub);
        const up = try decodeAll(unsub, &body);
        try testing.expectEqual(PacketType.unsubscribe, up.ptype);
        try testing.expectEqual(@as(u4, 2), up.flags);
        try testing.expectEqualStrings("a/#", (try readStr(up.body, if (protocol == .v5) 3 else 2)).s);
    }
    try testing.expectEqual(Protocol.v31, try Protocol.parse("v3.1"));
    try testing.expectEqual(Protocol.v311, try Protocol.parse("v3.1.1"));
    try testing.expectEqual(Protocol.v5, try Protocol.parse("v5"));
    try testing.expectError(error.InvalidProtocol, Protocol.parse("v4"));
    try testing.expectError(error.InvalidProtocol, Protocol.parse("v31"));
    try testing.expectError(error.InvalidClientId, encodeConnect(testing.allocator, .{ .protocol = .v31, .client_id = "" }));
    try testing.expectError(error.InvalidClientId, encodeConnect(testing.allocator, .{ .protocol = .v31, .client_id = "not-alphanumeric" }));
    try testing.expectError(error.InvalidClientId, encodeConnect(testing.allocator, .{ .protocol = .v31, .client_id = "abcdefghijklmnopqrstuvwx" }));
    try testing.expectError(error.MalformedPacket, encodePublish(testing.allocator, .v5, "t", "v", 1, false, 0));
    try testing.expectError(error.MalformedPacket, encodeSubscribe(testing.allocator, .v5, 1, "t", 3));
}

test "MQTT 5 validates property lengths, contexts, duplicate scalars and negotiated limits" {
    const bytes = [_]u8{ 0, 0, 18, 36, 1, 37, 0, 33, 0, 2, 39, 0, 0, 4, 0, 19, 0, 9, 34, 0, 0 };
    try testing.expectEqual(ConnackCode.accepted, try parseConnack(.v5, .init(0x20, &bytes)));
    const prop = try properties(&bytes, 2, .connack);
    try testing.expectEqual(@as(u2, 1), prop.max_qos);
    try testing.expect(!prop.retain_available);
    try testing.expectEqual(@as(u16, 2), prop.receive_max);
    try testing.expectEqual(@as(u32, 1024), prop.max_packet);
    try testing.expectEqual(@as(?u16, 9), prop.server_keepalive);
    try testing.expectError(error.Truncated, parseConnack(.v5, .init(0x20, &.{ 0, 0, 2, 36 })));
    try testing.expectError(error.MalformedPacket, parseConnack(.v5, .init(0x20, &.{ 0, 0, 4, 36, 1, 36, 0 })));
    try testing.expectError(error.MalformedPacket, parseConnack(.v5, .init(0x20, &.{ 0, 0, 2, 36, 2 })));
    try testing.expectError(error.MalformedPacket, parseConnack(.v5, .init(0x20, &.{ 0, 0, 3, 33, 0, 0 })));
    try testing.expectError(error.MalformedPacket, parseConnack(.v5, .init(0x20, &.{ 0, 1, 0 })));
    try testing.expectError(error.MalformedPacket, parsePublish(.v5, .init(0x30, &.{ 0, 1, 't', 2, 36, 0 })));
    try testing.expectError(error.MalformedPacket, parsePublish(.v5, .init(0x30, &.{ 0, 1, 't', 2, 1, 1, 0xff })));
    try testing.expectError(error.MalformedPacket, parsePublish(.v5, .init(0x30, &.{ 0, 1, 't', 3, 35, 0, 1 })));
    // Repeated user properties and subscription identifiers are allowed.
    const publish = try parsePublish(.v5, .init(0x30, &.{ 0, 1, 't', 14, 11, 1, 11, 2, 38, 0, 0, 0, 0, 38, 0, 0, 0, 0, 'v' }));
    try testing.expectEqualStrings("v", publish.payload);
    try testing.expectError(error.MalformedVarInt, properties(&.{ 0x80, 0 }, 0, .publish));
}

test "acknowledgements validate reason codes and exact packet lengths in every protocol" {
    inline for (std.meta.tags(Protocol)) |protocol| {
        for ([_]PacketType{ .puback, .pubrec, .pubrel, .pubcomp }) |kind| {
            const encoded = ack(kind, 7);
            try testing.expectEqual(@as(u8, 0), try parseAck(protocol, .init(encoded[0], encoded[2..])));
        }
        try testing.expectError(error.MalformedPacket, parseAck(protocol, .init(0x40, &.{ 0, 0 })));
        try testing.expectError(error.MalformedPacket, parseAck(protocol, .init(0x41, &.{ 0, 1 })));
    }
    try testing.expectEqual(@as(u8, 0x87), try parseAck(.v5, .init(0x40, &.{ 0, 1, 0x87, 0 })));
    try testing.expectEqual(@as(u8, 0x92), try parseAck(.v5, .init(0x70, &.{ 0, 1, 0x92 })));
    try testing.expectEqual(@as(u8, 0x80), try parseAck(.v311, .init(0x90, &.{ 0, 1, 0x80 })));
    try testing.expectEqual(@as(u8, 0x87), try parseAck(.v5, .init(0x90, &.{ 0, 1, 0, 0x87 })));
    try testing.expectEqual(@as(u8, 0x11), try parseAck(.v5, .init(0xb0, &.{ 0, 1, 0, 0x11 })));
    try testing.expectError(error.MalformedPacket, parseAck(.v5, .init(0x40, &.{ 0, 1, 0x01 })));
    try testing.expectError(error.MalformedPacket, parseAck(.v311, .init(0x40, &.{ 0, 1, 0 })));
    try testing.expectError(error.MalformedPacket, parseAck(.v5, .init(0x90, &.{ 0, 1, 0, 0, 1 })));
    try validateDisconnect(.v5, .init(0xe0, &.{ 0x89, 0 }));
    try testing.expectError(error.MalformedPacket, validateDisconnect(.v5, .init(0xe0, &.{0x01})));
}

test "fuzz protocol parsers validate bounded arbitrary properties and acknowledgement reasons" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [96]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const packet: Packet = .init(bytes[0], bytes[1..]);
            inline for (std.meta.tags(Protocol)) |protocol| {
                _ = parseConnack(protocol, packet) catch {};
                _ = parseAck(protocol, packet) catch {};
                validateDisconnect(protocol, packet) catch {};
                if (parsePublish(protocol, packet)) |view| try testing.expect(view.payload.len <= packet.body.len) else |_| {}
            }
            if (properties(&bytes, 0, packet.ptype)) |prop| try testing.expect(prop.next <= bytes.len) else |_| {}
            _ = Protocol.parse(&bytes) catch {};
        }
    }.run, .{});
}

test "fuzz protocol encoders retain payload and filter bytes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [24]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const name = std.fmt.bytesToHex(&bytes, .lower);
            inline for (std.meta.tags(Protocol)) |protocol| {
                const publish = try encodePublish(testing.allocator, protocol, &name, &bytes, @intCast(bytes[0] % 3), false, 1);
                defer testing.allocator.free(publish);
                var body: std.ArrayList(u8) = .empty;
                defer body.deinit(testing.allocator);
                try testing.expectEqualSlices(u8, &bytes, (try parsePublish(protocol, try decodeAll(publish, &body))).payload);
                const unsub = try encodeUnsubscribe(testing.allocator, protocol, 7, &name);
                defer testing.allocator.free(unsub);
                try testing.expectEqual(@as(u16, 7), try (try decodeAll(unsub, &body)).packetId());
            }
        }
    }.run, .{});
}

/// Decode a complete packet held in `bytes` (test inputs only).
fn decodeAll(bytes: []const u8, body: *std.ArrayList(u8)) !Packet {
    var reader: std.Io.Reader = .fixed(bytes);
    return readPacket(&reader, testing.allocator, body, max_remaining_length);
}

test "encodeVarInt/readVarInt: boundary values round-trip" {
    const cases = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, max_remaining_length };
    for (cases) |v| {
        var buf: [4]u8 = undefined;
        const enc = try encodeVarInt(v, &buf);
        var reader: std.Io.Reader = .fixed(enc);
        try testing.expectEqual(v, try readVarInt(&reader));
        try testing.expectEqual(enc.len, reader.seek);
    }
}

test "encodeVarInt: rejects oversized value" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.ValueTooLarge, encodeVarInt(max_remaining_length + 1, &buf));
}

test "encodeConnect: minimal clean session" {
    const pkt = try encodeConnect(testing.allocator, .{ .client_id = "phobos" });
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const dec = try decodeAll(pkt, &body);
    try testing.expectEqual(PacketType.connect, dec.ptype);
    // Protocol name "MQTT", level 4, flags 0x02 (clean), keepalive 60.
    try testing.expectEqualSlices(u8, &.{ 0, 4, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0, 60 }, dec.body[0..10]);
    const cid = try readStr(dec.body, 10);
    try testing.expectEqualStrings("phobos", cid.s);
}

test "encodeConnect: with will + credentials sets flags and payload order" {
    const pkt = try encodeConnect(testing.allocator, .{
        .client_id = "",
        .username = "u",
        .password = "p",
        .will_topic = "w/t",
        .will_payload = "off",
        .will_qos = 1,
        .will_retain = true,
    });
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const dec = try decodeAll(pkt, &body);
    // Flags byte at body offset 7: clean(0x02)|will(0x04)|willqos1(0x08)|willretain(0x20)|user(0x80)|pass(0x40)
    try testing.expectEqual(@as(u8, 0x02 | 0x04 | 0x08 | 0x20 | 0x80 | 0x40), dec.body[7]);
    const cid = try readStr(dec.body, 10);
    try testing.expectEqualStrings("", cid.s);
    const topic = try readStr(dec.body, cid.next);
    try testing.expectEqualStrings("w/t", topic.s);
    const payload = try readStr(dec.body, topic.next);
    try testing.expectEqualStrings("off", payload.s);
}

test "encodeConnect ignores a password without a username" {
    const pkt = try encodeConnect(testing.allocator, .{ .client_id = "id", .password = "secret" });
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const dec = try decodeAll(pkt, &body);
    try testing.expectEqual(@as(u8, 0x02), dec.body[7]);
    const cid = try readStr(dec.body, 10);
    try testing.expectEqualStrings("id", cid.s);
    try testing.expectEqual(cid.next, dec.body.len);
}

test "topic encoders reject invalid UTF-8 names and filters before writing" {
    const invalid = [_][]const u8{ "", "\x00", "a\x00b", "\xff", "\xed\xa0\x80" };
    for (invalid) |topic| {
        try testing.expectError(error.InvalidTopic, encodePublish(testing.allocator, .v311, topic, "p", 0, false, 0));
        try testing.expectError(error.InvalidTopic, encodeSubscribe(testing.allocator, .v311, 1, topic, 0));
    }
    for ([_][]const u8{ "a/#", "a/+/b", "#", "+" }) |topic| {
        try testing.expectError(error.InvalidTopic, encodePublish(testing.allocator, .v311, topic, "p", 0, false, 0));
        const pkt = try encodeSubscribe(testing.allocator, .v311, 1, topic, 0);
        testing.allocator.free(pkt);
    }
    for ([_][]const u8{ "a#", "a/#/b", "a+", "a/+b" }) |topic|
        try testing.expectError(error.InvalidTopic, encodeSubscribe(testing.allocator, .v311, 1, topic, 0));

    const long = try testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    const pkt = try encodePublish(testing.allocator, .v311, long[0 .. long.len - 1], "p", 0, false, 0);
    defer testing.allocator.free(pkt);
    try testing.expectError(error.InvalidTopic, encodePublish(testing.allocator, .v311, long, "p", 0, false, 0));
    try testing.expectError(error.InvalidTopic, encodeSubscribe(testing.allocator, .v311, 1, long, 0));
}

test "encodePublish/parsePublish: qos0 round-trips" {
    const pkt = try encodePublish(testing.allocator, .v311, "a/b", "hello", 0, false, 0);
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const view = try parsePublish(.v311, try decodeAll(pkt, &body));
    try testing.expectEqualStrings("a/b", view.topic);
    try testing.expectEqualStrings("hello", view.payload);
    try testing.expectEqual(@as(u2, 0), view.qos);
    try testing.expectEqual(@as(u16, 0), view.packet_id);
}

test "encodePublish/parsePublish: qos1 carries packet id + retain" {
    const pkt = try encodePublish(testing.allocator, .v311, "t", "p", 1, true, 0x1234);
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const view = try parsePublish(.v311, try decodeAll(pkt, &body));
    try testing.expectEqual(@as(u2, 1), view.qos);
    try testing.expect(view.retain);
    try testing.expectEqual(@as(u16, 0x1234), view.packet_id);
    try testing.expectEqualStrings("p", view.payload);
}

test "parsePublish rejects reserved QoS 3 and truncated bodies" {
    try testing.expectError(error.MalformedPacket, parsePublish(.v311, .init(0x36, &.{ 0, 1, 't', 0, 7 })));
    try testing.expectError(error.Truncated, parsePublish(.v311, .init(0x32, &.{ 0, 1, 't', 0 })));
    try testing.expectError(error.Truncated, parsePublish(.v311, .init(0x30, &.{0})));
    try testing.expectError(error.NotPublish, parsePublish(.v311, .init(0x40, &.{ 0, 1 })));
}

test "encodeSubscribe: flags are 0b0010 and body holds id+filter+qos" {
    const pkt = try encodeSubscribe(testing.allocator, .v311, 7, "x/#", 1);
    defer testing.allocator.free(pkt);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    const dec = try decodeAll(pkt, &body);
    try testing.expectEqual(PacketType.subscribe, dec.ptype);
    try testing.expectEqual(@as(u4, 0b0010), dec.flags);
    try testing.expectEqual(@as(u16, 7), try dec.packetId());
    const f = try readStr(dec.body, 2);
    try testing.expectEqualStrings("x/#", f.s);
    try testing.expectEqual(@as(u8, 1), dec.body[f.next]);
}

test "ack, pingreq and disconnect wire bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x02, 0x01, 0x02 }, &ack(.puback, 0x0102));
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x02, 0x00, 0x09 }, &ack(.pubrec, 9));
    try testing.expectEqualSlices(u8, &.{ 0x62, 0x02, 0x00, 0x09 }, &ack(.pubrel, 9));
    try testing.expectEqualSlices(u8, &.{ 0x70, 0x02, 0x00, 0x09 }, &ack(.pubcomp, 9));
    try testing.expectEqualSlices(u8, &.{ 0xC0, 0x00 }, &pingreq);
    try testing.expectEqualSlices(u8, &.{ 0xE0, 0x00 }, &disconnect);
}

test "parseConnack: accepted and rejected codes" {
    try testing.expectEqual(ConnackCode.accepted, try parseConnack(.v311, .init(0x20, &.{ 0, 0 })));
    try testing.expectEqual(ConnackCode.not_authorized, try parseConnack(.v311, .init(0x20, &.{ 0, 5 })));
    try testing.expectError(error.Truncated, parseConnack(.v311, .init(0x20, &.{0})));
}

test "readPacket: truncated, oversized and pipelined input" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    var short: std.Io.Reader = .fixed(&.{ 0x30, 0x0A, 0x00, 0x01 });
    try testing.expectError(error.EndOfStream, readPacket(&short, testing.allocator, &body, 64));
    var big: std.Io.Reader = .fixed(&.{ 0x30, 0x41 });
    try testing.expectError(error.PacketTooLarge, readPacket(&big, testing.allocator, &body, 64));
    var malformed: std.Io.Reader = .fixed(&.{ 0x30, 0x80, 0x80, 0x80, 0x80, 0 });
    try testing.expectError(error.MalformedVarInt, readPacket(&malformed, testing.allocator, &body, 64));
    var empty: std.Io.Reader = .fixed(&.{});
    try testing.expectError(error.EndOfStream, readPacket(&empty, testing.allocator, &body, 64));

    const both = pingreq ++ ack(.puback, 9);
    var reader: std.Io.Reader = .fixed(&both);
    try testing.expectEqual(PacketType.pingreq, (try readPacket(&reader, testing.allocator, &body, 64)).ptype);
    const second = try readPacket(&reader, testing.allocator, &body, 64);
    try testing.expectEqual(PacketType.puback, second.ptype);
    try testing.expectEqual(@as(u16, 9), try second.packetId());
}

test "readVarInt stops before packet data and enforces MQTT's four-byte bound" {
    var source: std.Io.Reader = .fixed(&.{ 0x80, 0x01, 'n', 'e', 'x', 't' });
    try testing.expectEqual(@as(u32, 128), try readVarInt(&source));
    try testing.expectEqualStrings("next", source.buffered());
    var padded: std.Io.Reader = .fixed(&.{ 0x80, 0x80, 0x80, 0x80, 0, 'x' });
    try testing.expectError(error.MalformedVarInt, readVarInt(&padded));
    try testing.expectEqual(@as(usize, 4), padded.seek);
    var short: std.Io.Reader = .fixed(&.{ 0x80, 0x80 });
    try testing.expectError(error.EndOfStream, readVarInt(&short));
    var empty: [0]u8 = .{};
    try testing.expectError(error.NoSpaceLeft, encodeVarInt(0, &empty));
}

// --- Fuzz tests ---

test "fuzz readPacket: arbitrary bytes never crash the decoders" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            var reader: std.Io.Reader = .fixed(buf[1 .. 1 + @min(n, buf.len - 1)]);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(testing.allocator);
            const pkt = readPacket(&reader, testing.allocator, &body, 64) catch return;
            if (pkt.ptype == .publish) {
                const view = parsePublish(.v311, pkt) catch return;
                try testing.expect(view.qos != 3);
            }
            if (pkt.ptype == .connack) _ = parseConnack(.v311, pkt) catch {};
            _ = pkt.packetId() catch {};
        }
    }.run, .{});
}

test "fuzz readVarInt consumes at most four bytes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [8]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var reader: std.Io.Reader = .fixed(&bytes);
            const result = readVarInt(&reader) catch {
                try testing.expect(reader.seek <= 4);
                return;
            };
            try testing.expect(result <= max_remaining_length);
            try testing.expect(reader.seek <= 4);
        }
    }.run, .{});
}

test "fuzz encodeConnect: arbitrary ids/creds round-trip the client id" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const split = @max(1, @as(usize, buf[0]) % buf.len);
            const pkt = encodeConnect(testing.allocator, .{ .client_id = buf[1..split], .username = buf[split..] }) catch return;
            defer testing.allocator.free(pkt);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(testing.allocator);
            const dec = try decodeAll(pkt, &body);
            try testing.expectEqualSlices(u8, buf[1..split], (try readStr(dec.body, 10)).s);
        }
    }.run, .{});
}

test "fuzz encodePublish/ack: round-trip topic, payload and packet id" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const split = @max(1, @as(usize, buf[0]) % buf.len);
            const qos: u2 = @intCast(buf[0] % 3);
            const id = @max(1, std.mem.readInt(u16, buf[1..3], .big));
            const hex = std.fmt.bytesToHex(&buf, .lower);
            const topic = hex[0 .. split * 2];
            const pkt = try encodePublish(testing.allocator, .v311, topic, buf[split..], qos, buf[0] & 1 == 1, id);
            defer testing.allocator.free(pkt);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(testing.allocator);
            const view = try parsePublish(.v311, try decodeAll(pkt, &body));
            try testing.expectEqualSlices(u8, topic, view.topic);
            try testing.expectEqualSlices(u8, buf[split..], view.payload);
            try testing.expectEqual(if (qos > 0) id else 0, view.packet_id);
            const reply = ack(.pubrec, id);
            try testing.expectEqual(id, try Packet.init(reply[0], reply[2..]).packetId());
        }
    }.run, .{});
}

test "fuzz encodeSubscribe: filter round-trips" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [40]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const topic = std.fmt.bytesToHex(&buf, .lower);
            const pkt = try encodeSubscribe(testing.allocator, .v311, 1, &topic, @intCast(buf[0] % 3));
            defer testing.allocator.free(pkt);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(testing.allocator);
            const dec = try decodeAll(pkt, &body);
            try testing.expectEqualSlices(u8, &topic, (try readStr(dec.body, 2)).s);
        }
    }.run, .{});
}

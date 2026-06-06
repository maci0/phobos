//! MQTT 3.1.1 TCP client over `std.Io.net`.
//!
//! A thin, synchronous client: connect → CONNACK, publish, subscribe, ping,
//! and a `readOne` step that decodes a single inbound packet and dispatches
//! PUBLISH frames to a callback (auto-replying to PINGREQ and PUBLISH-QoS1).
//! The owning component (`mqtt.zig`) drives `readOne` from a background task and
//! issues periodic `ping`s for keepalive. No raw socket syscalls — everything is
//! `std.Io.net`. Packet wire format lives in `mqtt_proto.zig`.

const std = @import("std");
const proto = @import("mqtt_proto.zig");
const net = std.Io.net;
const Io = std.Io;

/// Callback invoked for each inbound application PUBLISH. `topic`/`payload`
/// borrow client-owned memory valid only for the duration of the call — copy if
/// they must outlive it.
pub const PublishHandler = *const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8) void;

/// Upper bound on an inbound MQTT packet body (8 MiB). Larger frames are
/// rejected to cap attacker-controlled allocation.
pub const max_packet_len: u32 = 8 * 1024 * 1024;

pub const MqttClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    /// Persistent receive buffer + reader. Heap-owned so the reader's internal
    /// buffer pointer stays valid for the client's lifetime.
    reader_buf: []u8,
    rdr: net.Stream.Reader,
    next_id: u16 = 1,
    connected: bool = false,
    on_publish: ?PublishHandler = null,
    on_publish_ctx: ?*anyopaque = null,
    /// Serializes writes so a background reader's auto-replies cannot interleave
    /// with a foreground publish.
    write_mtx: Io.Mutex = .init,

    pub const ConnectError = error{
        ConnectionRefused,
        ConnackTimeout,
        ConnectionRejected,
    } || std.mem.Allocator.Error;

    /// Connect to `host:port`, send CONNECT, await an accepted CONNACK.
    /// `host` must be a dotted IPv4 literal or "localhost".
    pub fn connect(
        gpa: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        opts: proto.ConnectOptions,
    ) !MqttClient {
        const ip = if (std.mem.eql(u8, host, "localhost"))
            try net.IpAddress.parseIp4("127.0.0.1", port)
        else
            try net.IpAddress.parseIp4(host, port);
        const stream = try ip.connect(io, .{ .mode = .stream });

        const reader_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(reader_buf);

        var self: MqttClient = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader_buf = reader_buf,
            .rdr = stream.reader(io, reader_buf),
        };

        // Send CONNECT.
        const connect_pkt = try proto.encodeConnect(gpa, opts);
        defer gpa.free(connect_pkt);
        try self.writeAll(connect_pkt);

        // Await CONNACK.
        const owned = try self.readRawPacket();
        defer gpa.free(owned.body);
        const pkt = proto.Packet{ .ptype = owned.ptype(), .flags = owned.flags(), .body = owned.body, .total = 0 };
        if (pkt.ptype != .connack) return error.ConnectionRejected;
        const code = try proto.parseConnack(pkt);
        if (code != .accepted) return error.ConnectionRejected;
        self.connected = true;
        return self;
    }

    pub fn deinit(self: *MqttClient) void {
        self.disconnect();
        self.gpa.free(self.reader_buf);
        self.* = undefined;
    }

    /// Reattach the persistent reader after the struct has been copied to its
    /// final (stable) address. Must be called once when the caller stores the
    /// returned client by value, before any read. (The reader's buffer pointer
    /// is address-independent — it points at the heap `reader_buf` — but the
    /// `net.Stream.Reader` also keeps a back-reference; re-deriving is cheapest.)
    pub fn rebind(self: *MqttClient) void {
        self.rdr = self.stream.reader(self.io, self.reader_buf);
    }

    fn writeAll(self: *MqttClient, bytes: []const u8) !void {
        var wbuf: [256]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Encode + send a PUBLISH. QoS 1 allocates a packet id; the matching PUBACK
    /// is consumed by the read loop (fire-and-forget at this layer).
    pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        if (!self.connected) return error.NotConnected;
        const id = if (qos > 0) self.nextId() else 0;
        const pkt = try proto.encodePublish(self.gpa, topic, payload, qos, retain, id);
        defer self.gpa.free(pkt);
        try self.write_mtx.lock(self.io);
        defer self.write_mtx.unlock(self.io);
        try self.writeAll(pkt);
    }

    pub fn subscribe(self: *MqttClient, topic_filter: []const u8, qos: u2) !void {
        if (!self.connected) return error.NotConnected;
        const pkt = try proto.encodeSubscribe(self.gpa, self.nextId(), topic_filter, qos);
        defer self.gpa.free(pkt);
        try self.write_mtx.lock(self.io);
        defer self.write_mtx.unlock(self.io);
        try self.writeAll(pkt);
    }

    pub fn ping(self: *MqttClient) !void {
        if (!self.connected) return error.NotConnected;
        const pkt = try proto.encodePingreq(self.gpa);
        defer self.gpa.free(pkt);
        try self.write_mtx.lock(self.io);
        defer self.write_mtx.unlock(self.io);
        try self.writeAll(pkt);
    }

    /// Shut down the receive side to interrupt a background reader blocked in
    /// `readOne` (POSIX close alone does not reliably wake a concurrent recv).
    /// Call this before joining the reader thread.
    pub fn shutdownRecv(self: *MqttClient) void {
        self.stream.shutdown(self.io, .recv) catch {};
    }

    pub fn disconnect(self: *MqttClient) void {
        if (!self.connected) return;
        const pkt = proto.encodeDisconnect(self.gpa) catch {
            self.connected = false;
            self.stream.close(self.io);
            return;
        };
        defer self.gpa.free(pkt);
        self.writeAll(pkt) catch {};
        self.connected = false;
        self.stream.close(self.io);
    }

    fn nextId(self: *MqttClient) u16 {
        const id = self.next_id;
        self.next_id = if (self.next_id == std.math.maxInt(u16)) 1 else self.next_id + 1;
        return id;
    }

    const RawPacket = struct {
        b0: u8,
        body: []u8, // gpa-owned
        fn ptype(self: RawPacket) proto.PacketType {
            return @enumFromInt(@as(u4, @intCast(self.b0 >> 4)));
        }
        fn flags(self: RawPacket) u4 {
            return @intCast(self.b0 & 0x0F);
        }
    };

    /// Read exactly one packet off the wire (blocking). Returns gpa-owned body.
    fn readRawPacket(self: *MqttClient) !RawPacket {
        const r = &self.rdr.interface;
        const b0 = try r.takeByte();
        // Remaining-length varint.
        var mult: u32 = 1;
        var rl: u32 = 0;
        var count: u8 = 0;
        while (true) {
            const c = try r.takeByte();
            rl += @as(u32, c & 0x7F) * mult;
            count += 1;
            if (c & 0x80 == 0) break;
            mult *= 128;
            if (count >= 4) return error.MalformedVarInt;
        }
        // Bound the allocation: a malformed/hostile broker frame can encode up to
        // ~256 MB in the remaining-length field. Reject oversized packets rather
        // than allocate attacker-controlled memory.
        if (rl > max_packet_len) return error.PacketTooLarge;
        const body = try self.gpa.alloc(u8, rl);
        errdefer self.gpa.free(body);
        if (rl > 0) try r.readSliceAll(body);
        return .{ .b0 = b0, .body = body };
    }

    /// Read and dispatch one inbound packet. PUBLISH → on_publish (+ PUBACK for
    /// QoS 1). PINGREQ → PINGRESP. Other control packets (CONNACK already
    /// consumed, SUBACK, PUBACK, PINGRESP) are accepted and ignored. Returns the
    /// packet type handled.
    pub fn readOne(self: *MqttClient) !proto.PacketType {
        const raw = try self.readRawPacket();
        defer self.gpa.free(raw.body);
        const pkt = proto.Packet{ .ptype = raw.ptype(), .flags = raw.flags(), .body = raw.body, .total = 0 };
        switch (pkt.ptype) {
            .publish => {
                const view = try proto.parsePublish(pkt);
                if (self.on_publish) |cb| cb(self.on_publish_ctx.?, view.topic, view.payload);
                if (view.qos == 1) {
                    const ack = try proto.encodePuback(self.gpa, view.packet_id);
                    defer self.gpa.free(ack);
                    try self.write_mtx.lock(self.io);
                    defer self.write_mtx.unlock(self.io);
                    try self.writeAll(ack);
                }
            },
            .pingreq => {
                const resp = try proto.encodePingreq(self.gpa); // PINGRESP shares empty body
                // PINGRESP is type 13; build it explicitly.
                self.gpa.free(resp);
                var rr: [2]u8 = .{ 0xD0, 0x00 };
                try self.write_mtx.lock(self.io);
                defer self.write_mtx.unlock(self.io);
                try self.writeAll(&rr);
            },
            else => {},
        }
        return pkt.ptype;
    }
};

// ===========================================================================
// Tests — exercised against an in-file minimal broker double.
// ===========================================================================

const testing = std.testing;

/// Minimal MQTT broker for tests: accepts one connection, completes the
/// CONNECT/CONNACK handshake, then services SUBSCRIBE (SUBACK) and records the
/// first PUBLISH it receives. Can inject a PUBLISH to the client.
pub const TestBroker = struct {
    alloc: std.mem.Allocator,
    io: Io,
    server: net.Server,
    stream: ?net.Stream = null,
    rbuf: [4096]u8 = undefined,
    got_topic: [256]u8 = undefined,
    got_topic_len: usize = 0,
    got_payload: [256]u8 = undefined,
    got_payload_len: usize = 0,
    saw_subscribe: bool = false,

    pub fn bind(alloc: std.mem.Allocator, io: Io) !TestBroker {
        var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try ip.listen(io, .{ .reuse_address = true });
        return .{ .alloc = alloc, .io = io, .server = server };
    }

    pub fn port(self: *TestBroker) !u16 {
        var sa: std.os.linux.sockaddr.in = undefined;
        var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
        const rc = std.os.linux.getsockname(self.server.socket.handle, @ptrCast(&sa), &slen);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.GetSockNameFailed;
        return std.mem.bigToNative(u16, sa.port);
    }

    pub fn readRaw(alloc: std.mem.Allocator, r: *std.Io.Reader) !struct { b0: u8, body: []u8 } {
        const b0 = try r.takeByte();
        var mult: u32 = 1;
        var rl: u32 = 0;
        while (true) {
            const c = try r.takeByte();
            rl += @as(u32, c & 0x7F) * mult;
            if (c & 0x80 == 0) break;
            mult *= 128;
        }
        const body = try alloc.alloc(u8, rl);
        if (rl > 0) try r.readSliceAll(body);
        return .{ .b0 = b0, .body = body };
    }

    fn writeAll(self: *TestBroker, stream: net.Stream, bytes: []const u8) !void {
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// Accept + handshake + service `nframes` client packets.
    pub fn run(self: *TestBroker, nframes: usize) void {
        const stream = self.server.accept(self.io) catch return;
        self.stream = stream;
        var r = stream.reader(self.io, &self.rbuf);

        // CONNECT → CONNACK accepted.
        const c = readRaw(self.alloc, &r.interface) catch return;
        self.alloc.free(c.body);
        self.writeAll(stream, &.{ 0x20, 0x02, 0x00, 0x00 }) catch return;

        var handled: usize = 0;
        while (handled < nframes) : (handled += 1) {
            const raw = readRaw(self.alloc, &r.interface) catch return;
            defer self.alloc.free(raw.body);
            const ptype: proto.PacketType = @enumFromInt(@as(u4, @intCast(raw.b0 >> 4)));
            switch (ptype) {
                .subscribe => {
                    self.saw_subscribe = true;
                    const pid = (@as(u16, raw.body[0]) << 8) | raw.body[1];
                    // SUBACK: packet id + granted qos 0.
                    self.writeAll(stream, &.{ 0x90, 0x03, @intCast(pid >> 8), @intCast(pid & 0xFF), 0x00 }) catch return;
                },
                .publish => {
                    const pkt = proto.Packet{ .ptype = .publish, .flags = @intCast(raw.b0 & 0x0F), .body = raw.body, .total = 0 };
                    const v = proto.parsePublish(pkt) catch continue;
                    @memcpy(self.got_topic[0..v.topic.len], v.topic);
                    self.got_topic_len = v.topic.len;
                    @memcpy(self.got_payload[0..v.payload.len], v.payload);
                    self.got_payload_len = v.payload.len;
                },
                else => {},
            }
        }
    }

    pub fn injectPublish(self: *TestBroker, topic: []const u8, payload: []const u8) !void {
        const pkt = try proto.encodePublish(self.alloc, topic, payload, 0, false, 0);
        defer self.alloc.free(pkt);
        try self.writeAll(self.stream.?, pkt);
    }

    pub fn deinit(self: *TestBroker) void {
        if (self.stream) |s| s.close(self.io);
        self.server.deinit(self.io);
    }
};

const Captured = struct {
    topic: [256]u8 = undefined,
    topic_len: usize = 0,
    payload: [256]u8 = undefined,
    payload_len: usize = 0,
    fn cb(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        @memcpy(self.topic[0..topic.len], topic);
        self.topic_len = topic.len;
        @memcpy(self.payload[0..payload.len], payload);
        self.payload_len = payload.len;
    }
};

test "client connects, CONNACK accepted, publishes to broker" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try TestBroker.bind(testing.allocator, io);
    defer broker.deinit();
    const p = try broker.port();

    // Broker services 1 frame (the publish) after the handshake.
    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });

    var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", p, .{ .client_id = "phobos-test" });
    client.rebind();
    defer client.deinit();
    try testing.expect(client.connected);

    try client.publish("phobos/instance/test", "hello-broker", 0, false);
    bf.await(io);

    try testing.expectEqualStrings("phobos/instance/test", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("hello-broker", broker.got_payload[0..broker.got_payload_len]);
}

test "client subscribes and receives an injected publish" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try TestBroker.bind(testing.allocator, io);
    defer broker.deinit();
    const p = try broker.port();

    // Broker services 1 frame (the subscribe), then injects a publish.
    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });

    var client = try MqttClient.connect(testing.allocator, io, "localhost", p, .{ .client_id = "c" });
    client.rebind();
    defer client.deinit();

    var cap: Captured = .{};
    client.on_publish = Captured.cb;
    client.on_publish_ctx = &cap;

    try client.subscribe("phobos/#", 0);
    bf.await(io); // broker has processed the subscribe

    try broker.injectPublish("phobos/status", "{\"x\":1}");
    // Drain control packets (SUBACK) until the application PUBLISH arrives.
    var spins: usize = 0;
    while (cap.payload_len == 0 and spins < 5) : (spins += 1) {
        _ = try client.readOne();
    }
    try testing.expectEqualStrings("phobos/status", cap.topic[0..cap.topic_len]);
    try testing.expectEqualStrings("{\"x\":1}", cap.payload[0..cap.payload_len]);
    try testing.expect(broker.saw_subscribe);
}

test "fuzz client publish: arbitrary topics/payloads never crash the encoder path" {
    // No socket: exercises the encode path the client uses, under fuzzed input.
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const split = @as(usize, buf[0]) % buf.len;
            const topic = buf[1..@max(1, split)];
            const payload = buf[@max(1, split)..];
            const qos: u2 = @intCast(buf[0] % 3);
            const pkt = proto.encodePublish(testing.allocator, topic, payload, qos, buf[0] & 1 == 1, 1) catch return;
            defer testing.allocator.free(pkt);
            const dec = proto.decode(pkt) catch return;
            if (dec) |d| _ = proto.parsePublish(d) catch {};
        }
    }.run, .{});
}

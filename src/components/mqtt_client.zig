//! MQTT 3.1.1 TCP client over `std.Io.net`.
//!
//! A thin, synchronous client: connect → CONNACK, publish, subscribe, ping,
//! and a `readOne` step that decodes a single inbound packet, dispatches
//! PUBLISH frames to a callback and answers the QoS 1 and QoS 2 handshakes.
//! The owning component (`mqtt.zig`) drives `readOne` from a background task and
//! sends `ping` every half keepalive interval. Writes are serialized on
//! `write_mtx`, so a reader-thread acknowledgement never interleaves with a
//! foreground publish. Packet wire format lives in `mqtt_proto.zig`.

const std = @import("std");
const proto = @import("mqtt_proto.zig");
const net = std.Io.net;
const Io = std.Io;

const tls_transport = @import("../util/tls.zig");
pub const TlsOpts = tls_transport.Options;
const TlsState = tls_transport.State;

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
    /// Reusable inbound packet-body buffer — grown to the largest packet seen and
    /// reused, so steady inbound traffic does not alloc/free per packet. The body
    /// returned by readPacket borrows this; valid only until the next read.
    body_scratch: std.ArrayList(u8) = .empty,
    /// Packet-id source. Atomic so a foreground publish/subscribe and any
    /// concurrent caller never race the increment. Never yields 0 (invalid id).
    next_id: std.atomic.Value(u16) = std.atomic.Value(u16).init(1),
    /// When set, all I/O is routed through this TLS layer instead of the raw
    /// stream. Heap-owned (must not move); freed in deinit.
    tls: ?*TlsState = null,
    on_publish: ?PublishHandler = null,
    on_publish_ctx: ?*anyopaque = null,
    /// Serializes writes so a background reader's acknowledgements cannot
    /// interleave with a foreground publish.
    write_mtx: Io.Mutex = .init,

    /// Connect to `host:port`, send CONNECT, await an accepted CONNACK.
    /// Accepts IPv4, IPv6, or a DNS hostname.
    pub fn connect(
        gpa: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        opts: proto.ConnectOptions,
    ) !MqttClient {
        return connectInner(gpa, io, host, port, opts, null);
    }

    /// Like `connect`, but wraps the transport in TLS (MQTT over TLS, e.g. port
    /// 8883). The CONNECT/CONNACK handshake then flows over the encrypted channel.
    pub fn connectTls(
        gpa: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        opts: proto.ConnectOptions,
        tls_opts: TlsOpts,
    ) !MqttClient {
        return connectInner(gpa, io, host, port, opts, tls_opts);
    }

    fn connectInner(
        gpa: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        opts: proto.ConnectOptions,
        tls_opts: ?TlsOpts,
    ) !MqttClient {
        const stream = if (net.IpAddress.parse(host, port)) |ip|
            try ip.connect(io, .{ .mode = .stream })
        else |_|
            try (try net.HostName.init(host)).connect(io, port, .{ .mode = .stream });
        errdefer stream.close(io);

        const reader_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(reader_buf);

        var self: MqttClient = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader_buf = reader_buf,
            .rdr = stream.reader(io, reader_buf),
        };
        // On any handshake-failure return below, release the socket + the
        // (possibly grown) body scratch. These do NOT fire on the success path
        // (the returned struct owns them; the caller's deinit frees them).
        errdefer self.body_scratch.deinit(gpa);

        // Optional TLS handshake before MQTT CONNECT.
        if (tls_opts) |to| {
            self.tls = try tls_transport.connect(gpa, io, stream, to);
        }
        errdefer if (self.tls) |t| tls_transport.deinit(gpa, t);

        const connect_pkt = try proto.encodeConnect(gpa, opts);
        defer gpa.free(connect_pkt);
        try self.writeAll(connect_pkt);

        // Await CONNACK (body borrows body_scratch; consumed before next read).
        const pkt = try self.readPacket();
        if (pkt.ptype != .connack) return error.ConnectionRejected;
        if (try proto.parseConnack(pkt) != .accepted) return error.ConnectionRejected;
        return self;
    }

    /// Close the socket and free the client's buffers. Callers that want a
    /// clean broker-side close call `disconnect` first.
    pub fn deinit(self: *MqttClient) void {
        if (self.tls) |t| tls_transport.deinit(self.gpa, t);
        self.stream.close(self.io);
        self.body_scratch.deinit(self.gpa);
        self.gpa.free(self.reader_buf);
        self.* = undefined;
    }

    fn writeAll(self: *MqttClient, bytes: []const u8) !void {
        if (self.tls) |t| {
            try t.client.writer.writeAll(bytes);
            // tls flush encrypts pending plaintext into the underlying (net)
            // writer's buffer but does NOT flush that to the socket — do both.
            try tls_transport.flush(t);
            return;
        }
        var wbuf: [256]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    fn writeLocked(self: *MqttClient, bytes: []const u8) !void {
        try self.write_mtx.lock(self.io);
        defer self.write_mtx.unlock(self.io);
        try self.writeAll(bytes);
    }

    /// The inbound byte stream: the decrypted TLS reader when TLS is active, else
    /// the raw socket reader.
    fn inIface(self: *MqttClient) *std.Io.Reader {
        if (self.tls) |t| return &t.client.reader;
        return &self.rdr.interface;
    }

    /// Encode + send a PUBLISH. QoS 1 and 2 allocate a packet id; the broker's
    /// PUBACK/PUBREC is handled by the read loop.
    pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        const id = if (qos > 0) self.nextId() else 0;
        const pkt = try proto.encodePublish(self.gpa, topic, payload, qos, retain, id);
        defer self.gpa.free(pkt);
        try self.writeLocked(pkt);
    }

    pub fn subscribe(self: *MqttClient, topic_filter: []const u8, qos: u2) !void {
        const pkt = try proto.encodeSubscribe(self.gpa, self.nextId(), topic_filter, qos);
        defer self.gpa.free(pkt);
        try self.writeLocked(pkt);
    }

    pub fn ping(self: *MqttClient) !void {
        try self.writeLocked(&proto.pingreq);
    }

    /// Send DISCONNECT so the broker discards the Last Will. Best effort: a
    /// failed write leaves the will armed, which is the right outcome for a
    /// broken connection.
    pub fn disconnect(self: *MqttClient) void {
        self.writeLocked(&proto.disconnect) catch {};
    }

    /// Interrupt transport reads and writes from another thread. Call this
    /// before joining the reader thread.
    pub fn shutdownRecv(self: *MqttClient) void {
        self.stream.shutdown(self.io, .both) catch {};
    }

    fn nextId(self: *MqttClient) u16 {
        // fetchAdd wraps 0xFFFF→0; 0 is not a valid MQTT packet id, so skip it.
        while (true) {
            const old = self.next_id.fetchAdd(1, .monotonic);
            if (old != 0) return old;
        }
    }

    /// Read exactly one packet off the wire (blocking). The returned body
    /// borrows `body_scratch` and is valid only until the next read.
    fn readPacket(self: *MqttClient) !proto.Packet {
        return proto.readPacket(self.inIface(), self.gpa, &self.body_scratch, max_packet_len);
    }

    /// Read and dispatch one inbound packet. PUBLISH → on_publish, then PUBACK
    /// (QoS 1) or PUBREC (QoS 2). PUBREL → PUBCOMP and PUBREC → PUBREL complete
    /// the QoS 2 flows. Other control packets (SUBACK, PUBACK, PUBCOMP,
    /// PINGRESP) are accepted and ignored. Returns the packet type handled.
    pub fn readOne(self: *MqttClient) !proto.PacketType {
        const pkt = try self.readPacket();
        switch (pkt.ptype) {
            .publish => {
                const view = try proto.parsePublish(pkt);
                if (self.on_publish) |cb| {
                    if (self.on_publish_ctx) |c| cb(c, view.topic, view.payload);
                }
                switch (view.qos) {
                    0 => {},
                    1 => try self.writeLocked(&proto.ack(.puback, view.packet_id)),
                    2 => try self.writeLocked(&proto.ack(.pubrec, view.packet_id)),
                    3 => unreachable, // parsePublish rejects QoS 3
                }
            },
            .pubrec => try self.writeLocked(&proto.ack(.pubrel, try pkt.packetId())),
            .pubrel => try self.writeLocked(&proto.ack(.pubcomp, try pkt.packetId())),
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
/// CONNECT/CONNACK handshake, then services SUBSCRIBE (SUBACK), counts
/// SUBSCRIBE, PUBLISH and PINGREQ packets and records the last PUBLISH and
/// SUBSCRIBE it receives. Can inject a PUBLISH to the client.
pub const TestBroker = struct {
    alloc: std.mem.Allocator = std.heap.smp_allocator,
    io: Io,
    server: net.Server,
    stream: ?net.Stream = null,
    rbuf: [4096]u8 = undefined,
    body: std.ArrayList(u8) = .empty,
    /// CONNECT body copy, so tests can check the client id and the will.
    connect: [256]u8 = undefined,
    connect_len: usize = 0,
    got_topic: [256]u8 = undefined,
    got_topic_len: usize = 0,
    got_payload: [256]u8 = undefined,
    got_payload_len: usize = 0,
    got_retain: bool = false,
    last_subscribe: [128]u8 = undefined,
    last_subscribe_len: usize = 0,
    publishes: std.atomic.Value(u32) = .init(0),
    subscribes: std.atomic.Value(u32) = .init(0),
    pings: std.atomic.Value(u32) = .init(0),

    pub fn bind(io: Io) !TestBroker {
        var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try ip.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server };
    }

    pub fn port(self: *const TestBroker) u16 {
        return self.server.socket.address.getPort();
    }

    fn writeAll(self: *TestBroker, stream: net.Stream, bytes: []const u8) !void {
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    fn copy(dest: []u8, len: *usize, src: []const u8) void {
        const n = @min(dest.len, src.len);
        @memcpy(dest[0..n], src[0..n]);
        len.* = n;
    }

    /// Accept + handshake + service `nframes` client packets.
    pub fn run(self: *TestBroker, nframes: usize) void {
        const stream = self.server.accept(self.io) catch return;
        self.stream = stream;
        var r = stream.reader(self.io, &self.rbuf);

        // CONNECT → CONNACK accepted.
        const c = proto.readPacket(&r.interface, self.alloc, &self.body, max_packet_len) catch return;
        copy(&self.connect, &self.connect_len, c.body);
        self.writeAll(stream, &.{ 0x20, 0x02, 0x00, 0x00 }) catch return;

        var handled: usize = 0;
        while (handled < nframes) : (handled += 1) {
            const pkt = proto.readPacket(&r.interface, self.alloc, &self.body, max_packet_len) catch return;
            switch (pkt.ptype) {
                .subscribe => {
                    const pid = pkt.packetId() catch return;
                    // Body: id(2) + filter length(2) + filter + requested qos(1).
                    if (pkt.body.len >= 5) copy(&self.last_subscribe, &self.last_subscribe_len, pkt.body[4 .. pkt.body.len - 1]);
                    _ = self.subscribes.fetchAdd(1, .release);
                    // SUBACK: packet id + granted qos 0.
                    self.writeAll(stream, &.{ 0x90, 0x03, @intCast(pid >> 8), @intCast(pid & 0xFF), 0x00 }) catch return;
                },
                .publish => {
                    const v = proto.parsePublish(pkt) catch continue;
                    copy(&self.got_topic, &self.got_topic_len, v.topic);
                    copy(&self.got_payload, &self.got_payload_len, v.payload);
                    self.got_retain = v.retain;
                    _ = self.publishes.fetchAdd(1, .release);
                },
                .pingreq => _ = self.pings.fetchAdd(1, .release),
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
        self.body.deinit(self.alloc);
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

    var broker = try TestBroker.bind(io);
    defer broker.deinit();
    const p = broker.port();

    // Broker services 1 frame (the publish) after the handshake.
    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });

    var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", p, .{ .client_id = "phobos-test" });
    defer client.deinit();

    try client.publish("phobos/instance/test", "hello-broker", 0, false);
    bf.await(io);

    try testing.expectEqualStrings("phobos/instance/test", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("hello-broker", broker.got_payload[0..broker.got_payload_len]);
}

fn freeTcpPort(io: Io) !u16 {
    var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try ip.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    return srv.socket.address.getPort();
}

// End-to-end MQTT over TLS: socat TLS-terminates and forwards to the plaintext
// TestBroker (std has no TLS server, so socat is the TLS peer). Skips if
// openssl/socat aren't installed; a real handshake/CONNACK failure still fails.
test "client connects over TLS (socat OpenSSL proxy → plaintext broker)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const cert = try std.fs.path.join(alloc, &.{ dir, "cert.pem" });
    const key = try std.fs.path.join(alloc, &.{ dir, "key.pem" });

    const gen = std.process.run(alloc, io, .{ .argv = &.{ "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(gen.term == .exited and gen.term.exited == 0);

    var broker = try TestBroker.bind(io);
    defer broker.deinit();
    const tport = try freeTcpPort(io);

    // socat: TLS listener on tport, forwarding plaintext to the broker.
    const listen = try std.fmt.allocPrint(alloc, "OPENSSL-LISTEN:{d},bind=127.0.0.1,cert={s},key={s},verify=0,reuseaddr,fork", .{ tport, cert, key });
    const fwd = try std.fmt.allocPrint(alloc, "TCP:127.0.0.1:{d}", .{broker.port()});
    var socat = std.process.spawn(io, .{ .argv = &.{ "socat", listen, fwd }, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer socat.kill(io); // kill() reaps; wait() would assert id != null

    // Cancel, not close, unblocks the broker's accept if the client never connects.
    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });
    defer bf.cancel(io);

    // Connect over TLS, retrying while socat comes up (~up to 5 s).
    var client: ?MqttClient = null;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (MqttClient.connectTls(testing.allocator, io, "127.0.0.1", tport, .{ .client_id = "phobos-tls" }, .{ .host = "localhost", .insecure = true })) |c| {
            client = c;
            break;
        } else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
    }
    const c = if (client) |*cl| cl else return error.TlsConnectFailed;
    defer c.deinit();

    try c.publish("phobos/tls", "secure-hi", 0, false);
    bf.await(io);
    try testing.expectEqualStrings("phobos/tls", broker.got_topic[0..broker.got_topic_len]);
    try testing.expectEqualStrings("secure-hi", broker.got_payload[0..broker.got_payload_len]);
}

test "client subscribes and receives an injected publish" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = try TestBroker.bind(io);
    defer broker.deinit();
    const p = broker.port();

    // Broker services 1 frame (the subscribe), then injects a publish.
    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });

    var client = try MqttClient.connect(testing.allocator, io, "localhost", p, .{ .client_id = "c" });
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
    try testing.expectEqualStrings("phobos/#", broker.last_subscribe[0..broker.last_subscribe_len]);
}

test "TLS setup frees every partial buffer allocation" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    for (0..6) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        try testing.expectError(error.OutOfMemory, MqttClient.connectTls(failing.allocator(), io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "oom" }, .{ .host = "127.0.0.1", .insecure = true }));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "connect preserves PUBLISH buffered with CONNACK when the client moves" {
    const io = testing.io;
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const Broker = struct {
        fn run(s: *net.Server, aio: Io) !void {
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(aio, &rbuf);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(std.heap.smp_allocator);
            _ = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(aio, &wbuf);
            try writer.interface.writeAll(&.{ 0x20, 2, 0, 0, 0x30, 4, 0, 1, 't', 'v' });
            try writer.interface.flush();
        }
    };
    var future = try io.concurrent(Broker.run, .{ &server, io });
    defer future.cancel(io) catch {};
    const client = try testing.allocator.create(MqttClient);
    defer testing.allocator.destroy(client);
    client.* = try MqttClient.connect(testing.allocator, io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "buffered" });
    defer client.deinit();
    var captured: Captured = .{};
    client.on_publish = Captured.cb;
    client.on_publish_ctx = &captured;
    _ = try client.readOne();
    try testing.expectEqualStrings("t", captured.topic[0..captured.topic_len]);
    try testing.expectEqualStrings("v", captured.payload[0..captured.payload_len]);
    try future.await(io);
}

test "readOne completes QoS 2 handshakes; ping and disconnect reach the broker" {
    const io = testing.io;
    var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const Broker = struct {
        fn run(s: *net.Server, aio: Io, replies: *[16]u8) !void {
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(aio, &rbuf);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(std.heap.smp_allocator);
            _ = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(aio, &wbuf);
            // CONNACK, inbound QoS 2 PUBLISH id 7, PUBREL id 7, PUBREC id 9.
            try writer.interface.writeAll(&.{ 0x20, 2, 0, 0, 0x34, 6, 0, 1, 't', 0, 7, 'v' });
            try writer.interface.writeAll(&(proto.ack(.pubrel, 7) ++ proto.ack(.pubrec, 9)));
            try writer.interface.flush();
            // PUBREC 7, PUBCOMP 7, PUBREL 9, PINGREQ, DISCONNECT.
            try reader.interface.readSliceAll(replies);
        }
    };
    var replies: [16]u8 = undefined;
    var future = try io.concurrent(Broker.run, .{ &server, io, &replies });
    defer future.cancel(io) catch {};
    var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "qos2" });
    defer client.deinit();
    var captured: Captured = .{};
    client.on_publish = Captured.cb;
    client.on_publish_ctx = &captured;
    try testing.expectEqual(proto.PacketType.publish, try client.readOne());
    try testing.expectEqual(proto.PacketType.pubrel, try client.readOne());
    try testing.expectEqual(proto.PacketType.pubrec, try client.readOne());
    try client.ping();
    client.disconnect();
    try future.await(io);
    try testing.expectEqualStrings("v", captured.payload[0..captured.payload_len]);
    const expected = proto.ack(.pubrec, 7) ++ proto.ack(.pubcomp, 7) ++ proto.ack(.pubrel, 9) ++ proto.pingreq ++ proto.disconnect;
    try testing.expectEqualSlices(u8, &expected, &replies);
}

test "fuzz readOne: arbitrary broker bytes after CONNACK never crash the client" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const io = testing.io;
            var bytes: [48]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
            defer server.deinit(io);
            const Broker = struct {
                fn serve(s: *net.Server, aio: Io, data: []const u8) !void {
                    const stream = try s.accept(aio);
                    defer stream.close(aio);
                    var rbuf: [512]u8 = undefined;
                    var reader = stream.reader(aio, &rbuf);
                    var body: std.ArrayList(u8) = .empty;
                    defer body.deinit(std.heap.smp_allocator);
                    _ = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
                    var wbuf: [128]u8 = undefined;
                    var writer = stream.writer(aio, &wbuf);
                    try writer.interface.writeAll(&.{ 0x20, 2, 0, 0 });
                    try writer.interface.writeAll(data);
                    try writer.interface.flush();
                    // End the stream so the client's last readOne fails, then
                    // drain its acknowledgements until it closes.
                    try stream.shutdown(aio, .send);
                    while (true) _ = reader.interface.takeByte() catch break;
                }
            };
            var future = try io.concurrent(Broker.serve, .{ &server, io, @as([]const u8, &bytes) });
            defer future.cancel(io) catch {};
            var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "fuzz" });
            defer client.deinit();
            // The fixed input ends, so the stream closes and readOne errors.
            while (true) _ = client.readOne() catch break;
        }
    }.run, .{});
}

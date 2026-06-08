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
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// TLS transport options for `connectTls`. When `insecure` is set, the server
/// certificate is accepted as a self-signed cert with no host verification
/// (for self-signed brokers / tests). Otherwise the cert is verified for `host`
/// against `ca_path` (a PEM bundle) when given, or the system CA bundle.
pub const TlsOpts = struct {
    host: []const u8,
    insecure: bool = false,
    ca_path: ?[]const u8 = null,
};

/// Heap-stable TLS transport state. The std `tls.Client` recovers itself from
/// `&client.reader`/`&client.writer` via @fieldParentPtr, and holds pointers to
/// `net_reader`/`net_writer`, so this whole struct must never move after init.
const TlsState = struct {
    nrbuf: []u8, // ciphertext transport read buffer (>= tls min_buffer_len)
    nwbuf: []u8, // ciphertext transport write buffer
    rbuf: []u8, // decrypted read buffer
    wbuf: []u8, // decrypted write buffer
    net_reader: net.Stream.Reader,
    net_writer: net.Stream.Writer,
    bundle: ?Certificate.Bundle = null,
    rwlock: Io.RwLock = .init,
    client: tls.Client = undefined,
};

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
    /// returned by readRawPacket borrows this; valid only until the next read.
    body_scratch: std.ArrayList(u8) = .empty,
    /// Packet-id source. Atomic so a foreground publish/subscribe and any future
    /// concurrent caller never race the increment. Never yields 0 (invalid id).
    next_id: std.atomic.Value(u16) = std.atomic.Value(u16).init(1),
    connected: bool = false,
    /// When set, all I/O is routed through this TLS layer instead of the raw
    /// stream. Heap-owned (must not move); freed in deinit.
    tls: ?*TlsState = null,
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
        // On any handshake-failure return below, release the socket + the
        // (possibly grown) body scratch. These do NOT fire on the success path
        // (the returned struct owns them; the caller's deinit frees them).
        errdefer stream.close(io);
        errdefer self.body_scratch.deinit(gpa);

        // Optional TLS handshake before MQTT CONNECT.
        if (tls_opts) |to| {
            self.tls = try setupTls(gpa, io, stream, to);
        }
        errdefer if (self.tls) |t| freeTls(gpa, io, t);

        // Send CONNECT.
        const connect_pkt = try proto.encodeConnect(gpa, opts);
        defer gpa.free(connect_pkt);
        try self.writeAll(connect_pkt);

        // Await CONNACK (body borrows body_scratch; consumed before next read).
        const owned = try self.readRawPacket();
        const pkt = proto.Packet{ .ptype = owned.ptype(), .flags = owned.flags(), .body = owned.body, .total = 0 };
        if (pkt.ptype != .connack) return error.ConnectionRejected;
        const code = try proto.parseConnack(pkt);
        if (code != .accepted) return error.ConnectionRejected;
        self.connected = true;
        return self;
    }

    /// Build the heap-stable TLS layer over an already-connected `stream` and run
    /// the TLS handshake. The std `tls.Client` recovers itself via @fieldParentPtr
    /// and references net_reader/net_writer, so everything lives in the heap struct.
    fn setupTls(gpa: std.mem.Allocator, io: Io, stream: net.Stream, to: TlsOpts) !*TlsState {
        const t = try gpa.create(TlsState);
        errdefer gpa.destroy(t);
        const min = tls.Client.min_buffer_len;
        t.* = .{
            .nrbuf = try gpa.alloc(u8, min + 256),
            .nwbuf = try gpa.alloc(u8, min + 256),
            .rbuf = try gpa.alloc(u8, 16384),
            .wbuf = try gpa.alloc(u8, 16384),
            .net_reader = undefined,
            .net_writer = undefined,
        };
        errdefer gpa.free(t.nrbuf);
        errdefer gpa.free(t.nwbuf);
        errdefer gpa.free(t.rbuf);
        errdefer gpa.free(t.wbuf);
        t.net_reader = stream.reader(io, t.nrbuf);
        t.net_writer = stream.writer(io, t.nwbuf);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        // Fill the TLS entropy from the kernel CSPRNG (std.crypto.random is not
        // available in this stripped std).
        var got: usize = 0;
        while (got < entropy.len) {
            const rc = std.os.linux.getrandom(entropy[got..].ptr, entropy.len - got, 0);
            const signed: isize = @bitCast(rc);
            if (signed <= 0) return error.EntropyFailed;
            got += rc;
        }
        const now = Io.Timestamp.now(io, .real);

        var options: tls.Client.Options = .{
            .host = if (to.insecure) .no_verification else .{ .explicit = to.host },
            .ca = .self_signed, // overridden below when verifying
            .write_buffer = t.wbuf,
            .read_buffer = t.rbuf,
            .entropy = &entropy,
            .realtime_now = now,
        };
        if (!to.insecure) {
            t.bundle = .{ .map = .empty, .bytes = .empty };
            errdefer if (t.bundle) |*b| b.deinit(gpa);
            if (to.ca_path) |p|
                try t.bundle.?.addCertsFromFilePathAbsolute(gpa, io, now, p)
            else
                try t.bundle.?.rescan(gpa, io, now);
            options.ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &t.rwlock, .bundle = &t.bundle.? } };
        }
        t.client = try tls.Client.init(&t.net_reader.interface, &t.net_writer.interface, options);
        return t;
    }

    fn freeTls(gpa: std.mem.Allocator, io: Io, t: *TlsState) void {
        _ = io;
        if (t.bundle) |*b| b.deinit(gpa);
        gpa.free(t.nrbuf);
        gpa.free(t.nwbuf);
        gpa.free(t.rbuf);
        gpa.free(t.wbuf);
        gpa.destroy(t);
    }

    pub fn deinit(self: *MqttClient) void {
        self.disconnect();
        if (self.tls) |t| freeTls(self.gpa, self.io, t);
        self.body_scratch.deinit(self.gpa);
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
        if (self.tls) |t| {
            try t.client.writer.writeAll(bytes);
            // tls flush encrypts pending plaintext into the underlying (net)
            // writer's buffer but does NOT flush that to the socket — do both.
            try t.client.writer.flush();
            try t.net_writer.interface.flush();
            return;
        }
        var wbuf: [256]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    /// The inbound byte stream: the decrypted TLS reader when TLS is active, else
    /// the raw socket reader.
    fn inIface(self: *MqttClient) *std.Io.Reader {
        if (self.tls) |t| return &t.client.reader;
        return &self.rdr.interface;
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
        // fetchAdd wraps 0xFFFF→0; 0 is not a valid MQTT packet id, so skip it.
        while (true) {
            const old = self.next_id.fetchAdd(1, .monotonic);
            if (old != 0) return old;
        }
    }

    const RawPacket = struct {
        b0: u8,
        body: []u8, // borrows client.body_scratch; valid until the next read
        fn ptype(self: RawPacket) proto.PacketType {
            return @enumFromInt(@as(u4, @intCast(self.b0 >> 4)));
        }
        fn flags(self: RawPacket) u4 {
            return @intCast(self.b0 & 0x0F);
        }
    };

    /// Read exactly one packet off the wire (blocking). The returned body
    /// borrows `body_scratch` and is valid only until the next read.
    fn readRawPacket(self: *MqttClient) !RawPacket {
        const r = self.inIface();
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
        try self.body_scratch.ensureTotalCapacity(self.gpa, rl);
        self.body_scratch.items.len = rl;
        const body = self.body_scratch.items[0..rl];
        if (rl > 0) try r.readSliceAll(body);
        return .{ .b0 = b0, .body = body };
    }

    /// Read and dispatch one inbound packet. PUBLISH → on_publish (+ PUBACK for
    /// QoS 1). PINGREQ → PINGRESP. Other control packets (CONNACK already
    /// consumed, SUBACK, PUBACK, PINGRESP) are accepted and ignored. Returns the
    /// packet type handled.
    pub fn readOne(self: *MqttClient) !proto.PacketType {
        const raw = try self.readRawPacket();
        const pkt = proto.Packet{ .ptype = raw.ptype(), .flags = raw.flags(), .body = raw.body, .total = 0 };
        switch (pkt.ptype) {
            .publish => {
                const view = try proto.parsePublish(pkt);
                if (self.on_publish) |cb| {
                    if (self.on_publish_ctx) |c| cb(c, view.topic, view.payload);
                }
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
                    const pid = std.mem.readInt(u16, raw.body[0..2], .big);
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

fn freeTcpPort(io: Io) !u16 {
    var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var srv = try ip.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    var sa: std.os.linux.sockaddr.in = undefined;
    var slen: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
    _ = std.os.linux.getsockname(srv.socket.handle, @ptrCast(&sa), &slen);
    return std.mem.bigToNative(u16, sa.port);
}

// End-to-end MQTT over TLS: socat TLS-terminates and forwards to the plaintext
// TestBroker (std has no TLS server, so socat is the TLS peer). Skips cleanly if
// openssl/socat aren't installed; a real handshake/CONNACK failure still fails.
test "client connects over TLS (socat OpenSSL proxy → plaintext broker)" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "/tmp/phobos-mqtt-tls-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;

    // Generate a self-signed cert (skip the test if openssl is unavailable).
    const gen = std.process.run(alloc, io, .{ .argv = &.{
        "openssl",          "req",                "-x509",          "-newkey",
        "rsa:2048",         "-nodes",             "-keyout",        dir ++ "/key.pem",
        "-out",             dir ++ "/cert.pem",   "-days",          "1",
        "-subj",            "/CN=localhost",
    } }) catch return;
    alloc.free(gen.stdout);
    alloc.free(gen.stderr);
    if (gen.term != .exited or gen.term.exited != 0) return;

    var broker = try TestBroker.bind(alloc, io);
    const bport = try broker.port();
    const tport = try freeTcpPort(io);

    // socat: TLS listener on tport, forwarding plaintext to the broker on bport.
    var lbuf: [128]u8 = undefined;
    var fbuf: [64]u8 = undefined;
    const listen = std.fmt.bufPrint(&lbuf, "OPENSSL-LISTEN:{d},cert={s}/cert.pem,key={s}/key.pem,verify=0,reuseaddr,fork", .{ tport, dir, dir }) catch return;
    const fwd = std.fmt.bufPrint(&fbuf, "TCP:127.0.0.1:{d}", .{bport}) catch return;
    var socat = std.process.spawn(io, .{
        .argv = &.{ "socat", listen, fwd },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        broker.deinit();
        return;
    };
    defer socat.kill(io); // kill() reaps; wait() would assert id != null

    var bf = io.async(TestBroker.run, .{ &broker, @as(usize, 1) });

    // Connect over TLS, retrying while socat comes up (~up to 5 s).
    var client: ?MqttClient = null;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (MqttClient.connectTls(alloc, io, "127.0.0.1", tport, .{ .client_id = "phobos-tls" }, .{ .host = "localhost", .insecure = true })) |c| {
            client = c;
            break;
        } else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
    }

    if (client) |*c| {
        c.rebind();
        try testing.expect(c.connected);
        c.publish("phobos/tls", "secure-hi", 0, false) catch {};
        bf.await(io);
        c.deinit();
        broker.deinit();
        try testing.expectEqualStrings("phobos/tls", broker.got_topic[0..broker.got_topic_len]);
        try testing.expectEqualStrings("secure-hi", broker.got_payload[0..broker.got_payload_len]);
    } else {
        // Never connected: unblock the broker's accept, drain, then fail.
        broker.deinit();
        bf.await(io);
        return error.TlsConnectFailed;
    }
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

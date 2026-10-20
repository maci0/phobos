//! MQTT 3.1, 3.1.1 and 5 client over `std.Io.net`.
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
pub const max_packet_len = proto.max_packet_length;
pub const max_pending = proto.receive_maximum;

pub const MqttClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    protocol: proto.Protocol = .v311,
    limits: proto.Properties = .{ .next = 0 },
    /// Persistent receive buffer + reader. Heap-owned so the reader's internal
    /// buffer pointer stays valid for the client's lifetime.
    reader_buf: []u8,
    rdr: net.Stream.Reader,
    /// Reusable inbound packet-body buffer — grown to the largest packet seen and
    /// reused, so steady inbound traffic does not alloc/free per packet. The body
    /// returned by readPacket borrows this; valid only until the next read.
    body_scratch: std.ArrayList(u8) = .empty,
    /// Pending ids and completion events are protected by pending_mutex.
    next_id: u16 = 1,
    pending_mutex: Io.Mutex = .init,
    pending: [max_pending]Pending = @splat(.{}),
    closed: bool = false,
    inbound_qos2: [max_pending]u16 = @splat(0),
    /// When set, all I/O is routed through this TLS layer instead of the raw
    /// stream. Heap-owned (must not move); freed in deinit.
    tls: ?*TlsState = null,
    on_publish: ?PublishHandler = null,
    on_publish_ctx: ?*anyopaque = null,
    /// Serializes writes so a background reader's acknowledgements cannot
    /// interleave with a foreground publish.
    write_mtx: Io.Mutex = .init,
    /// Set before PINGREQ and cleared only by the reader receiving PINGRESP.
    ping_pending: std.atomic.Value(bool) = .init(false),

    const Pending = struct {
        id: u16 = 0,
        expected: proto.PacketType = .puback,
        waiting: bool = false,
        complete: bool = false,
        sending: bool = true,
        failure: ?anyerror = null,
        done: Io.Event = .unset,
    };

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
            .protocol = opts.protocol,
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
        if (try proto.parseConnack(opts.protocol, pkt) != .accepted) return error.ConnectionRejected;
        if (opts.clean_session and pkt.body[0] != 0) return error.MalformedPacket;
        if (opts.protocol == .v5) self.limits = try proto.properties(pkt.body, 2, .connack);
        return self;
    }

    /// Close the socket and free the client's buffers. Callers that want a
    /// clean broker-side close call `disconnect` first.
    pub fn deinit(self: *MqttClient) void {
        self.cancelPending();
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
        if (bytes.len > self.limits.max_packet) return error.PacketTooLarge;
        try self.write_mtx.lock(self.io);
        defer self.write_mtx.unlock(self.io);
        self.writeAll(bytes) catch |err| {
            self.shutdownRecv();
            return err;
        };
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
        const slot = if (qos > 0) try self.reserve(if (qos == 1) .puback else .pubrec, false) else null;
        var sent = false;
        defer if (slot) |entry| self.finishSend(entry, sent);
        try self.sendPublish(topic, payload, qos, retain, if (slot) |entry| entry.id else 0);
        sent = true;
    }

    fn sendPublish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: u2, retain: bool, id: u16) !void {
        if (qos > self.limits.max_qos or (retain and !self.limits.retain_available)) return error.UnsupportedPublish;
        const pkt = try proto.encodePublish(self.gpa, self.protocol, topic, payload, qos, retain, id);
        defer self.gpa.free(pkt);
        if (pkt.len > self.limits.max_packet) return error.PacketTooLarge;
        try self.writeLocked(pkt);
    }

    /// Off-reader callers only. Timeout covers lock acquisition, write and ACK.
    /// Cancellation or timeout closes this session before retiring its packet id.
    pub fn publishAwait(self: *MqttClient, topic: []const u8, payload: []const u8, qos: u2, retain: bool, timeout: ?Io.Duration) !void {
        if (timeout == null) return self.publishWaitInner(topic, payload, qos, retain) catch |err| {
            if (err == error.Canceled) self.shutdownRecv();
            return err;
        };
        const Task = struct {
            done: Io.Event = .unset,
            failure: ?anyerror = null,
            fn run(task: *@This(), client: *MqttClient, t: []const u8, p: []const u8, q: u2, r: bool) void {
                client.publishWaitInner(t, p, q, r) catch |err| {
                    task.failure = err;
                };
                task.done.set(client.io);
            }
        };
        var task: Task = .{};
        const deadline = Io.Clock.Timestamp.fromNow(self.io, .{ .raw = timeout.?, .clock = .awake });
        var future = try self.io.concurrent(Task.run, .{ &task, self, topic, payload, qos, retain });
        defer future.cancel(self.io);
        task.done.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| {
            self.shutdownRecv();
            return if (err == error.Timeout) error.PublishTimeout else err;
        };
        if (task.failure) |failure| return failure;
    }

    fn publishWaitInner(self: *MqttClient, topic: []const u8, payload: []const u8, qos: u2, retain: bool) !void {
        if (qos == 0) return self.sendPublish(topic, payload, qos, retain, 0);
        const entry = try self.reserve(if (qos == 1) .puback else .pubrec, true);
        defer self.release(entry);
        try self.sendPublish(topic, payload, qos, retain, entry.id);
        entry.done.wait(self.io) catch |err| {
            self.shutdownRecv();
            return err;
        };
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        if (entry.failure) |failure| return failure;
    }

    pub fn subscribe(self: *MqttClient, topic_filter: []const u8, qos: u2) !void {
        const entry = try self.reserve(.suback, false);
        var sent = false;
        defer self.finishSend(entry, sent);
        const pkt = try proto.encodeSubscribe(self.gpa, self.protocol, entry.id, topic_filter, qos);
        defer self.gpa.free(pkt);
        try self.writeLocked(pkt);
        sent = true;
    }

    pub fn unsubscribe(self: *MqttClient, topic_filter: []const u8) !void {
        const entry = try self.reserve(.unsuback, false);
        var sent = false;
        defer self.finishSend(entry, sent);
        const pkt = try proto.encodeUnsubscribe(self.gpa, self.protocol, entry.id, topic_filter);
        defer self.gpa.free(pkt);
        try self.writeLocked(pkt);
        sent = true;
    }

    pub fn ping(self: *MqttClient) !void {
        self.ping_pending.store(true, .release);
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
        self.cancelPending();
        self.stream.shutdown(self.io, .both) catch {};
    }

    /// Call before waiting for component client pins or joining the reader.
    pub fn cancelPending(self: *MqttClient) void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        self.closed = true;
        for (&self.pending) |*entry| if (entry.id != 0) self.finishLocked(entry, error.Disconnected);
    }

    fn reserve(self: *MqttClient, expected: proto.PacketType, waiting: bool) !*Pending {
        try self.pending_mutex.lock(self.io);
        defer self.pending_mutex.unlock(self.io);
        if (self.closed) return error.Disconnected;
        var empty: ?*Pending = null;
        var inflight: usize = 0;
        for (&self.pending) |*entry| {
            if (entry.id == 0) {
                empty = entry;
                continue;
            }
            if (entry.expected == .puback or entry.expected == .pubrec or entry.expected == .pubcomp) inflight += 1;
        }
        if ((expected == .puback or expected == .pubrec) and inflight >= self.limits.receive_max) return error.MessageQueueFull;
        const entry = empty orelse return error.MessageQueueFull;
        while (true) {
            const id = self.next_id;
            self.next_id +%= 1;
            if (id == 0) continue;
            var used = false;
            for (&self.pending) |*other| if (other.id == id) {
                used = true;
                break;
            };
            if (!used) {
                entry.* = .{ .id = id, .expected = expected, .waiting = waiting };
                return entry;
            }
        }
    }

    fn release(self: *MqttClient, entry: *Pending) void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        entry.* = .{};
    }

    fn finishSend(self: *MqttClient, entry: *Pending, success: bool) void {
        self.pending_mutex.lockUncancelable(self.io);
        defer self.pending_mutex.unlock(self.io);
        entry.sending = false;
        if (!success or entry.complete) entry.* = .{};
    }

    fn finishLocked(self: *MqttClient, entry: *Pending, failure: ?anyerror) void {
        if (entry.complete) return;
        if (entry.waiting) {
            entry.failure = failure;
            entry.complete = true;
            entry.done.set(self.io);
        } else if (entry.sending) {
            entry.complete = true;
        } else entry.* = .{};
    }

    fn acknowledge(self: *MqttClient, pkt: proto.Packet) !void {
        const reason = try proto.parseAck(self.protocol, pkt);
        const id = try pkt.packetId();
        var send_rel = false;
        self.pending_mutex.lockUncancelable(self.io);
        for (&self.pending) |*entry| {
            if (entry.id != id or entry.complete) continue;
            if (pkt.ptype == .pubrec and entry.expected == .pubcomp) {
                if (reason >= 0x80) self.finishLocked(entry, error.BrokerRejected) else send_rel = true;
                break;
            }
            if (entry.expected != pkt.ptype) break;
            if (reason >= 0x80) {
                self.finishLocked(entry, error.BrokerRejected);
            } else if (pkt.ptype == .pubrec) {
                entry.expected = .pubcomp;
                send_rel = true;
            } else self.finishLocked(entry, null);
            break;
        }
        self.pending_mutex.unlock(self.io);
        if (send_rel) try self.writeLocked(&proto.ack(.pubrel, id));
        if (reason >= 0x80 and (pkt.ptype == .suback or pkt.ptype == .unsuback)) return error.BrokerRejected;
    }

    /// Read exactly one packet off the wire (blocking). The returned body
    /// borrows `body_scratch` and is valid only until the next read.
    fn readPacket(self: *MqttClient) !proto.Packet {
        return proto.readPacket(self.inIface(), self.gpa, &self.body_scratch, max_packet_len);
    }

    /// Read and dispatch one inbound packet. PUBLISH → on_publish, then PUBACK
    /// (QoS 1) or PUBREC (QoS 2). PUBREL → PUBCOMP and PUBREC → PUBREL complete
    /// the QoS 2 flows. ACKs complete their registered packet ids; protocol and
    /// transport failures wake every pending caller. Returns the handled type.
    pub fn readOne(self: *MqttClient) !proto.PacketType {
        errdefer self.cancelPending();
        const pkt = try self.readPacket();
        switch (pkt.ptype) {
            .publish => {
                const view = try proto.parsePublish(self.protocol, pkt);
                var deliver = true;
                if (view.qos == 2) {
                    var empty: ?*u16 = null;
                    for (&self.inbound_qos2) |*id| {
                        if (id.* == view.packet_id) {
                            deliver = false;
                            break;
                        }
                        if (id.* == 0) empty = id;
                    }
                    if (deliver) (empty orelse return error.MessageQueueFull).* = view.packet_id;
                }
                if (deliver) if (self.on_publish) |cb| {
                    if (self.on_publish_ctx) |c| cb(c, view.topic, view.payload);
                };
                switch (view.qos) {
                    0 => {},
                    1 => try self.writeLocked(&proto.ack(.puback, view.packet_id)),
                    2 => try self.writeLocked(&proto.ack(.pubrec, view.packet_id)),
                    3 => unreachable, // parsePublish rejects QoS 3
                }
            },
            .puback, .pubrec, .pubcomp, .suback, .unsuback => try self.acknowledge(pkt),
            .pubrel => {
                _ = try proto.parseAck(self.protocol, pkt);
                const id = try pkt.packetId();
                var found = false;
                for (&self.inbound_qos2) |*known| if (known.* == id) {
                    known.* = 0;
                    found = true;
                    break;
                };
                if (!found and self.protocol == .v5)
                    try self.writeLocked(&.{ 0x70, 4, @intCast(id >> 8), @truncate(id), 0x92, 0 })
                else
                    try self.writeLocked(&proto.ack(.pubcomp, id));
            },
            .pingresp => {
                if (pkt.flags != 0 or pkt.body.len != 0) return error.MalformedPacket;
                self.ping_pending.store(false, .release);
            },
            .disconnect => {
                try proto.validateDisconnect(self.protocol, pkt);
                return error.Disconnected;
            },
            else => return error.MalformedPacket,
        }
        return pkt.ptype;
    }
};

// ===========================================================================
// Tests — exercised against an in-file minimal broker double.
// ===========================================================================

const testing = std.testing;

const AckBroker = struct {
    io: Io,
    server: net.Server,
    protocol: proto.Protocol,
    mode: enum { success, reject_puback, reject_pubrec, reject_pubcomp, reject_subscribe, disconnect, stall, stop_reading, duplicate } = .success,
    published: Io.Event = .unset,
    unsubscribed: Io.Event = .unset,
    completed: Io.Event = .unset,
    received: std.atomic.Value(u32) = .init(0),

    fn run(self: *AckBroker) !void {
        const stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var wbuf: [256]u8 = undefined;
        var writer = stream.writer(self.io, &wbuf);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(std.heap.smp_allocator);
        const connect = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
        const level_offset: usize = if (self.protocol == .v31) 8 else 6;
        try testing.expectEqual(@as(u8, switch (self.protocol) {
            .v31 => 3,
            .v311 => 4,
            .v5 => 5,
        }), connect.body[level_offset]);
        try writer.interface.writeAll(if (self.protocol == .v5) &.{ 0x20, 3, 0, 0, 0 } else &.{ 0x20, 2, 0, 0 });
        try writer.interface.flush();
        if (self.mode == .stop_reading) {
            var never: Io.Event = .unset;
            try never.wait(self.io);
        }
        if (self.mode == .duplicate) {
            const publish = try proto.encodePublish(std.heap.smp_allocator, self.protocol, "dup", "value", 2, false, 7);
            defer std.heap.smp_allocator.free(publish);
            try writer.interface.writeAll(publish);
            publish[0] |= 8;
            try writer.interface.writeAll(publish);
            try writer.interface.flush();
        }
        while (true) {
            const packet = proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len) catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                else => return err,
            };
            switch (packet.ptype) {
                .publish => {
                    const view = try proto.parsePublish(self.protocol, packet);
                    if (self.mode != .stall) {
                        try testing.expectEqualStrings("payload", view.payload);
                        try testing.expectEqualStrings("topic", view.topic);
                    }
                    _ = self.received.fetchAdd(1, .release);
                    self.published.set(self.io);
                    if (self.mode == .disconnect) return;
                    if (self.mode == .stall) continue;
                    if (view.qos == 1) try sendAck(&writer.interface, self.protocol, .puback, view.packet_id, if (self.mode == .reject_puback) 0x87 else 0);
                    if (view.qos == 2) {
                        try sendAck(&writer.interface, self.protocol, .pubrec, view.packet_id, if (self.mode == .reject_pubrec) 0x87 else 0);
                        if (self.mode == .success) try sendAck(&writer.interface, self.protocol, .pubrec, view.packet_id, 0);
                    }
                },
                .pubrel => try sendAck(&writer.interface, self.protocol, .pubcomp, try packet.packetId(), if (self.mode == .reject_pubcomp) 0x92 else 0),
                .subscribe => {
                    try sendAck(&writer.interface, self.protocol, .suback, try packet.packetId(), if (self.mode == .reject_subscribe) 0x80 else 0);
                    if (self.mode == .reject_subscribe) self.completed.set(self.io);
                },
                .unsubscribe => {
                    const offset: usize = if (self.protocol == .v5) 3 else 2;
                    try testing.expectEqualSlices(u8, &.{ 0, 5, 't', 'o', 'p', 'i', 'c' }, packet.body[offset..]);
                    try sendAck(&writer.interface, self.protocol, .unsuback, try packet.packetId(), 0);
                    self.unsubscribed.set(self.io);
                },
                .pubrec => {
                    if (self.received.fetchAdd(1, .acq_rel) == 1) try sendAck(&writer.interface, self.protocol, .pubrel, try packet.packetId(), 0);
                },
                .pubcomp => self.completed.set(self.io),
                .disconnect => return,
                else => return error.UnexpectedPacket,
            }
        }
    }

    fn sendAck(writer: *Io.Writer, protocol: proto.Protocol, kind: proto.PacketType, id: u16, reason: u8) !void {
        if (kind == .suback or (protocol == .v5 and kind == .unsuback)) {
            const bytes = [_]u8{ @as(u8, @backingInt(kind)) << 4, if (protocol == .v5) 4 else 3, @intCast(id >> 8), @truncate(id), 0, reason };
            if (protocol == .v5) try writer.writeAll(&bytes) else try writer.writeAll(&.{ bytes[0], 3, bytes[2], bytes[3], reason });
        } else if (reason != 0) {
            try writer.writeAll(&.{ @as(u8, @backingInt(kind)) << 4, 4, @intCast(id >> 8), @truncate(id), reason, 0 });
        } else try writer.writeAll(&proto.ack(kind, id));
        try writer.flush();
    }
};

fn drainClient(client: *MqttClient) void {
    while (true) _ = client.readOne() catch return;
}

test "publishAwait completes QoS 1 and 2, then unsubscribes in every protocol" {
    const io = testing.io;
    inline for (std.meta.tags(proto.Protocol)) |protocol| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = protocol };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "allprotocols", .protocol = protocol });
        defer client.deinit();
        var reader = try io.concurrent(drainClient, .{&client});
        defer {
            client.shutdownRecv();
            reader.cancel(io);
        }
        try client.publishAwait("topic", "payload", 1, false, .fromSeconds(1));
        try client.publishAwait("topic", "payload", 2, false, .fromSeconds(1));
        try testing.expectEqual(@as(u32, 2), broker.received.load(.acquire));
        try client.subscribe("topic", 1);
        try client.unsubscribe("topic");
        try broker.unsubscribed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        client.shutdownRecv();
        reader.cancel(io);
        try peer.await(io);
    }
}

test "MQTT 5 publishAwait reports PUBACK, PUBREC and PUBCOMP rejection" {
    const io = testing.io;
    for ([_]@FieldType(AckBroker, "mode"){ .reject_puback, .reject_pubrec, .reject_pubcomp }) |mode| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v5, .mode = mode };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "reject", .protocol = .v5 });
        defer client.deinit();
        var reader = try io.concurrent(drainClient, .{&client});
        defer {
            client.shutdownRecv();
            reader.cancel(io);
        }
        try testing.expectError(error.BrokerRejected, client.publishAwait("topic", "payload", if (mode == .reject_puback) 1 else 2, false, .fromSeconds(1)));
    }
}

test "publish identifiers wrap without collision and bounded slots free only after ACK" {
    const io = testing.io;
    var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v311 };
    defer broker.server.deinit(io);
    var peer = try io.concurrent(AckBroker.run, .{&broker});
    defer peer.cancel(io) catch {};
    var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "window" });
    defer client.deinit();
    client.next_id = std.math.maxInt(u16);
    for (0..max_pending) |_| try client.publish("topic", "payload", 1, false);
    try testing.expectError(error.MessageQueueFull, client.publish("topic", "payload", 1, false));
    try testing.expectEqual(proto.PacketType.puback, try client.readOne());
    client.next_id = 1;
    try client.publish("topic", "payload", 1, false);
    try testing.expectEqual(@as(u16, 33), client.next_id);
    try testing.expectError(error.MessageQueueFull, client.subscribe("topic", 1));
}

test "subscription rejection fails the connection instead of pretending to subscribe" {
    const io = testing.io;
    inline for (std.meta.tags(proto.Protocol)) |protocol| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = protocol, .mode = .reject_subscribe };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "suback", .protocol = protocol });
        defer client.deinit();
        try client.subscribe("topic", 1);
        try testing.expectError(error.BrokerRejected, client.readOne());
        try testing.expectError(error.Disconnected, client.subscribe("topic", 0));
    }
}

test "publishAwait timeout and disconnect wake pending requests" {
    const io = testing.io;
    for ([_]@FieldType(AckBroker, "mode"){ .stall, .disconnect }) |mode| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v311, .mode = mode };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "wake" });
        defer client.deinit();
        var reader = try io.concurrent(drainClient, .{&client});
        defer {
            client.shutdownRecv();
            reader.cancel(io);
        }
        try testing.expectError(if (mode == .stall) error.PublishTimeout else error.Disconnected, client.publishAwait("topic", "payload", 1, false, .fromMilliseconds(30)));
        for (client.pending) |entry| try testing.expectEqual(@as(u16, 0), entry.id);
    }
}

test "publishAwait timeout includes a blocked write mutex and a stalled socket" {
    const io = testing.io;
    for ([_]bool{ false, true }) |stall_socket| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v311, .mode = if (stall_socket) .stop_reading else .stall };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "blocked" });
        defer client.deinit();
        const payload = try std.heap.smp_allocator.alloc(u8, if (stall_socket) max_packet_len else 1);
        defer std.heap.smp_allocator.free(payload);
        @memset(payload, 'x');
        if (!stall_socket) client.write_mtx.lockUncancelable(io);
        defer if (!stall_socket) client.write_mtx.unlock(io);
        try testing.expectError(error.PublishTimeout, client.publishAwait("topic", payload, 1, false, .fromMilliseconds(30)));
        for (client.pending) |entry| try testing.expectEqual(@as(u16, 0), entry.id);
    }
}

test "cancelPending releases an unlimited publish wait and cancellation retires ids" {
    const io = testing.io;
    for ([_]bool{ false, true }) |cancel_future| {
        var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v311, .mode = .stall };
        defer broker.server.deinit(io);
        var peer = try io.concurrent(AckBroker.run, .{&broker});
        defer peer.cancel(io) catch {};
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "cancel" });
        defer client.deinit();
        const Wait = struct {
            done: Io.Event = .unset,
            failure: ?anyerror = null,
            fn run(self: *@This(), c: *MqttClient) void {
                c.publishAwait("topic", "payload", 1, false, null) catch |err| {
                    self.failure = err;
                };
                self.done.set(c.io);
            }
        };
        var waiter: Wait = .{};
        var future = try io.concurrent(Wait.run, .{ &waiter, &client });
        defer future.cancel(io);
        try broker.published.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        if (cancel_future) future.cancel(io) else client.cancelPending();
        try waiter.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        future.await(io);
        try testing.expectEqual(if (cancel_future) error.Canceled else error.Disconnected, waiter.failure.?);
        for (client.pending) |entry| try testing.expectEqual(@as(u16, 0), entry.id);
    }
}

test "inbound QoS 2 duplicates are acknowledged without duplicate delivery" {
    const io = testing.io;
    var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = .v5, .mode = .duplicate };
    defer broker.server.deinit(io);
    var peer = try io.concurrent(AckBroker.run, .{&broker});
    defer peer.cancel(io) catch {};
    var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "duplicate", .protocol = .v5 });
    defer client.deinit();
    const Count = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn callback(ctx: *anyopaque, _: []const u8, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.count.fetchAdd(1, .release);
        }
    };
    var counter: Count = .{};
    client.on_publish = Count.callback;
    client.on_publish_ctx = &counter;
    var reader = try io.concurrent(drainClient, .{&client});
    defer {
        client.shutdownRecv();
        reader.cancel(io);
    }
    try broker.completed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try testing.expectEqual(@as(u32, 1), counter.count.load(.acquire));
}

test "fuzz publishAwait and unsubscribe complete mixed QoS windows across protocol versions" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const io = testing.io;
            const protocol: proto.Protocol = @fromBackingInt(@intCast(smith.valueRangeAtMostWithHash(u8, 0, 2, 0)));
            var broker: AckBroker = .{ .io = io, .server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}), .protocol = protocol };
            defer broker.server.deinit(io);
            var peer = try io.concurrent(AckBroker.run, .{&broker});
            defer peer.cancel(io) catch {};
            var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.server.socket.address.getPort(), .{ .client_id = "fuzzacks", .protocol = protocol });
            defer client.deinit();
            var reader = try io.concurrent(drainClient, .{&client});
            defer {
                client.shutdownRecv();
                reader.cancel(io);
            }
            for (0..4) |index| {
                const qos = smith.valueRangeAtMostWithHash(u2, 0, 2, @intCast(index + 1));
                try client.publishAwait("topic", "payload", qos, false, .fromSeconds(1));
            }
            try client.unsubscribe("topic");
            try broker.unsubscribed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        }
    }.run, .{});
}

/// Minimal MQTT broker for tests: accepts one connection, completes the
/// CONNECT/CONNACK handshake, then services SUBSCRIBE (SUBACK), counts
/// SUBSCRIBE, PUBLISH and PINGREQ packets and records the last PUBLISH and
/// SUBSCRIBE it receives. Can inject a PUBLISH to the client.
pub const TestBroker = struct {
    alloc: std.mem.Allocator = std.heap.smp_allocator,
    io: Io,
    server: net.Server,
    stream: ?net.Stream = null,
    protocol: std.atomic.Value(proto.Protocol) = .init(.v311),
    write_mutex: Io.Mutex = .init,
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
    last_unsubscribe: [128]u8 = undefined,
    last_unsubscribe_len: usize = 0,
    publishes: std.atomic.Value(u32) = .init(0),
    subscribes: std.atomic.Value(u32) = .init(0),
    unsubscribes: std.atomic.Value(u32) = .init(0),
    pings: std.atomic.Value(u32) = .init(0),
    reply_pings: bool = true,
    reply_publishes: bool = true,

    pub fn bind(io: Io) !TestBroker {
        var ip = try net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try ip.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server };
    }

    pub fn port(self: *const TestBroker) u16 {
        return self.server.socket.address.getPort();
    }

    fn writeAll(self: *TestBroker, stream: net.Stream, bytes: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
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
        if (c.body.len < 10) return;
        const protocol: proto.Protocol = if (std.mem.startsWith(u8, c.body, &.{ 0, 6, 'M', 'Q', 'I', 's', 'd', 'p', 3 })) .v31 else switch (c.body[6]) {
            4 => .v311,
            5 => .v5,
            else => return,
        };
        self.protocol.store(protocol, .release);
        self.writeAll(stream, if (protocol == .v5) &.{ 0x20, 3, 0, 0, 0 } else &.{ 0x20, 2, 0, 0 }) catch return;

        var handled: usize = 0;
        while (handled < nframes) : (handled += 1) {
            const pkt = proto.readPacket(&r.interface, self.alloc, &self.body, max_packet_len) catch return;
            switch (pkt.ptype) {
                .subscribe => {
                    const pid = pkt.packetId() catch return;
                    const offset: usize = if (protocol == .v5) 5 else 4;
                    if (pkt.body.len > offset) copy(&self.last_subscribe, &self.last_subscribe_len, pkt.body[offset .. pkt.body.len - 1]);
                    _ = self.subscribes.fetchAdd(1, .release);
                    // SUBACK: packet id + granted qos 0.
                    if (protocol == .v5)
                        self.writeAll(stream, &.{ 0x90, 4, @intCast(pid >> 8), @truncate(pid), 0, 0 }) catch return
                    else
                        self.writeAll(stream, &.{ 0x90, 3, @intCast(pid >> 8), @truncate(pid), 0 }) catch return;
                },
                .unsubscribe => {
                    const id = pkt.packetId() catch return;
                    const offset: usize = if (protocol == .v5) 5 else 4;
                    if (pkt.body.len >= offset) copy(&self.last_unsubscribe, &self.last_unsubscribe_len, pkt.body[offset..]);
                    _ = self.unsubscribes.fetchAdd(1, .release);
                    if (protocol == .v5)
                        self.writeAll(stream, &.{ 0xb0, 4, @intCast(id >> 8), @truncate(id), 0, 0 }) catch return
                    else
                        self.writeAll(stream, &proto.ack(.unsuback, id)) catch return;
                },
                .publish => {
                    const v = proto.parsePublish(protocol, pkt) catch continue;
                    copy(&self.got_topic, &self.got_topic_len, v.topic);
                    copy(&self.got_payload, &self.got_payload_len, v.payload);
                    self.got_retain = v.retain;
                    _ = self.publishes.fetchAdd(1, .release);
                    if (self.reply_publishes and v.qos != 0) self.writeAll(stream, &proto.ack(if (v.qos == 1) .puback else .pubrec, v.packet_id)) catch return;
                },
                .pubrel => if (self.reply_publishes) self.writeAll(stream, &proto.ack(.pubcomp, pkt.packetId() catch return)) catch return,
                .pingreq => {
                    _ = self.pings.fetchAdd(1, .release);
                    if (self.reply_pings) self.writeAll(stream, &.{ 0xD0, 0x00 }) catch return;
                },
                else => {},
            }
        }
    }

    pub fn injectPublish(self: *TestBroker, topic: []const u8, payload: []const u8) !void {
        const pkt = try proto.encodePublish(self.alloc, self.protocol.load(.acquire), topic, payload, 0, false, 0);
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

test "shared broker fixture negotiates every protocol and records unsubscribe filters" {
    const io = testing.io;
    inline for (std.meta.tags(proto.Protocol)) |protocol| {
        var broker = try TestBroker.bind(io);
        defer broker.deinit();
        const Run = struct {
            fn run(b: *TestBroker, done: *Io.Event) void {
                b.run(5); // SUBSCRIBE, two PUBLISHes, PUBREL and UNSUBSCRIBE.
                done.set(b.io);
            }
        };
        var done: Io.Event = .unset;
        var peer = try io.concurrent(Run.run, .{ &broker, &done });
        defer peer.cancel(io);
        var client = try MqttClient.connect(std.heap.smp_allocator, io, "127.0.0.1", broker.port(), .{ .client_id = "sharedfixture", .protocol = protocol });
        defer client.deinit();
        var reader = try io.concurrent(drainClient, .{&client});
        defer {
            client.shutdownRecv();
            reader.cancel(io);
        }
        try client.subscribe("topic", 1);
        try client.publishAwait("topic", "payload", 1, false, .fromSeconds(1));
        try client.publishAwait("topic", "payload", 2, false, .fromSeconds(1));
        try client.unsubscribe("topic");
        try done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        peer.await(io);
        try testing.expectEqual(protocol, broker.protocol.load(.acquire));
        try testing.expectEqual(@as(u32, 2), broker.publishes.load(.acquire));
        try testing.expectEqual(@as(u32, 1), broker.unsubscribes.load(.acquire));
        try testing.expectEqualStrings("topic", broker.last_subscribe[0..broker.last_subscribe_len]);
        try testing.expectEqualStrings("topic", broker.last_unsubscribe[0..broker.last_unsubscribe_len]);
    }
}

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
        fn run(s: *net.Server, aio: Io, replies: *[12]u8) !void {
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var rbuf: [512]u8 = undefined;
            var reader = stream.reader(aio, &rbuf);
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(std.heap.smp_allocator);
            _ = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
            var wbuf: [512]u8 = undefined;
            var writer = stream.writer(aio, &wbuf);
            // CONNACK, inbound QoS 2 PUBLISH id 7, then PUBREL id 7.
            try writer.interface.writeAll(&.{ 0x20, 2, 0, 0, 0x34, 6, 0, 1, 't', 0, 7, 'v' });
            try writer.interface.writeAll(&proto.ack(.pubrel, 7));
            try writer.interface.flush();
            // PUBREC 7, PUBCOMP 7, PINGREQ, DISCONNECT.
            try reader.interface.readSliceAll(replies);
        }
    };
    var replies: [12]u8 = undefined;
    var future = try io.concurrent(Broker.run, .{ &server, io, &replies });
    defer future.cancel(io) catch {};
    var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "qos2" });
    defer client.deinit();
    var captured: Captured = .{};
    client.on_publish = Captured.cb;
    client.on_publish_ctx = &captured;
    try testing.expectEqual(proto.PacketType.publish, try client.readOne());
    try testing.expectEqual(proto.PacketType.pubrel, try client.readOne());
    try client.ping();
    client.disconnect();
    try future.await(io);
    try testing.expectEqualStrings("v", captured.payload[0..captured.payload_len]);
    const expected = proto.ack(.pubrec, 7) ++ proto.ack(.pubcomp, 7) ++ proto.pingreq ++ proto.disconnect;
    try testing.expectEqualSlices(u8, &expected, &replies);
}

test "fuzz readOne: arbitrary broker bytes after CONNACK never crash the client" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const io = testing.io;
            var bytes: [48]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const protocol: proto.Protocol = @fromBackingInt(@intCast(bytes[0] % 3));
            var server = try (try net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
            defer server.deinit(io);
            const Broker = struct {
                fn serve(s: *net.Server, aio: Io, data: []const u8, version: proto.Protocol) !void {
                    const stream = try s.accept(aio);
                    defer stream.close(aio);
                    var rbuf: [512]u8 = undefined;
                    var reader = stream.reader(aio, &rbuf);
                    var body: std.ArrayList(u8) = .empty;
                    defer body.deinit(std.heap.smp_allocator);
                    _ = try proto.readPacket(&reader.interface, std.heap.smp_allocator, &body, max_packet_len);
                    var wbuf: [128]u8 = undefined;
                    var writer = stream.writer(aio, &wbuf);
                    try writer.interface.writeAll(if (version == .v5) &.{ 0x20, 3, 0, 0, 0 } else &.{ 0x20, 2, 0, 0 });
                    try writer.interface.writeAll(data);
                    try writer.interface.flush();
                    // End the stream so the client's last readOne fails, then
                    // drain its acknowledgements until it closes.
                    try stream.shutdown(aio, .send);
                    while (true) _ = reader.interface.takeByte() catch break;
                }
            };
            var future = try io.concurrent(Broker.serve, .{ &server, io, @as([]const u8, &bytes), protocol });
            defer future.cancel(io) catch {};
            var client = try MqttClient.connect(testing.allocator, io, "127.0.0.1", server.socket.address.getPort(), .{ .client_id = "fuzz", .protocol = protocol });
            defer client.deinit();
            // The fixed input ends, so the stream closes and readOne errors.
            while (true) _ = client.readOne() catch break;
        }
    }.run, .{});
}

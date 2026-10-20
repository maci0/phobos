//! Owned, heap-stable standard TLS client state. The caller owns the stream.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;

/// TLS transport options for `connectTls`. When `insecure` is set, the server
/// certificate is accepted as a self-signed cert with no host verification
/// (for self-signed brokers / tests). Otherwise the cert is verified for `host`
/// against `ca_path` (a PEM bundle) when given, or the system CA bundle.
pub const Options = struct {
    host: []const u8,
    insecure: bool = false,
    ca_path: ?[]const u8 = null,
};

/// Heap-stable TLS transport state. The std `tls.Client` recovers itself from
/// `&client.reader`/`&client.writer` via @fieldParentPtr, and holds pointers to
/// `net_reader`/`net_writer`, so this whole struct must never move after init.
pub const State = struct {
    nrbuf: []u8, // ciphertext transport read buffer (>= tls min_buffer_len)
    nwbuf: []u8, // ciphertext transport write buffer
    rbuf: []u8, // decrypted read buffer
    wbuf: []u8, // decrypted write buffer
    net_reader: net.Stream.Reader,
    net_writer: net.Stream.Writer,
    client: tls.Client = undefined,
};

pub fn connect(gpa: std.mem.Allocator, io: Io, stream: net.Stream, to: Options) !*State {
    const t = try gpa.create(State);
    errdefer gpa.destroy(t);
    const min = tls.Client.min_buffer_len;
    const nrbuf = try gpa.alloc(u8, min + 256);
    errdefer gpa.free(nrbuf);
    const nwbuf = try gpa.alloc(u8, min + 256);
    errdefer gpa.free(nwbuf);
    const rbuf = try gpa.alloc(u8, 16384);
    errdefer gpa.free(rbuf);
    const wbuf = try gpa.alloc(u8, 16384);
    errdefer gpa.free(wbuf);
    t.* = .{
        .nrbuf = nrbuf,
        .nwbuf = nwbuf,
        .rbuf = rbuf,
        .wbuf = wbuf,
        .net_reader = undefined,
        .net_writer = undefined,
    };
    t.net_reader = stream.reader(io, t.nrbuf);
    t.net_writer = stream.writer(io, t.nwbuf);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    try io.randomSecure(&entropy);
    const now = Io.Timestamp.now(io, .real);

    var options: tls.Client.Options = .{
        .host = if (to.insecure) .no_verification else .{ .explicit = to.host },
        .ca = .self_signed, // overridden below when verifying
        .write_buffer = t.wbuf,
        .read_buffer = t.rbuf,
        .entropy = &entropy,
        .realtime_now = now,
    };
    // `tls.Client.init` reads the CA bundle only during the handshake, so the
    // parsed system bundle is freed on return rather than held per connection.
    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    var lock: Io.RwLock = .init;
    if (!to.insecure) {
        if (to.ca_path) |p|
            try bundle.addCertsFromFilePath(gpa, io, now, .cwd(), p)
        else
            try bundle.rescan(gpa, io, now);
        options.ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } };
    }
    t.client = try tls.Client.init(&t.net_reader.interface, &t.net_writer.interface, options);
    return t;
}

pub fn deinit(gpa: std.mem.Allocator, t: *State) void {
    gpa.free(t.nrbuf);
    gpa.free(t.nwbuf);
    gpa.free(t.rbuf);
    gpa.free(t.wbuf);
    gpa.destroy(t);
}

pub fn flush(state: *State) !void {
    try state.client.writer.flush();
    try state.net_writer.interface.flush();
}

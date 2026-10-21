//! Streaming usb.ids lookup and an explicitly started, cancelable cache update.
//! Names are Latin-1 in usb.ids and owned UTF-8 in lookup results. Lookups hold
//! no table in memory; atomic file replacement keeps concurrent readers stable.
const std = @import("std");
const DataStore = @import("../store/datastore.zig").DataStore;
const http_get = @import("http_get.zig");
const Io = std.Io;
const Dir = Io.Dir;
const max_file_bytes = 8 * 1024 * 1024;
const max_line_bytes = 8192;
const max_header_bytes = 1024;
pub const default_url = "http://www.linux-usb.org/usb.ids";
const update_timeout: Io.Duration = .fromSeconds(20);

pub const Ids = struct { vendor: u16, product: u16, class: u8, subclass: u8, protocol: u8 };

/// Every non-null string belongs to the caller's allocator.
pub const Names = struct {
    manufacturer: ?[]const u8 = null,
    product: ?[]const u8 = null,
    description: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
    subclass: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    version: ?[]const u8 = null,

    pub fn deinit(self: *Names, alloc: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(Names)) |field| if (@field(self, field)) |text| alloc.free(text);
        self.* = .{};
    }
};

const Scan = struct { names: Names = .{}, digest: [32]u8 = undefined, records: usize = 0 };
const Group = union(enum) { none, vendor: u16, class: u8, other };

fn replace(alloc: std.mem.Allocator, destination: *std.ArrayList(u8), bytes: []const u8) !void {
    destination.clearRetainingCapacity();
    try destination.ensureTotalCapacity(alloc, bytes.len * 2);
    for (bytes) |byte| {
        if (byte == 0 or (byte < 32 and byte != '\t')) return error.InvalidUsbIds;
        var utf8: [2]u8 = undefined;
        const size = std.unicode.utf8Encode(byte, &utf8) catch unreachable;
        try destination.appendSlice(alloc, utf8[0..size]);
    }
}

fn hex(comptime T: type, token: []const u8) !T {
    if (token.len != @bitSizeOf(T) / 4) return error.InvalidUsbIds;
    for (token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidUsbIds;
    return std.fmt.parseInt(T, token, 16) catch error.InvalidUsbIds;
}

fn scan(reader: *Io.Reader, alloc: std.mem.Allocator, query: ?Ids) !Scan {
    var result: Scan = .{};
    errdefer result.names.deinit(alloc);
    const NameField = std.meta.FieldEnum(Names);
    var selected: std.EnumArray(NameField, std.ArrayList(u8)) = .initFill(.empty);
    defer for (&selected.values) |*buffer| buffer.deinit(alloc);
    var group: Group = .none;
    var sub: ?u16 = null;
    var total: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (try reader.takeDelimiter('\n')) |raw| {
        total += raw.len + 1;
        if (total > max_file_bytes + 1) return error.UsbIdsTooLarge;
        hash.update(raw);
        hash.update("\n");
        const content = std.mem.trim(u8, raw, " \t\r");
        if (content.len == 0) continue;
        for (content) |byte| if (byte < 32 and byte != '\t') return error.InvalidUsbIds;
        if (content[0] == '#') {
            if (std.mem.startsWith(u8, content, "# Version:")) {
                const version = std.mem.trim(u8, content[10..], " \t");
                if (version.len == 0) return error.InvalidUsbIds;
                try replace(alloc, selected.getPtr(.version), version);
            }
            continue;
        }
        const indent = std.mem.findNone(u8, raw, "\t") orelse raw.len;
        var tokens = std.mem.tokenizeAny(u8, content, " \t");
        const token = tokens.next() orelse continue;
        var description = std.mem.trim(u8, tokens.rest(), " \t");
        if (indent == 0) {
            sub = null;
            const vendor: ?u16 = hex(u16, token) catch null;
            if (vendor) |id| {
                group = .{ .vendor = id };
                result.records += 1;
                if (description.len == 0) return error.InvalidUsbIds;
                if (query) |ids| if (group.vendor == ids.vendor) try replace(alloc, selected.getPtr(.manufacturer), description);
            } else if (std.mem.eql(u8, token, "C")) {
                const class_id = tokens.next() orelse return error.InvalidUsbIds;
                group = .{ .class = try hex(u8, class_id) };
                description = std.mem.trim(u8, tokens.rest(), " \t");
                if (description.len == 0) return error.InvalidUsbIds;
                result.records += 1;
                if (query) |ids| if (group.class == ids.class) try replace(alloc, selected.getPtr(.class_name), description);
            } else {
                const other_id = tokens.next() orelse return error.InvalidUsbIds;
                _ = std.fmt.parseInt(u32, other_id, 16) catch return error.InvalidUsbIds;
                if (std.mem.trim(u8, tokens.rest(), " \t").len == 0) return error.InvalidUsbIds;
                group = .other;
            }
        } else switch (group) {
            .none, .other => {},
            .vendor => |vendor| {
                if (indent > 2) return error.InvalidUsbIds;
                const product = try hex(u16, token);
                if (description.len == 0) return error.InvalidUsbIds;
                if (indent == 1) {
                    sub = product;
                    if (query) |ids| if (vendor == ids.vendor and product == ids.product) try replace(alloc, selected.getPtr(.product), description);
                }
            },
            .class => |class_id| {
                if (indent > 2) return error.InvalidUsbIds;
                const value = try hex(u8, token);
                if (description.len == 0) return error.InvalidUsbIds;
                if (indent == 1) {
                    sub = value;
                    if (query) |ids| if (class_id == ids.class and value == ids.subclass) try replace(alloc, selected.getPtr(.subclass), description);
                } else if (sub) |subclass| {
                    if (query) |ids| if (class_id == ids.class and subclass == ids.subclass and value == ids.protocol) try replace(alloc, selected.getPtr(.protocol), description);
                }
            },
        }
    }
    if (result.records == 0) return error.InvalidUsbIds;
    inline for (comptime std.meta.fieldNames(Names)) |field| {
        const buffer = selected.getPtr(@field(NameField, field));
        if (buffer.items.len != 0) @field(result.names, field) = try buffer.toOwnedSlice(alloc);
    }
    hash.final(&result.digest);
    return result;
}

fn scanFile(io: Io, file: Io.File, alloc: std.mem.Allocator, query: ?Ids) !Scan {
    if ((try file.stat(io)).size > max_file_bytes) return error.UsbIdsTooLarge;
    var buffer: [max_line_bytes]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return scan(&reader.interface, alloc, query);
}

/// Missing files use Moonraker's built-in 1d50 entries. Other I/O or parse errors propagate.
pub fn lookup(io: Io, alloc: std.mem.Allocator, path: ?[]const u8, ids: Ids) !Names {
    var names: Names = .{};
    errdefer names.deinit(alloc);
    if (path) |p| {
        const file = Dir.cwd().openFile(io, p, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (file) |input| {
            defer input.close(io);
            names = (try scanFile(io, input, alloc, ids)).names;
        }
    }
    if (names.manufacturer == null and ids.vendor == 0x1d50) names.manufacturer = try alloc.dupe(u8, "OpenMoko, Inc");
    if (names.product == null and ids.vendor == 0x1d50) {
        const builtin_name: ?[]const u8 = switch (ids.product) {
            0x614e => "Klipper 3d-Printer Firmware",
            0x6177 => "Katapult Bootloader (CDC_ACM)",
            else => null,
        };
        if (builtin_name) |name| names.product = try alloc.dupe(u8, name);
    }
    if (names.manufacturer) |vendor| names.description = if (names.product) |product|
        try std.fmt.allocPrint(alloc, "{s} {s}", .{ vendor, product })
    else
        try alloc.dupe(u8, vendor);
    if (ids.class == 0 or names.class_name == null) {
        inline for (.{ "class_name", "subclass", "protocol" }) |field| {
            if (@field(names, field)) |text| alloc.free(text);
            @field(names, field) = null;
        }
    } else {
        inline for (.{ "subclass", "protocol" }) |field| {
            if (@field(names, field)) |text| {
                inline for (.{ "?", "none", "undefined", "reserved/undefined", "unused", "no subclass" }) |null_name| {
                    if (std.ascii.eqlIgnoreCase(text, null_name)) {
                        alloc.free(text);
                        @field(names, field) = null;
                        break;
                    }
                }
            }
        }
    }
    return names;
}

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []u8,
    store: DataStore,
    /// Borrowed until stop joins; tests use a loopback URL.
    url: []const u8 = default_url,
    timeout: Io.Duration = update_timeout,
    worker: ?Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    done: Io.Event = .unset,
    update_mutex: Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: Io, data_path: []const u8, store: DataStore) !Ctx {
        return .{ .gpa = gpa, .io = io, .path = try std.fs.path.join(gpa, &.{ data_path, "misc", "usb.ids" }), .store = store };
    }

    pub fn deinit(self: *Ctx) void {
        self.stop();
        self.gpa.free(self.path);
    }

    pub fn stop(self: *Ctx) void {
        self.stopping.store(true, .release);
        self.done.set(self.io);
        if (self.worker) |*worker| {
            worker.cancel(self.io);
            self.worker = null;
        }
    }

    /// Daemon entry point only. App setup and HTTP test servers never start downloads.
    pub fn start(self: *Ctx, force: bool) !void {
        if (self.worker != null) return;
        if (@import("builtin").is_test) {
            if (self.gpa.vtable == std.testing.allocator.vtable) return error.TestingAllocatorThread;
        }
        self.stopping.store(false, .release);
        self.done.reset();
        self.worker = try self.io.concurrent(run, .{ self, force });
    }

    fn run(self: *Ctx, force: bool) void {
        var download = self.io.concurrent(downloadTask, .{ self, force }) catch |err| {
            std.log.warn("usb.ids update could not start: {s}", .{@errorName(err)});
            return;
        };
        // The wait or await handles the result; deferred cancellation joins on interruption.
        defer download.cancel(self.io) catch {};
        const deadline = Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = self.timeout, .clock = .awake });
        while (!self.done.isSet()) {
            self.done.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Canceled => return,
                error.Timeout => {
                    if (self.stopping.load(.acquire)) return;
                    if (!deadline.compare(.lte, .now(self.io, .awake))) continue;
                    std.log.warn("usb.ids update failed: Timeout", .{});
                    return;
                },
            };
        }
        if (self.stopping.load(.acquire)) return;
        download.await(self.io) catch |err| {
            if (err != error.Canceled) std.log.warn("usb.ids update failed: {s}", .{@errorName(err)});
        };
    }

    fn downloadTask(self: *Ctx, force: bool) !void {
        defer self.done.set(self.io);
        try self.update(force);
    }

    /// Synchronous update off Core. Callers outside the daemon own the deadline.
    /// Cache files replace atomically after validation; a digest binds conditional headers
    /// to the matching file if a datastore failure separates file and metadata commits.
    pub fn update(self: *Ctx, force: bool) !void {
        try self.update_mutex.lock(self.io);
        defer self.update_mutex.unlock(self.io);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        var old_digest: ?[32]u8 = null;
        const old = Dir.cwd().openFile(self.io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (old) |file| {
            defer file.close(self.io);
            if (!force) return;
            if (scanFile(self.io, file, alloc, null)) |parsed| {
                old_digest = parsed.digest;
            } else |err| switch (err) {
                // A forced update repairs invalid caches without conditional headers.
                error.InvalidUsbIds, error.StreamTooLong, error.UsbIdsTooLarge => {},
                else => return err,
            }
        }
        const metadata: std.json.Value = (try self.store.getItem(alloc, "moonraker", "usb_id_req_info")) orelse .{ .object = .empty };
        if (metadata != .object) return error.InvalidCacheMetadata;
        const expected_digest = if (old_digest) |digest| std.fmt.bytesToHex(digest, .lower) else @as([64]u8, @splat(0));
        const stored_digest = metadata.object.get("sha256");
        const conditional = old_digest != null and stored_digest != null and stored_digest.? == .string and std.mem.eql(u8, &expected_digest, stored_digest.?.string);
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(alloc, .{ .name = "Accept", .value = "text/plain" });
        if (conditional) {
            inline for (.{ .{ "etag", "If-None-Match" }, .{ "last_modified", "If-Modified-Since" } }) |field| {
                if (metadata.object.get(field[0])) |value| {
                    if (value != .string or value.string.len > max_header_bytes or !std.unicode.utf8ValidateSlice(value.string) or std.mem.findAny(u8, value.string, "\r\n\x00") != null) return error.InvalidCacheMetadata;
                    try headers.append(alloc, .{ .name = field[1], .value = value.string });
                }
            }
        }
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        var request = try client.request(.GET, try std.Uri.parse(self.url), .{ .headers = http_get.identity_headers, .extra_headers = headers.items, .keep_alive = false });
        defer request.deinit();
        request.accept_encoding = http_get.identity_only;
        try request.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.status == .not_modified) {
            if (!conditional) return error.InvalidNotModified;
            return;
        }
        if (response.head.status != .ok) return error.HttpStatus;
        var new_metadata: std.json.ObjectMap = .empty;
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            inline for (.{ .{ "etag", "etag" }, .{ "last-modified", "last_modified" } }) |field| {
                if (std.ascii.eqlIgnoreCase(header.name, field[0])) {
                    if (header.value.len > max_header_bytes or !std.unicode.utf8ValidateSlice(header.value)) return error.InvalidCacheMetadata;
                    try new_metadata.put(alloc, field[1], .{ .string = try alloc.dupe(u8, header.value) });
                }
            }
        }
        var directory = try Dir.cwd().createDirPathOpen(self.io, std.fs.path.dirname(self.path).?, .{});
        defer directory.close(self.io);
        var pending = try directory.createFileAtomic(self.io, std.fs.path.basename(self.path), .{ .replace = true });
        defer pending.deinit(self.io);
        var write_buffer: [8192]u8 = undefined;
        var writer = pending.file.writer(self.io, &write_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        var bounded = response.reader(&transfer_buffer).limited(.limited(max_file_bytes + 1), &.{});
        const count = bounded.interface.streamRemaining(&writer.interface) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => return err,
        };
        if (count > max_file_bytes) return error.UsbIdsTooLarge;
        if (response.head.content_length) |length| if (length != count) return error.HttpBodyTruncated;
        try writer.interface.flush();
        const temporary_name = std.fmt.hex(pending.file_basename_hex);
        const input = try pending.dir.openFile(self.io, &temporary_name, .{});
        defer input.close(self.io);
        const validated = try scanFile(self.io, input, alloc, null);
        const digest = std.fmt.bytesToHex(validated.digest, .lower);
        try new_metadata.put(alloc, "sha256", .{ .string = &digest });
        try pending.file.sync(self.io);
        try pending.replace(self.io);
        try self.store.insertItem(alloc, "moonraker", "usb_id_req_info", .{ .object = new_metadata });
    }
};

const sample =
    \\# Version: 2026.10.20
    \\1234  Sample Vendor
    \\\t5678  Example Device
    \\\t\t0001  Interface
    \\1d50  OpenMoko database name
    \\\t614e  Database Firmware
    \\C 03  Human Interface Device
    \\\t01  Boot Interface Subclass
    \\\t\t02  Mouse
    \\C 02  Communications
    \\\t00  None
    \\\t\t00  Reserved/Undefined
    \\C 00  Defined at Interface level
;

fn sampleText(alloc: std.mem.Allocator) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, sample, "\\t", "\t");
}

test "usb ids lookup resolves vendors products classes protocols and version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = try sampleText(alloc);
    defer alloc.free(text);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "usb.ids", .data = text });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "usb.ids", alloc);
    defer alloc.free(path);
    var names = try lookup(std.testing.io, alloc, path, .{ .vendor = 0x1234, .product = 0x5678, .class = 3, .subclass = 1, .protocol = 2 });
    defer names.deinit(alloc);
    try std.testing.expectEqualStrings("Sample Vendor", names.manufacturer.?);
    try std.testing.expectEqualStrings("Example Device", names.product.?);
    try std.testing.expectEqualStrings("Sample Vendor Example Device", names.description.?);
    try std.testing.expectEqualStrings("Human Interface Device", names.class_name.?);
    try std.testing.expectEqualStrings("Boot Interface Subclass", names.subclass.?);
    try std.testing.expectEqualStrings("Mouse", names.protocol.?);
    try std.testing.expectEqualStrings("2026.10.20", names.version.?);
    var null_descriptions = try lookup(std.testing.io, alloc, path, .{ .vendor = 0x1d50, .product = 0x614e, .class = 2, .subclass = 0, .protocol = 0 });
    defer null_descriptions.deinit(alloc);
    try std.testing.expectEqualStrings("OpenMoko database name", null_descriptions.manufacturer.?);
    try std.testing.expectEqualStrings("Database Firmware", null_descriptions.product.?);
    try std.testing.expectEqualStrings("Communications", null_descriptions.class_name.?);
    try std.testing.expect(null_descriptions.subclass == null);
    try std.testing.expect(null_descriptions.protocol == null);
    var interface = try lookup(std.testing.io, alloc, path, .{ .vendor = 0x1234, .product = 0xffff, .class = 0, .subclass = 0, .protocol = 0 });
    defer interface.deinit(alloc);
    try std.testing.expectEqualStrings("Sample Vendor", interface.description.?);
    try std.testing.expect(interface.product == null);
    try std.testing.expect(interface.class_name == null);
}

test "usb ids missing cache retains built-in names and unknown IDs remain null" {
    const alloc = std.testing.allocator;
    var klipper = try lookup(std.testing.io, alloc, null, .{ .vendor = 0x1d50, .product = 0x614e, .class = 0, .subclass = 0, .protocol = 0 });
    defer klipper.deinit(alloc);
    try std.testing.expectEqualStrings("OpenMoko, Inc Klipper 3d-Printer Firmware", klipper.description.?);
    var katapult = try lookup(std.testing.io, alloc, null, .{ .vendor = 0x1d50, .product = 0x6177, .class = 0, .subclass = 0, .protocol = 0 });
    defer katapult.deinit(alloc);
    try std.testing.expectEqualStrings("Katapult Bootloader (CDC_ACM)", katapult.product.?);
    var unknown = try lookup(std.testing.io, alloc, null, .{ .vendor = 0xabcd, .product = 1, .class = 0, .subclass = 0, .protocol = 0 });
    defer unknown.deinit(alloc);
    inline for (comptime std.meta.fieldNames(Names)) |field| try std.testing.expect(@field(unknown, field) == null);
}

test "usb ids parser converts Latin-1 and handles duplicates and unrelated sections" {
    const alloc = std.testing.allocator;
    var reader: Io.Reader = .fixed("1234  Caf\xe9\n\t5678  first\n\t5678  final\nAT 0001 Audio\n\t01  Other\nC 03 HID\n\t01  Sub\n\t\t02  Mouse\n");
    var parsed = try scan(&reader, alloc, .{ .vendor = 0x1234, .product = 0x5678, .class = 3, .subclass = 1, .protocol = 2 });
    defer parsed.names.deinit(alloc);
    try std.testing.expectEqualStrings("Caf\xc3\xa9", parsed.names.manufacturer.?);
    try std.testing.expectEqualStrings("final", parsed.names.product.?);
    try std.testing.expectEqualStrings("Mouse", parsed.names.protocol.?);
}

test "usb ids lookup accepts physical descriptor bias records in the printer cache" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "usb.ids", .data = "# Version: 2026.06.10\n1d6b Linux Foundation\n\t0002 2.0 root hub\nC 09 Hub\n\t00 Unused\n\t\t00 Full speed hub\nBIAS 0 Not Applicable\nBIAS 1 Right Hand\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "usb.ids", alloc);
    defer alloc.free(path);
    var names = try lookup(std.testing.io, alloc, path, .{ .vendor = 0x1d6b, .product = 2, .class = 9, .subclass = 0, .protocol = 0 });
    defer names.deinit(alloc);
    try std.testing.expectEqualStrings("Linux Foundation 2.0 root hub", names.description.?);
    try std.testing.expectEqualStrings("Hub", names.class_name.?);
    try std.testing.expect(names.subclass == null);
    try std.testing.expectEqualStrings("Full speed hub", names.protocol.?);
    try std.testing.expectEqualStrings("2026.06.10", names.version.?);
}

test "usb ids malformed entries fail without leaking partial names" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "",                      "# comment\n",               "1234 Vendor\n\tzzzz Bad\n",      "1234 Vendor\n\t5678\n",
        "C 03 HID\n\tgg Nope\n", "# Version:\n1234 Vendor\n", "1234 Vendor\n\t5678 Nul\x00x\n", "C 03 HID\n\t\t\t01 Bad\n",
    }) |text| {
        var reader: Io.Reader = .fixed(text);
        try std.testing.expectError(error.InvalidUsbIds, scan(&reader, alloc, .{ .vendor = 0x1234, .product = 0x5678, .class = 3, .subclass = 1, .protocol = 2 }));
    }
}

test "usb ids parser releases all partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const text = try sampleText(alloc);
            defer alloc.free(text);
            var reader: Io.Reader = .fixed(text);
            var parsed = try scan(&reader, alloc, .{ .vendor = 0x1234, .product = 0x5678, .class = 3, .subclass = 1, .protocol = 2 });
            defer parsed.names.deinit(alloc);
            var fallback = try lookup(std.testing.io, alloc, null, .{ .vendor = 0x1d50, .product = 0x6177, .class = 0, .subclass = 0, .protocol = 0 });
            defer fallback.deinit(alloc);
        }
    }.run, .{});
}

test "fuzz usb ids parser bounds malformed records and produces valid UTF-8" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var bytes: [512]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var reader: Io.Reader = .fixed(&bytes);
            var parsed = scan(&reader, alloc, .{ .vendor = 0x1234, .product = 0x5678, .class = 3, .subclass = 1, .protocol = 2 }) catch |err| switch (err) {
                error.InvalidUsbIds => return,
                else => return err,
            };
            defer parsed.names.deinit(alloc);
            inline for (comptime std.meta.fieldNames(Names)) |field| if (@field(parsed.names, field)) |text| try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        }
    }.run, .{});
}

const LocalHttp = struct {
    io: Io,
    server: Io.net.Server,
    body: []const u8,
    status: u16 = 200,
    declared_length: ?usize = null,
    request: [8192]u8 = undefined,
    request_len: usize = 0,
    entered: Io.Event = .unset,
    done: Io.Event = .unset,
    release: Io.Event = .unset,
    stall: bool = false,
    wait_for_eof: bool = false,
    raw_response: ?[]const u8 = null,

    fn init(aio: Io, body: []const u8) !LocalHttp {
        return .{ .io = aio, .body = body, .server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{}) };
    }
    fn deinit(self: *LocalHttp) void {
        self.server.deinit(self.io);
    }
    fn url(self: *LocalHttp, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/usb.ids", .{self.server.socket.address.getPort()});
    }
    fn serve(self: *LocalHttp) void {
        defer self.done.set(self.io);
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var rbuf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var capture = Io.Writer.fixed(&self.request);
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch return orelse return;
            capture.writeAll(line) catch return;
            capture.writeByte('\n') catch return;
            if (std.mem.trim(u8, line, "\r").len == 0) break;
        }
        self.request_len = capture.buffered().len;
        self.entered.set(self.io);
        if (self.wait_for_eof) {
            _ = reader.interface.takeByte() catch return;
            return;
        }
        if (self.stall) self.release.wait(self.io) catch return;
        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &wbuf);
        if (self.raw_response) |raw| {
            writer.interface.writeAll(raw) catch return;
            writer.interface.flush() catch return;
            return;
        }
        writer.interface.print("HTTP/1.1 {d} Test\r\nContent-Length: {d}\r\nETag: \"revision-1\"\r\nLast-Modified: Tue, 20 Oct 2026 00:00:00 GMT\r\nConnection: close\r\n\r\n", .{ self.status, self.declared_length orelse self.body.len }) catch return;
        writer.interface.writeAll(self.body) catch return;
        writer.interface.flush() catch return;
    }
};

test "usb ids download caches a complete file and revalidates with matching metadata" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
    defer ctx.deinit();
    const text = try sampleText(alloc);
    defer alloc.free(text);
    var peer = try LocalHttp.init(aio, text);
    defer peer.deinit();
    const url = try peer.url(alloc);
    defer alloc.free(url);
    ctx.url = url;
    var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
    defer serving.cancel(aio);
    try ctx.update(false);
    try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    serving.await(aio);
    const cached = try tmp.dir.readFileAlloc(aio, "misc/usb.ids", alloc, .limited(max_file_bytes));
    defer alloc.free(cached);
    try std.testing.expectEqualStrings(text, cached);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const metadata = (try database.getItem(arena.allocator(), "moonraker", "usb_id_req_info")).?.object;
    try std.testing.expectEqualStrings("\"revision-1\"", metadata.get("etag").?.string);
    try std.testing.expectEqual(@as(usize, 64), metadata.get("sha256").?.string.len);
    ctx.url = "http://127.0.0.1:1/unused";
    try ctx.update(false);
    var conditional = try LocalHttp.init(aio, "");
    defer conditional.deinit();
    conditional.status = 304;
    const conditional_url = try conditional.url(alloc);
    defer alloc.free(conditional_url);
    ctx.url = conditional_url;
    var second = try aio.concurrent(LocalHttp.serve, .{&conditional});
    defer second.cancel(aio);
    try ctx.update(true);
    try conditional.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    second.await(aio);
    const request = conditional.request[0..conditional.request_len];
    try std.testing.expect(std.mem.find(u8, request, "If-None-Match: \"revision-1\"") != null);
    try std.testing.expect(std.mem.find(u8, request, "If-Modified-Since: Tue, 20 Oct 2026") != null);
}

test "usb ids failed and truncated downloads preserve the previous cache" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(aio, "misc");
    try tmp.dir.writeFile(aio, .{ .sub_path = "misc/usb.ids", .data = "1234 Previous\n" });
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
    defer ctx.deinit();
    for ([_]u8{ 0, 1, 2, 3, 4 }) |failure| {
        var peer = try LocalHttp.init(aio, if (failure == 0) "<html>failed</html>" else "1234 Replacement\n");
        defer peer.deinit();
        if (failure == 1) peer.status = 500;
        if (failure == 2) peer.declared_length = peer.body.len + 10;
        if (failure == 3) peer.status = 304;
        if (failure == 4) peer.raw_response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nd\r\n1234 Changed\n\r\n";
        const url = try peer.url(alloc);
        defer alloc.free(url);
        ctx.url = url;
        var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
        defer serving.cancel(aio);
        const result = ctx.update(true);
        if (result) |_| return error.ExpectedFailure else |_| {}
        try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        serving.await(aio);
        const cached = try tmp.dir.readFileAlloc(aio, "misc/usb.ids", alloc, .limited(max_file_bytes));
        defer alloc.free(cached);
        try std.testing.expectEqualStrings("1234 Previous\n", cached);
        try std.testing.expect((try database.getItem(alloc, "moonraker", "usb_id_req_info")) == null);
    }
}

test "usb ids forced download repairs a malformed existing cache" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(aio, "misc");
    try tmp.dir.writeFile(aio, .{ .sub_path = "misc/usb.ids", .data = "invalid" });
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
    defer ctx.deinit();
    var peer = try LocalHttp.init(aio, "1234 Repaired\n");
    defer peer.deinit();
    const url = try peer.url(alloc);
    defer alloc.free(url);
    ctx.url = url;
    var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
    defer serving.cancel(aio);
    try ctx.update(true);
    try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    serving.await(aio);
    const cached = try tmp.dir.readFileAlloc(aio, "misc/usb.ids", alloc, .limited(max_file_bytes));
    defer alloc.free(cached);
    try std.testing.expectEqualStrings("1234 Repaired\n", cached);
    try std.testing.expect(std.mem.find(u8, peer.request[0..peer.request_len], "If-None-Match") == null);
}

test "usb ids metadata failure cannot attach stale conditional headers to a changed file" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
    defer ctx.deinit();
    for (0..3) |index| {
        var peer = try LocalHttp.init(aio, if (index == 0) "1234 Initial\n" else "1234 Changed\n");
        defer peer.deinit();
        const url = try peer.url(alloc);
        defer alloc.free(url);
        ctx.url = url;
        var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
        defer serving.cancel(aio);
        var failed_vtable = database.dataStore().vtable.*;
        failed_vtable.insertItem = struct {
            fn fail(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: @import("../store/datastore.zig").Key, _: std.json.Value) @import("../store/datastore.zig").Error!void {
                return error.BackendError;
            }
        }.fail;
        if (index == 1) {
            ctx.store = .{ .ctx = database.dataStore().ctx, .vtable = &failed_vtable };
            try std.testing.expectError(error.BackendError, ctx.update(true));
        } else {
            ctx.store = database.dataStore();
            try ctx.update(index != 0);
        }
        try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        serving.await(aio);
        if (index == 2) try std.testing.expect(std.mem.find(u8, peer.request[0..peer.request_len], "If-None-Match") == null);
    }
}

test "usb ids download enforces body and line limits without replacing the cache" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(aio, "misc");
    try tmp.dir.writeFile(aio, .{ .sub_path = "misc/usb.ids", .data = "1234 Original\n" });
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
    defer ctx.deinit();
    for ([_]usize{ max_file_bytes + 1, max_line_bytes + 1 }) |size| {
        const body = try alloc.alloc(u8, size);
        defer alloc.free(body);
        @memset(body, 'x');
        @memcpy(body[0..6], "1234  ");
        var peer = try LocalHttp.init(aio, body);
        defer peer.deinit();
        const url = try peer.url(alloc);
        defer alloc.free(url);
        ctx.url = url;
        var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
        defer serving.cancel(aio);
        if (size > max_file_bytes) {
            try std.testing.expectError(error.UsbIdsTooLarge, ctx.update(true));
        } else try std.testing.expectError(error.StreamTooLong, ctx.update(true));
        try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        serving.await(aio);
        const cached = try tmp.dir.readFileAlloc(aio, "misc/usb.ids", alloc, .limited(max_file_bytes));
        defer alloc.free(cached);
        try std.testing.expectEqualStrings("1234 Original\n", cached);
    }
}

test "usb ids daemon worker cancels a stalled download and joins before cleanup" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(std.heap.smp_allocator, aio, root, database.dataStore());
    defer ctx.deinit();
    var peer = try LocalHttp.init(aio, "1234 Unused\n");
    defer peer.deinit();
    peer.stall = true;
    const url = try peer.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    ctx.url = url;
    var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
    defer serving.cancel(aio);
    try ctx.start(false);
    try peer.entered.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    const stop_started = Io.Clock.awake.now(aio);
    ctx.stop();
    try std.testing.expect(stop_started.untilNow(aio, .awake).toMilliseconds() < 1000);
    try std.testing.expect(ctx.worker == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(aio, "misc/usb.ids", .{}));
    var forbidden = try Ctx.init(std.testing.allocator, aio, root, database.dataStore());
    defer forbidden.deinit();
    try std.testing.expectError(error.TestingAllocatorThread, forbidden.start(false));
}

test "fuzz usb ids selected records preserve Latin-1 names and identifier hierarchy" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var input_name: [16]u8 = undefined;
            smith.bytesWithHash(&input_name, 0);
            for (&input_name) |*byte| if (byte.* < 33 or byte.* == 127) {
                byte.* = 'a';
            };
            const product = smith.valueWithHash(u16, 1);
            const body = try std.fmt.allocPrint(alloc, "1234  {s}\n\t{x:0>4}  Device\nC 03 HID\n\t01 Boot\n\t\t02 Mouse\nBIAS 1 Right Hand\n", .{ &input_name, product });
            defer alloc.free(body);
            var reader: Io.Reader = .fixed(body);
            var parsed = try scan(&reader, alloc, .{ .vendor = 0x1234, .product = product, .class = 3, .subclass = 1, .protocol = 2 });
            defer parsed.names.deinit(alloc);
            try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.names.manufacturer.?));
            try std.testing.expectEqualStrings("Device", parsed.names.product.?);
            try std.testing.expectEqualStrings("HID", parsed.names.class_name.?);
            try std.testing.expectEqualStrings("Boot", parsed.names.subclass.?);
            try std.testing.expectEqualStrings("Mouse", parsed.names.protocol.?);
        }
    }.run, .{});
}

test "usb ids daemon download deadline cancels the HTTP connection" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(std.heap.smp_allocator, aio, root, database.dataStore());
    defer ctx.deinit();
    var peer = try LocalHttp.init(aio, "");
    defer peer.deinit();
    peer.wait_for_eof = true;
    const url = try peer.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    ctx.url = url;
    ctx.timeout = .fromMilliseconds(50);
    var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
    defer serving.cancel(aio);
    try ctx.start(false);
    try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    ctx.stop();
    serving.await(aio);
    try std.testing.expect(ctx.worker == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(aio, "misc/usb.ids", .{}));
}

test "usb ids repeated matching records reuse bounded selection storage" {
    const alloc = std.testing.allocator;
    var text: Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    for (0..2048) |_| try text.writer.writeAll("1234 Repeated vendor name\n");
    var fixed_storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_storage);
    var reader: Io.Reader = .fixed(text.written());
    var parsed = try scan(&reader, fixed.allocator(), .{ .vendor = 0x1234, .product = 1, .class = 0, .subclass = 0, .protocol = 0 });
    defer parsed.names.deinit(fixed.allocator());
    try std.testing.expectEqualStrings("Repeated vendor name", parsed.names.manufacturer.?);
}

test "usb ids updates release every partial HTTP and atomic-file allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const aio = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
            defer std.testing.allocator.free(root);
            var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
            defer database.deinit();
            var ctx = try Ctx.init(alloc, aio, root, database.dataStore());
            defer ctx.deinit();
            var peer = try LocalHttp.init(aio, "1234 Vendor\n\t5678 Device\nC 03 HID\n");
            defer peer.deinit();
            const url = try peer.url(std.testing.allocator);
            defer std.testing.allocator.free(url);
            ctx.url = url;
            var serving = try aio.concurrent(LocalHttp.serve, .{&peer});
            defer serving.cancel(aio);
            try ctx.update(false);
            try peer.done.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
            serving.await(aio);
        }
    }.run, .{});
}

test "usb ids worker cancellation interrupts a wait for another update" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var database = try @import("../store/sqlite_store.zig").SqliteStore.open(aio, ":memory:");
    defer database.deinit();
    var ctx = try Ctx.init(std.heap.smp_allocator, aio, root, database.dataStore());
    defer ctx.deinit();
    ctx.update_mutex.lockUncancelable(aio);
    defer ctx.update_mutex.unlock(aio);
    // No request can pass the held update mutex.
    try ctx.start(false);
    const started = Io.Clock.awake.now(aio);
    ctx.stop();
    try std.testing.expect(started.untilNow(aio, .awake).toMilliseconds() < 1000);
}

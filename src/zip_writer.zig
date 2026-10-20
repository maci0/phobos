//! Streaming ZIP32 archives using native ZIP headers, CRC32 and DEFLATE.
const std = @import("std");
const Io = std.Io;
const zip = std.zip;
const flate = std.compress.flate;

pub const Archive = struct {
    alloc: std.mem.Allocator,
    output: *Io.File.Writer,
    store_only: bool,
    entries: std.ArrayList(Entry) = .empty,
    names_bytes: usize = 0,
    compressor: ?*flate.Compress = null,
    window: ?[]u8 = null,
    finished: bool = false,

    pub const max_entries = 4096;
    pub const max_names_bytes = 1024 * 1024;
    const Entry = struct { header: zip.CentralDirectoryFileHeader, name: []const u8 };

    /// Names passed to addFile must remain valid until finish or deinit. The
    /// output writer needs more than eight bytes of buffering for DEFLATE.
    pub fn init(alloc: std.mem.Allocator, output: *Io.File.Writer, store_only: bool) Archive {
        return .{ .alloc = alloc, .output = output, .store_only = store_only };
    }

    pub fn deinit(self: *Archive) void {
        self.entries.deinit(self.alloc);
        if (self.compressor) |compressor| self.alloc.destroy(compressor);
        if (self.window) |window| self.alloc.free(window);
    }

    pub fn addFile(self: *Archive, file: Io.File, name: []const u8) !void {
        if (self.finished) return error.InvalidParams;
        try validateName(name);
        if (self.entries.items.len >= max_entries or name.len > max_names_bytes - self.names_bytes) return error.ArchiveTooLarge;
        const st = try file.stat(self.output.io);
        if (st.kind != .file) return error.InvalidParams;
        if (st.size >= std.math.maxInt(u32)) return error.ArchiveTooLarge;
        const offset = try position(self.output);
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(st.mtime.toSeconds(), 315532800, 4354819199)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const date: u16 = (@as(u16, @intCast(yd.year - 1980)) << 9) | (@as(u16, md.month.numeric()) << 5) | (@as(u16, md.day_index) + 1);
        const time: u16 = (@as(u16, ds.getHoursIntoDay()) << 11) | (@as(u16, ds.getMinutesIntoHour()) << 5) | (@as(u16, ds.getSecondsIntoMinute()) / 2);
        const method: zip.CompressionMethod = if (self.store_only) .store else .deflate;
        const header: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0x0808)), // UTF-8 and trailing data descriptor.
            .compression_method = method,
            .last_modification_time = time,
            .last_modification_date = date,
            .crc32 = 0,
            .compressed_size = 0,
            .uncompressed_size = 0,
            .filename_len = @intCast(name.len),
            .extra_len = 0,
        };
        try self.entries.ensureUnusedCapacity(self.alloc, 1);
        const w = &self.output.interface;
        try w.writeStruct(header, .little);
        try w.writeAll(name);
        const data_start = try position(self.output);
        var destination = w;
        if (!self.store_only) {
            if (w.buffer.len <= 8) return error.InvalidParams;
            if (self.compressor == null) self.compressor = try self.alloc.create(flate.Compress);
            if (self.window == null) self.window = try self.alloc.alloc(u8, flate.max_window_len);
            self.compressor.?.* = try flate.Compress.init(w, self.window.?, .raw, .default);
            destination = &self.compressor.?.writer;
        }
        var crc = std.hash.Crc32.init();
        var buf: [64 * 1024]u8 = undefined;
        var read_offset: u64 = 0;
        while (read_offset < st.size) {
            const chunk = buf[0..@min(buf.len, st.size - read_offset)];
            const n = try file.readPositionalAll(self.output.io, chunk, read_offset);
            if (n != chunk.len) return error.EndOfStream;
            crc.update(chunk);
            try destination.writeAll(chunk);
            read_offset += n;
            _ = try position(self.output);
        }
        if (!self.store_only) try self.compressor.?.finish();
        const compressed_size = (try position(self.output)) - data_start;
        const checksum = crc.final();
        try w.writeInt(u32, 0x08074b50, .little);
        try w.writeInt(u32, checksum, .little);
        try w.writeInt(u32, compressed_size, .little);
        try w.writeInt(u32, @intCast(st.size), .little);
        self.entries.appendAssumeCapacity(.{ .name = name, .header = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = (3 << 8) | 20,
            .version_needed_to_extract = 20,
            .flags = header.flags,
            .compression_method = method,
            .last_modification_time = time,
            .last_modification_date = date,
            .crc32 = checksum,
            .compressed_size = compressed_size,
            .uncompressed_size = @intCast(st.size),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = (@as(u32, 0o100000) | (st.permissions.toMode() & 0o777)) << 16,
            .local_file_header_offset = offset,
        } });
        self.names_bytes += name.len;
    }

    pub fn finish(self: *Archive) !void {
        if (self.finished) return error.InvalidParams;
        const start = try position(self.output);
        const w = &self.output.interface;
        for (self.entries.items) |entry| {
            try w.writeStruct(entry.header, .little);
            try w.writeAll(entry.name);
        }
        const size = (try position(self.output)) - start;
        try w.writeStruct(@as(zip.EndRecord, .{
            .signature = zip.end_record_sig,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = @intCast(self.entries.items.len),
            .record_count_total = @intCast(self.entries.items.len),
            .central_directory_size = size,
            .central_directory_offset = start,
            .comment_len = 0,
        }), .little);
        _ = try position(self.output);
        try self.output.flush();
        self.finished = true;
    }
};

fn position(output: *const Io.File.Writer) !u32 {
    const pos = output.logicalPos();
    if (pos >= std.math.maxInt(u32)) return error.ArchiveTooLarge;
    return @intCast(pos);
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > std.math.maxInt(u16) or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfAny(u8, name, "\\\x00:") != null) return error.InvalidParams;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidParams;
    }
}

test "zip writer validates relative portable names" {
    for ([_][]const u8{ "", "/absolute", "../escape", "a/../b", "a/./b", "a//b", "a/", "a\\b", "C:drive", "a\x00b", "\xff" }) |name|
        try std.testing.expectError(error.InvalidParams, validateName(name));
    try validateName("gcodes/folder/print.gcode");
    try validateName("config/é.cfg");
}

test "fuzz zip names remain relative normalized UTF-8" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buf: [1024]u8 = undefined;
            const name = buf[0..smith.slice(&buf)];
            validateName(name) catch return;
            try std.testing.expect(name.len > 0 and name[0] != '/');
            try std.testing.expect(std.unicode.utf8ValidateSlice(name));
            var parts = std.mem.splitScalar(u8, name, '/');
            while (parts.next()) |part| try std.testing.expect(part.len > 0 and !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, ".."));
        }
    }.run, .{});
}

test "zip writer streams stored and compressed files with CRC and Unix modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "G1 X20 Y20 E0.1\n";
    const data = try std.testing.allocator.alloc(u8, line.len * 10000);
    defer std.testing.allocator.free(data);
    for (0..10000) |i| @memcpy(data[i * line.len ..][0..line.len], line);
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = data });
    const source = try tmp.dir.openFile(io, "source", .{});
    defer source.close(io);
    try source.setPermissions(io, .fromMode(0o4755));
    for ([_]bool{ true, false }) |store_only| {
        const file = try tmp.dir.createFile(io, "archive.zip", .{ .read = true });
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var output = file.writer(io, &buf);
        var archive = Archive.init(std.testing.allocator, &output, store_only);
        defer archive.deinit();
        try archive.addFile(source, "config/start.sh");
        try archive.addFile(source, "gcodes/test.gcode");
        try archive.finish();
        try std.testing.expectError(error.InvalidParams, archive.finish());
        try std.testing.expectError(error.InvalidParams, archive.addFile(source, "extra"));
        var read_buf: [1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        var iter = try zip.Iterator.init(&reader);
        var count: usize = 0;
        while (try iter.next()) |entry| {
            try std.testing.expectEqual(if (store_only) zip.CompressionMethod.store else .deflate, entry.compression_method);
            if (store_only) try std.testing.expectEqual(data.len, entry.compressed_size) else try std.testing.expect(entry.compressed_size < data.len / 2);
            var name_buf: [128]u8 = undefined;
            const name = try entry.getFilename(&reader, &name_buf, .{});
            try std.testing.expectEqualStrings(if (count == 0) "config/start.sh" else "gcodes/test.gcode", name);
            var extracted: Io.Writer.Allocating = .init(std.testing.allocator);
            defer extracted.deinit();
            try entry.extractTo(&reader, &extracted.writer);
            try std.testing.expectEqualStrings(data, extracted.written());
            try std.testing.expectEqual(entry.crc32, std.hash.Crc32.hash(extracted.written()));
            try reader.seekTo(entry.header_zip_offset);
            const central = try reader.interface.takeStruct(zip.CentralDirectoryFileHeader, .little);
            try std.testing.expectEqual(@as(u32, 0o100755), central.external_file_attributes >> 16);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }
}

test "zip writer bounds entry counts, names and ZIP32 extents" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "archive.zip", .{ .read = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var output = file.writer(io, &buf);
    var archive = Archive.init(std.testing.allocator, &output, true);
    defer archive.deinit();
    try archive.entries.resize(std.testing.allocator, Archive.max_entries);
    try std.testing.expectError(error.ArchiveTooLarge, archive.addFile(file, "name"));
    archive.entries.clearRetainingCapacity();
    archive.names_bytes = Archive.max_names_bytes;
    try std.testing.expectError(error.ArchiveTooLarge, archive.addFile(file, "name"));
    archive.names_bytes = 0;
    output.pos = std.math.maxInt(u32);
    try std.testing.expectError(error.ArchiveTooLarge, archive.finish());
}

test "fuzz zip writer roundtrips arbitrary stored and deflated contents" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var bytes: [8192]u8 = undefined;
            const data = bytes[0..smith.slice(&bytes)];
            try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = data });
            const source = try tmp.dir.openFile(io, "source", .{});
            defer source.close(io);
            const file = try tmp.dir.createFile(io, "archive.zip", .{ .read = true });
            defer file.close(io);
            var buf: [1024]u8 = undefined;
            var output = file.writer(io, &buf);
            var archive = Archive.init(std.testing.allocator, &output, smith.value(bool));
            defer archive.deinit();
            try archive.addFile(source, "file.bin");
            try archive.finish();
            var read_buf: [1024]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            var iter = try zip.Iterator.init(&reader);
            const entry = (try iter.next()).?;
            var decoded: Io.Writer.Allocating = .init(std.testing.allocator);
            defer decoded.deinit();
            try entry.extractTo(&reader, &decoded.writer);
            try std.testing.expectEqualSlices(u8, data, decoded.written());
            try std.testing.expectEqual(std.hash.Crc32.hash(data), entry.crc32);
            try std.testing.expectEqual(null, try iter.next());
        }
    }.run, .{});
}

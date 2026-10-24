//! Extract one OrcaSlicer plate into an unpublished upload file.
const std = @import("std");
const Io = std.Io;
const max_entries = 4096;
const max_gcode_bytes: u64 = 2 * 1024 * 1024 * 1024;

pub fn isPackaged(filename: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(filename, ".gcode.3mf");
}

fn plateNumber(name: []const u8) ?u32 {
    const suffix = std.mem.cutPrefix(u8, name, "Metadata/plate_") orelse return null;
    const number = std.mem.cutSuffix(u8, suffix, ".gcode") orelse return null;
    if (number.len == 0 or number[0] < '1' or number[0] > '9') return null;
    return std.fmt.parseInt(u32, number, 10) catch null;
}

const Checksums = struct {
    crc: std.hash.Crc32 = .init(),
    md5: std.crypto.hash.Md5 = .init(.{}),

    pub fn update(self: *Checksums, bytes: []const u8) void {
        self.crc.update(bytes);
        self.md5.update(bytes);
    }
};

fn validateEntry(reader: *Io.File.Reader, entry: std.zip.Iterator.Entry, source_size: u64) !void {
    if (entry.file_offset > source_size or entry.compressed_size > source_size - entry.file_offset or entry.uncompressed_size > max_gcode_bytes) return error.ArchiveTooLarge;
    try reader.seekTo(entry.header_zip_offset);
    const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
    const mode = if (header.version_made_by >> 8 == 3) header.external_file_attributes >> 16 else 0;
    if (mode & 0xf000 != 0 and mode & 0xf000 != 0x8000) return error.UnsafeArchiveType;
}

/// Caller owns source/output and publishes output only after this succeeds.
pub fn extract(io: Io, source: Io.File, output: Io.File, plate_index: ?[]const u8) !void {
    const wanted = if (plate_index) |text| if (text.len == 0) null else std.fmt.parseInt(u32, text, 10) catch return error.InvalidPlateIndex else null;
    if (wanted == 0) return error.InvalidPlateIndex;
    const size = (try source.stat(io)).size;
    if (size > max_gcode_bytes) return error.ArchiveTooLarge;
    var input: [32768]u8 = undefined;
    var reader = source.reader(io, &input);
    var iterator = try std.zip.Iterator.init(&reader);
    if (iterator.cd_record_count > max_entries or iterator.cd_zip_offset > size or iterator.cd_size > size - iterator.cd_zip_offset) return error.ArchiveTooLarge;
    var selected: ?std.zip.Iterator.Entry = null;
    var plate: u32 = 0;
    while (try iterator.next()) |entry| {
        var name_buffer: [4096]u8 = undefined;
        const name = try entry.getFilename(&reader, &name_buffer, .{});
        const number = plateNumber(name) orelse continue;
        if (wanted) |index| if (number != index) continue;
        if (selected != null) return if (wanted == null) error.MultiplePlates else error.DuplicatePlate;
        try validateEntry(&reader, entry, size);
        selected = entry;
        plate = number;
    }
    const entry = selected orelse return error.PlateNotFound;
    var sidecar_buffer: [64]u8 = undefined;
    const sidecar = try std.fmt.bufPrint(&sidecar_buffer, "Metadata/plate_{d}.gcode.md5", .{plate});
    iterator = try std.zip.Iterator.init(&reader);
    var expected: ?[16]u8 = null;
    while (try iterator.next()) |candidate| {
        var name_buffer: [4096]u8 = undefined;
        const name = try candidate.getFilename(&reader, &name_buffer, .{});
        if (!std.mem.eql(u8, name, sidecar)) continue;
        if (expected != null or candidate.uncompressed_size > 128) return error.InvalidMd5;
        try validateEntry(&reader, candidate, size);
        var data: [128]u8 = undefined;
        var fixed = Io.Writer.fixed(&data);
        var buffer: [128]u8 = undefined;
        var hashing = fixed.hashed(std.hash.Crc32.init(), &buffer);
        try candidate.extractTo(&reader, &hashing.writer);
        try hashing.writer.flush();
        if (hashing.hasher.final() != candidate.crc32) return error.ZipChecksumMismatch;
        const hex = std.mem.trim(u8, fixed.buffered(), " \r\n\t");
        if (hex.len != 32) return error.InvalidMd5;
        var digest: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidMd5;
        expected = digest;
    }
    var output_buffer: [32768]u8 = undefined;
    var writer = output.writer(io, &output_buffer);
    if (expected) |digest| try writer.interface.print("; MD5:{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
    var hash_buffer: [32768]u8 = undefined;
    var hashing = writer.interface.hashed(Checksums{}, &hash_buffer);
    try entry.extractTo(&reader, &hashing.writer);
    try hashing.writer.flush();
    try writer.end();
    if (hashing.hasher.crc.final() != entry.crc32) return error.ZipChecksumMismatch;
    var digest: [16]u8 = undefined;
    hashing.hasher.md5.final(&digest);
    if (expected) |value| if (!std.mem.eql(u8, &value, &digest)) return error.Md5Mismatch;
    try output.sync(io);
}

const Fixture = struct { name: []const u8, data: []const u8 };

fn archiveFixture(dir: Io.Dir, entries: []const Fixture, compressed: bool) !Io.File {
    const io = std.testing.io;
    const archive = try dir.createFile(io, "bundle.3mf", .{ .read = true });
    errdefer archive.close(io);
    var buffer: [32768]u8 = undefined;
    var writer = archive.writer(io, &buffer);
    var zip = @import("../zip_writer.zig").Archive.init(std.testing.allocator, &writer, !compressed);
    defer zip.deinit();
    for (entries) |fixture| {
        const input = try dir.createFile(io, "input", .{ .read = true });
        defer input.close(io);
        try input.writeStreamingAll(io, fixture.data);
        try zip.addFile(input, fixture.name);
    }
    try zip.finish();
    try writer.end();
    return archive;
}

test "3MF plate selection streams stored and compressed G-code with MD5" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |compressed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const archive = try archiveFixture(tmp.dir, &.{
            .{ .name = "Metadata/plate_1.gcode", .data = "hello" },
            .{ .name = "Metadata/plate_1.gcode.md5", .data = "5d41402abc4b2a76b9719d911017c592\n" },
            .{ .name = "Metadata/plate_2.gcode", .data = "second" },
        }, compressed);
        defer archive.close(io);
        var output = try tmp.dir.createFileAtomic(io, "result.gcode", .{ .replace = true });
        defer output.deinit(io);
        try std.testing.expectError(error.MultiplePlates, extract(io, archive, output.file, null));
        try std.testing.expectError(error.InvalidPlateIndex, extract(io, archive, output.file, "0"));
        try std.testing.expectError(error.PlateNotFound, extract(io, archive, output.file, "3"));
        try extract(io, archive, output.file, "1");
        try output.replace(io);
        const actual = try tmp.dir.readFileAlloc(io, "result.gcode", std.testing.allocator, .limited(256));
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("; MD5:5d41402abc4b2a76b9719d911017c592\nhello", actual);
    }
}

test "3MF invalid MD5 preserves an existing destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "result.gcode", .data = "original" });
    const archive = try archiveFixture(tmp.dir, &.{
        .{ .name = "Metadata/plate_1.gcode", .data = "hello" },
        .{ .name = "Metadata/plate_1.gcode.md5", .data = "00000000000000000000000000000000" },
    }, false);
    defer archive.close(io);
    {
        var output = try tmp.dir.createFileAtomic(io, "result.gcode", .{ .replace = true });
        defer output.deinit(io);
        try std.testing.expectError(error.Md5Mismatch, extract(io, archive, output.file, null));
    }
    const actual = try tmp.dir.readFileAlloc(io, "result.gcode", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("original", actual);
}

test "fuzz packaged filenames and plate names" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var data: [128]u8 = undefined;
            smith.bytesWithHash(&data, 0);
            _ = isPackaged(&data);
            if (plateNumber(&data)) |number| try std.testing.expect(number > 0);
        }
    }.run, .{});
}

test "3MF rejects duplicate plates, damaged CRC and linked entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const duplicates = try archiveFixture(tmp.dir, &.{
            .{ .name = "Metadata/plate_1.gcode", .data = "one" },
            .{ .name = "Metadata/plate_1.gcode", .data = "two" },
        }, false);
        defer duplicates.close(io);
        var output = try tmp.dir.createFileAtomic(io, "result.gcode", .{ .replace = true });
        defer output.deinit(io);
        try std.testing.expectError(error.DuplicatePlate, extract(io, duplicates, output.file, "1"));
    }
    const archive = try archiveFixture(tmp.dir, &.{.{ .name = "Metadata/plate_1.gcode", .data = "hello" }}, false);
    defer archive.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    const entry = (try iterator.next()).?;
    var changed_crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &changed_crc, entry.crc32 ^ 1, .little);
    try archive.writePositionalAll(io, &changed_crc, entry.header_zip_offset + @offsetOf(std.zip.CentralDirectoryFileHeader, "crc32"));
    {
        var output = try tmp.dir.createFileAtomic(io, "result.gcode", .{ .replace = true });
        defer output.deinit(io);
        try std.testing.expectError(error.ZipChecksumMismatch, extract(io, archive, output.file, null));
    }
    var attributes: [4]u8 = undefined;
    std.mem.writeInt(u32, &attributes, @as(u32, 0o120777) << 16, .little);
    try archive.writePositionalAll(io, &attributes, entry.header_zip_offset + @offsetOf(std.zip.CentralDirectoryFileHeader, "external_file_attributes"));
    var output = try tmp.dir.createFileAtomic(io, "result.gcode", .{ .replace = true });
    defer output.deinit(io);
    try std.testing.expectError(error.UnsafeArchiveType, extract(io, archive, output.file, null));
}

//! Bounded release downloads and staged directory installation for web/ZIP sources.
const std = @import("std");
const Source = @import("update_manager.zig").Source;
const http_get = @import("http_get.zig");
const power = @import("power.zig");
const jv = @import("../json/value.zig");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const max_archive = 128 * 1024 * 1024;
const max_expanded = 512 * 1024 * 1024;
const max_entries = 16384;

pub const Installed = struct { version: []const u8, asset_name: []const u8 = "" };
pub const Release = struct { version: []const u8, url: []const u8, size: u64 = 0 };

fn text(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidRelease;
    const field = value.object.get(key) orelse return error.InvalidRelease;
    if (field != .string or field.string.len == 0) return error.InvalidRelease;
    return field.string;
}

fn readText(alloc: Allocator, io: Io, dir: Dir, path: []const u8) ![]const u8 {
    const file = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidRelease;
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(alloc, .limited(64 * 1024));
}

/// Returned strings belong to alloc. The configured repo must match the bundle.
pub fn installed(alloc: Allocator, io: Io, dir: Dir, src: Source) !Installed {
    if (dir.statFile(io, ".git", .{ .follow_symlinks = false })) |_| return error.GitDirectory else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const body = readText(alloc, io, dir, "release_info.json") catch |err| switch (err) {
        error.FileNotFound => {
            if (src.type != .web) return error.InvalidRelease;
            const version = std.mem.trim(u8, try readText(alloc, io, dir, ".version"), " \r\n\t");
            if (version.len == 0 or !std.unicode.utf8ValidateSlice(version)) return error.InvalidRelease;
            const manifest = readText(alloc, io, dir, "manifest.json") catch |e| switch (e) {
                error.FileNotFound => try readText(alloc, io, dir, "manifest.webmanifest"),
                else => return e,
            };
            const data = try std.json.parseFromSliceLeaky(std.json.Value, alloc, manifest, .{ .allocate = .alloc_always });
            if (jv.exceedsDepth(data, jv.max_value_depth)) return error.InvalidRelease;
            const name = try text(data, "name");
            if (!(std.ascii.eqlIgnoreCase(name, "fluidd") and std.ascii.eqlIgnoreCase(src.owner, "fluidd-core") and std.ascii.eqlIgnoreCase(src.repo_name, "fluidd")) and
                !(std.ascii.eqlIgnoreCase(name, "mainsail") and std.ascii.eqlIgnoreCase(src.owner, "mainsail-crew") and std.ascii.eqlIgnoreCase(src.repo_name, "mainsail"))) return error.InvalidRelease;
            return .{ .version = version };
        },
        else => return err,
    };
    const data = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always });
    if (jv.exceedsDepth(data, jv.max_value_depth)) return error.InvalidRelease;
    if (!std.ascii.eqlIgnoreCase(try text(data, "project_owner"), src.owner) or
        !std.ascii.eqlIgnoreCase(try text(data, "project_name"), src.repo_name)) return error.InvalidRelease;
    return .{ .version = try text(data, "version"), .asset_name = if (data.object.get("asset_name")) |asset| if (asset == .string) asset.string else return error.InvalidRelease else "" };
}

pub fn validRelative(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return false;
    return true;
}

pub const Target = struct {
    parent: Dir,
    name: []const u8,
    backup: []const u8,

    pub fn open(alloc: Allocator, io: Io, path: []const u8, environment: ?*const std.process.Environ.Map) !Target {
        const expanded = if (std.mem.startsWith(u8, path, "~/")) try std.fs.path.join(alloc, &.{ if (environment) |env| env.get("HOME") orelse return error.InvalidPath else return error.InvalidPath, path[2..] }) else path;
        const resolved = try Dir.cwd().realPathFileAlloc(io, expanded, alloc);
        const name = std.fs.path.basename(resolved);
        const parent_path = std.fs.path.dirname(resolved) orelse return error.InvalidPath;
        if (!validRelative(name) or std.mem.eql(u8, resolved, "/")) return error.InvalidPath;
        const parent = try Dir.openDirAbsolute(io, parent_path, .{});
        errdefer parent.close(io);
        var target = try parent.openDir(io, name, .{ .follow_symlinks = false });
        target.close(io);
        return .{ .parent = parent, .name = name, .backup = try std.fmt.allocPrint(alloc, ".{s}.phobos-rollback", .{name}) };
    }

    pub fn close(self: Target, io: Io) void {
        self.parent.close(io);
    }

    pub fn read(self: Target, alloc: Allocator, io: Io, src: Source) !Installed {
        const dir = try self.parent.openDir(io, self.name, .{ .follow_symlinks = false });
        defer dir.close(io);
        return installed(alloc, io, dir, src);
    }
};

fn urlAllowed(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) and uri.host != null and uri.user == null and uri.password == null;
}

/// Cached Moonraker dl_info is used without contacting a release API.
pub fn cachedRelease(cache: std.json.Value) ?Release {
    const version = text(cache, "remote_version") catch return null;
    if (std.mem.eql(u8, version, "?")) return null;
    const info = cache.object.get("dl_info") orelse return null;
    if (info != .array or info.array.items.len != 3 or info.array.items[0] != .string or info.array.items[2] != .integer or info.array.items[2].integer < 0) return null;
    const url = info.array.items[0].string;
    if (!urlAllowed(url)) return null;
    return .{ .version = version, .url = url, .size = @intCast(info.array.items[2].integer) };
}

/// Select one release asset. All returned strings belong to alloc.
pub fn parseRelease(alloc: Allocator, body: []const u8, asset_name: []const u8) !Release {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always });
    if (jv.exceedsDepth(parsed, jv.max_value_depth)) return error.InvalidRelease;
    var value = parsed;
    if (value == .array) {
        if (value.array.items.len == 0) return error.InvalidRelease;
        value = value.array.items[0];
    }
    const version = try text(value, "name");
    const assets = if (value == .object) value.object.get("assets") orelse return error.InvalidRelease else return error.InvalidRelease;
    if (assets != .array or assets.array.items.len > 128) return error.InvalidRelease;
    for (assets.array.items) |asset| {
        const name = try text(asset, "name");
        if (asset_name.len != 0) {
            if (!std.mem.eql(u8, name, asset_name)) continue;
        } else if (!std.mem.endsWith(u8, name, ".zip")) continue;
        const url = try text(asset, "browser_download_url");
        if (!urlAllowed(url)) return error.InvalidRelease;
        const size = asset.object.get("size") orelse return error.InvalidRelease;
        if (size != .integer or size.integer <= 0 or size.integer > max_archive) return error.ReleaseTooLarge;
        return .{ .version = version, .url = url, .size = @intCast(size.integer) };
    }
    return error.ReleaseAssetMissing;
}

fn repoPartValid(part: []const u8) bool {
    if (part.len == 0 or part.len > 128 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

pub fn refresh(alloc: Allocator, io: Io, src: Source, current: Installed, api_base: []const u8) !Release {
    if (!repoPartValid(src.owner) or !repoPartValid(src.repo_name)) return error.InvalidRelease;
    const url = try std.fmt.allocPrint(alloc, "{s}/repos/{s}/{s}/releases{s}", .{ api_base, src.owner, src.repo_name, if (std.mem.eql(u8, src.channel, "dev")) "?per_page=1" else "/latest" });
    const buffer = try alloc.alloc(u8, 256 * 1024);
    const body = try power.deviceRequest(alloc, io, .GET, url, null, .fromSeconds(30), buffer);
    return parseRelease(alloc, body, current.asset_name);
}

fn downloadRequest(client: *std.http.Client, url: []const u8, file: Io.File) !u64 {
    var req = try client.request(.GET, try std.Uri.parse(url), .{ .headers = http_get.identity_headers, .keep_alive = false, .redirect_behavior = @fromBackingInt(3) });
    defer req.deinit();
    req.accept_encoding = http_get.identity_only;
    try req.sendBodiless();
    var head: [8192]u8 = undefined;
    var response = try req.receiveHead(&head);
    if (response.head.status.class() != .success) return error.HttpStatus;
    var transfer: [16384]u8 = undefined;
    const reader = response.reader(&transfer);
    var limited = reader.limited(.limited(max_archive), &.{});
    var output: [32768]u8 = undefined;
    var writer = file.writer(client.io, &output);
    const count = limited.interface.streamRemaining(&writer.interface) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => {
            try writer.end();
            try file.sync(client.io);
            return count;
        },
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
    };
    return error.ReleaseTooLarge;
}

fn download(alloc: Allocator, io: Io, release: Release, file: Io.File) !void {
    if (!urlAllowed(release.url) or release.size > max_archive) return error.InvalidRelease;
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const Outcome = union(enum) { downloaded: @typeInfo(@TypeOf(downloadRequest)).@"fn".return_type.?, expired: Io.Cancelable!void };
    var outcomes: [2]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &outcomes);
    defer select.cancelDiscard();
    try select.concurrent(.downloaded, downloadRequest, .{ &client, release.url, file });
    try select.concurrent(.expired, Io.sleep, .{ io, Io.Duration.fromSeconds(120), .awake });
    switch (try select.await()) {
        .expired => |result| {
            try result;
            return error.Timeout;
        },
        .downloaded => |result| {
            const count = try result;
            if (count == 0 or (release.size != 0 and release.size != count)) return error.ReleaseSizeMismatch;
        },
    }
}

/// Extract into a new private directory. Links, devices, traversal and bad CRCs fail.
pub fn extract(io: Io, archive: Io.File, dest: Dir) !void {
    const size = (try archive.stat(io)).size;
    if (size > max_archive) return error.ReleaseTooLarge;
    var input: [32768]u8 = undefined;
    var reader = archive.reader(io, &input);
    var iter = try std.zip.Iterator.init(&reader);
    if (iter.cd_record_count > max_entries or iter.cd_zip_offset > size or iter.cd_size > size - iter.cd_zip_offset) return error.ReleaseTooLarge;
    var total: u64 = 0;
    while (try iter.next()) |entry| {
        if (entry.file_offset > size or entry.compressed_size > size - entry.file_offset or entry.uncompressed_size > max_expanded - total) return error.ReleaseTooLarge;
        total += entry.uncompressed_size;
        var filename: [Dir.max_path_bytes]u8 = undefined;
        var name = try entry.getFilename(&reader, &filename, .{});
        const directory = std.mem.endsWith(u8, name, "/");
        if (directory) name = name[0 .. name.len - 1];
        if (!validRelative(name)) return error.UnsafeArchivePath;
        try reader.seekTo(entry.header_zip_offset);
        const header = try reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const mode = if (header.version_made_by >> 8 == 3) header.external_file_attributes >> 16 else 0;
        const kind = mode & 0xf000;
        if (kind != 0 and kind != (if (directory) @as(u32, 0x4000) else 0x8000)) return error.UnsafeArchiveType;
        if (directory) {
            if (entry.uncompressed_size != 0) return error.InvalidRelease;
            if (entry.crc32 != 0) return error.ZipChecksumMismatch;
            try dest.createDirPath(io, name);
            continue;
        }
        if (std.fs.path.dirname(name)) |parent| try dest.createDirPath(io, parent);
        const permissions: Io.File.Permissions = .fromMode(if (mode & 0o777 != 0) mode & 0o777 else 0o644);
        const file = try dest.createFile(io, name, .{ .exclusive = true, .permissions = permissions });
        defer file.close(io);
        try file.setPermissions(io, permissions);
        var output = file.writer(io, &.{});
        var hash_buffer: [32768]u8 = undefined;
        var hashing = output.interface.hashed(std.hash.Crc32.init(), &hash_buffer);
        try entry.extractTo(&reader, &hashing.writer);
        try hashing.writer.flush();
        try output.end();
        if (hashing.hasher.final() != entry.crc32) return error.ZipChecksumMismatch;
        try file.sync(io);
    }
}

fn copyPersistent(io: Io, src: Dir, dest: Dir, path: []const u8, budget: *u64, entries: *usize, depth: usize) anyerror!void {
    if (depth > 64 or entries.* >= max_entries) return error.ReleaseTooLarge;
    entries.* += 1;
    const stat = src.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    switch (stat.kind) {
        .file => {
            if (stat.size > budget.*) return error.ReleaseTooLarge;
            budget.* -= stat.size;
            const file = try src.openFile(io, path, .{ .follow_symlinks = false });
            defer file.close(io);
            if ((try file.stat(io)).kind != .file) return error.UnsafePersistentFile;
            const permissions: Io.File.Permissions = .fromMode(stat.permissions.toMode() & 0o777);
            const out = try dest.createFile(io, path, .{ .permissions = permissions });
            defer out.close(io);
            try out.setPermissions(io, permissions);
            var output_buffer: [1024]u8 = undefined;
            var input_buffer: [1024]u8 = undefined;
            var writer = out.writer(io, &output_buffer);
            var reader = file.reader(io, &input_buffer);
            if (try writer.interface.sendFileAll(&reader, .limited64(stat.size)) != stat.size) return error.UnsafePersistentFile;
            try writer.end();
            try out.sync(io);
        },
        .directory => {
            const child = try src.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            const output = try dest.createDirPathOpen(io, path, .{});
            defer output.close(io);
            var iter = child.iterate();
            while (try iter.next(io)) |entry| try copyPersistent(io, child, output, entry.name, budget, entries, depth + 1);
        },
        else => return error.UnsafePersistentFile,
    }
}

fn temporary(io: Io, parent: Dir, name_buffer: []u8) ![]const u8 {
    for (0..8) |_| {
        var random: [12]u8 = undefined;
        try io.randomSecure(&random);
        const name = try std.fmt.bufPrint(name_buffer, ".phobos-update-{x}", .{random});
        parent.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return name;
    }
    return error.PathAlreadyExists;
}

/// The old directory is retained for rollback. A failed publish restores it.
pub fn install(alloc: Allocator, io: Io, target: Target, src: Source, release: Release) !bool {
    const old = try target.read(alloc, io, src);
    if (std.mem.eql(u8, std.mem.trimStart(u8, old.version, "v"), std.mem.trimStart(u8, release.version, "v"))) return false;
    var name_buffer: [96]u8 = undefined;
    const stage_name = try temporary(io, target.parent, &name_buffer);
    var cleanup = true;
    defer if (cleanup) target.parent.deleteTree(io, stage_name) catch {};
    const stage = try target.parent.openDir(io, stage_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    const archive = try stage.createFile(io, "release.zip", .{ .read = true, .exclusive = true });
    defer archive.close(io);
    try download(alloc, io, release, archive);
    try stage.createDir(io, "new", .fromMode(0o755));
    const bundle = try stage.openDir(io, "new", .{});
    defer bundle.close(io);
    try extract(io, archive, bundle);
    const next = try installed(alloc, io, bundle, src);
    if (!std.mem.eql(u8, std.mem.trimStart(u8, next.version, "v"), std.mem.trimStart(u8, release.version, "v"))) return error.ReleaseVersionMismatch;
    const current = try target.parent.openDir(io, target.name, .{ .follow_symlinks = false });
    defer current.close(io);
    var budget: u64 = max_expanded;
    var entries: usize = 0;
    for (src.persistent_files) |path| {
        if (!validRelative(path) or std.mem.eql(u8, path, ".version") or std.mem.eql(u8, path, "release_info.json")) return error.UnsafePersistentFile;
        // Walk each parent without following links in the installed tree.
        var parts = std.mem.splitScalar(u8, path, '/');
        var from = current;
        var to = bundle;
        var close_from = false;
        var close_to = false;
        defer {
            if (close_from) from.close(io);
            if (close_to) to.close(io);
        }
        var part = parts.next().?;
        var missing = false;
        while (parts.next()) |next_part| {
            const next_from = from.openDir(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => {
                    missing = true;
                    break;
                },
                else => return err,
            };
            if (close_from) from.close(io);
            from = next_from;
            close_from = true;
            const next_to = try to.createDirPathOpen(io, part, .{});
            if (close_to) to.close(io);
            to = next_to;
            close_to = true;
            part = next_part;
        }
        if (missing) continue;
        _ = from.statFile(io, part, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try to.deleteTree(io, part);
        try copyPersistent(io, from, to, part, &budget, &entries, 0);
    }
    const has_backup = if (target.parent.openDir(io, target.backup, .{ .follow_symlinks = false })) |backup| blk: {
        defer backup.close(io);
        _ = try installed(alloc, io, backup, src);
        break :blk true;
    } else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    try publish(io, target, stage, has_backup, &cleanup);
    return true;
}

fn publish(io: Io, target: Target, stage: Dir, has_backup: bool, cleanup: *bool) !void {
    if (has_backup) try target.parent.renamePreserve(target.backup, stage, "previous", io);
    target.parent.renamePreserve(target.name, target.parent, target.backup, io) catch |err| {
        if (has_backup) stage.renamePreserve("previous", target.parent, target.backup, io) catch {
            cleanup.* = false;
            return error.RestoreFailed;
        };
        return err;
    };
    stage.renamePreserve("new", target.parent, target.name, io) catch |err| {
        target.parent.renamePreserve(target.backup, target.parent, target.name, io) catch {
            cleanup.* = false;
            return error.RestoreFailed;
        };
        if (has_backup) stage.renamePreserve("previous", target.parent, target.backup, io) catch {
            cleanup.* = false;
            return error.RestoreFailed;
        };
        return err;
    };
}

pub fn rollback(alloc: Allocator, io: Io, target: Target, src: Source) !void {
    _ = try target.read(alloc, io, src);
    const backup = try target.parent.openDir(io, target.backup, .{ .follow_symlinks = false });
    defer backup.close(io);
    _ = try installed(alloc, io, backup, src);
    var name_buffer: [96]u8 = undefined;
    const stage_name = try temporary(io, target.parent, &name_buffer);
    var cleanup = true;
    defer if (cleanup) target.parent.deleteTree(io, stage_name) catch {};
    const stage = try target.parent.openDir(io, stage_name, .{});
    defer stage.close(io);
    try target.parent.renamePreserve(target.name, stage, "current", io);
    target.parent.renamePreserve(target.backup, target.parent, target.name, io) catch |err| {
        stage.renamePreserve("current", target.parent, target.name, io) catch {
            cleanup = false;
            return error.RestoreFailed;
        };
        return err;
    };
    stage.renamePreserve("current", target.parent, target.backup, io) catch |err| {
        target.parent.renamePreserve(target.name, target.parent, target.backup, io) catch {
            cleanup = false;
            return error.RestoreFailed;
        };
        stage.renamePreserve("current", target.parent, target.name, io) catch {
            cleanup = false;
            return error.RestoreFailed;
        };
        return err;
    };
}

const testing = std.testing;
const fixture_source: Source = .{ .name = "client", .type = .zip, .owner = "owner", .repo_name = "project" };
const fixture_v1 = "{\"project_owner\":\"owner\",\"project_name\":\"project\",\"version\":\"1.0\",\"asset_name\":\"client.zip\"}";
const fixture_v2 = "{\"project_owner\":\"owner\",\"project_name\":\"project\",\"version\":\"2.0\",\"asset_name\":\"client.zip\"}";

fn fixtureArchive(io: Io, dir: Dir, store: bool) !Io.File {
    const Archive = @import("../zip_writer.zig").Archive;
    const archive = try dir.createFile(io, "bundle.zip", .{ .read = true });
    errdefer archive.close(io);
    var buffer: [32768]u8 = undefined;
    var writer = archive.writer(io, &buffer);
    var zip = Archive.init(testing.allocator, &writer, store);
    defer zip.deinit();
    for ([_]struct { name: []const u8, data: []const u8, mode: u16 = 0o644 }{
        .{ .name = "release_info.json", .data = fixture_v2 },
        .{ .name = "index.html", .data = "new client" },
        .{ .name = "run", .data = "executable", .mode = 0o755 },
        .{ .name = "settings/theme", .data = "bundled theme" },
        .{ .name = "absent.txt", .data = "new default" },
    }) |entry| {
        const input = try dir.createFile(io, "input", .{ .read = true, .permissions = .fromMode(entry.mode) });
        defer input.close(io);
        try input.setPermissions(io, .fromMode(entry.mode));
        try input.writeStreamingAll(io, entry.data);
        try zip.addFile(input, entry.name);
    }
    try zip.finish();
    try writer.end();
    return archive;
}

const FixtureHttp = struct {
    io: Io,
    server: Io.net.Server,
    file: ?Io.File = null,
    body: []const u8 = "",
    status: u16 = 200,
    extra_length: u64 = 0,

    fn init(io: Io) !FixtureHttp {
        return .{ .io = io, .server = try (try Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{}) };
    }
    fn url(self: *FixtureHttp, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }
    fn serve(self: *FixtureHttp) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var input: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &input);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len <= 2) break;
        }
        var output: [32768]u8 = undefined;
        var writer = stream.writer(self.io, &output);
        const length = if (self.file) |file| (file.stat(self.io) catch return).size else self.body.len;
        writer.interface.print("HTTP/1.1 {d} Fixture\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ self.status, length + self.extra_length }) catch return;
        if (self.file) |file| {
            var file_buffer: [32768]u8 = undefined;
            var file_reader = file.reader(self.io, &file_buffer);
            _ = writer.interface.sendFileAll(&file_reader, .limited64(length)) catch return;
        } else writer.interface.writeAll(self.body) catch return;
        writer.interface.flush() catch return;
    }
};

test "web ZIP install preserves settings executable modes and both rollback versions" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const archive = try fixtureArchive(io, temp.dir, false);
    defer archive.close(io);
    try temp.dir.createDir(io, "client", .default_dir);
    const client = try temp.dir.openDir(io, "client", .{});
    defer client.close(io);
    try client.writeFile(io, .{ .sub_path = "release_info.json", .data = fixture_v1 });
    try client.writeFile(io, .{ .sub_path = "index.html", .data = "old client" });
    try client.createDir(io, "settings", .default_dir);
    try client.writeFile(io, .{ .sub_path = "settings/theme", .data = "user theme" });
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var source = fixture_source;
    source.persistent_files = &.{ "settings/theme", "absent.txt" };
    const target = try Target.open(alloc, io, try temp.dir.realPathFileAlloc(io, "client", alloc), null);
    defer target.close(io);
    var server = try FixtureHttp.init(io);
    defer server.server.deinit(io);
    server.file = archive;
    var serving = try io.concurrent(FixtureHttp.serve, .{&server});
    defer serving.cancel(io);
    var url_buffer: [96]u8 = undefined;
    const release: Release = .{ .version = "2.0", .url = try server.url(&url_buffer), .size = (try archive.stat(io)).size };
    try testing.expect(try install(alloc, io, target, source, release));
    serving.await(io);
    try testing.expectEqualStrings("2.0", (try target.read(alloc, io, source)).version);
    const updated = try target.parent.openDir(io, target.name, .{});
    defer updated.close(io);
    try testing.expectEqualStrings("new client", try readText(alloc, io, updated, "index.html"));
    try testing.expectEqualStrings("user theme", try readText(alloc, io, updated, "settings/theme"));
    try testing.expectEqualStrings("new default", try readText(alloc, io, updated, "absent.txt"));
    try testing.expectEqual(@as(u32, 0o755), (try updated.statFile(io, "run", .{})).permissions.toMode() & 0o777);
    try testing.expect(!try install(alloc, io, target, source, release));
    try rollback(alloc, io, target, source);
    try testing.expectEqualStrings("1.0", (try target.read(alloc, io, source)).version);
    try rollback(alloc, io, target, source);
    try testing.expectEqualStrings("2.0", (try target.read(alloc, io, source)).version);
}

test "ZIP extraction rejects traversal symlinks bad checksums and excessive output" {
    const Mutation = enum { traversal, symlink, checksum, expanded };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        const archive = try fixtureArchive(testing.io, temp.dir, true);
        defer archive.close(testing.io);
        var buffer: [4096]u8 = undefined;
        var reader = archive.reader(testing.io, &buffer);
        var iterator = try std.zip.Iterator.init(&reader);
        _ = try iterator.next();
        const entry = (try iterator.next()).?;
        switch (mutation) {
            .traversal => try archive.writePositionalAll(testing.io, "../outside", entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)),
            .symlink => {
                var mode: [4]u8 = undefined;
                std.mem.writeInt(u32, &mode, 0xa1ff << 16, .little);
                try archive.writePositionalAll(testing.io, &mode, entry.header_zip_offset + @offsetOf(std.zip.CentralDirectoryFileHeader, "external_file_attributes"));
            },
            .checksum => try archive.writePositionalAll(testing.io, &.{ 0, 0, 0, 0 }, entry.header_zip_offset + @offsetOf(std.zip.CentralDirectoryFileHeader, "crc32")),
            .expanded => {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, max_expanded + 1, .little);
                try archive.writePositionalAll(testing.io, &bytes, entry.header_zip_offset + @offsetOf(std.zip.CentralDirectoryFileHeader, "uncompressed_size"));
            },
        }
        try temp.dir.createDir(testing.io, "out", .default_dir);
        const out = try temp.dir.openDir(testing.io, "out", .{});
        defer out.close(testing.io);
        try testing.expectError(switch (mutation) {
            .traversal => error.ZipBadFilename,
            .symlink => error.UnsafeArchiveType,
            .checksum => error.ZipChecksumMismatch,
            .expanded => error.ReleaseTooLarge,
        }, extract(testing.io, archive, out));
        try testing.expectError(error.FileNotFound, temp.dir.statFile(testing.io, "outside", .{}));
    }
}

test "release API refresh uses loopback metadata and truncated downloads retain the installation" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(io, "client", .default_dir);
    const client = try temp.dir.openDir(io, "client", .{});
    defer client.close(io);
    try client.writeFile(io, .{ .sub_path = "release_info.json", .data = fixture_v1 });
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const target = try Target.open(alloc, io, try temp.dir.realPathFileAlloc(io, "client", alloc), null);
    defer target.close(io);
    var server = try FixtureHttp.init(io);
    defer server.server.deinit(io);
    var url_buffer: [96]u8 = undefined;
    const url = try server.url(&url_buffer);
    server.body = try std.fmt.allocPrint(alloc, "{{\"name\":\"2.0\",\"assets\":[{{\"name\":\"client.zip\",\"browser_download_url\":\"{s}/client.zip\",\"size\":10}}]}}", .{url});
    var serving = try io.concurrent(FixtureHttp.serve, .{&server});
    defer serving.cancel(io);
    const release = try refresh(alloc, io, fixture_source, .{ .version = "1.0", .asset_name = "client.zip" }, url);
    serving.await(io);
    try testing.expectEqualStrings("2.0", release.version);
    server.body = "truncated";
    server.extra_length = 100;
    serving = try io.concurrent(FixtureHttp.serve, .{&server});
    if (install(alloc, io, target, fixture_source, release)) |_| return error.TestUnexpectedResult else |_| {}
    serving.await(io);
    try testing.expectEqualStrings("1.0", (try target.read(alloc, io, fixture_source)).version);
    try testing.expectError(error.FileNotFound, target.parent.statFile(io, target.backup, .{}));
}

test "client handlers refresh cached releases install restart and roll back through injected services" {
    const manager = @import("update_manager.zig");
    const Restart = struct {
        calls: usize = 0,
        ctx: *manager.UpdateCtx,
        fail: bool = false,
        fn run(raw: *anyopaque, _: Allocator, service: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try testing.expectEqualStrings("klipper", service);
            try testing.expect(self.ctx.commands.tryLock());
            self.ctx.commands.unlock(self.ctx.clock_io);
            try testing.expect(self.ctx.busy.load(.acquire));
            self.calls += 1;
            if (self.fail) return error.MockServiceFailure;
        }
    };
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const archive = try fixtureArchive(io, temp.dir, true);
    defer archive.close(io);
    try temp.dir.createDir(io, "client", .default_dir);
    const client = try temp.dir.openDir(io, "client", .{});
    defer client.close(io);
    try client.writeFile(io, .{ .sub_path = "release_info.json", .data = fixture_v1 });
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var source = fixture_source;
    source.repo_path = try temp.dir.realPathFileAlloc(io, "client", alloc);
    source.managed_services = &.{"klipper"};
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(io, ":memory:");
    defer db.deinit();
    var server = try FixtureHttp.init(io);
    defer server.server.deinit(io);
    var url_buffer: [96]u8 = undefined;
    const url = try server.url(&url_buffer);
    server.body = try std.fmt.allocPrint(alloc, "{{\"name\":\"2.0\",\"assets\":[{{\"name\":\"client.zip\",\"browser_download_url\":\"{s}/client.zip\",\"size\":{d}}}]}}", .{ url, (try archive.stat(io)).size });
    var ctx: manager.UpdateCtx = .{ .clock_io = io, .gpa = std.heap.smp_allocator, .io = io, .bus = null, .sources = &.{source}, .store = db.dataStore(), .github_api_base = url };
    defer ctx.deinit();
    var restart: Restart = .{ .ctx = &ctx };
    ctx.restart_service = Restart.run;
    ctx.service_ctx = &restart;
    const params = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"client\"}", .{});
    var serving = try io.concurrent(FixtureHttp.serve, .{&server});
    defer serving.cancel(io);
    const refreshed = try manager.handleRefresh(&ctx, params, alloc);
    serving.await(io);
    const info = refreshed.object.get("version_info").?.object.get("client").?.object;
    try testing.expectEqualStrings("2.0", info.get("remote_version").?.string);
    server.file = archive;
    serving = try io.concurrent(FixtureHttp.serve, .{&server});
    try testing.expectEqualStrings("ok", (try manager.handleUpdateClient(&ctx, params, alloc)).string);
    serving.await(io);
    try testing.expectEqual(@as(usize, 1), restart.calls);
    const payload = try manager.handleStatus(&ctx, .null, alloc);
    const installed_info = payload.object.get("version_info").?.object.get("client").?.object;
    try testing.expectEqualStrings("2.0", installed_info.get("version").?.string);
    try testing.expectEqualStrings("1.0", installed_info.get("rollback_version").?.string);
    _ = try manager.handleUpdateClient(&ctx, params, alloc);
    try testing.expectEqual(@as(usize, 1), restart.calls);
    _ = try manager.handleRollback(&ctx, params, alloc);
    try testing.expectEqual(@as(usize, 2), restart.calls);
    restart.fail = true;
    serving = try io.concurrent(FixtureHttp.serve, .{&server});
    try testing.expectError(error.MockServiceFailure, manager.handleUpdateClient(&ctx, params, alloc));
    serving.await(io);
    try testing.expect(!ctx.busy.load(.acquire));
    restart.fail = false;
    _ = try manager.handleRollback(&ctx, params, alloc);
    restart.fail = true;
    try testing.expectError(error.MockServiceFailure, manager.handleRollback(&ctx, params, alloc));
    try testing.expect(!ctx.busy.load(.acquire));
    restart.fail = false;
    _ = try manager.handleRollback(&ctx, params, alloc);
    const final = try manager.handleStatus(&ctx, .null, alloc);
    try testing.expectEqualStrings("1.0", final.object.get("version_info").?.object.get("client").?.object.get("version").?.string);
}

test "a persistent parent symlink aborts installation without changing either tree" {
    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const archive = try fixtureArchive(io, temp.dir, true);
    defer archive.close(io);
    try temp.dir.createDir(io, "client", .default_dir);
    try temp.dir.createDir(io, "outside", .default_dir);
    try temp.dir.writeFile(io, .{ .sub_path = "outside/theme", .data = "outside data" });
    const client = try temp.dir.openDir(io, "client", .{});
    defer client.close(io);
    try client.writeFile(io, .{ .sub_path = "release_info.json", .data = fixture_v1 });
    try client.symLink(io, "../outside", "settings", .{ .is_directory = true });
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const target = try Target.open(alloc, io, try temp.dir.realPathFileAlloc(io, "client", alloc), null);
    defer target.close(io);
    var source = fixture_source;
    source.persistent_files = &.{"settings/theme"};
    var server = try FixtureHttp.init(io);
    defer server.server.deinit(io);
    server.file = archive;
    var url_buffer: [96]u8 = undefined;
    var serving = try io.concurrent(FixtureHttp.serve, .{&server});
    defer serving.cancel(io);
    if (install(alloc, io, target, source, .{ .version = "2.0", .url = try server.url(&url_buffer) })) |_| return error.TestUnexpectedResult else |_| {}
    serving.await(io);
    try testing.expectEqualStrings("1.0", (try target.read(alloc, io, source)).version);
    try testing.expectEqualStrings("outside data", try readText(alloc, io, temp.dir, "outside/theme"));
    try testing.expectError(error.FileNotFound, target.parent.statFile(io, target.backup, .{}));
}

test "fuzz install refusal and rollback preserve validated directories" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            try temp.dir.createDir(testing.io, "client", .default_dir);
            try temp.dir.writeFile(testing.io, .{ .sub_path = "client/release_info.json", .data = fixture_v1 });
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const target = try Target.open(alloc, testing.io, try temp.dir.realPathFileAlloc(testing.io, "client", alloc), null);
            defer target.close(testing.io);
            const manager = @import("update_manager.zig");
            var source = fixture_source;
            source.repo_path = try temp.dir.realPathFileAlloc(testing.io, "client", alloc);
            var ctx: manager.UpdateCtx = .{ .clock_io = testing.io, .gpa = testing.allocator, .io = testing.io, .bus = null, .sources = &.{source} };
            defer ctx.deinit();
            const params = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"client\"}", .{});
            try testing.expectError(error.InvalidRelease, install(alloc, testing.io, target, fixture_source, .{ .version = "2.0", .url = "file:///forbidden" }));
            if (smith.value(bool)) {
                try target.parent.createDir(testing.io, target.backup, .default_dir);
                const backup = try target.parent.openDir(testing.io, target.backup, .{});
                defer backup.close(testing.io);
                try backup.writeFile(testing.io, .{ .sub_path = "release_info.json", .data = fixture_v2 });
                _ = try manager.handleRollback(&ctx, params, alloc);
                try testing.expectEqualStrings("2.0", (try target.read(alloc, testing.io, fixture_source)).version);
            } else {
                try testing.expectError(error.FileNotFound, manager.handleRollback(&ctx, params, alloc));
                try testing.expectEqualStrings("1.0", (try target.read(alloc, testing.io, fixture_source)).version);
            }
            try testing.expect(!ctx.busy.load(.acquire));
        }
    }.run, .{});
}

test "failed publication restores the current install and its previous rollback copy" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "client", .default_dir);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "client/release_info.json", .data = fixture_v1 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const target = try Target.open(alloc, testing.io, try temp.dir.realPathFileAlloc(testing.io, "client", alloc), null);
    defer target.close(testing.io);
    try target.parent.createDir(testing.io, target.backup, .default_dir);
    const backup = try target.parent.openDir(testing.io, target.backup, .{});
    defer backup.close(testing.io);
    try backup.writeFile(testing.io, .{ .sub_path = "release_info.json", .data = fixture_v2 });
    try temp.dir.createDir(testing.io, "stage", .default_dir);
    const stage = try temp.dir.openDir(testing.io, "stage", .{});
    defer stage.close(testing.io);
    var cleanup = true;
    try testing.expectError(error.FileNotFound, publish(testing.io, target, stage, true, &cleanup));
    try testing.expect(cleanup);
    try testing.expectEqualStrings("1.0", (try target.read(alloc, testing.io, fixture_source)).version);
    const restored = try target.parent.openDir(testing.io, target.backup, .{});
    defer restored.close(testing.io);
    try testing.expectEqualStrings("2.0", (try installed(alloc, testing.io, restored, fixture_source)).version);
}

test "fuzz persistent copies enforce byte budgets and preserve arbitrary contents" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const count = smith.valueRangeAtMost(u16, 0, bytes.len);
            try temp.dir.createDir(testing.io, "src", .default_dir);
            try temp.dir.createDir(testing.io, "dest", .default_dir);
            const src = try temp.dir.openDir(testing.io, "src", .{});
            defer src.close(testing.io);
            const dest = try temp.dir.openDir(testing.io, "dest", .{});
            defer dest.close(testing.io);
            try src.writeFile(testing.io, .{ .sub_path = "file", .data = bytes[0..count] });
            var budget: u64 = count;
            var entries: usize = 0;
            try copyPersistent(testing.io, src, dest, "file", &budget, &entries, 0);
            try testing.expectEqual(@as(u64, 0), budget);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try testing.expectEqualSlices(u8, bytes[0..count], try readText(arena.allocator(), testing.io, dest, "file"));
            if (count > 0) {
                budget = count - 1;
                try testing.expectError(error.ReleaseTooLarge, copyPersistent(testing.io, src, dest, "file", &budget, &entries, 0));
            }
        }
    }.run, .{});
}

test "fuzz publication restores failures and keeps completed versions" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            try temp.dir.createDir(testing.io, "client", .default_dir);
            try temp.dir.createDir(testing.io, "stage", .default_dir);
            try temp.dir.writeFile(testing.io, .{ .sub_path = "client/release_info.json", .data = fixture_v1 });
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            const target = try Target.open(alloc, testing.io, try temp.dir.realPathFileAlloc(testing.io, "client", alloc), null);
            defer target.close(testing.io);
            const stage = try temp.dir.openDir(testing.io, "stage", .{});
            defer stage.close(testing.io);
            const has_backup = smith.value(bool);
            if (has_backup) {
                try target.parent.createDir(testing.io, target.backup, .default_dir);
                const backup = try target.parent.openDir(testing.io, target.backup, .{});
                defer backup.close(testing.io);
                try backup.writeFile(testing.io, .{ .sub_path = "release_info.json", .data = fixture_v2 });
            }
            const succeeds = smith.value(bool);
            if (succeeds) {
                try stage.createDir(testing.io, "new", .default_dir);
                try stage.writeFile(testing.io, .{ .sub_path = "new/release_info.json", .data = fixture_v2 });
            }
            var cleanup = true;
            if (succeeds) {
                try publish(testing.io, target, stage, has_backup, &cleanup);
            } else try testing.expectError(error.FileNotFound, publish(testing.io, target, stage, has_backup, &cleanup));
            try testing.expectEqualStrings(if (succeeds) "2.0" else "1.0", (try target.read(alloc, testing.io, fixture_source)).version);
            try testing.expect(cleanup);
        }
    }.run, .{});
}

test "fuzz release HTTP URLs reject unsupported schemes before making a connection" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            const file = try temp.dir.createFile(testing.io, "download", .{});
            defer file.close(testing.io);
            var bytes: [64]u8 = undefined;
            @memcpy(bytes[0.."unsupported:".len], "unsupported:");
            smith.bytesWithHash(bytes["unsupported:".len..], 0);
            var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
            defer client.deinit();
            if (downloadRequest(&client, &bytes, file)) |_| return error.TestUnexpectedResult else |_| {}
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var bad = fixture_source;
            bad.owner = "../invalid";
            try testing.expectError(error.InvalidRelease, refresh(arena.allocator(), testing.io, bad, .{ .version = "1.0" }, "file:///invalid"));
        }
    }.run, .{});
}

test "fuzz malformed ZIP archives fail inside a private directory" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            var bytes: [1024]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const file = try temp.dir.createFile(testing.io, "bad.zip", .{ .read = true });
            defer file.close(testing.io);
            try file.writeStreamingAll(testing.io, &bytes);
            try temp.dir.createDir(testing.io, "out", .default_dir);
            const out = try temp.dir.openDir(testing.io, "out", .{});
            defer out.close(testing.io);
            extract(testing.io, file, out) catch {};
        }
    }.run, .{});
}

test "release metadata selects the named ZIP and reads a Moonraker download cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const body = "[{\"name\":\"2.0\",\"assets\":[{\"name\":\"other.zip\",\"browser_download_url\":\"https://example.invalid/other.zip\",\"size\":12},{\"name\":\"client.zip\",\"browser_download_url\":\"http://127.0.0.1/client.zip\",\"size\":42}]}]";
    const release = try parseRelease(alloc, body, "client.zip");
    try testing.expectEqualStrings("2.0", release.version);
    try testing.expectEqual(@as(u64, 42), release.size);
    try testing.expectEqualStrings("http://127.0.0.1/client.zip", release.url);
    try testing.expectError(error.ReleaseAssetMissing, parseRelease(alloc, body, "missing.zip"));
    const cache = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"remote_version\":\"2.0\",\"dl_info\":[\"http://127.0.0.1/a.zip\",\"application/zip\",42]}", .{});
    try testing.expectEqual(@as(u64, 42), cachedRelease(cache).?.size);
    try testing.expect(cachedRelease(.null) == null);
    try testing.expect(!urlAllowed("file:///etc/passwd"));
    try testing.expect(!repoPartValid("../escape"));
}

test "relative update paths reject links traversal and reserved Git directories" {
    for ([_][]const u8{ "", "/absolute", "../escape", "a/../b", "a//b", "a\\b", ".git/config", "a/./b", "a/", "a\x00b" }) |path| try testing.expect(!validRelative(path));
    try testing.expect(validRelative("settings/theme.json"));
}

test "installed releases validate identity and persistent copies reject symlinks" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "client", .default_dir);
    const client = try temp.dir.openDir(testing.io, "client", .{});
    defer client.close(testing.io);
    try client.writeFile(testing.io, .{ .sub_path = "release_info.json", .data = fixture_v1 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try testing.expectEqualStrings("1.0", (try installed(alloc, testing.io, client, fixture_source)).version);
    var wrong = fixture_source;
    wrong.owner = "another";
    try testing.expectError(error.InvalidRelease, installed(alloc, testing.io, client, wrong));
    try client.symLink(testing.io, "release_info.json", "link", .{});
    try temp.dir.createDir(testing.io, "output", .default_dir);
    const output = try temp.dir.openDir(testing.io, "output", .{});
    defer output.close(testing.io);
    var bytes: u64 = 1024;
    var entries: usize = 0;
    try testing.expectError(error.UnsafePersistentFile, copyPersistent(testing.io, client, output, "link", &bytes, &entries, 0));
    try copyPersistent(testing.io, client, output, "release_info.json", &bytes, &entries, 0);
    try testing.expectEqualStrings(fixture_v1, try readText(alloc, testing.io, output, "release_info.json"));
    try client.createDir(testing.io, ".git", .default_dir);
    try testing.expectError(error.GitDirectory, installed(alloc, testing.io, client, fixture_source));
}

test "web manifest fallback and configured home symlinks resolve to a checked target" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "fluidd", .default_dir);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "fluidd/.version", .data = "v1.37.7\n" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "fluidd/manifest.webmanifest", .data = "{\"name\":\"Fluidd\"}" });
    try temp.dir.symLink(testing.io, "fluidd", "alias", .{ .is_directory = true });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", try temp.dir.realPathFileAlloc(testing.io, ".", alloc));
    const target = try Target.open(alloc, testing.io, "~/alias", &environment);
    defer target.close(testing.io);
    try testing.expectEqualStrings("fluidd", target.name);
    const source: Source = .{ .name = "fluidd", .type = .web, .owner = "fluidd-core", .repo_name = "fluidd" };
    try testing.expectEqualStrings("v1.37.7", (try target.read(alloc, testing.io, source)).version);
    try testing.expectError(error.InvalidPath, Target.open(alloc, testing.io, "~/alias", null));
    try testing.expectError(error.InvalidPath, Target.open(alloc, testing.io, "/", null));
}

test "fuzz release and cached metadata remains bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var bytes: [1024]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const body = bytes[0..smith.valueRangeAtMost(u16, 0, bytes.len)];
            _ = validRelative(body);
            _ = urlAllowed(body);
            _ = repoPartValid(body);
            _ = parseRelease(alloc, body, "") catch {};
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch return;
            _ = cachedRelease(parsed);
        }
    }.run, .{});
}

test "fuzz installed metadata cannot follow a release-info symlink" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            var body: [128]u8 = undefined;
            smith.bytesWithHash(&body, 0);
            try temp.dir.writeFile(testing.io, .{ .sub_path = "info", .data = &body });
            try temp.dir.symLink(testing.io, "info", "release_info.json", .{});
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            if (installed(arena.allocator(), testing.io, temp.dir, fixture_source)) |_| return error.TestUnexpectedResult else |_| {}
        }
    }.run, .{});
}

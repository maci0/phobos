//! Startup-only MQTT credential rendering and Moonraker secrets files.
const std = @import("std");
const ConfigParser = @import("../config/confighelper.zig").ConfigParser;
const Template = @import("sensor_template.zig").Template;
const jv = @import("../json/value.zig");

/// Secrets and deprecated password files are bounded before parsing.
const max_credential_file = 1 << 20;
const max_secret_entries = 4096;

pub const Credentials = struct {
    arena: std.heap.ArenaAllocator,
    username: ?[]const u8,
    password: ?[]const u8,

    pub fn deinit(self: *Credentials) void {
        self.arena.deinit();
    }
};

/// The result owns all rendered strings. `password` overrides `password_file`.
pub fn load(gpa: std.mem.Allocator, io: std.Io, datadir: []const u8, home: ?[]const u8, cfg: *const ConfigParser) !Credentials {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var globals: std.json.ObjectMap = .empty;
    try globals.put(a, "secrets", try loadSecrets(a, io, datadir, home, cfg.get("secrets", "secrets_path")));
    const username = if (cfg.get("mqtt", "username")) |text| try render(a, text, globals) else null;
    var password: ?[]const u8 = null;
    if (cfg.get("mqtt", "password_file")) |path| {
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, try expandPath(a, path, home), a, .limited(max_credential_file));
        if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidUtf8;
        password = std.mem.trim(u8, contents, &std.ascii.whitespace);
    }
    if (cfg.get("mqtt", "password")) |text| password = try render(a, text, globals);
    return .{ .arena = arena, .username = username, .password = password };
}

fn render(a: std.mem.Allocator, source: []const u8, globals: std.json.ObjectMap) ![]const u8 {
    var template = try Template.init(a, source);
    defer template.deinit();
    return std.mem.trim(u8, try template.renderText(a, globals, null), &std.ascii.whitespace);
}

fn expandPath(a: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return try a.dupe(u8, home orelse return error.MissingHomeDirectory);
    if (std.mem.startsWith(u8, path, "~/")) return try std.fs.path.join(a, &.{ home orelse return error.MissingHomeDirectory, path[2..] });
    if (std.mem.startsWith(u8, path, "~")) return error.UnsupportedHomeDirectory;
    return path;
}

fn optionalFile(a: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return null;
    return try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_credential_file));
}

fn loadSecrets(a: std.mem.Allocator, io: std.Io, datadir: []const u8, home: ?[]const u8, override: ?[]const u8) !std.json.Value {
    const default_path = try std.fs.path.join(a, &.{ datadir, "moonraker.secrets" });
    const bytes = (try optionalFile(a, io, default_path)) orelse if (override) |path|
        (try optionalFile(a, io, try expandPath(a, path, home))) orelse return .{ .object = .empty }
    else
        return .{ .object = .empty };
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .max_value_len = max_credential_file })) |value| {
        if (value == .object and !jv.exceedsDepth(value, jv.max_value_depth)) return value;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => return parseIni(a, bytes) catch |ini_err| switch (ini_err) {
            error.OutOfMemory, error.SecretsTooLarge => return ini_err,
            else => {
                std.debug.print("phobos: warning: invalid MQTT secrets file, expected JSON or INI\n", .{});
                return .{ .object = .empty };
            },
        },
    }
    std.debug.print("phobos: warning: MQTT JSON secrets must contain an object\n", .{});
    return .{ .object = .empty };
}

/// Secrets INI uses literal values, without the Moonraker config comment wrapper.
fn parseIni(a: std.mem.Allocator, source: []const u8) !std.json.Value {
    var parser = ConfigParser.init(a);
    defer parser.deinit();
    parser.inline_comments = false;
    parser.process_includes = false;
    try parser.parseString(source, "moonraker.secrets");
    var result: std.json.ObjectMap = .empty;
    var entries: usize = 0;
    var bytes: usize = 0;
    var sections = parser.sections_map.iterator();
    while (sections.next()) |section| {
        if (std.mem.eql(u8, section.key_ptr.*, "DEFAULT")) continue;
        var object: std.json.ObjectMap = .empty;
        if (parser.sections_map.get("DEFAULT")) |defaults| {
            var values = defaults.options.iterator();
            while (values.next()) |option| try putSecret(a, &object, option.key_ptr.*, option.value_ptr.*, &entries, &bytes);
        }
        var options = section.value_ptr.options.iterator();
        while (options.next()) |option| try putSecret(a, &object, option.key_ptr.*, option.value_ptr.*, &entries, &bytes);
        try result.put(a, try a.dupe(u8, section.key_ptr.*), .{ .object = object });
    }
    return .{ .object = result };
}

fn putSecret(a: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8, entries: *usize, bytes: *usize) !void {
    if (entries.* == max_secret_entries or key.len > max_credential_file - bytes.* or value.len > max_credential_file - bytes.* - key.len) return error.SecretsTooLarge;
    entries.* += 1;
    bytes.* += key.len + value.len;
    try object.put(a, try a.dupe(u8, key), .{ .string = try a.dupe(u8, value) });
}

test "MQTT credential files render templates and preserve inline comment characters" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const datadir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(datadir);
    try tmp.dir.writeFile(io, .{ .sub_path = "moonraker.secrets", .data = "[mqtt]\nusername: user\npassword: secret # value ; x\nliteral: a \\# b\n[include broker]\nusername: alternative\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "password", .data = " from-file\n" });
    var cfg = ConfigParser.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[mqtt]\nusername: {secrets['include broker'].username}\npassword: {secrets.mqtt.password}\npassword_file: ~/password\n", "fixture");
    var credentials = try load(std.testing.allocator, io, datadir, datadir, &cfg);
    defer credentials.deinit();
    try std.testing.expectEqualStrings("alternative", credentials.username.?);
    try std.testing.expectEqualStrings("secret # value ; x", credentials.password.?);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const secrets = try loadSecrets(arena.allocator(), io, datadir, null, null);
    try std.testing.expectEqualStrings("a \\# b", secrets.object.get("mqtt").?.object.get("literal").?.string);
}

test "MQTT credential JSON secrets override fallback and password files are checked" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const datadir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(datadir);
    try tmp.dir.writeFile(io, .{ .sub_path = "fallback.json", .data = "{\"user\":\"from-json\",\"pass\":\"value\"}" });
    var cfg = ConfigParser.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[secrets]\nsecrets_path: ~/fallback.json\n[mqtt]\nusername: {secrets.user}\npassword_file: ~/password\n", "fixture");
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, io, datadir, datadir, &cfg));
    try tmp.dir.writeFile(io, .{ .sub_path = "password", .data = " file-pass\n" });
    var credentials = try load(std.testing.allocator, io, datadir, datadir, &cfg);
    defer credentials.deinit();
    try std.testing.expectEqualStrings("from-json", credentials.username.?);
    try std.testing.expectEqualStrings("file-pass", credentials.password.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "moonraker.secrets", .data = "{\"user\":\"preferred\"}" });
    var preferred = try load(std.testing.allocator, io, datadir, datadir, &cfg);
    defer preferred.deinit();
    try std.testing.expectEqualStrings("preferred", preferred.username.?);
}

test "fuzz MQTT secrets parsing keeps bounded values valid JSON" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const value = parseIni(arena.allocator(), &bytes) catch return;
            _ = try std.json.Stringify.valueAlloc(arena.allocator(), value, .{});
        }
    }.run, .{});
}

test "MQTT secrets INI defaults inherit and explicit values override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseIni(arena.allocator(), "[DEFAULT]\nusername=default\npassword=shared\n[mqtt]\nusername=explicit\n[other]\nvalue=local\n");
    try std.testing.expect(value.object.get("DEFAULT") == null);
    try std.testing.expectEqualStrings("explicit", value.object.get("mqtt").?.object.get("username").?.string);
    try std.testing.expectEqualStrings("shared", value.object.get("mqtt").?.object.get("password").?.string);
    try std.testing.expectEqualStrings("default", value.object.get("other").?.object.get("username").?.string);
}

test "MQTT credentials release every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const datadir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(datadir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "moonraker.secrets", .data = "{\"mqtt\":{\"username\":\"user\",\"password\":\"value\"}}" });
    var cfg = ConfigParser.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[mqtt]\nusername: {secrets.mqtt.username}\npassword: {secrets.mqtt.password}\n", "fixture");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, path: []const u8, config: *const ConfigParser) !void {
            var value = try load(a, std.testing.io, path, null, config);
            defer value.deinit();
            try std.testing.expectEqualStrings("user", value.username.?);
            try std.testing.expectEqualStrings("value", value.password.?);
        }
    }.run, .{ datadir, &cfg });
}

test "MQTT secrets default expansion has an aggregate byte budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source: std.Io.Writer.Allocating = .init(arena.allocator());
    try source.writer.writeAll("[DEFAULT]\npassword=");
    try source.writer.splatByteAll('a', max_credential_file / 2);
    try source.writer.writeAll("\n[first]\na=1\n[second]\na=2\n[third]\na=3\n");
    try std.testing.expectError(error.SecretsTooLarge, parseIni(arena.allocator(), source.written()));
}

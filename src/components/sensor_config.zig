//! Owned metadata from sensor parameter_* and history_field_* dictionaries.
const std = @import("std");
const config = @import("../config/confighelper.zig");
const max_metadata_fields = 64;

pub const Metadata = struct {
    arena: std.heap.ArenaAllocator,
    parameters: std.json.Array,
    fields: std.json.Array,

    pub fn create(alloc: std.mem.Allocator, cfg: *const config.ConfigParser, section: []const u8) !*Metadata {
        const self = try alloc.create(Metadata);
        self.* = .{ .arena = .init(alloc), .parameters = undefined, .fields = undefined };
        errdefer self.destroy(alloc);
        const a = self.arena.allocator();
        self.parameters = .init(a);
        self.fields = .init(a);
        const provider = try a.dupe(u8, section);
        for (try cfg.optionNames(section, a)) |option| {
            if (std.mem.startsWith(u8, option, "parameter_")) {
                if (self.parameters.items.len >= max_metadata_fields) return error.InvalidConfig;
                var info = try parseDictionary(a, cfg.get(section, option).?);
                try info.put(a, "name", .{ .string = try a.dupe(u8, option["parameter_".len..]) });
                try self.parameters.append(.{ .object = info });
            } else if (std.mem.startsWith(u8, option, "history_field_")) {
                if (self.fields.items.len >= max_metadata_fields) return error.InvalidConfig;
                const raw = try parseDictionary(a, cfg.get(section, option).?);
                const parameter = raw.get("parameter") orelse return error.InvalidConfig;
                var field: std.json.ObjectMap = .empty;
                try field.put(a, "field", .{ .string = try a.dupe(u8, option["history_field_".len..]) });
                try field.put(a, "provider", .{ .string = provider });
                try field.put(a, "parameter", parameter);
                try field.put(a, "description", raw.get("desc") orelse .{ .string = try std.fmt.allocPrint(a, "{s} tracker", .{parameter.string}) });
                const strategy = raw.get("strategy") orelse std.json.Value{ .string = "basic" };
                const normalized = try std.ascii.allocLowerString(a, strategy.string);
                const allowed = [_][]const u8{ "basic", "delta", "accumulate", "average", "maximum", "minimum", "collect" };
                var valid = false;
                for (allowed) |name| if (std.mem.eql(u8, name, normalized)) {
                    valid = true;
                    break;
                };
                if (!valid) return error.InvalidConfig;
                try field.put(a, "strategy", .{ .string = normalized });
                try field.put(a, "units", raw.get("units") orelse .null);
                for ([_][]const u8{ "init_tracker", "exclude_paused", "report_total", "report_maximum" }) |name| {
                    const enabled = if (raw.get(name)) |value| std.ascii.eqlIgnoreCase(value.string, "true") else false;
                    try field.put(a, name, .{ .bool = enabled });
                }
                const precision: std.json.Value = if (raw.get("precision")) |value| .{ .integer = std.fmt.parseInt(i64, value.string, 10) catch return error.InvalidConfig } else .null;
                try field.put(a, "precision", precision);
                try self.fields.append(.{ .object = field });
            }
        }
        return self;
    }

    pub fn destroy(self: *Metadata, alloc: std.mem.Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

fn parseDictionary(a: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    var result: std.json.ObjectMap = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
        const key = try a.dupe(u8, std.mem.trim(u8, line[0..split], " \t\r"));
        const value = try a.dupe(u8, std.mem.trim(u8, line[split + 1 ..], " \t\r"));
        try result.put(a, key, .{ .string = value });
    }
    return result;
}

test "sensor metadata preserves parameter dictionaries and normalizes history configuration" {
    var cfg = config.ConfigParser.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[sensor env]\nparameter_temperature:\n  units = C\n  description = Air temperature\nhistory_field_peak:\n  parameter = temperature\n  strategy = MAXIMUM\n  report_maximum = true\n  precision = 2\n", "sensor.cfg");
    const metadata = try Metadata.create(std.testing.allocator, &cfg, "sensor env");
    defer metadata.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("temperature", metadata.parameters.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("Air temperature", metadata.parameters.items[0].object.get("description").?.string);
    const field = metadata.fields.items[0].object;
    try std.testing.expectEqualStrings("maximum", field.get("strategy").?.string);
    try std.testing.expectEqualStrings("sensor env", field.get("provider").?.string);
    try std.testing.expect(field.get("report_maximum").?.bool);
    try std.testing.expectEqual(@as(i64, 2), field.get("precision").?.integer);
}

test "sensor metadata rejects missing parameters and malformed dictionaries without leaking" {
    for ([_][]const u8{ "desc = no parameter", "parameter", "parameter = t\n  strategy = wrong", "parameter = t\n  precision = x" }) |value| {
        var cfg = config.ConfigParser.init(std.testing.allocator);
        defer cfg.deinit();
        const source = try std.fmt.allocPrint(std.testing.allocator, "[sensor env]\nhistory_field_test:\n  {s}\n", .{value});
        defer std.testing.allocator.free(source);
        try cfg.parseString(source, "sensor.cfg");
        try std.testing.expectError(error.InvalidConfig, Metadata.create(std.testing.allocator, &cfg, "sensor env"));
    }
}

test "fuzz sensor metadata dictionaries remain bounded and owned" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var bytes: [80]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = parseDictionary(arena.allocator(), &bytes) catch .empty;
            const strategies = [_][]const u8{ "basic", "delta", "accumulate", "average", "maximum", "minimum", "collect" };
            var cfg = config.ConfigParser.init(std.testing.allocator);
            defer cfg.deinit();
            const source = try std.fmt.allocPrint(arena.allocator(), "[sensor fuzz]\nparameter_value:\n  units = C\nhistory_field_reading:\n  parameter = value\n  strategy = {s}\n  precision = {d}\n  init_tracker = {s}\n", .{ strategies[bytes[0] % strategies.len], @as(i64, bytes[1] % 9) - 4, if (bytes[2] & 1 == 0) "true" else "false" });
            try cfg.parseString(source, "sensor.cfg");
            const metadata = try Metadata.create(std.testing.allocator, &cfg, "sensor fuzz");
            defer metadata.destroy(std.testing.allocator);
            try std.testing.expectEqualStrings("value", metadata.parameters.items[0].object.get("name").?.string);
            try std.testing.expectEqualStrings(strategies[bytes[0] % strategies.len], metadata.fields.items[0].object.get("strategy").?.string);
        }
    }.run, .{});
}

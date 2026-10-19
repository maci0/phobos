//! PanelDue line parser. Matches `moonraker/components/paneldue.py` after the
//! 2026-09-28 parser change: the checksummed script is stripped, and M23/M30/
//! M32/M36/M37/M98 keep a single filename argument only when it is non-empty.
const std = @import("std");

pub const ParseError = error{InvalidChecksum};

const file_cmds = [_][]const u8{ "M23", "M30", "M32", "M36", "M37", "M98" };

fn hasM112(line: []const u8) bool {
    if (line.len < 4) return false;
    var i: usize = 0;
    while (i + 4 <= line.len) : (i += 1) {
        const c0 = line[i];
        const m = if (c0 == 'm') 'M' else c0;
        if (m == 'M' and line[i + 1] == '1' and line[i + 2] == '1' and line[i + 3] == '2') return true;
    }
    return false;
}

fn isFileCmd(cmd: []const u8) bool {
    for (file_cmds) |c| if (std.mem.eql(u8, c, cmd)) return true;
    return false;
}

pub const PanelDue = struct {
    enable_checksum: bool = false,
    /// Parts from the last accepted line. Slices point into `line_store` after
    /// `feedBytes`, or into the caller's line after `processLine`.
    parts: [8][]const u8 = undefined,
    part_count: usize = 0,
    emergency_stop: bool = false,
    /// Last finished line from `feedBytes`. `parts` borrow this after a chunk
    /// is split, so they stay valid once the pending buffer drops the line.
    line_store: [512]u8 = undefined,

    /// Split a serial chunk on newlines and run `processLine` on each finished
    /// line. `pending` holds an incomplete trailing line between reads.
    /// A line longer than `line_store` is truncated. No serial device is opened.
    pub fn feedBytes(self: *PanelDue, alloc: std.mem.Allocator, pending: *std.ArrayList(u8), chunk: []const u8) !void {
        try pending.appendSlice(alloc, chunk);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const raw = pending.items[0..nl];
            const n = @min(raw.len, self.line_store.len);
            @memcpy(self.line_store[0..n], raw[0..n]);
            self.processLine(self.line_store[0..n]) catch |err| {
                pending.replaceRange(alloc, 0, nl + 1, &.{}) catch {};
                return err;
            };
            try pending.replaceRange(alloc, 0, nl + 1, &.{});
        }
    }

    pub fn processLine(self: *PanelDue, line: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (hasM112(trimmed)) {
            self.emergency_stop = true;
            self.part_count = 0;
            return;
        }
        const n = try parseLine(trimmed, self.enable_checksum, &self.parts);
        self.part_count = n.len;
    }
};

/// Split a PanelDue line into gcode parts.
/// `out` receives the command and, for file commands with an argument, that
/// argument (spaces preserved). Returns the slice of `out` that was filled.
pub fn parseLine(line: []const u8, enable_checksum: bool, out: [][]const u8) ParseError![]const []const u8 {
    const script = if (enable_checksum) blk: {
        const cs_index = std.mem.lastIndexOfScalar(u8, line, '*') orelse return error.InvalidChecksum;
        // Moonraker keeps a line number only when `int(line[1:space])` works.
        // Otherwise the script is everything before '*', so `M98*cs` stays M98.
        const start: usize = if (std.mem.indexOfScalar(u8, line, ' ')) |sp| inner: {
            if (sp == 0 or sp > cs_index) break :inner 0;
            _ = std.fmt.parseInt(i64, line[1..sp], 10) catch break :inner 0;
            break :inner sp + 1;
        } else 0;
        var sum: u8 = 0;
        for (line[0..cs_index]) |c| sum ^= c;
        const cs_text = std.mem.trim(u8, line[cs_index + 1 ..], " \r\n");
        const checksum = std.fmt.parseInt(u32, cs_text, 10) catch return error.InvalidChecksum;
        if ((sum & 0xFF) != checksum) return error.InvalidChecksum;
        const raw = if (start <= cs_index) line[start..cs_index] else line[0..0];
        break :blk std.mem.trim(u8, raw, " \t\r\n");
    } else line;

    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, script, " \t");
    const cmd = it.next() orelse return out[0..0];
    if (out.len == 0) return out[0..0];
    out[0] = cmd;
    n = 1;
    if (isFileCmd(cmd)) {
        if (cmd.len <= script.len) {
            const arg = std.mem.trim(u8, script[cmd.len..], " \t\r\n");
            if (arg.len > 0 and out.len > 1) {
                out[1] = arg;
                n = 2;
            }
        }
        return out[0..n];
    }
    while (it.next()) |tok| {
        if (n >= out.len) break;
        out[n] = tok;
        n += 1;
    }
    return out[0..n];
}

fn checksumLine(buf: []u8, body: []const u8) []const u8 {
    var sum: u8 = 0;
    for (body) |c| sum ^= c;
    const n = std.fmt.bufPrint(buf, "{s}*{d}", .{ body, sum }) catch return body;
    return n;
}

test "processLine: file command keeps spaces and drops an empty argument" {
    var due = PanelDue{};
    try due.processLine("M23 my file.gco");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M23", due.parts[0]);
    try std.testing.expectEqualStrings("my file.gco", due.parts[1]);

    try due.processLine("M98");
    try std.testing.expectEqual(@as(usize, 1), due.part_count);
    try std.testing.expectEqualStrings("M98", due.parts[0]);
}

test "processLine: checksummed script is stripped before the command is split" {
    var raw: [64]u8 = undefined;
    const line = checksumLine(&raw, "N10 M32  plate.gco");
    var due = PanelDue{ .enable_checksum = true };
    try due.processLine(line);
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M32", due.parts[0]);
    try std.testing.expectEqualStrings("plate.gco", due.parts[1]);
}

test "feedBytes splits a chunk on newlines and keeps the unfinished tail" {
    var due = PanelDue{};
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);
    try due.feedBytes(std.testing.allocator, &pending, "M23 my file.gco");
    try std.testing.expectEqual(@as(usize, 0), due.part_count);
    try std.testing.expectEqualStrings("M23 my file.gco", pending.items);
    try due.feedBytes(std.testing.allocator, &pending, "\n");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M23", due.parts[0]);
    try std.testing.expectEqualStrings("my file.gco", due.parts[1]);
    try std.testing.expectEqual(@as(usize, 0), pending.items.len);
    try due.feedBytes(std.testing.allocator, &pending, "M112\n");
    try std.testing.expect(due.emergency_stop);
}

test "processLine: bad checksum is rejected and M112 is emergency stop" {
    var due = PanelDue{ .enable_checksum = true };
    try std.testing.expectError(error.InvalidChecksum, due.processLine("N1 M23 f.gco*0"));
    due.enable_checksum = false;
    try due.processLine("M112");
    try std.testing.expect(due.emergency_stop);
}

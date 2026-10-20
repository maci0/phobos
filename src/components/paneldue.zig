//! PanelDue line parser, matching `process_line` in
//! `vendor/moonraker/moonraker/components/paneldue.py`: M112 anywhere is an
//! emergency stop, the checksummed script is extracted and verified, and
//! M23/M30/M32/M36/M37/M98 split into the command and one argument (possibly
//! empty). Parser only: phobos opens no PanelDue serial device, so nothing
//! outside tests feeds it lines (TODO.md).
const std = @import("std");

pub const ParseError = error{InvalidChecksum};

const file_cmds = [_][]const u8{ "M23", "M30", "M32", "M36", "M37", "M98" };

fn isFileCmd(cmd: []const u8) bool {
    for (file_cmds) |c| if (std.mem.eql(u8, c, cmd)) return true;
    return false;
}

pub const PanelDue = struct {
    enable_checksum: bool = false,
    /// Parts from the last accepted line; they borrow the caller's line.
    parts: [8][]const u8 = undefined,
    part_count: usize = 0,
    emergency_stop: bool = false,

    pub fn processLine(self: *PanelDue, line: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.ascii.findIgnoreCase(trimmed, "M112") != null) {
            self.emergency_stop = true;
            self.part_count = 0;
            return;
        }
        const n = try parseLine(trimmed, self.enable_checksum, &self.parts);
        self.part_count = n.len;
    }
};

/// Split a PanelDue line into gcode parts.
/// `out` receives the command and, for file commands, the trimmed rest of the
/// script (spaces preserved, possibly empty). Returns the filled slice of `out`.
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

    var it = std.mem.tokenizeAny(u8, script, " \t");
    const cmd = it.next() orelse return out[0..0];
    if (out.len == 0) return out[0..0];
    out[0] = cmd;
    var n: usize = 1;
    if (isFileCmd(cmd)) {
        if (out.len < 2) return out[0..1];
        out[1] = std.mem.trim(u8, it.rest(), " \t\r\n");
        return out[0..2];
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

test "processLine: file command keeps spaces and an empty argument" {
    var due = PanelDue{};
    try due.processLine("M23 my file.gco");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M23", due.parts[0]);
    try std.testing.expectEqualStrings("my file.gco", due.parts[1]);

    // paneldue.py always builds `[cmd, arg]` for file commands.
    try due.processLine("M98");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M98", due.parts[0]);
    try std.testing.expectEqualStrings("", due.parts[1]);

    var out: [2][]const u8 = undefined;
    const parts = try parseLine(" \tM32  a b ", false, &out);
    try std.testing.expectEqualStrings("a b", parts[1]);
    try std.testing.expectEqual(@as(usize, 1), (try parseLine("M32 x", false, out[0..1])).len);
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

test "processLine: bad checksum is rejected and M112 is emergency stop" {
    var due = PanelDue{ .enable_checksum = true };
    try std.testing.expectError(error.InvalidChecksum, due.processLine("N1 M23 f.gco*0"));
    due.enable_checksum = false;
    for ([_][]const u8{ "M112", "m112", "N12 m112 ; stop", "xxM112" }) |line| {
        due.emergency_stop = false;
        try due.processLine(line);
        try std.testing.expect(due.emergency_stop);
    }
}

test "fuzz processLine: arbitrary serial input preserves emergency detection" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const line = buf[0 .. smith.value(u8) % (buf.len + 1)];
            var due: PanelDue = .{};
            try due.processLine(line);
            try std.testing.expect(due.part_count <= due.parts.len);
            due.enable_checksum = true;
            due.processLine(line) catch |err| try std.testing.expectEqual(error.InvalidChecksum, err);
            var stop_buf: [buf.len + 4]u8 = undefined;
            const with_stop = try std.fmt.bufPrint(&stop_buf, "{s}m112", .{line});
            try due.processLine(with_stop);
            try std.testing.expect(due.emergency_stop);
            try std.testing.expectEqual(@as(usize, 0), due.part_count);
        }
    }.run, .{});
}

//! Config error set and configparser boolean spellings used by
//! confighelper.zig.
const std = @import("std");

pub const Error = error{
    NoSection,
    NoOption,
    ParseError,
    InvalidValue,
    OutOfMemory,
};

/// Parse a boolean from configparser-compatible strings.
/// Returns null if the value is unrecognised.
pub fn parseBool(raw: []const u8) ?bool {
    const v = std.mem.trim(u8, raw, &std.ascii.whitespace);
    // Stack-allocate a lowercase copy (max 10 bytes covers all valid tokens).
    var buf: [16]u8 = undefined;
    if (v.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..v.len], v);
    if (std.mem.eql(u8, lower, "true") or
        std.mem.eql(u8, lower, "yes") or
        std.mem.eql(u8, lower, "1") or
        std.mem.eql(u8, lower, "on")) return true;
    if (std.mem.eql(u8, lower, "false") or
        std.mem.eql(u8, lower, "no") or
        std.mem.eql(u8, lower, "0") or
        std.mem.eql(u8, lower, "off")) return false;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseBool: true spellings" {
    for (&[_][]const u8{ "true", "True", "TRUE", "yes", "YES", "Yes", "1", "on", "ON", "On" }) |s| {
        try std.testing.expect(parseBool(s).? == true);
    }
}

test "parseBool: false spellings" {
    for (&[_][]const u8{ "false", "False", "FALSE", "no", "NO", "No", "0", "off", "OFF", "Off" }) |s| {
        try std.testing.expect(parseBool(s).? == false);
    }
}

test "parseBool: invalid returns null" {
    try std.testing.expect(parseBool("maybe") == null);
    try std.testing.expect(parseBool("") == null);
    try std.testing.expect(parseBool("2") == null);
}

test "fuzz parseBool: never panics on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            // Use only the first 32 bytes as the "value" to keep it sane-ish.
            const val = buf[0..@min(32, buf.len)];
            _ = parseBool(val);
        }
    }.run, .{});
}

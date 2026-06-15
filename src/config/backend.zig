//! ConfigBackend — vtable interface for config providers.
//!
//! The default implementation is `ConfigParser` from confighelper.zig.
//! A leaner or mock backend can be swapped in by providing a different
//! implementation of the vtable.
const std = @import("std");

pub const Error = error{
    NoSection,
    NoOption,
    ParseError,
    InvalidValue,
    OutOfMemory,
};

/// Sections iterator: caller-owned slice of section-name slices.
/// Memory is owned by the backend's allocator; free via backend.freeSections.
pub const SectionList = [][]const u8;

/// Options iterator: caller-owned slice of option-name slices.
pub const OptionList = [][]const u8;

/// VTable for the ConfigBackend interface.
pub const VTable = struct {
    /// Return the raw string value for (section, option).  Returns null if missing.
    get: *const fn (self: *anyopaque, section: []const u8, option: []const u8) ?[]const u8,
    /// Check whether a section exists.
    hasSection: *const fn (self: *anyopaque, section: []const u8) bool,
    /// Check whether a (section, option) pair exists.
    hasOption: *const fn (self: *anyopaque, section: []const u8, option: []const u8) bool,
    /// List all section names.  Caller must free with freeSections.
    sections: *const fn (self: *anyopaque, alloc: std.mem.Allocator) Error!SectionList,
    /// List all option names in a section.  Caller must free with freeOptions.
    options: *const fn (self: *anyopaque, section: []const u8, alloc: std.mem.Allocator) Error!OptionList,
    /// Free a SectionList returned by sections().
    freeSections: *const fn (self: *anyopaque, alloc: std.mem.Allocator, list: SectionList) void,
    /// Free an OptionList returned by options().
    freeOptions: *const fn (self: *anyopaque, alloc: std.mem.Allocator, list: OptionList) void,
};

/// A ConfigBackend wraps a concrete implementation behind a vtable pointer.
pub const ConfigBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn get(self: ConfigBackend, section: []const u8, option: []const u8) ?[]const u8 {
        return self.vtable.get(self.ptr, section, option);
    }

    pub fn getInt(self: ConfigBackend, section: []const u8, option: []const u8) Error!i64 {
        const raw = self.get(section, option) orelse return Error.NoOption;
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        return std.fmt.parseInt(i64, trimmed, 10) catch Error.InvalidValue;
    }

    pub fn getFloat(self: ConfigBackend, section: []const u8, option: []const u8) Error!f64 {
        const raw = self.get(section, option) orelse return Error.NoOption;
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        return std.fmt.parseFloat(f64, trimmed) catch Error.InvalidValue;
    }

    /// Accepts: true/false/yes/no/1/0/on/off (case-insensitive) — same as
    /// Python configparser.getboolean().
    pub fn getBoolean(self: ConfigBackend, section: []const u8, option: []const u8) Error!bool {
        const raw = self.get(section, option) orelse return Error.NoOption;
        return parseBool(raw) orelse Error.InvalidValue;
    }

    pub fn hasSection(self: ConfigBackend, section: []const u8) bool {
        return self.vtable.hasSection(self.ptr, section);
    }

    pub fn hasOption(self: ConfigBackend, section: []const u8, option: []const u8) bool {
        return self.vtable.hasOption(self.ptr, section, option);
    }

    pub fn sections(self: ConfigBackend, alloc: std.mem.Allocator) Error!SectionList {
        return self.vtable.sections(self.ptr, alloc);
    }

    pub fn options(self: ConfigBackend, section: []const u8, alloc: std.mem.Allocator) Error!OptionList {
        return self.vtable.options(self.ptr, section, alloc);
    }

    pub fn freeSections(self: ConfigBackend, alloc: std.mem.Allocator, list: SectionList) void {
        self.vtable.freeSections(self.ptr, alloc, list);
    }

    pub fn freeOptions(self: ConfigBackend, section: []const u8, alloc: std.mem.Allocator, list: OptionList) void {
        _ = section;
        self.vtable.freeOptions(self.ptr, alloc, list);
    }
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
            const val = buf[0 .. @min(32, buf.len)];
            _ = parseBool(val);
        }
    }.run, .{});
}

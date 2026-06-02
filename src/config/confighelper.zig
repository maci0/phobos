/// confighelper.zig — configparser-compatible INI parser.
///
/// Matches Moonraker's `confighelper.py` / Python `configparser` semantics:
///
///  * Sections:   [section name]  — names may contain spaces.
///  * Options:    key: value  OR  key = value  (both separators).
///  * Comments:   lines whose first non-whitespace char is `#` or `;` are
///                skipped entirely.  Moonraker's FileSourceWrapper ALSO
///                strips inline comments preceded by at least one space
///                (` #` / ` ;`), and un-escapes ` \#` / ` \;`.
///                We reproduce that behaviour.
///  * Multi-line: a value continues on subsequent lines that are MORE
///                indented than the option key line (configparser semantics).
///  * Includes:   [include <glob>] — resolved relative to the config-file
///                dir; later writes override earlier ones (last-write wins).
///                Recursive includes are detected and rejected.
///  * Duplicate sections across files are allowed (merged); duplicate
///                sections within the same file raise ParseError (matching
///                Moonraker's FileSourceWrapper._parse_file).
///
/// Deviation from raw configparser: inline comment stripping is performed by
/// Moonraker's FileSourceWrapper wrapper, not by configparser itself (which
/// has inline_comment_prefixes unset).  We match the wrapper.
const std = @import("std");
const backend = @import("backend.zig");

pub const ConfigError = backend.Error;

// ---------------------------------------------------------------------------
// Internal data model
// ---------------------------------------------------------------------------

const Section = struct {
    name: []const u8, // owned by alloc
    options: std.StringHashMap([]const u8), // key → value (alloc-owned)
};

// ---------------------------------------------------------------------------
// ConfigParser
// ---------------------------------------------------------------------------

pub const ConfigParser = struct {
    alloc: std.mem.Allocator,
    section_order: std.ArrayListUnmanaged([]const u8),
    sections_map: std.StringHashMap(Section),

    pub fn init(alloc: std.mem.Allocator) ConfigParser {
        return .{
            .alloc = alloc,
            .section_order = .empty,
            .sections_map = std.StringHashMap(Section).init(alloc),
        };
    }

    pub fn deinit(self: *ConfigParser) void {
        // Free all section option keys and values.
        var it = self.sections_map.iterator();
        while (it.next()) |entry| {
            var oit = entry.value_ptr.options.iterator();
            while (oit.next()) |opt| {
                self.alloc.free(opt.key_ptr.*);
                self.alloc.free(opt.value_ptr.*);
            }
            entry.value_ptr.options.deinit();
            // Section name is owned; free it.  section_order also holds a
            // pointer to the same string, so only free once here.
            self.alloc.free(entry.key_ptr.*);
        }
        self.sections_map.deinit();
        // section_order items point to already-freed strings; just free the list.
        self.section_order.deinit(self.alloc);
    }

    // -----------------------------------------------------------------------
    // Public entry points
    // -----------------------------------------------------------------------

    /// Parse an INI string.  Include directives are silently ignored because
    /// there is no file-system context.
    pub fn parseString(
        self: *ConfigParser,
        source: []const u8,
        file_label: []const u8,
    ) ConfigError!void {
        var visited: std.ArrayListUnmanaged(u64) = .empty;
        defer visited.deinit(self.alloc);
        try self.parseInner(null, source, file_label, null, &visited);
    }

    /// Parse from a file path, resolving [include ...] directives.
    pub fn parseFile(
        self: *ConfigParser,
        io: std.Io,
        file_path: []const u8,
    ) ConfigError!void {
        const data = std.Io.Dir.cwd().readFileAlloc(
            io,
            file_path,
            self.alloc,
            .unlimited,
        ) catch return ConfigError.ParseError;
        defer self.alloc.free(data);

        var visited: std.ArrayListUnmanaged(u64) = .empty;
        defer visited.deinit(self.alloc);

        // Record this file's inode to detect recursive includes.
        if (std.Io.Dir.cwd().statFile(io, file_path, .{}) catch null) |st| {
            visited.append(self.alloc, st.inode) catch return ConfigError.OutOfMemory;
        }
        try self.parseInner(io, data, file_path, file_path, &visited);
    }

    // -----------------------------------------------------------------------
    // Core parser
    // -----------------------------------------------------------------------

    /// `io_opt`: null when parsing a bare string (no include support).
    /// `base_file`: if non-null, the file path used for include resolution.
    /// `visited`: inodes already seen (cycle detection).
    fn parseInner(
        self: *ConfigParser,
        io_opt: ?std.Io,
        source: []const u8,
        _file_label: []const u8,
        base_file: ?[]const u8,
        visited: *std.ArrayListUnmanaged(u64),
    ) ConfigError!void {
        _ = _file_label;

        var current_section: ?[]const u8 = null;
        var current_key: ?[]const u8 = null;
        var current_indent: usize = 0;
        var value_parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            // Free pending key (not yet flushed to the section map).
            if (current_key) |k| self.alloc.free(k);
            for (value_parts.items) |p| self.alloc.free(p);
            value_parts.deinit(self.alloc);
        }

        // Section names seen in this parse call (for dup detection within one file).
        var file_sections = std.StringHashMap(void).init(self.alloc);
        defer {
            var ki = file_sections.keyIterator();
            while (ki.next()) |k| self.alloc.free(k.*);
            file_sections.deinit();
        }

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            // Expand tabs (4-space stops — Moonraker uses expandtabs(4)).
            var tab_buf: [4096]u8 = undefined;
            const line_exp = expandTabs(raw_line, &tab_buf, 4);

            const trimmed = std.mem.trim(u8, line_exp, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#' or trimmed[0] == ';') continue;

            // Strip inline comments and unescape escaped comment chars.
            var icom_buf: [4096]u8 = undefined;
            const processed = stripInlineComment(line_exp, &icom_buf);

            const line_indent = countLeadingSpaces(processed);

            // Multi-line continuation: more indented than the key line.
            if (current_key != null and line_indent > current_indent) {
                const cont = std.mem.trim(u8, processed, &std.ascii.whitespace);
                const duped = self.alloc.dupe(u8, cont) catch return ConfigError.OutOfMemory;
                value_parts.append(self.alloc, duped) catch {
                    self.alloc.free(duped);
                    return ConfigError.OutOfMemory;
                };
                continue;
            }

            // Flush accumulated value before processing new line.
            if (current_key != null) {
                try self.flushOption(current_section.?, current_key.?, &value_parts);
                current_key = null;
                for (value_parts.items) |p| self.alloc.free(p);
                value_parts.clearRetainingCapacity();
            }

            const stripped = std.mem.trimStart(u8, processed, &std.ascii.whitespace);
            if (stripped.len == 0) continue;

            // Section header?
            if (stripped[0] == '[') {
                const close = std.mem.indexOfScalar(u8, stripped, ']') orelse
                    return ConfigError.ParseError;
                const sec_name = std.mem.trim(u8, stripped[1..close], &std.ascii.whitespace);

                // Include directive?
                if (std.mem.startsWith(u8, sec_name, "include ")) {
                    const glob_pat = std.mem.trim(u8, sec_name[8..], &std.ascii.whitespace);
                    if (glob_pat.len == 0) return ConfigError.ParseError;
                    if (io_opt) |io| {
                        if (base_file) |bf| {
                            try self.handleInclude(io, glob_pat, bf, visited);
                        }
                    }
                    current_section = null;
                    continue;
                }

                // Duplicate section within this file?
                if (file_sections.contains(sec_name)) return ConfigError.ParseError;
                const owned_for_set = self.alloc.dupe(u8, sec_name) catch return ConfigError.OutOfMemory;
                file_sections.put(owned_for_set, {}) catch {
                    self.alloc.free(owned_for_set);
                    return ConfigError.OutOfMemory;
                };

                current_section = try self.getOrCreateSection(sec_name);
                current_indent = 0;
                continue;
            }

            // Option line.
            if (current_section == null) continue; // option before any section — skip

            const sep_idx = findSeparator(stripped);
            if (sep_idx == null) {
                // Bare key (no separator) — treat as key = "".
                const key = std.mem.trim(u8, stripped, &std.ascii.whitespace);
                current_key = self.alloc.dupe(u8, key) catch return ConfigError.OutOfMemory;
                current_indent = line_indent;
                const empty = self.alloc.dupe(u8, "") catch return ConfigError.OutOfMemory;
                value_parts.append(self.alloc, empty) catch {
                    self.alloc.free(empty);
                    return ConfigError.OutOfMemory;
                };
                continue;
            }
            const key = std.mem.trim(u8, stripped[0..sep_idx.?], &std.ascii.whitespace);
            const val = std.mem.trim(u8, stripped[sep_idx.? + 1 ..], &std.ascii.whitespace);

            current_key = self.alloc.dupe(u8, key) catch return ConfigError.OutOfMemory;
            current_indent = line_indent;
            const val_duped = self.alloc.dupe(u8, val) catch return ConfigError.OutOfMemory;
            value_parts.append(self.alloc, val_duped) catch {
                self.alloc.free(val_duped);
                return ConfigError.OutOfMemory;
            };
        }

        // Flush last pending option.
        if (current_key != null) {
            try self.flushOption(current_section.?, current_key.?, &value_parts);
            current_key = null; // transferred to options map; defer must not free.
        }
    }

    fn flushOption(
        self: *ConfigParser,
        section_name: []const u8,
        key: []const u8,
        value_parts: *std.ArrayListUnmanaged([]const u8),
    ) ConfigError!void {
        const sec = self.sections_map.getPtr(section_name) orelse return;
        const joined = std.mem.join(self.alloc, "\n", value_parts.items) catch return ConfigError.OutOfMemory;
        errdefer self.alloc.free(joined);
        const gop = sec.options.getOrPut(key) catch return ConfigError.OutOfMemory;
        if (gop.found_existing) {
            // Overwrite: free old value and the new key (map keeps old key pointer).
            self.alloc.free(gop.value_ptr.*);
            self.alloc.free(key);
        }
        // If new entry, key is now owned by the map; value is set below.
        gop.value_ptr.* = joined;
    }

    fn getOrCreateSection(self: *ConfigParser, name: []const u8) ConfigError![]const u8 {
        if (self.sections_map.getKey(name)) |existing| return existing;
        const owned = self.alloc.dupe(u8, name) catch return ConfigError.OutOfMemory;
        const sec = Section{
            .name = owned,
            .options = std.StringHashMap([]const u8).init(self.alloc),
        };
        self.sections_map.put(owned, sec) catch {
            self.alloc.free(owned);
            return ConfigError.OutOfMemory;
        };
        self.section_order.append(self.alloc, owned) catch return ConfigError.OutOfMemory;
        return owned;
    }

    fn handleInclude(
        self: *ConfigParser,
        io: std.Io,
        glob_pat: []const u8,
        base_file: []const u8,
        visited: *std.ArrayListUnmanaged(u64),
    ) ConfigError!void {
        const dir_path = std.fs.path.dirname(base_file) orelse ".";

        var base_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_path: []const u8 = if (glob_pat.len > 0 and glob_pat[0] == '/')
            glob_pat
        else
            std.fmt.bufPrint(&base_path_buf, "{s}/{s}", .{ dir_path, glob_pat }) catch return ConfigError.ParseError;

        var paths = globExpandIo(self.alloc, io, base_path) catch return ConfigError.ParseError;
        defer {
            for (paths.items) |p| self.alloc.free(p);
            paths.deinit(self.alloc);
        }

        if (paths.items.len == 0) return ConfigError.ParseError;

        for (paths.items) |inc_path| {
            // Cycle detection via inode.
            const st = std.Io.Dir.cwd().statFile(io, inc_path, .{}) catch return ConfigError.ParseError;
            const inode: u64 = st.inode;
            for (visited.items) |v| {
                if (v == inode) return ConfigError.ParseError;
            }
            visited.append(self.alloc, inode) catch return ConfigError.OutOfMemory;
            defer _ = visited.pop();

            const data = std.Io.Dir.cwd().readFileAlloc(io, inc_path, self.alloc, .unlimited) catch return ConfigError.ParseError;
            defer self.alloc.free(data);
            try self.parseInner(io, data, inc_path, inc_path, visited);
        }
    }

    // -----------------------------------------------------------------------
    // Accessors
    // -----------------------------------------------------------------------

    pub fn get(self: *const ConfigParser, section: []const u8, option: []const u8) ?[]const u8 {
        const sec = self.sections_map.get(section) orelse return null;
        return sec.options.get(option);
    }

    pub fn hasSection(self: *const ConfigParser, section: []const u8) bool {
        return self.sections_map.contains(section);
    }

    pub fn hasOption(self: *const ConfigParser, section: []const u8, option: []const u8) bool {
        const sec = self.sections_map.get(section) orelse return false;
        return sec.options.contains(option);
    }

    pub fn getInt(self: *const ConfigParser, section: []const u8, option: []const u8) ConfigError!i64 {
        const raw = self.get(section, option) orelse return ConfigError.NoOption;
        return std.fmt.parseInt(i64, std.mem.trim(u8, raw, &std.ascii.whitespace), 10) catch ConfigError.InvalidValue;
    }

    pub fn getFloat(self: *const ConfigParser, section: []const u8, option: []const u8) ConfigError!f64 {
        const raw = self.get(section, option) orelse return ConfigError.NoOption;
        return std.fmt.parseFloat(f64, std.mem.trim(u8, raw, &std.ascii.whitespace)) catch ConfigError.InvalidValue;
    }

    pub fn getBoolean(self: *const ConfigParser, section: []const u8, option: []const u8) ConfigError!bool {
        const raw = self.get(section, option) orelse return ConfigError.NoOption;
        return backend.parseBool(raw) orelse ConfigError.InvalidValue;
    }

    /// Caller owns the returned slice but NOT the strings (parser-owned).
    pub fn sectionNames(self: *const ConfigParser, alloc: std.mem.Allocator) ConfigError![][]const u8 {
        const out = alloc.alloc([]const u8, self.section_order.items.len) catch return ConfigError.OutOfMemory;
        for (self.section_order.items, 0..) |s, i| out[i] = s;
        return out;
    }

    /// Caller owns the returned slice but NOT the strings.
    pub fn optionNames(self: *const ConfigParser, section: []const u8, alloc: std.mem.Allocator) ConfigError![][]const u8 {
        const sec = self.sections_map.get(section) orelse return ConfigError.NoSection;
        const out = alloc.alloc([]const u8, sec.options.count()) catch return ConfigError.OutOfMemory;
        var it = sec.options.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| {
            out[i] = k.*;
            i += 1;
        }
        return out;
    }

    // -----------------------------------------------------------------------
    // ConfigBackend vtable
    // -----------------------------------------------------------------------

    const vtable_impl = backend.VTable{
        .get = vtGet,
        .hasSection = vtHasSection,
        .hasOption = vtHasOption,
        .sections = vtSections,
        .options = vtOptions,
        .freeSections = vtFreeSlice,
        .freeOptions = vtFreeSlice,
    };

    pub fn asBackend(self: *ConfigParser) backend.ConfigBackend {
        return .{ .ptr = self, .vtable = &vtable_impl };
    }

    fn vtGet(ptr: *anyopaque, sec: []const u8, opt: []const u8) ?[]const u8 {
        return (@as(*ConfigParser, @ptrCast(@alignCast(ptr)))).get(sec, opt);
    }
    fn vtHasSection(ptr: *anyopaque, sec: []const u8) bool {
        return (@as(*ConfigParser, @ptrCast(@alignCast(ptr)))).hasSection(sec);
    }
    fn vtHasOption(ptr: *anyopaque, sec: []const u8, opt: []const u8) bool {
        return (@as(*ConfigParser, @ptrCast(@alignCast(ptr)))).hasOption(sec, opt);
    }
    fn vtSections(ptr: *anyopaque, alloc: std.mem.Allocator) backend.Error!backend.SectionList {
        return (@as(*ConfigParser, @ptrCast(@alignCast(ptr)))).sectionNames(alloc);
    }
    fn vtOptions(ptr: *anyopaque, sec: []const u8, alloc: std.mem.Allocator) backend.Error!backend.OptionList {
        return (@as(*ConfigParser, @ptrCast(@alignCast(ptr)))).optionNames(sec, alloc);
    }
    fn vtFreeSlice(ptr: *anyopaque, alloc: std.mem.Allocator, list: [][]const u8) void {
        _ = ptr;
        alloc.free(list);
    }
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn expandTabs(src: []const u8, buf: []u8, tab_size: usize) []const u8 {
    var out_len: usize = 0;
    var col: usize = 0;
    for (src) |c| {
        if (c == '\t') {
            const spaces = tab_size - (col % tab_size);
            const to_write = @min(spaces, buf.len - out_len);
            @memset(buf[out_len .. out_len + to_write], ' ');
            out_len += to_write;
            col += to_write;
        } else {
            if (out_len >= buf.len) break;
            buf[out_len] = c;
            out_len += 1;
            col += 1;
        }
    }
    return buf[0..out_len];
}

/// Strip inline comments: first ` #` or ` ;` (space + char) truncates.
/// Then unescape ` \#` → ` #` and ` \;` → ` ;`.
fn stripInlineComment(src: []const u8, buf: []u8) []const u8 {
    const copy_len = @min(src.len, buf.len);
    @memcpy(buf[0..copy_len], src[0..copy_len]);
    var work_len = copy_len;

    // Truncate at first unescaped ` #` or ` ;`.
    var i: usize = 0;
    while (i + 1 < work_len) : (i += 1) {
        if (buf[i] == ' ' and (buf[i + 1] == '#' or buf[i + 1] == ';')) {
            work_len = i;
            break;
        }
    }

    // Unescape in-place.
    var ri: usize = 0;
    var wi: usize = 0;
    while (ri < work_len) {
        if (ri + 2 < work_len and
            buf[ri] == ' ' and buf[ri + 1] == '\\' and
            (buf[ri + 2] == '#' or buf[ri + 2] == ';'))
        {
            buf[wi] = ' ';
            wi += 1;
            buf[wi] = buf[ri + 2];
            wi += 1;
            ri += 3;
        } else {
            buf[wi] = buf[ri];
            wi += 1;
            ri += 1;
        }
    }
    return buf[0..wi];
}

fn countLeadingSpaces(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') : (n += 1) {}
    return n;
}

fn findSeparator(s: []const u8) ?usize {
    return std.mem.indexOfAny(u8, s, ":=");
}

/// Glob expander using std.Io.Dir.  Returns sorted owned paths.
fn globExpandIo(
    alloc: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
) !std.ArrayListUnmanaged([]const u8) {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;

    const dir_part = std.fs.path.dirname(pattern) orelse ".";
    const file_pat = std.fs.path.basename(pattern);
    const has_wildcard = std.mem.indexOfAny(u8, file_pat, "*?") != null;

    if (!has_wildcard) {
        // Single file: verify it exists.
        std.Io.Dir.cwd().access(io, pattern, .{}) catch return result;
        const owned = try alloc.dupe(u8, pattern);
        try result.append(alloc, owned);
        return result;
    }

    var dir = std.Io.Dir.cwd().openDir(io, dir_part, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        if (globMatch(file_pat, entry.name)) {
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_part, entry.name });
            try entries.append(alloc, full);
        }
    }

    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (entries.items) |e| try result.append(alloc, e);
    entries.items.len = 0; // avoid double-free

    return result;
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= name.len) : (i += 1) {
            if (globMatch(pattern[1..], name[i..])) return true;
        }
        return false;
    }
    if (name.len == 0) return false;
    if (pattern[0] == '?' or pattern[0] == name[0]) return globMatch(pattern[1..], name[1..]);
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse: basic key:value and key=value" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[mysec]\nkey1: hello\nkey2 = world\n", "");
    try std.testing.expect(p.hasSection("mysec"));
    try std.testing.expectEqualStrings("hello", p.get("mysec", "key1").?);
    try std.testing.expectEqualStrings("world", p.get("mysec", "key2").?);
}

test "parse: section names with spaces" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[printer kinematics]\nspeed: 100\n", "");
    try std.testing.expect(p.hasSection("printer kinematics"));
    try std.testing.expectEqualStrings("100", p.get("printer kinematics", "speed").?);
}

test "parse: full-line comments ignored (#)" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\n# comment\nkey: value\n", "");
    try std.testing.expect(!p.hasOption("sec", "# comment"));
    try std.testing.expectEqualStrings("value", p.get("sec", "key").?);
}

test "parse: full-line comments ignored (;)" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\n; semicolon comment\nkey: value\n", "");
    try std.testing.expectEqualStrings("value", p.get("sec", "key").?);
}

test "parse: inline hash comment stripped" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\nkey: hello world # trailing\n", "");
    try std.testing.expectEqualStrings("hello world", p.get("sec", "key").?);
}

test "parse: inline semicolon comment stripped" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\nkey: hello ; comment\n", "");
    try std.testing.expectEqualStrings("hello", p.get("sec", "key").?);
}

test "parse: escaped inline comment not stripped" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    // " \#" should become " #", not be treated as a comment.
    try p.parseString("[sec]\nkey: hello \\# not a comment\n", "");
    try std.testing.expectEqualStrings("hello # not a comment", p.get("sec", "key").?);
}

test "parse: multiline indented continuation" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString(
        \\[test_options]
        \\test_list:
        \\    one
        \\    two
        \\    three
    , "");
    const val = p.get("test_options", "test_list").?;
    var iter = std.mem.splitScalar(u8, val, '\n');
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(std.testing.allocator);
    while (iter.next()) |l| {
        const t = std.mem.trim(u8, l, &std.ascii.whitespace);
        if (t.len > 0) try parts.append(std.testing.allocator, t);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("one", parts.items[0]);
    try std.testing.expectEqualStrings("two", parts.items[1]);
    try std.testing.expectEqualStrings("three", parts.items[2]);
}

test "parse: multiple sections" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[a]\nx: 1\n[b]\ny: 2\n", "");
    try std.testing.expectEqualStrings("1", p.get("a", "x").?);
    try std.testing.expectEqualStrings("2", p.get("b", "y").?);
}

test "parse: missing section returns null" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[a]\nx: 1\n", "");
    try std.testing.expect(p.get("b", "x") == null);
}

test "parse: missing option returns null" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[a]\nx: 1\n", "");
    try std.testing.expect(p.get("a", "nope") == null);
}

test "getInt: valid" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\ntest_int: 1\n", "");
    try std.testing.expectEqual(@as(i64, 1), try p.getInt("s", "test_int"));
}

test "getInt: missing returns NoOption" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\n", "");
    try std.testing.expectError(ConfigError.NoOption, p.getInt("s", "missing"));
}

test "getInt: bad value returns InvalidValue" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nv: not_a_number\n", "");
    try std.testing.expectError(ConfigError.InvalidValue, p.getInt("s", "v"));
}

test "getFloat: valid" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\ntest_float: 3.5\n", "");
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try p.getFloat("s", "test_float"), 1e-9);
}

test "getFloat: missing returns NoOption" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\n", "");
    try std.testing.expectError(ConfigError.NoOption, p.getFloat("s", "missing"));
}

test "getFloat: bad value returns InvalidValue" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nv: abc\n", "");
    try std.testing.expectError(ConfigError.InvalidValue, p.getFloat("s", "v"));
}

test "getBoolean: true spellings" {
    for (&[_][]const u8{ "true", "True", "TRUE", "yes", "YES", "1", "on", "ON" }) |s| {
        var p = ConfigParser.init(std.testing.allocator);
        defer p.deinit();
        const src = try std.fmt.allocPrint(std.testing.allocator, "[s]\nv: {s}\n", .{s});
        defer std.testing.allocator.free(src);
        try p.parseString(src, "");
        try std.testing.expect(try p.getBoolean("s", "v") == true);
    }
}

test "getBoolean: false spellings" {
    for (&[_][]const u8{ "false", "False", "FALSE", "no", "NO", "0", "off", "OFF" }) |s| {
        var p = ConfigParser.init(std.testing.allocator);
        defer p.deinit();
        const src = try std.fmt.allocPrint(std.testing.allocator, "[s]\nv: {s}\n", .{s});
        defer std.testing.allocator.free(src);
        try p.parseString(src, "");
        try std.testing.expect(try p.getBoolean("s", "v") == false);
    }
}

test "getBoolean: missing returns NoOption" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\n", "");
    try std.testing.expectError(ConfigError.NoOption, p.getBoolean("s", "missing"));
}

test "getBoolean: invalid returns InvalidValue" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nv: maybe\n", "");
    try std.testing.expectError(ConfigError.InvalidValue, p.getBoolean("s", "v"));
}

test "hasSection / hasOption" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\nkey: val\n", "");
    try std.testing.expect(p.hasSection("sec"));
    try std.testing.expect(!p.hasSection("other"));
    try std.testing.expect(p.hasOption("sec", "key"));
    try std.testing.expect(!p.hasOption("sec", "other"));
    try std.testing.expect(!p.hasOption("nosec", "key"));
}

test "sectionNames: parse order preserved" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[a]\n[b]\n[c]\n", "");
    const names = try p.sectionNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("a", names[0]);
    try std.testing.expectEqualStrings("b", names[1]);
    try std.testing.expectEqualStrings("c", names[2]);
}

test "optionNames: returns all option names" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\nfoo: 1\nbar: 2\n", "");
    const names = try p.optionNames("sec", std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "optionNames: missing section returns NoSection" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[sec]\n", "");
    try std.testing.expectError(ConfigError.NoSection, p.optionNames("nosec", std.testing.allocator));
}

test "parse: supplemental.conf (ported from test_config.py)" {
    // Matches vendor/moonraker/tests/assets/moonraker/supplemental.conf
    const src =
        \\[prefix_sec one]
        \\
        \\[prefix_sec two]
        \\
        \\[prefix_sec three]
        \\
        \\[test_options]
        \\test_int: 1
        \\test_float: 3.5
        \\test_bool: True
        \\test_string: Hello World
        \\test_list:
        \\    one
        \\    two
        \\    three
    ;
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString(src, "");

    try std.testing.expect(p.hasSection("prefix_sec one"));
    try std.testing.expect(p.hasSection("prefix_sec two"));
    try std.testing.expect(p.hasSection("prefix_sec three"));
    try std.testing.expect(p.hasSection("test_options"));

    // test_config.py: TestGetString.test_get_str_exists
    try std.testing.expectEqualStrings("Hello World", p.get("test_options", "test_string").?);
    // TestGetInt.test_get_int_exists
    try std.testing.expectEqual(@as(i64, 1), try p.getInt("test_options", "test_int"));
    // TestGetFloat.test_get_float_exists
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try p.getFloat("test_options", "test_float"), 1e-9);
    // TestGetBoolean.test_get_boolean_exists
    try std.testing.expect(try p.getBoolean("test_options", "test_bool") == true);
}

test "parse: malformed section header returns ParseError" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectError(ConfigError.ParseError, p.parseString("[unclosed\nkey: val\n", ""));
}

test "parse: duplicate section within same file returns ParseError" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectError(ConfigError.ParseError, p.parseString("[sec]\nkey: 1\n[sec]\nkey: 2\n", ""));
}

test "parse: include merges two files via parseFile" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "included.conf", .data = "[included]\nfoo: from_include\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.conf", .data = "[include included.conf]\n[main]\nbar: from_main\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plen = try tmp.dir.realPathFile(io, "main.conf", &path_buf);
    const main_path = path_buf[0..plen];

    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseFile(io, main_path);

    try std.testing.expect(p.hasSection("included"));
    try std.testing.expectEqualStrings("from_include", p.get("included", "foo").?);
    try std.testing.expect(p.hasSection("main"));
    try std.testing.expectEqualStrings("from_main", p.get("main", "bar").?);
}

test "parse: include glob with .inc extension merges multiple files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "part1.inc", .data = "[sec_a]\nv: 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "part2.inc", .data = "[sec_b]\nv: 2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.conf", .data = "[include *.inc]\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plen = try tmp.dir.realPathFile(io, "main.conf", &path_buf);
    const main_path = path_buf[0..plen];

    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseFile(io, main_path);

    try std.testing.expect(p.hasSection("sec_a"));
    try std.testing.expect(p.hasSection("sec_b"));
    try std.testing.expectEqualStrings("1", p.get("sec_a", "v").?);
    try std.testing.expectEqualStrings("2", p.get("sec_b", "v").?);
}

test "parse: include missing file returns ParseError" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.conf", .data = "[include nonexistent.conf]\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plen = try tmp.dir.realPathFile(io, "main.conf", &path_buf);
    const main_path = path_buf[0..plen];

    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectError(ConfigError.ParseError, p.parseFile(io, main_path));
}

test "backend interface: dispatches to ConfigParser" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nkey: 42\nbool_opt: yes\nfloat_opt: 1.5\n", "");
    const b = p.asBackend();
    try std.testing.expectEqualStrings("42", b.get("s", "key").?);
    try std.testing.expectEqual(@as(i64, 42), try b.getInt("s", "key"));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), try b.getFloat("s", "float_opt"), 1e-9);
    try std.testing.expect(try b.getBoolean("s", "bool_opt") == true);
    try std.testing.expect(b.hasSection("s"));
    try std.testing.expect(b.hasOption("s", "key"));
    const secs = try b.sections(std.testing.allocator);
    defer b.freeSections(std.testing.allocator, secs);
    try std.testing.expectEqual(@as(usize, 1), secs.len);
    const opts = try b.options("s", std.testing.allocator);
    defer b.freeOptions("s", std.testing.allocator, opts);
    try std.testing.expectEqual(@as(usize, 3), opts.len);
}

test "backend: getInt missing returns NoOption" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\n", "");
    const b = p.asBackend();
    try std.testing.expectError(backend.Error.NoOption, b.getInt("s", "missing"));
}

test "backend: getFloat invalid returns InvalidValue" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nv: bad\n", "");
    const b = p.asBackend();
    try std.testing.expectError(backend.Error.InvalidValue, b.getFloat("s", "v"));
}

test "backend: getBoolean invalid returns InvalidValue" {
    var p = ConfigParser.init(std.testing.allocator);
    defer p.deinit();
    try p.parseString("[s]\nv: nope\n", "");
    const b = p.asBackend();
    try std.testing.expectError(backend.Error.InvalidValue, b.getBoolean("s", "v"));
}

test "globMatch: patterns" {
    try std.testing.expect(globMatch("*.conf", "foo.conf"));
    try std.testing.expect(!globMatch("*.conf", "foo.txt"));
    try std.testing.expect(globMatch("*.inc", "part1.inc"));
    try std.testing.expect(!globMatch("*.inc", "part1.conf"));
    try std.testing.expect(globMatch("foo?", "foox"));
    try std.testing.expect(!globMatch("foo?", "foo"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("exact", "exact"));
    try std.testing.expect(!globMatch("exact", "inexact"));
}

test "expandTabs: tab → 4 spaces" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("    foo", expandTabs("\tfoo", &buf, 4));
}

test "expandTabs: no tabs unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", expandTabs("hello", &buf, 4));
}

test "stripInlineComment: strips space-hash" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", stripInlineComment("hello # comment", &buf));
}

test "stripInlineComment: strips space-semicolon" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", stripInlineComment("hello ; comment", &buf));
}

test "stripInlineComment: preserves escaped hash" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello # not comment", stripInlineComment("hello \\# not comment", &buf));
}

test "stripInlineComment: no comment unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("plain text", stripInlineComment("plain text", &buf));
}

test "fuzz parseString: never crashes on arbitrary input" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var p = ConfigParser.init(std.testing.allocator);
            defer p.deinit();
            _ = p.parseString(&buf, "") catch {};
        }
    }.run, .{});
}

test "fuzz getters: typed errors only, no panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = @min(@as(usize, buf[0]) + 1, 64);
            var val_clean: [64]u8 = undefined;
            for (buf[1 .. 1 + len], 0..) |c, i| {
                val_clean[i] = if (c == 0 or c == '\n') ' ' else c;
            }
            const val = val_clean[0..len];
            const src = try std.fmt.allocPrint(std.testing.allocator, "[s]\nv: {s}\n", .{val});
            defer std.testing.allocator.free(src);
            var p = ConfigParser.init(std.testing.allocator);
            defer p.deinit();
            p.parseString(src, "") catch {};
            _ = p.getInt("s", "v") catch {};
            _ = p.getFloat("s", "v") catch {};
            _ = p.getBoolean("s", "v") catch {};
        }
    }.run, .{});
}

test "fuzz globMatch: no panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const half = buf.len / 2;
            _ = globMatch(buf[0..half], buf[half..]);
        }
    }.run, .{});
}

test "fuzz stripInlineComment: no panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf_in: [256]u8 = undefined;
            var buf_out: [256]u8 = undefined;
            smith.bytesWithHash(&buf_in, 0);
            _ = stripInlineComment(&buf_in, &buf_out);
        }
    }.run, .{});
}

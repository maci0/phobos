//! Minimal RSS 2.0 XML parser.
//!
//! Extracts <item> entries from an RSS 2.0 feed. Handles CDATA sections
//! and namespace-prefixed elements. No full XML DOM — just enough for
//! the announcements feed format used by Moonraker's Moonlight service.
//!
//! Parsed entry fields:
//!   guid, title, link, description, pubDate (RFC 2822 → unix timestamp),
//!   category (priority), feed (caller-supplied)
//!
//! Usage:
//!   var parser = RssParser.init(alloc);
//!   const entries = try parser.parse(xml_data, feed_name);
//!   defer {
//!       for (entries) |entry| entry.deinit(alloc);
//!       alloc.free(entries);
//!   }

const std = @import("std");

/// One parsed RSS item with calendar date converted to Unix seconds.
pub const RssItem = struct {
    guid: []const u8 = "",
    title: []const u8 = "",
    link: []const u8 = "",
    description: []const u8 = "",
    category: []const u8 = "",
    /// Unix timestamp (UTC seconds since epoch), 0 if unparseable.
    date: f64,

    pub fn deinit(self: RssItem, alloc: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(RssItem)) |field| {
            if (@TypeOf(@field(self, field)) == []const u8) alloc.free(@field(self, field));
        }
    }
};

// ---------------------------------------------------------------------------
// Tokeniser
// ---------------------------------------------------------------------------

const TokenType = enum {
    start_tag, // <tag>
    end_tag, // </tag>
    text, // content between tags (CDATA unwrapped)
    eof,
};

const Token = struct {
    type: TokenType,
    tag: []const u8, // tag name (lowercased), empty for text/eof
    text: []const u8, // text content (for text tokens)
};

/// Lightweight zero-alloc XML tokeniser.
const Tokenizer = struct {
    src: []const u8,
    pos: usize,
    buf: [256]u8 = undefined, // scratch for tag name accumulation

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn next(self: *Tokenizer) Token {
        self.pos = std.mem.findNonePos(u8, self.src, self.pos, " \t\r\n") orelse self.src.len;
        if (self.pos >= self.src.len) return .{ .type = .eof, .tag = "", .text = "" };

        if (self.src[self.pos] == '<') {
            self.pos += 1;
            if (self.pos >= self.src.len) return .{ .type = .eof, .tag = "", .text = "" };

            if (self.src[self.pos] == '/') {
                self.pos += 1;
                const start = self.pos;
                self.pos = std.mem.findScalarPos(u8, self.src, self.pos, '>') orelse self.src.len;
                const tag = self.lowerTag(self.src[start..self.pos]);
                if (self.pos < self.src.len) self.pos += 1;
                return .{ .type = .end_tag, .tag = tag, .text = "" };
            }

            if (self.src[self.pos] == '?' or self.src[self.pos] == '!') {
                if (std.mem.startsWith(u8, self.src[self.pos..], "![CDATA[")) {
                    self.pos += 8;
                    const start = self.pos;
                    const end = std.mem.findPos(u8, self.src, self.pos, "]]>") orelse self.src.len;
                    self.pos = if (end < self.src.len) end + 3 else end;
                    return .{ .type = .text, .tag = "", .text = self.src[start..end] };
                }
                const start = self.pos;
                self.pos = std.mem.findScalarPos(u8, self.src, self.pos, '>') orelse self.src.len;
                if (self.pos < self.src.len) self.pos += 1;
                return .{ .type = .text, .tag = "", .text = self.src[start..self.pos] };
            }

            const start = self.pos;
            const end = std.mem.findAnyPos(u8, self.src, self.pos, "> \t\r\n") orelse self.src.len;
            const tag = self.lowerTag(self.src[start..end]);
            self.pos = std.mem.findScalarPos(u8, self.src, end, '>') orelse self.src.len;
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .type = .start_tag, .tag = tag, .text = "" };
        }

        const start = self.pos;
        self.pos = std.mem.findScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
        return .{ .type = .text, .tag = "", .text = self.src[start..self.pos] };
    }

    fn lowerTag(self: *Tokenizer, tag: []const u8) []const u8 {
        const n = @min(tag.len, 64);
        return std.ascii.lowerString(&self.buf, tag[0..n]);
    }
};

// ---------------------------------------------------------------------------
// RSS 2.0 parser
// ---------------------------------------------------------------------------

/// Recognised element names inside <item>.
const known_fields = std.StaticStringMap(void).initComptime(.{
    .{ "title", {} },   .{ "link", {} }, .{ "description", {} },
    .{ "pubdate", {} }, .{ "guid", {} }, .{ "category", {} },
});

pub const RssParser = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) RssParser {
        return .{ .alloc = alloc };
    }

    /// Parse RSS 2.0 XML and return owned RssItem list (caller must free).
    /// `feed_name` is the caller-supplied feed identifier stored in each item.
    pub fn parse(self: *RssParser, xml: []const u8, feed_name: []const u8) ![]RssItem {
        var tok = Tokenizer.init(xml);

        // State: depth tracking — we collect items when inside <item>.
        var depth: u8 = 0; // 0=root, 1=in channel, 2=in item
        var items: std.ArrayList(RssItem) = .empty;
        errdefer {
            for (items.items) |it| {
                it.deinit(self.alloc);
            }
            items.deinit(self.alloc);
        }
        var cur = try RssItemBuilder.init(self.alloc);
        defer cur.deinit(self.alloc);

        var field: ?[]const u8 = null;

        while (true) {
            const t = tok.next();
            switch (t.type) {
                .eof => break,
                .start_tag => {
                    if (std.mem.eql(u8, t.tag, "rss") or std.mem.eql(u8, t.tag, "channel")) {
                        if (depth == 0) depth = 1;
                    } else if (std.mem.eql(u8, t.tag, "item")) {
                        depth = 2;
                        cur.reset();
                    } else if (depth == 2 and known_fields.has(t.tag)) {
                        field = t.tag;
                    }
                },
                .end_tag => {
                    if (std.mem.eql(u8, t.tag, "item")) {
                        depth = 1;
                        if (cur.guid.items.len > 0) {
                            const item = try cur.finalize(self.alloc, feed_name);
                            errdefer item.deinit(self.alloc);
                            try items.append(self.alloc, item);
                        }
                        cur.reset();
                    } else if (std.mem.eql(u8, t.tag, "rss") or std.mem.eql(u8, t.tag, "channel")) {
                        depth = 0;
                    } else if (depth == 2) {
                        field = null;
                    }
                },
                .text => {
                    if (depth == 2 and field != null) {
                        try cur.appendField(self.alloc, field.?, t.text);
                    }
                },
            }
        }

        return items.toOwnedSlice(self.alloc);
    }
};

// ---------------------------------------------------------------------------
// Item builder (accumulates field text, converts on finalize)
// ---------------------------------------------------------------------------

const RssItemBuilder = struct {
    guid: std.ArrayList(u8),
    title: std.ArrayList(u8),
    link: std.ArrayList(u8),
    description: std.ArrayList(u8),
    category: std.ArrayList(u8),
    pub_date: std.ArrayList(u8),

    fn init(_: std.mem.Allocator) !RssItemBuilder {
        return .{
            .guid = .empty,
            .title = .empty,
            .link = .empty,
            .description = .empty,
            .category = .empty,
            .pub_date = .empty,
        };
    }

    fn deinit(self: *RssItemBuilder, alloc: std.mem.Allocator) void {
        self.guid.deinit(alloc);
        self.title.deinit(alloc);
        self.link.deinit(alloc);
        self.description.deinit(alloc);
        self.category.deinit(alloc);
        self.pub_date.deinit(alloc);
    }

    fn reset(self: *RssItemBuilder) void {
        self.guid.clearRetainingCapacity();
        self.title.clearRetainingCapacity();
        self.link.clearRetainingCapacity();
        self.description.clearRetainingCapacity();
        self.category.clearRetainingCapacity();
        self.pub_date.clearRetainingCapacity();
    }

    fn appendField(self: *RssItemBuilder, alloc: std.mem.Allocator, field: []const u8, text: []const u8) !void {
        const list: *std.ArrayList(u8) = switch (field[0]) {
            'g' => &self.guid, // guid
            't' => &self.title, // title
            'l' => &self.link, // link
            'd' => &self.description, // description
            'c' => &self.category, // category
            'p' => &self.pub_date, // pubdate
            else => return,
        };
        try list.appendSlice(alloc, text);
    }

    fn finalize(self: *RssItemBuilder, alloc: std.mem.Allocator, _: []const u8) !RssItem {
        const date = parseRfc2822(self.pub_date.items);

        var item: RssItem = .{ .date = date };
        errdefer item.deinit(alloc);
        inline for (comptime std.meta.fieldNames(RssItem)) |field| {
            if (@TypeOf(@field(item, field)) == []const u8) @field(item, field) = try alloc.dupe(u8, @field(self, field).items);
        }
        return item;
    }
};

// ---------------------------------------------------------------------------
// RFC 2822 date parser
// ---------------------------------------------------------------------------

const epoch = std.time.epoch;
const DAY_NAMES = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

/// Parse an RFC 2822 date string to Unix timestamp (UTC seconds).
/// Examples: "Mon, 15 Jan 2024 12:00:00 GMT", "15 Jan 2024 12:00:00 +0000"
fn parseRfc2822(s: []const u8) f64 {
    // Skip optional day-of-week prefix "Day, "
    var pos: usize = 0;
    for (DAY_NAMES) |day| {
        if (std.ascii.startsWithIgnoreCase(s, day)) {
            pos = if (std.mem.findScalar(u8, s, ',')) |comma| comma + 1 else 0;
            break;
        }
    }

    var tokens = std.mem.tokenizeAny(u8, s[pos..], " \t\r\n");

    // Day (1-31)
    const day_str = tokens.next() orelse return 0;
    const day_num = std.fmt.parseInt(u32, day_str, 10) catch return 0;

    // Month (3-letter)
    const month_str = tokens.next() orelse return 0;
    const month_idx = findMonth(month_str) orelse return 0;

    // Year (4-digit)
    const year_str = tokens.next() orelse return 0;
    const year = std.fmt.parseInt(epoch.Year, year_str, 10) catch return 0;
    if (year < epoch.epoch_year or day_num == 0 or day_num > epoch.getDaysInMonth(year, month_idx)) return 0;

    // Time HH:MM:SS
    const time_str = tokens.next() orelse return 0;
    const hms = parseHms(time_str) catch return 0;

    // Timezone: GMT, UT, Z, EST, EDT, CST, CDT, MST, MDT, PST, PDT, or +/-HHMM
    var tz_offset: i64 = 0;
    const tz_str = tokens.next();
    if (tz_str) |tz| {
        if (std.ascii.eqlIgnoreCase(tz, "gmt") or std.ascii.eqlIgnoreCase(tz, "ut") or std.ascii.eqlIgnoreCase(tz, "z")) {
            tz_offset = 0;
        } else if (std.ascii.eqlIgnoreCase(tz, "est")) {
            tz_offset = -5 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "edt")) {
            tz_offset = -4 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "cst")) {
            tz_offset = -6 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "cdt")) {
            tz_offset = -5 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "mst")) {
            tz_offset = -7 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "mdt")) {
            tz_offset = -6 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "pst")) {
            tz_offset = -8 * 3600;
        } else if (std.ascii.eqlIgnoreCase(tz, "pdt")) {
            tz_offset = -7 * 3600;
        } else {
            // +/-HHMM
            tz_offset = parseTzOffset(tz) catch 0;
        }
    }

    return unixFromFields(year, month_idx, day_num, hms[0], hms[1], hms[2]) - @as(f64, @floatFromInt(tz_offset));
}

fn parseHms(s: []const u8) ![3]u32 {
    var parts: [3]u32 = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    for (&parts) |*p| {
        const segment = it.next() orelse return error.InvalidDate;
        p.* = try std.fmt.parseInt(u32, segment, 10);
    }
    if (parts[0] > 23 or parts[1] > 59 or parts[2] > 60 or it.next() != null) return error.InvalidDate;
    return parts;
}

fn parseTzOffset(s: []const u8) !i64 {
    if (s.len < 3) return error.InvalidDate;
    var i: usize = 0;
    const neg = s[0] == '-';
    if (s[0] == '+' or s[0] == '-') i += 1;
    const hh = try std.fmt.parseInt(i64, s[i..][0..@min(2, s.len - i)], 10);
    i += 2;
    const mm = if (i < s.len) try std.fmt.parseInt(i64, s[i..][0..@min(2, s.len - i)], 10) else 0;
    var secs: i64 = hh * 3600 + mm * 60;
    if (neg) secs = -secs;
    return secs;
}

fn findMonth(name: []const u8) ?epoch.Month {
    if (name.len != 3) return null;
    var lower: [3]u8 = undefined;
    return std.meta.stringToEnum(epoch.Month, std.ascii.lowerString(&lower, name));
}

fn unixFromFields(year: epoch.Year, month: epoch.Month, day: u32, hour: u32, min: u32, sec: u32) f64 {
    var days: u64 = 0;
    var current_year: epoch.Year = epoch.epoch_year;
    while (current_year < year) : (current_year += 1) days += epoch.getDaysInYear(current_year);
    var current_month: u4 = 1;
    while (current_month < month.numeric()) : (current_month += 1) days += epoch.getDaysInMonth(year, @fromBackingInt(current_month));
    days += day - 1;
    return @floatFromInt(days * epoch.secs_per_day + hour * 3600 + min * 60 + sec);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "RssParser: basic RSS 2.0 feed" {
    const xml =
        \\<?xml version="1.0"?>
        \\<rss version="2.0">
        \\  <channel>
        \\    <title>Test Feed</title>
        \\    <item>
        \\      <title>Test Item</title>
        \\      <link>https://example.com/1</link>
        \\      <description>A test description</description>
        \\      <pubDate>Mon, 15 Jan 2024 12:00:00 GMT</pubDate>
        \\      <guid>https://example.com/1</guid>
        \\      <category>high</category>
        \\    </item>
        \\  </channel>
        \\</rss>
    ;

    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "testfeed");
    defer {
        for (items) |it| {
            it.deinit(testing.allocator);
        }
        testing.allocator.free(items);
    }

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("https://example.com/1", items[0].guid);
    try testing.expectEqualStrings("Test Item", items[0].title);
    try testing.expectEqualStrings("https://example.com/1", items[0].link);
    try testing.expectEqualStrings("A test description", items[0].description);
    try testing.expectEqualStrings("high", items[0].category);
    try testing.expect(items[0].date > 0);
}

test "RssParser: multiple items" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item><title>A</title><link>http://a</link><description>dA</description><pubDate>01 Jan 2024 00:00:00 GMT</pubDate><guid>gA</guid><category>low</category></item>
        \\  <item><title>B</title><link>http://b</link><description>dB</description><pubDate>02 Jan 2024 00:00:00 GMT</pubDate><guid>gB</guid><category>normal</category></item>
        \\</channel></rss>
    ;

    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "mf");
    defer {
        for (items) |it| {
            it.deinit(testing.allocator);
        }
        testing.allocator.free(items);
    }

    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("gA", items[0].guid);
    try testing.expectEqualStrings("gB", items[1].guid);
}

test "RssParser: CDATA description" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item>
        \\    <title>CDATA Test</title>
        \\    <link>http://cd</link>
        \\    <description><![CDATA[<p>Hello <b>World</b></p>]]></description>
        \\    <pubDate>15 Mar 2024 08:00:00 +0000</pubDate>
        \\    <guid>cd-guid</guid>
        \\    <category>info</category>
        \\  </item>
        \\</channel></rss>
    ;

    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "cf");
    defer {
        for (items) |it| {
            it.deinit(testing.allocator);
        }
        testing.allocator.free(items);
    }

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("<p>Hello <b>World</b></p>", items[0].description);
}

test "RssParser: item with missing fields" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item>
        \\    <guid>min-guid</guid>
        \\  </item>
        \\</channel></rss>
    ;

    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "mf");
    defer {
        for (items) |it| {
            it.deinit(testing.allocator);
        }
        testing.allocator.free(items);
    }

    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("min-guid", items[0].guid);
    try testing.expectEqualStrings("", items[0].title);
    try testing.expectEqualStrings("", items[0].link);
}

test "RssParser: empty feed returns empty slice" {
    const xml = "<rss version=\"2.0\"><channel></channel></rss>";
    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "ef");
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "RssParser: item without guid is skipped" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item><title>No GUID</title><link>http://ng</link><description>d</description><pubDate>01 Jan 2024 00:00:00 GMT</pubDate><category>x</category></item>
        \\</channel></rss>
    ;

    var p = RssParser.init(testing.allocator);
    const items = try p.parse(xml, "ngf");
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "parseRfc2822: Mon, 15 Jan 2024 12:00:00 GMT" {
    const ts = parseRfc2822("Mon, 15 Jan 2024 12:00:00 GMT");
    try testing.expect(ts > 0);
    // 2024-01-15 12:00:00 UTC = 1705320000
    try testing.expectEqual(@as(f64, 1705320000), ts);
}

test "parseRfc2822: no day-of-week" {
    const ts = parseRfc2822("15 Jan 2024 12:00:00 +0000");
    try testing.expectEqual(@as(f64, 1705320000), ts);
}

test "parseRfc2822: with timezone offset" {
    // 15 Jan 2024 07:00:00 EST = 15 Jan 2024 12:00:00 UTC
    const ts = parseRfc2822("15 Jan 2024 07:00:00 EST");
    try testing.expectEqual(@as(f64, 1705320000), ts);
}

test "parseRfc2822: invalid returns 0" {
    try testing.expectEqual(@as(f64, 0), parseRfc2822("not a date"));
    try testing.expectEqual(@as(f64, 0), parseRfc2822(""));
}

test "fuzz RssParser: random bytes never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = @as(usize, buf[0]) % buf.len;
            // Limit to ~1KB to avoid combinatorial explosion
            const input_len = @min(len, 1024);
            const input = buf[0..input_len];

            var p = RssParser.init(a);
            const items = p.parse(input, "fuzz") catch return;
            for (items) |it| it.deinit(a);
            a.free(items);
        }
    }.run, .{});
}

test "RSS parsing tolerates truncated markup" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "</", "<rss></", "<item><guid>x</guid></", "<rss><![CDATA[abc" }) |text| {
        var parser = RssParser.init(alloc);
        const items = try parser.parse(text, "test");
        defer {
            for (items) |item| item.deinit(alloc);
            alloc.free(items);
        }
        try testing.expectEqual(@as(usize, 0), items.len);
    }
    var tokenizer = Tokenizer.init("<![CDATA[abc");
    const token = tokenizer.next();
    try testing.expectEqual(TokenType.text, token.type);
    try testing.expectEqualStrings("abc", token.text);
}

test "fuzz RSS tokenization keeps truncated markup within the input" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const prefixes = [_][]const u8{ "</", "<![CDATA[", "<item>", "<?", "<" };
            const prefix = prefixes[smith.valueRangeAtMostWithHash(u8, 0, prefixes.len - 1, 1)];
            @memcpy(bytes[0..prefix.len], prefix);
            const len = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 2);
            var tokenizer = Tokenizer.init(bytes[0..len]);
            while (true) {
                const before = tokenizer.pos;
                const token = tokenizer.next();
                try testing.expect(tokenizer.pos <= len);
                if (token.type == .eof) break;
                try testing.expect(tokenizer.pos > before);
            }
        }
    }.run, .{});
}

test "RSS dates retain timestamps beyond the 32-bit Unix range" {
    try testing.expectEqual(@as(f64, 4323283200), parseRfc2822("01 Jan 2107 00:00:00 GMT"));
}

test "RSS dates reject invalid calendar fields and out-of-range years" {
    for ([_][]const u8{
        "00 Jan 2024 00:00:00 GMT",
        "31 Feb 2024 00:00:00 GMT",
        "29 Feb 2100 00:00:00 GMT",
        "01 Jan 4294967295 00:00:00 GMT",
        "01 Jan 2024 24:00:00 GMT",
    }) |input| try testing.expectEqual(@as(f64, 0), parseRfc2822(input));
}

test "RSS parsing releases partial native string copies on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn parse(alloc: std.mem.Allocator) !void {
            var parser = RssParser.init(alloc);
            const items = try parser.parse(
                "<rss><channel><item><guid>g</guid><title>title</title><link>url</link><description>body</description><category>high</category></item><item><guid>h</guid><title>next</title></item></channel></rss>",
                "feed",
            );
            defer alloc.free(items);
            defer for (items) |item| item.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), items.len);
        }
    }.parse, .{});
}

test "fuzz RSS calendar fields agree with the standard epoch calendar" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const year = smith.valueRangeAtMostWithHash(u16, 1970, 9999, 0);
            const month: epoch.Month = @fromBackingInt(smith.valueRangeAtMostWithHash(u4, 1, 12, 1));
            const seconds = unixFromFields(year, month, 1, 0, 0, 0);
            const parsed: epoch.EpochSeconds = .{ .secs = @intFromFloat(seconds) };
            const year_day = parsed.getEpochDay().calculateYearDay();
            try testing.expectEqual(year, year_day.year);
            const month_day = year_day.calculateMonthDay();
            try testing.expectEqual(month, month_day.month);
            try testing.expectEqual(@as(u5, 0), month_day.day_index);
        }
    }.run, .{});
}

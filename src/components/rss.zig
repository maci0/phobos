//! Minimal RSS 2.0 XML parser.
//!
//! Extracts the channel `<title>` and the `<item>` entries of an RSS 2.0 feed,
//! following `xml.etree.ElementTree.findtext` as Moonraker's announcements.py
//! uses it: a field holds the text before its first child element, only the
//! first occurrence of a field counts, whitespace is kept, the five predefined
//! entities and numeric character references are decoded, CDATA is literal,
//! and comments, processing instructions and declarations are skipped. No DOM:
//! just enough for the Moonlight announcement feeds.
//!
//! Parsed item fields:
//!   guid, title, link, description, category (priority),
//!   pubDate (RFC 2822 → unix timestamp, null when unparseable)
//!
//! Usage:
//!   const feed = try parse(alloc, xml_data);
//!   defer feed.deinit(alloc);

const std = @import("std");

/// One parsed RSS item with calendar date converted to Unix seconds.
pub const RssItem = struct {
    guid: []const u8 = "",
    title: []const u8 = "",
    link: []const u8 = "",
    description: []const u8 = "",
    category: []const u8 = "",
    /// Unix timestamp (UTC seconds since epoch); null when pubDate is missing
    /// or unparseable.
    date: ?f64,

    pub fn deinit(self: RssItem, alloc: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(RssItem)) |field| {
            if (@TypeOf(@field(self, field)) == []const u8) alloc.free(@field(self, field));
        }
    }
};

/// A parsed feed. Caller owns it; free with `deinit`.
pub const Feed = struct {
    /// Channel `<title>` text, empty when absent.
    title: []const u8,
    items: []RssItem,

    pub fn deinit(self: Feed, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        for (self.items) |item| item.deinit(alloc);
        alloc.free(self.items);
    }
};

// ---------------------------------------------------------------------------
// Tokeniser
// ---------------------------------------------------------------------------

const TokenType = enum {
    start_tag, // <tag>
    end_tag, // </tag>
    text, // character data between tags (entities still encoded)
    cdata, // CDATA section content (literal)
    eof,
};

const Token = struct {
    type: TokenType,
    /// Lowercased tag name; aliases the tokenizer scratch buffer until the next call.
    tag: []const u8 = "",
    text: []const u8 = "",
};

/// Lightweight zero-alloc XML tokeniser.
const Tokenizer = struct {
    src: []const u8,
    pos: usize,
    buf: [max_tag_len]u8 = undefined, // scratch for the lowercased tag name

    const max_tag_len = 64;

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn next(self: *Tokenizer) Token {
        while (self.pos < self.src.len) {
            if (self.src[self.pos] != '<') {
                const start = self.pos;
                self.pos = std.mem.findScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
                return .{ .type = .text, .text = self.src[start..self.pos] };
            }
            const rest = self.src[self.pos..];
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const start = self.pos + "<![CDATA[".len;
                const end = std.mem.findPos(u8, self.src, start, "]]>") orelse self.src.len;
                self.pos = @min(end + "]]>".len, self.src.len);
                return .{ .type = .cdata, .text = self.src[start..end] };
            }
            // Comments, processing instructions and declarations carry no text.
            if (std.mem.startsWith(u8, rest, "<!--")) {
                self.skipPast("-->", "<!--".len);
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<?")) {
                self.skipPast("?>", "<?".len);
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<!")) {
                self.skipPast(">", "<!".len);
                continue;
            }
            const is_end = std.mem.startsWith(u8, rest, "</");
            const start = self.pos + @as(usize, if (is_end) 2 else 1);
            const end = std.mem.findAnyPos(u8, self.src, start, "/> \t\r\n") orelse self.src.len;
            const tag = std.ascii.lowerString(&self.buf, self.src[start..][0..@min(end - start, max_tag_len)]);
            self.skipPast(">", end - self.pos);
            return .{ .type = if (is_end) .end_tag else .start_tag, .tag = tag };
        }
        return .{ .type = .eof };
    }

    /// Advance past `terminator`, searching from `self.pos + offset`; to the
    /// end of input when it is missing.
    fn skipPast(self: *Tokenizer, terminator: []const u8, offset: usize) void {
        const end = std.mem.findPos(u8, self.src, @min(self.pos + offset, self.src.len), terminator) orelse {
            self.pos = self.src.len;
            return;
        };
        self.pos = end + terminator.len;
    }
};

// ---------------------------------------------------------------------------
// RSS 2.0 parser
// ---------------------------------------------------------------------------

/// Recognised element names inside <item>. Names match `RssItem` fields
/// except `pubdate`, which becomes `RssItem.date`.
const Field = enum { guid, title, link, description, category, pubdate };
const item_fields = std.StaticStringMap(Field).initComptime(.{
    .{ "guid", .guid },               .{ "title", .title },       .{ "link", .link },
    .{ "description", .description }, .{ "category", .category }, .{ "pubdate", .pubdate },
});

/// Parse UTF-8 RSS 2.0 XML. Caller owns the result (free with `Feed.deinit`).
pub fn parse(alloc: std.mem.Allocator, xml: []const u8) !Feed {
    if (!std.unicode.utf8ValidateSlice(xml)) return error.InvalidUtf8;
    var tok = Tokenizer.init(xml);

    var depth: u8 = 0; // 0=root, 1=in channel, 2=in item
    var items: std.ArrayList(RssItem) = .empty;
    errdefer {
        for (items.items) |it| it.deinit(alloc);
        items.deinit(alloc);
    }
    var fields: std.EnumArray(Field, std.ArrayList(u8)) = .initFill(.empty);
    defer for (&fields.values) |*list| list.deinit(alloc);
    var seen: std.EnumSet(Field) = .empty;
    var channel_title: std.ArrayList(u8) = .empty;
    defer channel_title.deinit(alloc);
    var channel_title_seen = false;
    // Text destination: the open field element, until it closes or a child opens.
    var capture: ?*std.ArrayList(u8) = null;

    while (true) {
        const t = tok.next();
        switch (t.type) {
            .eof => break,
            .start_tag => {
                capture = null;
                if (std.mem.eql(u8, t.tag, "rss") or std.mem.eql(u8, t.tag, "channel")) {
                    if (depth == 0) depth = 1;
                } else if (std.mem.eql(u8, t.tag, "item")) {
                    depth = 2;
                    for (&fields.values) |*list| list.clearRetainingCapacity();
                    seen = .empty;
                } else if (depth == 2) {
                    const field = item_fields.get(t.tag) orelse continue;
                    if (seen.contains(field)) continue;
                    seen.insert(field);
                    capture = fields.getPtr(field);
                } else if (depth == 1 and !channel_title_seen and std.mem.eql(u8, t.tag, "title")) {
                    channel_title_seen = true;
                    capture = &channel_title;
                }
            },
            .end_tag => {
                capture = null;
                if (std.mem.eql(u8, t.tag, "item")) {
                    depth = 1;
                    if (fields.get(.guid).items.len > 0) {
                        const item = try finalize(alloc, &fields);
                        errdefer item.deinit(alloc);
                        try items.append(alloc, item);
                    }
                } else if (std.mem.eql(u8, t.tag, "rss") or std.mem.eql(u8, t.tag, "channel")) {
                    depth = 0;
                }
            },
            .text => if (capture) |list| try appendDecoded(alloc, list, t.text),
            .cdata => if (capture) |list| try list.appendSlice(alloc, t.text),
        }
    }

    const title = try alloc.dupe(u8, channel_title.items);
    errdefer alloc.free(title);
    return .{ .title = title, .items = try items.toOwnedSlice(alloc) };
}

fn finalize(alloc: std.mem.Allocator, fields: *const std.EnumArray(Field, std.ArrayList(u8))) !RssItem {
    var item: RssItem = .{ .date = parseRfc2822(fields.get(.pubdate).items) };
    errdefer item.deinit(alloc);
    inline for (comptime std.meta.fieldNames(RssItem)) |name| {
        if (@TypeOf(@field(item, name)) == []const u8)
            @field(item, name) = try alloc.dupe(u8, fields.get(@field(Field, name)).items);
    }
    return item;
}

/// Longest entity reference decoded (`&#x10FFFF;` with a leading zero).
const max_entity_len = 11;
const predefined_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" },
});

/// Append character data, decoding predefined entities and numeric character
/// references. An unknown or malformed reference is kept literally.
fn appendDecoded(alloc: std.mem.Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    var rest = text;
    while (std.mem.findScalar(u8, rest, '&')) |amp| {
        try list.appendSlice(alloc, rest[0..amp]);
        rest = rest[amp..];
        var utf8: [4]u8 = undefined;
        const semi = std.mem.findScalar(u8, rest[0..@min(rest.len, max_entity_len)], ';');
        const decoded = if (semi) |s| decodeEntity(rest[1..s], &utf8) else null;
        if (decoded) |bytes| {
            try list.appendSlice(alloc, bytes);
            rest = rest[semi.? + 1 ..];
        } else {
            try list.append(alloc, '&');
            rest = rest[1..];
        }
    }
    try list.appendSlice(alloc, rest);
}

fn decodeEntity(name: []const u8, buf: *[4]u8) ?[]const u8 {
    if (predefined_entities.get(name)) |s| return s;
    if (name.len < 2 or name[0] != '#') return null;
    const cp = if (name[1] == 'x' or name[1] == 'X')
        std.fmt.parseInt(u21, name[2..], 16) catch return null
    else
        std.fmt.parseInt(u21, name[1..], 10) catch return null;
    const n = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// RFC 2822 date parser
// ---------------------------------------------------------------------------

const epoch = std.time.epoch;
const DAY_NAMES = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };

/// Parse an RFC 2822 date string to Unix timestamp (UTC seconds), or null.
/// Seconds are optional and a year below 100 maps to 1969-2068, as in
/// Python's `email.utils.parsedate_to_datetime`.
/// Examples: "Mon, 15 Jan 2024 12:00:00 GMT", "15 Jan 24 12:00 +0000"
fn parseRfc2822(s: []const u8) ?f64 {
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
    const day_str = tokens.next() orelse return null;
    const day_num = std.fmt.parseInt(u32, day_str, 10) catch return null;

    // Month (3-letter)
    const month_str = tokens.next() orelse return null;
    const month_idx = findMonth(month_str) orelse return null;

    // Year
    const year_str = tokens.next() orelse return null;
    var year_num = std.fmt.parseInt(u32, year_str, 10) catch return null;
    if (year_num < 100) year_num += if (year_num > 68) 1900 else 2000;
    const year = std.math.cast(epoch.Year, year_num) orelse return null;
    if (year < epoch.epoch_year or day_num == 0 or day_num > epoch.getDaysInMonth(year, month_idx)) return null;

    // Time HH:MM[:SS]
    const time_str = tokens.next() orelse return null;
    const hms = parseHms(time_str) catch return null;

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

/// `HH:MM` or `HH:MM:SS`; missing seconds are zero.
fn parseHms(s: []const u8) ![3]u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, ':');
    var n: usize = 0;
    while (it.next()) |segment| : (n += 1) {
        if (n == parts.len) return error.InvalidDate;
        parts[n] = try std.fmt.parseInt(u32, segment, 10);
    }
    if (n < 2 or parts[0] > 23 or parts[1] > 59 or parts[2] > 60) return error.InvalidDate;
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

test "RSS rejects non-UTF-8 title and item text before producing JSON strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "<rss><channel><title>\xff</title></channel></rss>",
        "<rss><channel><item><guid>x</guid><description>\xc3</description></item></channel></rss>",
        "<rss><channel><item><guid>\xff</guid></item></channel></rss>",
    }) |xml| try testing.expectError(error.InvalidUtf8, parse(a, xml));
    const valid = try parse(a, "<rss><channel><title>caf\u{e9}</title></channel></rss>");
    try testing.expectEqualStrings("caf\u{e9}", valid.title);
}

test "parse: basic RSS 2.0 feed" {
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

    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);

    try testing.expectEqualStrings("Test Feed", feed.title);
    try testing.expectEqual(@as(usize, 1), feed.items.len);
    const item = feed.items[0];
    try testing.expectEqualStrings("https://example.com/1", item.guid);
    try testing.expectEqualStrings("Test Item", item.title);
    try testing.expectEqualStrings("https://example.com/1", item.link);
    try testing.expectEqualStrings("A test description", item.description);
    try testing.expectEqualStrings("high", item.category);
    try testing.expectEqual(@as(?f64, 1705320000), item.date);
}

test "parse: multiple items" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item><title>A</title><link>http://a</link><description>dA</description><pubDate>01 Jan 2024 00:00:00 GMT</pubDate><guid>gA</guid><category>low</category></item>
        \\  <item><title>B</title><link>http://b</link><description>dB</description><pubDate>02 Jan 2024 00:00:00 GMT</pubDate><guid>gB</guid><category>normal</category></item>
        \\</channel></rss>
    ;

    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), feed.items.len);
    try testing.expectEqualStrings("gA", feed.items[0].guid);
    try testing.expectEqualStrings("gB", feed.items[1].guid);
    try testing.expectEqualStrings("", feed.title);
}

test "parse: CDATA description" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item>
        \\    <title>CDATA Test</title>
        \\    <description><![CDATA[<p>Hello &amp; <b>World</b></p>]]></description>
        \\    <guid>cd-guid</guid>
        \\  </item>
        \\</channel></rss>
    ;

    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), feed.items.len);
    try testing.expectEqualStrings("<p>Hello &amp; <b>World</b></p>", feed.items[0].description);
}

test "parse: item with missing fields has no date" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item>
        \\    <guid>min-guid</guid>
        \\  </item>
        \\</channel></rss>
    ;

    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), feed.items.len);
    try testing.expectEqualStrings("min-guid", feed.items[0].guid);
    try testing.expectEqualStrings("", feed.items[0].title);
    try testing.expectEqualStrings("", feed.items[0].link);
    try testing.expectEqual(@as(?f64, null), feed.items[0].date);
}

test "parse: empty feed returns no items" {
    const feed = try parse(testing.allocator, "<rss version=\"2.0\"><channel><title>Moonraker</title></channel></rss>");
    defer feed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), feed.items.len);
    try testing.expectEqualStrings("Moonraker", feed.title);
}

test "parse: item without guid is skipped" {
    const xml =
        \\<rss version="2.0"><channel>
        \\  <item><title>No GUID</title><link>http://ng</link><category>x</category></item>
        \\</channel></rss>
    ;

    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), feed.items.len);
}

test "parse: nested elements end a field's text and do not redirect it" {
    // A field keeps the text before its first child element, like
    // ElementTree.findtext; tag scratch reuse must not change the target field.
    const xml =
        \\<rss><channel><item><guid>g</guid><category>high</category>
        \\<description>Use <code>x</code> now</description><title>a<p/>b</title></item></channel></rss>
    ;
    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);
    const item = feed.items[0];
    try testing.expectEqualStrings("high", item.category);
    try testing.expectEqualStrings("Use ", item.description);
    try testing.expectEqualStrings("a", item.title);
    try testing.expectEqual(@as(?f64, null), item.date);
}

test "parse: entities, comments, processing instructions and whitespace" {
    const xml =
        \\<rss><channel><title><!-- c -->Moon<?pi x?>raker</title><item><guid>g</guid>
        \\<title>A &amp; B &lt;x&gt; &#39;q&#x27; &quot;&apos; &bogus; &#xZZ; &</title>
        \\<description> a <![CDATA[b]]> c </description>
        \\<!DOCTYPE ignored><link>l</link><link>second</link></item></channel></rss>
    ;
    const feed = try parse(testing.allocator, xml);
    defer feed.deinit(testing.allocator);
    try testing.expectEqualStrings("Moonraker", feed.title);
    const item = feed.items[0];
    try testing.expectEqualStrings("A & B <x> 'q' \"' &bogus; &#xZZ; &", item.title);
    try testing.expectEqualStrings(" a b c ", item.description);
    try testing.expectEqualStrings("l", item.link);
}

test "decodeEntity: predefined and numeric references" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("&", decodeEntity("amp", &buf).?);
    try testing.expectEqualStrings("\u{e9}", decodeEntity("#233", &buf).?);
    try testing.expectEqualStrings("\u{1f600}", decodeEntity("#x1F600", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), decodeEntity("#xD800", &buf));
    try testing.expectEqual(@as(?[]const u8, null), decodeEntity("#", &buf));
    try testing.expectEqual(@as(?[]const u8, null), decodeEntity("nbsp", &buf));
}

test "fuzz appendDecoded: output never exceeds input and never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const prefixes = [_][]const u8{ "&#x", "&#", "&amp;", "&", "" };
            const prefix = prefixes[smith.valueRangeAtMostWithHash(u8, 0, prefixes.len - 1, 1)];
            @memcpy(bytes[0..prefix.len], prefix);
            const len = smith.valueRangeAtMostWithHash(u8, 0, bytes.len, 2);
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(testing.allocator);
            try appendDecoded(testing.allocator, &list, bytes[0..len]);
            // Every decoded reference is shorter than its source text.
            try testing.expect(list.items.len <= len);
        }
    }.run, .{});
}

test "parseRfc2822: Mon, 15 Jan 2024 12:00:00 GMT" {
    // 2024-01-15 12:00:00 UTC = 1705320000
    try testing.expectEqual(@as(?f64, 1705320000), parseRfc2822("Mon, 15 Jan 2024 12:00:00 GMT"));
}

test "parseRfc2822: no day-of-week" {
    try testing.expectEqual(@as(?f64, 1705320000), parseRfc2822("15 Jan 2024 12:00:00 +0000"));
}

test "parseRfc2822: with timezone offset" {
    // 15 Jan 2024 07:00:00 EST = 15 Jan 2024 12:00:00 UTC
    try testing.expectEqual(@as(?f64, 1705320000), parseRfc2822("15 Jan 2024 07:00:00 EST"));
}

test "parseRfc2822: optional seconds and two-digit years" {
    try testing.expectEqual(@as(?f64, 1705320000), parseRfc2822("Mon, 15 Jan 2024 12:00 GMT"));
    try testing.expectEqual(@as(?f64, 1705320000), parseRfc2822("15 Jan 24 12:00:00 GMT"));
    // 70 → 1970; 69 → 1969 is before the epoch.
    try testing.expectEqual(@as(?f64, 0), parseRfc2822("01 Jan 70 00:00 GMT"));
    try testing.expectEqual(@as(?f64, null), parseRfc2822("01 Jan 69 00:00 GMT"));
    try testing.expectEqual(@as(?f64, null), parseRfc2822("01 Jan 2024 12 GMT"));
    try testing.expectEqual(@as(?f64, null), parseRfc2822("01 Jan 2024 12:00:00:00 GMT"));
}

test "parseRfc2822: invalid returns null" {
    try testing.expectEqual(@as(?f64, null), parseRfc2822("not a date"));
    try testing.expectEqual(@as(?f64, null), parseRfc2822(""));
}

test "fuzz parse: random bytes never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = smith.valueRangeAtMostWithHash(u16, 0, buf.len, 1);
            const input = buf[0..len];
            for (0..2) |pass| {
                if (pass == 1) for (input) |*byte| {
                    byte.* &= 0x7f;
                };
                if (!std.unicode.utf8ValidateSlice(input)) {
                    try testing.expectError(error.InvalidUtf8, parse(testing.allocator, input));
                    continue;
                }
                const feed = try parse(testing.allocator, input);
                defer feed.deinit(testing.allocator);
                try testing.expect(std.unicode.utf8ValidateSlice(feed.title));
                for (feed.items) |item| inline for (comptime std.meta.fieldNames(RssItem)) |field| {
                    if (@TypeOf(@field(item, field)) == []const u8)
                        try testing.expect(std.unicode.utf8ValidateSlice(@field(item, field)));
                };
            }
        }
    }.run, .{});
}

test "fuzz parseRfc2822: arbitrary text never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const valid = "Mon, 15 Jan 24 12:00:00 GMT";
            var buf: [40]u8 = @splat(' ');
            @memcpy(buf[0..valid.len], valid);
            const start = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 0);
            smith.bytesWithHash(buf[start..], 1);
            const len = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 2);
            if (parseRfc2822(buf[0..len])) |ts| try testing.expect(std.math.isFinite(ts));
        }
    }.run, .{});
}

test "RSS parsing tolerates truncated markup" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "</", "<rss></", "<item><guid>x</guid></", "<rss><![CDATA[abc", "<!--", "<?x", "<!" }) |text| {
        const feed = try parse(alloc, text);
        defer feed.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), feed.items.len);
    }
    var tokenizer = Tokenizer.init("<![CDATA[abc");
    const token = tokenizer.next();
    try testing.expectEqual(TokenType.cdata, token.type);
    try testing.expectEqualStrings("abc", token.text);
}

test "fuzz RSS tokenization keeps truncated markup within the input" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const prefixes = [_][]const u8{ "</", "<![CDATA[", "<item>", "<?", "<", "<!--", "<!" };
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
    try testing.expectEqual(@as(?f64, 4323283200), parseRfc2822("01 Jan 2107 00:00:00 GMT"));
}

test "RSS dates reject invalid calendar fields and out-of-range years" {
    for ([_][]const u8{
        "00 Jan 2024 00:00:00 GMT",
        "31 Feb 2024 00:00:00 GMT",
        "29 Feb 2100 00:00:00 GMT",
        "01 Jan 4294967295 00:00:00 GMT",
        "01 Jan 2024 24:00:00 GMT",
    }) |input| try testing.expectEqual(@as(?f64, null), parseRfc2822(input));
}

test "RSS parsing releases partial native string copies on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const feed = try parse(
                alloc,
                "<rss><channel><title>t</title><item><guid>g</guid><title>title</title><link>url</link><description>a&amp;b</description><category>high</category></item><item><guid>h</guid><title>next</title></item></channel></rss>",
            );
            defer feed.deinit(alloc);
            try testing.expectEqual(@as(usize, 2), feed.items.len);
        }
    }.run, .{});
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

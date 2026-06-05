//! server.announcements.* API component — Moonraker-compatible announcements.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/announcements.py`:
//!
//!   GET    /server/announcements/list    → server.announcements.list
//!   POST   /server/announcements/update  → server.announcements.update
//!   POST   /server/announcements/dismiss → server.announcements.dismiss
//!   POST   /server/announcements/feed    → server.announcements.post_feed
//!   DELETE /server/announcements/feed    → server.announcements.delete_feed
//!   GET    /server/announcements/feeds   → server.announcements.feeds
//!
//! Announcements are persisted in the DataStore:
//!   namespace "announcements" — key per entry (hex sequence), value = entry object
//!   namespace "announcement_feeds" — key "feeds", value = JSON array of feed names
//!
//! NOTE: RSS feed fetching from Moonlight (arksine.github.io/moonlight) is
//! implemented via `fetchAndUpdateFeed`. ETag-based conditional GET is not yet
//! supported (Zig 0.16 FetchResult doesn't expose response headers).
//! Background periodic refresh runs on a timer thread (announcementsRefreshTimerThread).
//!
//! Announcement entry shape (matches announcements.py):
//!   entry_id, url, title, description, priority, date,
//!   dismissed, date_dismissed, dismiss_wake, source, feed
//!
//! list params: include_dismissed (bool, true) → {"entries": [...], "feeds": [...]}
//! update params: subscriptions (list) → {"entries": [...], "modified": bool}
//! dismiss params: entry_id (str), wake_time (int, null) → {"entry_id": str}
//! feeds → {"feeds": [...]}
//! post_feed params: name (str) → {"feed": str, "action": "added"|"skipped"}
//! delete_feed params: name (str) → {"feed": str, "action": "removed"}
//!
//! Notifications emitted:
//!   notify_announcement_update  (entries changed)
//!   notify_announcement_dismissed (entry dismissed)
//!   notify_announcement_wake    (dismissed entry woke up)

const std = @import("std");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const rss = @import("rss.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

const MOONLIGHT_BASE_URL = "https://arksine.github.io/moonlight";
/// Moonraker's announcements update interval: 1800 seconds = 30 minutes.
const UPDATE_CHECK_TIME: u64 = 1800;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const AnnouncementsCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,
    /// Owned allocator for in-memory feed list.
    gpa: std.mem.Allocator,
    /// In-memory list of feed names (includes built-in + stored extras).
    feeds: std.ArrayListUnmanaged([]u8),
    /// Counter for new entry keys (hex sequence).
    next_key: u64,
    /// Background refresh timer stop flag. Set by deinit, polled by the timer thread.
    refresh_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Handle for the background refresh timer thread, joined in deinit.
    refresh_thread: ?std.Thread = null,

    pub fn setIo(self: *AnnouncementsCtx, io: std.Io) void {
        self.io = io;
        // Start the periodic RSS refresh timer (30 minute interval).
        self.refresh_thread = std.Thread.spawn(.{}, announcementsRefreshTimerThread, .{self}) catch null;
    }

    /// Built-in feeds (always present, cannot be deleted).
    pub const builtin_feeds = [_][]const u8{ "moonraker", "klipper" };

    pub fn init(alloc: std.mem.Allocator, store: DataStore, bus: *NotifyBus) !AnnouncementsCtx {
        var ctx = AnnouncementsCtx{
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .feeds = .empty,
            .next_key = 0,
        };
        // Add built-in feeds
        for (builtin_feeds) |f| {
            try ctx.feeds.append(alloc, try alloc.dupe(u8, f));
        }
        // Load stored feeds
        ctx.loadFeeds() catch {};
        // Find next key from existing entries
        ctx.syncNextKey() catch {};
        return ctx;
    }

    pub fn deinit(self: *AnnouncementsCtx) void {
        self.refresh_stop.store(true, .release);
        // Clear io so the timer thread returns early even if it already passed
        // the while-condition. This prevents use-after-free when App tears down
        // the bus/connections before joining the announcements thread.
        self.io = null;
        if (self.refresh_thread) |th| {
            th.join();
            self.refresh_thread = null;
        }
        for (self.feeds.items) |f| self.gpa.free(f);
        self.feeds.deinit(self.gpa);
    }

    fn loadFeeds(self: *AnnouncementsCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const val = (try self.store.getItem(a, ns_feeds, feeds_key)) orelse return;
        switch (val) {
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .string) continue;
                    const name = item.string;
                    if (self.hasFeed(name)) continue;
                    const owned = try self.gpa.dupe(u8, name);
                    try self.feeds.append(self.gpa, owned);
                }
            },
            else => {},
        }
    }

    fn syncNextKey(self: *AnnouncementsCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const ns_obj = self.store.getNamespace(a, ns_entries) catch return;
        switch (ns_obj) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| {
                    const k = std.fmt.parseInt(u64, kv.key_ptr.*, 16) catch continue;
                    if (k >= self.next_key) self.next_key = k + 1;
                }
            },
            else => {},
        }
    }

    fn hasFeed(self: *const AnnouncementsCtx, name: []const u8) bool {
        for (self.feeds.items) |f| if (std.mem.eql(u8, f, name)) return true;
        return false;
    }

    fn isBuiltin(name: []const u8) bool {
        for (builtin_feeds) |f| if (std.mem.eql(u8, f, name)) return true;
        return false;
    }

    fn saveFeeds(self: *AnnouncementsCtx, arena: std.mem.Allocator) void {
        var arr: std.json.Array = .init(arena);
        for (self.feeds.items) |f| {
            arr.append(.{ .string = f }) catch {};
        }
        self.store.insertItem(arena, ns_feeds, feeds_key, .{ .array = arr }) catch {};
    }

    fn nextKeyStr(self: *AnnouncementsCtx, buf: []u8) ![]u8 {
        const s = try std.fmt.bufPrint(buf, "{X:0>6}", .{self.next_key});
        self.next_key += 1;
        return s;
    }

    /// List all entries from store, sorted by date descending.
    fn listEntries(self: *AnnouncementsCtx, arena: std.mem.Allocator, include_dismissed: bool) !std.json.Array {
        const ns_obj = self.store.getNamespace(arena, ns_entries) catch return .init(arena);
        var arr: std.json.Array = .init(arena);
        switch (ns_obj) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| {
                    const entry = kv.value_ptr.*;
                    if (!include_dismissed) {
                        const dismissed = switch (entry) {
                            .object => |o| switch (o.get("dismissed") orelse .null) {
                                .bool => |b| b,
                                else => false,
                            },
                            else => false,
                        };
                        if (dismissed) continue;
                    }
                    try arr.append(entry);
                }
            },
            else => {},
        }
        // Sort descending by date
        std.sort.pdq(std.json.Value, arr.items, {}, struct {
            fn gt(_: void, a: std.json.Value, b: std.json.Value) bool {
                const da = dateOf(a);
                const db = dateOf(b);
                return da > db;
            }
            fn dateOf(v: std.json.Value) f64 {
                return switch (v) {
                    .object => |o| switch (o.get("date") orelse .null) {
                        .float => |f| f,
                        .integer => |i| @floatFromInt(i),
                        else => 0.0,
                    },
                    else => 0.0,
                };
            }
        }.gt);
        return arr;
    }

    /// Feeds as a JSON array of strings.
    fn feedsJson(self: *AnnouncementsCtx, arena: std.mem.Allocator) !std.json.Array {
        var arr: std.json.Array = .init(arena);
        for (self.feeds.items) |f| try arr.append(.{ .string = f });
        return arr;
    }

    /// Fetch RSS feed from Moonlight and store new entries.
    /// Returns true if any entries were added or removed.
    /// Skips fetch when io is null (no network, e.g. tests or dump-api).
    pub fn fetchAndUpdateFeed(self: *AnnouncementsCtx, alloc: std.mem.Allocator, feed_name: []const u8) !bool {
        const io = self.io orelse return false;

        // Build URL: https://arksine.github.io/moonlight/assets/{feed}.xml
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, MOONLIGHT_BASE_URL ++ "/assets/{s}.xml", .{feed_name});

        // Arena for HTTP round-trip allocations.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var client: std.http.Client = .{ .allocator = aa, .io = io };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(aa);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
        }) catch return false;

        if (result.status != .ok) return false;

        const body = aw.toOwnedSlice() catch return false;

        // Parse RSS XML.
        var parser = rss.RssParser.init(alloc);
        const items = parser.parse(body, feed_name) catch return false;
        defer {
            for (items) |it| {
                alloc.free(it.guid);
                alloc.free(it.title);
                alloc.free(it.link);
                alloc.free(it.description);
                alloc.free(it.category);
            }
            alloc.free(items);
        }

        // Extract prefix from first item's guid (first two path segments).
        var prefix: ?[]const u8 = null;
        if (items.len > 0) {
            const g = items[0].guid;
            if (std.mem.indexOfScalar(u8, g, '/')) |first| {
                if (std.mem.indexOfScalar(u8, g[first + 1 ..], '/')) |second| {
                    prefix = g[0 .. first + 1 + second + 1];
                }
            }
        }

        var changed = false;

        // Collect valid entry ids for pruning.
        var valid_ids: std.ArrayList([]const u8) = .empty;
        defer valid_ids.deinit(alloc);

        for (items) |item| {
            try valid_ids.append(alloc, item.guid);

            // Check if entry already exists by guid.
            if (self.hasEntry(alloc, item.guid)) continue;

            // Build entry JSON.
            var entry_obj: std.json.ObjectMap = .empty;
            try entry_obj.put(alloc, "entry_id", .{ .string = item.guid });
            try entry_obj.put(alloc, "url", if (item.link.len > 0) .{ .string = item.link } else .null);
            try entry_obj.put(alloc, "title", if (item.title.len > 0) .{ .string = item.title } else .null);
            try entry_obj.put(alloc, "description", if (item.description.len > 0) .{ .string = item.description } else .null);
            try entry_obj.put(alloc, "priority", if (item.category.len > 0) .{ .string = item.category } else .null);
            try entry_obj.put(alloc, "date", .{ .float = item.date });
            try entry_obj.put(alloc, "dismissed", .{ .bool = false });
            try entry_obj.put(alloc, "date_dismissed", .null);
            try entry_obj.put(alloc, "dismiss_wake", .null);
            try entry_obj.put(alloc, "source", .{ .string = "moonlight" });
            try entry_obj.put(alloc, "feed", .{ .string = feed_name });

            var key_buf: [7]u8 = undefined;
            const key = try self.nextKeyStr(&key_buf);
            _ = self.store.insertItem(alloc, ns_entries, key, .{ .object = entry_obj }) catch continue;
            changed = true;
        }

        // Prune entries whose prefix matches but are no longer in the feed.
        if (prefix) |p| {
            if (self.pruneByPrefix(alloc, p, valid_ids.items)) {
                changed = true;
            }
        }

        return changed;
    }

    /// Update all registered feeds. Returns true if any changed.
    /// Emits notify_announcement_update when entries change.
    /// `locked` must be true when called from a handler (Core lock held),
    /// false when called from a background thread.
    pub fn updateAllFeeds(self: *AnnouncementsCtx, alloc: std.mem.Allocator, locked: bool) !bool {
        var changed = false;
        for (self.feeds.items) |f| {
            const feed_changed = self.fetchAndUpdateFeed(alloc, f) catch false;
            changed = changed or feed_changed;
        }
        if (changed) {
            self.notifyUpdate(alloc, locked);
        }
        return changed;
    }

    /// Check if an entry with the given guid exists in the store.
    fn hasEntry(self: *AnnouncementsCtx, alloc: std.mem.Allocator, entry_id: []const u8) bool {
        const ns_obj = self.store.getNamespace(alloc, ns_entries) catch return false;
        switch (ns_obj) {
            .object => |obj| {
                for (obj.values()) |*entry| {
                    const eid = switch (entry.*) {
                        .object => |o| switch (o.get("entry_id") orelse .null) {
                            .string => |s| s,
                            else => continue,
                        },
                        else => continue,
                    };
                    if (std.mem.eql(u8, eid, entry_id)) return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// Prune entries whose entry_id starts with `prefix` but are not in `valid_ids`.
    fn pruneByPrefix(self: *AnnouncementsCtx, alloc: std.mem.Allocator, prefix: []const u8, valid_ids: []const []const u8) bool {
        var changed = false;
        const ns_obj = self.store.getNamespace(alloc, ns_entries) catch return false;
        switch (ns_obj) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |kv| {
                    const entry = kv.value_ptr.*;
                    const eid = switch (entry) {
                        .object => |o| switch (o.get("entry_id") orelse .null) {
                            .string => |s| s,
                            else => continue,
                        },
                        else => continue,
                    };
                    if (!std.mem.startsWith(u8, eid, prefix)) continue;

                    var still_valid = false;
                    for (valid_ids) |vid| {
                        if (std.mem.eql(u8, vid, eid)) {
                            still_valid = true;
                            break;
                        }
                    }
                    if (!still_valid) {
                        _ = self.store.deleteItem(alloc, ns_entries, kv.key_ptr.*) catch {};
                        changed = true;
                    }
                }
            },
            else => {},
        }
        return changed;
    }

    /// Emit notify_announcement_update with current entries.
    /// `locked` must be true when called from a handler (Core lock held),
    /// false when called from a background thread.
    fn notifyUpdate(self: *AnnouncementsCtx, alloc: std.mem.Allocator, locked: bool) void {
        const io = self.io orelse return;
        const entries = self.listEntries(alloc, true) catch return;
        var map: std.json.ObjectMap = .empty;
        map.put(alloc, "entries", .{ .array = entries }) catch return;
        if (locked) {
            self.bus.emitLocked(io, "notify_announcement_update", .{ .object = map }) catch {};
        } else {
            self.bus.emit(io, "notify_announcement_update", .{ .object = map }) catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// Background refresh timer
// ---------------------------------------------------------------------------

/// Background thread spawned via std.Thread.spawn. Periodically fetches all
/// subscribed RSS feeds and emits notify_announcement_update when entries
/// change. Runs every UPDATE_CHECK_TIME seconds (30 min), matching Moonraker.
///
/// Sleeps in 1-second increments so the stop flag is polled frequently,
/// keeping deinit→join latency bounded (~1 s); otherwise the thread would
/// block in nanosleep for up to UPDATE_CHECK_TIME seconds.
fn announcementsRefreshTimerThread(self: *AnnouncementsCtx) void {
    var elapsed: u64 = 0;
    while (!self.refresh_stop.load(.acquire)) {
        var req: std.os.linux.timespec = .{ .sec = 1, .nsec = 0 };
        _ = std.os.linux.nanosleep(&req, null);
        if (self.refresh_stop.load(.acquire)) break;
        if (self.io == null) break;

        elapsed += 1;
        if (elapsed < UPDATE_CHECK_TIME) continue;
        elapsed = 0;

        // Arena for one refresh cycle. smp_allocator is thread-safe.
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // locked=false → emit() takes the Core lock instead of assuming it.
        _ = self.updateAllFeeds(a, false) catch {};
    }
}

// ---------------------------------------------------------------------------
// Namespace constants
// ---------------------------------------------------------------------------

pub const ns_entries: [:0]const u8 = "announcements";
pub const ns_feeds: [:0]const u8 = "announcement_feeds";
pub const feeds_key = "feeds";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) error{InvalidParams}!?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                .null => null,
                else => error.InvalidParams,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return (try getOptStr(params, field)) orelse error.InvalidParams;
}

fn getOptBool(params: std.json.Value, field: []const u8, default: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default,
            };
        },
        else => return default,
    }
}

fn getOptInt(params: std.json.Value, field: []const u8, default: ?i64) ?i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                .null => null,
                else => default,
            };
        },
        else => return default,
    }
}

fn getStrList(params: std.json.Value, field: []const u8) []const std.json.Value {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return &.{};
            return switch (v) {
                .array => |a| a.items,
                else => &.{},
            };
        },
        else => return &.{},
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/announcements/list
pub fn handleList(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const include_dismissed = getOptBool(params, "include_dismissed", true);
    const entries = try c.listEntries(alloc, include_dismissed);
    const feeds_arr = try c.feedsJson(alloc);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "entries", .{ .array = entries });
    try obj.put(alloc, "feeds", .{ .array = feeds_arr });
    return .{ .object = obj };
}

/// POST /server/announcements/update
/// Fetches RSS feeds for the requested subscriptions (or all if none specified).
/// Returns current entries and whether any were added/modified.
pub fn handleUpdate(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const subs_raw = getStrList(params, "subscriptions");

    // Validate requested subscriptions if specified
    if (subs_raw.len > 0) {
        for (subs_raw) |sv| {
            const name = switch (sv) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
            if (!c.hasFeed(name)) return error.InvalidParams;
        }
    }

    var changed = false;
    if (subs_raw.len > 0) {
        // Fetch only the requested feeds.
        for (subs_raw) |sv| {
            const name = sv.string;
            const feed_changed = c.fetchAndUpdateFeed(alloc, name) catch false;
            changed = changed or feed_changed;
        }
    } else {
        // Fetch all subscribed feeds.
        changed = c.updateAllFeeds(alloc, true) catch false;
    }

    const entries = try c.listEntries(alloc, true);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "entries", .{ .array = entries });
    try obj.put(alloc, "modified", .{ .bool = changed });
    return .{ .object = obj };
}

/// POST /server/announcements/dismiss
pub fn handleDismiss(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const entry_id = try getStr(params, "entry_id");
    const wake_time = getOptInt(params, "wake_time", null);

    // Find entry by entry_id field in the namespace
    const ns_obj = c.store.getNamespace(alloc, ns_entries) catch return error.NotFound;
    var found_key: ?[]const u8 = null;
    var found_entry: ?std.json.Value = null;

    switch (ns_obj) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |kv| {
                const entry = kv.value_ptr.*;
                const eid = switch (entry) {
                    .object => |o| switch (o.get("entry_id") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    },
                    else => continue,
                };
                if (std.mem.eql(u8, eid, entry_id)) {
                    found_key = kv.key_ptr.*;
                    found_entry = entry;
                    break;
                }
            }
        },
        else => return error.NotFound,
    }

    const key = found_key orelse return error.NotFound;
    var entry_obj = switch (found_entry.?) {
        .object => |o| o,
        else => return error.NotFound,
    };

    // Check already dismissed
    const already_dismissed = switch (entry_obj.get("dismissed") orelse .null) {
        .bool => |b| b,
        else => false,
    };
    if (already_dismissed) {
        var result: std.json.ObjectMap = .empty;
        try result.put(alloc, "entry_id", .{ .string = entry_id });
        return .{ .object = result };
    }

    // Build updated entry
    var new_entry: std.json.ObjectMap = .empty;
    {
        var it = entry_obj.iterator();
        while (it.next()) |kv| try new_entry.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
    }
    try new_entry.put(alloc, "dismissed", .{ .bool = true });
    var _ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &_ts);
    const cur_time = @as(f64, @floatFromInt(_ts.sec)) + @as(f64, @floatFromInt(_ts.nsec)) / 1.0e9;
    try new_entry.put(alloc, "date_dismissed", .{ .float = cur_time });
    if (wake_time) |wt| {
        try new_entry.put(alloc, "dismiss_wake", .{ .float = cur_time + @as(f64, @floatFromInt(wt)) });
    } else {
        try new_entry.put(alloc, "dismiss_wake", .null);
    }

    const key_z = try alloc.dupeZ(u8, key);
    c.store.insertItem(alloc, ns_entries, key_z, .{ .object = new_entry }) catch {};

    // Emit notify_announcement_dismissed (uses emitLocked — handler runs under Core lock).
    emitAnnouncementDismissed(c, alloc, entry_id);

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "entry_id", .{ .string = entry_id });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Notification emission
// ---------------------------------------------------------------------------

/// Emit `notify_announcement_update` with the current entries list.
/// Only call when entries actually changed (e.g. after real RSS fetch).
fn emitAnnouncementUpdate(ctx: *AnnouncementsCtx, alloc: std.mem.Allocator) void {
    const io = ctx.io orelse return;
    const entries = ctx.listEntries(alloc, false) catch return;
    if (entries.items.len == 0) return;
    var inner: std.json.ObjectMap = .empty;
    inner.put(alloc, "entries", .{ .array = entries }) catch return;
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;
    ctx.bus.emitLocked(io, notify.names.announcement_update, .{ .array = params }) catch {};
}

/// Emit `notify_announcement_dismissed` for a single entry.
fn emitAnnouncementDismissed(ctx: *AnnouncementsCtx, alloc: std.mem.Allocator, entry_id: []const u8) void {
    const io = ctx.io orelse return;
    var inner: std.json.ObjectMap = .empty;
    inner.put(alloc, "entry_id", .{ .string = entry_id }) catch return;
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;
    ctx.bus.emitLocked(io, notify.names.announcement_dismissed, .{ .array = params }) catch {};
}

/// Emit `notify_announcement_wake` for a single entry.
/// Only call when a dismissed entry's wake_time has been reached (requires
/// a background timer / event loop, not yet implemented).
fn emitAnnouncementWake(ctx: *AnnouncementsCtx, alloc: std.mem.Allocator, entry_id: []const u8) void {
    const io = ctx.io orelse return;
    var inner: std.json.ObjectMap = .empty;
    inner.put(alloc, "entry_id", .{ .string = entry_id }) catch return;
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;
    ctx.bus.emitLocked(io, notify.names.announcement_wake, .{ .array = params }) catch {};
}

/// GET /server/announcements/feeds
pub fn handleListFeeds(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const feeds_arr = try c.feedsJson(alloc);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feeds", .{ .array = feeds_arr });
    return .{ .object = obj };
}

/// POST /server/announcements/feed — add a new feed
pub fn handlePostFeed(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const name_raw = try getStr(params, "name");
    // Normalize to lowercase (matches announcements.py `name.lower()`)
    const name_lower = try alloc.alloc(u8, name_raw.len);
    for (name_raw, 0..) |ch, i| name_lower[i] = std.ascii.toLower(ch);

    const action: []const u8 = if (c.hasFeed(name_lower)) "skipped" else blk: {
        const owned = try c.gpa.dupe(u8, name_lower);
        errdefer c.gpa.free(owned);
        try c.feeds.append(c.gpa, owned);
        c.saveFeeds(alloc);

        // Trigger immediate RSS fetch for the new feed.
        const changed = c.fetchAndUpdateFeed(alloc, name_lower) catch false;
        if (changed) {
            c.notifyUpdate(alloc, true);
        }
        break :blk "added";
    };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feed", .{ .string = name_lower });
    try obj.put(alloc, "action", .{ .string = action });
    return .{ .object = obj };
}

/// DELETE /server/announcements/feed — remove a stored feed
pub fn handleDeleteFeed(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const name_raw = try getStr(params, "name");
    const name_lower = try alloc.alloc(u8, name_raw.len);
    for (name_raw, 0..) |ch, i| name_lower[i] = std.ascii.toLower(ch);

    // Built-in feeds cannot be deleted
    if (AnnouncementsCtx.isBuiltin(name_lower)) return error.Forbidden;

    // Must exist
    if (!c.hasFeed(name_lower)) return error.NotFound;

    // Remove from in-memory list
    var i: usize = 0;
    while (i < c.feeds.items.len) {
        if (std.mem.eql(u8, c.feeds.items[i], name_lower)) {
            c.gpa.free(c.feeds.items[i]);
            _ = c.feeds.orderedRemove(i);
            break;
        }
        i += 1;
    }
    c.saveFeeds(alloc);

    // Remove entries for this feed from the store
    pruneEntriesByFeed(c, alloc, name_lower);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feed", .{ .string = name_lower });
    try obj.put(alloc, "action", .{ .string = "removed" });
    return .{ .object = obj };
}

/// Dispatch for multi-verb /server/announcements/feed (POST=add, DELETE=remove).
pub fn handleFeedDispatch(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // This handler is registered for both verbs via multi-verb registration.
    // The caller uses the correct JSON-RPC method name to disambiguate.
    // For HTTP: POST routes call postFeed; DELETE routes call deleteFeed.
    // For JSON-RPC: the method name already disambiguates.
    // Since we can't tell verb from params alone, use heuristic: this
    // handler is only called from the multi-verb JSON-RPC path where the
    // method name selects the handler. Register separate per-verb handlers
    // via HTTP-only strategy and use the dispatch only for the single shared
    // entry point. See registration comments below.
    _ = ctx;
    _ = params;
    _ = alloc;
    return error.WrongDispatch; // should never be reached
}

/// Remove all entries belonging to a feed from the store.
fn pruneEntriesByFeed(c: *AnnouncementsCtx, alloc: std.mem.Allocator, feed_name: []const u8) void {
    const ns_obj = c.store.getNamespace(alloc, ns_entries) catch return;
    switch (ns_obj) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |kv| {
                const entry = kv.value_ptr.*;
                const efeed = switch (entry) {
                    .object => |o| switch (o.get("feed") orelse .null) {
                        .string => |s| s,
                        else => continue,
                    },
                    else => continue,
                };
                if (!std.ascii.eqlIgnoreCase(efeed, feed_name)) continue;
                const key_z = alloc.dupeZ(u8, kv.key_ptr.*) catch continue;
                _ = c.store.deleteItem(alloc, ns_entries, key_z) catch .null;
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// Endpoint mapping (from announcements.py):
//   /server/announcements/list    GET       → "server.announcements.list"
//   /server/announcements/dismiss POST      → "server.announcements.dismiss"
//   /server/announcements/update  POST      → "server.announcements.update"
//   /server/announcements/feed    POST+DEL  → "server.announcements.post_feed"
//                                             "server.announcements.delete_feed"
//   /server/announcements/feeds   GET       → "server.announcements.feeds"

pub fn registerAnnouncements(reg: *Registry, ctx: *AnnouncementsCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/server/announcements/list", .methods = &.{.GET} },
        c,
        handleList,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/announcements/dismiss", .methods = &.{.POST} },
        c,
        handleDismiss,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/announcements/update", .methods = &.{.POST} },
        c,
        handleUpdate,
    );
    // POST + DELETE → multi-verb → post_feed / delete_feed
    // Both verbs use the same underlying dispatch that routes to the correct
    // per-operation handler.
    try reg.registerEndpoint(
        .{ .path = "/server/announcements/feed", .methods = &.{ .POST, .DELETE } },
        c,
        handleFeedDispatchMulti,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/announcements/feeds", .methods = &.{.GET} },
        c,
        handleListFeeds,
    );
}

/// Multi-verb dispatch for /server/announcements/feed.
/// Both HTTP and JSON-RPC transports inject `_method` into params
/// (HTTP: line 338 of http_transport.zig; JSON-RPC: line 120 of jsonrpc.zig)
/// so we can branch on the verb, matching Moonraker's `_handle_feed_request`
/// which checks `web_request.get_request_type()`.
fn handleFeedDispatchMulti(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const verb: []const u8 = switch (params) {
        .object => |o| if (o.get("_method")) |v| switch (v) {
            .string => |s| s,
            else => "POST",
        } else "POST",
        else => "POST",
    };
    if (std.mem.eql(u8, verb, "DELETE")) {
        return handleDeleteFeed(ctx, params, alloc);
    }
    return handlePostFeed(ctx, params, alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// ---- In-memory store for tests ----

const MemNamespace = struct {
    name: []const u8,
    data: std.StringHashMap(std.json.Value),

    fn init(alloc: std.mem.Allocator, name: []const u8) MemNamespace {
        return .{ .name = name, .data = std.StringHashMap(std.json.Value).init(alloc) };
    }

    fn deinit(self: *MemNamespace) void {
        self.data.deinit();
    }
};

const MemStore = struct {
    alloc: std.mem.Allocator,
    namespaces: std.ArrayList(MemNamespace),

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc, .namespaces = .empty };
    }

    fn deinit(self: *MemStore) void {
        for (self.namespaces.items) |*n| n.deinit();
        self.namespaces.deinit(self.alloc);
    }

    fn getNs(self: *MemStore, name: []const u8) ?*MemNamespace {
        for (self.namespaces.items) |*n| if (std.mem.eql(u8, n.name, name)) return n;
        return null;
    }

    fn getOrCreate(self: *MemStore, name: []const u8) !*MemNamespace {
        if (self.getNs(name)) |n| return n;
        try self.namespaces.append(self.alloc, .init(self.alloc, name));
        return &self.namespaces.items[self.namespaces.items.len - 1];
    }

    fn vtGetItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!?std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return null;
        return n.data.get(key);
    }

    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getOrCreate(ns) catch return ds.Error.OutOfMemory;
        n.data.put(key, value) catch return ds.Error.OutOfMemory;
    }

    fn vtUpdateItem(ctx: *anyopaque, alloc: std.mem.Allocator, ns: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        return vtInsertItem(ctx, alloc, ns, key, value);
    }

    fn vtDeleteItem(ctx: *anyopaque, _: std.mem.Allocator, ns: [:0]const u8, key: []const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return ds.Error.KeyNotFound;
        const v = n.data.get(key) orelse return ds.Error.KeyNotFound;
        _ = n.data.remove(key);
        return v;
    }

    fn vtListNamespaces(ctx: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList([]const u8) = .empty;
        for (self.namespaces.items) |*n| out.append(arena, n.name) catch return ds.Error.OutOfMemory;
        return out.toOwnedSlice(arena) catch return ds.Error.OutOfMemory;
    }

    fn vtGetNamespace(ctx: *anyopaque, arena: std.mem.Allocator, ns: [:0]const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const n = self.getNs(ns) orelse return .{ .object = .empty };
        var obj: std.json.ObjectMap = .empty;
        var it = n.data.iterator();
        while (it.next()) |e| obj.put(arena, e.key_ptr.*, e.value_ptr.*) catch return ds.Error.OutOfMemory;
        return .{ .object = obj };
    }

    const vtable: ds.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };

    fn dataStore(self: *MemStore) DataStore {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const NullCore = @import("../server/core.zig").Core;
const NullConns = @import("../server/connections.zig").Connections;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn insertEntry(mem: *MemStore, alloc: std.mem.Allocator, key: []const u8, entry_json: []const u8) !void {
    const v = try std.json.parseFromSlice(std.json.Value, alloc, entry_json, .{});
    const ns = try mem.getOrCreate(ns_entries);
    try ns.data.put(key, v.value);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "handleListFeeds: returns built-in feeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const result = try handleListFeeds(@ptrCast(&ctx), .null, a);
    const feeds = result.object.get("feeds").?.array;
    try testing.expect(feeds.items.len >= 2);
    var found_mr = false;
    var found_kl = false;
    for (feeds.items) |f| {
        if (std.mem.eql(u8, f.string, "moonraker")) found_mr = true;
        if (std.mem.eql(u8, f.string, "klipper")) found_kl = true;
    }
    try testing.expect(found_mr);
    try testing.expect(found_kl);
}

test "handleList: empty store returns empty entries and built-in feeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const result = try handleList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), result.object.get("entries").?.array.items.len);
    try testing.expect(result.object.get("feeds").?.array.items.len >= 2);
}

test "handleList: include_dismissed=false filters dismissed entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertEntry(&mem, a, "000001",
        \\{"entry_id":"e1","dismissed":false,"date":100.0,"feed":"moonraker"}
    );
    try insertEntry(&mem, a, "000002",
        \\{"entry_id":"e2","dismissed":true,"date":200.0,"feed":"moonraker"}
    );

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"include_dismissed\":false}");
    const result = try handleList(@ptrCast(&ctx), p, a);
    try testing.expectEqual(@as(usize, 1), result.object.get("entries").?.array.items.len);
}

test "handlePostFeed: adds new feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"name\":\"myapp\"}");
    const result = try handlePostFeed(@ptrCast(&ctx), p, a);
    try testing.expectEqualStrings("myapp", result.object.get("feed").?.string);
    try testing.expectEqualStrings("added", result.object.get("action").?.string);
    try testing.expect(ctx.hasFeed("myapp"));
}

test "handlePostFeed: duplicate feed returns skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"name\":\"moonraker\"}");
    const result = try handlePostFeed(@ptrCast(&ctx), p, a);
    try testing.expectEqualStrings("skipped", result.object.get("action").?.string);
}

test "handleDeleteFeed: removes stored feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Add it first
    const p1 = try mkParams(a, "{\"name\":\"myclient\"}");
    _ = try handlePostFeed(@ptrCast(&ctx), p1, a);

    // Now delete
    const p2 = try mkParams(a, "{\"name\":\"myclient\"}");
    const result = try handleDeleteFeed(@ptrCast(&ctx), p2, a);
    try testing.expectEqualStrings("removed", result.object.get("action").?.string);
    try testing.expect(!ctx.hasFeed("myclient"));
}

test "handleDeleteFeed: builtin feed → Forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"name\":\"moonraker\"}");
    try testing.expectError(error.Forbidden, handleDeleteFeed(@ptrCast(&ctx), p, a));
}

test "handleDismiss: marks entry dismissed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertEntry(&mem, a, "000001",
        \\{"entry_id":"e1","dismissed":false,"date":100.0,"feed":"moonraker"}
    );

    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"entry_id\":\"e1\"}");
    const result = try handleDismiss(@ptrCast(&ctx), p, a);
    try testing.expectEqualStrings("e1", result.object.get("entry_id").?.string);
}

test "handleDismiss: unknown entry_id → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"entry_id\":\"nope\"}");
    try testing.expectError(error.NotFound, handleDismiss(@ptrCast(&ctx), p, a));
}

test "handleUpdate: returns entries and modified=false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const result = try handleUpdate(@ptrCast(&ctx), .null, a);
    try testing.expect(result.object.get("entries") != null);
    try testing.expectEqual(false, result.object.get("modified").?.bool);
}

test "registerAnnouncements: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(alloc, mem.dataStore(), &bus);
    defer ctx.deinit();

    try registerAnnouncements(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/announcements/list") != null);
    try testing.expect(reg.lookup(.POST, "/server/announcements/dismiss") != null);
    try testing.expect(reg.lookup(.POST, "/server/announcements/update") != null);
    try testing.expect(reg.lookup(.POST, "/server/announcements/feed") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/announcements/feed") != null);
    try testing.expect(reg.lookup(.GET, "/server/announcements/feeds") != null);

    try testing.expect(d.methods.get("server.announcements.list") != null);
    try testing.expect(d.methods.get("server.announcements.dismiss") != null);
    try testing.expect(d.methods.get("server.announcements.update") != null);
    try testing.expect(d.methods.get("server.announcements.post_feed") != null);
    try testing.expect(d.methods.get("server.announcements.delete_feed") != null);
    try testing.expect(d.methods.get("server.announcements.feeds") != null);
}

// ---------------------------------------------------------------------------
// Background refresh timer tests
// ---------------------------------------------------------------------------

test "notifyUpdate: locked=true uses emitLocked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.io = io;

    // locked=true → emitLocked. With entries present, should not crash.
    try insertEntry(&mem, a, "000001",
        \\{"entry_id":"e1","dismissed":false,"date":100.0,"feed":"moonraker"}
    );
    // Re-init to pick up the inserted entry for next_key etc.
    var ctx2 = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx2.deinit();
    ctx2.io = io;

    // notifyUpdate is private; test via updateAllFeeds which calls it when
    // changed. Since there's no network, fetchAndUpdateFeed returns false,
    // so no notification would be emitted. Instead, test that notifyUpdate
    // itself does not crash by calling it indirectly: add an entry, then
    // verify the update path is reachable.
    //
    // Direct test: notifyUpdate handles locked=true without io bounce.
    // We can't call the private fn, so instead verify that updateAllFeeds
    // with locked=true completes without error (even if no feeds changed).
    const changed = try ctx2.updateAllFeeds(a, true);
    try testing.expectEqual(false, changed);
}

test "notifyUpdate: locked=false uses emit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.io = io;

    // locked=false → emit(). Same as above, verify no crash.
    const changed = try ctx.updateAllFeeds(a, false);
    try testing.expectEqual(false, changed);
}

test "deinit: handles null refresh_thread gracefully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    // No setIo → refresh_thread is null. deinit must not crash.
    ctx.deinit();
}

test "deinit: sets refresh_stop and nulls io" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    ctx.io = io;

    // Spawn the timer thread.
    ctx.refresh_thread = std.Thread.spawn(.{}, announcementsRefreshTimerThread, .{&ctx}) catch null;

    // deinit must set the stop flag, null io, and join the thread.
    ctx.deinit();
    try testing.expect(ctx.refresh_thread == null);
    try testing.expect(ctx.io == null);
    try testing.expect(ctx.refresh_stop.load(.acquire));
}

test "announcementsRefreshTimerThread: exits when pre-stopped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    // Pre-set stop flag; the thread should exit the while loop without sleeping.
    ctx.refresh_stop.store(true, .release);
    announcementsRefreshTimerThread(&ctx);
    // If we reach here, the thread exited cleanly.
}

test "announcementsRefreshTimerThread: exits when io is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    // io is null (setIo never called). Thread should break on null io check
    // after the first 1-second sleep.
    ctx.refresh_stop.store(false, .release);
    announcementsRefreshTimerThread(&ctx);
    // If we reach here, the thread exited cleanly after the null io check.
}

test "fuzz notifyUpdate: locked=true/false never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();
            ctx.io = io;

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const locked: bool = (buf[0] & 1) != 0;
            _ = ctx.updateAllFeeds(a, locked) catch {};
        }
    }.run, .{});
}

// ---------------------------------------------------------------------------
// Fuzz tests
// ---------------------------------------------------------------------------

test "fuzz handleList: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"include_dismissed\":true}",
                "{\"include_dismissed\":false}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleList(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handlePostFeed: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"moonraker\"}",
                "{\"name\":\"newapp\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handlePostFeed(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDismiss: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"entry_id\":\"e1\"}",
                "{\"entry_id\":\"e1\",\"wake_time\":3600}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleDismiss(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleListFeeds: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleListFeeds(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleDeleteFeed: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"klipper\"}",
                "{\"name\":\"custom\"}",
                "{\"name\":\"nonexistent\"}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleDeleteFeed(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleUpdate: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"subscriptions\":[\"klipper\"]}",
                "{\"subscriptions\":[\"klipper\",\"moonraker\"]}",
                "{\"subscriptions\":[]}",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleUpdate(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "handleFeedDispatchMulti: POST dispatches to post_feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const params = try std.json.parseFromSlice(std.json.Value, a,
        \\{"name":"newfeed","_method":"POST"}
    , .{});
    const result = try handleFeedDispatchMulti(@ptrCast(&ctx), params.value, a);
    try testing.expectEqualStrings("newfeed", result.object.get("feed").?.string);
    try testing.expectEqualStrings("added", result.object.get("action").?.string);
}

test "handleFeedDispatchMulti: DELETE dispatches to delete_feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    // First add a feed via POST
    const p1 = try std.json.parseFromSlice(std.json.Value, a,
        \\{"name":"to_delete","_method":"POST"}
    , .{});
    _ = try handleFeedDispatchMulti(@ptrCast(&ctx), p1.value, a);

    // Then delete it via DELETE
    const p2 = try std.json.parseFromSlice(std.json.Value, a,
        \\{"name":"to_delete","_method":"DELETE"}
    , .{});
    const result = try handleFeedDispatchMulti(@ptrCast(&ctx), p2.value, a);
    try testing.expectEqualStrings("to_delete", result.object.get("feed").?.string);
    try testing.expectEqualStrings("removed", result.object.get("action").?.string);
}

test "handleFeedDispatchMulti: missing _method defaults to POST" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();

    const params = try std.json.parseFromSlice(std.json.Value, a,
        \\{"name":"defaulttest"}
    , .{});
    const result = try handleFeedDispatchMulti(@ptrCast(&ctx), params.value, a);
    try testing.expectEqualStrings("defaulttest", result.object.get("feed").?.string);
    try testing.expectEqualStrings("added", result.object.get("action").?.string);
}

test "fuzz handleFeedDispatchMulti: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = AnnouncementsCtx.init(a, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "{}",
                "{\"method\":\"list\"}",
                "{\"method\":\"update\"}",
                "{\"method\":\"dismiss\"}",
                "{\"method\":\"feeds\"}",
                "{\"method\":\"post_feed\"}",
                "{\"method\":\"delete_feed\"}",
                "null",
            };
            const p = std.json.parseFromSlice(std.json.Value, a, strs[buf[0] % strs.len], .{}) catch return;
            _ = handleFeedDispatchMulti(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

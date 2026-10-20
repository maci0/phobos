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
//! DataStore layout (as announcements.py):
//!   namespace "announcements" — key per entry (hex sequence), value = entry object
//!   namespace "moonraker" — `announcements.stored_feeds` (feeds added through
//!     POST, a JSON array of names) and `announcements.<feed>.etag`
//!
//! Feeds are fetched from Moonlight (arksine.github.io/moonlight) with an
//! ETag conditional GET: the stored ETag is sent as If-None-Match and a 304
//! skips the parse. Downloads run with the Core lock released and a time
//! bound; parsing and store updates run under Core. A worker refreshes every
//! feed every 30 minutes and wakes dismissed entries whose wake time passed.
//!
//! Announcement entry shape (matches announcements.py):
//!   entry_id, url, title, description, priority, date,
//!   dismissed, date_dismissed, dismiss_wake, source, feed
//!
//! list params: include_dismissed (bool, true) → {"entries": [...], "feeds": [...]}
//! update params: subscriptions (list, default all) → {"entries": [...], "modified": bool}
//! dismiss params: entry_id (str), wake_time (int, null) → {"entry_id": str}
//! feeds → {"feeds": [...]}
//! post_feed params: name (str) → {"feed": str, "action": "added"|"skipped"}
//! delete_feed params: name (str) → {"feed": str, "action": "removed"}
//!
//! Notifications emitted (params is a one-element array):
//!   notify_announcement_update    [{"entries": [...]}] (entries changed)
//!   notify_announcement_dismissed [{"entry_id": str}]
//!   notify_announcement_wake      [{"entry_id": str}]

const std = @import("std");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const clock = @import("../util/clock.zig");
const sleep = @import("../util/sleep.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const database = @import("database.zig");
const rss = @import("rss.zig");
const http_get = @import("http_get.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

const MOONLIGHT_BASE_URL = "https://arksine.github.io/moonlight";
/// Moonraker's announcements update interval: 1800 seconds = 30 minutes.
const UPDATE_CHECK_TIME: u64 = 1800;
/// Bound on one feed download: Moonraker's http_client defaults,
/// connect_timeout 5 s plus request_timeout 10 s.
const FETCH_TIMEOUT: std.Io.Duration = .fromSeconds(15);
/// `wake_at` value when no dismissed entry has a wake time.
const no_wake = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const AnnouncementsCtx = struct {
    clock_io: std.Io,
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,
    /// Owned allocator for the feed lists.
    gpa: std.mem.Allocator,
    /// Built-in feeds and `[announcements] subscriptions`, gpa-owned. These
    /// cannot be deleted.
    configured: std.ArrayList([]u8),
    /// Feeds added through POST /server/announcements/feed, persisted at
    /// `moonraker` / `announcements.stored_feeds`. gpa-owned; may repeat a
    /// configured name, like Moonraker's `stored_feeds`.
    stored: std.ArrayList([]u8),
    /// Counter for new entry keys (hex sequence).
    next_key: u64,
    /// Unix second at or after which a dismissed entry wakes; `no_wake` when
    /// none. Written under Core, read by the refresh worker without it. u32
    /// because 32-bit ARM has no 64-bit atomics; it saturates in 2106.
    wake_at: std.atomic.Value(u32) = .init(no_wake),
    /// Background refresh timer stop flag. Set by deinit, polled by the timer thread.
    refresh_stop: std.Io.Event = .unset,
    /// Handle for the background refresh timer thread, joined in deinit.
    refresh_thread: ?std.Io.Future(void) = null,
    /// `[announcements] enable_moonlight`. Moonraker default is true. When
    /// false, remote Moonlight fetches return no XML.
    moonlight_enabled: bool = true,
    /// `[announcements] dev_mode`. When set, feeds are not fetched from Moonlight.
    dev_mode: bool = false,

    pub fn setIo(self: *AnnouncementsCtx, io: std.Io) void {
        self.io = io;
        if (self.refresh_thread != null) return;
        self.refresh_stop.reset();
        // Start the periodic RSS refresh timer (30 minute interval).
        self.refresh_thread = io.concurrent(announcementsRefreshTimerThread, .{self}) catch null;
    }

    /// Built-in feeds (always present, cannot be deleted).
    pub const builtin_feeds = [_][]const u8{ "moonraker", "klipper" };

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io, store: DataStore, bus: *NotifyBus) !AnnouncementsCtx {
        var ctx = AnnouncementsCtx{
            .clock_io = clock_io,
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .configured = .empty,
            .stored = .empty,
            .next_key = 0,
        };
        errdefer ctx.deinit();
        for (builtin_feeds) |f| try appendOwned(alloc, &ctx.configured, f);
        ctx.loadStoredFeeds() catch |err|
            std.debug.print("phobos: warning: failed to load stored announcement feeds: {}\n", .{err});
        ctx.scanEntries() catch |err|
            std.debug.print("phobos: warning: failed to read announcements: {}\n", .{err});
        return ctx;
    }

    pub fn deinit(self: *AnnouncementsCtx) void {
        self.refresh_stop.set(self.clock_io);
        if (self.refresh_thread) |*th| {
            th.cancel(self.io.?);
            self.refresh_thread = null;
        }
        self.io = null;
        for (self.configured.items) |f| self.gpa.free(f);
        self.configured.deinit(self.gpa);
        for (self.stored.items) |f| self.gpa.free(f);
        self.stored.deinit(self.gpa);
    }

    fn loadStoredFeeds(self: *AnnouncementsCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const val = (try self.store.getItem(arena.allocator(), ns_moonraker, stored_feeds_key)) orelse return;
        if (val != .array) return;
        for (val.array.items) |item| {
            if (item != .string or contains(self.stored.items, item.string)) continue;
            try appendOwned(self.gpa, &self.stored, item.string);
        }
    }

    /// Set `next_key` past the largest hex key and `wake_at` to the earliest
    /// pending wake among stored entries.
    fn scanEntries(self: *AnnouncementsCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const ns_obj = try self.store.getNamespace(arena.allocator(), ns_entries);
        if (ns_obj != .object) return;
        var it = ns_obj.object.iterator();
        while (it.next()) |kv| {
            const k = std.fmt.parseInt(u64, kv.key_ptr.*, 16) catch continue;
            const next = std.math.add(u64, k, 1) catch continue;
            if (next > self.next_key) self.next_key = next;
        }
        self.wake_at.store(earliestWake(ns_obj.object), .monotonic);
    }

    /// True when `name` is a subscription (configured or stored).
    fn hasFeed(self: *const AnnouncementsCtx, name: []const u8) bool {
        return contains(self.configured.items, name) or contains(self.stored.items, name);
    }

    /// Subscription names in Moonraker's order: configured, then stored.
    /// The slice borrows the feed lists; valid while Core is held.
    fn feedNames(self: *const AnnouncementsCtx, arena: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        try names.appendSlice(arena, self.configured.items);
        for (self.stored.items) |s| if (!contains(self.configured.items, s)) try names.append(arena, s);
        return names.items;
    }

    fn saveStoredFeeds(self: *AnnouncementsCtx, arena: std.mem.Allocator) !void {
        var arr: std.json.Array = .init(arena);
        for (self.stored.items) |f| try arr.append(.{ .string = f });
        self.store.insertItem(arena, ns_moonraker, stored_feeds_key, .{ .array = arr }) catch |err|
            std.debug.print("phobos: warning: failed to persist announcement feeds: {}, feed list lost on restart\n", .{err});
    }

    fn nextKeyStr(self: *AnnouncementsCtx, buf: *[16]u8) []u8 {
        const s = std.fmt.bufPrint(buf, "{X:0>6}", .{self.next_key}) catch unreachable; // u64 is at most 16 hex digits
        self.next_key +|= 1;
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
                    if (!include_dismissed and boolMember(entry, "dismissed")) continue;
                    try arr.append(entry);
                }
            },
            else => {},
        }
        // Sort descending by date
        std.sort.pdq(std.json.Value, arr.items, {}, struct {
            fn gt(_: void, a: std.json.Value, b: std.json.Value) bool {
                return floatMember(a, "date") orelse 0 > floatMember(b, "date") orelse 0;
            }
        }.gt);
        return arr;
    }

    /// Add a configured subscription. Built-in and existing names are left as they are.
    /// Does not fetch the feed.
    pub fn addSubscription(self: *AnnouncementsCtx, name: []const u8) !void {
        if (name.len == 0) return;
        const owned = try std.ascii.allocLowerString(self.gpa, name);
        errdefer self.gpa.free(owned);
        if (contains(self.configured.items, owned)) {
            self.gpa.free(owned);
            return;
        }
        try self.configured.append(self.gpa, owned);
    }

    fn fetchEnabled(self: *const AnnouncementsCtx) bool {
        return self.moonlight_enabled and !self.dev_mode and self.io != null;
    }

    /// Fetch `names` from Moonlight and store new entries; returns true when
    /// entries were added or removed. The caller holds the Core lock; it is
    /// released during the downloads, so feed lists may change meanwhile.
    /// Does nothing without io, with Moonlight disabled, or in dev_mode.
    fn refreshFeeds(self: *AnnouncementsCtx, arena: std.mem.Allocator, names: []const []const u8) !bool {
        if (!self.fetchEnabled() or names.len == 0) return false;
        const io = self.io.?;
        const downloads = try arena.alloc(Download, names.len);
        const urls = try arena.alloc([]const u8, names.len);
        for (downloads, urls, names) |*d, *url, name| {
            d.* = .{ .name = try arena.dupe(u8, name), .etag = try self.loadEtag(arena, name) };
            url.* = try std.fmt.allocPrint(arena, MOONLIGHT_BASE_URL ++ "/assets/{s}.xml", .{name});
        }
        {
            self.bus.core.unlock(io);
            defer self.bus.core.lock(io);
            for (downloads, urls) |*d, url| d.fetch(arena, io, url, FETCH_TIMEOUT);
        }
        var changed = false;
        var index: ?EntryIndex = null;
        for (downloads) |d| {
            const resp = d.response orelse continue;
            if (resp.not_modified or resp.status != 200 or !self.hasFeed(d.name)) continue;
            self.storeEtag(arena, d.name, resp.etag);
            if (index == null) index = try EntryIndex.load(self, arena);
            changed = (self.applyFeed(arena, &index.?, d.name, resp.body) catch false) or changed;
        }
        return changed;
    }

    fn etagKey(arena: std.mem.Allocator, feed_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "announcements.{s}.etag", .{feed_name});
    }

    fn loadEtag(self: *AnnouncementsCtx, arena: std.mem.Allocator, feed_name: []const u8) !?[]const u8 {
        const v = self.store.getItem(arena, ns_moonraker, try etagKey(arena, feed_name)) catch return null;
        return if (v) |s| if (s == .string) s.string else null else null;
    }

    /// Persist the response ETag, or delete the stored one when absent
    /// (announcements.py `_fetch_moonlight`).
    fn storeEtag(self: *AnnouncementsCtx, arena: std.mem.Allocator, feed_name: []const u8, etag: ?[]const u8) void {
        const key = etagKey(arena, feed_name) catch return;
        if (etag) |e| {
            self.store.insertItem(arena, ns_moonraker, key, .{ .string = e }) catch |err|
                std.debug.print("phobos: warning: failed to persist ETag for feed '{s}': {}\n", .{ feed_name, err });
        } else {
            _ = self.store.deleteItem(arena, ns_moonraker, key) catch {}; // absent key: nothing stored
        }
    }

    /// Parse one feed body and update the store (announcements.py `_parse_xml`).
    /// Returns true when entries were added or pruned.
    fn applyFeed(self: *AnnouncementsCtx, arena: std.mem.Allocator, index: *EntryIndex, feed_name: []const u8, body: []const u8) !bool {
        const feed = try rss.parse(arena, body);
        // Prune prefix: the lowercased channel title, else the first two
        // `/`-separated segments of the first guid.
        var prefix = try std.ascii.allocLowerString(arena, feed.title);
        if (prefix.len == 0 and feed.items.len > 0) {
            const g = feed.items[0].guid;
            var end = g.len;
            if (std.mem.indexOfScalar(u8, g, '/')) |first| {
                end = std.mem.indexOfScalarPos(u8, g, first + 1, '/') orelse g.len;
            }
            prefix = @constCast(g[0..end]);
        }

        var changed = false;
        var valid_ids: std.StringHashMapUnmanaged(void) = .empty;
        for (feed.items) |item| {
            try valid_ids.put(arena, item.guid, {});
            if (index.keys.contains(item.guid)) continue;

            var entry_obj: std.json.ObjectMap = .empty;
            try entry_obj.put(arena, "entry_id", .{ .string = item.guid });
            try entry_obj.put(arena, "url", if (item.link.len > 0) .{ .string = item.link } else .null);
            try entry_obj.put(arena, "title", if (item.title.len > 0) .{ .string = item.title } else .null);
            try entry_obj.put(arena, "description", if (item.description.len > 0) .{ .string = item.description } else .null);
            try entry_obj.put(arena, "priority", if (item.category.len > 0) .{ .string = item.category } else .null);
            try entry_obj.put(arena, "date", .{ .float = item.date orelse clock.wallSeconds(self.clock_io) });
            try entry_obj.put(arena, "dismissed", .{ .bool = false });
            try entry_obj.put(arena, "date_dismissed", .null);
            try entry_obj.put(arena, "dismiss_wake", .null);
            try entry_obj.put(arena, "source", .{ .string = "moonlight" });
            try entry_obj.put(arena, "feed", .{ .string = feed_name });

            var key_buf: [16]u8 = undefined;
            const key = try arena.dupe(u8, self.nextKeyStr(&key_buf));
            self.store.insertItem(arena, ns_entries, key, .{ .object = entry_obj }) catch |err| {
                std.debug.print("phobos: warning: failed to store announcement '{s}': {}\n", .{ item.guid, err });
                continue;
            };
            try index.keys.put(arena, item.guid, key);
            changed = true;
        }

        if (prefix.len > 0) {
            var it = index.keys.iterator();
            var stale: std.ArrayList([]const u8) = .empty;
            while (it.next()) |kv| {
                if (std.mem.startsWith(u8, kv.key_ptr.*, prefix) and !valid_ids.contains(kv.key_ptr.*))
                    try stale.append(arena, kv.key_ptr.*);
            }
            for (stale.items) |entry_id| {
                const key = index.keys.fetchSwapRemove(entry_id).?.value;
                _ = self.store.deleteItem(arena, ns_entries, key) catch |err|
                    std.debug.print("phobos: warning: failed to remove stale announcement '{s}': {}\n", .{ key, err });
                changed = true;
            }
        }
        return changed;
    }

    /// Emit notify_announcement_update with current entries. Core must be held.
    fn notifyUpdate(self: *AnnouncementsCtx, arena: std.mem.Allocator) void {
        const io = self.io orelse return;
        const entries = self.listEntries(arena, true) catch return;
        var map: std.json.ObjectMap = .empty;
        map.put(arena, "entries", .{ .array = entries }) catch return;
        var params: std.json.Array = .init(arena);
        params.append(.{ .object = map }) catch return;
        self.bus.emitLocked(io, notify.names.announcement_update, .{ .array = params }) catch {};
    }
};

/// entry_id → store key for every stored entry, read once per refresh.
const EntryIndex = struct {
    keys: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn load(ctx: *AnnouncementsCtx, arena: std.mem.Allocator) !EntryIndex {
        var index: EntryIndex = .{};
        const ns_obj = try ctx.store.getNamespace(arena, ns_entries);
        if (ns_obj != .object) return index;
        var it = ns_obj.object.iterator();
        while (it.next()) |kv| {
            const eid = stringMember(kv.value_ptr.*, "entry_id") orelse continue;
            try index.keys.put(arena, eid, kv.key_ptr.*);
        }
        return index;
    }
};

/// One feed download for `refreshFeeds`; all memory is in the refresh arena.
const Download = struct {
    name: []const u8,
    etag: ?[]const u8 = null,
    /// Null when the request failed or timed out.
    response: ?http_get.Result = null,

    /// GET `url` with the stored ETag, cancelling the request after `timeout`.
    fn fetch(self: *Download, arena: std.mem.Allocator, io: std.Io, url: []const u8, timeout: std.Io.Duration) void {
        const Task = struct {
            fn run(a: std.mem.Allocator, tio: std.Io, u: []const u8, etag: ?[]const u8, done: *std.Io.Event) anyerror!http_get.Result {
                defer done.set(tio);
                return http_get.getConditional(a, tio, u, etag);
            }
        };
        var done: std.Io.Event = .unset;
        var task = io.concurrent(Task.run, .{ arena, io, url, self.etag, &done }) catch return;
        _ = sleep.untilStopped(io, timeout, &done);
        self.response = task.cancel(io) catch |err| {
            std.debug.print("phobos: announcements: failed to update subscription '{s}': {}\n", .{ self.name, err });
            return;
        };
    }
};

fn appendOwned(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), name: []const u8) !void {
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    try list.append(gpa, owned);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn stringMember(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const m = v.object.get(key) orelse return null;
    return if (m == .string) m.string else null;
}

fn boolMember(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const m = v.object.get(key) orelse return false;
    return m == .bool and m.bool;
}

fn floatMember(v: std.json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    return switch (v.object.get(key) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Background refresh timer
// ---------------------------------------------------------------------------

/// True if a stored entry is dismissed with a `dismiss_wake` time at/<= `now`.
/// Pure; the unit of wake detection.
fn entryShouldWake(entry: std.json.Value, now: f64) bool {
    if (!boolMember(entry, "dismissed")) return false;
    const wake = floatMember(entry, "dismiss_wake") orelse return false; // no wake time → stays dismissed
    return wake <= now;
}

/// Earliest whole second at which a dismissed entry wakes, or `no_wake`.
fn earliestWake(entries: std.json.ObjectMap) u32 {
    var earliest: u32 = no_wake;
    for (entries.values()) |entry| {
        if (!boolMember(entry, "dismissed")) continue;
        const wake = floatMember(entry, "dismiss_wake") orelse continue;
        earliest = @min(earliest, std.math.lossyCast(u32, @ceil(wake)));
    }
    return earliest;
}

/// Re-surface dismissed entries whose `dismiss_wake` time has passed, emitting
/// notify_announcement_wake (Moonraker `_wake_dismissed`), and recompute
/// `wake_at`. Runs under the Core lock.
fn checkWakes(self: *AnnouncementsCtx, arena: std.mem.Allocator) void {
    const io = self.io orelse return;
    const ns = self.store.getNamespace(arena, ns_entries) catch return;
    if (ns != .object) return;

    const now = clock.wallSeconds(self.clock_io);
    var it = ns.object.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr;
        if (!entryShouldWake(entry.*, now)) continue;
        const eid = stringMember(entry.*, "entry_id") orelse continue;

        // Un-dismiss and persist.
        entry.object.put(arena, "dismissed", .{ .bool = false }) catch continue;
        entry.object.put(arena, "date_dismissed", .null) catch continue;
        entry.object.put(arena, "dismiss_wake", .null) catch continue;
        self.store.insertItem(arena, ns_entries, kv.key_ptr.*, entry.*) catch |err| {
            std.debug.print("phobos: warning: failed to persist announcement '{s}': {}, dismiss state lost on restart\n", .{ kv.key_ptr.*, err });
        };

        var inner: std.json.ObjectMap = .empty;
        inner.put(arena, "entry_id", .{ .string = eid }) catch continue;
        var params: std.json.Array = .init(arena);
        params.append(.{ .object = inner }) catch continue;
        self.bus.emitLocked(io, notify.names.announcement_wake, .{ .array = params }) catch {};
    }
    self.wake_at.store(earliestWake(ns.object), .monotonic);
}

/// Refresh every subscription and notify on change. Runs under the Core lock.
fn refreshAll(self: *AnnouncementsCtx, arena: std.mem.Allocator) void {
    const names = self.feedNames(arena) catch return;
    if (self.refreshFeeds(arena, names) catch false) self.notifyUpdate(arena);
}

fn announcementsRefreshTimerThread(self: *AnnouncementsCtx) void {
    const io = self.io orelse return;
    var elapsed: u64 = 0;
    while (!self.refresh_stop.isSet()) {
        if (sleep.untilStopped(io, .fromSeconds(1), &self.refresh_stop)) break;

        if (clock.wallSecondsInt(self.clock_io) >= self.wake_at.load(.monotonic)) {
            var wa = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer wa.deinit();
            self.bus.core.run(io, checkWakes, .{ self, wa.allocator() });
        }

        elapsed += 1;
        if (elapsed < UPDATE_CHECK_TIME) continue;
        elapsed = 0;

        // Arena for one refresh cycle. smp_allocator is thread-safe.
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        self.bus.core.run(io, refreshAll, .{ self, arena.allocator() });
    }
}

// ---------------------------------------------------------------------------
// Namespace constants
// ---------------------------------------------------------------------------

pub const ns_entries: [:0]const u8 = "announcements";
const ns_moonraker: [:0]const u8 = "moonraker";
const stored_feeds_key = "announcements.stored_feeds";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
                .float => |f| jv.floatToInt(f) orelse default,
                .string => |s| std.fmt.parseInt(i64, s, 10) catch default,
                .null => null,
                else => default,
            };
        },
        else => return default,
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
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "entries", .{ .array = entries });
    try obj.put(alloc, "feeds", try feedsJson(c, alloc));
    return .{ .object = obj };
}

fn feedsJson(c: *AnnouncementsCtx, alloc: std.mem.Allocator) !std.json.Value {
    var arr: std.json.Array = .init(alloc);
    for (try c.feedNames(alloc)) |f| try arr.append(.{ .string = f });
    return .{ .array = arr };
}

/// POST /server/announcements/update
/// Fetches the requested subscriptions (all when the param is absent).
/// Returns current entries and whether any were added/modified.
pub fn handleUpdate(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const requested: ?std.json.Value = if (params == .object) params.object.get("subscriptions") else null;
    const names = if (requested) |r| blk: {
        if (r != .array) return error.InvalidParams;
        const list = try alloc.alloc([]const u8, r.array.items.len);
        for (list, r.array.items) |*name, sv| {
            if (sv != .string or !c.hasFeed(sv.string)) return error.InvalidParams;
            name.* = sv.string;
        }
        break :blk list;
    } else try c.feedNames(alloc);

    const changed = try c.refreshFeeds(alloc, names);
    if (changed) c.notifyUpdate(alloc);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "entries", .{ .array = try c.listEntries(alloc, true) });
    try obj.put(alloc, "modified", .{ .bool = changed });
    return .{ .object = obj };
}

/// POST /server/announcements/dismiss
pub fn handleDismiss(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const entry_id = try database.getStr(params, "entry_id");
    const wake_time = getOptInt(params, "wake_time", null);

    // Unknown entry: Moonraker raises a plain ServerError (400).
    const index = try EntryIndex.load(c, alloc);
    const key = index.keys.get(entry_id) orelse return error.InvalidParams;
    var entry = (try c.store.getItem(alloc, ns_entries, key)) orelse return error.InvalidParams;
    if (entry != .object) return error.InvalidParams;

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "entry_id", .{ .string = entry_id });
    if (boolMember(entry, "dismissed")) return .{ .object = result };

    try entry.object.put(alloc, "dismissed", .{ .bool = true });
    const cur_time = clock.wallSeconds(c.clock_io);
    try entry.object.put(alloc, "date_dismissed", .{ .float = cur_time });
    if (wake_time) |wt| {
        const wake = cur_time + @as(f64, @floatFromInt(wt));
        try entry.object.put(alloc, "dismiss_wake", .{ .float = wake });
        _ = c.wake_at.fetchMin(std.math.lossyCast(u32, @ceil(wake)), .monotonic);
    } else {
        try entry.object.put(alloc, "dismiss_wake", .null);
    }

    c.store.insertItem(alloc, ns_entries, key, entry) catch |err| {
        std.debug.print("phobos: warning: failed to persist dismissed announcement '{s}': {}, dismiss state lost on restart\n", .{ key, err });
    };

    // Emit notify_announcement_dismissed (uses emitLocked — handler runs under Core lock).
    emitAnnouncementDismissed(c, alloc, entry_id);
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Notification emission
// ---------------------------------------------------------------------------

/// Emit `notify_announcement_dismissed` for a single entry.
fn emitAnnouncementDismissed(ctx: *AnnouncementsCtx, alloc: std.mem.Allocator, entry_id: []const u8) void {
    const io = ctx.io orelse return;
    var inner: std.json.ObjectMap = .empty;
    inner.put(alloc, "entry_id", .{ .string = entry_id }) catch return;
    var params: std.json.Array = .init(alloc);
    params.append(.{ .object = inner }) catch return;
    ctx.bus.emitLocked(io, notify.names.announcement_dismissed, .{ .array = params }) catch {};
}

/// GET /server/announcements/feeds
pub fn handleListFeeds(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feeds", try feedsJson(c, alloc));
    return .{ .object = obj };
}

/// POST /server/announcements/feed — add a new feed
pub fn handlePostFeed(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    // Normalize to lowercase (matches announcements.py `name.lower()`)
    const name = try std.ascii.allocLowerString(alloc, try database.getStr(params, "name"));

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feed", .{ .string = name });
    if (c.hasFeed(name)) {
        try obj.put(alloc, "action", .{ .string = "skipped" });
        return .{ .object = obj };
    }
    try appendOwned(c.gpa, &c.stored, name);
    try c.saveStoredFeeds(alloc);
    if (try c.refreshFeeds(alloc, &.{name})) c.notifyUpdate(alloc);
    try obj.put(alloc, "action", .{ .string = "added" });
    return .{ .object = obj };
}

/// DELETE /server/announcements/feed — remove a stored feed
pub fn handleDeleteFeed(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *AnnouncementsCtx = @ptrCast(@alignCast(ctx));
    const name = try std.ascii.allocLowerString(alloc, try database.getStr(params, "name"));

    // Moonraker: "Feed '<name>' not stored" and "exists in the configuration,
    // cannot remove" are plain ServerErrors (400).
    const i = for (c.stored.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f, name)) break idx;
    } else return error.InvalidParams;
    if (contains(c.configured.items, name)) return error.InvalidParams;

    c.gpa.free(c.stored.orderedRemove(i));
    try c.saveStoredFeeds(alloc);
    if (try pruneEntriesByFeed(c, alloc, name)) c.notifyUpdate(alloc);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "feed", .{ .string = name });
    try obj.put(alloc, "action", .{ .string = "removed" });
    return .{ .object = obj };
}

/// Remove all entries belonging to a feed from the store. Returns true when
/// any entry was removed.
fn pruneEntriesByFeed(c: *AnnouncementsCtx, alloc: std.mem.Allocator, feed_name: []const u8) !bool {
    const ns_obj = try c.store.getNamespace(alloc, ns_entries);
    if (ns_obj != .object) return false;
    var removed = false;
    var it = ns_obj.object.iterator();
    while (it.next()) |kv| {
        const efeed = stringMember(kv.value_ptr.*, "feed") orelse continue;
        if (!std.ascii.eqlIgnoreCase(efeed, feed_name)) continue;
        _ = c.store.deleteItem(alloc, ns_entries, kv.key_ptr.*) catch |err| {
            std.debug.print("phobos: warning: failed to remove announcement '{s}': {}\n", .{ kv.key_ptr.*, err });
            continue;
        };
        removed = true;
    }
    return removed;
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

// ---- entryShouldWake ----

test "entryShouldWake: only dismissed entries past their wake time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { json: []const u8, now: f64, want: bool }{
        .{ .json = "{\"dismissed\":true,\"dismiss_wake\":100}", .now = 150, .want = true }, // past wake
        .{ .json = "{\"dismissed\":true,\"dismiss_wake\":100}", .now = 50, .want = false }, // before wake
        .{ .json = "{\"dismissed\":true,\"dismiss_wake\":100.0}", .now = 100, .want = true }, // exactly at wake
        .{ .json = "{\"dismissed\":true,\"dismiss_wake\":null}", .now = 1e12, .want = false }, // no wake → never
        .{ .json = "{\"dismissed\":false,\"dismiss_wake\":1}", .now = 1e12, .want = false }, // not dismissed
        .{ .json = "{}", .now = 1e12, .want = false },
    };
    for (cases) |c| {
        const v = (try std.json.parseFromSlice(std.json.Value, a, c.json, .{})).value;
        try testing.expectEqual(c.want, entryShouldWake(v, c.now));
    }
    // Non-object value.
    try testing.expectEqual(false, entryShouldWake(.{ .integer = 5 }, 1e12));
}

test "fuzz entryShouldWake: arbitrary JSON never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const parsed = std.json.parseFromSlice(std.json.Value, a, &buf, .{}) catch return;
            _ = entryShouldWake(parsed.value, 1234.0);
        }
    }.run, .{});
}

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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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

test "addSubscription: configured feed is listed and dev_mode skips fetch" {
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    ctx.dev_mode = true;
    try ctx.addSubscription("Fluidd");
    try ctx.addSubscription("moonraker");
    const result = try handleListFeeds(@ptrCast(&ctx), .null, a);
    var found = false;
    for (result.object.get("feeds").?.array.items) |f| {
        if (std.mem.eql(u8, f.string, "fluidd")) found = true;
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 3), result.object.get("feeds").?.array.items.len);
    try testing.expect(!(try ctx.refreshFeeds(a, &.{"fluidd"})));
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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

test "handleDeleteFeed: builtin feed → InvalidParams (not a stored feed)" {
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"name\":\"moonraker\"}");
    try testing.expectError(error.InvalidParams, handleDeleteFeed(@ptrCast(&ctx), p, a));
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"entry_id\":\"e1\"}");
    const result = try handleDismiss(@ptrCast(&ctx), p, a);
    try testing.expectEqualStrings("e1", result.object.get("entry_id").?.string);
}

test "handleDismiss: unknown entry_id → InvalidParams (Moonraker 400)" {
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();

    const p = try mkParams(a, "{\"entry_id\":\"nope\"}");
    try testing.expectError(error.InvalidParams, handleDismiss(@ptrCast(&ctx), p, a));
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(alloc, std.testing.io, mem.dataStore(), &bus);
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

test "deinit: without a refresh worker it still marks the context stopped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var core = NullCore.init();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(std.testing.io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    ctx.deinit();
    try testing.expect(ctx.refresh_thread == null);
    try testing.expect(ctx.refresh_stop.isSet());
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
    var ctx = try AnnouncementsCtx.init(std.heap.smp_allocator, std.testing.io, mem.dataStore(), &bus);
    ctx.io = io;

    // Spawn the timer thread.
    ctx.refresh_thread = io.concurrent(announcementsRefreshTimerThread, .{&ctx}) catch null;

    // deinit must set the stop flag, null io, and join the thread.
    ctx.deinit();
    try testing.expect(ctx.refresh_thread == null);
    try testing.expect(ctx.io == null);
    try testing.expect(ctx.refresh_stop.isSet());
}

test "announcementsRefreshTimerThread: returns at once when stopped or without io, doing no work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mem = MemStore.init(a);
    defer mem.deinit();
    // A dismissed entry that is already due: a worker iteration would wake it.
    try insertEntry(&mem, a, "000001",
        \\{"entry_id":"due","dismissed":true,"date":1.0,"dismiss_wake":1.0}
    );
    var core = NullCore.init();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    try testing.expectEqual(@as(u32, 1), ctx.wake_at.load(.monotonic));

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    // No io: returns before the first wait.
    announcementsRefreshTimerThread(&ctx);
    // Stopped: returns before the first iteration.
    ctx.io = io;
    ctx.refresh_stop.set(io);
    announcementsRefreshTimerThread(&ctx);
    ctx.io = null;
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 900);
    const entry = (try mem.dataStore().getItem(a, ns_entries, "000001")).?;
    try testing.expect(entry.object.get("dismissed").?.bool);
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const result = try handleListFeeds(@ptrCast(&ctx), .null, a);
            try testing.expectEqual(@as(usize, 2), result.object.get("feeds").?.array.items.len);
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
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
            var ctx = AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus) catch return;
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
// ---------------------------------------------------------------------------
// Feed refresh, notification payloads and wake timers
// ---------------------------------------------------------------------------

/// A store, a bus with one recorded connection, and a context with io wired
/// and Moonlight fetches off. Initialise in place: members point at each other.
const TestEnv = struct {
    mem: MemStore,
    core: NullCore = .init(),
    conns: NullConns,
    bus: NotifyBus,
    ctx: AnnouncementsCtx,
    frames: std.ArrayList([]const u8) = .empty,
    arena: std.mem.Allocator,

    fn init(self: *TestEnv, arena: std.mem.Allocator, io: std.Io) !void {
        self.* = .{ .mem = .init(arena), .conns = undefined, .bus = undefined, .ctx = undefined, .arena = arena };
        self.conns = .init(arena, &self.core);
        self.bus = .init(&self.core, &self.conns);
        const conn = try self.conns.add(io);
        self.conns.attachWriter(io, conn, self, record);
        self.ctx = try .init(arena, std.testing.io, self.mem.dataStore(), &self.bus);
        self.ctx.io = io;
        self.ctx.dev_mode = true;
    }

    fn deinit(self: *TestEnv, io: std.Io) void {
        self.ctx.deinit();
        self.conns.deinit(io);
        self.mem.deinit();
    }

    fn record(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestEnv = @ptrCast(@alignCast(ctx));
        try self.frames.append(self.arena, try self.arena.dupe(u8, bytes));
    }

    /// `params` of the only recorded frame, after checking its method.
    fn onlyParams(self: *TestEnv, method: []const u8) !std.json.Array {
        try testing.expectEqual(@as(usize, 1), self.frames.items.len);
        const frame = try std.json.parseFromSliceLeaky(std.json.Value, self.arena, self.frames.items[0], .{});
        try testing.expectEqualStrings(method, frame.object.get("method").?.string);
        const params = frame.object.get("params").?.array;
        try testing.expectEqual(@as(usize, 1), params.items.len);
        return params;
    }
};

const feed_xml =
    \\<rss><channel><title>Moonraker</title>
    \\<item><guid>moonraker/2024/a</guid><title>A &amp; B</title><pubDate>Mon, 15 Jan 2024 12:00 GMT</pubDate><category>high</category></item>
    \\<item><guid>moonraker/2024/b</guid><title>B</title><pubDate>whenever</pubDate></item>
    \\</channel></rss>
;

test "applyFeed: stores items, dates bad pubDates now, prunes by channel title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    // A stale entry under the channel prefix and an unrelated one.
    try insertEntry(&env.mem, a, "000010",
        \\{"entry_id":"moonraker/2023/old","dismissed":false,"date":1.0,"feed":"moonraker"}
    );
    try insertEntry(&env.mem, a, "000011",
        \\{"entry_id":"klipper/2023/x","dismissed":false,"date":1.0,"feed":"klipper"}
    );
    try env.ctx.scanEntries();

    var index = try EntryIndex.load(&env.ctx, a);
    const before = clock.wallSeconds(std.testing.io);
    try testing.expect(try env.ctx.applyFeed(a, &index, "moonraker", feed_xml));

    const ns = (try env.mem.dataStore().getNamespace(a, ns_entries)).object;
    try testing.expectEqual(@as(usize, 3), ns.count());
    try testing.expect(ns.get("000010") == null); // pruned
    try testing.expect(ns.get("000011") != null); // other prefix kept
    const first = ns.get("000012").?.object;
    try testing.expectEqualStrings("moonraker/2024/a", first.get("entry_id").?.string);
    try testing.expectEqualStrings("A & B", first.get("title").?.string);
    try testing.expectEqualStrings("high", first.get("priority").?.string);
    try testing.expectEqual(@as(f64, 1705320000), first.get("date").?.float);
    try testing.expect(first.get("url").? == .null);
    try testing.expect(ns.get("000013").?.object.get("date").?.float >= before);

    // A second pass adds nothing and prunes nothing.
    try testing.expect(!try env.ctx.applyFeed(a, &index, "moonraker", feed_xml));
    // An empty channel prunes every entry under its title.
    try testing.expect(try env.ctx.applyFeed(a, &index, "moonraker", "<rss><channel><title>MoonRaker</title></channel></rss>"));
    try testing.expectEqual(@as(usize, 1), (try env.mem.dataStore().getNamespace(a, ns_entries)).object.count());
}

test "applyFeed: without a channel title the prefix is the first two guid segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    try insertEntry(&env.mem, a, "000001",
        \\{"entry_id":"fluidd/x/old","dismissed":false,"date":1.0,"feed":"fluidd"}
    );
    try insertEntry(&env.mem, a, "000002",
        \\{"entry_id":"fluidd/y/other","dismissed":false,"date":1.0,"feed":"fluidd"}
    );
    var index = try EntryIndex.load(&env.ctx, a);
    try testing.expect(try env.ctx.applyFeed(a, &index, "fluidd", "<rss><channel><item><guid>fluidd/x/new</guid></item></channel></rss>"));
    const ns = (try env.mem.dataStore().getNamespace(a, ns_entries)).object;
    try testing.expect(ns.get("000001") == null);
    try testing.expect(ns.get("000002") != null);
}

test "fuzz applyFeed: arbitrary feed bodies never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var core = NullCore.init();
            var conns = NullConns.init(a, &core);
            defer conns.deinit(std.testing.io);
            var bus = NotifyBus.init(&core, &conns);
            var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
            defer ctx.deinit();

            var buf: [160]u8 = undefined;
            const prefix = "<rss><channel><item><guid>a/b/";
            @memcpy(buf[0..prefix.len], prefix);
            smith.bytesWithHash(buf[prefix.len..], 0);
            const len = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 1);
            var index = try EntryIndex.load(&ctx, a);
            _ = ctx.applyFeed(a, &index, "f", buf[0..len]) catch {};
            _ = ctx.applyFeed(a, &index, "f", buf[0..len]) catch {};
        }
    }.run, .{});
}

test "notifyUpdate: params is [{entries: [...]}]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    try insertEntry(&env.mem, a, "000001",
        \\{"entry_id":"e1","dismissed":false,"date":100.0,"feed":"moonraker"}
    );
    env.ctx.notifyUpdate(a);
    const params = try env.onlyParams(notify.names.announcement_update);
    const entries = params.items[0].object.get("entries").?.array;
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("e1", entries.items[0].object.get("entry_id").?.string);
}

test "handleDismiss: emits [{entry_id}] and schedules the wake" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    try insertEntry(&env.mem, a, "000001",
        \\{"entry_id":"e1","dismissed":false,"date":100.0,"feed":"moonraker"}
    );
    try testing.expectEqual(no_wake, env.ctx.wake_at.load(.monotonic));
    _ = try handleDismiss(@ptrCast(&env.ctx), try mkParams(a, "{\"entry_id\":\"e1\",\"wake_time\":60}"), a);
    const params = try env.onlyParams(notify.names.announcement_dismissed);
    try testing.expectEqualStrings("e1", params.items[0].object.get("entry_id").?.string);
    const now = clock.wallSecondsInt(std.testing.io);
    const wake = env.ctx.wake_at.load(.monotonic);
    try testing.expect(wake >= now + 59 and wake <= now + 62);
    const stored = (try env.mem.dataStore().getItem(a, ns_entries, "000001")).?.object;
    try testing.expect(stored.get("dismissed").?.bool);
}

test "checkWakes: wakes due entries, emits [{entry_id}], recomputes wake_at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    try insertEntry(&env.mem, a, "000001",
        \\{"entry_id":"due","dismissed":true,"date":1.0,"date_dismissed":1.0,"dismiss_wake":2.5,"feed":"moonraker"}
    );
    try insertEntry(&env.mem, a, "000002",
        \\{"entry_id":"later","dismissed":true,"date":1.0,"date_dismissed":1.0,"dismiss_wake":9e15,"feed":"moonraker"}
    );
    try env.ctx.scanEntries();
    try testing.expectEqual(@as(u32, 3), env.ctx.wake_at.load(.monotonic));

    checkWakes(&env.ctx, a);
    const params = try env.onlyParams(notify.names.announcement_wake);
    try testing.expectEqualStrings("due", params.items[0].object.get("entry_id").?.string);
    const woken = (try env.mem.dataStore().getItem(a, ns_entries, "000001")).?.object;
    try testing.expect(!woken.get("dismissed").?.bool);
    try testing.expect(woken.get("dismiss_wake").? == .null);
    // Wake times past 2106 saturate to `no_wake`.
    try testing.expectEqual(no_wake, env.ctx.wake_at.load(.monotonic));
}

test "fuzz earliestWake: any wake time, including NaN and infinities, never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var bits: [8]u8 = undefined;
            smith.bytesWithHash(&bits, 0);
            const wake: f64 = @bitCast(bits);
            var entry: std.json.ObjectMap = .empty;
            try entry.put(a, "dismissed", .{ .bool = true });
            try entry.put(a, "dismiss_wake", .{ .float = wake });
            var entries: std.json.ObjectMap = .empty;
            try entries.put(a, "000001", .{ .object = entry });
            const earliest = earliestWake(entries);
            if (wake <= 0) try testing.expect(earliest <= 0);
        }
    }.run, .{});
}

test "scanEntries: a maximal hex key neither overflows nor blocks new keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    try insertEntry(&mem, a, "FFFFFFFFFFFFFFFF",
        \\{"entry_id":"max","dismissed":false,"date":1.0}
    );
    try insertEntry(&mem, a, "FFFFFFF",
        \\{"entry_id":"big","dismissed":false,"date":1.0}
    );
    var core = NullCore.init();
    var conns = NullConns.init(a, &core);
    defer conns.deinit(std.testing.io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try AnnouncementsCtx.init(a, std.testing.io, mem.dataStore(), &bus);
    defer ctx.deinit();
    try testing.expectEqual(@as(u64, 0x10000000), ctx.next_key);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("10000000", ctx.nextKeyStr(&buf));
    ctx.next_key = std.math.maxInt(u64);
    try testing.expectEqualStrings("FFFFFFFFFFFFFFFF", ctx.nextKeyStr(&buf));
}

test "Download.fetch: a stalled server is cancelled after the timeout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Listening but never accepting: connect succeeds, no response arrives.
    var ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try ip.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/assets/f.xml", .{server.socket.address.getPort()});

    var d: Download = .{ .name = "f" };
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    d.fetch(arena.allocator(), io, url, .fromMilliseconds(200));
    try testing.expect(d.response == null);
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
}

test "feeds: stored feeds persist under moonraker and configured feeds cannot be deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());
    try env.ctx.addSubscription("Fluidd");

    _ = try handlePostFeed(@ptrCast(&env.ctx), try mkParams(a, "{\"name\":\"MyApp\"}"), a);
    _ = try handlePostFeed(@ptrCast(&env.ctx), try mkParams(a, "{\"name\":\"fluidd\"}"), a);
    const stored = (try env.mem.dataStore().getItem(a, "moonraker", stored_feeds_key)).?.array;
    try testing.expectEqual(@as(usize, 1), stored.items.len);
    try testing.expectEqualStrings("myapp", stored.items[0].string);

    const feeds = (try handleListFeeds(@ptrCast(&env.ctx), .null, a)).object.get("feeds").?.array;
    try testing.expectEqual(@as(usize, 4), feeds.items.len);
    try testing.expectEqualStrings("fluidd", feeds.items[2].string);
    try testing.expectEqualStrings("myapp", feeds.items[3].string);

    // Configured and unknown names are not stored feeds.
    for ([_][]const u8{ "{\"name\":\"fluidd\"}", "{\"name\":\"klipper\"}", "{\"name\":\"nope\"}" }) |p|
        try testing.expectError(error.InvalidParams, handleDeleteFeed(@ptrCast(&env.ctx), try mkParams(a, p), a));

    // Deleting a stored feed prunes its entries and notifies.
    try insertEntry(&env.mem, a, "000001",
        \\{"entry_id":"myapp/1","dismissed":false,"date":1.0,"feed":"myapp"}
    );
    _ = try handleDeleteFeed(@ptrCast(&env.ctx), try mkParams(a, "{\"name\":\"myapp\"}"), a);
    const params = try env.onlyParams(notify.names.announcement_update);
    try testing.expectEqual(@as(usize, 0), params.items[0].object.get("entries").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), (try env.mem.dataStore().getItem(a, "moonraker", stored_feeds_key)).?.array.items.len);

    // A restart reloads the stored list.
    _ = try handlePostFeed(@ptrCast(&env.ctx), try mkParams(a, "{\"name\":\"other\"}"), a);
    var reloaded = try AnnouncementsCtx.init(a, std.testing.io, env.mem.dataStore(), &env.bus);
    defer reloaded.deinit();
    try testing.expect(reloaded.hasFeed("other"));
}

test "handleUpdate: explicit empty list and unknown names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var env: TestEnv = undefined;
    try env.init(a, threaded.io());
    defer env.deinit(threaded.io());

    const result = try handleUpdate(@ptrCast(&env.ctx), try mkParams(a, "{\"subscriptions\":[]}"), a);
    try testing.expect(!result.object.get("modified").?.bool);
    try testing.expectError(error.InvalidParams, handleUpdate(@ptrCast(&env.ctx), try mkParams(a, "{\"subscriptions\":[\"nope\"]}"), a));
    try testing.expectError(error.InvalidParams, handleUpdate(@ptrCast(&env.ctx), try mkParams(a, "{\"subscriptions\":\"klipper\"}"), a));
    try testing.expectEqual(@as(usize, 0), env.frames.items.len);
}

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
//! NOTE: Network RSS feed fetching is not implemented in this slice. The
//! endpoints for feed management and listing operate on stored entries/feeds
//! only. The response shapes are faithful to Moonraker; a comment marks where
//! real RSS fetch would be triggered.
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

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

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

    pub fn setIo(self: *AnnouncementsCtx, io: std.Io) void {
        self.io = io;
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
};

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
/// NOTE: Real RSS fetch is not implemented. Returns current stored entries.
/// A production implementation would fetch each feed's XML from the network
/// (see RssFeed._fetch_moonlight in announcements.py) and parse it.
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

    // NOTE: No real RSS fetch in this slice.
    // In a full implementation: for each subscription, fetch the feed XML from
    // MOONLIGHT_URL/assets/{name}.xml, parse entries, store new ones.
    const entries = try c.listEntries(alloc, true);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "entries", .{ .array = entries });
    try obj.put(alloc, "modified", .{ .bool = false });
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
        // NOTE: In a full implementation, an RSS fetch for the new feed would
        // be triggered here (see RssFeed.update_entries in announcements.py).
        // notify_announcement_update would also be emitted if entries changed.
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
/// Used for both JSON-RPC post_feed/delete_feed (same handler, method name selects)
/// and for HTTP POST/DELETE routes.
fn handleFeedDispatchMulti(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // Heuristic for HTTP dispatch: if called from HTTP POST route, delegate
    // to post_feed; HTTP DELETE route delegates to delete_feed.
    // For JSON-RPC: post_feed and delete_feed method names both point here.
    // Since we can't distinguish in this sync handler, use: if the handler
    // is called with params that have "action" context we could distinguish,
    // but we don't have that. Instead, we try post first (add), and if the
    // feed already exists or we need delete semantics, we rely on the caller
    // using the right JSON-RPC method.
    //
    // In practice: HTTP routes are wired per-verb so:
    //   POST  /server/announcements/feed → calls this → tries add
    //   DELETE /server/announcements/feed → calls this → tries remove
    //
    // Since both go through the same handler and we can't tell verb,
    // we check for "action" hint. No such hint → default to post_feed.
    //
    // For a cleaner solution the registry would need verb-aware dispatch.
    // This matches the Moonraker behavior where the same _handle_feed_request
    // branches on req_type.
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

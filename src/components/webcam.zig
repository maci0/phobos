//! server.webcams.* API component — Moonraker-compatible webcam management.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/webcam.py` (WebcamManager):
//!
//!   GET             /server/webcams/list  → server.webcams.list
//!   GET/POST/DELETE /server/webcams/item  → multi-verb:
//!                                           server.webcams.get_item
//!                                           server.webcams.post_item
//!                                           server.webcams.delete_item
//!   POST            /server/webcams/test  → server.webcams.test
//!
//! Webcam record shape (WebCam.as_dict, public fields):
//!   name, enabled, icon, aspect_ratio, target_fps, target_fps_idle,
//!   location, service, stream_url, snapshot_url, flip_horizontal,
//!   flip_vertical, rotation, source, extra_data, uid
//!
//! Webcams are persisted in the DataStore under namespace "webcams" with
//! key = uid (matches Moonraker: db.insert_item("webcams", webcam.uid, cam_data)).
//!
//! notify_webcams_changed is emitted on POST and DELETE (matches webcam.py).
//! Payload: {"webcams": [...]} wrapped in a 1-element array per Moonraker bus.
//!
//! POST /server/webcams/item params (WebCam.from_web_request):
//!   name (required), enabled, icon, aspect_ratio, target_fps,
//!   target_fps_idle, location, service, stream_url (required), snapshot_url,
//!   flip_horizontal, flip_vertical, rotation, extra_data
//!
//! DELETE /server/webcams/item params: name or uid (webcam source must be "database")
//! GET /server/webcams/item params: name or uid
//! POST /server/webcams/test params: name or uid
//!   Response: {"name": ..., "snapshot_reachable": false, "snapshot_url": ..., "stream_url": ...}
//!
//! NOTE: webcam.py stores cams using camelCase field names in the DB (CAM_FIELDS
//! mapping). We replicate that mapping faithfully.

const std = @import("std");
const registry = @import("../server/registry.zig");
const clock = @import("../util/clock.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Webcam record (mirrors WebCam fields)
// ---------------------------------------------------------------------------

pub const Webcam = struct {
    // API field names (as returned by as_dict)
    name: []const u8,
    enabled: bool,
    icon: []const u8,
    aspect_ratio: []const u8,
    target_fps: i64,
    target_fps_idle: i64,
    location: []const u8,
    service: []const u8,
    stream_url: []const u8,
    snapshot_url: []const u8,
    flip_horizontal: bool,
    flip_vertical: bool,
    rotation: i64,
    source: []const u8,
    extra_data: std.json.ObjectMap,
    uid: []const u8,

    /// Serialize to JSON object (as_dict equivalent).
    /// All string values are duplicated into `alloc` so the returned value
    /// is safe to use after the Webcam is freed.
    pub fn asJson(self: *const Webcam, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "name", .{ .string = try alloc.dupe(u8, self.name) });
        try obj.put(alloc, "enabled", .{ .bool = self.enabled });
        try obj.put(alloc, "icon", .{ .string = try alloc.dupe(u8, self.icon) });
        try obj.put(alloc, "aspect_ratio", .{ .string = try alloc.dupe(u8, self.aspect_ratio) });
        try obj.put(alloc, "target_fps", .{ .integer = self.target_fps });
        try obj.put(alloc, "target_fps_idle", .{ .integer = self.target_fps_idle });
        try obj.put(alloc, "location", .{ .string = try alloc.dupe(u8, self.location) });
        try obj.put(alloc, "service", .{ .string = try alloc.dupe(u8, self.service) });
        try obj.put(alloc, "stream_url", .{ .string = try alloc.dupe(u8, self.stream_url) });
        try obj.put(alloc, "snapshot_url", .{ .string = try alloc.dupe(u8, self.snapshot_url) });
        try obj.put(alloc, "flip_horizontal", .{ .bool = self.flip_horizontal });
        try obj.put(alloc, "flip_vertical", .{ .bool = self.flip_vertical });
        try obj.put(alloc, "rotation", .{ .integer = self.rotation });
        try obj.put(alloc, "source", .{ .string = try alloc.dupe(u8, self.source) });
        try obj.put(alloc, "extra_data", .{ .object = self.extra_data });
        try obj.put(alloc, "uid", .{ .string = try alloc.dupe(u8, self.uid) });
        return .{ .object = obj };
    }

    /// Validate webcam fields. Returns error if invalid.
    pub fn validate(self: *const Webcam) !void {
        // rotation must be one of 0, 90, 180, 270 (webcam.py)
        if (self.rotation != 0 and self.rotation != 90 and
            self.rotation != 180 and self.rotation != 270)
        {
            return error.InvalidParams;
        }
        // aspect_ratio must be "N:M" format (webcam.py)
        const ratio = self.aspect_ratio;
        const colon = std.mem.indexOfScalar(u8, ratio, ':') orelse return error.InvalidParams;
        if (colon == 0 or colon == ratio.len - 1) return error.InvalidParams;
        for (ratio[0..colon]) |c| if (!std.ascii.isDigit(c)) return error.InvalidParams;
        for (ratio[colon + 1 ..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidParams;
    }
};

// ---------------------------------------------------------------------------
// CAM_FIELDS mapping (API field → DB field, from webcam.py)
// ---------------------------------------------------------------------------

// Maps API field name → DB (camelCase) field name for persistence.
// Extra fields (location, rotation, extra_data) stored directly.
const CamFieldMapping = struct {
    api: []const u8,
    db: []const u8,
};

const cam_fields = [_]CamFieldMapping{
    .{ .api = "name", .db = "name" },
    .{ .api = "service", .db = "service" },
    .{ .api = "target_fps", .db = "targetFps" },
    .{ .api = "stream_url", .db = "urlStream" },
    .{ .api = "snapshot_url", .db = "urlSnapshot" },
    .{ .api = "flip_horizontal", .db = "flipX" },
    .{ .api = "flip_vertical", .db = "flipY" },
    .{ .api = "enabled", .db = "enabled" },
    .{ .api = "target_fps_idle", .db = "targetFpsIdle" },
    .{ .api = "aspect_ratio", .db = "aspectRatio" },
    .{ .api = "icon", .db = "icon" },
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const WebcamCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,
    /// Allocator for owned strings in in-memory cam list
    gpa: std.mem.Allocator,
    /// In-memory map: uid → Webcam (persisted to DataStore on writes)
    cams: std.StringHashMapUnmanaged(Webcam),

    const ns: [:0]const u8 = "webcams";

    pub fn init(alloc: std.mem.Allocator, store: DataStore, bus: *NotifyBus) !WebcamCtx {
        var ctx = WebcamCtx{
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .cams = .{},
        };
        ctx.loadFromStore() catch {};
        return ctx;
    }

    pub fn setIo(self: *WebcamCtx, io: std.Io) void {
        self.io = io;
    }

    /// Emit notify_webcams_changed with current webcam list.
    /// Uses emitLocked — handlers run under the held Core lock.
    /// Payload: [{"webcams": [...]}] — matches Moonraker's _notify_webcams.
    fn emitWebcamsChanged(self: *WebcamCtx, arena: std.mem.Allocator) void {
        const io = self.io orelse return;
        const list = self.listJson(arena) catch return;
        var wrapper: std.json.ObjectMap = .empty;
        wrapper.put(arena, "webcams", list) catch return;
        var arr: std.json.Array = .init(arena);
        arr.append(.{ .object = wrapper }) catch return;
        self.bus.emitLocked(io, notify.names.webcams_changed, .{ .array = arr }) catch {};
    }

    pub fn deinit(self: *WebcamCtx) void {
        var it = self.cams.iterator();
        while (it.next()) |e| {
            freeWebcam(self.gpa, e.value_ptr);
            self.gpa.free(e.key_ptr.*);
        }
        self.cams.deinit(self.gpa);
    }

    /// Load persisted webcams from the DataStore on startup.
    fn loadFromStore(self: *WebcamCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const ns_data = self.store.getNamespace(a, ns) catch return;
        if (ns_data != .object) return;

        var it = ns_data.object.iterator();
        while (it.next()) |e| {
            const uid = e.key_ptr.*;
            const cam_data = e.value_ptr.*;
            if (cam_data != .object) continue;

            const cam = fromDbValue(self.gpa, uid, cam_data.object) catch continue;
            const uid_owned = try self.gpa.dupe(u8, uid);
            errdefer self.gpa.free(uid_owned);
            try self.cams.put(self.gpa, uid_owned, cam);
        }
    }

    /// Persist a webcam to the DataStore (matches _save_cam).
    fn saveToStore(self: *WebcamCtx, cam: *const Webcam) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const db_val = toDbValue(a, cam) catch return;
        const uid_z = a.dupeZ(u8, cam.uid) catch return;
        self.store.insertItem(a, ns, uid_z, db_val) catch {};
    }

    /// Delete a webcam from the DataStore.
    fn deleteFromStore(self: *WebcamCtx, uid: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const uid_z = a.dupeZ(u8, uid) catch return;
        _ = self.store.deleteItem(a, ns, uid_z) catch {};
    }

    /// Find cam by name (caller must hold mutex).
    pub fn findByName(self: *WebcamCtx, name: []const u8) ?*Webcam {
        var it = self.cams.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.name, name)) return e.value_ptr;
        }
        return null;
    }

    /// Find cam by uid (caller must hold mutex).
    pub fn findByUid(self: *WebcamCtx, uid: []const u8) ?*Webcam {
        return self.cams.getPtr(uid);
    }

    /// Generate a unique UID not already in use.
    fn newUid(self: *WebcamCtx, alloc: std.mem.Allocator) ![]const u8 {
        // Use a simple counter-based approach since we can't call UUID4 easily.
        // In production Moonraker uses uuid.uuid4(). We use a timestamp + count.
        const now_ns = clock.wallNanos();
        var attempt: u64 = 0;
        while (attempt < 1000) : (attempt += 1) {
            var buf: [40]u8 = undefined;
            const uid_str = try std.fmt.bufPrint(&buf, "{x:0>16}{x:0>8}", .{
                now_ns,
                attempt,
            });
            if (!self.cams.contains(uid_str)) {
                return alloc.dupe(u8, uid_str);
            }
        }
        return error.OutOfMemory;
    }

    /// Return a JSON array of all webcam dicts (for notifications and list).
    pub fn listJson(self: *WebcamCtx, alloc: std.mem.Allocator) !std.json.Value {
        var arr: std.json.Array = .init(alloc);
        var it = self.cams.iterator();
        while (it.next()) |e| {
            const v = try e.value_ptr.asJson(alloc);
            try arr.append(v);
        }
        return .{ .array = arr };
    }
};

// ---------------------------------------------------------------------------
// DB serialization helpers (CAM_FIELDS mapping)
// ---------------------------------------------------------------------------

/// Convert a Webcam to its DB representation (camelCase keys, matches _save_cam).
fn toDbValue(alloc: std.mem.Allocator, cam: *const Webcam) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // Apply CAM_FIELDS mapping
    for (cam_fields) |f| {
        if (std.mem.eql(u8, f.api, "name")) {
            try obj.put(alloc, f.db, .{ .string = cam.name });
        } else if (std.mem.eql(u8, f.api, "service")) {
            try obj.put(alloc, f.db, .{ .string = cam.service });
        } else if (std.mem.eql(u8, f.api, "target_fps")) {
            try obj.put(alloc, f.db, .{ .integer = cam.target_fps });
        } else if (std.mem.eql(u8, f.api, "stream_url")) {
            try obj.put(alloc, f.db, .{ .string = cam.stream_url });
        } else if (std.mem.eql(u8, f.api, "snapshot_url")) {
            try obj.put(alloc, f.db, .{ .string = cam.snapshot_url });
        } else if (std.mem.eql(u8, f.api, "flip_horizontal")) {
            try obj.put(alloc, f.db, .{ .bool = cam.flip_horizontal });
        } else if (std.mem.eql(u8, f.api, "flip_vertical")) {
            try obj.put(alloc, f.db, .{ .bool = cam.flip_vertical });
        } else if (std.mem.eql(u8, f.api, "enabled")) {
            try obj.put(alloc, f.db, .{ .bool = cam.enabled });
        } else if (std.mem.eql(u8, f.api, "target_fps_idle")) {
            try obj.put(alloc, f.db, .{ .integer = cam.target_fps_idle });
        } else if (std.mem.eql(u8, f.api, "aspect_ratio")) {
            try obj.put(alloc, f.db, .{ .string = cam.aspect_ratio });
        } else if (std.mem.eql(u8, f.api, "icon")) {
            try obj.put(alloc, f.db, .{ .string = cam.icon });
        }
    }
    try obj.put(alloc, "location", .{ .string = cam.location });
    try obj.put(alloc, "rotation", .{ .integer = cam.rotation });
    try obj.put(alloc, "extra_data", .{ .object = cam.extra_data });
    return .{ .object = obj };
}

/// Parse a Webcam from its DB representation (from_database equivalent).
fn fromDbValue(alloc: std.mem.Allocator, uid: []const u8, obj: std.json.ObjectMap) !Webcam {
    return Webcam{
        .name = try alloc.dupe(u8, strField(obj, "name", "")),
        .enabled = boolField(obj, "enabled", true),
        .icon = try alloc.dupe(u8, strField(obj, "icon", "mdiWebcam")),
        .aspect_ratio = try alloc.dupe(u8, strField(obj, "aspectRatio", "4:3")),
        .target_fps = intField(obj, "targetFps", 15),
        .target_fps_idle = intField(obj, "targetFpsIdle", 5),
        .location = try alloc.dupe(u8, strField(obj, "location", "printer")),
        .service = try alloc.dupe(u8, strField(obj, "service", "mjpegstreamer")),
        .stream_url = try alloc.dupe(u8, strField(obj, "urlStream", "")),
        .snapshot_url = try alloc.dupe(u8, strField(obj, "urlSnapshot", "")),
        .flip_horizontal = boolField(obj, "flipX", false),
        .flip_vertical = boolField(obj, "flipY", false),
        .rotation = intField(obj, "rotation", 0),
        .source = try alloc.dupe(u8, "database"),
        .extra_data = .empty,
        .uid = try alloc.dupe(u8, uid),
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .string => |s| s,
        else => default,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => default,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    const v = obj.get(key) orelse return default;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

/// Free all owned strings in a Webcam.
fn freeWebcam(alloc: std.mem.Allocator, cam: *Webcam) void {
    alloc.free(cam.name);
    alloc.free(cam.icon);
    alloc.free(cam.aspect_ratio);
    alloc.free(cam.location);
    alloc.free(cam.service);
    alloc.free(cam.stream_url);
    alloc.free(cam.snapshot_url);
    alloc.free(cam.source);
    alloc.free(cam.uid);
}

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

fn getOptBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .bool => |b| b,
                .string => |s| std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                .null => null,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

fn getOptInt(params: std.json.Value, field: []const u8, default_val: i64) i64 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return default_val;
            return switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                .string => |s| std.fmt.parseInt(i64, s, 10) catch default_val,
                else => default_val,
            };
        },
        else => return default_val,
    }
}

fn getOptObj(params: std.json.Value, field: []const u8) std.json.ObjectMap {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return .empty;
            return switch (v) {
                .object => |o| o,
                else => .empty,
            };
        },
        else => return .empty,
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/webcams/list → {"webcams": [...]}
pub fn handleWebcamList(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));
    const list = try c.listJson(alloc);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcams", list);
    return .{ .object = result };
}

/// GET /server/webcams/item → {"webcam": {...}}
pub fn handleWebcamGet(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));
    const cam = lookupCamera(c, params, true) orelse return error.NotFound;
    const cam_json = try cam.asJson(alloc);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcam", cam_json);
    return .{ .object = result };
}

/// POST /server/webcams/item → {"webcam": {...}}
/// Creates or updates a webcam; emits notify_webcams_changed.
pub fn handleWebcamPost(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    // Look up existing cam (optional for POST — creates if absent)
    const existing = lookupCamera(c, params, false);

    if (existing) |cam| {
        // Update path: check source
        if (std.mem.eql(u8, cam.source, "config")) {
            return error.Forbidden;
        }
        // Apply updates from params
        try updateCamFromParams(c.gpa, cam, params, c);
        try cam.validate();
        c.saveToStore(cam);
    } else {
        // Create new webcam
        const name = try getStr(params, "name");
        const uid = try c.newUid(alloc);
        errdefer alloc.free(uid);

        // Check for name collision
        if (c.findByName(name) != null) return error.InvalidParams;

        const new_cam = try camFromWebRequest(c.gpa, params, uid);
        try new_cam.validate();

        const uid_owned = try c.gpa.dupe(u8, uid);
        errdefer c.gpa.free(uid_owned);
        alloc.free(uid); // we duped it

        try c.cams.put(c.gpa, uid_owned, new_cam);
        const stored_cam = c.cams.getPtr(uid_owned).?;
        c.saveToStore(stored_cam);
    }

    const cam_ptr = lookupCamera(c, params, true).?;
    const cam_json = try cam_ptr.asJson(alloc);
    c.emitWebcamsChanged(alloc);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcam", cam_json);
    return .{ .object = result };
}

/// DELETE /server/webcams/item → {"webcam": {...}}
/// Deletes a webcam (source must be "database"); emits notify_webcams_changed.
pub fn handleWebcamDelete(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    const cam = lookupCamera(c, params, true) orelse return error.NotFound;

    if (std.mem.eql(u8, cam.source, "config")) {
        return error.Forbidden;
    }

    const cam_json = try cam.asJson(alloc);

    const uid_copy = try alloc.dupe(u8, cam.uid);
    defer alloc.free(uid_copy);

    // Remove from in-memory map and persist deletion
    if (c.cams.fetchRemove(uid_copy)) |kv| {
        var val = kv.value;
        freeWebcam(c.gpa, &val);
        c.gpa.free(kv.key);
    }
    c.deleteFromStore(uid_copy);

    c.emitWebcamsChanged(alloc);

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcam", cam_json);
    return .{ .object = result };
}

/// GET an `http(s)://` snapshot URL and report whether it responded with a
/// success status (Moonraker `_handle_webcam_test`: `snapshot_reachable = not
/// ret.has_error()`). Returns false for non-http URLs or when no io is wired
/// (tests). Note: std.http.Client.fetch has no per-request timeout here, mirroring
/// spoolman's proxy — an unroutable host can block until the OS TCP timeout.
fn probeSnapshot(io: std.Io, gpa: std.mem.Allocator, url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http")) return false;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var client: std.http.Client = .{ .allocator = aa, .io = io };
    defer client.deinit();
    var sink: [4096]u8 = undefined;
    var disc: std.Io.Writer.Discarding = .init(&sink);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &disc.writer,
    }) catch return false;
    return result.status.class() == .success;
}

/// POST /server/webcams/test → {"name", "snapshot_reachable", "snapshot_url", "stream_url"}.
/// Probes the snapshot URL when io is wired and the URL is http(s).
pub fn handleWebcamTest(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    const cam = lookupCamera(c, params, true) orelse return error.NotFound;

    const reachable = if (c.io) |io| probeSnapshot(io, c.gpa, cam.snapshot_url) else false;

    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "name", .{ .string = cam.name });
    try result.put(alloc, "snapshot_reachable", .{ .bool = reachable });
    try result.put(alloc, "snapshot_url", .{ .string = cam.snapshot_url });
    try result.put(alloc, "stream_url", .{ .string = cam.stream_url });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Look up a webcam by uid (preferred) or name. Returns null if not found.
/// When `required` is true and not found, caller should return error.NotFound.
fn lookupCamera(c: *WebcamCtx, params: std.json.Value, _: bool) ?*Webcam {
    if (getOptStr(params, "uid")) |uid| {
        return c.findByUid(uid);
    }
    if (getOptStr(params, "name")) |name| {
        return c.findByName(name);
    }
    return null;
}

/// Create a new Webcam from web request params (from_web_request equivalent).
fn camFromWebRequest(alloc: std.mem.Allocator, params: std.json.Value, uid: []const u8) !Webcam {
    const name = try getStr(params, "name");
    const stream_url = try getStr(params, "stream_url");
    return Webcam{
        .name = try alloc.dupe(u8, name),
        .enabled = getOptBool(params, "enabled", true),
        .icon = try alloc.dupe(u8, getOptStr(params, "icon") orelse "mdiWebcam"),
        .aspect_ratio = try alloc.dupe(u8, getOptStr(params, "aspect_ratio") orelse "4:3"),
        .target_fps = getOptInt(params, "target_fps", 15),
        .target_fps_idle = getOptInt(params, "target_fps_idle", 5),
        .location = try alloc.dupe(u8, getOptStr(params, "location") orelse "printer"),
        .service = try alloc.dupe(u8, getOptStr(params, "service") orelse "mjpegstreamer"),
        .stream_url = try alloc.dupe(u8, stream_url),
        .snapshot_url = try alloc.dupe(u8, getOptStr(params, "snapshot_url") orelse ""),
        .flip_horizontal = getOptBool(params, "flip_horizontal", false),
        .flip_vertical = getOptBool(params, "flip_vertical", false),
        .rotation = getOptInt(params, "rotation", 0),
        .source = try alloc.dupe(u8, "database"),
        .extra_data = getOptObj(params, "extra_data"),
        .uid = try alloc.dupe(u8, uid),
    };
}

/// Apply updates from POST params to an existing webcam (update equivalent).
fn updateCamFromParams(alloc: std.mem.Allocator, cam: *Webcam, params: std.json.Value, c: *WebcamCtx) !void {
    // Handle name rename
    if (getOptStr(params, "name")) |new_name| {
        if (!std.mem.eql(u8, cam.name, new_name)) {
            if (c.findByName(new_name) != null) return error.InvalidParams;
            alloc.free(cam.name);
            cam.name = try alloc.dupe(u8, new_name);
        }
    }
    if (getOptStr(params, "icon")) |v| {
        alloc.free(cam.icon);
        cam.icon = try alloc.dupe(u8, v);
    }
    if (getOptStr(params, "aspect_ratio")) |v| {
        alloc.free(cam.aspect_ratio);
        cam.aspect_ratio = try alloc.dupe(u8, v);
    }
    if (getOptStr(params, "location")) |v| {
        alloc.free(cam.location);
        cam.location = try alloc.dupe(u8, v);
    }
    if (getOptStr(params, "service")) |v| {
        alloc.free(cam.service);
        cam.service = try alloc.dupe(u8, v);
    }
    if (getOptStr(params, "stream_url")) |v| {
        alloc.free(cam.stream_url);
        cam.stream_url = try alloc.dupe(u8, v);
    }
    if (getOptStr(params, "snapshot_url")) |v| {
        alloc.free(cam.snapshot_url);
        cam.snapshot_url = try alloc.dupe(u8, v);
    }

    // Numeric/bool fields
    switch (params) {
        .object => |obj| {
            if (obj.get("enabled")) |v| cam.enabled = switch (v) {
                .bool => |b| b,
                else => cam.enabled,
            };
            if (obj.get("flip_horizontal")) |v| cam.flip_horizontal = switch (v) {
                .bool => |b| b,
                else => cam.flip_horizontal,
            };
            if (obj.get("flip_vertical")) |v| cam.flip_vertical = switch (v) {
                .bool => |b| b,
                else => cam.flip_vertical,
            };
            if (obj.get("target_fps")) |v| cam.target_fps = switch (v) {
                .integer => |i| i,
                else => cam.target_fps,
            };
            if (obj.get("target_fps_idle")) |v| cam.target_fps_idle = switch (v) {
                .integer => |i| i,
                else => cam.target_fps_idle,
            };
            if (obj.get("rotation")) |v| cam.rotation = switch (v) {
                .integer => |i| i,
                else => cam.rotation,
            };
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerWebcam(reg: *Registry, ctx: *WebcamCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // GET /server/webcams/list — single verb → "server.webcams.list"
    try reg.registerEndpoint(
        .{ .path = "/server/webcams/list", .methods = &.{.GET} },
        c,
        handleWebcamList,
    );

    // /server/webcams/item — Moonraker verb-prefixes the trio:
    // server.webcams.get_item / post_item / delete_item (Mainsail/Fluidd call
    // post_item + delete_item over WS to save/remove webcams). multi_verb on each.
    try reg.registerEndpoint(
        .{ .path = "/server/webcams/item", .methods = &.{.GET}, .multi_verb = true },
        c,
        handleWebcamGet,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/webcams/item", .methods = &.{.POST}, .multi_verb = true },
        c,
        handleWebcamPost,
    );
    try reg.registerEndpoint(
        .{ .path = "/server/webcams/item", .methods = &.{.DELETE}, .multi_verb = true },
        c,
        handleWebcamDelete,
    );

    // POST /server/webcams/test — single verb → "server.webcams.test"
    try reg.registerEndpoint(
        .{ .path = "/server/webcams/test", .methods = &.{.POST} },
        c,
        handleWebcamTest,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ds_mod = @import("../store/datastore.zig");

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// Minimal null bus for tests that don't need notifications.
// IMPORTANT: NullBus must not be moved after init (contains self-referential pointers).
// Always store in a variable and pass a pointer to it.
const NullBus = struct {
    core: @import("../server/core.zig").Core,
    conns_obj: @import("../server/connections.zig").Connections,
    bus: NotifyBus,

    fn init(alloc: std.mem.Allocator) NullBus {
        var nb: NullBus = undefined;
        nb.core = @import("../server/core.zig").Core.init();
        nb.conns_obj = @import("../server/connections.zig").Connections.init(alloc, &nb.core);
        nb.bus = NotifyBus.init(&nb.core, &nb.conns_obj);
        return nb;
    }
};

// Minimal NullStore for tests
const NullDS = struct {
    fn vtGetItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds_mod.Error!?std.json.Value {
        return null;
    }
    fn vtInsert(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds_mod.Error!void {}
    fn vtUpdate(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds_mod.Error!void {}
    fn vtDelete(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds_mod.Error!std.json.Value {
        return ds_mod.Error.KeyNotFound;
    }
    fn vtList(_: *anyopaque, arena: std.mem.Allocator) ds_mod.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }
    fn vtGetNs(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds_mod.Error!std.json.Value {
        return .{ .object = .empty };
    }
    const vtable: ds_mod.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsert,
        .updateItem = vtUpdate,
        .deleteItem = vtDelete,
        .listNamespaces = vtList,
        .getNamespace = vtGetNs,
    };
    var _ctx: u8 = 0;
    fn dataStore() DataStore {
        return .{ .ctx = @ptrCast(&_ctx), .vtable = &vtable };
    }
};

fn makeCtx(alloc: std.mem.Allocator, nb: *NullBus) !WebcamCtx {
    return WebcamCtx.init(alloc, NullDS.dataStore(), &nb.bus);
}

test "handleWebcamList: empty store returns empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const result = try handleWebcamList(@ptrCast(&ctx), .null, a);
    const webcams = result.object.get("webcams").?.array;
    try testing.expectEqual(@as(usize, 0), webcams.items.len);
}

test "webcam CRUD: create, get, update, delete round-trip" {
    // Use smp_allocator for ctx internals (mimics production), arena for handler allocs
    const ctx_alloc = std.heap.smp_allocator;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(ctx_alloc);
    var ctx = try WebcamCtx.init(ctx_alloc, NullDS.dataStore(), &nb.bus);
    defer ctx.deinit();

    // Create via POST
    const post_params = try mkParams(a, "{\"name\":\"cam1\",\"stream_url\":\"http://localhost/stream\"}");
    const post_result = try handleWebcamPost(@ptrCast(&ctx), post_params, a);
    const cam_json = post_result.object.get("webcam").?.object;
    try testing.expectEqualStrings("cam1", cam_json.get("name").?.string);
    try testing.expectEqualStrings("http://localhost/stream", cam_json.get("stream_url").?.string);
    try testing.expectEqualStrings("database", cam_json.get("source").?.string);
    try testing.expect(cam_json.get("uid") != null);

    // List should show one cam
    const list_result = try handleWebcamList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 1), list_result.object.get("webcams").?.array.items.len);

    // Get by name
    const get_params = try mkParams(a, "{\"name\":\"cam1\"}");
    const get_result = try handleWebcamGet(@ptrCast(&ctx), get_params, a);
    try testing.expectEqualStrings("cam1", get_result.object.get("webcam").?.object.get("name").?.string);

    // Delete by name
    const del_params = try mkParams(a, "{\"name\":\"cam1\"}");
    const del_result = try handleWebcamDelete(@ptrCast(&ctx), del_params, a);
    try testing.expectEqualStrings("cam1", del_result.object.get("webcam").?.object.get("name").?.string);

    // List should be empty again
    const list2 = try handleWebcamList(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(usize, 0), list2.object.get("webcams").?.array.items.len);
}

test "webcam: get non-existent cam → NotFound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"nonexistent\"}");
    try testing.expectError(error.NotFound, handleWebcamGet(@ptrCast(&ctx), params, a));
}

test "webcam: invalid rotation → InvalidParams on create" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"rotation\":45}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: invalid aspect_ratio → InvalidParams on create" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"aspect_ratio\":\"bad\"}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: test endpoint returns snapshot_reachable=false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const create_params = try mkParams(a, "{\"name\":\"cam2\",\"stream_url\":\"http://cam/stream\",\"snapshot_url\":\"http://cam/snap\"}");
    _ = try handleWebcamPost(@ptrCast(&ctx), create_params, a);

    const test_params = try mkParams(a, "{\"name\":\"cam2\"}");
    const result = try handleWebcamTest(@ptrCast(&ctx), test_params, a);
    try testing.expectEqual(false, result.object.get("snapshot_reachable").?.bool);
    try testing.expectEqualStrings("cam2", result.object.get("name").?.string);
}

test "probeSnapshot: non-http URLs are unreachable (no network attempt)" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(!probeSnapshot(io, testing.allocator, "rtsp://example/stream"));
    try testing.expect(!probeSnapshot(io, testing.allocator, "ftp://host/x"));
    try testing.expect(!probeSnapshot(io, testing.allocator, ""));
    try testing.expect(!probeSnapshot(io, testing.allocator, "webcam/?action=snapshot"));
}

test "fuzz probeSnapshot: non-http schemes never crash and never reach the network" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var tail: [32]u8 = undefined;
            smith.bytesWithHash(&tail, 0);
            // Force a non-http scheme so the guard returns before any fetch.
            var url: [40]u8 = undefined;
            const wrote = std.fmt.bufPrint(&url, "zz://{s}", .{tail[0..@min(tail.len, 30)]}) catch return;
            try testing.expect(!probeSnapshot(io, testing.allocator, wrote));
        }
    }.run, .{});
}

test "webcam: POST missing name → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"stream_url\":\"http://x\"}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: POST missing stream_url → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"cam1\"}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "registerWebcam: wires routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var nb = NullBus.init(alloc);
    var ctx = try makeCtx(alloc, &nb);
    defer ctx.deinit();

    try registerWebcam(&reg, &ctx);

    // HTTP routes present
    try testing.expect(reg.lookup(.GET, "/server/webcams/list") != null);
    try testing.expect(reg.lookup(.GET, "/server/webcams/item") != null);
    try testing.expect(reg.lookup(.POST, "/server/webcams/item") != null);
    try testing.expect(reg.lookup(.DELETE, "/server/webcams/item") != null);
    try testing.expect(reg.lookup(.POST, "/server/webcams/test") != null);

    // JSON-RPC methods: item is verb-prefixed (get_item/post_item/delete_item)
    try testing.expect(d.methods.get("server.webcams.list") != null);
    try testing.expect(d.methods.get("server.webcams.get_item") != null);
    try testing.expect(d.methods.get("server.webcams.post_item") != null);
    try testing.expect(d.methods.get("server.webcams.delete_item") != null);
    try testing.expect(d.methods.get("server.webcams.item") == null); // renamed
    try testing.expect(d.methods.get("server.webcams.test") != null);
    // POST and DELETE are HTTP-only, no JSON-RPC methods
}

// --- Fuzz tests ---

test "fuzz handleWebcamList: never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &nb) catch return;
            defer ctx.deinit();
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleWebcamList(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleWebcamPost: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &nb) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"cam1\",\"stream_url\":\"http://x\"}",
                "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"rotation\":45}",
                "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"rotation\":90}",
                "{\"stream_url\":\"http://x\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleWebcamPost(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleWebcamGet: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &nb) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"cam1\"}",
                "{\"uid\":\"abc123\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleWebcamGet(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleWebcamDelete: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &nb) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"cam1\"}",
                "{\"uid\":\"abc123\"}",
                "{\"uid\":\"nonexistent\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleWebcamDelete(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleWebcamTest: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var nb = NullBus.init(a);
            var ctx = makeCtx(a, &nb) catch return;
            defer ctx.deinit();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);

            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"name\":\"cam1\"}",
                "{\"uid\":\"abc123\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleWebcamTest(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz Webcam.validate: never panics on arbitrary field values" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const name = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const icon = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const aspect_ratio = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const location = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const service = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const stream_url = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const snapshot_url = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const source = a.dupe(u8, &buf) catch return;
            smith.bytesWithHash(&buf, 0);
            const uid = a.dupe(u8, &buf) catch return;

            var cam = Webcam{
                .name = name,
                .enabled = smith.valueWithHash(bool, 0),
                .icon = icon,
                .aspect_ratio = aspect_ratio,
                .target_fps = smith.valueWithHash(i64, 0),
                .target_fps_idle = smith.valueWithHash(i64, 0),
                .location = location,
                .service = service,
                .stream_url = stream_url,
                .snapshot_url = snapshot_url,
                .flip_horizontal = smith.valueWithHash(bool, 0),
                .flip_vertical = smith.valueWithHash(bool, 0),
                .rotation = smith.valueRangeLessThanWithHash(i64, 0, 360, 0),
                .source = source,
                .extra_data = .empty,
                .uid = uid,
            };
            _ = cam.validate() catch {};
        }
    }.run, .{});
}

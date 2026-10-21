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
//!   Response: {"name": ..., "snapshot_reachable": bool, "snapshot_url": ..., "stream_url": ...}
//!   Relative URLs use the routed local address, with a loopback fallback.
//!   Local wildcard listeners are rewritten to loopback. DNS and the snapshot
//!   GET run with Core released and each is cancelled after 2 s.
//!
//! A `uid` param naming no webcam is a 404 for every verb. New webcams get a
//! random UUID4. Config webcams list first; a database webcam with a config
//! webcam's name is hidden, and its row is kept.
//!
//! NOTE: webcam.py stores cams using camelCase field names in the DB (CAM_FIELDS
//! mapping). We replicate that mapping faithfully.

const std = @import("std");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const sleep = @import("../util/sleep.zig");
const webreq = @import("../json/params.zig");
const http_get = @import("http_get.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const machine = @import("machine.zig");

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

    fn dupe(self: Webcam, alloc: std.mem.Allocator) !Webcam {
        var owned = self;
        inline for (comptime std.meta.fieldNames(Webcam)) |field| {
            if (@TypeOf(@field(owned, field)) == []const u8) @field(owned, field) = "";
        }
        owned.extra_data = .empty;
        errdefer freeWebcam(alloc, &owned);
        inline for (comptime std.meta.fieldNames(Webcam)) |field| {
            if (@TypeOf(@field(owned, field)) == []const u8) @field(owned, field) = try alloc.dupe(u8, @field(self, field));
        }
        owned.extra_data = (try jv.deepCopy(alloc, .{ .object = self.extra_data })).object;
        return owned;
    }

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
        try obj.put(alloc, "extra_data", try jv.deepCopy(alloc, .{ .object = self.extra_data }));
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

/// Moonraker `uuid.uuid5(instance_uuid, "moonraker.webcam.<name>")`.
/// `instance_uuid` is 32 hex chars or a dashed UUID. The result is the
/// dashed form Klipper frontends store.
pub fn configWebcamUid(instance_uuid: []const u8, name: []const u8, buf: *[36]u8) ![]const u8 {
    var ns: [16]u8 = undefined;
    try parseUuid(instance_uuid, &ns);
    const prefix = "moonraker.webcam.";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(&ns);
    hasher.update(prefix);
    hasher.update(name);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);
    var bytes: [16]u8 = undefined;
    @memcpy(bytes[0..16], digest[0..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return formatUuid(&bytes, buf);
}

fn parseUuid(text: []const u8, out: *[16]u8) !void {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var hex: [32]u8 = undefined;
    if (s.len == 32) {
        @memcpy(hex[0..32], s[0..32]);
    } else if (s.len == 36 and s[8] == '-' and s[13] == '-' and s[18] == '-' and s[23] == '-') {
        var n: usize = 0;
        for (s) |c| {
            if (c == '-') continue;
            if (n >= 32) return error.InvalidUuid;
            hex[n] = c;
            n += 1;
        }
        if (n != 32) return error.InvalidUuid;
    } else return error.InvalidUuid;
    _ = std.fmt.hexToBytes(out, &hex) catch return error.InvalidUuid;
}

/// Lowercase 32-hex form of an instance UUID. Accepts dashed or bare hex.
pub fn canonicalInstanceHex(text: []const u8, out: *[32]u8) bool {
    var bytes: [16]u8 = undefined;
    parseUuid(text, &bytes) catch return false;
    out.* = std.fmt.bytesToHex(bytes, .lower);
    return true;
}

fn formatUuid(bytes: *const [16]u8, buf: *[36]u8) []const u8 {
    const hex = std.fmt.bytesToHex(bytes.*, .lower);
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

pub const WebcamCtx = struct {
    clock_io: std.Io,
    store: DataStore,
    bus: *NotifyBus,
    io: ?std.Io,
    machine_ctx: ?*machine.MachineCtx = null,
    /// Allocator for owned strings in in-memory cam list
    gpa: std.mem.Allocator,
    /// In-memory map: uid → Webcam (persisted to DataStore on writes)
    cams: std.StringHashMapUnmanaged(Webcam),
    /// Insertion order of uids (borrowing the map keys): config webcams in
    /// config order, then database webcams, as Moonraker's webcam dict.
    order: std.ArrayList([]const u8) = .empty,
    /// Number of config webcams at the front of `order`.
    config_count: usize = 0,
    /// Datadir `.moonraker.uuid`. Empty uses the nil UUID.
    instance_uuid: []const u8 = "",

    const ns: [:0]const u8 = "webcams";

    pub fn init(alloc: std.mem.Allocator, clock_io: std.Io, store: DataStore, bus: *NotifyBus) !WebcamCtx {
        var ctx = WebcamCtx{
            .clock_io = clock_io,
            .store = store,
            .bus = bus,
            .io = null,
            .gpa = alloc,
            .cams = .{},
        };
        ctx.loadFromStore() catch |err| {
            std.debug.print("phobos: warning: failed to load webcams from store: {} — saved webcams unavailable\n", .{err});
        };
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
        self.order.deinit(self.gpa);
    }

    /// Remove `uid` from `order`, keeping `config_count` in step.
    fn untrack(self: *WebcamCtx, uid: []const u8) void {
        for (self.order.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item, uid)) continue;
            _ = self.order.orderedRemove(i);
            if (i < self.config_count) self.config_count -= 1;
            return;
        }
    }

    /// Forget the webcam named `name` in memory. Its database row stays:
    /// Moonraker ignores a database webcam whose name a config webcam uses.
    fn dropByName(self: *WebcamCtx, name: []const u8) void {
        const existing = self.findByName(name) orelse return;
        // `existing.uid` is a separate allocation from the map key and stays
        // valid until `freeWebcam` below.
        self.untrack(existing.uid);
        const kv = self.cams.fetchRemove(existing.uid).?;
        var val = kv.value;
        freeWebcam(self.gpa, &val);
        self.gpa.free(kv.key);
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

            var cam = fromDbValue(self.gpa, uid, cam_data.object) catch continue;
            errdefer freeWebcam(self.gpa, &cam);
            const uid_owned = try self.gpa.dupe(u8, uid);
            errdefer self.gpa.free(uid_owned);
            try self.order.ensureUnusedCapacity(self.gpa, 1);
            try self.cams.put(self.gpa, uid_owned, cam);
            self.order.appendAssumeCapacity(uid_owned);
        }
    }

    /// Persist a webcam to the DataStore (matches _save_cam).
    fn saveToStore(self: *WebcamCtx, cam: *const Webcam) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const db_val = toDbValue(a, cam) catch return;
        self.store.insertItem(a, ns, cam.uid, db_val) catch |err| {
            std.debug.print("phobos: warning: failed to persist webcam '{s}': {} — change will be lost on restart\n", .{ cam.uid, err });
        };
    }

    /// Delete a webcam from the DataStore.
    fn deleteFromStore(self: *WebcamCtx, uid: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        _ = self.store.deleteItem(a, ns, uid) catch |err| switch (err) {
            error.KeyNotFound => {}, // idempotent delete — nothing persisted
            else => std.debug.print("phobos: warning: failed to delete webcam '{s}' from store: {} — may reappear on restart\n", .{ uid, err }),
        };
    }

    /// One `[webcam <name>]` section. `stream_url` is required. Strings are
    /// borrowed for the call and copied into the webcam table.
    pub const ConfigCam = struct {
        name: []const u8,
        enabled: bool = true,
        icon: []const u8 = "mdiWebcam",
        aspect_ratio: []const u8 = "4:3",
        target_fps: i64 = 15,
        target_fps_idle: i64 = 5,
        location: []const u8 = "printer",
        service: []const u8 = "mjpegstreamer",
        stream_url: []const u8,
        snapshot_url: []const u8 = "",
        flip_horizontal: bool = false,
        flip_vertical: bool = false,
        rotation: i64 = 0,
    };

    /// Load a config-sourced webcam. Moonraker `WebCam.from_config`: source is
    /// `config`, so later POST/DELETE of this name is forbidden. The uid is
    /// `uuid5(instance_uuid, "moonraker.webcam.<name>")`. A second add of the
    /// same name keeps the first record when that uid already matches.
    /// A stored cam with a different uid is replaced.
    pub fn addFromConfig(self: *WebcamCtx, spec: ConfigCam) !void {
        if (spec.name.len == 0 or spec.stream_url.len == 0) return error.InvalidParams;
        const gpa = self.gpa;
        var uid_buf: [36]u8 = undefined;
        const namespace = if (self.instance_uuid.len == 0) "00000000000000000000000000000000" else self.instance_uuid;
        const uid_tmp = try configWebcamUid(namespace, spec.name, &uid_buf);
        if (self.findByName(spec.name)) |existing| {
            if (std.mem.eql(u8, existing.uid, uid_tmp)) return;
        }
        var cam = try (Webcam{
            .name = spec.name,
            .enabled = spec.enabled,
            .icon = spec.icon,
            .aspect_ratio = spec.aspect_ratio,
            .target_fps = spec.target_fps,
            .target_fps_idle = spec.target_fps_idle,
            .location = spec.location,
            .service = spec.service,
            .stream_url = spec.stream_url,
            .snapshot_url = spec.snapshot_url,
            .flip_horizontal = spec.flip_horizontal,
            .flip_vertical = spec.flip_vertical,
            .rotation = spec.rotation,
            .source = "config",
            .extra_data = .empty,
            .uid = uid_tmp,
        }).dupe(gpa);
        errdefer freeWebcam(gpa, &cam);
        try cam.validate();
        const key = try gpa.dupe(u8, cam.uid);
        errdefer gpa.free(key);
        try self.order.ensureUnusedCapacity(gpa, 1);
        try self.cams.ensureUnusedCapacity(gpa, 1);
        self.dropByName(spec.name);
        // A database webcam whose random uid equals this uid5 is hidden too.
        if (self.findByUid(cam.uid)) |other| self.dropByName(other.name);
        self.cams.putAssumeCapacity(key, cam);
        self.order.insertAssumeCapacity(self.config_count, key);
        self.config_count += 1;
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

    /// A random UUID4 not already in use (Moonraker `_get_guaranteed_uuid`).
    fn newUid(self: *WebcamCtx, buf: *[36]u8) []const u8 {
        const io = self.io orelse self.clock_io;
        while (true) {
            var bytes: [16]u8 = undefined;
            io.random(&bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            const uid = formatUuid(&bytes, buf);
            if (!self.cams.contains(uid)) return uid;
        }
    }

    /// Return a JSON array of all webcam dicts (for notifications and list).
    pub fn listJson(self: *WebcamCtx, alloc: std.mem.Allocator) !std.json.Value {
        var arr: std.json.Array = .init(alloc);
        for (self.order.items) |uid| {
            const cam = self.cams.getPtr(uid) orelse continue;
            const v = try cam.asJson(alloc);
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
    return (Webcam{
        .name = strField(obj, "name", ""),
        .enabled = boolField(obj, "enabled", true),
        .icon = strField(obj, "icon", "mdiWebcam"),
        .aspect_ratio = strField(obj, "aspectRatio", "4:3"),
        .target_fps = intField(obj, "targetFps", 15),
        .target_fps_idle = intField(obj, "targetFpsIdle", 5),
        .location = strField(obj, "location", "printer"),
        .service = strField(obj, "service", "mjpegstreamer"),
        .stream_url = strField(obj, "urlStream", ""),
        .snapshot_url = strField(obj, "urlSnapshot", ""),
        .flip_horizontal = boolField(obj, "flipX", false),
        .flip_vertical = boolField(obj, "flipY", false),
        .rotation = intField(obj, "rotation", 0),
        .source = "database",
        .extra_data = if (obj.get("extra_data")) |v| if (v == .object) v.object else .empty else .empty,
        .uid = uid,
    }).dupe(alloc);
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
        .float => |f| jv.floatToInt(f) orelse default,
        else => default,
    };
}

/// Free all owned strings in a Webcam.
fn freeWebcam(alloc: std.mem.Allocator, cam: *Webcam) void {
    inline for (comptime std.meta.fieldNames(Webcam)) |field| {
        if (@TypeOf(@field(cam, field)) == []const u8) alloc.free(@field(cam, field));
    }
    jv.free(alloc, .{ .object = cam.extra_data });
}

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

/// `extra_data`: Moonraker `get("extra_data", {})`. Phobos stores an object,
/// so another type is rejected. Absent → empty.
fn getOptObj(params: std.json.Value, field: []const u8) error{InvalidParams}!std.json.ObjectMap {
    const v = (try webreq.optional(std.json.Value, params, field)) orelse return .empty;
    return if (v == .object) v.object else error.InvalidParams;
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
    // Moonraker get_str("name") when neither uid nor name was sent:
    // 400 "No data for argument: name". An unknown name stays 404.
    const cam = try lookupCamera(c, params) orelse return error.NotFound;
    const cam_json = try cam.asJson(alloc);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcam", cam_json);
    return .{ .object = result };
}

/// POST /server/webcams/item → {"webcam": {...}}
/// Creates or updates a webcam; emits notify_webcams_changed.
pub fn handleWebcamPost(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    // An unknown uid is a 404; an unknown name creates a webcam.
    const cam: *Webcam = if (lookupCamera(c, params) catch |err| switch (err) {
        error.MissingWebcamName => null,
        else => |e| return e,
    }) |existing| blk: {
        if (std.mem.eql(u8, existing.source, "config")) return error.Forbidden;
        var updated = try existing.dupe(c.gpa);
        errdefer freeWebcam(c.gpa, &updated);
        try updateCamFromParams(c, &updated, params);
        try updated.validate();
        freeWebcam(c.gpa, existing);
        existing.* = updated;
        break :blk existing;
    } else blk: {
        const name = try webreq.required([]const u8, params, "name");
        if (c.findByName(name) != null) return error.InvalidParams;
        var uid_buf: [36]u8 = undefined;
        var new_cam = try camFromWebRequest(c.gpa, params, c.newUid(&uid_buf));
        errdefer freeWebcam(c.gpa, &new_cam);
        try new_cam.validate();

        const uid_owned = try c.gpa.dupe(u8, new_cam.uid);
        errdefer c.gpa.free(uid_owned);
        try c.order.ensureUnusedCapacity(c.gpa, 1);
        try c.cams.put(c.gpa, uid_owned, new_cam);
        c.order.appendAssumeCapacity(uid_owned);
        break :blk c.cams.getPtr(uid_owned).?;
    };
    c.saveToStore(cam);

    const cam_json = try cam.asJson(alloc);
    c.emitWebcamsChanged(alloc);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "webcam", cam_json);
    return .{ .object = result };
}

/// DELETE /server/webcams/item → {"webcam": {...}}
/// Deletes a webcam (source must be "database"); emits notify_webcams_changed.
pub fn handleWebcamDelete(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    const cam = try lookupCamera(c, params) orelse return error.NotFound;

    if (std.mem.eql(u8, cam.source, "config")) {
        return error.Forbidden;
    }

    const cam_json = try cam.asJson(alloc);

    const uid_copy = try alloc.dupe(u8, cam.uid);
    defer alloc.free(uid_copy);

    c.untrack(uid_copy);
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

/// Moonraker probes snapshots with connect_timeout=1 s and request_timeout=1 s.
const SNAPSHOT_TIMEOUT: std.Io.Duration = .fromSeconds(2);
/// Linux exposes TCP listeners as text; read them through std.Io.
const network_file_limit = 256 * 1024;
const URL_RESOLVE_TIMEOUT: std.Io.Duration = .fromSeconds(2);
const UrlEnvironment = struct {
    public_ip: ?[]const u8 = null,
    network: std.json.Value = .null,
    tcp4: []const u8 = "",
    tcp6: []const u8 = "",
    io: ?std.Io = null,
};

fn readNetworkFile(aio: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
    const file = std.Io.Dir.cwd().openFile(aio, path, .{}) catch return "";
    defer file.close(aio);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(aio, &buffer);
    return reader.interface.allocRemaining(alloc, .limited(network_file_limit)) catch "";
}

/// UDP connect selects a source address without sending any packets.
fn publicAddress(aio: std.Io, candidates: []const std.Io.net.IpAddress) ?std.Io.net.IpAddress {
    for (candidates) |candidate| {
        const stream = candidate.connect(aio, .{ .mode = .dgram, .protocol = .udp }) catch continue;
        defer stream.close(aio);
        return stream.socket.address;
    }
    return null;
}

fn isLoopback(ip: std.Io.net.IpAddress) bool {
    return switch (ip) {
        .ip4 => |v| v.bytes[0] == 127,
        .ip6 => |v| std.mem.eql(u8, &v.bytes, &std.Io.net.Ip6Address.loopback(0).bytes) or
            if (std.Io.net.Ip4Address.fromIp6(v)) |v4| v4.bytes[0] == 127 else false,
    };
}

fn isLocalAddress(network: std.json.Value, ip: std.Io.net.IpAddress) bool {
    if (network != .object) return false;
    var it = network.object.iterator();
    while (it.next()) |iface| {
        if (iface.value_ptr.* != .object) continue;
        const addresses = iface.value_ptr.object.get("ip_addresses") orelse continue;
        if (addresses != .array) continue;
        for (addresses.array.items) |entry| {
            if (entry != .object) continue;
            const address = entry.object.get("address") orelse continue;
            if (address != .string) continue;
            const local = std.Io.net.IpAddress.parse(address.string, 0) catch continue;
            if (local.eql(&ip)) return true;
        }
    }
    return false;
}

fn hasWildcardListener(tcp: []const u8, port: u16, ipv6: bool) bool {
    var lines = std.mem.tokenizeScalar(u8, tcp, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = fields.next() orelse continue;
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        if (!std.mem.eql(u8, state, "0A")) continue;
        const colon = std.mem.indexOfScalar(u8, local, ':') orelse continue;
        if (colon != (if (ipv6) @as(usize, 32) else 8)) continue;
        if (!std.mem.allEqual(u8, local[0..colon], '0')) continue;
        const parsed = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        if (parsed == port) return true;
    }
    return false;
}

fn resolveHost(aio: std.Io, host: []const u8, port: u16) ?std.Io.net.IpAddress {
    const Task = struct {
        fn run(tio: std.Io, name: std.Io.net.HostName, target_port: u16, done: *std.Io.Event) ?std.Io.net.IpAddress {
            defer done.set(tio);
            var buffer: [16]std.Io.net.HostName.LookupResult = undefined;
            var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buffer);
            name.lookup(tio, &queue, .{ .port = target_port }) catch return null;
            while (queue.getOne(tio)) |result| switch (result) {
                .address => |address| return address,
                .canonical_name => {},
            } else |_| {}
            return null;
        }
    };
    const name = std.Io.net.HostName.init(host) catch return null;
    var done: std.Io.Event = .unset;
    var task = aio.concurrent(Task.run, .{ aio, name, port, &done }) catch return null;
    _ = sleep.untilStopped(aio, URL_RESOLVE_TIMEOUT, &done);
    var address = task.cancel(aio) orelse return null;
    address.setPort(0);
    return address;
}

/// Returned URL owns alloc storage, except for the empty string.
fn resolveUrl(alloc: std.mem.Allocator, url: []const u8, env: UrlEnvironment, convert_local: bool) ![]const u8 {
    if (url.len == 0) return "";
    const absolute = if (std.mem.indexOf(u8, url, "://")) |sep| sep > 0 and
        (for (url[0..sep]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') break false;
        } else true) and sep + 3 < url.len and url[sep + 3] != '/' else false;
    const resolved = if (absolute) try alloc.dupe(u8, url) else blk: {
        const ip = if (env.public_ip) |text| std.Io.net.IpAddress.parse(text, 0) catch null else null;
        const host = env.public_ip orelse "127.0.0.1";
        const brackets = ip != null and ip.? == .ip6;
        break :blk try std.fmt.allocPrint(alloc, "http://{s}{s}{s}/{s}", .{ if (brackets) "[" else "", host, if (brackets) "]" else "", std.mem.trimStart(u8, url, "/") });
    };
    errdefer alloc.free(resolved);
    if (!convert_local) return resolved;
    if (env.network != .object or env.network.object.count() == 0) return resolved;
    var uri = std.Uri.parse(resolved) catch return resolved;
    const port = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) @as(u16, 80) else if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) @as(u16, 443) else if (std.ascii.eqlIgnoreCase(uri.scheme, "rtsp")) @as(u16, 554) else return resolved;
    const host_component = uri.host orelse return resolved;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return resolved;
    const bare_host = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    const ip = std.Io.net.IpAddress.parse(bare_host, 0) catch if (env.io) |aio| resolveHost(aio, bare_host, port) orelse return resolved else return resolved;
    if (isLoopback(ip) or !isLocalAddress(env.network, ip)) return resolved;
    const loopback = if (hasWildcardListener(env.tcp4, port, false)) "127.0.0.1" else if (hasWildcardListener(env.tcp6, port, true)) "[::1]" else return resolved;
    uri.host = .{ .raw = loopback };
    uri.port = port;
    const result = try std.fmt.allocPrint(alloc, "{f}", .{uri});
    alloc.free(resolved);
    return result;
}

/// GET an `http(s)://` snapshot URL and report whether it responded with a
/// success status (Moonraker `_handle_webcam_test`: `snapshot_reachable = not
/// ret.has_error()`). The request is cancelled after `timeout`.
fn probeSnapshot(io: std.Io, gpa: std.mem.Allocator, url: []const u8, timeout: std.Io.Duration) bool {
    if (!std.mem.startsWith(u8, url, "http")) return false;
    const Task = struct {
        fn run(tio: std.Io, a: std.mem.Allocator, u: []const u8, done: *std.Io.Event) bool {
            defer done.set(tio);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var client: std.http.Client = .{ .allocator = arena.allocator(), .io = tio };
            defer client.deinit();
            var sink: [4096]u8 = undefined;
            var disc: std.Io.Writer.Discarding = .init(&sink);
            const status = http_get.requestToWriter(&client, .GET, u, null, &.{}, &disc.writer) catch return false;
            return status.class() == .success;
        }
    };
    var done: std.Io.Event = .unset;
    var task = io.concurrent(Task.run, .{ io, gpa, url, &done }) catch return false;
    _ = sleep.untilStopped(io, timeout, &done);
    return task.cancel(io);
}

/// POST /server/webcams/test → {"name", "snapshot_reachable", "snapshot_url", "stream_url"}.
/// Probes the snapshot URL when io is wired and the URL is http(s), with the
/// Core lock released for the request.
pub fn handleWebcamTest(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *WebcamCtx = @ptrCast(@alignCast(ctx));

    const cam = try lookupCamera(c, params) orelse return error.NotFound;
    // The camera may change while Core is released.
    const raw_snapshot = try alloc.dupe(u8, cam.snapshot_url);
    defer alloc.free(raw_snapshot);
    const raw_stream = try alloc.dupe(u8, cam.stream_url);
    defer alloc.free(raw_stream);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "name", .{ .string = try alloc.dupe(u8, cam.name) });
    var env: UrlEnvironment = .{};
    if (c.io) |aio| {
        c.bus.core.unlock(aio);
    }
    defer if (c.io) |aio| c.bus.core.lock(aio);
    if (c.io) |aio| {
        env.io = aio;
        if (c.machine_ctx) |mctx| env.network = machine.buildNetworkInfo(mctx, alloc).network;
        const candidates = [_]std.Io.net.IpAddress{
            .{ .ip4 = .{ .bytes = .{ 10, 255, 255, 255 }, .port = 1 } },
            .{ .ip6 = .{ .bytes = .{ 0x20, 1, 0xd, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 0x34 }, .port = 1, .interface = .none } },
        };
        if (publicAddress(aio, &candidates)) |ip| {
            var host_buf: [64]u8 = undefined;
            const address = try std.fmt.bufPrint(&host_buf, "{f}", .{ip});
            const host = address[0..std.mem.lastIndexOfScalar(u8, address, ':').?];
            env.public_ip = try alloc.dupe(u8, std.mem.trim(u8, host, "[]"));
        }
        env.tcp4 = readNetworkFile(aio, alloc, "/proc/net/tcp");
        env.tcp6 = readNetworkFile(aio, alloc, "/proc/net/tcp6");
    }
    const snapshot_url = try resolveUrl(alloc, raw_snapshot, env, true);
    try result.put(alloc, "snapshot_url", .{ .string = snapshot_url });
    try result.put(alloc, "stream_url", .{ .string = try resolveUrl(alloc, raw_stream, env, true) });
    const reachable = if (c.io) |aio| probeSnapshot(aio, c.gpa, snapshot_url, SNAPSHOT_TIMEOUT) else false;
    try result.put(alloc, "snapshot_reachable", .{ .bool = reachable });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Moonraker `_lookup_camera`: a `uid` param must name an existing webcam
/// (else 404); otherwise `name` selects one (null when absent from the table).
/// Neither param: `error.MissingWebcamName`.
fn lookupCamera(c: *WebcamCtx, params: std.json.Value) !?*Webcam {
    if (try webreq.optional([]const u8, params, "uid")) |uid| return c.findByUid(uid) orelse error.NotFound;
    const name = (try webreq.optional([]const u8, params, "name")) orelse return error.MissingWebcamName;
    return c.findByName(name);
}

/// Create a new Webcam from web request params (from_web_request equivalent).
fn camFromWebRequest(alloc: std.mem.Allocator, params: std.json.Value, uid: []const u8) !Webcam {
    return (Webcam{
        .name = try webreq.required([]const u8, params, "name"),
        .enabled = (try webreq.optional(bool, params, "enabled")) orelse true,
        .icon = try webreq.optional([]const u8, params, "icon") orelse "mdiWebcam",
        .aspect_ratio = try webreq.optional([]const u8, params, "aspect_ratio") orelse "4:3",
        .target_fps = (try webreq.optional(i64, params, "target_fps")) orelse 15,
        .target_fps_idle = (try webreq.optional(i64, params, "target_fps_idle")) orelse 5,
        .location = try webreq.optional([]const u8, params, "location") orelse "printer",
        .service = try webreq.optional([]const u8, params, "service") orelse "mjpegstreamer",
        .stream_url = try webreq.required([]const u8, params, "stream_url"),
        .snapshot_url = try webreq.optional([]const u8, params, "snapshot_url") orelse "",
        .flip_horizontal = (try webreq.optional(bool, params, "flip_horizontal")) orelse false,
        .flip_vertical = (try webreq.optional(bool, params, "flip_vertical")) orelse false,
        .rotation = (try webreq.optional(i64, params, "rotation")) orelse 0,
        .source = "database",
        .extra_data = try getOptObj(params, "extra_data"),
        .uid = uid,
    }).dupe(alloc);
}

/// Apply every non-protected field present in `params` (Moonraker
/// `WebCam.update`; `source` and `uid` are protected). `cam` is a private
/// copy; the caller frees it on error.
fn updateCamFromParams(c: *WebcamCtx, cam: *Webcam, params: std.json.Value) !void {
    inline for (.{ "name", "icon", "aspect_ratio", "location", "service", "stream_url", "snapshot_url" }) |field| {
        if (try webreq.optional([]const u8, params, field)) |value| {
            if (!std.mem.eql(u8, @field(cam, field), value)) {
                if (comptime std.mem.eql(u8, field, "name")) {
                    if (c.findByName(value) != null) return error.InvalidParams;
                }
                const owned = try c.gpa.dupe(u8, value);
                c.gpa.free(@field(cam, field));
                @field(cam, field) = owned;
            }
        }
    }
    inline for (.{ "enabled", "flip_horizontal", "flip_vertical" }) |field| {
        @field(cam, field) = (try webreq.optional(bool, params, field)) orelse @field(cam, field);
    }
    inline for (.{ "target_fps", "target_fps_idle", "rotation" }) |field| {
        @field(cam, field) = (try webreq.optional(i64, params, field)) orelse @field(cam, field);
    }
    if (params == .object and params.object.contains("extra_data")) {
        const extra = (try jv.deepCopy(c.gpa, .{ .object = try getOptObj(params, "extra_data") })).object;
        jv.free(c.gpa, .{ .object = cam.extra_data });
        cam.extra_data = extra;
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

// Minimal bus for tests that don't need notifications. Initialise in place:
// the bus points at the core and connection list beside it.
const NullBus = struct {
    core: @import("../server/core.zig").Core,
    conns_obj: @import("../server/connections.zig").Connections,
    bus: NotifyBus,

    fn init(nb: *NullBus, alloc: std.mem.Allocator) void {
        nb.core = .init();
        nb.conns_obj = .init(alloc, &nb.core);
        nb.bus = .init(&nb.core, &nb.conns_obj);
    }
};

// Minimal NullStore for tests
const NullDS = struct {
    fn vtGetItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: ds.Key) ds_mod.Error!?std.json.Value {
        return null;
    }
    fn vtInsert(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: ds.Key, _: std.json.Value) ds_mod.Error!void {}
    fn vtUpdate(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: ds.Key, _: std.json.Value) ds_mod.Error!void {}
    fn vtDelete(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: ds.Key) ds_mod.Error!std.json.Value {
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
    return WebcamCtx.init(alloc, std.testing.io, NullDS.dataStore(), &nb.bus);
}

test "webcam copies free partial fields and nested extra data" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"cam\",\"stream_url\":\"/stream\",\"extra_data\":{\"layout\":[\"wide\",2]}}", .{});
    defer parsed.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn copy(alloc: std.mem.Allocator, params: std.json.Value) !void {
            var cam = try camFromWebRequest(alloc, params, "uid");
            defer freeWebcam(alloc, &cam);
            try cam.validate();
        }
    }.copy, .{parsed.value});
}

test "webcam extra data survives its request and invalid updates preserve the record" {
    var nb: NullBus = undefined;
    nb.init(testing.allocator);
    var ctx = try makeCtx(testing.allocator, &nb);
    defer ctx.deinit();
    {
        var request = std.heap.ArenaAllocator.init(testing.allocator);
        defer request.deinit();
        const params = try mkParams(request.allocator(), "{\"name\":\"cam\",\"stream_url\":\"/stream\",\"extra_data\":{\"layout\":[\"wide\",2]}}");
        _ = try handleWebcamPost(@ptrCast(&ctx), params, request.allocator());
    }
    const cam = ctx.findByName("cam").?;
    try testing.expectEqualStrings("wide", cam.extra_data.get("layout").?.array.items[0].string);
    var response = std.heap.ArenaAllocator.init(testing.allocator);
    defer response.deinit();
    const serialized = try cam.asJson(response.allocator());
    const params = try mkParams(response.allocator(), "{\"name\":\"cam\",\"stream_url\":\"/changed\",\"rotation\":45}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, response.allocator()));
    try testing.expectEqualStrings("/stream", ctx.findByName("cam").?.stream_url);
    ctx.dropByName("cam");
    try testing.expectEqualStrings("wide", serialized.object.get("extra_data").?.object.get("layout").?.array.items[0].string);
}

test "configWebcamUid matches Moonraker uuid5 for the printer instance" {
    var buf: [36]u8 = undefined;
    const ns = "a48b28888e484d4fac9b7bc09e068dea";
    const cam = try configWebcamUid(ns, "cam", &buf);
    try testing.expectEqualStrings("1616e509-4515-53e4-8cd8-74875fb859c9", cam);
    const example = try configWebcamUid("a48b2888-8e48-4d4f-ac9b-7bc09e068dea", "Example", &buf);
    try testing.expectEqualStrings("e98363d4-af2e-5f41-8515-e84af7baf3c2", example);
    const name: [256]u8 = @splat('a');
    try testing.expectEqualStrings("30378439-b391-518d-9ef1-63eb2e1b3b9e", try configWebcamUid(ns, &name, &buf));
}

test "fuzz configWebcamUid hashes bounded names without intermediate storage" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var name: [1024]u8 = undefined;
            smith.bytesWithHash(&name, 0);
            const len = smith.valueRangeAtMostWithHash(u16, 0, name.len, 1);
            var first: [36]u8 = undefined;
            var second: [36]u8 = undefined;
            const namespace = "a48b28888e484d4fac9b7bc09e068dea";
            const uuid = try configWebcamUid(namespace, name[0..len], &first);
            try testing.expectEqualStrings(uuid, try configWebcamUid(namespace, name[0..len], &second));
            try testing.expectEqual(@as(u8, '5'), uuid[14]);
            try testing.expect(std.mem.findScalar(u8, "89ab", uuid[19]) != null);
        }
    }.run, .{});
}

test "addFromConfig: config webcam is listed and cannot be overwritten" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
    defer db.deinit();
    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try WebcamCtx.init(a, std.testing.io, db.dataStore(), &nb.bus);
    defer ctx.deinit();

    try ctx.addFromConfig(.{
        .name = "cam",
        .enabled = true,
        .service = "mjpegstreamer-adaptive",
        .stream_url = "/webcam/?action=stream",
        .snapshot_url = "/webcam/?action=snapshot",
    });
    try ctx.addFromConfig(.{
        .name = "cam",
        .enabled = false,
        .service = "other",
        .stream_url = "http://replaced",
    });

    const result = try handleWebcamList(@ptrCast(&ctx), .null, a);
    const webcams = result.object.get("webcams").?.array;
    try testing.expectEqual(@as(usize, 1), webcams.items.len);
    const cam = webcams.items[0].object;
    try testing.expectEqualStrings("cam", cam.get("name").?.string);
    try testing.expectEqualStrings("config", cam.get("source").?.string);
    try testing.expectEqualStrings("mjpegstreamer-adaptive", cam.get("service").?.string);
    try testing.expectEqualStrings("/webcam/?action=stream", cam.get("stream_url").?.string);
    try testing.expect(cam.get("enabled").?.bool);
    const stored = try ctx.store.getNamespace(a, "webcams");
    try testing.expectEqual(@as(usize, 0), stored.object.count());
}

test "handleWebcamList: empty store returns empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
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

    var nb: NullBus = undefined;
    nb.init(ctx_alloc);
    var ctx = try WebcamCtx.init(ctx_alloc, std.testing.io, NullDS.dataStore(), &nb.bus);
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

    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"nonexistent\"}");
    try testing.expectError(error.NotFound, handleWebcamGet(@ptrCast(&ctx), params, a));
    try testing.expectError(error.MissingWebcamName, handleWebcamGet(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.MissingWebcamName, handleWebcamGet(@ptrCast(&ctx), try mkParams(a, "{}"), a));
}

test "webcam: invalid rotation → InvalidParams on create" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"rotation\":45}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: invalid aspect_ratio → InvalidParams on create" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"name\":\"cam1\",\"stream_url\":\"http://x\",\"aspect_ratio\":\"bad\"}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: test endpoint returns snapshot_reachable=false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
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
    try testing.expect(!probeSnapshot(io, testing.allocator, "rtsp://example/stream", .fromMilliseconds(100)));
    try testing.expect(!probeSnapshot(io, testing.allocator, "ftp://host/x", .fromMilliseconds(100)));
    try testing.expect(!probeSnapshot(io, testing.allocator, "", .fromMilliseconds(100)));
    try testing.expect(!probeSnapshot(io, testing.allocator, "webcam/?action=snapshot", .fromMilliseconds(100)));
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
            try testing.expect(!probeSnapshot(io, testing.allocator, wrote, .fromMilliseconds(100)));
        }
    }.run, .{});
}

test "webcam: POST missing name → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(a, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"stream_url\":\"http://x\"}");
    try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), params, a));
}

test "webcam: POST missing stream_url → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nb: NullBus = undefined;
    nb.init(a);
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

    var nb: NullBus = undefined;
    nb.init(alloc);
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
            var nb: NullBus = undefined;
            nb.init(a);
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
            var nb: NullBus = undefined;
            nb.init(a);
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
            var nb: NullBus = undefined;
            nb.init(a);
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
            var nb: NullBus = undefined;
            nb.init(a);
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
            var nb: NullBus = undefined;
            nb.init(a);
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

test "webcam POST: an unknown uid is NotFound and creates nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(testing.allocator, &nb);
    defer ctx.deinit();

    const params = try mkParams(a, "{\"uid\":\"00000000-0000-4000-8000-000000000000\",\"name\":\"cam\",\"stream_url\":\"x\"}");
    try testing.expectError(error.NotFound, handleWebcamPost(@ptrCast(&ctx), params, a));
    try testing.expectError(error.NotFound, handleWebcamGet(@ptrCast(&ctx), params, a));
    try testing.expectEqual(@as(u32, 0), ctx.cams.count());
    try testing.expectEqual(@as(usize, 0), ctx.order.items.len);
}

test "webcam POST: new uids are UUID4 and updates apply every field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nb: NullBus = undefined;
    nb.init(a);
    var ctx = try makeCtx(testing.allocator, &nb);
    defer ctx.deinit();

    const created = try handleWebcamPost(@ptrCast(&ctx), try mkParams(a, "{\"name\":\"cam\",\"stream_url\":\"/s\",\"enabled\":\"false\",\"target_fps\":\"20\"}"), a);
    const uid = created.object.get("webcam").?.object.get("uid").?.string;
    var bytes: [16]u8 = undefined;
    try parseUuid(uid, &bytes);
    try testing.expectEqual(@as(usize, 36), uid.len);
    try testing.expectEqual(@as(u8, 0x40), bytes[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), bytes[8] & 0xc0);
    const cam = ctx.findByUid(uid).?;
    try testing.expect(!cam.enabled);
    try testing.expectEqual(@as(i64, 20), cam.target_fps);

    const update = try std.fmt.allocPrint(a, "{{\"uid\":\"{s}\",\"enabled\":\"TRUE\",\"rotation\":\"90\",\"extra_data\":{{\"k\":[1]}}}}", .{uid});
    _ = try handleWebcamPost(@ptrCast(&ctx), try mkParams(a, update), a);
    try testing.expect(cam.enabled);
    try testing.expectEqual(@as(i64, 90), cam.rotation);
    try testing.expectEqual(@as(i64, 1), cam.extra_data.get("k").?.array.items[0].integer);

    // Wrong types are a 400 and leave the record unchanged.
    for ([_][]const u8{ "\"enabled\":\"maybe\"", "\"target_fps\":\"fast\"", "\"extra_data\":5", "\"icon\":7" }) |field| {
        const body = try std.fmt.allocPrint(a, "{{\"uid\":\"{s}\",{s}}}", .{ uid, field });
        try testing.expectError(error.InvalidParams, handleWebcamPost(@ptrCast(&ctx), try mkParams(a, body), a));
    }
    try testing.expect(cam.enabled);
    try testing.expectEqualStrings("mdiWebcam", cam.icon);
    try testing.expectEqual(@as(i64, 1), cam.extra_data.get("k").?.array.items[0].integer);
}

test "addFromConfig: hides a same-name database webcam without deleting it and lists config first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
    defer db.deinit();
    var nb: NullBus = undefined;
    nb.init(a);
    {
        var ctx = try WebcamCtx.init(testing.allocator, std.testing.io, db.dataStore(), &nb.bus);
        defer ctx.deinit();
        _ = try handleWebcamPost(@ptrCast(&ctx), try mkParams(a, "{\"name\":\"db_cam\",\"stream_url\":\"/a\"}"), a);
        _ = try handleWebcamPost(@ptrCast(&ctx), try mkParams(a, "{\"name\":\"shared\",\"stream_url\":\"/b\"}"), a);
    }
    var ctx = try WebcamCtx.init(testing.allocator, std.testing.io, db.dataStore(), &nb.bus);
    defer ctx.deinit();
    try ctx.addFromConfig(.{ .name = "shared", .stream_url = "/config" });
    try ctx.addFromConfig(.{ .name = "second", .stream_url = "/config2" });

    const list = (try handleWebcamList(@ptrCast(&ctx), .null, a)).object.get("webcams").?.array.items;
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("shared", list[0].object.get("name").?.string);
    try testing.expectEqualStrings("config", list[0].object.get("source").?.string);
    try testing.expectEqualStrings("second", list[1].object.get("name").?.string);
    try testing.expectEqualStrings("db_cam", list[2].object.get("name").?.string);
    // The hidden row is still in the database.
    try testing.expectEqual(@as(usize, 2), (try db.dataStore().getNamespace(a, "webcams")).object.count());
    // Deleting a database webcam keeps the config webcams at the front.
    _ = try handleWebcamDelete(@ptrCast(&ctx), try mkParams(a, "{\"name\":\"db_cam\"}"), a);
    try testing.expectEqual(@as(usize, 2), ctx.config_count);
    try testing.expectEqual(@as(usize, 2), ctx.order.items.len);
}

test "resolveUrl: paths use the default host like Moonraker _get_url" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("http://127.0.0.1/webcam/?action=snapshot", try resolveUrl(a, "/webcam/?action=snapshot", .{}, true));
    try testing.expectEqualStrings("http://127.0.0.1/webcam", try resolveUrl(a, "webcam", .{}, true));
    try testing.expectEqualStrings("http://cam:8080/x", try resolveUrl(a, "http://cam:8080/x", .{}, true));
    try testing.expectEqualStrings("rtsp://cam/stream", try resolveUrl(a, "rtsp://cam/stream", .{}, true));
    try testing.expectEqualStrings("http://127.0.0.1/a://b", try resolveUrl(a, "/a://b", .{}, true));
    try testing.expectEqualStrings("", try resolveUrl(a, "", .{}, true));
}

test "fuzz resolveUrl: output is empty or carries a scheme and host" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const len = smith.valueRangeAtMostWithHash(u8, 0, buf.len, 1);
            const out = try resolveUrl(testing.allocator, buf[0..len], .{}, true);
            defer if (out.len > 0) testing.allocator.free(out);
            if (len == 0) return testing.expectEqual(@as(usize, 0), out.len);
            try testing.expect(std.mem.indexOf(u8, out, "://") != null);
        }
    }.run, .{});
}

test "probeSnapshot: a stalled server is cancelled after the timeout" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Listening but never accepting: connect succeeds, no response arrives.
    var ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try ip.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/snap", .{server.socket.address.getPort()});
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try testing.expect(!probeSnapshot(io, testing.allocator, url, .fromMilliseconds(200)));
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
}

test "probeSnapshot cancels a partial Content-Length body without panicking" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    const DeviceDouble = @import("power.zig").DeviceDouble;
    var device = try DeviceDouble.bind(aio, "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nx");
    defer device.server.deinit(aio);
    device.stall_after_reply = true;
    var serving = try aio.concurrent(DeviceDouble.serveOne, .{&device});
    defer serving.cancel(aio);
    var url: [96]u8 = undefined;
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    try testing.expect(!probeSnapshot(aio, std.heap.smp_allocator, try device.url(&url, "/"), .fromMilliseconds(20)));
    try testing.expect(start.untilNow(aio).raw.toMilliseconds() < 5000);
}

const test_tcp4 = "0: 00000000:0050 00000000:0000 0A\n1: 00000000:1F90 00000000:0000 0A\n";
const test_tcp6 = "0: 00000000000000000000000000000000:01BB 00000000000000000000000000000000:0000 0A\n";
const test_network = "{\"eth0\":{\"ip_addresses\":[{\"address\":\"192.168.5.10\",\"family\":\"ipv4\",\"is_link_local\":false},{\"address\":\"2001:db8::10\",\"family\":\"ipv6\",\"is_link_local\":false}]}}";

test "publicAddress uses the local socket address without sending a datagram" {
    const ip = publicAddress(testing.io, &.{.{ .ip4 = .loopback(1) }}).?;
    try testing.expect(isLoopback(ip));
    try testing.expect(ip.getPort() != 0);
    try testing.expect(publicAddress(testing.io, &.{}) == null);
}

test "resolveUrl uses the public IPv4 or IPv6 address and preserves URL components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const network = try mkParams(a, test_network);
    var env: UrlEnvironment = .{ .public_ip = "192.168.5.10", .network = network, .tcp4 = test_tcp4, .tcp6 = test_tcp6 };
    try testing.expectEqualStrings("http://192.168.5.10/cam?token=a%2Fb#image", try resolveUrl(a, "cam?token=a%2Fb#image", env, false));
    try testing.expectEqualStrings("http://127.0.0.1:80/cam?token=a%2Fb#image", try resolveUrl(a, "/cam?token=a%2Fb#image", env, true));
    try testing.expectEqualStrings("http://user:p%40ss%3Aword@127.0.0.1:8080/cam?q=a%26b#frame", try resolveUrl(a, "http://user:p%40ss%3Aword@192.168.5.10:8080/cam?q=a%26b#frame", env, true));
    env.public_ip = "2001:db8::10";
    try testing.expectEqualStrings("http://[2001:db8::10]/cam", try resolveUrl(a, "/cam", env, false));
    try testing.expectEqualStrings("https://[::1]:443/snap?x=1", try resolveUrl(a, "https://[2001:db8::10]/snap?x=1", env, true));
    try testing.expectEqualStrings("http://127.0.0.2:8080/x", try resolveUrl(a, "http://127.0.0.2:8080/x", env, true));
    try testing.expectEqualStrings("http://192.168.5.20:8080/x", try resolveUrl(a, "http://192.168.5.20:8080/x", env, true));
    try testing.expectEqualStrings("custom://192.168.5.10/x", try resolveUrl(a, "custom://192.168.5.10/x", env, true));
    env.tcp4 = "0: 0A05A8C0:1F90 00000000:0000 0A\n";
    try testing.expectEqualStrings("http://192.168.5.10:8080/x", try resolveUrl(a, "http://192.168.5.10:8080/x", env, true));
}

test "hasWildcardListener requires a wildcard address, matching port and LISTEN state" {
    try testing.expect(hasWildcardListener(test_tcp4, 80, false));
    try testing.expect(hasWildcardListener(test_tcp6, 443, true));
    try testing.expect(!hasWildcardListener(test_tcp4, 443, false));
    try testing.expect(!hasWildcardListener("0: 00000000:0050 00000000:0000 01\n", 80, false));
    try testing.expect(!hasWildcardListener("0: 0100007F:0050 00000000:0000 0A\n", 80, false));
    try testing.expect(!hasWildcardListener(test_tcp4, 80, true));
}

test "readNetworkFile reads bounded fixture files and tolerates missing snapshots" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "route", .data = test_tcp4 });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "route", a);
    defer a.free(path);
    const contents = readNetworkFile(testing.io, a, path);
    defer a.free(contents);
    try testing.expectEqualStrings(test_tcp4, contents);
    try tmp.dir.deleteFile(testing.io, "route");
    try testing.expectEqualStrings("", readNetworkFile(testing.io, a, path));
}

test "resolveHost resolves localhost with native DNS and rejects invalid names" {
    const ip = resolveHost(testing.io, "localhost", 80).?;
    try testing.expect(isLoopback(ip));
    try testing.expectEqual(@as(u16, 0), ip.getPort());
    try testing.expect(resolveHost(testing.io, "bad host", 80) == null);
    try testing.expect(isLoopback(try std.Io.net.IpAddress.parse("::ffff:127.0.0.1", 0)));
    try testing.expect(!isLoopback(try std.Io.net.IpAddress.parse("2001:db8::1", 0)));
}

test "fuzz webcam listener and local URL conversion parsers" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) anyerror!void {
            var bytes: [256]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const len = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 1);
            const text = bytes[0..len];
            _ = hasWildcardListener(text, 80, false);
            _ = hasWildcardListener(text, 443, true);
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "tcp", .data = text });
            const path = try tmp.dir.realPathFileAlloc(testing.io, "tcp", testing.allocator);
            defer testing.allocator.free(path);
            const contents = readNetworkFile(testing.io, testing.allocator, path);
            defer testing.allocator.free(contents);
            try testing.expectEqualStrings(text, contents);
            var invalid_name: [265]u8 = undefined;
            const name = try std.fmt.bufPrint(&invalid_name, "invalid {s}", .{text});
            try testing.expect(resolveHost(testing.io, name, 80) == null);
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const network = try mkParams(a, test_network);
            _ = publicAddress(testing.io, if (len % 2 == 0) &.{.{ .ip4 = .loopback(1) }} else &.{});
            const ip = std.Io.net.IpAddress.parse(text, 0) catch try std.Io.net.IpAddress.parse("192.168.5.10", 0);
            _ = isLocalAddress(network, ip);
            _ = isLoopback(ip);
            const resolved = try resolveUrl(testing.allocator, text, .{ .public_ip = "2001:db8::10", .network = network, .tcp4 = text, .tcp6 = text }, true);
            defer if (resolved.len > 0) testing.allocator.free(resolved);
            if (len > 0) try testing.expect(std.mem.indexOf(u8, resolved, "://") != null);
        }
    }.run, .{});
}

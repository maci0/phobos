//! server.spoolman.* API component — Moonraker-compatible spoolman integration.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/spoolman.py` (SpoolManager):
//!
//!   GET/POST /server/spoolman/spool_id → server.spoolman.get_spool_id
//!                                        server.spoolman.post_spool_id
//!   POST     /server/spoolman/proxy    → server.spoolman.proxy
//!   GET      /server/spoolman/status   → server.spoolman.status
//!
//! Active spool ID is persisted in the DataStore under
//! namespace "moonraker", key "spoolman.spool_id" (matches spoolman.py).
//!
//! notify_active_spool_set is emitted (via NotifyBus.emitLocked + io) whenever
//! the active spool changes, with payload [{"spool_id": <id|null>}]. Emission
//! requires a live io; call setIo() after the App event loop starts. emitLocked
//! is used because the POST handler runs under the held Core lock.
//!
//! `[spoolman] server` is normalized like `_get_spoolman_urls`: an optional
//! http(s) scheme (default http), trailing slashes dropped, `/api` appended.
//! A WebSocket supervisor (ws_client.zig) keeps ws(s)://<host>/api/v1/spool
//! open; `spoolman_connected` is that socket's state, and spool-deletion pushes
//! clear the active spool (handleSpoolDeletedLocked). The proxy forwards to
//! <api url><path> off the Core lock and, while the socket is down, returns
//! the v2 "not available" shape (use_v2_response=true) or a 503, as Moonraker
//! does.
//!
//! Toolhead E positions accumulate pending filament use, excluding retractions
//! already recovered by the previous high-water mark. At most 128 spool IDs
//! retain accounting; a full queue rejects a new selection before mutation.
//! An owned worker validates the active spool on each WebSocket connection and
//! reports pending use at `sync_rate` (default five seconds). Failed reports
//! retain their usage for the next cycle; no network operation holds Core.

const std = @import("std");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const sleep = @import("../util/sleep.zig");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const ws_client_mod = @import("ws_client.zig");
const http_get = @import("http_get.zig");
const jsonrpc = @import("../jsonrpc.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const NotifyBus = notify.NotifyBus;

// ---------------------------------------------------------------------------
// Persistence constants (matches spoolman.py)
// ---------------------------------------------------------------------------

const db_namespace: [:0]const u8 = "moonraker";
const active_spool_key = "spoolman.spool_id";

/// Largest proxied Spoolman response body; larger replies are 503.
const max_proxy_response_len = 4 * 1024 * 1024;
/// Moonraker's HTTP client request deadline, including connection and body.
const proxy_timeout: std.Io.Duration = .fromSeconds(10);
/// Moonraker's WebSocket keepalive interval; allow one interval for a pong.
const ws_ping_interval: std.Io.Duration = .fromSeconds(20);
/// Bounds retained accounting while Spoolman is unavailable.
pub const max_pending_spools = 128;
const max_extruder_name_len = 128;
pub const default_sync_rate_seconds: u32 = 5;

const PendingReport = struct {
    used: f64 = 0,
    in_flight: ?ReportClaim = null,
};

const ReportClaim = struct { id: i64, used: f64, token: u64 };
const ReportResult = enum { sent, retry, missing };

/// Methods the proxy forwards (spoolman.py `_proxy_spoolman_request`).
const proxy_methods = std.StaticStringMap(std.http.Method).initComptime(.{
    .{ "GET", .GET },
    .{ "POST", .POST },
    .{ "PUT", .PUT },
    .{ "PATCH", .PATCH },
    .{ "DELETE", .DELETE },
});

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const SpoolmanCtx = struct {
    store: DataStore,
    bus: *NotifyBus,
    /// io is set after the event loop starts (via setIo). Notifications are
    /// only emitted when io is non-null. This avoids requiring a live event
    /// loop during App.init / dump-api / unit tests.
    io: ?std.Io,
    /// Allocator for arena-scoped notification payloads.
    gpa: std.mem.Allocator,
    /// Spoolman API base, "<scheme>://<host>/api" (gpa-owned; null until
    /// `setServerUrl`). The proxy appends the request path.
    api_url: ?[]const u8 = null,
    /// Live WebSocket connection state (Moonraker's spoolman_connected),
    /// maintained by the WS supervisor thread.
    ws_connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ws_thread: ?std.Io.Future(void) = null,
    report_thread: ?std.Io.Future(void) = null,
    report_wake: std.Io.Event = .unset,
    check_spool_pending: std.atomic.Value(bool) = .init(false),
    /// Used only by the reporting worker, reset after successful delivery.
    report_error_logged: bool = false,
    ws_stop: std.Io.Event = .unset,
    ws_mutex: std.Io.Mutex = std.Io.Mutex.init,
    ws: ?*ws_client_mod.WsClient = null,
    /// WebSocket target derived from `api_url` (gpa-owned host and path).
    ws_host: ?[]const u8 = null,
    ws_port: u16 = 0,
    ws_path: ?[]const u8 = null,
    ws_tls: bool = false,
    /// Callback invoked off the Core lock on a spool-deletion push; App wires it
    /// to clear the active spool under the Core lock.
    on_spool_deleted: ?*const fn (ctx: *anyopaque, spool_id: i64) void = null,
    on_spool_deleted_ctx: ?*anyopaque = null,
    /// Accounting and active selection are guarded by Core.
    pending_reports: std.AutoArrayHashMapUnmanaged(i64, PendingReport) = .empty,
    active_spool: ?i64 = null,
    klippy_ready: bool = false,
    extrusion_initialized: bool = false,
    highest_epos: f64 = 0,
    last_epos: f64 = 0,
    extruder_name: [max_extruder_name_len]u8 = undefined,
    extruder_name_len: usize = 0,
    sync_rate_seconds: u32 = default_sync_rate_seconds,
    next_report_token: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, store: DataStore, bus: *NotifyBus) !SpoolmanCtx {
        var self: SpoolmanCtx = .{ .store = store, .bus = bus, .io = null, .gpa = alloc };
        self.active_spool = try self.loadSpoolId();
        return self;
    }

    /// Stop both workers and free the server target and pending accounting.
    pub fn deinit(self: *SpoolmanCtx) void {
        self.stopWs();
        self.pending_reports.deinit(self.gpa);
        if (self.api_url) |u| self.gpa.free(u);
        if (self.ws_host) |h| self.gpa.free(h);
        if (self.ws_path) |p| self.gpa.free(p);
        self.api_url = null;
        self.ws_host = null;
        self.ws_path = null;
    }

    /// Supply a live io so notifications can be emitted. Called after the
    /// App's event loop is running (e.g. from httpServer setup).
    pub fn setIo(self: *SpoolmanCtx, io: std.Io) void {
        self.io = io;
        // Emit current connection state now that the event loop is live.
        self.emitStatus(false);
    }

    /// Apply `[spoolman] server` like spoolman.py `_get_spoolman_urls`: an
    /// optional case-insensitive http:// or https:// prefix (default http),
    /// trailing slashes removed, `/api` appended. Keeps the previous target on
    /// failure. Call before `startWs`.
    pub fn setServerUrl(self: *SpoolmanCtx, url: []const u8) !void {
        const https = std.ascii.startsWithIgnoreCase(url, "https://");
        const rest = if (https)
            url["https://".len..]
        else if (std.ascii.startsWithIgnoreCase(url, "http://"))
            url["http://".len..]
        else
            url;
        const host = std.mem.trimEnd(u8, rest, "/");
        if (host.len == 0) return error.InvalidUrl;
        const api_url = try std.fmt.allocPrint(self.gpa, "{s}://{s}/api", .{ if (https) "https" else "http", host });
        errdefer self.gpa.free(api_url);
        try self.parseWsTarget(api_url);
        if (self.api_url) |old| self.gpa.free(old);
        self.api_url = api_url;
    }

    /// Moonraker `connected()`: the WebSocket state.
    pub fn connected(self: *const SpoolmanCtx) bool {
        return self.ws_connected.load(.acquire);
    }

    /// Apply the positive `[spoolman] sync_rate` before starting workers.
    pub fn setSyncRate(self: *SpoolmanCtx, seconds: i64) !void {
        if (seconds < 1 or seconds > std.math.maxInt(u32)) return error.InvalidSyncRate;
        self.sync_rate_seconds = @intCast(seconds);
    }

    /// Emit notify_spoolman_status_changed. `locked` selects emitLocked (caller
    /// holds the Core lock) vs emit (lock-taking, for the WS supervisor thread).
    fn emitStatus(self: *SpoolmanCtx, locked: bool) void {
        const io = self.io orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var payload: std.json.ObjectMap = .empty;
        payload.put(a, "spoolman_connected", .{ .bool = self.connected() }) catch return;
        // Moonraker send_event("spoolman:spoolman_status_changed", {...}) → params
        // is the single-element data tuple [{...}]; emit requires a JSON array.
        var arr: std.json.Array = .init(a);
        arr.append(.{ .object = payload }) catch return;
        if (locked)
            self.bus.emitLocked(io, notify.names.spoolman_status_changed, .{ .array = arr }) catch {}
        else
            self.bus.emit(io, notify.names.spoolman_status_changed, .{ .array = arr }) catch {};
    }

    fn wsLock(self: *SpoolmanCtx) void {
        if (self.io) |io| self.ws_mutex.lockUncancelable(io);
    }
    fn wsUnlock(self: *SpoolmanCtx) void {
        if (self.io) |io| self.ws_mutex.unlock(io);
    }

    /// Derive and own the WebSocket target of `api_url` ("http(s)://host/api"):
    /// the same host, the URL's port or the scheme default, TLS for https, and
    /// path <api path>/v1/spool. Keeps a valid target on failure.
    fn parseWsTarget(self: *SpoolmanCtx, api_url: []const u8) !void {
        const uri = try std.Uri.parse(api_url);
        const secure = std.mem.eql(u8, uri.scheme, "https");
        if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidUrl;
        var buf: [512]u8 = undefined;
        var host = try (uri.host orelse return error.InvalidUrl).toRaw(&buf);
        if (std.mem.startsWith(u8, host, "[") and std.mem.endsWith(u8, host, "]")) host = host[1 .. host.len - 1];
        const port = uri.port orelse if (secure) @as(u16, 443) else @as(u16, 80);
        if (std.Io.net.IpAddress.parse(host, port)) |_| {} else |_| {
            _ = try std.Io.net.HostName.init(host);
        }
        const owned_host = try self.gpa.dupe(u8, host);
        errdefer self.gpa.free(owned_host);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/v1/spool", .{uri.path.percent_encoded});
        if (self.ws_host) |old| self.gpa.free(old);
        if (self.ws_path) |old| self.gpa.free(old);
        self.ws_host = owned_host;
        self.ws_path = path;
        self.ws_port = port;
        self.ws_tls = secure;
    }

    /// Start the WebSocket and reporting workers (no-op without a server, io, or
    /// if already running).
    pub fn startWs(self: *SpoolmanCtx) void {
        if (self.ws_thread != null or self.ws_host == null) return;
        const io = self.io orelse return;
        self.ws_stop.reset();
        self.ws_thread = io.concurrent(wsSupervisor, .{self}) catch |err| {
            std.debug.print("phobos: warning: Spoolman worker not started: {}\n", .{err});
            return;
        };
        self.report_thread = io.concurrent(reportSupervisor, .{self}) catch |err| {
            self.stopWs();
            std.debug.print("phobos: warning: Spoolman reporting worker not started: {}\n", .{err});
            return;
        };
    }

    pub fn stopWs(self: *SpoolmanCtx) void {
        if (self.io) |stop_io| self.ws_stop.set(stop_io) else self.ws_stop = .is_set;
        self.wsLock();
        if (self.ws) |w| w.shutdownRecv();
        self.wsUnlock();
        if (self.io) |stop_io| self.report_wake.set(stop_io);
        if (self.report_thread) |*t| {
            t.cancel(self.io.?);
            self.report_thread = null;
        }
        if (self.ws_thread) |*t| {
            t.cancel(self.io.?);
            self.ws_thread = null;
        }
    }

    fn freeWsLocked(self: *SpoolmanCtx) void {
        self.wsLock();
        const w = self.ws;
        self.ws = null;
        self.wsUnlock();
        if (w) |c| c.deinit();
    }

    /// Reconnect supervisor: connect to ws://host/api/v1/spool, mark connected,
    /// read push frames (spool deletions), reconnect with backoff on drop.
    fn wsSupervisor(self: *SpoolmanCtx) void {
        var backoff_ms: u64 = 500;
        const max_backoff: u64 = 30_000;
        const host = self.ws_host orelse return;
        const io = self.io orelse return;
        while (!self.ws_stop.isSet()) {
            const w = ws_client_mod.WsClient.connect(self.gpa, io, host, self.ws_port, self.ws_path.?, if (self.ws_tls) .{ .host = host } else null) catch {
                if (self.ws_stop.isSet()) break;
                if (sleep.untilStopped(io, .fromMilliseconds(@intCast(backoff_ms)), &self.ws_stop)) break;
                backoff_ms = @min(backoff_ms * 2, max_backoff);
                continue;
            };
            self.wsLock();
            self.ws = w;
            self.wsUnlock();
            w.enableHeartbeat(ws_ping_interval, ws_ping_interval);
            if (self.ws_stop.isSet()) w.shutdownRecv();
            self.ws_connected.store(true, .release);
            self.check_spool_pending.store(true, .release);
            self.report_wake.set(io);
            self.emitStatus(false);
            backoff_ms = 500;

            while (!self.ws_stop.isSet()) {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                const msg = w.readMessage(arena.allocator()) catch break;
                if (msg.opcode == .text) self.handleWsMessage(msg.data);
            }

            self.ws_connected.store(false, .release);
            self.emitStatus(false);
            self.freeWsLocked();
            if (self.ws_stop.isSet()) break;
            if (sleep.untilStopped(io, .fromMilliseconds(@intCast(backoff_ms)), &self.ws_stop)) break;
            backoff_ms = @min(backoff_ms * 2, max_backoff);
        }
    }

    fn reportSupervisor(self: *SpoolmanCtx) void {
        const io = self.io orelse return;
        while (!self.ws_stop.isSet()) {
            self.report_wake.reset();
            if (self.connected()) {
                if (self.check_spool_pending.swap(false, .acq_rel)) {
                    self.report_error_logged = false;
                    self.checkActiveSpool();
                }
                self.reportExtrusion();
            }
            if (self.ws_stop.isSet()) break;
            _ = sleep.untilStopped(io, .fromSeconds(self.sync_rate_seconds), &self.report_wake);
        }
    }

    /// Network work runs on the reporting worker; only state transitions enter Core.
    fn checkActiveSpool(self: *SpoolmanCtx) void {
        const io = self.io orelse return;
        const id = self.bus.core.run(io, getSpoolId, .{self}) orelse return;
        const base = self.api_url orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const url = std.fmt.allocPrint(alloc, "{s}/v1/spool/{d}", .{ base, id }) catch return;
        const response = proxyRequest(self.gpa, io, .GET, url, null, alloc, .fromSeconds(2)) catch |err| {
            self.logReportError(err);
            return;
        };
        if (response.status == 404) {
            self.bus.core.run(io, forgetMissingSpoolLocked, .{ self, id }) catch |err| self.logReportError(err);
        } else if (response.status < 200 or response.status >= 300) self.logReportError(error.UpstreamRequestFailed);
    }

    fn logReportError(self: *SpoolmanCtx, err: anyerror) void {
        if (!self.report_error_logged and !self.ws_stop.isSet()) {
            std.debug.print("phobos: Spoolman filament report failed: {}\n", .{err});
            self.report_error_logged = true;
        }
    }

    /// Claim a bounded batch so new extrusion can accumulate during HTTP requests.
    fn claimReportsLocked(self: *SpoolmanCtx, batch: *[max_pending_spools]ReportClaim) usize {
        var count: usize = 0;
        var entries = self.pending_reports.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.used <= 0 or entry.value_ptr.in_flight != null) continue;
            self.next_report_token +%= 1;
            if (self.next_report_token == 0) self.next_report_token = 1;
            const claim: ReportClaim = .{ .id = entry.key_ptr.*, .used = entry.value_ptr.used, .token = self.next_report_token };
            entry.value_ptr.used = 0;
            entry.value_ptr.in_flight = claim;
            batch[count] = claim;
            count += 1;
        }
        return count;
    }

    fn forgetMissingSpoolLocked(self: *SpoolmanCtx, id: i64) !void {
        if (self.active_spool == id) try self.setSpoolId(null);
        _ = self.pending_reports.orderedRemove(id);
    }

    fn finishReportLocked(self: *SpoolmanCtx, claim: ReportClaim, result: ReportResult) !void {
        const report = self.pending_reports.getPtr(claim.id) orelse return;
        const pending = report.in_flight orelse return;
        if (pending.token != claim.token) return;
        switch (result) {
            .missing => return self.forgetMissingSpoolLocked(claim.id),
            .retry => report.used += claim.used,
            .sent => {},
        }
        report.in_flight = null;
        self.removeEmptyReport(claim.id);
    }

    fn restoreReportsLocked(self: *SpoolmanCtx, claims: []const ReportClaim) void {
        for (claims) |claim| self.finishReportLocked(claim, .retry) catch unreachable;
    }

    /// Called only by the owned reporting worker, or synchronously by fixtures.
    /// A deferred restore also preserves unprocessed usage when canceled mid-request.
    pub fn reportExtrusion(self: *SpoolmanCtx) void {
        const io = self.io orelse return;
        const base = self.api_url orelse return;
        if (!self.connected()) return;
        var batch: [max_pending_spools]ReportClaim = undefined;
        const count = self.bus.core.run(io, claimReportsLocked, .{ self, &batch });
        defer self.bus.core.run(io, restoreReportsLocked, .{ self, batch[0..count] });
        for (batch[0..count]) |claim| {
            if (!self.connected() or self.ws_stop.isSet()) break;
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const alloc = scratch.allocator();
            const url = std.fmt.allocPrint(alloc, "{s}/v1/spool/{d}/use", .{ base, claim.id }) catch |err| {
                self.logReportError(err);
                continue;
            };
            var payload_buf: [512]u8 = undefined;
            var payload: std.Io.Writer = .fixed(&payload_buf);
            std.json.Stringify.value(.{ .use_length = claim.used }, .{}, &payload) catch |err| {
                self.logReportError(err);
                continue;
            };
            const response = proxyRequest(self.gpa, io, .PUT, url, payload.buffered(), alloc, proxy_timeout) catch |err| {
                self.logReportError(err);
                continue;
            };
            const result: ReportResult = if (response.status == 404) .missing else if (response.status < 200 or response.status >= 300) .retry else .sent;
            self.bus.core.run(io, finishReportLocked, .{ self, claim, result }) catch |err| {
                self.logReportError(err);
                continue;
            };
            if (result == .retry) self.logReportError(error.UpstreamRequestFailed) else self.report_error_logged = false;
        }
    }

    /// Parse a Spoolman push frame; on a spool deletion, invoke on_spool_deleted.
    /// {"resource":"spool","type":"deleted","payload":{"id":N}}.
    fn handleWsMessage(self: *SpoolmanCtx, data: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), data, .{}) catch return;
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        const res = o.get("resource") orelse return;
        const typ = o.get("type") orelse return;
        if (res != .string or typ != .string) return;
        if (!std.mem.eql(u8, res.string, "spool") or !std.mem.eql(u8, typ.string, "deleted")) return;
        const pl = o.get("payload") orelse return;
        if (pl != .object) return;
        const idv = pl.object.get("id") orelse return;
        const id: i64 = switch (idv) {
            .integer => |i| i,
            .float => |f| if (f == @trunc(f)) jv.floatToInt(f) orelse return else return,
            else => return,
        };
        if (self.on_spool_deleted) |cb| {
            if (self.on_spool_deleted_ctx) |c| cb(c, id);
        }
    }

    /// Clear the active spool if it matches `deleted_id` (Moonraker behaviour).
    /// Runs under the Core lock (App wires this via core.run).
    pub fn handleSpoolDeletedLocked(self: *SpoolmanCtx, deleted_id: i64) !void {
        const active = self.getSpoolId() orelse return;
        if (active == deleted_id) {
            try self.setSpoolId(null);
            _ = self.pending_reports.orderedRemove(deleted_id);
        }
    }

    fn loadSpoolId(self: *SpoolmanCtx) !?i64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = self.store.getItem(a, db_namespace, active_spool_key) catch |err| switch (err) {
            error.NamespaceNotFound, error.KeyNotFound => return null,
            else => return err,
        };
        return switch (v orelse return null) {
            .integer => |i| i,
            .null => null,
            else => error.InvalidSpoolId,
        };
    }

    /// Return the cached active spool ID (null if none).
    pub fn getSpoolId(self: *SpoolmanCtx) ?i64 {
        return self.active_spool;
    }

    /// Set the active spool ID. Persists to DataStore and, if io is set,
    /// emits notify_active_spool_set with payload [{"spool_id": <id|null>}].
    pub fn setSpoolId(self: *SpoolmanCtx, spool_id: ?i64) !void {
        if (self.getSpoolId() == spool_id) return;
        const previous = self.active_spool;
        const added = if (spool_id) |id| try self.reserveReport(id) else false;
        errdefer if (added) {
            _ = self.pending_reports.orderedRemove(spool_id.?);
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const val: std.json.Value = if (spool_id) |id| .{ .integer = id } else .null;
        try self.store.insertItem(a, db_namespace, active_spool_key, val);
        self.active_spool = spool_id;
        self.highest_epos = self.last_epos;
        if (previous) |id| self.removeEmptyReport(id);

        // Emit notification only when a live event loop is available.
        const io = self.io orelse return;
        var obj: std.json.ObjectMap = .empty;
        obj.put(a, "spool_id", val) catch return;
        var arr: std.json.Array = .init(a);
        arr.append(.{ .object = obj }) catch return;
        // setSpoolId is reached from the POST /server/spoolman/spool_id handler,
        // which runs under the held Core lock (Core.run). Re-acquiring via emit
        // would deadlock the non-reentrant mutex; use emitLocked.
        self.bus.emitLocked(io, notify.names.active_spool_set, .{ .array = arr }) catch {};
    }

    fn reserveReport(self: *SpoolmanCtx, id: i64) !bool {
        if (self.pending_reports.contains(id)) return false;
        if (self.pending_reports.count() == max_pending_spools) return error.ServiceUnavailable;
        try self.pending_reports.put(self.gpa, id, .{});
        return true;
    }

    fn removeEmptyReport(self: *SpoolmanCtx, id: i64) void {
        const report = self.pending_reports.get(id) orelse return;
        if (report.used == 0 and report.in_flight == null and self.active_spool != id)
            _ = self.pending_reports.orderedRemove(id);
    }

    /// Klippy lifecycle hook. Call under Core before its initial status snapshot.
    pub fn onKlippyStateLocked(self: *SpoolmanCtx, ready: bool) void {
        self.klippy_ready = ready;
        if (!ready) self.extrusion_initialized = false;
    }

    /// Track toolhead E coordinates, which already include the extrusion factor.
    /// Call under Core; this performs no network requests.
    pub fn onKlippyStatusLocked(self: *SpoolmanCtx, status: std.json.Value, _: std.json.Value) !void {
        if (!self.klippy_ready or status != .object) return;
        const toolhead = status.object.get("toolhead") orelse return;
        if (toolhead != .object) return error.InvalidParams;
        const name = switch (toolhead.object.get("extruder") orelse .null) {
            .string => |name| name,
            .null => if (self.extruder_name_len == 0) "extruder" else self.extruder_name[0..self.extruder_name_len],
            else => return error.InvalidParams,
        };
        if (name.len == 0 or name.len > self.extruder_name.len or !std.unicode.utf8ValidateSlice(name)) return error.InvalidParams;
        const epos: f64 = if (toolhead.object.get("position")) |position| blk: {
            if (position != .array or position.array.items.len != 4) return error.InvalidParams;
            break :blk switch (position.array.items[3]) {
                .integer => |value| @floatFromInt(value),
                .float => |value| value,
                else => return error.InvalidParams,
            };
        } else if (self.extrusion_initialized) self.highest_epos else return;
        if (!std.math.isFinite(epos)) return error.InvalidParams;
        const changed = !std.mem.eql(u8, name, self.extruder_name[0..self.extruder_name_len]);
        if (self.extrusion_initialized and !changed and epos > self.highest_epos) {
            if (self.getSpoolId()) |id| {
                const delta = epos - self.highest_epos;
                if (!std.math.isFinite(delta)) return error.InvalidParams;
                _ = try self.reserveReport(id);
                const report = self.pending_reports.getPtr(id).?;
                const updated = report.used + delta;
                if (!std.math.isFinite(updated) or !std.math.isFinite(updated + if (report.in_flight) |claim| claim.used else @as(f64, 0))) return error.InvalidParams;
                report.used = updated;
            }
        }
        self.last_epos = epos;
        if (!self.extrusion_initialized or changed or epos > self.highest_epos) self.highest_epos = epos;
        if (changed) std.mem.copyForwards(u8, self.extruder_name[0..name.len], name);
        self.extruder_name_len = name.len;
        self.extrusion_initialized = true;
    }
};

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/spoolman/status → spoolman connection status
/// Shape: spoolman_connected, pending_reports ({spool_id, filament_used}), spool_id.
pub fn handleStatus(ctx: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "spoolman_connected", .{ .bool = c.connected() });
    var pending: std.json.Array = .init(alloc);
    var reports = c.pending_reports.iterator();
    while (reports.next()) |entry| {
        if (entry.value_ptr.used <= 0) continue;
        var report: std.json.ObjectMap = .empty;
        try report.put(alloc, "spool_id", .{ .integer = entry.key_ptr.* });
        try report.put(alloc, "filament_used", .{ .float = entry.value_ptr.used });
        try pending.append(.{ .object = report });
    }
    try obj.put(alloc, "pending_reports", .{ .array = pending });
    const spool_id = c.getSpoolId();
    if (spool_id) |id| {
        try obj.put(alloc, "spool_id", .{ .integer = id });
    } else {
        try obj.put(alloc, "spool_id", .null);
    }
    return .{ .object = obj };
}

/// GET /server/spoolman/spool_id → {"spool_id": <id|null>}
/// POST /server/spoolman/spool_id (spool_id param) → set active spool
pub fn handleSpoolId(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));
    // GET returns the active spool; POST sets it. Dispatch on the transport's
    // injected `_method`, NOT on whether `spool_id` is present — otherwise a GET
    // with `?spool_id=5` would mutate state (unsafe method).
    const is_post = switch (params) {
        .object => |obj| if (obj.get("_method")) |m| (m == .string and std.mem.eql(u8, m.string, "POST")) else false,
        else => false,
    };

    if (is_post) {
        const new_id = (try webreq.optional(i64, params, "spool_id"));
        try c.setSpoolId(new_id);
    }

    var obj: std.json.ObjectMap = .empty;
    const spool_id = c.getSpoolId();
    if (spool_id) |id| {
        try obj.put(alloc, "spool_id", .{ .integer = id });
    } else {
        try obj.put(alloc, "spool_id", .null);
    }
    return .{ .object = obj };
}

fn errNotAvailable(alloc: std.mem.Allocator, use_v2: bool) anyerror!std.json.Value {
    if (use_v2) {
        var err_obj: std.json.ObjectMap = .empty;
        try err_obj.put(alloc, "status_code", .{ .integer = 503 });
        try err_obj.put(alloc, "message", .{ .string = "Spoolman server not available" });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "response", .null);
        try obj.put(alloc, "error", .{ .object = err_obj });
        return .{ .object = obj };
    }
    return error.ServiceUnavailable;
}

/// POST /server/spoolman/proxy → proxy a request to Spoolman (spoolman.py
/// `_proxy_spoolman_request`). Runs off the Core lock.
///
/// Params: request_method (GET/POST/PUT/PATCH/DELETE), path ("/v1/..."),
/// query (appended as ?query), body (JSON request body; not with GET),
/// use_v2_response. While the WebSocket is down the reply is the 503 shape.
/// v1 returns the decoded Spoolman response; v2 wraps it as {"response",
/// "response_headers", "error"} and reports Spoolman HTTP errors in "error".
pub fn handleProxy(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx));
    const method = proxy_methods.get(try webreq.required([]const u8, params, "request_method")) orelse return error.InvalidParams;
    const path = try webreq.required([]const u8, params, "path");
    const query = (try webreq.optional([]const u8, params, "query"));
    const body: ?std.json.Value = if (params == .object) switch (params.object.get("body") orelse .null) {
        .null => null,
        else => |b| b,
    } else null;
    const use_v2 = ((try webreq.optional(bool, params, "use_v2_response")) orelse false);
    if (body != null and method == .GET) return error.InvalidParams;
    if (!std.mem.startsWith(u8, path, "/v1/")) return error.InvalidParams;
    if (body) |b| if (jv.exceedsDepth(b, jv.max_value_depth)) return error.InvalidParams;

    if (!c.connected()) return errNotAvailable(alloc, use_v2);
    const api_url = c.api_url orelse return errNotAvailable(alloc, use_v2);
    const io = c.io orelse return errNotAvailable(alloc, use_v2);
    const url = try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}", .{ api_url, path, if (query != null) "?" else "", query orelse "" });
    const payload: ?[]const u8 = if (body) |b| try std.json.Stringify.valueAlloc(alloc, b, .{}) else null;
    const response = proxyRequest(c.gpa, io, method, url, payload, alloc, proxy_timeout) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errNotAvailable(alloc, use_v2),
    };

    if (response.status >= 400) {
        if (!use_v2) {
            try jsonrpc.setErrorReply(alloc, params, @fromBackingInt(@intCast(response.status)), response.reason);
            return error.UpstreamRequestFailed;
        }
        // Surface Spoolman's own {"message": ...} from the error body when present.
        const msg = extractSpoolmanMessage(alloc, response.body) orelse "Spoolman request failed";
        var err_obj: std.json.ObjectMap = .empty;
        try err_obj.put(alloc, "status_code", .{ .integer = response.status });
        try err_obj.put(alloc, "message", .{ .string = msg });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "response", .null);
        try obj.put(alloc, "error", .{ .object = err_obj });
        return .{ .object = obj };
    }

    const response_val = parseProxyBody(alloc, response.body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return errNotAvailable(alloc, use_v2),
    };
    if (!use_v2) return response_val;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "response", response_val);
    try obj.put(alloc, "response_headers", .{ .object = response.headers });
    try obj.put(alloc, "error", .null);
    return .{ .object = obj };
}

const ProxyResponse = struct {
    status: u16,
    reason: []const u8,
    headers: std.json.ObjectMap,
    body: []const u8,
};

/// Decode external JSON without passing excessive nesting to the serializer.
/// Strings and parsed storage borrow the request arena and response body.
fn parseProxyBody(alloc: std.mem.Allocator, body: []const u8) error{ OutOfMemory, InvalidUtf8 }!std.json.Value {
    if (body.len == 0) return .null;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .string = body },
    };
    return if (jv.exceedsDepth(parsed, jv.max_value_depth)) .{ .string = body } else parsed;
}

/// One HTTP round trip to Spoolman. The client lives in a gpa arena freed on
/// return; status, headers and body are copied into `out`. The body must be
/// uncompressed and at most `max_proxy_response_len` bytes.
fn proxyRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    out: std.mem.Allocator,
    timeout: std.Io.Duration,
) !ProxyResponse {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Outcome = union(enum) {
        response: anyerror!ProxyResponse,
        expired: std.Io.Cancelable!void,
    };
    var outcomes: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &outcomes);
    defer select.cancelDiscard();
    try select.concurrent(.response, proxyRoundTrip, .{ arena.allocator(), io, method, url, payload });
    try select.concurrent(.expired, std.Io.sleep, .{ io, timeout, .awake });
    const response = switch (try select.await()) {
        .expired => |result| {
            try result;
            return error.Timeout;
        },
        .response => |result| try result,
    };
    var headers: std.json.ObjectMap = .empty;
    var it = response.headers.iterator();
    while (it.next()) |h| try headers.put(out, try out.dupe(u8, h.key_ptr.*), .{ .string = try out.dupe(u8, h.value_ptr.string) });
    return .{
        .status = response.status,
        .reason = try out.dupe(u8, response.reason),
        .headers = headers,
        .body = try out.dupe(u8, response.body),
    };
}

fn proxyRoundTrip(
    out: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
) !ProxyResponse {
    var client: std.http.Client = .{ .allocator = out, .io = io };
    defer client.deinit();

    var headers = http_get.identity_headers;
    if (payload != null) headers.content_type = .{ .override = "application/json" };
    var req = try client.request(method, try std.Uri.parse(url), .{
        .headers = headers,
        .keep_alive = false,
        .redirect_behavior = if (payload == null) @fromBackingInt(@intCast(3)) else .unhandled,
    });
    defer req.deinit();
    req.accept_encoding = http_get.identity_only;
    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(p);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(if (payload == null) &redirect_buf else &.{});
    if (!std.unicode.utf8ValidateSlice(response.head.reason)) return error.InvalidUtf8;
    const reason = try out.dupe(u8, response.head.reason);
    var headers_out: std.json.ObjectMap = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (!std.unicode.utf8ValidateSlice(h.name) or !std.unicode.utf8ValidateSlice(h.value)) return error.InvalidUtf8;
        try headers_out.put(out, try out.dupe(u8, h.name), .{ .string = try out.dupe(u8, h.value) });
    }
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(out, .limited(max_proxy_response_len)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => |e| return e,
    };
    return .{ .status = @backingInt(response.head.status), .reason = reason, .headers = headers_out, .body = body };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// spoolman.py registers spool_id with RequestType.GET | RequestType.POST
// which in the baseline scanner produces multi_verb names:
//   server.spoolman.get_spool_id, server.spoolman.post_spool_id
//
// Strategy: register GET+POST together (multi=true) for spool_id,
// single-verb for proxy and status.

/// Extract Spoolman's error `message` from a JSON error body (Moonraker reads
/// `{"message": ...}`). Returns null when the body isn't JSON or has no string
/// message. The result is duped into `alloc`.
fn extractSpoolmanMessage(alloc: std.mem.Allocator, body: []const u8) ?[]const u8 {
    if (body.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    if (parsed.value != .object) return null;
    const m = parsed.value.object.get("message") orelse return null;
    if (m != .string) return null;
    return alloc.dupe(u8, m.string) catch null;
}

pub fn registerSpoolman(reg: *Registry, ctx: *SpoolmanCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // /server/spoolman/spool_id — GET+POST → multi-verb names
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/spool_id", .methods = &.{ .GET, .POST } },
        c,
        handleSpoolId,
    );

    // /server/spoolman/proxy — POST only → "server.spoolman.proxy". Off Core:
    // the HTTP round trip blocks, and the handler reads only config set before
    // serving plus the atomic WebSocket state.
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/proxy", .methods = &.{.POST}, .off_core = true },
        c,
        handleProxy,
    );

    // /server/spoolman/status — GET only → "server.spoolman.status"
    try reg.registerEndpoint(
        .{ .path = "/server/spoolman/status", .methods = &.{.GET} },
        c,
        handleStatus,
    );

    // Klipper remote method: gcode macros can set the active spool
    // (Moonraker register_remote_method("spoolman_set_active_spool", ...)).
    try reg.dispatcher.register("spoolman_set_active_spool", c, handleSetActiveSpool);
}

/// Klipper remote method `spoolman_set_active_spool` → setSpoolId. Params carry
/// `spool_id` (int or null). Returns null (remote methods produce no response).
pub fn handleSetActiveSpool(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    _ = alloc;
    const c: *SpoolmanCtx = @ptrCast(@alignCast(ctx_ptr));
    const value = if (params == .object) (try webreq.optional(std.json.Value, params, "spool_id")) orelse .null else params;
    const sid: ?i64 = switch (value) {
        .integer => |i| i,
        .null => null,
        else => return error.InvalidParams,
    };
    try c.setSpoolId(sid);
    return .null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ds_mod = @import("../store/datastore.zig");
const Core = @import("../server/core.zig").Core;
const connections_mod = @import("../server/connections.zig");

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// Minimal null bus for tests.
const NullBus = struct {
    core: Core,
    conns_obj: connections_mod.Connections,
    bus: NotifyBus,

    fn init(alloc: std.mem.Allocator) NullBus {
        var nb: NullBus = undefined;
        nb.core = Core.init();
        nb.conns_obj = connections_mod.Connections.init(alloc, &nb.core);
        nb.bus = NotifyBus.init(&nb.core, &nb.conns_obj);
        return nb;
    }
};

// Minimal memory-backed DataStore for unit tests.
const MemStore = struct {
    alloc: std.mem.Allocator,
    data: std.StringHashMap(std.json.Value),
    writes: usize = 0,
    fail_writes: bool = false,
    fail_reads: bool = false,

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc, .data = std.StringHashMap(std.json.Value).init(alloc) };
    }

    fn deinit(self: *MemStore) void {
        self.data.deinit();
    }

    fn vtGetItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8) ds_mod.Error!?std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        if (self.fail_reads) return error.BackendError;
        return self.data.get(key);
    }

    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: std.json.Value) ds_mod.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        if (self.fail_writes) return error.BackendError;
        self.data.put(key, value) catch return ds_mod.Error.OutOfMemory;
        self.writes += 1;
    }

    fn vtUpdateItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: std.json.Value) ds_mod.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        self.data.put(key, value) catch return ds_mod.Error.OutOfMemory;
    }

    fn vtDeleteItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds_mod.Error!std.json.Value {
        return ds_mod.Error.KeyNotFound;
    }

    fn vtListNamespaces(_: *anyopaque, arena: std.mem.Allocator) ds_mod.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }

    fn vtGetNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds_mod.Error!std.json.Value {
        return .{ .object = .empty };
    }

    const vtable: ds_mod.VTable = .{
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

fn makeCtx(alloc: std.mem.Allocator, mem: *MemStore, nb: *NullBus) !SpoolmanCtx {
    return SpoolmanCtx.init(alloc, mem.dataStore(), &nb.bus);
}

var ws_captured_id: i64 = -1;
fn wsCaptureDeleted(_: *anyopaque, id: i64) void {
    ws_captured_id = id;
}

test "spoolman WS: deletion frame invokes on_spool_deleted with the spool id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);
    var dummy: u8 = 0;
    ctx.on_spool_deleted = wsCaptureDeleted;
    ctx.on_spool_deleted_ctx = &dummy;

    ws_captured_id = -1;
    ctx.handleWsMessage("{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":42}}");
    try testing.expectEqual(@as(i64, 42), ws_captured_id);

    ws_captured_id = -1;
    ctx.handleWsMessage("{\"resource\":\"spool\",\"type\":\"updated\",\"payload\":{\"id\":7}}");
    ctx.handleWsMessage("{\"resource\":\"filament\",\"type\":\"deleted\",\"payload\":{\"id\":7}}");
    ctx.handleWsMessage("{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":42.5}}");
    ctx.handleWsMessage("{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":1e500}}");
    ctx.handleWsMessage("not json");
    try testing.expectEqual(@as(i64, -1), ws_captured_id);
    ctx.handleWsMessage("{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":42.0}}");
    try testing.expectEqual(@as(i64, 42), ws_captured_id);
}

test "fuzz Spoolman deletion pushes preserve integer equality" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var mem = MemStore.init(testing.allocator);
            defer mem.deinit();
            var nb = NullBus.init(testing.allocator);
            var ctx = try makeCtx(testing.allocator, &mem, &nb);
            defer ctx.deinit();
            var dummy: u8 = 0;
            ctx.on_spool_deleted = wsCaptureDeleted;
            ctx.on_spool_deleted_ctx = &dummy;
            const id = smith.valueRangeAtMostWithHash(u8, 0, 127, 0);
            const fractional = smith.valueWithHash(bool, 1);
            var frame: [128]u8 = undefined;
            ws_captured_id = -1;
            ctx.handleWsMessage(try std.fmt.bufPrint(&frame, "{{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{{\"id\":{d}.{s}}}}}", .{ id, if (fractional) "5" else "0" }));
            try testing.expectEqual(if (fractional) @as(i64, -1) else @as(i64, id), ws_captured_id);
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 2);
            ctx.handleWsMessage(&bytes);
        }
    }.run, .{});
}

test "spoolman WS: deletion clears the active spool only when it matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    _ = try handleSpoolId(@ptrCast(&ctx), try mkParams(a, "{\"spool_id\": 5, \"_method\": \"POST\"}"), a);
    try ctx.handleSpoolDeletedLocked(99);
    try testing.expectEqual(@as(i64, 5), ctx.getSpoolId().?);
    try ctx.handleSpoolDeletedLocked(5);
    try testing.expect(ctx.getSpoolId() == null);
}

test "setServerUrl normalizes like _get_spoolman_urls and stays disconnected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var mem = MemStore.init(arena.allocator());
    defer mem.deinit();
    var nb = NullBus.init(arena.allocator());
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    // Scheme-less values default to http; the HTTP and WS ports agree.
    try ctx.setServerUrl("192.168.1.9:7913");
    try testing.expectEqualStrings("http://192.168.1.9:7913/api", ctx.api_url.?);
    try testing.expectEqualStrings("192.168.1.9", ctx.ws_host.?);
    try testing.expectEqual(@as(u16, 7913), ctx.ws_port);
    try testing.expectEqualStrings("/api/v1/spool", ctx.ws_path.?);
    try ctx.setServerUrl("HTTP://localhost/");
    try testing.expectEqualStrings("http://localhost/api", ctx.api_url.?);
    try testing.expectEqual(@as(u16, 80), ctx.ws_port);
    try testing.expect(!ctx.ws_tls);
    try testing.expectError(error.InvalidUrl, ctx.setServerUrl("http://"));
    try testing.expectEqualStrings("http://localhost/api", ctx.api_url.?);
    // Configuration alone is not a connection (Moonraker reports ws_connected).
    var status_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer status_arena.deinit();
    const status = try handleStatus(@ptrCast(&ctx), .null, status_arena.allocator());
    try testing.expectEqual(false, status.object.get("spoolman_connected").?.bool);
}

var ws_sup_deleted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
fn wsSupFlag(_: *anyopaque, _: i64) void {
    ws_sup_deleted.store(true, .release);
}

fn spoolmanTestWsServer(server: *std.Io.net.Server, io: std.Io, payload: []const u8) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [2048]u8 = undefined;
    var wbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);
    var http = std.http.Server.init(&r.interface, &w.interface);
    var request = http.receiveHead() catch return;
    const key = switch (request.upgradeRequested()) {
        .websocket => |key| key orelse return,
        else => return,
    };
    var ws = request.respondWebSocket(.{ .key = key }) catch return;
    ws.writeMessage(payload, .text) catch return;
    while (true) _ = r.interface.takeByte() catch break;
}

test "spoolman WS supervisor: connects, receives a deletion push, shuts down cleanly" {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ip = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try ip.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var sf = io.async(spoolmanTestWsServer, .{ &server, io, @as([]const u8, "{\"resource\":\"spool\",\"type\":\"deleted\",\"payload\":{\"id\":5}}") });

    defer sf.cancel(io);
    var mem = MemStore.init(alloc);
    defer mem.deinit();
    // Stable inline bus (NullBus.init returns by value with self-pointers that
    // would dangle once emit() is actually exercised with a live io).
    var core = Core.init();
    var conns = connections_mod.Connections.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try SpoolmanCtx.init(alloc, mem.dataStore(), &bus);
    defer ctx.deinit();
    var url_buf: [64]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{port}));
    ctx.io = io;
    var dummy: u8 = 0;
    ctx.on_spool_deleted = wsSupFlag;
    ctx.on_spool_deleted_ctx = &dummy;
    ws_sup_deleted.store(false, .release);

    ctx.startWs();
    var tries: usize = 0;
    while (!(ctx.connected() and ws_sup_deleted.load(.acquire)) and tries < 400) : (tries += 1) {
        io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(ctx.connected());
    try testing.expect(ws_sup_deleted.load(.acquire));

    ctx.stopWs();
    sf.await(io);
    try testing.expect(!ctx.connected());
    try testing.expect(ctx.ws_thread == null);
}

test "handleStatus: returns correct shape with no active spool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const result = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(false, result.object.get("spoolman_connected").?.bool);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
    try testing.expectEqual(@as(usize, 0), result.object.get("pending_reports").?.array.items.len);
}

test "handleSpoolId GET: returns null when no spool set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const result = try handleSpoolId(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
}

test "handleSpoolId POST: sets active spool and persists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    // POST with spool_id = 42
    const params = try mkParams(a, "{\"spool_id\": 42, \"_method\": \"POST\"}");
    const result = try handleSpoolId(@ptrCast(&ctx), params, a);
    try testing.expectEqual(@as(i64, 42), result.object.get("spool_id").?.integer);

    // Verify persistence via GET (no spool_id in params)
    const get_result = try handleSpoolId(@ptrCast(&ctx), .null, a);
    try testing.expectEqual(@as(i64, 42), get_result.object.get("spool_id").?.integer);
}

test "extractSpoolmanMessage: pulls message from JSON error body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Spool not found", extractSpoolmanMessage(a, "{\"message\":\"Spool not found\"}").?);
    try testing.expect(extractSpoolmanMessage(a, "") == null);
    try testing.expect(extractSpoolmanMessage(a, "not json") == null);
    try testing.expect(extractSpoolmanMessage(a, "{\"other\":1}") == null);
    try testing.expect(extractSpoolmanMessage(a, "{\"message\":123}") == null);
}

test "fuzz extractSpoolmanMessage: arbitrary body never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var buf: [48]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = extractSpoolmanMessage(arena.allocator(), &buf);
        }
    }.run, .{});
}

test "handleSetActiveSpool: remote method sets/clears the active spool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    // Set via the remote method.
    _ = try handleSetActiveSpool(@ptrCast(&ctx), try mkParams(a, "{\"spool_id\": 7}"), a);
    try testing.expectEqual(@as(i64, 7), (try handleSpoolId(@ptrCast(&ctx), .null, a)).object.get("spool_id").?.integer);

    for ([_][]const u8{ "{\"spool_id\":\"bad\"}", "{\"spool_id\":true}", "{\"spool_id\":1.5}", "{\"spool_id\":{}}" }) |json| {
        try testing.expectError(error.InvalidParams, handleSetActiveSpool(@ptrCast(&ctx), try mkParams(a, json), a));
        try testing.expectEqual(@as(?i64, 7), ctx.getSpoolId());
    }

    // Clear via the remote method (spool_id null).
    _ = try handleSetActiveSpool(@ptrCast(&ctx), try mkParams(a, "{\"spool_id\": null, \"_method\": \"POST\"}"), a);
    try testing.expectEqual(std.json.Value.null, (try handleSpoolId(@ptrCast(&ctx), .null, a)).object.get("spool_id").?);
}

test "fuzz handleSetActiveSpool: arbitrary params never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = try makeCtx(a, &mem, &nb);
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const p = std.json.parseFromSlice(std.json.Value, a, &buf, .{}) catch return;
            _ = handleSetActiveSpool(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "handleSpoolId POST: invalid values preserve spool, absent field clears" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    // Set first
    const set_params = try mkParams(a, "{\"spool_id\": 5, \"_method\": \"POST\"}");
    _ = try handleSpoolId(@ptrCast(&ctx), set_params, a);

    for ([_][]const u8{ "null", "\"bad\"", "{}" }) |value| {
        const json = try std.fmt.allocPrint(a, "{{\"spool_id\":{s},\"_method\":\"POST\"}}", .{value});
        try testing.expectError(error.InvalidParams, handleSpoolId(@ptrCast(&ctx), try mkParams(a, json), a));
        try testing.expectEqual(@as(?i64, 5), ctx.getSpoolId());
    }
    // WebRequest.get_int defaults only when the key is absent.
    const clear_params = try mkParams(a, "{\"_method\": \"POST\"}");
    const result = try handleSpoolId(@ptrCast(&ctx), clear_params, a);
    try testing.expectEqual(.null, result.object.get("spool_id").?);
}

test "handleProxy: missing request_method → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), .null, a));
}

test "handleProxy: invalid path → InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/bad\"}");
    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: not connected → ServiceUnavailable (non-v2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\"}");
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: not connected → v2 error shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"use_v2_response\": true}");
    const result = try handleProxy(@ptrCast(&ctx), params, a);
    try testing.expectEqual(.null, result.object.get("response").?);
    const err = result.object.get("error").?.object;
    try testing.expectEqual(@as(i64, 503), err.get("status_code").?.integer);
}

test "spoolman active-spool persistence round-trip: set then reload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    // Set spool ID
    try ctx.setSpoolId(77);

    // Create a new context from the same datastore (simulates restart)
    var ctx2 = try SpoolmanCtx.init(a, mem.dataStore(), &nb.bus);
    try testing.expectEqual(@as(?i64, 77), ctx2.getSpoolId());
}

test "Spoolman accounts toolhead extrusion across retractions, flow and restarts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try ctx.setSpoolId(7);
    ctx.onKlippyStateLocked(true);
    const updates = [_][]const u8{
        "{\"toolhead\":{\"position\":[0,0,0,100],\"extruder\":\"extruder\"}}",
        "{\"toolhead\":{\"position\":[0,0,0,105]}}",
        "{\"toolhead\":{\"position\":[0,0,0,103]}}",
        "{\"toolhead\":{\"position\":[0,0,0,105]}}",
        "{\"toolhead\":{\"position\":[0,0,0,107]}}",
        "{\"toolhead\":{\"position\":[0,0,0,108]},\"gcode_move\":{\"extrude_factor\":0.5}}",
        "{\"toolhead\":{\"position\":[0,0,0,1000],\"extruder\":\"extruder1\"}}",
        "{\"toolhead\":{\"position\":[0,0,0,1002]}}",
    };
    for (updates) |update| try ctx.onKlippyStatusLocked(try mkParams(a, update), .null);
    try ctx.setSpoolId(8);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,1004]}}"), .null);
    ctx.onKlippyStateLocked(false);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,50]}}"), .null);
    ctx.onKlippyStateLocked(true);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,3]}}"), .null);
    const status = try handleStatus(&ctx, .null, a);
    const pending = status.object.get("pending_reports").?.array.items;
    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqual(@as(i64, 7), pending[0].object.get("spool_id").?.integer);
    try testing.expectEqual(@as(f64, 10), pending[0].object.get("filament_used").?.float);
    try testing.expectEqual(@as(i64, 8), pending[1].object.get("spool_id").?.integer);
    try testing.expectEqual(@as(f64, 5), pending[1].object.get("filament_used").?.float);
    try testing.expectEqualStrings("extruder1", ctx.extruder_name[0..ctx.extruder_name_len]);
    try testing.expectError(error.InvalidParams, ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[1]}}"), .null));
    _ = try jv.successResponse(a, .{ .integer = 1 }, status);
}

test "Spoolman refuses a selection before overflowing pending accounting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    ctx.onKlippyStateLocked(true);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
    for (1..max_pending_spools + 1) |index| {
        try ctx.setSpoolId(@intCast(index));
        var bytes: [80]u8 = undefined;
        const update = try std.fmt.bufPrint(&bytes, "{{\"toolhead\":{{\"position\":[0,0,0,{d}]}}}}", .{index});
        try ctx.onKlippyStatusLocked(try mkParams(a, update), .null);
    }
    try testing.expectError(error.ServiceUnavailable, ctx.setSpoolId(max_pending_spools + 1));
    try testing.expectEqual(@as(?i64, max_pending_spools), ctx.getSpoolId());
    const status = try handleStatus(&ctx, .null, a);
    try testing.expectEqual(max_pending_spools, status.object.get("pending_reports").?.array.items.len);
    try ctx.handleSpoolDeletedLocked(max_pending_spools);
    try ctx.setSpoolId(max_pending_spools + 1);
    try testing.expectEqual(@as(?i64, max_pending_spools + 1), ctx.getSpoolId());
}

test "Spoolman selection and accounting survive persistence and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try ctx.setSpoolId(1);
    ctx.onKlippyStateLocked(true);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
    try ctx.onKlippyStatusLocked(try mkParams(a, "{\"toolhead\":{\"position\":[0,0,0,5]}}"), .null);
    mem.fail_writes = true;
    try testing.expectError(error.BackendError, ctx.setSpoolId(2));
    try testing.expectError(error.BackendError, ctx.handleSpoolDeletedLocked(1));
    try testing.expectEqual(@as(?i64, 1), ctx.getSpoolId());
    try testing.expect(ctx.pending_reports.get(2) == null);
    try testing.expectEqual(@as(f64, 5), ctx.pending_reports.get(1).?.used);
    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var req_arena = std.heap.ArenaAllocator.init(gpa);
            defer req_arena.deinit();
            const alloc = req_arena.allocator();
            var store = MemStore.init(gpa);
            defer store.deinit();
            var bus = NullBus.init(gpa);
            var context = try makeCtx(gpa, &store, &bus);
            defer context.deinit();
            try context.setSpoolId(1);
            context.onKlippyStateLocked(true);
            try context.onKlippyStatusLocked(try mkParams(alloc, "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
            try context.onKlippyStatusLocked(try mkParams(alloc, "{\"toolhead\":{\"position\":[0,0,0,3]}}"), .null);
            const response = try handleStatus(&context, .null, alloc);
            const wire = try jv.successResponse(alloc, .{ .integer = 1 }, response);
            _ = try std.json.parseFromSliceLeaky(std.json.Value, alloc, wire, .{});
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Allocation.run, .{});
}

test "Spoolman initialization rejects unreadable or corrupt persisted selection" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var nb = NullBus.init(testing.allocator);
    mem.fail_reads = true;
    try testing.expectError(error.BackendError, makeCtx(testing.allocator, &mem, &nb));
    mem.fail_reads = false;
    try mem.data.put(active_spool_key, .{ .string = "bad" });
    try testing.expectError(error.InvalidSpoolId, makeCtx(testing.allocator, &mem, &nb));
    try mem.data.put(active_spool_key, .{ .integer = 17 });
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try testing.expectEqual(@as(?i64, 17), ctx.getSpoolId());
}

test "fuzz Spoolman persisted selection accepts only integer or null" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var bytes: [32]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const value: std.json.Value = switch (bytes[0] % 5) {
                0 => .null,
                1 => .{ .integer = bytes[1] },
                2 => .{ .string = &bytes },
                3 => .{ .bool = true },
                else => .{ .float = 1.0 },
            };
            try mem.data.put(active_spool_key, value);
            if (value == .integer or value == .null) {
                var ctx = try makeCtx(a, &mem, &nb);
                defer ctx.deinit();
                try testing.expectEqual(if (value == .integer) @as(?i64, value.integer) else null, ctx.getSpoolId());
            } else try testing.expectError(error.InvalidSpoolId, makeCtx(a, &mem, &nb));
        }
    }.run, .{});
}

test "fuzz Spoolman extrusion updates keep bounded finite reports" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = try makeCtx(testing.allocator, &mem, &nb);
            defer ctx.deinit();
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            ctx.onKlippyStateLocked(true);
            for (bytes, 0..) |byte, index| {
                if (byte % 13 == 0) ctx.onKlippyStateLocked(false);
                if (byte % 7 == 0) ctx.onKlippyStateLocked(true);
                try ctx.setSpoolId(if (byte % 3 == 0) null else byte % 5);
                var buffer: [128]u8 = undefined;
                const update = try std.fmt.bufPrint(&buffer, "{{\"toolhead\":{{\"position\":[0,0,0,{d}],\"extruder\":\"extruder{d}\"}}}}", .{ @as(i32, byte) - @as(i32, @intCast(index)), byte % 2 });
                try ctx.onKlippyStatusLocked(try mkParams(a, update), .null);
                try testing.expect(ctx.pending_reports.count() <= max_pending_spools);
                for (ctx.pending_reports.values()) |report| try testing.expect(std.math.isFinite(report.used) and report.used >= 0);
            }
            const response = try handleStatus(&ctx, .null, a);
            const wire = try jv.successResponse(a, .{ .integer = 1 }, response);
            _ = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
        }
    }.run, .{});
}

test "Spoolman startup notifications hold Core and unchanged spools do not notify" {
    const io = testing.io;
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var core = Core.init();
    var conns = connections_mod.Connections.init(testing.allocator, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try SpoolmanCtx.init(testing.allocator, mem.dataStore(), &bus);
    defer ctx.deinit();
    const Capture = struct {
        core: *Core,
        io: std.Io,
        status: usize = 0,
        active: usize = 0,
        unlocked: bool = false,

        fn write(ptr: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.core.mutex.tryLock()) {
                self.core.unlock(self.io);
                self.unlocked = true;
            }
            if (std.mem.indexOf(u8, bytes, notify.names.spoolman_status_changed) != null) self.status += 1;
            if (std.mem.indexOf(u8, bytes, notify.names.active_spool_set) != null) self.active += 1;
        }
    };
    var capture: Capture = .{ .core = &core, .io = io };
    const conn = try conns.add(io, false);
    conns.attachWriter(io, conn, &capture, Capture.write);
    ctx.setIo(io);
    for ([_]?i64{ 7, 7, null, null }) |id| try core.run(io, SpoolmanCtx.setSpoolId, .{ &ctx, id });
    try testing.expectEqual(@as(usize, 1), capture.status);
    try testing.expectEqual(@as(usize, 2), capture.active);
    try testing.expectEqual(@as(usize, 2), mem.writes);
    try testing.expect(!capture.unlocked);
}

test "fuzz Spoolman spool selection only persists changes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var mem = MemStore.init(arena.allocator());
            defer mem.deinit();
            var nb = NullBus.init(arena.allocator());
            var ctx = try makeCtx(arena.allocator(), &mem, &nb);
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var previous: ?i64 = null;
            var expected: usize = 0;
            for (buf) |byte| {
                const id: ?i64 = if (byte % 3 == 0) null else byte % 4;
                if (id != previous) expected += 1;
                try ctx.setSpoolId(id);
                try testing.expectEqual(expected, mem.writes);
                try testing.expectEqual(id, ctx.getSpoolId());
                previous = id;
            }
        }
    }.run, .{});
}

test "registerSpoolman: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var nb = NullBus.init(alloc);
    var ctx = try SpoolmanCtx.init(alloc, mem.dataStore(), &nb.bus);

    try registerSpoolman(&reg, &ctx);

    // HTTP routes
    try testing.expect(reg.lookup(.GET, "/server/spoolman/spool_id") != null);
    try testing.expect(reg.lookup(.POST, "/server/spoolman/spool_id") != null);
    try testing.expect(reg.lookup(.POST, "/server/spoolman/proxy").?.off_core);
    try testing.expect(reg.lookup(.GET, "/server/spoolman/status") != null);

    // JSON-RPC methods
    try testing.expect(d.methods.get("server.spoolman.get_spool_id") != null);
    try testing.expect(d.methods.get("server.spoolman.post_spool_id") != null);
    try testing.expect(d.methods.get("server.spoolman.proxy") != null);
    try testing.expect(d.methods.get("server.spoolman.status") != null);
    try testing.expect(d.methods.get("spoolman_set_active_spool") != null);
}

// --- Fuzz tests ---

test "handleProxy: query parameter is accepted (not-connected path)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"query\": \"key=value\"}");
    // Not connected → ServiceUnavailable, but the query param is valid.
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy: GET with body returns InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    // Parameter checks run before the connection check, as in spoolman.py.
    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"body\": {\"key\": 1}}");
    try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), params, a));
    // Only GET/POST/PUT/PATCH/DELETE are forwarded.
    for ([_][]const u8{ "HEAD", "OPTIONS", "TRACE", "CONNECT", "get" }) |verb| {
        var buf: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"request_method\": \"{s}\", \"path\": \"/v1/spool\"}}", .{verb});
        try testing.expectError(error.InvalidParams, handleProxy(@ptrCast(&ctx), try mkParams(a, json), a));
    }
}

test "handleProxy: v2 error shape includes response and error keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"use_v2_response\": true}");
    const result = try handleProxy(@ptrCast(&ctx), params, a);
    // v2 error shape: {"response": null, "error": {"status_code": 503, ...}}
    try testing.expect(result.object.get("response") != null);
    try testing.expectEqual(.null, result.object.get("response").?);
    try testing.expect(result.object.get("error") != null);
    try testing.expect(result.object.get("error").? == .object);
}

test "handleProxy: query with special characters is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(a, &mem, &nb);

    const params = try mkParams(a, "{\"request_method\": \"GET\", \"path\": \"/v1/spool\", \"query\": \"a=1&b=2\"}");
    try testing.expectError(error.ServiceUnavailable, handleProxy(@ptrCast(&ctx), params, a));
}

test "handleProxy forwards to <server>/api with JSON body, headers and Spoolman errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    const io = testing.io;
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);

    const Peer = struct {
        target: [128]u8 = undefined,
        target_len: usize = 0,
        content_type: [64]u8 = undefined,
        content_type_len: usize = 0,
        body: [64]u8 = undefined,
        body_len: usize = 0,

        /// Serve one request, recording the request target, content type and body.
        fn serve(self: *@This(), s: *std.Io.net.Server, aio: std.Io, reply: []const u8) void {
            const stream = s.accept(aio) catch return;
            defer stream.close(aio);
            var rbuf: [2048]u8 = undefined;
            var r = stream.reader(aio, &rbuf);
            const request_line = r.interface.takeDelimiterInclusive('\n') catch return;
            var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
            _ = parts.next();
            const target = parts.next() orelse return;
            @memcpy(self.target[0..target.len], target);
            self.target_len = target.len;
            var length: usize = 0;
            while (true) {
                const line = r.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
                const value = std.mem.trim(u8, line[(std.mem.indexOfScalar(u8, line, ':') orelse continue) + 1 ..], " \r\n");
                if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                    @memcpy(self.content_type[0..value.len], value);
                    self.content_type_len = value.len;
                }
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) length = std.fmt.parseInt(usize, value, 10) catch return;
            }
            r.interface.readSliceAll(self.body[0..length]) catch return;
            self.body_len = length;
            var wbuf: [512]u8 = undefined;
            var w = stream.writer(aio, &wbuf);
            w.interface.writeAll(reply) catch return;
            w.interface.flush() catch return;
        }
    };

    var ctx = try makeCtx(std.heap.smp_allocator, &mem, &nb);
    defer ctx.deinit();
    var url: [64]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url, "127.0.0.1:{d}/", .{server.socket.address.getPort()}));
    ctx.io = io;
    ctx.ws_connected.store(true, .release);

    var peer: Peer = .{};
    var task = io.async(Peer.serve, .{ &peer, &server, io, @as([]const u8, "HTTP/1.1 201 Created\r\nX-Test: yes\r\nContent-Length: 8\r\nConnection: close\r\n\r\n{\"id\":3}") });
    const ok = try handleProxy(@ptrCast(&ctx), try mkParams(a, "{\"request_method\":\"POST\",\"path\":\"/v1/spool\",\"query\":\"a=1\",\"body\":{\"x\":1},\"use_v2_response\":true}"), a);
    task.await(io);
    try testing.expectEqualStrings("/api/v1/spool?a=1", peer.target[0..peer.target_len]);
    try testing.expectEqualStrings("application/json", peer.content_type[0..peer.content_type_len]);
    try testing.expectEqualStrings("{\"x\":1}", peer.body[0..peer.body_len]);
    try testing.expectEqual(@as(i64, 3), ok.object.get("response").?.object.get("id").?.integer);
    try testing.expectEqualStrings("yes", ok.object.get("response_headers").?.object.get("X-Test").?.string);
    try testing.expect(ok.object.get("error").? == .null);

    peer = .{};
    task = io.async(Peer.serve, .{ &peer, &server, io, @as([]const u8, "HTTP/1.1 404 Not Found\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"message\":\"No such spool\"}") });
    const missing = try handleProxy(@ptrCast(&ctx), try mkParams(a, "{\"request_method\":\"GET\",\"path\":\"/v1/spool/9\",\"use_v2_response\":true}"), a);
    task.await(io);
    const err = missing.object.get("error").?.object;
    try testing.expectEqual(@as(i64, 404), err.get("status_code").?.integer);
    try testing.expectEqualStrings("No such spool", err.get("message").?.string);

    var dispatcher = jsonrpc.Dispatcher.init(a);
    defer dispatcher.deinit();
    try dispatcher.registerEntry("proxy", .{ .ctx = &ctx, .handler = handleProxy, .off_core = true });
    task = io.async(Peer.serve, .{ &peer, &server, io, @as([]const u8, "HTTP/1.1 404 Custom reason\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"message\":\"No such spool\"}") });
    const wire = try dispatcher.handle("{\"jsonrpc\":\"2.0\",\"method\":\"proxy\",\"params\":{\"request_method\":\"GET\",\"path\":\"/v1/spool/9\"},\"id\":1}", a);
    task.await(io);
    const reply = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
    const failure = reply.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32601), failure.get("code").?.integer);
    try testing.expectEqualStrings("Custom reason", failure.get("message").?.string);

    for ([_][]const u8{
        "HTTP/1.1 404 \xff\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX-Label: \xff\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    }) |invalid| {
        task = io.async(Peer.serve, .{ &peer, &server, io, invalid });
        const unavailable = try handleProxy(@ptrCast(&ctx), try mkParams(a, "{\"request_method\":\"GET\",\"path\":\"/v1/spool\",\"use_v2_response\":true}"), a);
        task.await(io);
        try testing.expectEqual(@as(i64, 503), unavailable.object.get("error").?.object.get("status_code").?.integer);
    }
}

test "Spoolman proxy survives a reset during a fixed-length body" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, aio: std.Io) !void {
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(aio, &wbuf);
            try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n{\"a\":");
            try w.interface.flush();
            // Unread request bytes make close reset the connection.
            try aio.sleep(.fromMilliseconds(50), .awake);
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &server, io });
    defer peer.cancel(io) catch {};
    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    if (proxyRequest(std.heap.smp_allocator, io, .GET, url, null, arena.allocator(), .fromSeconds(1))) |_| {
        return error.ExpectedInterruptedBody;
    } else |err| try testing.expect(err == error.ReadFailed or err == error.HttpConnectionClosing);
    try peer.await(io);
}

test "Spoolman proxy cancels a stalled response at its deadline" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, aio: std.Io, closed: *std.Io.Event) !void {
            defer closed.set(aio);
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var buf: [4096]u8 = undefined;
            var reader = stream.reader(aio, &buf);
            while (true) _ = try reader.interface.takeByte();
        }
    };
    var closed: std.Io.Event = .unset;
    var peer = try io.concurrent(Peer.run, .{ &server, io, &closed });
    defer peer.cancel(io) catch {};
    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, proxyRequest(std.heap.smp_allocator, io, .GET, url, null, arena.allocator(), .fromMilliseconds(50)));
    try testing.expect(started.untilNow(io).raw.toMilliseconds() < 1000);
    try closed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try testing.expectError(error.EndOfStream, peer.await(io));
}

test "Spoolman proxy converts excessive JSON nesting into a safe string" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var nb = NullBus.init(a);
    var ctx = try makeCtx(std.heap.smp_allocator, &mem, &nb);
    defer ctx.deinit();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, aio: std.Io) !void {
            const stream = try s.accept(aio);
            defer stream.close(aio);
            var rbuf: [2048]u8 = undefined;
            var reader = stream.reader(aio, &rbuf);
            var head: std.http.Reader = .{ .in = &reader.interface, .interface = undefined, .state = .ready, .max_head_len = 2048 };
            _ = try head.receiveHead();
            var wbuf: [2048]u8 = undefined;
            var writer = stream.writer(aio, &wbuf);
            const depth = 512;
            try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{depth * 2});
            try writer.interface.splatByteAll('[', depth);
            try writer.interface.splatByteAll(']', depth);
            try writer.interface.flush();
        }
    };
    var peer = try io.concurrent(Peer.run, .{ &server, io });
    defer peer.cancel(io) catch {};
    var url_buf: [80]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url_buf, "127.0.0.1:{d}", .{server.socket.address.getPort()}));
    ctx.io = io;
    ctx.ws_connected.store(true, .release);
    const result = try handleProxy(@ptrCast(&ctx), try mkParams(a, "{\"request_method\":\"GET\",\"path\":\"/v1/spool\",\"use_v2_response\":true}"), a);
    try testing.expect(result.object.get("response").? == .string);
    const serialized = try jv.successResponse(a, .{ .integer = 1 }, result);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, serialized, .{});
    try testing.expectEqual(@as(usize, 1024), parsed.object.get("result").?.object.get("response").?.string.len);
    try peer.await(io);
}

test "fuzz Spoolman response bodies stay safe to serialize" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [512]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const depth: usize = buf[0];
            const nested = buf[1] % 2 == 0;
            if (nested) {
                @memset(buf[0..depth], '[');
                @memset(buf[depth .. depth * 2], ']');
            }
            const body = if (nested) buf[0 .. depth * 2] else &buf;
            const parsed = parseProxyBody(a, body) catch |err| switch (err) {
                error.InvalidUtf8 => {
                    try testing.expect(!std.unicode.utf8ValidateSlice(body));
                    return;
                },
                else => return err,
            };
            try testing.expect(!jv.exceedsDepth(parsed, jv.max_value_depth));
            const wire = try jv.successResponse(a, .{ .integer = 1 }, parsed);
            _ = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
        }
    }.run, .{});
}

test "Spoolman response parsing rejects invalid UTF-8 and preserves plain text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidUtf8, parseProxyBody(a, "\xff"));
    try testing.expectEqualStrings("not JSON", (try parseProxyBody(a, "not JSON")).string);
    try testing.expectEqual(std.json.Value.null, try parseProxyBody(a, ""));
    try testing.expectEqual(@as(i64, 7), (try parseProxyBody(a, "7")).integer);
    const Allocation = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var parsed_arena = std.heap.ArenaAllocator.init(gpa);
            defer parsed_arena.deinit();
            _ = try parseProxyBody(parsed_arena.allocator(), "{\"items\":[1,{\"value\":\"test\"}]}");
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Allocation.run, .{});
}

test "Spoolman response numbers remain valid JSON after serialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try parseProxyBody(a, "{\"v\":[1.25,-2,{\"huge\":[1e500,-1e500]}]}");
    const wire = try jv.successResponse(a, .{ .integer = 1 }, result);
    const round_trip = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
    const values = round_trip.object.get("result").?.object.get("v").?.array.items;
    try testing.expectEqual(@as(f64, 1.25), values[0].float);
    try testing.expectEqual(@as(i64, -2), values[1].integer);
    const huge = values[2].object.get("huge").?.array.items;
    try testing.expectEqualStrings("1e500", huge[0].number_string);
    try testing.expectEqualStrings("-1e500", huge[1].number_string);
}

test "fuzz handleSpoolId: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = try makeCtx(a, &mem, &nb);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"spool_id\": 1}",
                "{\"spool_id\": null}",
                "{\"spool_id\": \"bad\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleSpoolId(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleProxy: never panics on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = try makeCtx(a, &mem, &nb);

            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"request_method\": \"GET\", \"path\": \"/v1/spool\"}",
                "{\"request_method\": \"POST\", \"path\": \"/v1/spool\", \"use_v2_response\": true}",
                "{\"request_method\": \"GET\", \"path\": \"/bad\"}",
            };
            const p = std.json.parseFromSlice(
                std.json.Value,
                a,
                strs[buf[0] % strs.len],
                .{},
            ) catch return;
            _ = handleProxy(@ptrCast(&ctx), p.value, a) catch {};
        }
    }.run, .{});
}

test "fuzz handleStatus: never panics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var nb = NullBus.init(a);
            var ctx = try makeCtx(a, &mem, &nb);

            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = handleStatus(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "stopWs cancels a peer stalled before the upgrade response" {
    const a = std.heap.smp_allocator;
    var mem = MemStore.init(a);
    defer mem.deinit();
    const aio = testing.io;
    var core = Core.init();
    var conns = connections_mod.Connections.init(a, &core);
    defer conns.deinit(aio);
    var bus = NotifyBus.init(&core, &conns);
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
    defer server.deinit(aio);
    var accepted: std.Io.Event = .unset;
    const Peer = struct {
        fn run(s: *std.Io.net.Server, ready: *std.Io.Event, io: std.Io) void {
            const stream = s.accept(io) catch return;
            defer stream.close(io);
            ready.set(io);
            var buf: [512]u8 = undefined;
            var reader = stream.reader(io, &buf);
            while (true) _ = reader.interface.takeByte() catch break;
        }
    };
    var peer = try aio.concurrent(Peer.run, .{ &server, &accepted, aio });
    defer peer.cancel(aio);
    var ctx = try SpoolmanCtx.init(a, mem.dataStore(), &bus);
    defer ctx.deinit();
    var url: [80]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}", .{server.socket.address.getPort()}));
    ctx.io = aio;
    ctx.startWs();
    try accepted.waitTimeout(aio, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
    const start = std.Io.Clock.Timestamp.now(aio, .awake);
    ctx.stopWs();
    try testing.expect(start.untilNow(aio).raw.toMilliseconds() < 1000);
    try testing.expect(ctx.ws_thread == null);
}

test "Spoolman URI parsing preserves IPv6, TLS, and reverse-proxy paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var mem = MemStore.init(arena.allocator());
    defer mem.deinit();
    var nb = NullBus.init(arena.allocator());
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try ctx.setServerUrl("https://[::1]:7443/spools/");
    try testing.expectEqualStrings("https://[::1]:7443/spools/api", ctx.api_url.?);
    try testing.expectEqualStrings("::1", ctx.ws_host.?);
    try testing.expectEqualStrings("/spools/api/v1/spool", ctx.ws_path.?);
    try testing.expectEqual(@as(u16, 7443), ctx.ws_port);
    try testing.expect(ctx.ws_tls);
    try testing.expectError(error.InvalidPort, ctx.setServerUrl("http://localhost:bad"));
    try testing.expectError(error.InvalidUrl, ctx.setServerUrl("https://localhost?token=x"));
    try testing.expectEqualStrings("::1", ctx.ws_host.?);
    for (0..3) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        ctx.gpa = failing.allocator();
        try testing.expectError(error.OutOfMemory, ctx.setServerUrl("http://newhost:7912/new"));
        ctx.gpa = testing.allocator;
        try testing.expectEqualStrings("::1", ctx.ws_host.?);
        try testing.expectEqualStrings("https://[::1]:7443/spools/api", ctx.api_url.?);
    }
}

test "fuzz Spoolman URI parser rejects malformed bounded targets" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var mem = MemStore.init(arena.allocator());
            defer mem.deinit();
            var nb = NullBus.init(arena.allocator());
            var ctx = try makeCtx(testing.allocator, &mem, &nb);
            defer ctx.deinit();
            var raw: [96]u8 = undefined;
            smith.bytesWithHash(&raw, 0);
            ctx.setServerUrl(&raw) catch return;
            try testing.expect(std.mem.endsWith(u8, ctx.api_url.?, "/api"));
            try testing.expect(std.mem.endsWith(u8, ctx.ws_path.?, "/api/v1/spool"));
        }
    }.run, .{});
}

test "Spoolman report claims preserve new usage, retries and deletion generations" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var nb = NullBus.init(testing.allocator);
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try ctx.setSpoolId(1);
    ctx.pending_reports.getPtr(1).?.used = 10;
    var batch: [max_pending_spools]ReportClaim = undefined;
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    ctx.pending_reports.getPtr(1).?.used = 2;
    try ctx.finishReportLocked(batch[0], .retry);
    try testing.expectEqual(@as(f64, 12), ctx.pending_reports.get(1).?.used);
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    const old = batch[0];
    try ctx.handleSpoolDeletedLocked(1);
    try ctx.setSpoolId(1);
    ctx.pending_reports.getPtr(1).?.used = 3;
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    try ctx.finishReportLocked(old, .retry);
    try testing.expectEqual(@as(f64, 0), ctx.pending_reports.get(1).?.used);
    ctx.restoreReportsLocked(batch[0..1]);
    try testing.expectEqual(@as(f64, 3), ctx.pending_reports.get(1).?.used);
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    mem.fail_writes = true;
    try testing.expectError(error.BackendError, ctx.finishReportLocked(batch[0], .missing));
    try testing.expectEqual(@as(?i64, 1), ctx.getSpoolId());
    ctx.restoreReportsLocked(batch[0..1]);
    try testing.expectEqual(@as(f64, 3), ctx.pending_reports.get(1).?.used);
    mem.fail_writes = false;
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    try ctx.finishReportLocked(batch[0], .missing);
    try testing.expect(ctx.getSpoolId() == null);
    try testing.expectEqual(@as(usize, 0), ctx.pending_reports.count());
    try ctx.setSpoolId(2);
    ctx.pending_reports.getPtr(2).?.used = 5;
    try ctx.setSpoolId(3);
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    try ctx.finishReportLocked(batch[0], .sent);
    ctx.restoreReportsLocked(batch[0..1]);
    try testing.expect(!ctx.pending_reports.contains(2));
    try testing.expectEqual(@as(?i64, 3), ctx.getSpoolId());
    try testing.expectEqual(@as(usize, 0), ctx.claimReportsLocked(&batch));
    ctx.pending_reports.getPtr(3).?.used = std.math.floatMax(f64) / 2;
    try testing.expectEqual(@as(usize, 1), ctx.claimReportsLocked(&batch));
    ctx.onKlippyStateLocked(true);
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    try ctx.onKlippyStatusLocked(try mkParams(scratch.allocator(), "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
    try testing.expectError(error.InvalidParams, ctx.onKlippyStatusLocked(try mkParams(scratch.allocator(), "{\"toolhead\":{\"position\":[0,0,0,1.7976931348623157e308]}}"), .null));
    ctx.restoreReportsLocked(batch[0..1]);
    try testing.expectEqual(std.math.floatMax(f64) / 2, ctx.pending_reports.get(3).?.used);
}

test "Spoolman sync rate rejects invalid values before mutation" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var nb = NullBus.init(testing.allocator);
    var ctx = try makeCtx(testing.allocator, &mem, &nb);
    defer ctx.deinit();
    try testing.expectEqual(default_sync_rate_seconds, ctx.sync_rate_seconds);
    try ctx.setSyncRate(1);
    for ([_]i64{ 0, -1, std.math.maxInt(i64) }) |bad| {
        try testing.expectError(error.InvalidSyncRate, ctx.setSyncRate(bad));
        try testing.expectEqual(@as(u32, 1), ctx.sync_rate_seconds);
    }
}

test "fuzz Spoolman report transitions retain finite bounded usage" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var mem = MemStore.init(testing.allocator);
            defer mem.deinit();
            var nb = NullBus.init(testing.allocator);
            var ctx = try makeCtx(testing.allocator, &mem, &nb);
            defer ctx.deinit();
            var batch: [max_pending_spools]ReportClaim = undefined;
            for (0..64) |step_index| {
                const step: u32 = @intCast(step_index);
                const id = smith.valueRangeAtMostWithHash(i64, 0, 7, step * 3);
                try ctx.setSpoolId(id);
                ctx.pending_reports.getPtr(id).?.used += @floatFromInt(smith.valueRangeAtMostWithHash(u16, 0, 1000, step * 3 + 1));
                const count = ctx.claimReportsLocked(&batch);
                for (batch[0..count]) |claim| {
                    const result: ReportResult = @fromBackingInt(@intCast(smith.valueRangeAtMostWithHash(u8, 0, 2, step * 3 + 2)));
                    try ctx.finishReportLocked(claim, result);
                }
                ctx.restoreReportsLocked(batch[0..count]);
                try testing.expect(ctx.pending_reports.count() <= max_pending_spools);
                for (ctx.pending_reports.values()) |report| {
                    try testing.expect(report.in_flight == null);
                    try testing.expect(std.math.isFinite(report.used) and report.used >= 0);
                }
            }
            const seconds = smith.value(i64);
            const result = ctx.setSyncRate(seconds);
            if (seconds >= 1 and seconds <= std.math.maxInt(u32)) try result else try testing.expectError(error.InvalidSyncRate, result);
        }
    }.run, .{});
}

/// Local HTTP/WebSocket fixture; all workers use the runtime allocator.
const ReportPeer = struct {
    mutex: std.Io.Mutex = .init,
    uses: [16]f64 = @splat(0),
    ids: [16]i64 = @splat(0),
    reports: std.atomic.Value(u32) = .init(0),
    validations: std.atomic.Value(u32) = .init(0),
    sockets: std.atomic.Value(u32) = .init(0),
    disconnect_through: std.atomic.Value(u32) = .init(0),
    missing: std.atomic.Value(bool) = .init(false),
    first_fails: bool = false,
    stall: bool = false,
    release: std.Io.Event = .unset,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This(), server: *std.Io.net.Server, aio: std.Io) void {
        var tasks: [24]?std.Io.Future(void) = @splat(null);
        defer for (&tasks) |*task| if (task.*) |*future| future.cancel(aio);
        for (&tasks) |*task| {
            const stream = server.accept(aio) catch return;
            task.* = aio.concurrent(serve, .{ self, stream, aio }) catch {
                stream.close(aio);
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn serve(self: *@This(), stream: std.Io.net.Stream, aio: std.Io) void {
        defer stream.close(aio);
        self.serveRequest(stream, aio) catch |err| switch (err) {
            error.Canceled, error.ReadFailed, error.WriteFailed => {},
            else => self.failed.store(true, .release),
        };
    }

    fn serveRequest(self: *@This(), stream: std.Io.net.Stream, aio: std.Io) !void {
        var rbuf: [4096]u8 = undefined;
        var wbuf: [2048]u8 = undefined;
        var reader = stream.reader(aio, &rbuf);
        var writer = stream.writer(aio, &wbuf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        switch (request.upgradeRequested()) {
            .websocket => |maybe_key| {
                var ws = try request.respondWebSocket(.{ .key = maybe_key orelse return error.InvalidUpgrade });
                try ws.flush();
                const generation = self.sockets.fetchAdd(1, .acq_rel) + 1;
                while (generation > self.disconnect_through.load(.acquire)) try aio.sleep(.fromMilliseconds(5), .awake);
                return;
            },
            else => {},
        }
        if (!std.mem.startsWith(u8, request.head.target, "/api/v1/spool/")) return error.InvalidTarget;
        const suffix = request.head.target["/api/v1/spool/".len..];
        const id_text = suffix[0 .. std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len];
        const id = try std.fmt.parseInt(i64, id_text, 10);
        if (request.head.method == .GET) {
            _ = self.validations.fetchAdd(1, .acq_rel);
            try request.respond("", .{ .status = if (self.missing.load(.acquire)) .not_found else .ok, .keep_alive = false });
            return;
        }
        if (request.head.method != .PUT or !std.mem.endsWith(u8, suffix, "/use")) return error.InvalidMethod;
        var body_buf: [512]u8 = undefined;
        const body = try request.readerExpectNone(&body_buf).allocRemaining(std.heap.smp_allocator, .limited(512));
        defer std.heap.smp_allocator.free(body);
        const parsed = try std.json.parseFromSlice(struct { use_length: f64 }, std.heap.smp_allocator, body, .{});
        defer parsed.deinit();
        self.mutex.lockUncancelable(aio);
        const index = self.reports.load(.monotonic);
        const reply_status: std.http.Status = if (self.missing.load(.acquire)) .not_found else if (self.first_fails and index == 0) .service_unavailable else .ok;
        if (index >= self.uses.len) {
            self.mutex.unlock(aio);
            return error.TooManyReports;
        }
        self.uses[index] = parsed.value.use_length;
        self.ids[index] = id;
        self.reports.store(index + 1, .release);
        self.mutex.unlock(aio);
        if (self.stall) try self.release.wait(aio);
        try request.respond("", .{ .status = reply_status, .keep_alive = false });
    }

    fn waitCount(counter: *std.atomic.Value(u32), aio: std.Io, minimum: u32) !void {
        const start = std.Io.Clock.Timestamp.now(aio, .awake);
        while (counter.load(.acquire) < minimum) {
            if (start.untilNow(aio).raw.toMilliseconds() > 5000) return error.Timeout;
            try aio.sleep(.fromMilliseconds(5), .awake);
        }
    }
};

test "Spoolman live reporter retries, obeys sync rate and validates on reconnect" {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var peer: ReportPeer = .{ .first_fails = true };
    var fake = try io.concurrent(ReportPeer.run, .{ &peer, &server, io });
    defer fake.cancel(io);
    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var core = Core.init();
    var conns = connections_mod.Connections.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try SpoolmanCtx.init(alloc, mem.dataStore(), &bus);
    defer ctx.deinit();
    var url: [64]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url, "127.0.0.1:{d}", .{server.socket.address.getPort()}));
    try ctx.setSyncRate(1);
    try ctx.setSpoolId(17);
    ctx.pending_reports.getPtr(17).?.used = 10;
    ctx.io = io;
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    ctx.startWs();
    try ReportPeer.waitCount(&peer.reports, io, 2);
    try testing.expect(started.untilNow(io).raw.toMilliseconds() >= 900);
    peer.disconnect_through.store(1, .release);
    core.lock(io);
    ctx.pending_reports.getPtr(17).?.used += 3;
    core.unlock(io);
    try ReportPeer.waitCount(&peer.sockets, io, 2);
    try ReportPeer.waitCount(&peer.reports, io, 3);
    peer.mutex.lockUncancelable(io);
    const uses = peer.uses[0..3].*;
    const ids = peer.ids[0..3].*;
    peer.mutex.unlock(io);
    try testing.expectEqualSlices(f64, &.{ 10, 10, 3 }, &uses);
    try testing.expectEqualSlices(i64, &.{ 17, 17, 17 }, &ids);
    peer.missing.store(true, .release);
    peer.disconnect_through.store(2, .release);
    try ReportPeer.waitCount(&peer.validations, io, 3);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (core.run(io, SpoolmanCtx.getSpoolId, .{&ctx}) != null) {
        if (start.untilNow(io).raw.toMilliseconds() > 3000) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    ctx.stopWs();
    try testing.expect(!ctx.connected());
    try testing.expect(ctx.report_thread == null and ctx.ws_thread == null);
    try testing.expect(!peer.failed.load(.acquire));
}

test "Spoolman cancellation restores an in-flight report and permits Core updates" {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    var peer: ReportPeer = .{ .stall = true };
    var fake = try io.concurrent(ReportPeer.run, .{ &peer, &server, io });
    defer fake.cancel(io);
    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var core = Core.init();
    var conns = connections_mod.Connections.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var ctx = try SpoolmanCtx.init(alloc, mem.dataStore(), &bus);
    defer ctx.deinit();
    var url: [64]u8 = undefined;
    try ctx.setServerUrl(try std.fmt.bufPrint(&url, "127.0.0.1:{d}", .{server.socket.address.getPort()}));
    try ctx.setSpoolId(4);
    ctx.pending_reports.getPtr(4).?.used = 10;
    ctx.onKlippyStateLocked(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try ctx.onKlippyStatusLocked(try mkParams(arena.allocator(), "{\"toolhead\":{\"position\":[0,0,0,0]}}"), .null);
    ctx.io = io;
    ctx.startWs();
    try ReportPeer.waitCount(&peer.reports, io, 1);
    try core.run(io, SpoolmanCtx.onKlippyStatusLocked, .{ &ctx, try mkParams(arena.allocator(), "{\"toolhead\":{\"position\":[0,0,0,2]}}"), @as(std.json.Value, .null) });
    const status = try core.run(io, handleStatus, .{ @as(*anyopaque, &ctx), @as(std.json.Value, .null), arena.allocator() });
    const pending = status.object.get("pending_reports").?.array.items;
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(@as(f64, 2), pending[0].object.get("filament_used").?.float);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    ctx.stopWs();
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 1000);
    try testing.expectEqual(@as(f64, 12), ctx.pending_reports.get(4).?.used);
    try testing.expect(ctx.pending_reports.get(4).?.in_flight == null);
    // A 404 from a usage update also drops the queue and persisted selection.
    peer.missing.store(true, .release);
    peer.release.set(io);
    ctx.ws_stop.reset();
    ctx.ws_connected.store(true, .release);
    ctx.reportExtrusion();
    try testing.expect(ctx.getSpoolId() == null);
    try testing.expectEqual(@as(usize, 0), ctx.pending_reports.count());
    peer.missing.store(false, .release);
    try core.run(io, SpoolmanCtx.setSpoolId, .{ &ctx, @as(?i64, 19) });
    ctx.pending_reports.getPtr(19).?.used = std.math.floatMax(f64);
    ctx.reportExtrusion();
    try testing.expectEqual(std.math.floatMax(f64), peer.uses[2]);
    try testing.expect(!peer.failed.load(.acquire));
}

test "Klippy Unix snapshots and pushed extrusion reach the Spoolman reporter" {
    const klippy_mod = @import("klippy_connection.zig");
    const framing = @import("../util/klippy_frame.zig");
    const KlippyPeer = struct {
        reconnect: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This(), server: *std.Io.net.Server, aio: std.Io) void {
            self.sessions(server, aio) catch |err| switch (err) {
                error.Canceled => {},
                else => self.failed.store(true, .release),
            };
        }

        fn sessions(self: *@This(), server: *std.Io.net.Server, aio: std.Io) !void {
            for (0..2) |cycle| {
                const stream = try server.accept(aio);
                defer stream.close(aio);
                var rbuf: [4096]u8 = undefined;
                var wbuf: [2048]u8 = undefined;
                var reader = stream.reader(aio, &rbuf);
                var writer = stream.writer(aio, &wbuf);
                while (true) {
                    const payload = try framing.read(std.heap.smp_allocator, &reader.interface);
                    defer std.heap.smp_allocator.free(payload);
                    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, payload, .{});
                    defer parsed.deinit();
                    const req = parsed.value.object;
                    const method = req.get("method").?.string;
                    const id = req.get("id").?.string;
                    var response: [512]u8 = undefined;
                    const result = if (std.mem.eql(u8, method, "info"))
                        "{\"state\":\"ready\"}"
                    else if (std.mem.eql(u8, method, "objects/query"))
                        "{\"status\":{\"heaters\":{\"available_sensors\":[]}}}"
                    else if (std.mem.eql(u8, method, "objects/subscribe"))
                        (if (cycle == 0) "{\"status\":{\"toolhead\":{\"position\":[0,0,0,100],\"extruder\":\"extruder\"}},\"eventtime\":1}" else "{\"status\":{\"toolhead\":{\"position\":[0,0,0,0],\"extruder\":\"extruder\"}},\"eventtime\":2}")
                    else
                        "{}";
                    try framing.write(&writer.interface, try std.fmt.bufPrint(&response, "{{\"id\":\"{s}\",\"result\":{s}}}", .{ id, result }));
                    try writer.interface.flush();
                    if (std.mem.eql(u8, method, "gcode/subscribe_output")) break;
                }
                const first = [_][]const u8{
                    "{\"toolhead\":{\"position\":[0,0,0,105]}}",
                    "{\"toolhead\":{\"position\":[0,0,0,103]}}",
                    "{\"toolhead\":{\"position\":[0,0,0,105]}}",
                    "{\"toolhead\":{\"position\":[0,0,0,107]}}",
                    "{\"toolhead\":{\"position\":[0,0,0,108]},\"gcode_move\":{\"extrude_factor\":0.5}}",
                    "{\"toolhead\":{\"position\":[0,0,0,1000],\"extruder\":\"extruder1\"}}",
                    "{\"toolhead\":{\"position\":[0,0,0,1002]}}",
                };
                const second = [_][]const u8{"{\"toolhead\":{\"position\":[0,0,0,3]}}"};
                const updates: []const []const u8 = if (cycle == 0) &first else &second;
                for (updates) |status| {
                    var frame: [512]u8 = undefined;
                    try framing.write(&writer.interface, try std.fmt.bufPrint(&frame, "{{\"method\":\"process_status_update\",\"params\":{{\"status\":{s},\"eventtime\":3}}}}", .{status}));
                }
                try writer.interface.flush();
                if (cycle == 0) try self.reconnect.wait(aio) else try self.finish.wait(aio);
            }
        }
    };
    const Capture = struct {
        spoolman: *SpoolmanCtx,
        klippy: *klippy_mod.KlippyCtx,
        statuses: std.atomic.Value(u32) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        fn state(raw: *anyopaque, _: std.Io, state_value: klippy_mod.State) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.spoolman.onKlippyStateLocked(state_value == .ready);
        }
        fn status(raw: *anyopaque, _: std.Io, value: std.json.Value, time: std.json.Value) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // The seeded status precedes the final ready callback.
            self.spoolman.onKlippyStateLocked(self.klippy.state == .ready and self.spoolman.api_url != null);
            self.spoolman.onKlippyStatusLocked(value, time) catch self.failed.store(true, .release);
            _ = self.statuses.fetchAdd(1, .acq_rel);
        }
    };
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/spool-klippy.sock", .{ testing.TmpDir.parent_dir_path, &tmp.sub_path });
    var uds = try (try std.Io.net.UnixAddress.init(path)).listen(io, .{});
    defer uds.deinit(io);
    var klippy_peer: KlippyPeer = .{};
    var unix_task = try io.concurrent(KlippyPeer.run, .{ &klippy_peer, &uds, io });
    defer unix_task.cancel(io);
    var http = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer http.deinit(io);
    var report_peer: ReportPeer = .{};
    var http_task = try io.concurrent(ReportPeer.run, .{ &report_peer, &http, io });
    defer http_task.cancel(io);
    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var core = Core.init();
    var conns = connections_mod.Connections.init(alloc, &core);
    defer conns.deinit(io);
    var bus = NotifyBus.init(&core, &conns);
    var spoolman = try SpoolmanCtx.init(alloc, mem.dataStore(), &bus);
    defer spoolman.deinit();
    var url: [64]u8 = undefined;
    try spoolman.setServerUrl(try std.fmt.bufPrint(&url, "127.0.0.1:{d}", .{http.socket.address.getPort()}));
    try spoolman.setSpoolId(29);
    spoolman.io = io;
    spoolman.ws_connected.store(true, .release);
    var klippy = try klippy_mod.KlippyCtx.init(alloc, &bus);
    defer klippy.deinit();
    klippy.setIo(io);
    klippy.uds_path = path;
    var capture: Capture = .{ .spoolman = &spoolman, .klippy = &klippy };
    klippy.event_ctx = &capture;
    klippy.on_state = Capture.state;
    klippy.on_status = Capture.status;
    try klippy.start();
    defer klippy.stop(io);
    try ReportPeer.waitCount(&capture.statuses, io, 8);
    spoolman.reportExtrusion();
    try testing.expectEqual(@as(u32, 1), report_peer.reports.load(.acquire));
    try testing.expectEqual(@as(f64, 10), report_peer.uses[0]);
    klippy_peer.reconnect.set(io);
    try ReportPeer.waitCount(&capture.statuses, io, 10);
    spoolman.reportExtrusion();
    try testing.expectEqual(@as(u32, 2), report_peer.reports.load(.acquire));
    try testing.expectEqual(@as(f64, 3), report_peer.uses[1]);
    try testing.expectEqual(@as(i64, 29), report_peer.ids[1]);
    try testing.expect(!capture.failed.load(.acquire));
    try testing.expect(!klippy_peer.failed.load(.acquire));
    try testing.expect(!report_peer.failed.load(.acquire));
}

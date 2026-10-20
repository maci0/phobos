//! App: single assembly point for the phobos server.
//!
//! `App.init` constructs and owns every shared component (Core, Dispatcher,
//! Registry, Connections, NotifyBus, ServerInfo) and calls `registerAll()`,
//! which is the one canonical place where every currently-implemented endpoint,
//! JSON-RPC method, and notification name is wired in.
//!
//! The `--dump-api` command and the test harness both build an App so prod and
//! test share identical registration logic.

const std = @import("std");

const Core = @import("server/core.zig").Core;
const jsonrpc = @import("jsonrpc.zig");
const registry = @import("server/registry.zig");
const connections = @import("server/connections.zig");
const notify = @import("server/notify.zig");
const methods = @import("core/methods.zig");
const ws = @import("transport/ws.zig");
const http_transport = @import("http_transport.zig");
const db_component = @import("components/database.zig");
const history_component = @import("components/history.zig");
const job_queue_component = @import("components/job_queue.zig");
const job_state_component = @import("components/job_state.zig");
const announcements_component = @import("components/announcements.zig");
const data_store_component = @import("components/data_store.zig");
const server_misc_component = @import("components/server_misc.zig");
const notifier_component = @import("components/notifier.zig");
const webcam_component = @import("components/webcam.zig");
const sensor_component = @import("components/sensor.zig");
const authorization_component = @import("components/authorization.zig");
const spoolman_component = @import("components/spoolman.zig");
const mqtt_component = @import("components/mqtt.zig");
const mqtt_credentials = @import("components/mqtt_credentials.zig");
const extensions_component = @import("components/extensions.zig");
const analysis_component = @import("components/analysis.zig");
const file_manager_component = @import("components/file_manager.zig");
const machine_component = @import("components/machine.zig");
const update_manager_component = @import("components/update_manager.zig");
const power_component = @import("components/power.zig");
const button_component = @import("components/button.zig");
const wled_component = @import("components/wled.zig");
const td1_component = @import("components/td1.zig");
const printer_component = @import("components/printer.zig");
const klippy_connection_component = @import("components/klippy_connection.zig");
const octoprint_component = @import("components/octoprint_compat.zig");
const zeroconf_component = @import("components/zeroconf.zig");
const paneldue_component = @import("components/paneldue.zig");
const feather_updates_component = @import("components/feather_updates.zig");
const ds = @import("store/datastore.zig");
const config_helper = @import("config/confighelper.zig");

const feather_component_name = [_][]const u8{"feather_updates"};

fn restartUpdatedService(ctx: *anyopaque, alloc: std.mem.Allocator, service: []const u8) !void {
    const machine: *MachineCtx = @ptrCast(@alignCast(ctx));
    try machine.serviceAction(alloc, .restart, service);
}

fn featherPrinterIdle(ctx: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.core.run(app.update_ctx.clock_io, featherPrinterIdleLocked, .{app});
}

fn featherPrinterIdleLocked(app: *App) bool {
    if (!app.info.klippy_connected) return false;
    if (!std.mem.eql(u8, app.info.klippy_state, "ready")) return false;
    return !app.job_state_ctx.isActive();
}

fn hostPowerArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "reboot") or std.mem.eql(u8, arg, "shutdown") or std.mem.eql(u8, arg, "poweroff");
}

const GitSpawnFn = *const fn (*anyopaque, std.mem.Allocator, []const []const u8) anyerror!void;

/// Production Feather runner. Git argv runs as `git -C <configured repo>`.
/// `machine.update.client` goes through `handleUpdateClient`. Reboot,
/// shutdown, and poweroff are refused. A null `git_spawn` runs git only when
/// the update manager has a live io; tests install `git_spawn` and never
/// spawn git. Apt and pip strings are not executed here.
fn daemonFeatherRun(app: *App, alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    for (argv) |arg| {
        if (hostPowerArg(arg)) return error.Refused;
    }
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "machine.update.client")) {
        if (argv.len < 2 or argv[1].len == 0) return error.UpdateFailed;
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "name", .{ .string = argv[1] });
        const result = update_manager_component.handleUpdateClient(app.update_ctx, .{ .object = params }, a) catch return error.UpdateFailed;
        if (result != .string or !std.mem.eql(u8, result.string, "ok")) return error.UpdateFailed;
        return;
    }
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "git")) {
        const src = app.update_ctx.findSource(app.feather.update_key) orelse return error.NoCommandRunner;
        if (src.repo_path.len == 0) return error.NoCommandRunner;
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(alloc);
        try full.append(alloc, "git");
        try full.append(alloc, "-C");
        try full.append(alloc, src.repo_path);
        for (argv[1..]) |arg| try full.append(alloc, arg);
        if (app.git_spawn) |spawn| {
            const sctx = app.git_spawn_ctx orelse return error.NoCommandRunner;
            try spawn(sctx, alloc, full.items);
            return;
        }
        const io = app.update_ctx.io orelse return error.NoCommandRunner;
        const result = update_manager_component.gitRun(io, alloc, src.repo_path, argv[1..], update_manager_component.git_fetch_timeout_s, app.update_ctx.gitEnvironment()) catch return error.GitFailed;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (!(result.term == .exited and result.term.exited == 0)) return error.GitFailed;
        return;
    }
    return error.NoCommandRunner;
}

fn featherCmd(ctx: *anyopaque, alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (argv) |arg| {
        if (hostPowerArg(arg)) return error.Refused;
    }
    // Only tests install a shell (TestServer's no-op), so HTTP update tests do
    // not spawn git, apt, or pip. The daemon runs `daemonFeatherRun`.
    if (app.update_ctx.shell) |sh| {
        const shell_ctx = app.update_ctx.shell_ctx orelse return error.NoCommandRunner;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        for (argv, 0..) |arg, i| {
            if (i != 0) try buf.append(alloc, ' ');
            try buf.appendSlice(alloc, arg);
        }
        try sh(shell_ctx, alloc, buf.items);
        return;
    }
    try daemonFeatherRun(app, alloc, argv);
}

fn featherKlippySend(ctx: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.klippy_ctx.isConnected()) return;
    app.klippy_ctx.postMethod(method, params, alloc) catch {};
}

/// Pending Klipper remote-method calls; further calls are dropped with a warning.
const remote_call_queue_len = 16;
/// Bound active remote calls independently of the pending reader queue.
const max_concurrent_remote_calls = 16;

/// Remote methods registered with Klippy: Feather's, plus the component
/// methods Moonraker registers (power, WLED, Spoolman, MQTT and notifiers).
const klippy_remote_methods = feather_updates_component.remote_methods ++ [_][]const u8{
    "set_device_power",
    "set_wled_state",
    "set_wled",
    "spoolman_set_active_spool",
    "publish_mqtt_topic",
    "notify",
};

/// Klippy `RemoteHandler`, run on the Klippy reader under Core. Queues the
/// call for `remoteWorker`.
fn onKlippyRemoteMethod(ctx: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (try app.extensions_ctx.forwardRemote(method, params, alloc)) return;
    const io = app.klippy_ctx.io orelse return;
    const req = (try remoteMethodRequest(app.alloc, method, params)) orelse return;
    const queued = app.remote_calls.put(io, &.{req}, 0) catch 0;
    if (queued == 0) {
        app.alloc.free(req);
        std.debug.print("phobos: warning: Klipper remote method {s} dropped: queue full\n", .{method});
    }
}

fn onKlippyState(ctx: *anyopaque, _: std.Io, state: klippy_connection_component.State) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    switch (state) {
        .ready => app.job_queue_ctx.onKlippyReady(),
        .shutdown, .disconnected, .@"error" => app.job_queue_ctx.onKlippyShutdown(),
        .startup => {},
    }
}

/// The JSON-RPC request for Klipper remote method `method`, gpa-owned, or
/// null for an unknown method or a `set_device_power` state Moonraker ignores.
/// `set_device_power` maps to `machine.device_power.post_device` and
/// `publish_mqtt_topic` to `server.mqtt.publish_mqtt_topic`; the others,
/// Feather's included, keep their names and kwargs. `force` is not supported.
fn remoteMethodRequest(alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) error{OutOfMemory}!?[]u8 {
    const kwargs: std.json.Value = if (params == .object) params else .{ .object = .empty };
    if (std.mem.eql(u8, method, "set_device_power")) {
        const action = devicePowerAction(kwargs.object.get("state") orelse .null) orelse return null;
        const device = kwargs.object.get("device") orelse return null;
        if (device != .string) return null;
        return try std.json.Stringify.valueAlloc(alloc, .{
            .jsonrpc = "2.0",
            .method = "machine.device_power.post_device",
            .params = .{ .device = device.string, .action = action },
            .id = 0,
        }, .{});
    }
    const target: []const u8 = if (std.mem.eql(u8, method, "publish_mqtt_topic"))
        "server.mqtt.publish_mqtt_topic"
    else for (klippy_remote_methods) |name| {
        if (std.mem.eql(u8, method, name)) break name;
    } else return null;
    return try std.json.Stringify.valueAlloc(alloc, .{ .jsonrpc = "2.0", .method = target, .params = kwargs, .id = 0 }, .{});
}

fn featherMethod(method: []const u8) bool {
    for (feather_updates_component.remote_methods) |name| {
        if (std.mem.eql(u8, method, name)) return true;
    }
    return false;
}

/// power.py `set_device_power` state rules: a bool, or a case-insensitive
/// "on", "off", "toggle", "true" or "false". Anything else is ignored.
fn devicePowerAction(state: std.json.Value) ?[]const u8 {
    switch (state) {
        .bool => |b| return if (b) "on" else "off",
        .string => |s| {
            inline for (.{ .{ "on", "on" }, .{ "true", "on" }, .{ "off", "off" }, .{ "false", "off" }, .{ "toggle", "toggle" } }) |pair| {
                if (std.ascii.eqlIgnoreCase(s, pair[0])) return pair[1];
            }
            return null;
        },
        else => return null,
    }
}

/// Run bounded independent calls; cancel and join every child on exit.
fn remoteWorker(app: *App, io: std.Io) void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var permits: std.Io.Semaphore = .{ .permits = max_concurrent_remote_calls };
    while (true) {
        permits.wait(io) catch return;
        const req = app.remote_calls.getOne(io) catch {
            permits.post(io);
            return;
        };
        group.concurrent(io, runRemoteCallBounded, .{ app, io, req, &permits }) catch |err| {
            app.alloc.free(req);
            permits.post(io);
            std.debug.print("phobos: warning: Klipper remote method dropped: {}\n", .{err});
        };
    }
}

fn runRemoteCallBounded(app: *App, io: std.Io, req: []u8, permits: *std.Io.Semaphore) void {
    defer permits.post(io);
    runRemoteCall(app, io, req);
}

/// Run one queued request and free it. Feather commands run outside Core;
/// the dispatcher takes Core per handler. Moonraker
/// logs a failed remote method; Klipper gets no reply.
fn runRemoteCall(app: *App, _: std.Io, req: []u8) void {
    defer app.alloc.free(req);
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // `remoteMethodRequest` built `req`, so its shape is known.
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, req, .{}) catch return;
    const method = root.object.get("method").?.string;
    if (featherMethod(method)) {
        feather_updates_component.onKlippyMethod(&app.feather, app.alloc, method, root.object.get("params").?) catch |err|
            std.debug.print("phobos: warning: Klipper remote method {s} failed: {}\n", .{ method, err });
        return;
    }
    const out = app.dispatcher.handleParsedRoot(.{ .transport = .INTERNAL }, root, a) catch return;
    if (std.mem.indexOf(u8, out, "\"error\"") != null) std.debug.print("phobos: warning: Klipper remote method failed: {s}\n", .{out});
}

const Registry = registry.Registry;
const Dispatcher = jsonrpc.Dispatcher;
const Connections = connections.Connections;
const NotifyBus = notify.NotifyBus;
const ServerInfo = methods.ServerInfo;
const DbCtx = db_component.DbCtx;
const HistoryCtx = history_component.HistoryCtx;
const JobQueueCtx = job_queue_component.JobQueueCtx;
const JobStateCtx = job_state_component.JobStateCtx;
const AnnouncementsCtx = announcements_component.AnnouncementsCtx;
const DataStoreCtx = data_store_component.DataStoreCtx;
const ServerMiscCtx = server_misc_component.ServerMiscCtx;
const NotifierCtx = notifier_component.NotifierCtx;
const WebcamCtx = webcam_component.WebcamCtx;
const SensorCtx = sensor_component.SensorCtx;
const AuthCtx = authorization_component.AuthCtx;
const SpoolmanCtx = spoolman_component.SpoolmanCtx;
const MqttCtx = mqtt_component.MqttCtx;
const ExtensionsCtx = extensions_component.ExtensionsCtx;
const AnalysisCtx = analysis_component.AnalysisCtx;
const FileCtx = file_manager_component.FileCtx;
const FileRoot = file_manager_component.Root;
const MachineCtx = machine_component.MachineCtx;
const UpdateCtx = update_manager_component.UpdateCtx;
const UpdateSource = update_manager_component.Source;
const PowerCtx = power_component.PowerCtx;
const ButtonCtx = button_component.ButtonCtx;
const WledCtx = wled_component.WledCtx;
const Td1Ctx = td1_component.Td1Ctx;
const PrinterCtx = printer_component.PrinterCtx;
const KlippyConnectionCtx = klippy_connection_component.KlippyCtx;
const OctoPrintCtx = octoprint_component.OctoPrintCtx;
const ZeroconfCtx = zeroconf_component.ZeroconfCtx;

/// Replace an owned path with its canonical target. Missing paths are unchanged.
fn canonicalPath(alloc: std.mem.Allocator, aio: std.Io, path: []u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(aio, path, &buf) catch return path;
    if (std.mem.eql(u8, buf[0..n], path)) return path;
    const resolved = try alloc.dupe(u8, buf[0..n]);
    alloc.free(path);
    return resolved;
}

/// Coerce a config i64 to a smaller int, falling back to `default` when it is
/// out of range — so a typo'd/oversized numeric config value can't panic the
/// `@intCast`. (getInt returns i64; e.g. `port: 70000` parses but won't fit u16.)
fn clampInt(comptime T: type, raw: i64, default: T) T {
    return std.math.cast(T, raw) orelse default;
}

/// SQLite is Moonraker database-compatible; file uses atomic-rename JSON.
pub const StoreBackend = enum { sqlite, file };

/// Owns the concrete store backend behind the DataStore vtable, so App can hold
/// either without a comptime-fixed type. Dispatches dataStore()/deinit.
const StoreHolder = union(StoreBackend) {
    sqlite: *@import("store/sqlite_store.zig").SqliteStore,
    file: *@import("store/file_store.zig").FileStore,

    fn dataStore(self: StoreHolder) ds.DataStore {
        return switch (self) {
            inline else => |s| s.dataStore(),
        };
    }
    fn deinit(self: StoreHolder, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |s| {
                s.deinit();
                alloc.destroy(s);
            },
        }
    }
};

/// The fully-assembled server application. All fields are heap-allocated and
/// owned by this struct; call `deinit` to release them.
pub const App = struct {
    alloc: std.mem.Allocator,

    core: *Core,
    dispatcher: *Dispatcher,
    reg: *Registry,
    info: *ServerInfo,
    conns: *Connections,
    bus: *NotifyBus,
    db_ctx: *DbCtx,
    history_ctx: *HistoryCtx,
    job_queue_ctx: *JobQueueCtx,
    job_state_ctx: *JobStateCtx,
    announcements_ctx: *AnnouncementsCtx,
    data_store_ctx: *DataStoreCtx,
    server_misc_ctx: *ServerMiscCtx,
    notifier_ctx: *NotifierCtx,
    webcam_ctx: *WebcamCtx,
    sensor_ctx: *SensorCtx,
    /// Routes inbound MQTT messages to the sensor component under the Core lock.
    /// Stable storage so MqttCtx can hold a pointer to it.
    sensor_mqtt_bridge: SensorMqttBridge = undefined,
    auth_ctx: *AuthCtx,
    spoolman_ctx: *SpoolmanCtx,
    mqtt_ctx: *MqttCtx,
    extensions_ctx: *ExtensionsCtx,
    analysis_ctx: *AnalysisCtx,
    file_ctx: *FileCtx,
    machine_ctx: *MachineCtx,
    update_ctx: *UpdateCtx,
    power_ctx: *PowerCtx,
    button_ctx: *ButtonCtx,
    wled_ctx: *WledCtx,
    td1_ctx: *Td1Ctx,
    printer_ctx: *PrinterCtx,
    klippy_ctx: *KlippyConnectionCtx,
    octoprint_ctx: *OctoPrintCtx,
    zeroconf_ctx: *ZeroconfCtx,
    /// Absolute datadir whose subfolders back the file_manager roots. Owned and
    /// freed in deinit. The root paths in `file_roots` point into the joined
    /// strings owned alongside it.
    datadir: []u8,
    /// `datadir` is the per-instance /tmp fallback; deinit deletes it.
    temp_datadir: bool,
    /// Moonraker `.moonraker.uuid` (32 hex chars). Owned when `instance_uuid_owned`.
    instance_uuid: []u8 = &.{},
    instance_uuid_owned: bool = false,
    file_roots: []FileRoot,
    /// Owns the active DataStore backend (SQLite or atomic-rename file).
    db_store: StoreHolder,
    /// Parsed configuration. Null when no file was loaded; owned until deinit.
    cfg: ?*config_helper.ConfigParser = null,
    config_path_owned: ?[]u8 = null,
    /// Allowed CORS origins from `[authorization] cors_domains`. Each slice + the
    /// outer array are gpa-owned; freed in deinit. Passed to the HTTP server.
    cors_domains: [][]const u8 = &.{},
    /// `[server] use_xheaders`, Moonraker default true. Copied onto the HTTP
    /// server in `httpServer`.
    use_xheaders: bool = true,
    /// `[server] max_websocket_connections`, Moonraker default 50.
    max_websocket_connections: usize = http_transport.default_max_websocket_connections,
    /// Optional PanelDue serial device and protocol state.
    paneldue: paneldue_component.PanelDue = .{},
    /// Forge-X Feather update adapter. Enabled when `[feather_updates]` exists.
    feather: feather_updates_component.FeatherCtx = .{},
    /// Klipper `call_remote_method` calls as gpa-owned JSON-RPC request
    /// strings. The Klippy reader enqueues without blocking; `remoteWorker`
    /// runs them so git, device and broker I/O never stalls the status
    /// drain. Bound in `httpServer`.
    remote_calls: std.Io.Queue([]u8) = .init(&.{}),
    remote_call_buf: [remote_call_queue_len][]u8 = undefined,
    remote_worker: ?std.Io.Future(void) = null,
    /// Records `git -C <repo>` argv in tests. Production leaves this null and
    /// `daemonFeatherRun` spawns git only when update io is set.
    git_spawn: ?GitSpawnFn = null,
    git_spawn_ctx: ?*anyopaque = null,
    /// Owns `update_ctx.sources` once `sourcesFromConfig` has replaced the defaults.
    update_sources_arena: ?std.heap.ArenaAllocator = null,
    /// True when `klippy_ctx.uds_path` was duped from config and must be freed.
    klippy_uds_owned: bool = false,

    /// App with an in-memory SQLite database (tests, --dump-api). `data_path`
    /// is as for `initWithStore`.
    pub fn init(alloc: std.mem.Allocator, aio: std.Io, data_path: ?[]const u8) !App {
        return initWithStore(alloc, .sqlite, aio, ":memory:", data_path);
    }

    /// Assemble the App with an explicit DataStore backend. `data_path` is
    /// the file_manager datadir (Moonraker's `-d`); when null, a per-instance
    /// `/tmp/phobos-data-<addr>` is used and `deinit` deletes it. `db_path`
    /// defaults to `<datadir>/database/moonraker-sql.db` (sqlite) or
    /// `<datadir>/database` (file). Never keep real data under /tmp, which is
    /// tmpfs on embedded targets.
    pub fn initWithStore(alloc: std.mem.Allocator, db_backend: StoreBackend, aio: std.Io, db_path: ?[]const u8, data_path: ?[]const u8) !App {
        // Validate an explicitly configured datadir up front (before any
        // allocation) so a rejection doesn't leak partially-built state. A
        // relative `-d` would resolve against an unpredictable cwd.
        if (data_path) |dp| {
            if (!std.fs.path.isAbsolute(dp)) return error.InvalidDataPath;
        }
        const core = try alloc.create(Core);
        errdefer alloc.destroy(core);
        core.* = Core.init();

        const dispatcher = try alloc.create(Dispatcher);
        errdefer alloc.destroy(dispatcher);
        dispatcher.* = Dispatcher.init(alloc);
        errdefer dispatcher.deinit();

        const reg = try alloc.create(Registry);
        errdefer alloc.destroy(reg);
        reg.* = Registry.init(alloc, dispatcher);
        errdefer reg.deinit();

        const info = try alloc.create(ServerInfo);
        errdefer alloc.destroy(info);
        info.* = .{};

        const conns = try alloc.create(Connections);
        errdefer alloc.destroy(conns);
        conns.* = Connections.init(alloc, core);
        errdefer conns.deinit(aio);

        const bus = try alloc.create(NotifyBus);
        errdefer alloc.destroy(bus);
        bus.* = NotifyBus.init(core, conns);

        var dd_buf: [64]u8 = undefined;
        const datadir = if (data_path) |dp| dd: {
            // Configured datadir (Moonraker's `-d`, validated absolute above):
            // create it and any missing parents fail-fast so a bad/unwritable
            // path is reported at startup, not at request time.
            var data_dir = try std.Io.Dir.cwd().createDirPathOpen(aio, dp, .{});
            data_dir.close(aio);
            break :dd try alloc.dupe(u8, dp);
        } else dd: {
            const dd_tmp = try std.fmt.bufPrint(&dd_buf, "/tmp/phobos-data-{x}", .{@intFromPtr(core)});
            try std.Io.Dir.cwd().createDirPath(aio, dd_tmp);
            break :dd try alloc.dupe(u8, dd_tmp);
        };
        errdefer alloc.free(datadir);
        // Best-effort: a failed temp cleanup must not mask the init error.
        errdefer if (data_path == null) std.Io.Dir.cwd().deleteTree(aio, datadir) catch {};

        const db_ctx = try alloc.create(DbCtx);
        errdefer alloc.destroy(db_ctx);

        // Build the DataStore behind the selected backend.
        const store_path = if (db_path) |p| try alloc.dupeSentinel(u8, p, 0) else switch (db_backend) {
            .sqlite => try std.fs.path.joinZ(alloc, &.{ datadir, "database", "moonraker-sql.db" }),
            .file => try std.fs.path.joinZ(alloc, &.{ datadir, "database" }),
        };
        defer alloc.free(store_path);
        const db_store: StoreHolder = switch (db_backend) {
            .sqlite => blk: {
                const SqliteStore = @import("store/sqlite_store.zig").SqliteStore;
                const store_ptr = try alloc.create(SqliteStore);
                errdefer alloc.destroy(store_ptr);
                store_ptr.* = try SqliteStore.open(aio, store_path);
                break :blk .{ .sqlite = store_ptr };
            },
            .file => blk: {
                const FileStore = @import("store/file_store.zig").FileStore;
                const store_ptr = try alloc.create(FileStore);
                errdefer alloc.destroy(store_ptr);
                store_ptr.* = FileStore.open(aio, store_path) catch return error.BackendOpenFailed;
                break :blk .{ .file = store_ptr };
            },
        };
        errdefer db_store.deinit(alloc);
        db_ctx.* = .{ .store = db_store.dataStore() };

        // --- History context ---
        const history_ctx = try alloc.create(HistoryCtx);
        errdefer alloc.destroy(history_ctx);
        history_ctx.* = HistoryCtx{
            .clock_io = aio,
            .store = db_ctx.store,
            .bus = bus,
            .io = null,
            .current_job_id = null,
            .job_user = "No User",
            .gpa = alloc,
        };

        // --- Job queue context ---
        const job_queue_ctx = try alloc.create(JobQueueCtx);
        errdefer alloc.destroy(job_queue_ctx);
        job_queue_ctx.* = try JobQueueCtx.init(alloc, aio, db_ctx.store, bus);
        errdefer job_queue_ctx.deinit();

        // --- Job state context ---
        const job_state_ctx = try alloc.create(JobStateCtx);
        errdefer alloc.destroy(job_state_ctx);
        job_state_ctx.* = JobStateCtx.init(alloc);
        errdefer job_state_ctx.deinit();
        // Cross-wire: JobState → History + JobQueue for state-change events.
        job_state_ctx.history = history_ctx;
        job_state_ctx.job_queue = job_queue_ctx;

        // Mark any jobs left "in_progress" from a previous run as interrupted.
        history_ctx.markInterruptedJobs() catch |err|
            std.debug.print("phobos: warning: failed to mark interrupted jobs on startup: {} — stale 'in_progress' jobs may remain\n", .{err});

        // --- Announcements context ---
        const announcements_ctx = try alloc.create(AnnouncementsCtx);
        errdefer alloc.destroy(announcements_ctx);
        announcements_ctx.* = try AnnouncementsCtx.init(alloc, aio, db_ctx.store, bus);
        announcements_ctx.data_path = datadir;
        errdefer announcements_ctx.deinit();

        // --- Data store context (gcode_store + temperature_store) ---
        const data_store_ctx = try alloc.create(DataStoreCtx);
        errdefer alloc.destroy(data_store_ctx);
        data_store_ctx.* = try DataStoreCtx.init(alloc);
        errdefer data_store_ctx.deinit();

        // --- Server misc context (restart + logs/rollover) ---
        const server_misc_ctx = try alloc.create(ServerMiscCtx);
        errdefer alloc.destroy(server_misc_ctx);
        server_misc_ctx.* = .{};

        // --- Notifier context (notifiers/list) ---
        const notifier_ctx = try alloc.create(NotifierCtx);
        errdefer alloc.destroy(notifier_ctx);
        notifier_ctx.* = .{};

        // --- Webcam context (webcams CRUD) ---
        const webcam_ctx = try alloc.create(WebcamCtx);
        errdefer alloc.destroy(webcam_ctx);
        webcam_ctx.* = try WebcamCtx.init(alloc, aio, db_ctx.store, bus);
        errdefer webcam_ctx.deinit();

        // --- Sensor context (sensors list/info/measurements) ---
        const sensor_ctx = try alloc.create(SensorCtx);
        errdefer alloc.destroy(sensor_ctx);
        sensor_ctx.* = SensorCtx.init(alloc, bus);
        errdefer sensor_ctx.deinit();
        sensor_ctx.history_ctx = history_ctx; // report measurements to history aux fields

        // --- Authorization context (access.* + auth hook) ---
        const auth_ctx = try alloc.create(AuthCtx);
        errdefer alloc.destroy(auth_ctx);
        // Issuer mirrors Moonraker's "http://<hostname>:<port>". The default
        // host/port keep tokens self-consistent within this instance.
        auth_ctx.* = try AuthCtx.init(alloc, aio, db_ctx.store, "http://localhost:7125");
        errdefer auth_ctx.deinit();

        // --- Spoolman context (spool_id persistence + proxy stubs) ---
        // io is not stored here; setIo() is called after the event loop starts
        // (see httpServer). Notifications are suppressed until then.
        // The server URL is set later in setConfig when the config file is parsed.
        const spoolman_ctx = try alloc.create(SpoolmanCtx);
        errdefer alloc.destroy(spoolman_ctx);
        spoolman_ctx.* = try SpoolmanCtx.init(alloc, db_ctx.store, bus);

        // --- MQTT context (no broker; faithful endpoint shapes) ---
        const mqtt_ctx = try alloc.create(MqttCtx);
        errdefer alloc.destroy(mqtt_ctx);
        mqtt_ctx.* = MqttCtx.init(alloc);

        // --- Extension agents ---
        const extensions_ctx = try alloc.create(ExtensionsCtx);
        errdefer alloc.destroy(extensions_ctx);
        extensions_ctx.* = .{ .alloc = alloc, .io = aio, .bus = bus };
        errdefer extensions_ctx.deinit();

        // --- Analysis context (execution requires an injected runner) ---
        const analysis_ctx = try alloc.create(AnalysisCtx);
        errdefer alloc.destroy(analysis_ctx);
        analysis_ctx.* = .{ .data_path = datadir, .io = aio };

        // --- File manager context (server.files.*) ---
        const root_specs = [_]struct { name: []const u8, full: bool }{
            .{ .name = "config", .full = true },
            .{ .name = "logs", .full = false },
            .{ .name = "gcodes", .full = true },
        };
        const file_roots = try alloc.alloc(FileRoot, root_specs.len);
        errdefer alloc.free(file_roots);
        var roots_initialized: usize = 0;
        errdefer for (file_roots[0..roots_initialized]) |r| alloc.free(r.path);
        for (root_specs, 0..) |spec, i| {
            const p = try std.fs.path.join(alloc, &.{ datadir, spec.name });
            errdefer alloc.free(p);
            var root_dir = try std.Io.Dir.cwd().createDirPathOpen(aio, p, .{});
            root_dir.close(aio);
            // Forge-x points printer_data/{config,logs,gcodes} at /opt/config,
            // /data/logFiles, and /data. Moonraker reports the symlink target.
            file_roots[i] = .{ .name = spec.name, .path = try canonicalPath(alloc, aio, p), .full_access = spec.full };
            roots_initialized += 1;
        }

        const file_ctx = try alloc.create(FileCtx);
        errdefer alloc.destroy(file_ctx);
        file_ctx.* = .{ .gpa = alloc, .roots = file_roots, .bus = bus, .job_state = job_state_ctx, .server_info = info, .job_queue = job_queue_ctx };
        analysis_ctx.files = file_ctx;

        // --- Machine context (machine.* + machine.proc_stats) ---
        // io is wired later via httpServer/setIo so /proc & /sys reads work.
        const machine_ctx = try alloc.create(MachineCtx);
        errdefer alloc.destroy(machine_ctx);
        machine_ctx.* = .{
            .clock_io = aio,
            .gpa = alloc,
            .bus = bus,
            .conns = conns,
            .usb_ids = try @import("components/usb_ids.zig").Ctx.init(alloc, aio, datadir, db_ctx.store),
        };
        errdefer machine_ctx.usb_ids.?.deinit();
        webcam_ctx.machine_ctx = machine_ctx;

        // --- Update manager context (machine.update.*) ---
        // The default source set (system + moonraker + klipper git repos) is a
        // static borrow; real git/package state is stubbed. io is wired later via
        // setIo so notifications reach connected WebSocket clients.
        const update_ctx = try alloc.create(UpdateCtx);
        errdefer alloc.destroy(update_ctx);
        update_ctx.* = .{
            .clock_io = aio,
            .gpa = alloc,
            .store = db_ctx.store,
            .sources = &update_manager_component.default_sources,
            .bus = bus,
            // Refuse update operations while a print is active (Moonraker 503).
            .printing_check = JobStateCtx.isActiveErased,
            .printing_ctx = job_state_ctx,
            .restart_service = restartUpdatedService,
            .service_ctx = machine_ctx,
        };

        // --- Power device context (machine.device_power.*) ---
        // Devices come from [power <name>] config sections (none in the bare
        // spine → empty list). HTTP-URL devices send real GET requests and
        // `type: gpio` devices drive the sysfs line (see power.zig); other vendor
        // types remain in-memory.
        const power_ctx = try alloc.create(PowerCtx);
        errdefer alloc.destroy(power_ctx);
        power_ctx.* = PowerCtx.init(alloc, bus);
        // Reject locked_while_printing changes during a print (Moonraker power.py).
        power_ctx.printing_check = JobStateCtx.isActiveErased;
        power_ctx.printing_ctx = job_state_ctx;

        const button_ctx = try alloc.create(ButtonCtx);
        errdefer alloc.destroy(button_ctx);
        button_ctx.* = ButtonCtx.init(alloc, bus);
        errdefer button_ctx.deinit();

        // --- WLED context (machine.wled.*) ---
        // Strips come from [wled <name>] config (none in the bare spine).
        // Address strips use the WLED JSON HTTP API; serial strips write JSON to
        // the character device (see wled.zig).
        const wled_ctx = try alloc.create(WledCtx);
        errdefer alloc.destroy(wled_ctx);
        wled_ctx.* = WledCtx.init(alloc);

        // --- TD-1 context (machine.td1.*) ---
        // Discovery owns persistent per-device readers after I/O is wired.
        const td1_ctx = try alloc.create(Td1Ctx);
        errdefer alloc.destroy(td1_ctx);
        td1_ctx.* = Td1Ctx.init(alloc, aio);

        // --- Printer context (printer.* — Klippy-disconnected stubs) ---
        const printer_ctx = try alloc.create(PrinterCtx);
        errdefer alloc.destroy(printer_ctx);
        printer_ctx.* = .{};

        // --- Klippy connection context (Unix-socket bridge to Klippy) ---
        const klippy_ctx = try alloc.create(KlippyConnectionCtx);
        errdefer alloc.destroy(klippy_ctx);
        klippy_ctx.* = try KlippyConnectionCtx.init(alloc, bus);
        errdefer klippy_ctx.deinit();
        klippy_ctx.server_info = info;
        klippy_ctx.job_state = job_state_ctx;
        klippy_ctx.history = history_ctx;
        extensions_ctx.klippy = klippy_ctx;
        file_ctx.klippy = klippy_ctx;

        // Wire the Klippy connection into the printer context so handlers
        // (print.start, pause, resume, cancel, restart, firmware_restart)
        // can proxy requests through the Unix-domain socket bridge.
        printer_ctx.klippy = klippy_ctx;

        // Wire Klippy dispatch into the job queue so it can start/pause prints.
        job_queue_ctx.setKlippyDispatch(@ptrCast(klippy_ctx), &jobQueueKlippyDispatch);
        // Reject enqueuing a missing gcode file; defer dispatch while printing.
        job_queue_ctx.file_check = FileCtx.gcodeExistsErased;
        job_queue_ctx.file_check_ctx = file_ctx;
        job_queue_ctx.printing_check = JobStateCtx.isActiveErased;
        job_queue_ctx.printing_ctx = job_state_ctx;
        // History jobs report whether their gcode file still exists.
        history_ctx.file_check = FileCtx.gcodeExistsErased;
        history_ctx.file_check_ctx = file_ctx;

        // --- OctoPrint compatibility context (/api/*) ---
        const octoprint_ctx = try alloc.create(OctoPrintCtx);
        errdefer alloc.destroy(octoprint_ctx);
        octoprint_ctx.* = .{};
        octoprint_ctx.server_info = info;
        octoprint_ctx.temp_store = data_store_ctx;
        octoprint_ctx.klippy = klippy_ctx;
        octoprint_ctx.files = file_ctx;
        klippy_ctx.octoprint = octoprint_ctx;
        klippy_ctx.temp_store = data_store_ctx;
        db_ctx.registered_namespaces = &.{ "moonraker", "announcements", "update_manager" };

        // --- Zeroconf/SSDP context (/server/zeroconf/ssdp) ---
        const zeroconf_ctx = try alloc.create(ZeroconfCtx);
        errdefer alloc.destroy(zeroconf_ctx);
        zeroconf_ctx.* = .{};

        var app = App{
            .alloc = alloc,
            .core = core,
            .dispatcher = dispatcher,
            .reg = reg,
            .info = info,
            .conns = conns,
            .bus = bus,
            .db_ctx = db_ctx,
            .history_ctx = history_ctx,
            .job_queue_ctx = job_queue_ctx,
            .job_state_ctx = job_state_ctx,
            .announcements_ctx = announcements_ctx,
            .data_store_ctx = data_store_ctx,
            .server_misc_ctx = server_misc_ctx,
            .notifier_ctx = notifier_ctx,
            .webcam_ctx = webcam_ctx,
            .sensor_ctx = sensor_ctx,
            .auth_ctx = auth_ctx,
            .spoolman_ctx = spoolman_ctx,
            .mqtt_ctx = mqtt_ctx,
            .extensions_ctx = extensions_ctx,
            .analysis_ctx = analysis_ctx,
            .file_ctx = file_ctx,
            .machine_ctx = machine_ctx,
            .update_ctx = update_ctx,
            .power_ctx = power_ctx,
            .button_ctx = button_ctx,
            .wled_ctx = wled_ctx,
            .td1_ctx = td1_ctx,
            .printer_ctx = printer_ctx,
            .klippy_ctx = klippy_ctx,
            .octoprint_ctx = octoprint_ctx,
            .zeroconf_ctx = zeroconf_ctx,
            .datadir = datadir,
            .temp_datadir = data_path == null,
            .file_roots = file_roots,
            .db_store = db_store,
        };

        app.syncRegisteredDirectories();
        try app.registerAll();
        return app;
    }

    /// Copy file-root names into `server.info` `registered_directories`.
    /// Names are stable literals. The fixed array is updated under the same
    /// lock the info handler uses, so a root added during handshake is visible
    /// without reallocating a slice the handler might be reading.
    fn syncRegisteredDirectories(self: *App) void {
        const io = self.file_ctx.io;
        if (io) |i| self.info.state_mutex.lockUncancelable(i);
        defer if (io) |i| self.info.state_mutex.unlock(i);
        const n = @min(self.file_roots.len, self.info.directory_names.len);
        for (self.file_roots[0..n], 0..) |r, i| self.info.directory_names[i] = r.name;
        self.info.directory_count = @intCast(n);
    }

    /// Parse and apply a config file. Parse errors leave configuration unset.
    pub fn setConfig(self: *App, aio: std.Io, config_path: []const u8) !void {
        if (self.cfg != null) return error.ConfigAlreadyLoaded;
        const cfg = parsed: {
            const cfg = try self.alloc.create(config_helper.ConfigParser);
            errdefer self.alloc.destroy(cfg);
            cfg.* = config_helper.ConfigParser.init(self.alloc);
            errdefer cfg.deinit();
            try cfg.parseFile(aio, config_path);
            break :parsed cfg;
        };
        try self.setParsedConfig(aio, config_path, cfg);
    }

    /// Consumes cfg, including on error. It must use self.alloc. A component
    /// error retains its borrowed config until App teardown; discard the App.
    pub fn setParsedConfig(self: *App, aio: std.Io, config_path: []const u8, cfg: *config_helper.ConfigParser) !void {
        var published = false;
        errdefer if (!published) {
            cfg.deinit();
            self.alloc.destroy(cfg);
        };
        if (self.cfg != null) return error.ConfigAlreadyLoaded;
        const queue_gcode_uploads = if (cfg.get("file_manager", "queue_gcode_uploads") != null)
            try cfg.getBoolean("file_manager", "queue_gcode_uploads")
        else
            false;
        const owned_path = try self.alloc.dupe(u8, config_path);
        self.cfg = cfg;
        published = true;
        self.config_path_owned = owned_path;
        self.info.cfg = cfg;
        self.info.config_file_path = owned_path;
        self.ensureInstanceUuid(aio);

        // [server] use_xheaders defaults true. False keeps the socket peer
        // even when X-Forwarded-For / X-Real-Ip are present.
        if (cfg.getBoolean("server", "use_xheaders")) |v| {
            self.use_xheaders = v;
        } else |_| {}
        if (cfg.getInt("server", "max_websocket_connections")) |n| {
            self.max_websocket_connections = clampInt(usize, n, http_transport.default_max_websocket_connections);
        } else |_| {}

        if (cfg.get("server", "klippy_uds_address")) |uds| {
            if (uds.len > 0) {
                if (self.alloc.dupe(u8, uds)) |duped| {
                    if (self.klippy_uds_owned) self.alloc.free(self.klippy_ctx.uds_path);
                    self.klippy_ctx.uds_path = duped;
                    self.klippy_uds_owned = true;
                } else |_| {}
            }
        }

        if (cfg.hasSection("td1")) {
            const baud = std.math.cast(u32, cfg.getInt("td1", "baudrate") catch |err| switch (err) {
                error.NoOption => 115200,
                else => return err,
            }) orelse return error.InvalidConfig;
            _ = try @import("components/serial.zig").Serial.baudToSpeed(baud);
            self.td1_ctx.baud = baud;
        }

        if (cfg.hasSection("paneldue")) {
            try self.paneldue.configure(cfg);
        }

        // Analysis never downloads an executable or installs a process runner.
        self.analysis_ctx.io = aio;
        if (cfg.hasSection("analysis")) try self.applyAnalysisConfig(cfg);

        // [spoolman] requires a server and a positive reporting interval.
        if (cfg.hasSection("spoolman")) {
            const url = cfg.get("spoolman", "server") orelse return error.NoOption;
            try self.spoolman_ctx.setServerUrl(url);
            try self.spoolman_ctx.setSyncRate(if (cfg.get("spoolman", "sync_rate") != null) try cfg.getInt("spoolman", "sync_rate") else spoolman_component.default_sync_rate_seconds);
        }

        // System provider for machine.services.* ([machine] provider): selects
        // systemctl vs supervisorctl vs in-memory. Default stays systemd_dbus.
        if (cfg.get("machine", "provider")) |p| {
            self.machine_ctx.setProvider(p) catch |err| {
                std.debug.print("phobos: warning: failed to set machine provider '{s}': {}\n", .{ p, err });
            };
        }
        if (cfg.get("machine", "supervisord_config_path")) |path| try self.machine_ctx.setSupervisordConfigPath(path);
        // Forge-X `[machine] script_path` is the directory SimpleProvider runs.
        // reboot and shutdown stay no-ops; this path is only a service script.
        if (cfg.get("machine", "script_path")) |p| {
            self.machine_ctx.setScriptPath(p) catch |err| {
                std.debug.print("phobos: warning: failed to set machine script_path: {}\n", .{err});
            };
        }
        if (cfg.getFloat("machine", "script_timeout")) |t| {
            if (t > 0) self.machine_ctx.script_timeout_s = t;
        } else |_| {}

        // CORS allow-list ([authorization] cors_domains): a whitespace/newline
        // separated list of origins (`*`, `*.dom`, or exact). Enables a
        // cross-origin web UI to talk to phobos.
        if (cfg.get("authorization", "cors_domains")) |raw| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
            while (it.next()) |dom| {
                const d = self.alloc.dupe(u8, dom) catch continue;
                list.append(self.alloc, d) catch self.alloc.free(d);
            }
            self.cors_domains = list.toOwnedSlice(self.alloc) catch &.{};
        }

        // Wire [authorization] security options into the auth context. Without
        // this an operator who sets force_logins / enable_api_key /
        // login_timeout in the config has those values silently ignored — a
        // login requirement that is never enforced, or an API key that stays
        // enabled after being disabled, is a security misconfiguration.
        if (cfg.hasSection("authorization")) {
            if (cfg.getBoolean("authorization", "force_logins")) |v| {
                self.auth_ctx.force_logins = v;
            } else |_| {}
            if (cfg.getBoolean("authorization", "enable_api_key")) |v| {
                self.auth_ctx.enable_api_key = v;
            } else |_| {}
            // login_timeout is expressed in days (Moonraker default 90); ignore
            // non-positive or unparseable values rather than minting tokens that
            // expire immediately.
            if (cfg.getInt("authorization", "login_timeout")) |days| {
                if (days > 0) self.auth_ctx.login_timeout_days = days;
            } else |_| {}
            if (cfg.get("authorization", "trusted_clients")) |raw| {
                self.auth_ctx.setTrustedClients(raw) catch |err| {
                    std.debug.print("phobos: warning: trusted_clients not applied: {}\n", .{err});
                };
            }
        }

        // [update_manager] and [update_manager <name>] clients. System is
        // omitted when enable_system_updates is false. Paths are recorded
        // only; status does not fetch unless a later refresh asks it to.
        var sources_arena = std.heap.ArenaAllocator.init(self.alloc);
        if (update_manager_component.sourcesFromConfig(sources_arena.allocator(), cfg)) |srcs| {
            if (self.update_sources_arena) |*old| old.deinit();
            self.update_sources_arena = sources_arena;
            self.update_ctx.sources = srcs;
        } else |err| {
            sources_arena.deinit();
            std.debug.print("phobos: warning: update sources not applied: {}\n", .{err});
        }

        self.bindFeather();
        if (cfg.hasSection("announcements")) {
            if (cfg.getBoolean("announcements", "dev_mode")) |v| {
                self.announcements_ctx.dev_mode = v;
            } else |_| {}
            if (cfg.getBoolean("announcements", "enable_moonlight")) |v| {
                self.announcements_ctx.moonlight_enabled = v;
            } else |_| {}
            if (cfg.get("announcements", "subscriptions")) |raw| {
                var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
                while (it.next()) |name| {
                    self.announcements_ctx.addSubscription(name) catch |err| {
                        std.debug.print("phobos: warning: announcement subscription '{s}' not added: {}\n", .{ name, err });
                    };
                }
            }
        }

        if (cfg.hasSection("data_store")) {
            if (cfg.getInt("data_store", "gcode_store_size")) |n| {
                if (n > 0) self.data_store_ctx.setGcodeStoreSize(clampInt(usize, n, 0)) catch |err| {
                    std.debug.print("phobos: warning: gcode_store_size not applied: {}\n", .{err});
                };
            } else |_| {}
            if (cfg.getInt("data_store", "temperature_store_size")) |n| {
                if (n > 0) self.data_store_ctx.setTemperatureStoreSize(clampInt(usize, n, 0)) catch |err| {
                    std.debug.print("phobos: warning: temperature_store_size not applied: {}\n", .{err});
                };
            } else |_| {}
        }

        if (cfg.hasSection("update_manager")) {
            if (cfg.getBoolean("update_manager", "enable_auto_refresh")) |v| {
                self.update_ctx.auto_refresh = v;
            } else |_| {}
            if (cfg.getInt("update_manager", "refresh_interval")) |hours| {
                if (hours > 0) self.update_ctx.refresh_interval_hours = hours;
            } else |_| {}
            if (cfg.get("update_manager", "refresh_window")) |raw| {
                var nums: [2]i64 = .{ 0, 5 };
                var n: usize = 0;
                var it = std.mem.tokenizeAny(u8, raw, "-,\n\t ");
                while (it.next()) |tok| {
                    if (n >= 2) break;
                    nums[n] = std.fmt.parseInt(i64, tok, 10) catch break;
                    n += 1;
                }
                if (n == 2 and nums[0] != nums[1] and nums[0] >= 0 and nums[0] <= 23 and nums[1] >= 0 and nums[1] <= 23) {
                    self.update_ctx.refresh_window_start = nums[0];
                    self.update_ctx.refresh_window_end = nums[1];
                }
            }
        }

        self.file_ctx.queue_gcode_uploads = queue_gcode_uploads;

        if (cfg.get("file_manager", "file_system_observer")) |raw| {
            self.file_ctx.observer_kind = if (std.ascii.eqlIgnoreCase(raw, "inotify")) .inotify else .none;
            if (!std.ascii.eqlIgnoreCase(raw, "none") and self.file_ctx.observer_kind == .none)
                std.debug.print("phobos: warning: invalid file_system_observer '{s}', using none\n", .{raw});
        }

        if (cfg.get("file_manager", "excludes")) |raw| {
            self.file_ctx.setExcludes(raw) catch |err| {
                std.debug.print("phobos: warning: file excludes not applied: {}\n", .{err});
            };
        }

        if (cfg.get("klippy_apis", "hidden_objects")) |raw| {
            self.printer_ctx.setHiddenObjects(self.alloc, raw) catch |err| {
                std.debug.print("phobos: warning: hidden_objects not applied: {}\n", .{err});
            };
        }

        if (cfg.hasSection("octoprint_compat")) {
            if (cfg.getBoolean("octoprint_compat", "enable_ufp")) |v| {
                self.octoprint_ctx.enable_ufp = v;
            } else |_| {}
            if (cfg.getBoolean("octoprint_compat", "flip_h")) |v| {
                self.octoprint_ctx.flip_h = v;
            } else |_| {}
            if (cfg.getBoolean("octoprint_compat", "flip_v")) |v| {
                self.octoprint_ctx.flip_v = v;
            } else |_| {}
            if (cfg.getBoolean("octoprint_compat", "rotate_90")) |v| {
                self.octoprint_ctx.rotate_90 = v;
            } else |_| {}
            if (cfg.getBoolean("octoprint_compat", "webcam_enabled")) |v| {
                self.octoprint_ctx.webcam_enabled = v;
            } else |_| {}
            if (cfg.get("octoprint_compat", "stream_url")) |url| {
                if (self.alloc.dupe(u8, url)) |duped| {
                    if (self.octoprint_ctx.stream_url_owned) self.alloc.free(self.octoprint_ctx.stream_url);
                    self.octoprint_ctx.stream_url = duped;
                    self.octoprint_ctx.stream_url_owned = true;
                } else |_| {}
            }
        }

        if (cfg.hasSection("feather_updates")) {
            self.klippy_ctx.remote_methods = &klippy_remote_methods;
            self.feather.enabled = true;
            if (cfg.get("feather_updates", "update_key")) |key| {
                if (key.len > 0 and key.len <= 64) self.feather.update_key = key;
            }
            self.info.extra_components = &feather_component_name;
        }

        // Wire job_queue transition gcode/delay + behaviour flags from the
        // [job_queue] section.
        if (cfg.hasSection("job_queue")) {
            const tg = cfg.get("job_queue", "job_transition_gcode");
            const td: f64 = cfg.getFloat("job_queue", "job_transition_delay") catch 0.0;
            self.job_queue_ctx.setTransitionConfig(tg, td);
            // Moonraker defaults: both false.
            const automatic = cfg.getBoolean("job_queue", "automatic_transition") catch false;
            self.job_queue_ctx.setAutomaticTransition(automatic);
            self.job_queue_ctx.load_on_startup = if (cfg.get("job_queue", "load_on_startup") != null)
                try cfg.getBoolean("job_queue", "load_on_startup")
            else
                false;
        }

        // [mqtt] (mqtt.py MQTTClient). Moonraker fails the component on a bad
        // option; phobos warns and leaves MQTT unconfigured.
        if (cfg.hasSection("mqtt")) self.applyMqttConfig(aio, cfg) catch |err|
            std.debug.print("phobos: warning: invalid [mqtt] config: {}, MQTT disabled\n", .{err});

        try self.power_ctx.configure(cfg);
        try self.button_ctx.configure(cfg);

        // Wire WLED strips, webcams, and notifiers from prefixed sections.
        self.notifier_ctx.deinit(self.alloc);
        if (cfg.sectionNames(self.alloc)) |names| {
            defer self.alloc.free(names);
            for (names) |sect| {
                if (std.mem.startsWith(u8, sect, "notifier ")) {
                    const nname = sect["notifier ".len..];
                    if (nname.len == 0) continue;
                    // `url` and `events` are required (notifier.py NotifierInstance).
                    const url = cfg.get(sect, "url");
                    const events = cfg.get(sect, "events");
                    if (url == null or events == null) {
                        std.debug.print("phobos: warning: [{s}] needs url and events, notifier skipped\n", .{sect});
                        continue;
                    }
                    self.notifier_ctx.addNotifier(self.alloc, .{
                        .name = nname,
                        .url = url.?,
                        .title = cfg.get(sect, "title"),
                        .body = cfg.get(sect, "body"),
                        .body_format = cfg.get(sect, "body_format"),
                        .events = events.?,
                    }) catch |err| {
                        std.debug.print("phobos: warning: failed to add notifier '{s}': {}\n", .{ nname, err });
                    };
                    continue;
                }
                if (std.mem.startsWith(u8, sect, "webcam ")) {
                    const cam_name = sect["webcam ".len..];
                    if (cam_name.len == 0) continue;
                    const stream = cfg.get(sect, "stream_url") orelse continue;
                    self.webcam_ctx.addFromConfig(.{
                        .name = cam_name,
                        .enabled = cfg.getBoolean(sect, "enabled") catch true,
                        .icon = cfg.get(sect, "icon") orelse "mdiWebcam",
                        .aspect_ratio = cfg.get(sect, "aspect_ratio") orelse "4:3",
                        .target_fps = cfg.getInt(sect, "target_fps") catch 15,
                        .target_fps_idle = cfg.getInt(sect, "target_fps_idle") catch 5,
                        .location = cfg.get(sect, "location") orelse "printer",
                        .service = cfg.get(sect, "service") orelse "mjpegstreamer",
                        .stream_url = stream,
                        .snapshot_url = cfg.get(sect, "snapshot_url") orelse "",
                        .flip_horizontal = cfg.getBoolean(sect, "flip_horizontal") catch false,
                        .flip_vertical = cfg.getBoolean(sect, "flip_vertical") catch false,
                        .rotation = cfg.getInt(sect, "rotation") catch 0,
                    }) catch |err| {
                        std.debug.print("phobos: warning: failed to add webcam '{s}': {}\n", .{ cam_name, err });
                    };
                    continue;
                }
                if (!std.mem.startsWith(u8, sect, "wled ")) continue;
                const strip_name = sect["wled ".len..];
                if (strip_name.len == 0) continue;
                // Moonraker wled.py: `type` http (address/port/protocol) or
                // serial (serial/baud); other types fail the strip.
                const strip_type = cfg.get(sect, "type") orelse "http";
                var url_buf: [512]u8 = undefined;
                const transport: wled_component.Transport = if (std.ascii.eqlIgnoreCase(strip_type, "http")) http: {
                    const address = cfg.get(sect, "address") orelse {
                        std.debug.print("phobos: warning: wled strip '{s}': address required, strip not added\n", .{strip_name});
                        continue;
                    };
                    const port: u16 = clampInt(u16, cfg.getInt(sect, "port") catch 80, 80);
                    const protocol = cfg.get(sect, "protocol") orelse "http";
                    break :http .{ .http = std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}/json", .{ protocol, address, port }) catch {
                        std.debug.print("phobos: warning: wled strip '{s}': address too long, strip not added\n", .{strip_name});
                        continue;
                    } };
                } else if (std.ascii.eqlIgnoreCase(strip_type, "serial")) serial: {
                    const path = cfg.get(sect, "serial") orelse {
                        std.debug.print("phobos: warning: wled strip '{s}': serial required, strip not added\n", .{strip_name});
                        continue;
                    };
                    const baud = std.math.cast(u32, cfg.getInt(sect, "baud") catch wled_component.default_baud) orelse {
                        std.debug.print("phobos: warning: wled strip '{s}': invalid baud, strip not added\n", .{strip_name});
                        continue;
                    };
                    break :serial .{ .serial = .{ .path = path, .baud = baud } };
                } else {
                    std.debug.print("phobos: warning: wled strip '{s}': unsupported type '{s}', strip not added\n", .{ strip_name, strip_type });
                    continue;
                };
                const timeout_ms = std.math.lossyCast(i64, (cfg.getFloat(sect, "timeout") catch 2.0) * std.time.ms_per_s);
                const chain_count = std.math.cast(usize, cfg.getInt(sect, "chain_count") catch 1) orelse 0;
                if (timeout_ms <= 0 or chain_count == 0) {
                    std.debug.print("phobos: warning: wled strip '{s}': chain_count and timeout must be positive, strip not added\n", .{strip_name});
                    continue;
                }
                self.wled_ctx.addStrip(.{
                    .name = strip_name,
                    .chain_count = chain_count,
                    .initial_preset = cfg.getInt(sect, "initial_preset") catch -1,
                    .initial_color = .{
                        cfg.getFloat(sect, "initial_red") catch 0.5,
                        cfg.getFloat(sect, "initial_green") catch 0.5,
                        cfg.getFloat(sect, "initial_blue") catch 0.5,
                        cfg.getFloat(sect, "initial_white") catch 0.5,
                    },
                    .transport = transport,
                    .timeout = .fromMilliseconds(timeout_ms),
                }) catch |err| {
                    std.debug.print("phobos: warning: failed to add wled strip '{s}': {}\n", .{ strip_name, err });
                };
            }
        } else |_| {}

        // Register history auxiliary fields from [history_field <name>] sections.
        if (cfg.sectionNames(self.alloc)) |names| {
            defer self.alloc.free(names);
            for (names) |sect| {
                if (std.mem.startsWith(u8, sect, "history_field ")) {
                    const field_name = sect["history_field ".len..];
                    if (field_name.len == 0) continue;
                    const provider = cfg.get(sect, "provider") orelse continue;
                    const parameter = cfg.get(sect, "parameter") orelse continue;
                    const units = cfg.get(sect, "units");
                    const strategy = history_component.AuxStrategy.fromString(cfg.get(sect, "strategy") orelse "basic");
                    self.history_ctx.registerAuxField(provider, field_name, parameter, units, strategy) catch |err| {
                        std.debug.print("phobos: warning: failed to add history_field '{s}': {}\n", .{ field_name, err });
                    };
                } else if (std.mem.startsWith(u8, sect, "sensor ")) {
                    // [sensor <name>]: register the sensor + its MQTT topic and
                    // optional state_response_template. Subscribed on MQTT connect.
                    const sname = sect["sensor ".len..];
                    if (sname.len == 0) continue;
                    const store_size = std.math.cast(usize, cfg.getInt(sect, "sensor_store_size") catch sensor_component.default_store_size) orelse {
                        std.debug.print("phobos: warning: sensor '{s}' not added: negative sensor_store_size\n", .{sname});
                        continue;
                    };
                    _ = self.sensor_ctx.addSensor(sname, .{
                        .type = cfg.get(sect, "type") orelse "mqtt",
                        .name = cfg.get(sect, "name"),
                        .store_size = store_size,
                        .state_topic = cfg.get(sect, "state_topic"),
                        .state_response_template = cfg.get(sect, "state_response_template"),
                        .config = cfg,
                        .section = sect,
                    }) catch |err| {
                        std.debug.print("phobos: warning: failed to add sensor '{s}': {}\n", .{ sname, err });
                        continue;
                    };
                }
            }
        } else |_| {}
    }

    /// Set a mock command-runner on the machine component so tests don't
    /// exec real systemctl/reboot/shutdown commands on the host.
    pub fn setMachineRunCmdFn(self: *App, run_cmd_fn: MachineCtx.RunCmdFn, ctx: *anyopaque) void {
        self.machine_ctx.setRunCmdFn(run_cmd_fn, ctx);
    }

    /// Stop and join workers before freeing their dependencies.
    pub fn deinit(self: *App, io: std.Io) void {
        self.power_ctx.stopTimerWorker();
        self.button_ctx.stop();
        self.paneldue.deinit();
        self.file_ctx.stopObserver();
        self.remote_calls.close(io);
        if (self.remote_worker) |*w| {
            // Cancel and join the worker's calls before component teardown.
            w.cancel(io);
        }
        while (self.remote_calls.getOneUncancelable(io)) |req| self.alloc.free(req) else |_| {}
        self.update_ctx.deinit();
        self.data_store_ctx.stopSampler();
        self.sensor_ctx.stopSampler();
        self.klippy_ctx.stop(io);
        self.job_queue_ctx.cancelDelayTimer();
        self.announcements_ctx.deinit();
        self.mqtt_ctx.deinit();
        self.history_ctx.handleServerExit(self.job_state_ctx.getLastStats());
        // Stop Spoolman's socket and reporting workers before io/conns teardown.
        self.spoolman_ctx.deinit();
        // Stop the TD-1 discovery/poll thread (uses io + core) before teardown.
        self.td1_ctx.stopPolling();
        self.wled_ctx.stopInitialization();
        // Stop the machine proc_stat timer thread before tearing down
        // connections (the timer thread may access conns within emitProcStatUpdate).
        self.machine_ctx.deinit();
        self.alloc.destroy(self.machine_ctx);
        self.conns.deinit(io);
        self.reg.deinit();
        self.dispatcher.deinit();
        // Auth context must be torn down before the store closes (it persists
        // users to the DataStore).
        self.auth_ctx.deinit();
        self.alloc.destroy(self.auth_ctx);
        self.extensions_ctx.deinit();
        self.alloc.destroy(self.extensions_ctx);
        for (self.file_roots) |r| self.alloc.free(r.path);
        self.alloc.free(self.file_roots);
        if (self.instance_uuid_owned) self.alloc.free(self.instance_uuid);
        self.file_ctx.deinit(); // frees the metadata cache
        self.alloc.destroy(self.file_ctx);
        if (self.update_sources_arena) |*arena| arena.deinit();
        self.alloc.destroy(self.update_ctx);
        self.power_ctx.deinit();
        self.alloc.destroy(self.power_ctx);
        self.button_ctx.deinit();
        self.alloc.destroy(self.button_ctx);
        self.wled_ctx.deinit();
        self.alloc.destroy(self.wled_ctx);
        self.td1_ctx.deinit();
        self.alloc.destroy(self.td1_ctx);
        self.printer_ctx.deinit(self.alloc);
        self.alloc.destroy(self.printer_ctx);
        self.klippy_ctx.deinit();
        if (self.klippy_uds_owned) self.alloc.free(self.klippy_ctx.uds_path);
        self.alloc.destroy(self.klippy_ctx);
        self.octoprint_ctx.deinit(self.alloc);
        self.alloc.destroy(self.octoprint_ctx);
        self.alloc.destroy(self.zeroconf_ctx);
        self.analysis_ctx.deinit(self.alloc);
        self.alloc.destroy(self.analysis_ctx);
        self.alloc.destroy(self.mqtt_ctx);
        self.alloc.destroy(self.spoolman_ctx);
        self.db_store.deinit(self.alloc);
        // Best-effort: shutdown continues if the temp tree cannot be removed.
        if (self.temp_datadir) std.Io.Dir.cwd().deleteTree(io, self.datadir) catch {};
        self.alloc.free(self.datadir);
        for (self.cors_domains) |d| self.alloc.free(d);
        if (self.cors_domains.len > 0) self.alloc.free(self.cors_domains);
        self.sensor_ctx.deinit();
        self.alloc.destroy(self.sensor_ctx);
        self.webcam_ctx.deinit();
        self.alloc.destroy(self.webcam_ctx);
        self.notifier_ctx.deinit(self.alloc);
        self.alloc.destroy(self.notifier_ctx);
        self.server_misc_ctx.* = .{};
        self.alloc.destroy(self.server_misc_ctx);
        self.data_store_ctx.deinit();
        self.alloc.destroy(self.data_store_ctx);
        self.alloc.destroy(self.announcements_ctx);
        self.job_queue_ctx.deinit();
        self.alloc.destroy(self.job_queue_ctx);
        self.job_state_ctx.deinit();
        self.alloc.destroy(self.job_state_ctx);
        self.history_ctx.deinit();
        self.alloc.destroy(self.history_ctx);
        self.alloc.destroy(self.bus);
        self.alloc.destroy(self.conns);
        self.alloc.destroy(self.info);
        self.alloc.destroy(self.db_ctx);
        self.alloc.destroy(self.reg);
        self.alloc.destroy(self.dispatcher);
        self.alloc.destroy(self.core);
        if (self.cfg) |cfg| {
            cfg.deinit();
            self.alloc.destroy(cfg);
        }
        if (self.config_path_owned) |path| self.alloc.free(path);
    }

    /// Register ALL currently-implemented endpoints, JSON-RPC methods, and
    /// transport routes in one place. This is the single authoritative list of
    /// what phobos exposes. Extend this function when adding new handlers.
    fn registerAll(self: *App) !void {
        // Core HTTP + JSON-RPC endpoints: server.info, server.config.
        try methods.registerCore(self.reg, self.info);

        // Database component: server.database.* endpoints.
        try db_component.registerDatabase(self.reg, self.db_ctx);

        // History component: server.history.* endpoints.
        try history_component.registerHistory(self.reg, self.history_ctx);

        // Job queue component: server.job_queue.* endpoints.
        try job_queue_component.registerJobQueue(self.reg, self.job_queue_ctx);

        // Announcements component: server.announcements.* endpoints.
        try announcements_component.registerAnnouncements(self.reg, self.announcements_ctx);

        // Data store component: server.gcode_store + server.temperature_store.
        try data_store_component.registerDataStore(self.reg, self.data_store_ctx);

        // Server misc component: server.restart + server.logs.rollover.
        try server_misc_component.registerServerMisc(self.reg, self.server_misc_ctx);

        // Notifier component: server.notifiers.list + debug.notifiers.test.
        try notifier_component.registerNotifier(self.reg, self.notifier_ctx);

        // Webcam component: server.webcams.* endpoints.
        try webcam_component.registerWebcam(self.reg, self.webcam_ctx);

        // Sensor component: server.sensors.* endpoints.
        try sensor_component.registerSensor(self.reg, self.sensor_ctx);

        // Authorization component: access.* endpoints.
        try authorization_component.registerAuthorization(self.reg, self.auth_ctx);

        // Spoolman component: server.spoolman.* endpoints.
        try spoolman_component.registerSpoolman(self.reg, self.spoolman_ctx);

        // MQTT component: server.mqtt.* endpoints.
        try mqtt_component.registerMqtt(self.reg, self.mqtt_ctx);

        // Extensions component: server.extensions.* + connection.* endpoints.
        try extensions_component.registerExtensions(self.reg, self.extensions_ctx);

        // Analysis component: server.analysis.* endpoints.
        try analysis_component.registerAnalysis(self.reg, self.analysis_ctx);

        // File manager component: server.files.* endpoints.
        try file_manager_component.registerFileManager(self.reg, self.file_ctx);

        // Machine component: machine.* + machine.proc_stats endpoints.
        try machine_component.registerMachine(self.reg, self.machine_ctx);

        // Update manager component: machine.update.* endpoints.
        try update_manager_component.registerUpdateManager(self.reg, self.update_ctx);

        // Power device component: machine.device_power.* endpoints.
        try power_component.registerPower(self.reg, self.power_ctx);

        // WLED component: machine.wled.* endpoints.
        try wled_component.registerWled(self.reg, self.wled_ctx);

        // TD-1 component: machine.td1.* endpoints.
        try td1_component.registerTd1(self.reg, self.td1_ctx);

        // Printer component: printer.* endpoints (proxied to Klippy). With no
        // Klippy connection every handler returns the 503 disconnected error.
        try printer_component.registerPrinter(self.reg, self.printer_ctx);

        // OctoPrint compatibility shim: /api/* (HTTP-only, no JSON-RPC).
        try octoprint_component.registerOctoPrint(self.reg, self.octoprint_ctx);

        // Zeroconf/SSDP discovery: /server/zeroconf/ssdp (HTTP-only).
        try zeroconf_component.registerZeroconf(self.reg, self.zeroconf_ctx);

        // WS-only endpoints (server.connection.identify, server.websocket.id):
        // handled inside the WS transport layer per-connection (they need the
        // live *Connection). Register them as WEBSOCKET-only endpoints so they
        // appear in the API surface (both as endpoints and JSON-RPC methods);
        // the derived dispatcher entry points at a no-op stub the WS layer
        // intercepts before the dispatcher is consulted.
        try self.reg.registerEndpoint(
            .{ .path = "/server/connection/identify", .methods = &.{.POST}, .transports = &.{.WEBSOCKET}, .auth_required = false },
            @ptrCast(self.info),
            wsStubHandler,
        );
        try self.reg.registerEndpoint(
            .{ .path = "/server/websocket/id", .methods = &.{.GET}, .transports = &.{.WEBSOCKET} },
            @ptrCast(self.info),
            wsStubHandler,
        );
        // Guard: the registry-derived names must match the WS layer constants,
        // or the WS interception in transport/ws.zig would never fire.
        comptime {
            std.debug.assert(std.mem.eql(u8, ws.identify_method, "server.connection.identify"));
            std.debug.assert(std.mem.eql(u8, ws.websocket_id_method, "server.websocket.id"));
        }

        // Forge-X Feather callbacks. The three remote method names are
        // installed on the heap KlippyCtx here. httpServer/setConfig rebind
        // the handler pointer once App is at its final address.
        self.klippy_ctx.remote_methods = &klippy_remote_methods;
        self.bindFeather();
    }

    /// Read or create `<datadir>/.moonraker.uuid` and point webcam config uids
    /// at it. Moonraker writes `uuid4().hex` once and keeps that file.
    fn ensureInstanceUuid(self: *App, io: std.Io) void {
        if (self.instance_uuid.len != 0) {
            self.webcam_ctx.instance_uuid = self.instance_uuid;
            return;
        }
        const path = std.fs.path.join(self.alloc, &.{ self.datadir, ".moonraker.uuid" }) catch return;
        defer self.alloc.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(80))) |raw| {
            defer self.alloc.free(raw);
            var canon: [32]u8 = undefined;
            if (webcam_component.canonicalInstanceHex(raw, &canon)) {
                const owned = self.alloc.dupe(u8, &canon) catch return;
                self.instance_uuid = owned;
                self.instance_uuid_owned = true;
                self.webcam_ctx.instance_uuid = owned;
                return;
            }
        } else |_| {}
        var bytes: [16]u8 = undefined;
        io.randomSecure(&bytes) catch return;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const owned = self.alloc.dupe(u8, &hex) catch return;
        self.instance_uuid = owned;
        self.instance_uuid_owned = true;
        self.webcam_ctx.instance_uuid = owned;
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer file.close(io);
        var wbuf: [64]u8 = undefined;
        var w = file.writer(io, &wbuf);
        w.interface.writeAll(&hex) catch return;
        w.interface.flush() catch return;
    }

    /// Point Klippy's remote-method hook at this App's Feather adapter.
    fn bindFeather(self: *App) void {
        self.feather.updates = self.update_ctx;
        self.feather.idle = featherPrinterIdle;
        self.feather.idle_ctx = self;
        self.feather.cmd = featherCmd;
        self.feather.cmd_ctx = self;
        self.feather.klippy_send = featherKlippySend;
        self.feather.klippy_send_ctx = self;
        self.klippy_ctx.remote_handler = onKlippyRemoteMethod;
        self.klippy_ctx.remote_handler_ctx = self;
        self.klippy_ctx.event_ctx = self;
        self.klippy_ctx.on_state = onKlippyState;
    }

    /// Moonraker registers `config_examples` and `docs` only after Klippy
    /// reports `klipper_path` and those directories exist. A missing directory
    /// is skipped. `..` in the path is rejected. The callback must copy; this
    /// joins new owned paths onto `file_roots`.
    pub fn registerKlipperRoots(self: *App, klipper_path: []const u8) void {
        if (klipper_path.len < 2 or klipper_path[0] != '/') return;
        if (std.mem.eql(u8, klipper_path, "/")) return;
        if (std.mem.indexOf(u8, klipper_path, "..") != null) return;
        const io = self.file_ctx.io orelse return;
        self.addReadRoot(io, "config_examples", klipper_path, "config");
        self.addReadRoot(io, "docs", klipper_path, "docs");
    }

    fn onKlipperPath(ctx: *anyopaque, klipper_path: []const u8) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const io = self.file_ctx.io orelse return;
        self.core.run(io, App.registerKlipperRoots, .{ self, klipper_path });
    }

    fn addReadRoot(self: *App, io: std.Io, name: []const u8, parent: []const u8, child: []const u8) void {
        const path = std.fs.path.join(self.alloc, &.{ parent, child }) catch return;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            self.alloc.free(path);
            return;
        };
        dir.close(io);
        for (self.file_roots) |*r| {
            if (!std.mem.eql(u8, r.name, name)) continue;
            if (std.mem.eql(u8, r.path, path)) {
                self.alloc.free(path);
                return;
            }
            self.alloc.free(r.path);
            r.path = path;
            r.full_access = false;
            self.file_ctx.roots = self.file_roots;
            self.file_ctx.observeRoot(name);
            return;
        }
        const grown = self.alloc.realloc(self.file_roots, self.file_roots.len + 1) catch {
            self.alloc.free(path);
            return;
        };
        grown[grown.len - 1] = .{ .name = name, .path = path, .full_access = false };
        self.file_roots = grown;
        self.file_ctx.roots = grown;
        self.file_ctx.observeRoot(name);
        self.syncRegisteredDirectories();
    }

    /// Read `[mqtt]` like mqtt.py: `address` is required, `instance_name`
    /// defaults to the host name and `api_qos` to `default_qos`.
    fn applyMqttConfig(self: *App, aio: std.Io, cfg: *const config_helper.ConfigParser) !void {
        const address = cfg.get("mqtt", "address") orelse return error.MissingAddress;
        const port = cfg.getInt("mqtt", "port") catch |err| switch (err) {
            error.NoOption => 1883,
            else => return err,
        };
        const default_qos = cfg.getInt("mqtt", "default_qos") catch |err| switch (err) {
            error.NoOption => 0,
            else => return err,
        };
        const api_qos: ?i64 = cfg.getInt("mqtt", "api_qos") catch |err| switch (err) {
            error.NoOption => null,
            else => return err,
        };
        const enable_api = cfg.getBoolean("mqtt", "enable_moonraker_api") catch |err| switch (err) {
            error.NoOption => true,
            else => return err,
        };
        const enable_tls = cfg.getBoolean("mqtt", "enable_tls") catch |err| switch (err) {
            error.NoOption => false,
            else => return err,
        };
        const protocol = try @import("components/mqtt_proto.zig").Protocol.parse(cfg.get("mqtt", "mqtt_protocol") orelse "v3.1.1");
        const status_interval = if (cfg.hasOption("mqtt", "status_interval")) blk: {
            const value = try cfg.getFloat("mqtt", "status_interval");
            if (!std.math.isFinite(value) or value <= 0.25) return error.InvalidStatusInterval;
            break :blk value;
        } else 0;
        const split_status = cfg.getBoolean("mqtt", "publish_split_status") catch |err| switch (err) {
            error.NoOption => false,
            else => return err,
        };
        var config_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer config_arena.deinit();
        const objects = try mqtt_component.parseStatusObjects(config_arena.allocator(), cfg.get("mqtt", "status_objects") orelse "");
        var generated_id: [23]u8 = undefined;
        const requested_id = cfg.get("mqtt", "client_id") orelse "";
        const client_id = if (protocol == .v31 and requested_id.len == 0) blk: {
            var random: [8]u8 = undefined;
            try aio.randomSecure(&random);
            break :blk try std.fmt.bufPrint(&generated_id, "phobos{s}", .{std.fmt.bytesToHex(random, .lower)});
        } else requested_id;
        var credentials = try mqtt_credentials.load(self.alloc, aio, self.datadir, self.mqtt_ctx.home_directory, cfg);
        defer credentials.deinit();
        var host_buf: [64]u8 = undefined; // HOST_NAME_MAX
        const instance_name = cfg.get("mqtt", "instance_name") orelse
            std.mem.trim(u8, try std.Io.Dir.cwd().readFile(aio, "/proc/sys/kernel/hostname", &host_buf), &std.ascii.whitespace);
        try self.mqtt_ctx.setConfig(.{
            .address = address,
            .protocol = protocol,
            .clock_io = aio,
            .status_objects = objects,
            .status_interval = status_interval,
            .publish_split_status = split_status,
            .port = std.math.cast(u16, port) orelse return error.InvalidPort,
            .username = credentials.username,
            .password = credentials.password,
            .client_id = client_id,
            .instance_name = instance_name,
            .default_qos = default_qos,
            .api_qos = api_qos,
            .enable_moonraker_api = enable_api,
            .enable_tls = enable_tls,
        });
    }

    /// Inject before requests are served. The embedding owns backend authentication.
    pub fn setAnalysisRunner(self: *App, runner: ?analysis_component.Runner) void {
        self.analysis_ctx.setRunner(runner);
    }

    fn applyAnalysisConfig(self: *App, cfg: *const config_helper.ConfigParser) !void {
        const configured = cfg.get("analysis", "platform") orelse "auto";
        if (!std.mem.eql(u8, configured, "auto") and !std.mem.eql(u8, configured, "linux") and !std.mem.eql(u8, configured, "rpi") and !std.mem.eql(u8, configured, "osx")) return error.InvalidValue;
        const plat: []const u8 = if (std.mem.eql(u8, configured, "linux") or std.mem.eql(u8, configured, "rpi") or std.mem.eql(u8, configured, "osx"))
            configured
        else if (@import("builtin").cpu.arch == .arm or @import("builtin").cpu.arch == .aarch64)
            "rpi"
        else
            "linux";
        const seconds = cfg.getInt("analysis", "estimator_timeout") catch |err| switch (err) {
            error.NoOption => 600,
            else => return err,
        };
        if (seconds <= 0) return error.InvalidValue;
        const bin = try std.fmt.allocPrint(self.alloc, "{s}/tools/klipper_estimator/klipper_estimator_{s}", .{ self.datadir, plat });
        errdefer self.alloc.free(bin);
        var cfg_path = try std.fmt.allocPrint(self.alloc, "{s}/tools/klipper_estimator/default_estimator_cfg.json", .{self.datadir});
        errdefer self.alloc.free(cfg_path);
        if (cfg.get("analysis", "estimator_config")) |rel| {
            const trimmed = std.mem.trim(u8, rel, " \t/");
            var segments = std.mem.splitScalar(u8, trimmed, '/');
            while (segments.next()) |segment| if (std.mem.eql(u8, segment, "..")) return error.InvalidValue;
            var local = std.heap.ArenaAllocator.init(self.alloc);
            defer local.deinit();
            const path = try file_manager_component.resolveRequestPath(self.file_ctx, local.allocator(), try std.fmt.allocPrint(local.allocator(), "config/{s}", .{trimmed}));
            const file = try path.openFile(self.analysis_ctx.io.?, local.allocator());
            file.close(self.analysis_ctx.io.?);
            const custom = try self.alloc.dupe(u8, path.abs);
            self.alloc.free(cfg_path);
            cfg_path = custom;
        }
        if (self.analysis_ctx.paths_owned) {
            self.alloc.free(self.analysis_ctx.estimator_path);
            self.alloc.free(self.analysis_ctx.estimator_config);
        }
        self.analysis_ctx.estimator_path = bin;
        self.analysis_ctx.estimator_config = cfg_path;
        self.analysis_ctx.paths_owned = true;
        self.analysis_ctx.timeout = .fromSeconds(seconds);
    }

    /// Returns the HTTP transport Server configured with this App's components.
    /// The caller must supply a live `io` (from a threaded event loop). The
    /// returned Server borrows all App-owned pointers; the App must outlive it.
    pub fn httpServer(self: *App, io: std.Io) http_transport.Server {
        // Rebind after App is at its final address (init returned it by value).
        self.bindFeather();
        self.auth_ctx.on_user_logout = onUserLogout;
        self.auth_ctx.on_user_logout_ctx = self;
        if (self.remote_worker == null) {
            self.remote_calls = .init(&self.remote_call_buf);
            self.remote_worker = io.concurrent(remoteWorker, .{ self, io }) catch |err| blk: {
                self.remote_calls.close(io);
                std.debug.print("phobos: warning: Klipper remote methods disabled: {}\n", .{err});
                break :blk null;
            };
        }
        self.ensureInstanceUuid(io);
        // Temperature store needs io to lock its buffer from the RPC handler.
        // Wire Core+io into the dispatcher so it takes the Core lock per-method
        // (read-only `off_core` methods skip it). Without this every JSON-RPC
        // method would run unlocked.
        self.dispatcher.setRuntime(self.core, io);
        self.data_store_ctx.setIo(io);
        // Wire the live io into the spoolman component so it can emit
        // notify_active_spool_set to connected WebSocket clients.
        self.spoolman_ctx.setIo(io);
        // Spoolman WebSocket, deletion pushes and periodic filament reports.
        self.spoolman_ctx.on_spool_deleted = spoolmanSpoolDeleted;
        self.spoolman_ctx.on_spool_deleted_ctx = self;
        self.spoolman_ctx.startWs();
        // TD-1 filament sensor: background USB discovery + serial polling.
        self.td1_ctx.setIo(io);
        self.td1_ctx.setCore(self.core);
        if (self.cfg != null and self.cfg.?.hasSection("td1")) self.td1_ctx.startPolling() catch |err|
            std.debug.print("phobos: warning: TD1 discovery disabled: {}\n", .{err});
        // Wire io into the file manager so it can emit notify_filelist_changed.
        self.file_ctx.setIo(io);
        self.analysis_ctx.io = io;
        self.analysis_ctx.core = self.core;
        self.klippy_ctx.on_klipper_path = onKlipperPath;
        self.klippy_ctx.on_klipper_path_ctx = self;
        // Wire io into the machine component for /proc & /sys reads.
        self.machine_ctx.core = self.core;
        self.machine_ctx.setIo(io);
        // Wire io into the update manager so it can emit notify_update_response /
        // notify_update_refreshed to connected WebSocket clients.
        self.update_ctx.setIo(io);
        // Wire io into the power component so it can emit notify_power_changed.
        self.power_ctx.setIo(io);
        self.power_ctx.applyInitialStates();
        // Handlers hold Core from here on; device HTTP releases it.
        self.power_ctx.core = self.core;
        self.button_ctx.io = io;
        self.button_ctx.core = self.core;
        self.wled_ctx.setIo(io);
        self.wled_ctx.core = self.core;
        self.wled_ctx.startInitialization() catch |err|
            std.debug.print("phobos: warning: WLED initialization disabled: {}\n", .{err});
        self.sensor_ctx.setIo(io);
        // Wire io into the job queue so it can emit notify_job_queue_changed.
        self.job_queue_ctx.setIo(io);
        // Wire io into the history component so it can emit notify_history_changed.
        self.history_ctx.setIo(io);
        // Wire io into the announcements component so it can emit notify_announcement_*.
        self.announcements_ctx.setIo(io);
        // Wire io into the webcam component so it can emit notify_webcams_changed.
        self.webcam_ctx.setIo(io);
        // Wire io into the klippy connection so it can connect and handshake.
        self.klippy_ctx.setIo(io);
        self.paneldue.bind(io, self.alloc, self.core, self.klippy_ctx, self.file_ctx);
        self.paneldue.start() catch |err| std.debug.print("phobos: PanelDue startup: {}\n", .{err});
        // Wire io into MQTT and, when a broker is configured, connect to it in
        // the background (a slow/unreachable broker must not stall startup).
        self.mqtt_ctx.io = io;
        // Bridge inbound MQTT messages → sensors (under the Core lock) and
        // subscribe sensor topics on connect.
        self.sensor_mqtt_bridge = .{ .app = self };
        self.mqtt_ctx.on_message = SensorMqttBridge.onMessage;
        self.mqtt_ctx.on_message_ctx = &self.sensor_mqtt_bridge;
        // JSON-RPC-over-MQTT bridge: dispatch api_request frames through the
        // shared dispatcher and publish the response.
        self.mqtt_ctx.api_dispatch = mqttApiDispatch;
        self.mqtt_ctx.api_dispatch_ctx = self;
        self.mqtt_ctx.on_connected = SensorMqttBridge.onConnected;
        self.mqtt_ctx.on_connected_ctx = &self.sensor_mqtt_bridge;
        self.mqtt_ctx.on_connection = SensorMqttBridge.onConnection;
        self.mqtt_ctx.on_connection_ctx = &self.sensor_mqtt_bridge;
        self.mqtt_ctx.start();
        // Wire connections and io into ServerInfo so server.info reports live
        // websocket_count.
        self.info.conns = self.conns;
        self.info.io = io;
        return .{
            .io = io,
            .core = self.core,
            .reg = self.reg,
            .dispatcher = self.dispatcher,
            .conns = self.conns,
            .auth = self.auth_ctx,
            .file_ctx = self.file_ctx,
            .datadir = self.datadir,
            .klippy_ctx = self.klippy_ctx,
            .extensions_ctx = self.extensions_ctx,
            .cors_domains = self.cors_domains,
            .use_xheaders = self.use_xheaders,
            .max_websocket_connections = self.max_websocket_connections,
        };
    }
};

fn onUserLogout(ctx: *anyopaque, user: []const u8) void {
    const instance: *App = @ptrCast(@alignCast(ctx));
    instance.conns.invalidateUser(instance.auth_ctx.io, user);
}

/// Placeholder handler for WS-only methods registered in the dispatcher for
/// reflection purposes. The real implementations in `transport/ws.zig`
/// intercept those method names before the dispatcher is consulted.
fn wsStubHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.WsOnlyMethod;
}

/// Dispatch a parsed MQTT API request through the JSON-RPC dispatcher and
/// return the response bytes. Wired into MqttCtx.api_dispatch; runs on the MQTT
/// reader thread, which does not hold Core. The dispatcher takes Core per
/// method, so wrapping this in core.run would deadlock.
fn mqttApiDispatch(ctx: *anyopaque, request: std.json.Value, alloc: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    // MQTT requests are not authenticated (Moonraker MQTTClient.screen_rpc_request).
    return app.dispatcher.handleParsedRoot(.{
        .transport = .MQTT,
        .screen = .{ .ctx = app.mqtt_ctx, .run = MqttCtx.screenRequest },
    }, request, alloc);
}

/// Spoolman WS spool-deletion hook: clear the active spool (if it was the
/// deleted one) under the Core lock. Runs off the WS supervisor thread.
fn spoolmanSpoolDeleted(ctx: *anyopaque, spool_id: i64) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const io = app.spoolman_ctx.io orelse return;
    app.core.run(io, SpoolmanCtx.handleSpoolDeletedLocked, .{ app.spoolman_ctx, spool_id }) catch |err|
        std.debug.print("phobos: failed to clear deleted spool {d}: {}\n", .{ spool_id, err });
}

/// Glue between the MQTT reader thread and the sensor component. Inbound
/// messages enter the sensor store under the Core lock so they serialize with
/// JSON-RPC handlers and notifications.
pub const SensorMqttBridge = struct {
    app: *App = undefined,

    pub fn onConnection(ctx: *anyopaque, connected: bool) void {
        const self: *SensorMqttBridge = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const io = app.mqtt_ctx.io orelse return;
        app.core.run(io, SensorCtx.onMqttConnection, .{ app.sensor_ctx, connected });
    }

    /// MQTT inbound-message hook. Runs sensor ingestion under the Core lock.
    pub fn onMessage(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *SensorMqttBridge = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const io = app.mqtt_ctx.io orelse return;
        var arena = std.heap.ArenaAllocator.init(app.alloc);
        defer arena.deinit();
        app.core.run(io, SensorCtx.ingestMqttMessage, .{ app.sensor_ctx, topic, payload, arena.allocator() });
    }

    /// MQTT post-connect hook: subscribe every MQTT sensor's state topic.
    pub fn onConnected(ctx: *anyopaque) void {
        const self: *SensorMqttBridge = @ptrCast(@alignCast(ctx));
        const app = self.app;
        const io = app.mqtt_ctx.io orelse return;
        var arena = std.heap.ArenaAllocator.init(app.alloc);
        defer arena.deinit();
        const topics = app.core.run(io, copyTopics, .{ self, arena.allocator() }) catch |err| {
            std.debug.print("phobos: warning: sensor topics not subscribed: {}\n", .{err});
            return;
        };
        for (topics) |topic| app.mqtt_ctx.subscribeTopicLive(topic, null);
    }

    fn copyTopics(self: *SensorMqttBridge, alloc: std.mem.Allocator) ![][]const u8 {
        var topics: std.ArrayList([]const u8) = .empty;
        var it = self.app.sensor_ctx.sensors.valueIterator();
        while (it.next()) |s| {
            if (s.state_topic) |topic| try topics.append(alloc, try alloc.dupe(u8, topic));
        }
        return topics.toOwnedSlice(alloc);
    }
};

/// Dispatches a gcode request to Klippy on behalf of the job_queue component.
/// This is the adapter that bridges job_queue's anyopaque dispatch to
/// KlippyCtx.requestOffCore(). Called via JobQueueCtx.setKlippyDispatch.
fn jobQueueKlippyDispatch(klippy_opaque: *anyopaque, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const k: *KlippyConnectionCtx = @ptrCast(@alignCast(klippy_opaque));
    // Job dispatch runs on a dedicated worker thread
    // (job_queue.scheduleNextJobDispatch) that holds no Core and is not the
    // Klippy reader (which would block on its own response).
    return k.requestOffCore(method, params, alloc);
}

// --- tests ---------------------------------------------------------------

test "deinit drains queued remote calls even without a worker" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    var instance = try App.init(alloc, std.testing.io, path);
    instance.remote_calls = .init(&instance.remote_call_buf);
    const req = (try remoteMethodRequest(alloc, "set_wled", .null)).?;
    try instance.remote_calls.putAll(std.testing.io, &.{req});
    instance.deinit(std.testing.io);
}

/// App whose datadir is `tmp`.
fn testApp(alloc: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !App {
    const data_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(data_path);
    return App.init(alloc, io, data_path);
}

test "App.init registers server.info and server.config" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);

    // HTTP routes present in the registry.
    try std.testing.expect(app.reg.lookup(.GET, "/server/info") != null);
    try std.testing.expect(app.reg.lookup(.GET, "/server/config") != null);

    // JSON-RPC methods present in the dispatcher.
    try std.testing.expect(app.dispatcher.methods.get("server.info") != null);
    try std.testing.expect(app.dispatcher.methods.get("server.config") != null);
}

test "setConfig [server] use_xheaders false is what httpServer serves" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[server]\nuse_xheaders: false\n" });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    const before = app.httpServer(io);
    try std.testing.expect(before.use_xheaders);
    try app.setConfig(io, cfg_path);
    const after = app.httpServer(io);
    try std.testing.expect(!after.use_xheaders);
}

test "a late config error retains borrowed configuration until App teardown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const aio = std.testing.io;
    try tmp.dir.writeFile(aio, .{ .sub_path = "invalid.cfg", .data = "[job_queue]\nload_on_startup: invalid\n" });
    const path = try tmp.dir.realPathFileAlloc(aio, "invalid.cfg", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const data_path = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(data_path);
    var server_app = try App.init(std.testing.allocator, aio, data_path);
    defer server_app.deinit(aio);
    try std.testing.expectError(error.InvalidValue, server_app.setConfig(aio, path));
    try std.testing.expect(server_app.cfg != null);
    try std.testing.expectEqualStrings("invalid", server_app.cfg.?.get("job_queue", "load_on_startup").?);
    try std.testing.expect(server_app.info.cfg == server_app.cfg);
    try std.testing.expectEqualStrings(path, server_app.config_path_owned.?);
}

test "setConfig loads trusted clients, update sources, and feather_updates" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[server]
        \\klippy_uds_address: /no/such/klippy.sock
        \\
        \\[authorization]
        \\trusted_clients:
        \\    0.0.0.0/0
        \\
        \\[update_manager]
        \\enable_system_updates: False
        \\
        \\[feather_updates]
        \\update_key: forge-x
        \\
        \\[update_manager forge-x]
        \\type: git_repo
        \\channel: dev
        \\path: /no/such/forge-x
        \\origin: https://github.com/DrA1ex/ff5m.git
        \\primary_branch: 1.4.2
        \\
        \\[update_manager fluidd]
        \\type: web
        \\repo: fluidd-core/fluidd
        \\path: /no/such/fluidd
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);

    const addr = try std.Io.net.IpAddress.parse("8.8.8.8", 0);
    try std.testing.expect(app.auth_ctx.trusted.isTrusted(addr));
    try std.testing.expectEqualStrings("/no/such/klippy.sock", app.klippy_ctx.uds_path);
    try std.testing.expect(app.feather.enabled);
    try std.testing.expectEqualStrings("forge-x", app.feather.update_key);
    try std.testing.expectEqual(klippy_remote_methods.len, app.klippy_ctx.remote_methods.len);
    try std.testing.expect(app.klippy_ctx.remote_handler != null);

    var saw_system = false;
    var saw_forge = false;
    for (app.update_ctx.sources) |s| {
        if (std.mem.eql(u8, s.name, "system")) saw_system = true;
        if (std.mem.eql(u8, s.name, "forge-x")) {
            saw_forge = true;
            try std.testing.expectEqualStrings("ff5m", s.repo_name);
            try std.testing.expectEqualStrings("1.4.2", s.branch);
        }
    }
    try std.testing.expect(!saw_system);
    try std.testing.expect(saw_forge);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const built = try methods.serverInfoHandler(app.info, .null, arena.allocator());
    var found_update = false;
    var found_octo = false;
    var found_feather = false;
    for (built.object.get("components").?.array.items) |c| {
        if (std.mem.eql(u8, c.string, "update_manager")) found_update = true;
        if (std.mem.eql(u8, c.string, "octoprint_compat")) found_octo = true;
        if (std.mem.eql(u8, c.string, "feather_updates")) found_feather = true;
    }
    try std.testing.expect(found_update);
    try std.testing.expect(found_octo);
    try std.testing.expect(found_feather);

    const status = try feather_updates_component.statusResponse(&app.feather, arena.allocator(), 3);
    try std.testing.expectEqual(@as(i64, 3), status.object.get("token").?.integer);
    try std.testing.expect(status.object.get("error").?.string.len > 0 or status.object.get("installed_version") != null);

    const Rec = struct {
        method: []const u8 = "",
        fn send(ctx: *anyopaque, _: std.mem.Allocator, method: []const u8, _: std.json.Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.method = method;
        }
    };
    var rec = Rec{};
    app.feather.klippy_send = Rec.send;
    app.feather.klippy_send_ctx = &rec;
    var params: std.json.ObjectMap = .empty;
    try params.put(arena.allocator(), "token", .{ .integer = 1 });
    var frame: std.json.ObjectMap = .empty;
    try frame.put(arena.allocator(), "params", .{ .object = params });
    // Remote calls queue for the worker; run the one queued call here.
    app.remote_calls = .init(&app.remote_call_buf);
    app.klippy_ctx.io = io;
    try app.klippy_ctx.dispatchRemoteMethod(io, "feather_request_forge_x_update_status", .{ .object = frame });
    try std.testing.expectEqualStrings("", rec.method);
    runRemoteCall(&app, io, try app.remote_calls.getOne(io));
    try std.testing.expectEqualStrings("feather/update_status", rec.method);
    try std.testing.expectEqualStrings("feather_request_forge_x_update_status", app.klippy_ctx.remote_methods[0]);
    try std.testing.expectEqualStrings("feather_start_forge_x_update", app.klippy_ctx.remote_methods[1]);
    try std.testing.expectEqualStrings("feather_reset_forge_x_update", app.klippy_ctx.remote_methods[2]);
}

test "dispatchFrame: id-less reset uses the daemon runner and does not spawn git" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[feather_updates]
        \\update_key: forge-x
        \\
        \\[update_manager forge-x]
        \\type: git_repo
        \\channel: dev
        \\path: /no/such/feather-repo
        \\origin: https://github.com/DrA1ex/ff5m.git
        \\primary_branch: 1.4.2
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    app.bindFeather();
    // No package runner: apt and pip updates are refused before they start.
    try std.testing.expect(app.update_ctx.shell == null);
    try std.testing.expect(app.update_ctx.io == null);
    app.info.klippy_connected = true;
    app.info.klippy_state = "ready";

    const SpawnRec = struct {
        alloc: std.mem.Allocator,
        cmds: std.ArrayList([]const u8),
        fn spawn(ctx: *anyopaque, call_alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(call_alloc);
            for (argv, 0..) |arg, i| {
                if (i != 0) try buf.append(call_alloc, ' ');
                try buf.appendSlice(call_alloc, arg);
            }
            try self.cmds.append(self.alloc, try self.alloc.dupe(u8, buf.items));
        }
    };
    var rec = SpawnRec{ .alloc = alloc, .cmds = .empty };
    defer {
        for (rec.cmds.items) |s| alloc.free(s);
        rec.cmds.deinit(alloc);
    }
    app.git_spawn = SpawnRec.spawn;
    app.git_spawn_ctx = &rec;

    try std.testing.expectError(error.Refused, featherCmd(&app, alloc, &.{ "git", "reboot" }));
    try std.testing.expectError(error.Refused, featherCmd(&app, alloc, &.{"shutdown"}));
    try std.testing.expectError(error.Refused, featherCmd(&app, alloc, &.{"poweroff"}));
    try std.testing.expectEqual(@as(usize, 0), rec.cmds.items.len);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try featherCmd(&app, arena_state.allocator(), &.{ "machine.update.client", "forge-x" });
    try std.testing.expectEqual(@as(usize, 0), rec.cmds.items.len);
    try std.testing.expectError(error.UpdateFailed, featherCmd(&app, arena_state.allocator(), &.{ "machine.update.client", "missing-source" }));

    const Prog = struct {
        alloc: std.mem.Allocator,
        methods: std.ArrayList([]const u8),
        states: std.ArrayList([]const u8),
        fn send(ctx: *anyopaque, _: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.methods.append(self.alloc, try self.alloc.dupe(u8, method));
            if (params == .object) {
                if (params.object.get("state")) |st| {
                    if (st == .string) try self.states.append(self.alloc, try self.alloc.dupe(u8, st.string));
                }
            }
        }
    };
    var prog = Prog{ .alloc = alloc, .methods = .empty, .states = .empty };
    defer {
        for (prog.methods.items) |s| alloc.free(s);
        prog.methods.deinit(alloc);
        for (prog.states.items) |s| alloc.free(s);
        prog.states.deinit(alloc);
    }
    app.feather.klippy_send = Prog.send;
    app.feather.klippy_send_ctx = &prog;

    const payload = "{\"method\":\"feather_reset_forge_x_update\",\"params\":{\"token\":8}}";
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"id\"") == null);
    app.remote_calls = .init(&app.remote_call_buf);
    app.klippy_ctx.io = io;
    try app.klippy_ctx.dispatchFrame(io, payload);
    runRemoteCall(&app, io, try app.remote_calls.getOne(io));
    try std.testing.expectEqual(@as(usize, 2), rec.cmds.items.len);
    try std.testing.expectEqualStrings("git -C /no/such/feather-repo reset --hard HEAD", rec.cmds.items[0]);
    try std.testing.expectEqualStrings("git -C /no/such/feather-repo clean -fd", rec.cmds.items[1]);
    try std.testing.expectEqualStrings("feather/update_progress", prog.methods.items[0]);
    try std.testing.expectEqualStrings("reset_complete", prog.states.items[0]);
}

test "setConfig loads announcement subscriptions and gcode store size" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[announcements]
        \\dev_mode: True
        \\subscriptions:
        \\    fluidd
        \\
        \\[data_store]
        \\gcode_store_size: 2
        \\temperature_store_size: 3
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    try std.testing.expect(app.announcements_ctx.dev_mode);
    try std.testing.expectEqual(@as(usize, 2), app.data_store_ctx.gcode_ring.entries.buffer.len);
    try std.testing.expectEqual(@as(usize, 3), app.data_store_ctx.temp_capacity);
    try app.data_store_ctx.pushGcodeCommand("one", 1);
    try app.data_store_ctx.pushGcodeCommand("two", 2);
    try app.data_store_ctx.pushGcodeCommand("three", 3);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const feeds = try announcements_component.handleListFeeds(@ptrCast(app.announcements_ctx), .null, arena.allocator());
    var found = false;
    for (feeds.object.get("feeds").?.array.items) |f| {
        if (std.mem.eql(u8, f.string, "fluidd")) found = true;
    }
    try std.testing.expect(found);
    const store = try data_store_component.handleGcodeStore(@ptrCast(app.data_store_ctx), .null, arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), store.object.get("gcode_store").?.array.items.len);
}

test "setConfig [octoprint_compat] is what /api/settings returns" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[octoprint_compat]
        \\enable_ufp: false
        \\flip_h: true
        \\rotate_90: true
        \\webcam_enabled: false
        \\stream_url: http://cam/stream
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const settings = try octoprint_component.handleSettings(@ptrCast(app.octoprint_ctx), .null, arena.allocator());
    try std.testing.expect(settings.object.get("plugins").?.object.get("UltimakerFormatPackage") == null);
    const webcam = settings.object.get("webcam").?.object;
    try std.testing.expect(webcam.get("flipH").?.bool);
    try std.testing.expect(webcam.get("rotate90").?.bool);
    try std.testing.expect(!webcam.get("webcamEnabled").?.bool);
    try std.testing.expectEqualStrings("http://cam/stream", webcam.get("streamUrl").?.string);
}

test "setConfig loads [webcam name] cameras into the list" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[webcam cam]
        \\enabled: True
        \\service: mjpegstreamer-adaptive
        \\stream_url: /webcam/?action=stream
        \\snapshot_url: /webcam/?action=snapshot
        \\
        \\[webcam Example]
        \\enabled: False
        \\stream_url: http://your_IP:8080/?action=stream
        \\snapshot_url: http://your_IP:8080/?action=snapshot
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    const uuid_path = try std.fmt.allocPrint(alloc, "{s}/.moonraker.uuid", .{app.datadir});
    defer alloc.free(uuid_path);
    {
        const uuid_file = try std.Io.Dir.cwd().createFile(io, uuid_path, .{});
        defer uuid_file.close(io);
        var wbuf: [64]u8 = undefined;
        var w = uuid_file.writer(io, &wbuf);
        try w.interface.writeAll("a48b28888e484d4fac9b7bc09e068dea");
        try w.interface.flush();
    }
    try app.setConfig(io, cfg_path);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const listed = try webcam_component.handleWebcamList(@ptrCast(app.webcam_ctx), .null, arena.allocator());
    const cams = listed.object.get("webcams").?.array;
    try std.testing.expectEqual(@as(usize, 2), cams.items.len);
    const cam = cams.items[0].object;
    try std.testing.expectEqualStrings("cam", cam.get("name").?.string);
    try std.testing.expectEqualStrings("1616e509-4515-53e4-8cd8-74875fb859c9", cam.get("uid").?.string);
    try std.testing.expectEqualStrings("config", cam.get("source").?.string);
    try std.testing.expectEqualStrings("mjpegstreamer-adaptive", cam.get("service").?.string);
    try std.testing.expectEqualStrings("/webcam/?action=stream", cam.get("stream_url").?.string);
    try std.testing.expect(cam.get("enabled").?.bool);
    const example = cams.items[1].object;
    try std.testing.expectEqualStrings("Example", example.get("name").?.string);
    try std.testing.expectEqualStrings("e98363d4-af2e-5f41-8515-e84af7baf3c2", example.get("uid").?.string);
    try std.testing.expect(!example.get("enabled").?.bool);
}

test "setConfig [machine] provider simple restarts through script_path and does not reboot" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[machine]
        \\provider: simple
        \\supervisord_config_path: provider config.conf
        \\script_path: /no/such/scripts
        \\script_timeout: 12
        \\validate_service: false
        \\validate_config: false
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    try std.testing.expectEqualStrings("simple", app.machine_ctx.provider_name);
    try std.testing.expectEqualStrings("provider config.conf", app.machine_ctx.supervisord_config_path.?);
    try std.testing.expectEqualStrings("/no/such/scripts", app.machine_ctx.script_path);
    try std.testing.expectEqual(@as(f64, 12), app.machine_ctx.script_timeout_s);

    const Rec = struct {
        path: []const u8 = "",
        action: []const u8 = "",
        calls: usize = 0,
        alloc: std.mem.Allocator,
        fn run(ctx: *anyopaque, _: std.mem.Allocator, argv: []const []const u8) anyerror!machine_component.MachineCtx.RunCmdResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (argv.len >= 1) self.path = try self.alloc.dupe(u8, argv[0]);
            if (argv.len >= 2) self.action = try self.alloc.dupe(u8, argv[1]);
            return .{ .stdout = &.{}, .stderr = &.{} };
        }
    };
    var rec = Rec{ .alloc = alloc };
    defer if (rec.path.len > 0) alloc.free(rec.path);
    defer if (rec.action.len > 0) alloc.free(rec.action);
    app.setMachineRunCmdFn(Rec.run, @ptrCast(&rec));
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const params = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"service\":\"klipper\"}", .{});
    defer params.deinit();
    const restarted = try machine_component.handleServiceRestart(@ptrCast(app.machine_ctx), params.value, arena.allocator());
    try std.testing.expectEqualStrings("ok", restarted.string);
    try std.testing.expectEqualStrings("/no/such/scripts/klipper", rec.path);
    try std.testing.expectEqualStrings("restart", rec.action);
    // AGENT: NEVER turn these two calls into systemctl/reboot/shutdown/poweroff.
    // They must stay no-ops. rec.calls stays 1 (the service restart only).
    // Implementing the real command reboots the machine that runs the tests.
    _ = try machine_component.handleReboot(@ptrCast(app.machine_ctx), .null, arena.allocator());
    _ = try machine_component.handleShutdown(@ptrCast(app.machine_ctx), .null, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
}

test "setConfig loads auto-refresh, excludes, and hidden objects" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[update_manager]
        \\enable_auto_refresh: False
        \\refresh_interval: 168
        \\refresh_window: 0-5
        \\
        \\[file_manager]
        \\file_system_observer: none
        \\queue_gcode_uploads: True
        \\excludes:
        \\    gcodes/.mod
        \\    gcodes/logFiles
        \\
        \\[klippy_apis]
        \\hidden_objects:
        \\    output_pin level_h1
        \\    output_pin power_off
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    try std.testing.expect(!app.update_ctx.auto_refresh);
    try std.testing.expectEqual(@as(i64, 168), app.update_ctx.refresh_interval_hours);
    try std.testing.expectEqual(@as(i64, 0), app.update_ctx.refresh_window_start);
    try std.testing.expectEqual(@as(i64, 5), app.update_ctx.refresh_window_end);
    try std.testing.expect(app.update_ctx.refresh_thread == null);
    try std.testing.expectEqual(.none, app.file_ctx.observer_kind);
    try std.testing.expect(app.file_ctx.queue_gcode_uploads);
    try std.testing.expect(app.file_ctx.observer == null);
    try std.testing.expect(file_manager_component.FileCtx.pathExcluded(app.file_ctx.excludes, "gcodes", ".mod"));
    try std.testing.expect(file_manager_component.FileCtx.pathExcluded(app.file_ctx.excludes, "gcodes", "logFiles/a.log"));
    try std.testing.expect(!app.update_ctx.tickAutoRefresh(2));
    try std.testing.expectEqual(@as(usize, 2), app.printer_ctx.hidden_objects.len);
    try std.testing.expectEqualStrings("output_pin level_h1", app.printer_ctx.hidden_objects[0]);
    try std.testing.expectEqualStrings("output_pin power_off", app.printer_ctx.hidden_objects[1]);
}

test "setConfig refuses an invalid upload queue boolean" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "moonraker.conf", .data = "[file_manager]\nqueue_gcode_uploads: invalid\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "moonraker.conf", alloc);
    defer alloc.free(path);
    var application = try testApp(alloc, io, &tmp);
    defer application.deinit(io);
    try std.testing.expect(!application.file_ctx.queue_gcode_uploads);
    try std.testing.expectError(error.InvalidValue, application.setConfig(io, path));
    try std.testing.expect(!application.file_ctx.queue_gcode_uploads);
    try std.testing.expect(application.cfg == null);
    try std.testing.expect(application.info.cfg == null);
}

test "setConfig [power] reads pin and protocol URLs without leaking" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[power psu]
        \\type: gpio
        \\pin: !gpiochip0/gpio23
        \\locked_while_printing: True
        \\initial_state: on
        \\
        \\[power plug]
        \\type: shelly
        \\address: 10.0.0.9
        \\output_id: 2
        \\
        \\[power bad]
        \\type: gpio
        \\pin: nope
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    const psu = app.power_ctx.findDevice("psu").?;
    try std.testing.expectEqual(@as(?u32, 23), psu.gpio_pin);
    try std.testing.expect(psu.gpio_active_low);
    try std.testing.expect(psu.locked_while_printing);
    try std.testing.expectEqualStrings("on", psu.initial_state.?);
    try std.testing.expectEqualStrings("off", psu.state);
    const plug = app.power_ctx.findDevice("plug").?;
    try std.testing.expectEqualStrings("http://10.0.0.9/relay/2?turn=on", plug.on_url.?);
    try std.testing.expectEqualStrings("http://10.0.0.9/relay/2", plug.status_url.?);
    try std.testing.expect(app.power_ctx.findDevice("bad") == null);
}

test "setConfig reads GPIO button sections without starting device readers" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "moonraker.conf", .data = "[button estop]\npin: !gpiochip1/gpio3\non_press: {% do call_method('printer.emergency_stop') %}\n" });
    var path: [128]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&path, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    var application = try testApp(alloc, io, &tmp);
    defer application.deinit(io);
    try application.setConfig(io, config_path);
    const button = application.button_ctx.buttons.get("estop").?;
    try std.testing.expectEqual(@as(u32, 1), button.pin.chip);
    try std.testing.expect(button.pin.inverted);
    try std.testing.expect(button.input == null and button.reader == null);
    try std.testing.expect(application.button_ctx.worker == null);
}

test "setConfig [wled] builds http and serial transports and rejects bad strips" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const body =
        \\[wled desk]
        \\address: 10.0.0.5
        \\chain_count: 3
        \\timeout: 0.5
        \\
        \\[wled shelf]
        \\type: serial
        \\serial: /dev/ttyWLED
        \\
        \\[wled nowhere]
        \\type: serial
        \\
        \\[wled odd]
        \\type: dmx
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    const desk = app.wled_ctx.findStrip("desk").?;
    try std.testing.expectEqualStrings("http://10.0.0.5:80/json", desk.transport.http);
    try std.testing.expectEqual(@as(usize, 3), desk.chain_count);
    try std.testing.expectEqual(@as(i64, 500), desk.timeout.toMilliseconds());
    const shelf = app.wled_ctx.findStrip("shelf").?;
    try std.testing.expectEqualStrings("/dev/ttyWLED", shelf.transport.serial.path);
    try std.testing.expectEqual(wled_component.default_baud, shelf.transport.serial.baud);
    try std.testing.expect(app.wled_ctx.findStrip("nowhere") == null);
    try std.testing.expect(app.wled_ctx.findStrip("odd") == null);
}

test "httpServer does not start TD1 discovery without its configuration section" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const aio = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var app = try testApp(std.heap.smp_allocator, aio, &tmp);
    defer app.deinit(aio);
    app.td1_ctx.tty_root = root;
    _ = app.httpServer(aio);
    try std.testing.expect(app.td1_ctx.poll_thread == null);
}

test "setConfig validates TD1 baudrate and preserves rejected configuration until teardown" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    for ([_][]const u8{ "9600", "-1", "123456", "bad" }) |baud| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var cfg_buf: [96]u8 = undefined;
        const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
        var body: [64]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(aio, .{ .sub_path = cfg_path, .data = try std.fmt.bufPrint(&body, "[td1]\nbaudrate: {s}\n", .{baud}) });
        var app = try testApp(alloc, aio, &tmp);
        defer app.deinit(aio);
        if (std.mem.eql(u8, baud, "9600")) {
            try app.setConfig(aio, cfg_path);
            try std.testing.expectEqual(@as(u32, 9600), app.td1_ctx.baud);
        } else {
            if (app.setConfig(aio, cfg_path)) |_| return error.AcceptedInvalidBaud else |_| {}
            try std.testing.expect(app.cfg != null);
            try std.testing.expect(app.info.cfg == app.cfg);
        }
    }
}

test "setConfig [paneldue] processPanelDueLine strips checksummed file commands" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[paneldue]\nserial: paneldue-fixture\nenable_checksum: true\n" });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);

    const body = "N10 M32  plate.gco  ";
    var sum: u8 = 0;
    for (body) |c| sum ^= c;
    var core: [64]u8 = undefined;
    const checksummed = std.fmt.bufPrint(&core, "{s}*{d}", .{ body, sum }) catch unreachable;
    var wrapped: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&wrapped, "  {s}\r\n", .{checksummed}) catch unreachable;

    try app.paneldue.processLine(line);
    try std.testing.expectEqual(@as(usize, 2), app.paneldue.part_count);
    try std.testing.expectEqualStrings("M32", app.paneldue.parts[0]);
    try std.testing.expectEqualStrings("plate.gco", app.paneldue.parts[1]);

    const bare = "M98";
    sum = 0;
    for (bare) |c| sum ^= c;
    const m98 = std.fmt.bufPrint(&core, "{s}*{d}", .{ bare, sum }) catch unreachable;
    try app.paneldue.processLine(m98);
    try std.testing.expectEqual(@as(usize, 2), app.paneldue.part_count);
    try std.testing.expectEqualStrings("M98", app.paneldue.parts[0]);
    try std.testing.expectEqualStrings("", app.paneldue.parts[1]);

    try std.testing.expectError(error.InvalidChecksum, app.paneldue.processLine("N1 M30 my file.gco*0"));
}

test "setConfig [paneldue] keeps checksums on for a malformed enable_checksum" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[paneldue]\nserial: paneldue-fixture\nenable_checksum: maybe\n" });
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    try std.testing.expect(app.paneldue.enable_checksum);
}

test "setConfig preserves a rejected PanelDue config until teardown" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[paneldue]\nserial: paneldue-fixture\nbaud: 123456\n" });
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try std.testing.expectError(error.UnsupportedBaud, app.setConfig(io, cfg_path));
    const cfg = app.cfg.?;
    try std.testing.expect(app.info.cfg.? == cfg);
    try std.testing.expectEqualStrings("123456", cfg.get("paneldue", "baud").?);
    try std.testing.expectEqualStrings(cfg_path, app.info.config_file_path.?);
}

test "setConfig loads an analysis platform and a notifier record" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data =
        \\[analysis]
        \\platform: linux
        \\
        \\[notifier desk]
        \\url: tgram://token/chat
        \\title: hi
        \\body: there
        \\body_format: text
        \\events: complete, error
        \\
        \\[notifier bad-url]
        \\url: relative/path
        \\events: *
        \\
        \\[notifier bad-format]
        \\url: json://host
        \\body_format: xml
        \\events: *
        \\
    });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    try std.testing.expect(std.mem.endsWith(u8, app.analysis_ctx.estimator_path, "klipper_estimator_linux"));
    try std.testing.expect(std.mem.endsWith(u8, app.analysis_ctx.estimator_config, "default_estimator_cfg.json"));

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const status = try analysis_component.handleStatus(@ptrCast(app.analysis_ctx), .null, a);
    try std.testing.expectEqualStrings("klipper_estimator_linux", status.object.get("estimator_executable").?.string);
    try std.testing.expectEqual(false, status.object.get("estimator_ready").?.bool);
    try std.testing.expectEqual(true, status.object.get("using_default_config").?.bool);

    const listed = try notifier_component.handleNotifierList(@ptrCast(app.notifier_ctx), .null, a);
    const items = listed.object.get("notifiers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("desk", items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("tgram://token/chat", items[0].object.get("url").?.string);
    try std.testing.expectEqual(@as(usize, 2), items[0].object.get("events").?.array.items.len);
    var params: std.json.ObjectMap = .empty;
    try params.put(a, "name", .{ .string = "desk" });
    try std.testing.expectError(error.AppriseNotAvailable, notifier_component.handleNotifierTest(@ptrCast(app.notifier_ctx), .{ .object = params }, a));
}

test "analysis config validates timeout platform and checked custom paths" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, aio, &tmp);
    defer app.deinit(aio);
    try tmp.dir.writeFile(aio, .{ .sub_path = "config/my..settings.json", .data = "{}" });
    for ([_][]const u8{
        "[analysis]\nplatform: unsupported\n",
        "[analysis]\nestimator_timeout: 0\n",
        "[analysis]\nestimator_timeout: -1\n",
        "[analysis]\nestimator_timeout: invalid\n",
        "[analysis]\nestimator_config: ../outside.json\n",
    }) |text| {
        var cfg = config_helper.ConfigParser.init(alloc);
        defer cfg.deinit();
        try cfg.parseString(text, "analysis.cfg");
        try std.testing.expectError(error.InvalidValue, app.applyAnalysisConfig(&cfg));
    }
    var cfg = config_helper.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString("[analysis]\nestimator_timeout: 7\nestimator_config: my..settings.json\n", "analysis.cfg");
    try app.applyAnalysisConfig(&cfg);
    try std.testing.expectEqual(@as(i64, 7), app.analysis_ctx.timeout.toSeconds());
    try std.testing.expect(std.mem.endsWith(u8, app.analysis_ctx.estimator_config, "/config/my..settings.json"));
    try std.testing.expect(app.analysis_ctx.core == null);
    try std.testing.expect(app.analysis_ctx.runner == null);
}

test "fuzz analysis config accepts positive estimator timeouts without changing runner ownership" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var app = try testApp(std.testing.allocator, std.testing.io, &tmp);
            defer app.deinit(std.testing.io);
            const seconds = smith.valueRangeAtMostWithHash(i64, -2, 30, 0);
            var body: [128]u8 = undefined;
            var cfg = config_helper.ConfigParser.init(std.testing.allocator);
            defer cfg.deinit();
            try cfg.parseString(try std.fmt.bufPrint(&body, "[analysis]\nestimator_timeout: {d}\nplatform: rpi\n", .{seconds}), "analysis.cfg");
            if (seconds <= 0) {
                try std.testing.expectError(error.InvalidValue, app.applyAnalysisConfig(&cfg));
            } else {
                try app.applyAnalysisConfig(&cfg);
                try std.testing.expectEqual(seconds, app.analysis_ctx.timeout.toSeconds());
                try std.testing.expect(std.mem.endsWith(u8, app.analysis_ctx.estimator_path, "klipper_estimator_rpi"));
            }
            try std.testing.expect(app.analysis_ctx.runner == null);
            try std.testing.expect(app.analysis_ctx.core == null);
        }
    }.run, .{});
}

test "setConfig reads Moonraker's [mqtt] address and defaults" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data =
        \\[mqtt]
        \\address: broker.lan
        \\default_qos: 1
        \\enable_tls: true
        \\
    });
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);
    const mqtt = app.mqtt_ctx.config.?;
    try std.testing.expectEqualStrings("broker.lan", mqtt.address);
    try std.testing.expectEqual(@as(u16, 1883), mqtt.port);
    try std.testing.expectEqual(@as(u2, 1), mqtt.api_qos);
    try std.testing.expect(mqtt.enable_tls and mqtt.enable_moonraker_api);
    try std.testing.expect(mqtt.instance_name.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, mqtt.status_topic, "/moonraker/status"));

    // Without `address` MQTT stays unconfigured.
    var app2 = try testApp(alloc, io, &tmp);
    defer app2.deinit(io);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[mqtt]\nhost: broker.lan\n" });
    try app2.setConfig(io, cfg_path);
    try std.testing.expect(app2.mqtt_ctx.config == null);
}

test "canonicalPath follows a directory symlink" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real/config");
    const target = try tmp.dir.realPathFileAlloc(io, "real", alloc);
    defer alloc.free(target);
    try tmp.dir.symLink(io, target, "data", .{});
    const joined = try std.fs.path.join(alloc, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, "data", "config" });
    const got = try canonicalPath(alloc, io, joined);
    defer alloc.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "/real/config"));
}

test "registerKlipperRoots adds config_examples and docs when those directories exist" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var klipper = std.testing.tmpDir(.{});
    defer klipper.cleanup();
    try klipper.dir.createDirPath(io, "config");
    try klipper.dir.createDirPath(io, "docs");
    const base = try klipper.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(base);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    app.file_ctx.setIo(io);
    try std.testing.expectEqual(@as(usize, 3), app.file_roots.len);
    app.registerKlipperRoots(base);
    try std.testing.expectEqual(@as(usize, 5), app.file_roots.len);
    try std.testing.expectEqualStrings("config_examples", app.file_roots[3].name);
    try std.testing.expect(std.mem.endsWith(u8, app.file_roots[3].path, "/config"));
    try std.testing.expectEqualStrings("docs", app.file_roots[4].name);
    try std.testing.expect(!app.file_roots[3].full_access);
    App.onKlipperPath(@ptrCast(&app), base);
    try std.testing.expectEqual(@as(usize, 5), app.file_roots.len);
    try std.testing.expectEqual(@as(u8, 5), app.info.directory_count);
    try std.testing.expectEqualStrings("config_examples", app.info.directory_names[3]);
    try std.testing.expectEqualStrings("docs", app.info.directory_names[4]);
    app.registerKlipperRoots("/no/such/klipper");
    app.registerKlipperRoots("/no/such/klipper/../etc");
    try std.testing.expectEqual(@as(usize, 5), app.file_roots.len);
}

test "setConfig parses [sensor <name>] and wires topic + state_response_template" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [64]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[sensor chamber]\n" ++
        "type: mqtt\n" ++
        "state_topic: test/chamber\n" ++
        "name: Chamber Air\n" ++
        "sensor_store_size: 5\n" ++
        "parameter_temp:\n  units = C\n  description = Chamber temperature\n" ++
        "history_field_peak:\n  parameter = temp\n  strategy = maximum\n  units = C\n  init_tracker = true\n  exclude_paused = true\n  report_total = true\n  report_maximum = true\n  precision = 2\n" ++
        "state_response_template: {% set d = payload|fromjson %}{ set_result(\"temp\", d.t|float) }\n" });

    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);
    try app.setConfig(io, cfg_path);

    // Sensor registered with its topic + template.
    const s = app.sensor_ctx.findSensor("chamber") orelse return error.SensorNotRegistered;
    try std.testing.expectEqualStrings("test/chamber", s.state_topic.?);
    try std.testing.expect(s.state_response_template != null);
    try std.testing.expectEqualStrings("Chamber Air", s.name);
    try std.testing.expectEqual(@as(usize, 5), s.store_size);

    // A payload on its topic flows through the template into a measurement.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    app.sensor_ctx.ingestMqttMessage("test/chamber", "{\"t\": 42.5}", arena.allocator());
    try std.testing.expectEqual(@as(f64, 42.5), s.last_measurements.get("temp").?);
    const a = arena.allocator();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"sensor\":\"chamber\",\"extended\":true}", .{});
    const extended = try sensor_component.handleSensorInfo(app.sensor_ctx, params, a);
    const parameter = extended.object.get("parameter_info").?.array.items[0].object;
    try std.testing.expectEqualStrings("Chamber temperature", parameter.get("description").?.string);
    const field = extended.object.get("history_fields").?.array.items[0].object;
    try std.testing.expectEqualStrings("sensor chamber", field.get("provider").?.string);
    try std.testing.expectEqualStrings("temp", field.get("parameter").?.string);
    try std.testing.expect(field.get("init_tracker").?.bool);
    try std.testing.expect(!app.history_ctx.aux_fields.items[0].has_value);

    const Event = @import("components/job_state.zig").JobEvent;
    app.history_ctx.onJobStateChanged(Event.started, .empty, .empty);
    app.sensor_ctx.ingestMqttMessage("test/chamber", "{\"t\":40}", a);
    app.history_ctx.onJobStateChanged(Event.paused, .empty, .empty);
    app.sensor_ctx.ingestMqttMessage("test/chamber", "{\"t\":99}", a);
    app.history_ctx.onJobStateChanged(Event.resumed, .empty, .empty);
    app.sensor_ctx.ingestMqttMessage("test/chamber", "{\"t\":43.123}", a);
    app.history_ctx.onJobStateChanged(Event.complete, .empty, .empty);
    const totals = try history_component.handleTotals(app.history_ctx, .null, a);
    const aux = totals.object.get("auxiliary_totals").?.array.items[0].object;
    try std.testing.expectEqualStrings("peak", aux.get("field").?.string);
    try std.testing.expectEqual(@as(f64, 43.12), aux.get("total").?.float);
    try std.testing.expectEqual(@as(f64, 43.12), aux.get("maximum").?.float);
}

test "live MQTT sensor bridge replaces readings, samples history and reports broker disconnect" {
    const alloc = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(alloc, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const Broker = @import("components/mqtt_client.zig").TestBroker;
    var broker = try Broker.bind(io);
    defer broker.deinit();
    const Fixture = struct {
        fn brokerRun(server: *Broker, done: *std.Io.Event) void {
            defer done.set(server.io);
            server.run(2); // Online status and the sensor's subscription.
        }
        fn received(instance: *App, expected: f64) bool {
            const sensor = instance.sensor_ctx.findSensor("env").?;
            return (sensor.last_measurements.get("temperature") orelse return false) == expected;
        }
        fn disconnected(instance: *App) bool {
            const sensor = instance.sensor_ctx.findSensor("env").?;
            return std.mem.eql(u8, sensor.error_state orelse return false, "MQTT Disconnected") and sensor.last_measurements.count() == 0;
        }
        fn sampled(instance: *App) bool {
            const sensor = instance.sensor_ctx.findSensor("env").?;
            return if (sensor.history.get("temperature")) |ring| ring.len > 0 else false;
        }
    };
    var broker_done: std.Io.Event = .unset;
    var task = try io.concurrent(Fixture.brokerRun, .{ &broker, &broker_done });
    defer task.cancel(io);
    var instance = try testApp(alloc, io, &tmp);
    defer instance.deinit(io);
    instance.td1_ctx.tty_root = instance.datadir;
    instance.td1_ctx.dev_prefix = instance.datadir;
    _ = try instance.sensor_ctx.addSensor("env", .{ .type = "mqtt", .state_topic = "test/environment", .store_size = 3 });
    try instance.mqtt_ctx.setConfig(.{ .address = "127.0.0.1", .port = broker.port(), .instance_name = "sensor-fixture", .enable_moonraker_api = false });
    _ = instance.httpServer(io);
    try std.testing.expect(@import("util/sleep.zig").untilStopped(io, .fromSeconds(2), &broker_done));
    task.await(io);
    try std.testing.expectEqualStrings("test/environment", broker.last_subscribe[0..broker.last_subscribe_len]);

    var request = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer request.deinit();
    const a = request.allocator();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"sensor\":\"env\"}", .{});
    for ([_][]const u8{ "{\"temperature\":20,\"humidity\":40}", "{\"temperature\":21}" }, [_]f64{ 20, 21 }) |payload, expected| {
        try broker.injectPublish("test/environment", payload);
        var received = false;
        for (0..400) |_| {
            received = instance.core.run(io, Fixture.received, .{ &instance, expected });
            if (received) break;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        try std.testing.expect(received);
    }
    const info = try instance.core.run(io, sensor_component.handleSensorInfo, .{ @as(*anyopaque, instance.sensor_ctx), params, a });
    try std.testing.expectEqual(@as(f64, 21), info.object.get("values").?.object.get("temperature").?.float);
    try std.testing.expect(info.object.get("values").?.object.get("humidity") == null);
    const before = try instance.core.run(io, sensor_component.handleSensorMeasurements, .{ @as(*anyopaque, instance.sensor_ctx), params, a });
    try std.testing.expectEqual(@as(usize, 0), before.object.get("env").?.object.count());
    try instance.sensor_ctx.startSampler();
    var timer_sampled = false;
    for (0..600) |_| {
        timer_sampled = instance.core.run(io, Fixture.sampled, .{&instance});
        if (timer_sampled) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    instance.sensor_ctx.stopSampler();
    try std.testing.expect(timer_sampled);
    instance.core.run(io, SensorCtx.sampleSensors, .{ instance.sensor_ctx, a });
    instance.core.run(io, SensorCtx.sampleSensors, .{ instance.sensor_ctx, a });
    const sampled = try instance.core.run(io, sensor_component.handleSensorMeasurements, .{ @as(*anyopaque, instance.sensor_ctx), params, a });
    const readings = sampled.object.get("env").?.object.get("temperature").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), readings.len);
    try std.testing.expectEqual(@as(f64, 21), readings[1].float);
    try broker.stream.?.shutdown(io, .both);
    var disconnected = false;
    for (0..400) |_| {
        disconnected = instance.core.run(io, Fixture.disconnected, .{&instance});
        if (disconnected) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(disconnected);
    const after = try instance.core.run(io, sensor_component.handleSensorInfo, .{ @as(*anyopaque, instance.sensor_ctx), params, a });
    try std.testing.expectEqual(@as(usize, 0), after.object.get("values").?.object.count());
}

test "initWithStore: file backend builds + database round-trips" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dp = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dp);

    var app = try App.initWithStore(alloc, .file, io, null, dp);
    defer app.deinit(io);
    try std.testing.expect(app.db_store == .file);
    // Without a db_path the store lives under <datadir>/database.
    try tmp.dir.access(io, "database", .{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try app.db_ctx.store.insertItem(a, "moonraker", "file_manager.version", .{ .integer = 7 });
    const got = (try app.db_ctx.store.getItem(a, "moonraker", "file_manager.version")).?;
    try std.testing.expectEqual(@as(i64, 7), got.integer);
}

test "initWithStore: data_path sets the datadir (Moonraker -d) and default database" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dp = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dp);

    var app = try App.initWithStore(alloc, .sqlite, std.testing.io, null, dp);
    defer app.deinit(io);
    try std.testing.expectEqualStrings(dp, app.datadir);
    try std.testing.expect(!app.temp_datadir);
    try tmp.dir.access(io, "database/moonraker-sql.db", .{});
}

test "initWithStore: relative data_path is rejected at startup" {
    const alloc = std.testing.allocator;
    // A relative -d would resolve against an unpredictable cwd — fail-fast.
    try std.testing.expectError(error.InvalidDataPath, App.initWithStore(alloc, .sqlite, std.testing.io, null, "relative/datadir"));
}

test "initWithStore: nested absolute data_path is created (mkdir -p)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    // Parent does not exist yet — ensureDirPathRaw must create the whole chain,
    // and each gcodes/config/logs root under it (mkdirChecked). If any step
    // failed, initWithStore would return an error rather than reach here.
    const dp = try std.fs.path.join(alloc, &.{ root, "a", "b", "c" });
    defer alloc.free(dp);
    var app = try App.initWithStore(alloc, .sqlite, std.testing.io, null, dp);
    defer app.deinit(io);
    try std.testing.expectEqualStrings(dp, app.datadir);
    // The gcodes root beneath the nested datadir must now be openable.
    var d = try tmp.dir.openDir(io, "a/b/c/gcodes", .{});
    d.close(io);
}

test "App.init registers WS-only methods in the dispatcher" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);

    try std.testing.expect(app.dispatcher.methods.get("server.connection.identify") != null);
    try std.testing.expect(app.dispatcher.methods.get("server.websocket.id") != null);
}

test "App.init: dispatcher has exactly the expected methods" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, io, &tmp);
    defer app.deinit(io);

    const expected = [_][]const u8{
        // Core
        "server.info",
        "server.config",
        // Database public
        "server.database.list",
        "server.database.get_item",
        "server.database.post_item",
        "server.database.delete_item",
        "server.database.compact",
        "server.database.post_backup",
        "server.database.delete_backup",
        "server.database.restore",
        // Database debug
        "debug.database.list",
        "debug.database.get_item",
        "debug.database.post_item",
        "debug.database.delete_item",
        "debug.database.table",
        // History
        "server.history.list",
        "server.history.totals",
        "server.history.reset_totals",
        "server.history.get_job",
        "server.history.delete_job",
        // Job queue
        "server.job_queue.status",
        "server.job_queue.pause",
        "server.job_queue.start",
        "server.job_queue.jump",
        "server.job_queue.post_job",
        "server.job_queue.delete_job",
        "pause_job_queue",
        "start_job_queue",
        // Announcements
        "server.announcements.list",
        "server.announcements.dismiss",
        "server.announcements.update",
        "server.announcements.post_feed",
        "server.announcements.delete_feed",
        "server.announcements.feeds",
        // Data store
        "server.gcode_store",
        "server.temperature_store",
        // Server misc
        "server.restart",
        "server.logs.rollover",
        // Notifier
        "server.notifiers.list",
        "debug.notifiers.test",
        "notify",
        // Webcam (item endpoint is verb-prefixed)
        "server.webcams.list",
        "server.webcams.get_item",
        "server.webcams.post_item",
        "server.webcams.delete_item",
        "server.webcams.test",
        // Sensor
        "server.sensors.list",
        "server.sensors.info",
        "server.sensors.measurements",
        // Authorization (access.*)
        "access.login",
        "access.logout",
        "access.refresh_jwt",
        "access.get_user",
        "access.post_user",
        "access.delete_user",
        "access.users.list",
        "access.user.password",
        "access.get_api_key",
        "access.post_api_key",
        "access.oneshot_token",
        "access.info",
        // Spoolman
        "server.spoolman.get_spool_id",
        "server.spoolman.post_spool_id",
        "server.spoolman.proxy",
        "server.spoolman.status",
        // MQTT
        "server.mqtt.publish",
        "server.mqtt.subscribe",
        "server.mqtt.publish_mqtt_topic",
        // Extensions
        "server.extensions.list",
        "server.extensions.request",
        "connection.register_remote_method",
        "connection.send_event",
        // Analysis
        "server.analysis.status",
        "server.analysis.estimate",
        "server.analysis.process",
        "server.analysis.dump_config",
        // File manager (server.files.*)
        "server.files.roots",
        "server.files.list",
        "server.files.metadata",
        "server.files.metascan",
        "server.files.thumbnails",
        "server.files.get_directory",
        "server.files.post_directory",
        "server.files.delete_directory",
        "server.files.move",
        "server.files.copy",
        "server.files.zip",
        "server.files.delete_file",
        // Machine (machine.* + machine.proc_stats)
        "machine.system_info",
        "machine.proc_stats",
        "machine.reboot",
        "machine.shutdown",
        "machine.services.restart",
        "machine.services.stop",
        "machine.services.start",
        "machine.sudo.info",
        "machine.sudo.password",
        "machine.peripherals.usb",
        "machine.peripherals.serial",
        "machine.peripherals.video",
        "machine.peripherals.canbus",
        // Update manager (machine.update.*)
        "machine.update.status",
        "machine.update.refresh",
        "machine.update.upgrade",
        "machine.update.full",
        "machine.update.moonraker",
        "machine.update.klipper",
        "machine.update.system",
        "machine.update.client",
        "machine.update.recover",
        "machine.update.rollback",
        // Power device (machine.device_power.*)
        "machine.device_power.devices",
        "machine.device_power.status",
        "machine.device_power.on",
        "machine.device_power.off",
        "machine.device_power.get_device",
        "machine.device_power.post_device",
        "set_device_power",
        // WLED (machine.wled.*)
        "machine.wled.strips",
        "machine.wled.status",
        "machine.wled.on",
        "machine.wled.off",
        "machine.wled.toggle",
        "machine.wled.get_strip",
        "machine.wled.post_strip",
        // TD-1 (machine.td1.*)
        "machine.td1.data",
        "machine.td1.reboot",
        // Printer (printer.* — Klippy-proxied)
        "printer.print.start",
        "printer.print.pause",
        "printer.print.resume",
        "printer.print.cancel",
        "printer.restart",
        "printer.firmware_restart",
        "printer.emergency_stop",
        // Klipper-proxied (is_remote): single dotted method, GET|POST route.
        "printer.info",
        "printer.objects.list",
        "printer.objects.query",
        "printer.objects.subscribe",
        "printer.query_endstops.status",
        "printer.gcode.script",
        "printer.gcode.help",
        // WS-only stubs
        "server.connection.identify",
        "server.websocket.id",
        "set_wled_state",
        "set_wled",
        "spoolman_set_active_spool",
    };
    try std.testing.expectEqual(@as(usize, expected.len), app.dispatcher.methods.count());
    for (expected) |m| {
        try std.testing.expect(app.dispatcher.methods.get(m) != null);
    }
}

test "App.init idempotency: double init+deinit does not corrupt allocator" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two independent App instances must each init and deinit cleanly.
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    var a = try testApp(alloc, io, &tmp_a);
    var b = try testApp(alloc, io, &tmp_b);
    defer a.deinit(io);
    defer b.deinit(io);

    try std.testing.expect(a.dispatcher.methods.get("server.info") != null);
    try std.testing.expect(b.dispatcher.methods.get("server.info") != null);
}

test "fuzz_app: App.init/deinit cycle never crashes" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            // Use the smith to vary iterations but App.init has no fuzz-able parameters.
            var b: [4]u8 = undefined;
            smith.bytesWithHash(&b, 0);
            const _count = b[0]; // Suppress "never mutated" warning by reading.
            _ = _count;

            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var app = try testApp(std.heap.smp_allocator, io, &tmp);
            app.deinit(io);
        }
    }.run, .{});
}

test "App initialization frees partial state on allocation failure" {
    const aio = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var baseline = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var complete = try App.initWithStore(baseline.allocator(), .sqlite, aio, ":memory:", path);
    const count = baseline.alloc_index;
    complete.deinit(aio);
    for (0..count) |index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        if (App.initWithStore(failing.allocator(), .sqlite, aio, ":memory:", path)) |built| {
            var partial = built;
            partial.deinit(aio);
        } else |_| {}
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "setConfig rejects a partial parse without applying any options" {
    const aio = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(alloc, aio, &tmp);
    defer app.deinit(aio);
    try tmp.dir.writeFile(aio, .{ .sub_path = "bad.conf", .data = "[server]\nklippy_uds_address: /unwanted\n[broken\n" });
    const path = try tmp.dir.realPathFileAlloc(aio, "bad.conf", alloc);
    defer alloc.free(path);
    try std.testing.expectError(error.ParseError, app.setConfig(aio, path));
    try std.testing.expect(app.cfg == null);
    try std.testing.expect(app.info.cfg == null);
    try std.testing.expect(!app.klippy_uds_owned);
    try tmp.dir.writeFile(aio, .{ .sub_path = "bad.conf", .data = "[server]\n" });
    try app.setConfig(aio, path);
    try std.testing.expectError(error.ConfigAlreadyLoaded, app.setConfig(aio, path));
}

test "startup accepts symlinked file roots and database parents" {
    const alloc = std.testing.allocator;
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(aio, "real", .default_dir);
    try tmp.dir.symLink(aio, "real", "config", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(aio, ".", alloc);
    defer alloc.free(root);
    const database = try std.fs.path.join(alloc, &.{ root, "config", "test.db" });
    defer alloc.free(database);
    var app = try App.initWithStore(alloc, .sqlite, aio, database, root);
    defer app.deinit(aio);
    try std.testing.expect(std.mem.endsWith(u8, app.file_roots[0].path, "/real"));
    const FileStore = @import("store/file_store.zig").FileStore;
    const path = try std.fs.path.join(alloc, &.{ root, "config" });
    defer alloc.free(path);
    var store = try FileStore.open(aio, path);
    defer store.deinit();
}

test "Klipper remote methods map to Moonraker's JSON-RPC requests" {
    const alloc = std.testing.allocator;
    var params: std.json.ObjectMap = .empty;
    defer params.deinit(alloc);
    try params.put(alloc, "device", .{ .string = "psu" });
    try params.put(alloc, "state", .{ .string = "TRUE" });
    const power = (try remoteMethodRequest(alloc, "set_device_power", .{ .object = params })).?;
    defer alloc.free(power);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"machine.device_power.post_device","params":{"device":"psu","action":"on"},"id":0}
    , power);
    // power.py ignores unknown states; unknown methods are dropped.
    try params.put(alloc, "state", .{ .string = "blink" });
    try std.testing.expect(try remoteMethodRequest(alloc, "set_device_power", .{ .object = params }) == null);
    try std.testing.expect(try remoteMethodRequest(alloc, "no_such_method", .{ .object = params }) == null);
    const mqtt = (try remoteMethodRequest(alloc, "publish_mqtt_topic", .null)).?;
    defer alloc.free(mqtt);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"server.mqtt.publish_mqtt_topic","params":{},"id":0}
    , mqtt);
    params.clearRetainingCapacity();
    try params.put(alloc, "name", .{ .string = "desk" });
    try params.put(alloc, "message", .{ .string = "done" });
    const notification = (try remoteMethodRequest(alloc, "notify", .{ .object = params })).?;
    defer alloc.free(notification);
    const parsed_notification = try std.json.parseFromSlice(std.json.Value, alloc, notification, .{});
    defer parsed_notification.deinit();
    try std.testing.expectEqualStrings("notify", parsed_notification.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("desk", parsed_notification.value.object.get("params").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("done", parsed_notification.value.object.get("params").?.object.get("message").?.string);
    try std.testing.expectEqualStrings("toggle", devicePowerAction(.{ .string = "Toggle" }).?);
    try std.testing.expectEqualStrings("off", devicePowerAction(.{ .bool = false }).?);
    try std.testing.expect(devicePowerAction(.{ .integer = 1 }) == null);
}

test "fuzz remoteMethodRequest: any method and kwargs give valid JSON or null" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const alloc = std.testing.allocator;
            var buf: [24]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const names = klippy_remote_methods ++ [_][]const u8{"unknown"};
            var params: std.json.ObjectMap = .empty;
            defer params.deinit(alloc);
            try params.put(alloc, "device", .{ .string = buf[0..8] });
            try params.put(alloc, "state", .{ .string = buf[8..] });
            const req = (try remoteMethodRequest(alloc, names[buf[0] % names.len], .{ .object = params })) orelse return;
            defer alloc.free(req);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, req, .{});
            parsed.deinit();
        }
    }.run, .{});
}

test "setParsedConfig consumes the parser when path allocation fails" {
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var app = try testApp(alloc, aio, &tmp);
    defer app.deinit(aio);
    const cfg = try alloc.create(config_helper.ConfigParser);
    cfg.* = config_helper.ConfigParser.init(alloc);
    try cfg.parseString("[server]\nuse_xheaders: false\n", "startup.conf");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, app.setParsedConfig(aio, "startup.conf", cfg));
    try std.testing.expect(app.cfg == null);
    try std.testing.expect(app.info.cfg == null);
    try std.testing.expect(app.use_xheaders);
}

const RemoteCallGate = struct {
    io: std.Io,
    ready: std.Io.Semaphore = .{},
    release: std.Io.Event = .unset,
    fast_done: std.Io.Event = .unset,
    active: std.atomic.Value(usize) = .init(0),
    started: std.atomic.Value(usize) = .init(0),
    finished: std.atomic.Value(usize) = .init(0),
    exceeded_limit: std.atomic.Value(bool) = .init(false),

    fn handle(ctx: *anyopaque, params: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const active = self.active.fetchAdd(1, .seq_cst) + 1;
        defer _ = self.active.fetchSub(1, .seq_cst);
        defer _ = self.finished.fetchAdd(1, .seq_cst);
        if (active > 16) self.exceeded_limit.store(true, .seq_cst);
        _ = self.started.fetchAdd(1, .seq_cst);
        self.ready.post(self.io);
        const block = params.object.get("block").?.bool;
        if (block) try self.release.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) else self.fast_done.set(self.io);
        return .null;
    }

    fn enqueue(self: *@This(), app: *App, block: bool) !void {
        const request = try std.json.Stringify.valueAlloc(app.alloc, .{
            .jsonrpc = "2.0",
            .method = "test.remote",
            .params = .{ .block = block },
            .id = 0,
        }, .{});
        errdefer app.alloc.free(request);
        try app.remote_calls.putOne(self.io, request);
    }

    fn start(self: *@This(), app: *App) !void {
        try app.dispatcher.registerEntry("test.remote", .{ .ctx = self, .handler = handle, .off_core = true });
        app.dispatcher.setRuntime(app.core, self.io);
        app.remote_calls = .init(&app.remote_call_buf);
        app.remote_worker = try self.io.concurrent(remoteWorker, .{ app, self.io });
    }
};

test "remote worker runs a second call while the first is stalled and joins on teardown" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer std.debug.assert(owned.deinit() == 0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(owned.allocator(), io, &tmp);
    var live = true;
    defer if (live) app.deinit(io);
    var gate: RemoteCallGate = .{ .io = io };
    try gate.start(&app);
    try gate.enqueue(&app, true);
    try gate.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try gate.enqueue(&app, false);
    try gate.fast_done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } });
    try std.testing.expect(gate.active.load(.seq_cst) >= 1);
    app.deinit(io);
    live = false;
    try std.testing.expectEqual(@as(usize, 0), gate.active.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), gate.finished.load(.seq_cst));
}

test "remote worker bounds active calls and queued ownership during cancellation" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer std.debug.assert(owned.deinit() == 0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(owned.allocator(), io, &tmp);
    var live = true;
    defer if (live) app.deinit(io);
    var gate: RemoteCallGate = .{ .io = io };
    try gate.start(&app);
    for (0..16) |_| try gate.enqueue(&app, true);
    for (0..16) |_| try gate.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expectEqual(@as(usize, 16), gate.active.load(.seq_cst));
    for (0..remote_call_queue_len) |_| try gate.enqueue(&app, true);
    const extra = try app.alloc.dupe(u8, "not queued");
    const inserted = try app.remote_calls.put(io, &.{extra}, 0);
    if (inserted == 0) app.alloc.free(extra);
    try std.testing.expectEqual(@as(usize, 0), inserted);
    app.deinit(io);
    live = false;
    try std.testing.expect(!gate.exceeded_limit.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), gate.active.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 16), gate.finished.load(.seq_cst));
}

test "remote worker frees rejected tasks when native concurrency is exhausted" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20, .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer std.debug.assert(owned.deinit() == 0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(owned.allocator(), io, &tmp);
    defer app.deinit(io);
    var gate: RemoteCallGate = .{ .io = io };
    try gate.start(&app);
    for (0..remote_call_queue_len) |_| try gate.enqueue(&app, false);
    app.remote_calls.close(io);
    app.remote_worker.?.await(io);
    app.remote_worker = null;
    try std.testing.expectEqual(@as(usize, 0), gate.started.load(.seq_cst));
}

test "fuzz remote worker shutdown joins tasks and drains every owned request" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const count = smith.valueRangeAtMostWithHash(u8, 0, 8, 0);
            const concurrency = smith.valueRangeAtMostWithHash(u8, 1, 5, 1);
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20, .concurrent_limit = .limited(concurrency) });
            defer threaded.deinit();
            const io = threaded.io();
            var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
            defer std.debug.assert(owned.deinit() == 0);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var app = try testApp(owned.allocator(), io, &tmp);
            var live = true;
            defer if (live) app.deinit(io);
            var gate: RemoteCallGate = .{ .io = io };
            try gate.start(&app);
            for (0..count) |index| try gate.enqueue(&app, index % 2 == 0);
            app.deinit(io);
            live = false;
            try std.testing.expectEqual(@as(usize, 0), gate.active.load(.seq_cst));
            try std.testing.expectEqual(gate.started.load(.seq_cst), gate.finished.load(.seq_cst));
            try std.testing.expect(!gate.exceeded_limit.load(.seq_cst));
        }
    }.run, .{});
}

test "remote worker reuses permits after calls finish" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer std.debug.assert(owned.deinit() == 0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(owned.allocator(), io, &tmp);
    defer app.deinit(io);
    var gate: RemoteCallGate = .{ .io = io };
    try gate.start(&app);
    for (0..16) |_| try gate.enqueue(&app, true);
    for (0..16) |_| try gate.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    for (0..8) |_| try gate.enqueue(&app, false);
    gate.release.set(io);
    for (0..8) |_| try gate.ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    app.remote_calls.close(io);
    app.remote_worker.?.await(io);
    app.remote_worker = null;
    try std.testing.expectEqual(@as(usize, 24), gate.finished.load(.seq_cst));
    try std.testing.expect(!gate.exceeded_limit.load(.seq_cst));
}

test "remote worker teardown drains pending calls under canceled lock contention" {
    const Probe = struct {
        io: std.Io,
        app: *App,
        live: *bool,
        kick: std.Io.Event = .unset,
        locked: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        ready: std.Io.Event = .unset,
        park: std.Io.Event = .unset,
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };

        fn hold(self: *@This()) void {
            self.kick.waitTimeout(self.io, timeout) catch return;
            self.app.remote_calls.type_erased.mutex.lockUncancelable(self.io);
            defer self.app.remote_calls.type_erased.mutex.unlock(self.io);
            self.locked.set(self.io);
            self.release.waitTimeout(self.io, timeout) catch return;
        }
        fn worker(self: *@This()) void {
            self.park.waitTimeout(self.io, timeout) catch {};
            self.kick.set(self.io);
            self.locked.waitTimeout(self.io, timeout) catch return;
        }
        fn releaseAfterLock(self: *@This()) void {
            self.locked.waitTimeout(self.io, timeout) catch return;
            self.io.sleep(.fromMilliseconds(20), .awake) catch return;
            self.release.set(self.io);
        }
        fn teardown(self: *@This()) void {
            self.ready.set(self.io);
            self.park.waitTimeout(self.io, timeout) catch |err| {
                if (err == error.Canceled) self.io.recancel();
            };
            self.app.deinit(self.io);
            self.live.* = false;
        }
    };
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 1 << 20 });
    defer threaded.deinit();
    const io = threaded.io();
    var owned = std.heap.SafeAllocator.init(std.heap.smp_allocator, .{});
    defer std.debug.assert(owned.deinit() == 0);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try testApp(owned.allocator(), io, &tmp);
    var live = true;
    defer if (live) app.deinit(io);
    app.remote_calls = .init(&app.remote_call_buf);
    const req = try app.alloc.dupe(u8, "owned pending call");
    try app.remote_calls.putOne(io, req);
    var probe: Probe = .{ .io = io, .app = &app, .live = &live };
    var holder = try io.concurrent(Probe.hold, .{&probe});
    defer holder.cancel(io);
    var releaser = try io.concurrent(Probe.releaseAfterLock, .{&probe});
    defer releaser.cancel(io);
    app.remote_worker = try io.concurrent(Probe.worker, .{&probe});
    var teardown = try io.concurrent(Probe.teardown, .{&probe});
    defer teardown.cancel(io);
    defer probe.release.set(io);
    try probe.ready.waitTimeout(io, Probe.timeout);
    teardown.cancel(io);
    holder.await(io);
    releaser.await(io);
}

test "setConfig renders MQTT secrets and selects protocol and status configuration" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg_buf: [96]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cfg_buf, "{s}/{s}/moonraker.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    try tmp.dir.writeFile(io, .{ .sub_path = "moonraker.secrets", .data = "{\"mqtt\":{\"username\":\"user\",\"password\":\"pass\"}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "password", .data = "file value\n" });
    for ([_][]const u8{ "v3.1", "v3.1.1", "v5" }) |protocol| {
        var source: std.Io.Writer.Allocating = .init(alloc);
        defer source.deinit();
        try source.writer.print(
            "[mqtt]\naddress: broker.lan\nmqtt_protocol: {s}\nusername: {{secrets.mqtt.username}}\npassword: {{secrets.mqtt.password}}\npassword_file: ~/password\nstatus_objects:\n  extruder=temperature,target\n  heater_bed\nstatus_interval: 0.5\npublish_split_status: true\n",
            .{protocol},
        );
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = source.written() });
        var app = try testApp(alloc, io, &tmp);
        defer app.deinit(io);
        try app.mqtt_ctx.setHomeDirectory(app.datadir);
        try app.setConfig(io, cfg_path);
        const mqtt = app.mqtt_ctx.config.?;
        try std.testing.expectEqual(try @import("components/mqtt_proto.zig").Protocol.parse(protocol), mqtt.protocol);
        try std.testing.expectEqualStrings("user", mqtt.username.?);
        try std.testing.expectEqualStrings("pass", mqtt.password.?);
        if (mqtt.protocol == .v31) {
            try std.testing.expectEqual(@as(usize, 22), mqtt.client_id.len);
            for (mqtt.client_id) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte));
        }
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const selectors = try app.mqtt_ctx.statusSubscription(arena.allocator());
        try std.testing.expectEqual(@as(usize, 2), selectors.object.count());
        try std.testing.expectEqual(@as(usize, 2), selectors.object.get("extruder").?.array.items.len);
        try std.testing.expect(selectors.object.get("heater_bed").? == .null);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[mqtt]\naddress: broker.lan\nmqtt_protocol: unsupported\n" });
    var invalid = try testApp(alloc, io, &tmp);
    defer invalid.deinit(io);
    try invalid.setConfig(io, cfg_path);
    try std.testing.expect(invalid.mqtt_ctx.config == null);
}

test "setConfig loads Spoolman sync rate and rejects missing or invalid options" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/spoolman.conf", .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path });
    const cases = .{
        .{ "[spoolman]\nserver: 127.0.0.1:1234\nsync_rate: 9\n", @as(?anyerror, null), @as(u32, 9) },
        .{ "[spoolman]\nserver: 127.0.0.1:1234\n", @as(?anyerror, null), @as(u32, 5) },
        .{ "[spoolman]\nsync_rate: 1\n", @as(?anyerror, error.NoOption), @as(u32, 5) },
        .{ "[spoolman]\nserver: http://\n", @as(?anyerror, error.InvalidUrl), @as(u32, 5) },
        .{ "[spoolman]\nserver: 127.0.0.1:1234\nsync_rate: 0\n", @as(?anyerror, error.InvalidSyncRate), @as(u32, 5) },
        .{ "[spoolman]\nserver: 127.0.0.1:1234\nsync_rate: bad\n", @as(?anyerror, error.InvalidValue), @as(u32, 5) },
    };
    inline for (cases) |case| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = case[0] });
        var instance = try testApp(std.testing.allocator, io, &tmp);
        defer instance.deinit(io);
        const result = instance.setConfig(io, path);
        if (case[1]) |err| try std.testing.expectError(err, result) else try result;
        try std.testing.expectEqual(case[2], instance.spoolman_ctx.sync_rate_seconds);
        try std.testing.expect(instance.spoolman_ctx.report_thread == null);
    }
}

test "USB ID cache setup never starts a network worker in HTTP test servers" {
    const aio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(aio, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var instance = try App.init(std.testing.allocator, aio, path);
    defer instance.deinit(aio);
    instance.machine_ctx.no_proc_stat_timer = true;
    _ = instance.httpServer(aio);
    try std.testing.expect(instance.machine_ctx.usb_ids != null);
    try std.testing.expect(instance.machine_ctx.usb_ids.?.worker == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(aio, "misc/usb.ids", .{}));
}

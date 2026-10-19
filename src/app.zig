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
const extensions_component = @import("components/extensions.zig");
const analysis_component = @import("components/analysis.zig");
const file_manager_component = @import("components/file_manager.zig");
const machine_component = @import("components/machine.zig");
const update_manager_component = @import("components/update_manager.zig");
const power_component = @import("components/power.zig");
const wled_component = @import("components/wled.zig");
const td1_component = @import("components/td1.zig");
const printer_component = @import("components/printer.zig");
const klippy_connection_component = @import("components/klippy_connection.zig");
const octoprint_component = @import("components/octoprint_compat.zig");
const button_component = @import("components/button.zig");
const zeroconf_component = @import("components/zeroconf.zig");
const paneldue_component = @import("components/paneldue.zig");
const feather_updates_component = @import("components/feather_updates.zig");
const ds = @import("store/datastore.zig");
const config_helper = @import("config/confighelper.zig");

const feather_component_name = [_][]const u8{"feather_updates"};

fn featherPrinterIdle(ctx: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx));
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
        const result = std.process.run(alloc, io, .{ .argv = full.items }) catch return error.GitFailed;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (!(result.term == .exited and result.term.exited == 0)) return error.GitFailed;
        return;
    }
    return error.NoCommandRunner;
}

fn daemonShell(ctx: *anyopaque, alloc: std.mem.Allocator, cmdline: []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, cmdline, " \t");
    while (it.next()) |arg| try args.append(alloc, arg);
    try daemonFeatherRun(app, alloc, args.items);
}

fn featherCmd(ctx: *anyopaque, alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    for (argv) |arg| {
        if (hostPowerArg(arg)) return error.Refused;
    }
    // TestServer installs a no-op shell so HTTP update tests do not spawn
    // git, apt, or pip. The daemon shell is the production runner.
    if (app.update_ctx.shell) |sh| {
        if (sh != daemonShell) {
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
    }
    try daemonFeatherRun(app, alloc, argv);
}

fn featherKlippySend(ctx: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (!app.klippy_ctx.isConnected()) return;
    app.klippy_ctx.postMethod(method, params, alloc) catch {};
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
const WledCtx = wled_component.WledCtx;
const Td1Ctx = td1_component.Td1Ctx;
const ButtonCtx = button_component.ButtonCtx;
const PrinterCtx = printer_component.PrinterCtx;
const KlippyConnectionCtx = klippy_connection_component.KlippyCtx;
const OctoPrintCtx = octoprint_component.OctoPrintCtx;
const ZeroconfCtx = zeroconf_component.ZeroconfCtx;

/// Create a directory via the raw mkdir syscall (App.init has no live io yet).
/// Ignores already-exists; other failures are non-fatal (the file_manager
/// handlers will surface I/O errors at request time).
/// Replace `path` with its realpath when the directory is a symlink.
/// `path` is owned. The returned slice is owned. A missing path is unchanged.
fn canonicalPath(alloc: std.mem.Allocator, path: []u8) []u8 {
    if (path.len == 0 or path.len >= 4096) return path;
    const z = alloc.dupeSentinel(u8, path, 0) catch return path;
    defer alloc.free(z);
    var buf: [4096]u8 = undefined;
    const resolved = std.c.realpath(z.ptr, &buf) orelse return path;
    const slice = std.mem.span(resolved);
    if (std.mem.eql(u8, slice, path)) return path;
    const duped = alloc.dupe(u8, slice) catch return path;
    alloc.free(path);
    return duped;
}

fn mkdirRaw(path_z: [:0]const u8) void {
    const rc = std.os.linux.mkdir(path_z.ptr, 0o755);
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) {}
}

/// mkdir a single component, returning an error on anything but success/exists.
fn mkdirChecked(path_z: [:0]const u8) error{DataDirCreateFailed}!void {
    const rc = std.os.linux.mkdir(path_z.ptr, 0o755);
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) return error.DataDirCreateFailed;
}

/// `mkdir -p` for an absolute path: create every parent then the leaf,
/// fail-fast on a real error (permission, ENOTDIR, …). Unlike mkdirRaw this is
/// used for an explicitly configured `-d` datadir, where a silent failure would
/// otherwise surface only as confusing request-time errors.
fn ensureDirPathRaw(path: []const u8) error{ DataDirCreateFailed, DataPathTooLong }!void {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return error.DataPathTooLong;
    // Create each intermediate prefix at every '/'.
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        try mkdirChecked(buf[0..i :0]);
    }
    // Create the leaf.
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    try mkdirChecked(buf[0..path.len :0]);
}

/// Which DataStore backend to use. `sqlite` (default) is Moonraker
/// `moonraker-sql.db`-compatible and needs no `io` handle; `file` is the pure-Zig
/// atomic-rename JSON backend (no C dependency) and requires an `io` handle.
/// Selected via `[database] backend` in the config.
/// Coerce a config i64 to a smaller int, falling back to `default` when it is
/// out of range — so a typo'd/oversized numeric config value can't panic the
/// `@intCast`. (getInt returns i64; e.g. `port: 70000` parses but won't fit u16.)
fn clampInt(comptime T: type, raw: i64, default: T) T {
    if (raw < std.math.minInt(T) or raw > std.math.maxInt(T)) return default;
    return @intCast(raw);
}

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
    wled_ctx: *WledCtx,
    td1_ctx: *Td1Ctx,
    button_ctx: *ButtonCtx,
    printer_ctx: *PrinterCtx,
    klippy_ctx: *KlippyConnectionCtx,
    octoprint_ctx: *OctoPrintCtx,
    zeroconf_ctx: *ZeroconfCtx,
    /// Absolute datadir whose subfolders back the file_manager roots. Owned and
    /// freed in deinit. The root paths in `file_roots` point into the joined
    /// strings owned alongside it.
    datadir: []u8,
    /// Moonraker `.moonraker.uuid` (32 hex chars). Owned when `instance_uuid_owned`.
    instance_uuid: []u8 = &.{},
    instance_uuid_owned: bool = false,
    file_roots: []FileRoot,
    /// Owns the active DataStore backend (SQLite or atomic-rename file).
    db_store: StoreHolder,
    /// Parsed config, populated by setConfig(). Null when no config file was
    /// loaded (dump-api, tests). Owned; freed in deinit.
    cfg: ?*config_helper.ConfigParser = null,
    /// Allowed CORS origins from `[authorization] cors_domains`. Each slice + the
    /// outer array are gpa-owned; freed in deinit. Passed to the HTTP server.
    cors_domains: [][]const u8 = &.{},
    /// `[server] use_xheaders`, Moonraker default true. Copied onto the HTTP
    /// server in `httpServer`.
    use_xheaders: bool = true,
    /// PanelDue serial-line processor. `processPanelDueLine` is the reader
    /// entry: it strips the line and calls `parseLine`.
    paneldue: paneldue_component.PanelDue = .{},
    /// Forge-X Feather update adapter. Enabled when `[feather_updates]` exists.
    feather: feather_updates_component.FeatherCtx = .{},
    /// Records `git -C <repo>` argv in tests. Production leaves this null and
    /// `daemonFeatherRun` spawns git only when update io is set.
    git_spawn: ?GitSpawnFn = null,
    git_spawn_ctx: ?*anyopaque = null,
    /// True when `update_ctx.sources` is an owned `sourcesFromConfig` result.
    update_sources_owned: bool = false,
    /// True when `klippy_ctx.uds_path` was duped from config and must be freed.
    klippy_uds_owned: bool = false,

    /// Default entry point: SQLite backend, no io needed at init time.
    pub fn init(alloc: std.mem.Allocator) !App {
        return initWithStore(alloc, .sqlite, null, null, null);
    }

    /// Assemble the App with an explicit DataStore backend. The `file` backend
    /// needs a live `io` handle (filesystem); `sqlite` ignores it. `data_path` is
    /// the file_manager datadir (Moonraker's `-d`); when null a per-instance temp
    /// dir is used (tests / --dump-api only — never write real data under /tmp,
    /// which is tmpfs on embedded targets).
    pub fn initWithStore(alloc: std.mem.Allocator, db_backend: StoreBackend, db_io: ?std.Io, db_path: ?[]const u8, data_path: ?[]const u8) !App {
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

        const reg = try alloc.create(Registry);
        errdefer alloc.destroy(reg);
        reg.* = Registry.init(alloc, dispatcher);

        const info = try alloc.create(ServerInfo);
        errdefer alloc.destroy(info);
        info.* = .{};

        const conns = try alloc.create(Connections);
        errdefer alloc.destroy(conns);
        conns.* = Connections.init(alloc, core);

        const bus = try alloc.create(NotifyBus);
        errdefer alloc.destroy(bus);
        bus.* = NotifyBus.init(core, conns);

        const db_ctx = try alloc.create(DbCtx);
        errdefer alloc.destroy(db_ctx);

        // Build the DataStore behind the selected backend. A temporary path keyed
        // by `db_ctx`'s address keeps tests/dump-api isolated. SQLite (default)
        // opens at init with no io; the file backend needs the live io handle.
        const db_store: StoreHolder = blk: {
            var path_buf: [256]u8 = undefined;
            switch (db_backend) {
                .sqlite => {
                    const SqliteStore = @import("store/sqlite_store.zig").SqliteStore;
                    const store_ptr = try alloc.create(SqliteStore);
                    errdefer alloc.destroy(store_ptr);
                    const path_z = if (db_path) |p|
                        try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{p}, 0)
                    else
                        try std.fmt.bufPrintSentinel(&path_buf, "/tmp/phobos-db-{x}.db", .{@intFromPtr(db_ctx)}, 0);
                    store_ptr.* = try SqliteStore.open(alloc, path_z);
                    break :blk .{ .sqlite = store_ptr };
                },
                .file => {
                    const io = db_io orelse return error.FileBackendNeedsIo;
                    const FileStore = @import("store/file_store.zig").FileStore;
                    const store_ptr = try alloc.create(FileStore);
                    errdefer alloc.destroy(store_ptr);
                    const dir_path = if (db_path) |p|
                        try std.fmt.bufPrint(&path_buf, "{s}", .{p})
                    else
                        try std.fmt.bufPrint(&path_buf, "/tmp/phobos-db-{x}", .{@intFromPtr(db_ctx)});
                    store_ptr.* = FileStore.open(alloc, io, dir_path) catch return error.BackendOpenFailed;
                    break :blk .{ .file = store_ptr };
                },
            }
        };
        db_ctx.* = .{ .store = db_store.dataStore() };

        // --- History context ---
        const history_ctx = try alloc.create(HistoryCtx);
        errdefer alloc.destroy(history_ctx);
        history_ctx.* = HistoryCtx{
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
        job_queue_ctx.* = try JobQueueCtx.init(alloc, db_ctx.store, bus);

        // --- Job state context ---
        const job_state_ctx = try alloc.create(JobStateCtx);
        errdefer alloc.destroy(job_state_ctx);
        job_state_ctx.* = try JobStateCtx.init(alloc, bus);
        // Cross-wire: JobState → History + JobQueue for state-change events.
        job_state_ctx.history = history_ctx;
        job_state_ctx.job_queue = job_queue_ctx;

        // Mark any jobs left "in_progress" from a previous run as interrupted.
        history_ctx.markInterruptedJobs() catch |err|
            std.debug.print("phobos: warning: failed to mark interrupted jobs on startup: {} — stale 'in_progress' jobs may remain\n", .{err});

        // --- Announcements context ---
        const announcements_ctx = try alloc.create(AnnouncementsCtx);
        errdefer alloc.destroy(announcements_ctx);
        announcements_ctx.* = try AnnouncementsCtx.init(alloc, db_ctx.store, bus);

        // --- Data store context (gcode_store + temperature_store) ---
        const data_store_ctx = try alloc.create(DataStoreCtx);
        errdefer alloc.destroy(data_store_ctx);
        data_store_ctx.* = try DataStoreCtx.init(alloc);

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
        webcam_ctx.* = try WebcamCtx.init(alloc, db_ctx.store, bus);

        // --- Sensor context (sensors list/info/measurements) ---
        const sensor_ctx = try alloc.create(SensorCtx);
        errdefer alloc.destroy(sensor_ctx);
        sensor_ctx.* = SensorCtx.init(alloc, bus);
        sensor_ctx.history_ctx = history_ctx; // report measurements to history aux fields

        // --- Authorization context (access.* + auth hook) ---
        const auth_ctx = try alloc.create(AuthCtx);
        errdefer alloc.destroy(auth_ctx);
        // Issuer mirrors Moonraker's "http://<hostname>:<port>". The default
        // host/port keep tokens self-consistent within this instance.
        auth_ctx.* = try AuthCtx.init(alloc, db_ctx.store, "http://localhost:7125");
        // The spine transport does not yet surface the socket peer address;
        // trust requests whose IP is unknown (local deployment default). Valid
        // JWT / API-key credentials still take precedence.
        auth_ctx.trust_unknown_ip = true;

        // --- Spoolman context (spool_id persistence + proxy stubs) ---
        // io is not stored here; setIo() is called after the event loop starts
        // (see httpServer). Notifications are suppressed until then.
        // server_url is set later in setConfig when the config file is parsed.
        const spoolman_ctx = try alloc.create(SpoolmanCtx);
        errdefer alloc.destroy(spoolman_ctx);
        spoolman_ctx.* = SpoolmanCtx.init(alloc, db_ctx.store, bus, null);

        // --- MQTT context (no broker; faithful endpoint shapes) ---
        const mqtt_ctx = try alloc.create(MqttCtx);
        errdefer alloc.destroy(mqtt_ctx);
        mqtt_ctx.* = MqttCtx.init(alloc);

        // --- Extensions context (agent registry) ---
        const extensions_ctx = try alloc.create(ExtensionsCtx);
        errdefer alloc.destroy(extensions_ctx);
        extensions_ctx.* = ExtensionsCtx.init(alloc);

        // --- Analysis context (klipper_estimator stubs) ---
        const analysis_ctx = try alloc.create(AnalysisCtx);
        errdefer alloc.destroy(analysis_ctx);
        analysis_ctx.* = .{};

        // --- File manager context (server.files.*) ---
        // Datadir defaults to a per-instance temp directory so tests and
        // --dump-api have writable roots without polluting the cwd. The roots
        // gcodes/config/logs are created beneath it. Directories are created
        // with the raw mkdir syscall because App.init has no live io yet (io is
        // wired later via httpServer/setIo).
        var dd_buf: [256]u8 = undefined;
        const datadir = if (data_path) |dp| dd: {
            // Configured datadir (Moonraker's `-d`, validated absolute above):
            // create it and any missing parents fail-fast so a bad/unwritable
            // path is reported at startup, not at request time.
            try ensureDirPathRaw(dp);
            break :dd try alloc.dupe(u8, dp);
        } else dd: {
            // No datadir given (tests / --dump-api): per-instance temp dir.
            const dd_tmp = try std.fmt.bufPrintSentinel(&dd_buf, "/tmp/phobos-data-{x}", .{@intFromPtr(analysis_ctx)}, 0);
            mkdirRaw(dd_tmp);
            break :dd try alloc.dupe(u8, dd_tmp);
        };
        errdefer alloc.free(datadir);

        const root_specs = [_]struct { name: []const u8, full: bool }{
            .{ .name = "config", .full = true },
            .{ .name = "logs", .full = false },
            .{ .name = "gcodes", .full = true },
        };
        const file_roots = try alloc.alloc(FileRoot, root_specs.len);
        errdefer alloc.free(file_roots);
        for (root_specs, 0..) |spec, i| {
            const p = try std.fs.path.join(alloc, &.{ datadir, spec.name });
            const pz = try alloc.dupeSentinel(u8, p, 0);
            defer alloc.free(pz);
            // For an explicitly configured datadir, a root we can't create means
            // the daemon can't serve files — fail-fast. For the temp default,
            // stay lenient (tests / --dump-api may run read-only).
            if (data_path != null) try mkdirChecked(pz) else mkdirRaw(pz);
            // Forge-x points printer_data/{config,logs,gcodes} at /opt/config,
            // /data/logFiles, and /data. Moonraker reports the symlink target.
            file_roots[i] = .{ .name = spec.name, .path = canonicalPath(alloc, p), .full_access = spec.full };
        }

        const file_ctx = try alloc.create(FileCtx);
        errdefer alloc.destroy(file_ctx);
        file_ctx.* = .{ .gpa = alloc, .roots = file_roots, .bus = bus };

        // --- Machine context (machine.* + machine.proc_stats) ---
        // io is wired later via httpServer/setIo so /proc & /sys reads work.
        const machine_ctx = try alloc.create(MachineCtx);
        errdefer alloc.destroy(machine_ctx);
        machine_ctx.* = .{ .gpa = alloc, .bus = bus, .conns = conns };

        // --- Update manager context (machine.update.*) ---
        // The default source set (system + moonraker + klipper git repos) is a
        // static borrow; real git/package state is stubbed. io is wired later via
        // setIo so notifications reach connected WebSocket clients.
        const update_ctx = try alloc.create(UpdateCtx);
        errdefer alloc.destroy(update_ctx);
        update_ctx.* = .{
            .gpa = alloc,
            .store = db_ctx.store,
            .sources = &update_manager_component.default_sources,
            .bus = bus,
            // Refuse update operations while a print is active (Moonraker 503).
            .printing_check = JobStateCtx.isActiveErased,
            .printing_ctx = job_state_ctx,
        };

        // --- Power device context (machine.device_power.*) ---
        // Devices come from [power <name>] config sections (none in the bare
        // spine → empty list). HTTP-URL devices send real GET requests and
        // `type: gpio` devices drive the sysfs line (see power.zig); other vendor
        // types remain in-memory.
        const power_ctx = try alloc.create(PowerCtx);
        errdefer alloc.destroy(power_ctx);
        power_ctx.* = PowerCtx.init(alloc, bus);

        // --- WLED context (machine.wled.*) ---
        // Strips come from [wled <name>] config (none in the bare spine).
        // Address strips use the WLED JSON HTTP API; serial strips write JSON to
        // the character device (see wled.zig).
        const wled_ctx = try alloc.create(WledCtx);
        errdefer alloc.destroy(wled_ctx);
        wled_ctx.* = WledCtx.init(alloc);

        // --- TD-1 context (machine.td1.*) ---
        // Devices are auto-discovered by USB vid/pid and read over the serial
        // port (see td1.zig: findTd1Devices + pollSerialOnce, started after io
        // is wired). None present on a host without a TD-1.
        const td1_ctx = try alloc.create(Td1Ctx);
        errdefer alloc.destroy(td1_ctx);
        td1_ctx.* = Td1Ctx.init(alloc);

        const button_ctx = try alloc.create(ButtonCtx);
        errdefer alloc.destroy(button_ctx);
        button_ctx.* = ButtonCtx.init(alloc, bus);

        // --- Printer context (printer.* — Klippy-disconnected stubs) ---
        const printer_ctx = try alloc.create(PrinterCtx);
        errdefer alloc.destroy(printer_ctx);
        printer_ctx.* = .{};

        // --- Klippy connection context (Unix-socket bridge to Klippy) ---
        const klippy_ctx = try alloc.create(KlippyConnectionCtx);
        errdefer alloc.destroy(klippy_ctx);
        klippy_ctx.* = try KlippyConnectionCtx.init(alloc, bus);
        klippy_ctx.server_info = info;
        klippy_ctx.job_state = job_state_ctx;
        klippy_ctx.history = history_ctx;
        // Wire the Core lock so the Klippy bridge uses the concurrent reader path
        // (persistent socket drain + response correlation) instead of inline drain.
        klippy_ctx.core = core;

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

        // --- OctoPrint compatibility context (/api/*) ---
        const octoprint_ctx = try alloc.create(OctoPrintCtx);
        errdefer alloc.destroy(octoprint_ctx);
        octoprint_ctx.* = OctoPrintCtx.init();
        octoprint_ctx.server_info = info;
        octoprint_ctx.temp_store = data_store_ctx;
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
            .wled_ctx = wled_ctx,
            .td1_ctx = td1_ctx,
            .button_ctx = button_ctx,
            .printer_ctx = printer_ctx,
            .klippy_ctx = klippy_ctx,
            .octoprint_ctx = octoprint_ctx,
            .zeroconf_ctx = zeroconf_ctx,
            .datadir = datadir,
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

    /// Parse a config file and wire it into server.config responses. Safe to
    /// call even when no --config flag was given; in that case the config
    /// objects stay empty (server.config still returns the correct shape).
    pub fn setConfig(self: *App, aio: std.Io, config_path: []const u8) void {
        const cfg = self.alloc.create(config_helper.ConfigParser) catch {
            std.debug.print("phobos: warning: OOM parsing config\n", .{});
            return;
        };
        cfg.* = config_helper.ConfigParser.init(self.alloc);
        cfg.parseFile(aio, config_path) catch |err| {
            std.debug.print("phobos: warning: could not parse config '{s}': {}\n", .{ config_path, err });
        };
        self.cfg = cfg;
        self.info.cfg = cfg;
        self.info.config_file_path = config_path;
        self.ensureInstanceUuid(aio);

        // [server] use_xheaders defaults true. False keeps the socket peer
        // even when X-Forwarded-For / X-Real-Ip are present.
        if (cfg.getBoolean("server", "use_xheaders")) |v| {
            self.use_xheaders = v;
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

        // [paneldue] enable_checksum defaults true, matching Moonraker. The
        // serial reader calls processPanelDueLine, which strips the line and
        // parses it. Absent section leaves the processor idle (checksum off).
        if (cfg.hasSection("paneldue")) {
            self.paneldue.enable_checksum = cfg.getBoolean("paneldue", "enable_checksum") catch true;
        }

        // [analysis] points at klipper_estimator under the datadir. The binary
        // is not downloaded. Status reports it missing until the file exists.
        self.analysis_ctx.io = aio;
        if (cfg.hasSection("analysis")) self.applyAnalysisConfig(cfg);

        // Wire spoolman server URL from [spoolman] server key.
        if (cfg.get("spoolman", "server")) |url| {
            self.spoolman_ctx.setServerUrl(url);
        }

        // System provider for machine.services.* ([machine] provider): selects
        // systemctl vs supervisorctl vs in-memory. Default stays systemd_dbus.
        if (cfg.get("machine", "provider")) |p| {
            self.machine_ctx.setProvider(p) catch |err| {
                std.debug.print("phobos: warning: failed to set machine provider '{s}': {}\n", .{ p, err });
            };
        }
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
        if (update_manager_component.sourcesFromConfig(self.alloc, cfg)) |srcs| {
            if (self.update_sources_owned) update_manager_component.freeSources(self.alloc, self.update_ctx.sources);
            self.update_ctx.sources = srcs;
            self.update_sources_owned = true;
        } else |err| {
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
                if (n > 0) self.data_store_ctx.setGcodeStoreSize(@intCast(n)) catch |err| {
                    std.debug.print("phobos: warning: gcode_store_size not applied: {}\n", .{err});
                };
            } else |_| {}
            if (cfg.getInt("data_store", "temperature_store_size")) |n| {
                if (n > 0) self.data_store_ctx.setTemperatureStoreSize(@intCast(n)) catch |err| {
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

        if (cfg.hasSection("file_manager")) {
            if (cfg.get("file_manager", "file_system_observer")) |raw| {
                if (std.ascii.eqlIgnoreCase(raw, "inotify")) {
                    self.file_ctx.observer = .inotify;
                } else {
                    self.file_ctx.observer = .none;
                }
            } else {
                // Moonraker's default when the section exists and the key does not.
                self.file_ctx.observer = .inotify;
            }
            if (cfg.get("file_manager", "excludes")) |raw| {
                self.file_ctx.setExcludes(raw) catch |err| {
                    std.debug.print("phobos: warning: file excludes not applied: {}\n", .{err});
                };
            }
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
            self.klippy_ctx.remote_methods = &feather_updates_component.remote_methods;
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
            const load_on_start = cfg.getBoolean("job_queue", "load_on_startup") catch false;
            self.job_queue_ctx.setQueueOptions(automatic, load_on_start);
        }

        // Wire MQTT broker config from [mqtt] section.
        if (cfg.hasSection("mqtt")) {
            const host = cfg.get("mqtt", "host") orelse "localhost";
            const port: u16 = clampInt(u16, cfg.getInt("mqtt", "port") catch 1883, 1883);
            const username = cfg.get("mqtt", "username");
            const password = cfg.get("mqtt", "password");
            self.mqtt_ctx.setConfig(host, port, username, password) catch |err|
                std.debug.print("phobos: warning: failed to apply [mqtt] config: {} — MQTT disabled\n", .{err});
            if (cfg.get("mqtt", "instance_name")) |iname| {
                self.mqtt_ctx.setInstanceName(iname) catch {};
            }
            if (cfg.get("mqtt", "client_id")) |cid| {
                self.mqtt_ctx.setClientId(cid) catch {};
            }
            if (cfg.get("mqtt", "default_qos")) |qos_str| {
                const qos: u8 = clampInt(u8, std.fmt.parseInt(i64, qos_str, 10) catch 0, 0);
                self.mqtt_ctx.setDefaultQos(qos);
            }
            if (cfg.getBoolean("mqtt", "enable_moonraker_api")) |ena| {
                self.mqtt_ctx.setApiEnabled(ena);
            } else |_| {}
            if (cfg.get("mqtt", "api_qos")) |aqos_str| {
                const aqos: i64 = std.fmt.parseInt(i64, aqos_str, 10) catch @as(i64, 0);
                self.mqtt_ctx.setApiQos(aqos);
            }
        }

        // Wire power devices from [power <name>] sections.
        var power_sects: std.ArrayList([]const u8) = .empty;
        defer power_sects.deinit(self.alloc);
        if (cfg.sectionNames(self.alloc)) |names| {
            defer self.alloc.free(names);
            for (names) |sect| {
                if (!std.mem.startsWith(u8, sect, "power ")) continue;
                const dev_name = sect["power ".len..];
                if (dev_name.len == 0) continue;
                power_sects.append(self.alloc, dev_name) catch continue;
            }
        } else |_| {}
        for (power_sects.items) |dev_name| {
            const sect = std.fmt.allocPrint(self.alloc, "power {s}", .{dev_name}) catch continue;
            defer self.alloc.free(sect);
            const dev_type = cfg.get(sect, "type") orelse "gpio";
            const initial_state: ?[]const u8 = if (cfg.get(sect, "initial_state")) |s|
                self.alloc.dupe(u8, s) catch null
            else
                null;
            const bound_services: ?[]const u8 = if (cfg.get(sect, "bound_services")) |s|
                self.alloc.dupe(u8, s) catch null
            else
                null;
            const name_dup = self.alloc.dupe(u8, dev_name) catch continue;
            const type_dup = self.alloc.dupe(u8, dev_type) catch continue;
            const state_dup = self.alloc.dupe(u8, "off") catch continue;

            // HTTP URLs: explicit on_url/off_url/status_url win; otherwise derive
            // them for protocol types (tasmota/shelly) from `address`+`output_id`.
            // addDeviceFull dupes these, so the temporaries here are freed after.
            var on_url: ?[]const u8 = if (cfg.get(sect, "on_url")) |s| (self.alloc.dupe(u8, s) catch null) else null;
            var off_url: ?[]const u8 = if (cfg.get(sect, "off_url")) |s| (self.alloc.dupe(u8, s) catch null) else null;
            var status_url: ?[]const u8 = if (cfg.get(sect, "status_url")) |s| (self.alloc.dupe(u8, s) catch null) else null;
            if (on_url == null) {
                if (cfg.get(sect, "address")) |addr| {
                    const output_id = cfg.getInt(sect, "output_id") catch 1;
                    const password = cfg.get(sect, "password");
                    const urls: ?power_component.ProtoUrls =
                        if (std.mem.eql(u8, dev_type, "tasmota"))
                            (power_component.tasmotaUrls(self.alloc, addr, output_id, password) catch null)
                        else if (std.mem.eql(u8, dev_type, "shelly"))
                            (power_component.shellyUrls(self.alloc, addr, output_id) catch null)
                        else
                            null;
                    if (urls) |u| {
                        on_url = u.on;
                        off_url = u.off;
                        status_url = u.status;
                    }
                }
            }
            defer {
                if (on_url) |u| self.alloc.free(u);
                if (off_url) |u| self.alloc.free(u);
                if (status_url) |u| self.alloc.free(u);
            }

            const dev = power_component.Device{
                .name = name_dup,
                .type_str = type_dup,
                .state = state_dup,
                .locked_while_printing = cfg.getBoolean(sect, "locked_while_printing") catch false,
                .off_when_shutdown = cfg.getBoolean(sect, "off_when_shutdown") catch false,
                .off_when_shutdown_delay = cfg.getFloat(sect, "off_when_shutdown_delay") catch 0.0,
                .on_when_queued = cfg.getBoolean(sect, "on_when_job_queued") catch cfg.getBoolean(sect, "on_when_queued") catch false,
                .klipper_restart = cfg.getBoolean(sect, "klipper_restart") catch false,
                .restart_delay = cfg.getFloat(sect, "restart_delay") catch 0.0,
                .bound_services = bound_services,
                .initial_state = initial_state,
                .restrict_actions = cfg.getBoolean(sect, "restrict_action_processing") catch true,
                .timer = cfg.getFloat(sect, "timer") catch 0.0,
                .is_shutdown = false,
                .on_url = on_url,
                .off_url = off_url,
                .status_url = status_url,
            };
            self.power_ctx.addDeviceFull(dev) catch |err| {
                std.debug.print("phobos: warning: failed to add power device '{s}': {}\n", .{ dev_name, err });
                self.alloc.free(dev.name);
                self.alloc.free(dev.type_str);
                self.alloc.free(dev.state);
                if (dev.bound_services) |bs| self.alloc.free(bs);
                if (dev.initial_state) |is| self.alloc.free(is);
            };
        }

        // Wire WLED strips, webcams, and notifiers from prefixed sections.
        self.notifier_ctx.deinit(self.alloc);
        if (cfg.sectionNames(self.alloc)) |names| {
            defer self.alloc.free(names);
            for (names) |sect| {
                if (std.mem.startsWith(u8, sect, "notifier ")) {
                    const nname = sect["notifier ".len..];
                    if (nname.len == 0) continue;
                    const url = cfg.get(sect, "url") orelse continue;
                    self.notifier_ctx.addNotifier(self.alloc, .{
                        .name = nname,
                        .url = url,
                        .title = cfg.get(sect, "title") orelse "",
                        .body = cfg.get(sect, "body") orelse "",
                        .body_format = cfg.get(sect, "body_format") orelse "text",
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
                const chain_count: i64 = cfg.getInt(sect, "chain_count") catch @as(i64, 1);
                const initial_preset: i64 = cfg.getInt(sect, "initial_preset") catch @as(i64, -1);
                const initial_red: f64 = cfg.getFloat(sect, "initial_red") catch 0.5;
                const initial_green: f64 = cfg.getFloat(sect, "initial_green") catch 0.5;
                const initial_blue: f64 = cfg.getFloat(sect, "initial_blue") catch 0.5;
                const initial_white: f64 = cfg.getFloat(sect, "initial_white") catch 0.5;
                const address: ?[]const u8 = cfg.get(sect, "address");
                const port: u16 = clampInt(u16, cfg.getInt(sect, "port") catch 80, 80);
                const protocol: ?[]const u8 = cfg.get(sect, "protocol");
                // Build initial_colors as JSON array [R,G,B,W].
                const initial_colors = std.fmt.allocPrint(self.alloc, "[{d},{d},{d},{d}]", .{ initial_red, initial_green, initial_blue, initial_white }) catch continue;
                // Build chain_data with color_size=4 per node.
                const color_size: usize = 4;
                const chain_data_len = @as(usize, @intCast(chain_count)) * color_size;
                const chain_data = self.alloc.alloc(u8, chain_data_len) catch continue;
                @memset(chain_data, 0);
                self.wled_ctx.addStrip(strip_name, chain_count, chain_data, initial_preset, initial_preset, initial_colors, false, address, port, protocol) catch |err| {
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
                    const stype = cfg.get(sect, "type") orelse "mqtt";
                    _ = self.sensor_ctx.addSensor(sname, stype) catch |err| {
                        std.debug.print("phobos: warning: failed to add sensor '{s}': {}\n", .{ sname, err });
                        continue;
                    };
                    if (cfg.get(sect, "state_topic")) |t| self.sensor_ctx.setSensorTopic(sname, t) catch |err|
                        std.debug.print("phobos: warning: sensor '{s}' state_topic not set: {} — sensor will not update\n", .{ sname, err });
                    if (cfg.get(sect, "state_response_template")) |tm| self.sensor_ctx.setSensorTemplate(sname, tm) catch |err|
                        std.debug.print("phobos: warning: sensor '{s}' template not set: {}\n", .{ sname, err });
                }
            }
        } else |_| {}
    }

    /// Set a mock command-runner on the machine component so tests don't
    /// exec real systemctl/reboot/shutdown commands on the host.
    pub fn setMachineRunCmdFn(self: *App, run_cmd_fn: MachineCtx.RunCmdFn, ctx: *anyopaque) void {
        self.machine_ctx.setRunCmdFn(run_cmd_fn, ctx);
    }

    /// Free all owned resources. `io` is required only for the Connections
    /// registry teardown which needs an Io-aware mutex; pass a threaded io or
    /// use `deinitNoIo` in pure unit tests where no event loop is running.
    pub fn deinit(self: *App, io: std.Io) void {
        self.update_ctx.stopAutoRefresh();
        self.data_store_ctx.stopSampler();
        self.history_ctx.handleServerExit(self.job_state_ctx.getLastStats());
        // Stop the Spoolman WS supervisor (uses io) before io/conns teardown.
        self.spoolman_ctx.stopWs();
        // Stop the TD-1 discovery/poll thread (uses io + core) before teardown.
        self.td1_ctx.stopPolling();
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
        self.alloc.free(self.datadir);
        self.file_ctx.deinit(); // frees the metadata cache
        self.alloc.destroy(self.file_ctx);
        if (self.update_sources_owned) update_manager_component.freeSources(self.alloc, self.update_ctx.sources);
        self.alloc.destroy(self.update_ctx);
        self.power_ctx.deinit();
        self.alloc.destroy(self.power_ctx);
        self.wled_ctx.deinit();
        self.alloc.destroy(self.wled_ctx);
        self.td1_ctx.deinit();
        self.alloc.destroy(self.td1_ctx);
        self.button_ctx.deinit();
        self.alloc.destroy(self.button_ctx);
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
        self.mqtt_ctx.deinit();
        self.alloc.destroy(self.mqtt_ctx);
        self.alloc.destroy(self.spoolman_ctx);
        self.db_store.deinit(self.alloc);
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
        self.announcements_ctx.deinit();
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

        // Button component: notify_button_event (notification-only).
        try button_component.registerButton(self.reg, self.button_ctx);

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
        self.klippy_ctx.remote_methods = &feather_updates_component.remote_methods;
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
        const n = std.os.linux.getrandom(&bytes, bytes.len, 0);
        if (std.os.linux.errno(n) != .SUCCESS or n != bytes.len) return;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var hex: [32]u8 = undefined;
        const hexd = "0123456789abcdef";
        for (bytes, 0..) |b, i| {
            hex[i * 2] = hexd[b >> 4];
            hex[i * 2 + 1] = hexd[b & 0xf];
        }
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
        self.klippy_ctx.remote_handler = feather_updates_component.onKlippyMethod;
        self.klippy_ctx.remote_handler_ctx = &self.feather;
        // Keep a test-installed shell (TestServer's no-op). Otherwise the
        // daemon runner is what live reset/update calls.
        if (self.update_ctx.shell == null or self.update_ctx.shell == daemonShell) {
            self.update_ctx.shell = daemonShell;
            self.update_ctx.shell_ctx = self;
        }
    }

    /// Feed one PanelDue serial line. Strips it, treats M112 as emergency stop,
    /// and otherwise parses through `parseLine` (checksummed file commands keep
    /// a single filename only when it is non-empty).
    pub fn processPanelDueLine(self: *App, line: []const u8) paneldue_component.ParseError!void {
        return self.paneldue.processLine(line);
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
            return;
        }
        const grown = self.alloc.realloc(self.file_roots, self.file_roots.len + 1) catch {
            self.alloc.free(path);
            return;
        };
        grown[grown.len - 1] = .{ .name = name, .path = path, .full_access = false };
        self.file_roots = grown;
        self.file_ctx.roots = grown;
        self.syncRegisteredDirectories();
    }

    fn applyAnalysisConfig(self: *App, cfg: *const config_helper.ConfigParser) void {
        const configured = cfg.get("analysis", "platform") orelse "auto";
        const plat: []const u8 = if (std.mem.eql(u8, configured, "linux") or std.mem.eql(u8, configured, "rpi") or std.mem.eql(u8, configured, "osx"))
            configured
        else if (@import("builtin").cpu.arch == .arm or @import("builtin").cpu.arch == .aarch64)
            "rpi"
        else
            "linux";
        const bin = std.fmt.allocPrint(self.alloc, "{s}/tools/klipper_estimator/klipper_estimator_{s}", .{ self.datadir, plat }) catch return;
        var cfg_path = std.fmt.allocPrint(self.alloc, "{s}/tools/klipper_estimator/default_estimator_cfg.json", .{self.datadir}) catch {
            self.alloc.free(bin);
            return;
        };
        if (cfg.get("analysis", "estimator_config")) |rel| {
            const trimmed = std.mem.trim(u8, rel, " \t/");
            if (trimmed.len > 0 and std.mem.indexOf(u8, trimmed, "..") == null) {
                if (std.fs.path.join(self.alloc, &.{ self.datadir, "config", trimmed })) |custom| {
                    var use_custom = false;
                    if (self.analysis_ctx.io) |io| {
                        if (std.Io.Dir.cwd().openFile(io, custom, .{})) |f| {
                            f.close(io);
                            use_custom = true;
                        } else |_| {}
                    }
                    if (use_custom) {
                        self.alloc.free(cfg_path);
                        cfg_path = custom;
                    } else {
                        self.alloc.free(custom);
                        std.debug.print("phobos: warning: estimator_config '{s}' is not in the config root\n", .{trimmed});
                    }
                } else |_| {}
            }
        }
        if (self.analysis_ctx.paths_owned) {
            self.alloc.free(self.analysis_ctx.estimator_path);
            self.alloc.free(self.analysis_ctx.estimator_config);
        }
        self.analysis_ctx.estimator_path = bin;
        self.analysis_ctx.estimator_config = cfg_path;
        self.analysis_ctx.paths_owned = true;
    }

    /// Returns the HTTP transport Server configured with this App's components.
    /// The caller must supply a live `io` (from a threaded event loop). The
    /// returned Server borrows all App-owned pointers; the App must outlive it.
    pub fn httpServer(self: *App, io: std.Io) http_transport.Server {
        // Rebind after App is at its final address (init returned it by value).
        self.bindFeather();
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
        // Spoolman WebSocket: live connection status + spool-deleted push.
        self.spoolman_ctx.on_spool_deleted = spoolmanSpoolDeleted;
        self.spoolman_ctx.on_spool_deleted_ctx = self;
        self.spoolman_ctx.startWs();
        // TD-1 filament sensor: background USB discovery + serial polling.
        self.td1_ctx.setIo(io);
        self.td1_ctx.setCore(self.core);
        self.td1_ctx.startPolling();
        // Wire io into the file manager so it can emit notify_filelist_changed.
        self.file_ctx.setIo(io);
        if (self.file_ctx.observer == .inotify) self.file_ctx.startObserver();
        self.analysis_ctx.io = io;
        self.klippy_ctx.on_klipper_path = onKlipperPath;
        self.klippy_ctx.on_klipper_path_ctx = self;
        // Wire io into the machine component for /proc & /sys reads.
        self.machine_ctx.setIo(io);
        // Wire io into the update manager so it can emit notify_update_response /
        // notify_update_refreshed to connected WebSocket clients.
        self.update_ctx.setIo(io);
        // Wire io into the power component so it can emit notify_power_changed.
        self.power_ctx.setIo(io);
        self.power_ctx.applyInitialStates();
        // Wire io into the button component so it can emit notify_button_event.
        self.button_ctx.setIo(io);
        self.button_ctx.startPolling();
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
        // Wire io into MQTT and, when a broker is configured, connect to it in
        // the background (a slow/unreachable broker must not stall startup).
        self.mqtt_ctx.setIo(io);
        // Bridge inbound MQTT messages → sensors (under the Core lock) and
        // subscribe sensor topics on connect.
        self.sensor_mqtt_bridge = .{ .app = self };
        self.mqtt_ctx.on_message = SensorMqttBridge.onMessage;
        self.mqtt_ctx.on_message_ctx = &self.sensor_mqtt_bridge;
        // JSON-RPC-over-MQTT bridge: dispatch api_request frames through the
        // shared dispatcher (under the Core lock) and publish the response.
        self.mqtt_ctx.api_dispatch = mqttApiDispatch;
        self.mqtt_ctx.api_dispatch_ctx = self;
        self.mqtt_ctx.on_connected = SensorMqttBridge.onConnected;
        self.mqtt_ctx.on_connected_ctx = &self.sensor_mqtt_bridge;
        if (self.mqtt_ctx.isConfigured()) {
            // Tracked std.Thread (not a discarded io.async future) so
            // disconnectBroker can join it before teardown — closes the
            // deinit-vs-in-flight-connect UAF window.
            self.mqtt_ctx.connect_thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, MqttCtx.connectBrokerBg, .{self.mqtt_ctx}) catch null;
        }
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
            .cors_domains = self.cors_domains,
            .use_xheaders = self.use_xheaders,
        };
    }
};

/// Placeholder handler for WS-only methods registered in the dispatcher for
/// reflection purposes. The real implementations in `transport/ws.zig`
/// intercept those method names before the dispatcher is consulted.
fn wsStubHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.WsOnlyMethod;
}

/// Glue between the MQTT client (background reader thread) and the sensor
/// component. Inbound messages are dispatched into the sensor store under the
/// Core lock so they serialize with JSON-RPC handlers and notifications.
/// Dispatch an inbound MQTT api_request payload through the JSON-RPC dispatcher
/// under the Core lock (the mqtt reader thread does not hold it), returning the
/// response bytes. Wired into MqttCtx.api_dispatch.
fn mqttApiDispatch(ctx: *anyopaque, payload: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    _ = app.mqtt_ctx.io orelse return error.NotReady;
    // Dispatcher.handle takes the Core lock itself, per-method (skipping it for
    // off_core reads). Wrapping it in core.run here would double-lock the
    // non-reentrant Core mutex and freeze the server.
    return app.dispatcher.handle(payload, alloc);
}

/// Spoolman WS spool-deletion hook: clear the active spool (if it was the
/// deleted one) under the Core lock. Runs off the WS supervisor thread.
fn spoolmanSpoolDeleted(ctx: *anyopaque, spool_id: i64) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const io = app.spoolman_ctx.io orelse return;
    app.core.run(io, SpoolmanCtx.handleSpoolDeletedLocked, .{ app.spoolman_ctx, spool_id });
}

pub const SensorMqttBridge = struct {
    app: *App = undefined,

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
        var it = self.app.sensor_ctx.sensors.valueIterator();
        while (it.next()) |s| {
            if (s.state_topic) |topic| self.app.mqtt_ctx.subscribeTopicLive(topic);
        }
    }
};

/// Dispatches a gcode request to Klippy on behalf of the job_queue component.
/// This is the adapter that bridges job_queue's anyopaque dispatch to
/// KlippyCtx.request(). Called via JobQueueCtx.setKlippyDispatch.
fn jobQueueKlippyDispatch(klippy_opaque: *anyopaque, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const k: *KlippyConnectionCtx = @ptrCast(@alignCast(klippy_opaque));
    // Always off-Core: job dispatch runs on a dedicated worker thread
    // (job_queue.scheduleNextJobDispatch), never on the Klippy reader thread
    // (which would block on its own response) and never while holding Core
    // (requestConcurrent's core.unlock would then be unbalanced).
    return k.requestOffCore(method, params, alloc);
}

// --- tests ---------------------------------------------------------------

test "App.init registers server.info and server.config" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
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

    const cfg_path = ".zig-cache/phobos-use-xheaders-test.cfg";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[server]\nuse_xheaders: false\n" });
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    const before = app.httpServer(io);
    try std.testing.expect(before.use_xheaders);
    app.setConfig(io, cfg_path);
    const after = app.httpServer(io);
    try std.testing.expect(!after.use_xheaders);
}

test "setConfig loads trusted clients, update sources, and feather_updates" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg_path = ".zig-cache/phobos-printer-gap-test.cfg";
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);

    const addr = try std.Io.net.IpAddress.parse("8.8.8.8", 0);
    try std.testing.expect(app.auth_ctx.trusted.isTrusted(addr));
    try std.testing.expectEqualStrings("/no/such/klippy.sock", app.klippy_ctx.uds_path);
    try std.testing.expect(app.feather.enabled);
    try std.testing.expectEqualStrings("forge-x", app.feather.update_key);
    try std.testing.expectEqual(@as(usize, 3), app.klippy_ctx.remote_methods.len);
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
    try app.klippy_ctx.dispatchRemoteMethod(io, "feather_request_forge_x_update_status", .{ .object = frame });
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
    const cfg_path = ".zig-cache/phobos-feather-daemon-test.cfg";
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
    app.bindFeather();
    try std.testing.expect(app.update_ctx.shell == daemonShell);
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
    try app.klippy_ctx.dispatchFrame(io, payload);
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
    const cfg_path = ".zig-cache/phobos-announce-store-test.cfg";
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
    try std.testing.expect(app.announcements_ctx.dev_mode);
    try std.testing.expectEqual(@as(usize, 2), app.data_store_ctx.gcode_ring.capacity);
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
    const cfg_path = ".zig-cache/phobos-octo-config-test.cfg";
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
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
    const cfg_path = ".zig-cache/phobos-webcam-config-test.cfg";
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
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
    app.setConfig(io, cfg_path);

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
    const cfg_path = ".zig-cache/phobos-machine-simple-test.cfg";
    const body =
        \\[machine]
        \\provider: simple
        \\script_path: /no/such/scripts
        \\script_timeout: 12
        \\validate_service: false
        \\validate_config: false
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = body });
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
    try std.testing.expectEqualStrings("simple", app.machine_ctx.provider_name);
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

test "setConfig loads auto-refresh, excludes, observer none, and hidden objects" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg_path = ".zig-cache/phobos-parity-flags-test.cfg";
    const body =
        \\[update_manager]
        \\enable_auto_refresh: False
        \\refresh_interval: 168
        \\refresh_window: 0-5
        \\
        \\[file_manager]
        \\file_system_observer: none
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
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
    try std.testing.expect(!app.update_ctx.auto_refresh);
    try std.testing.expectEqual(@as(i64, 168), app.update_ctx.refresh_interval_hours);
    try std.testing.expectEqual(@as(i64, 0), app.update_ctx.refresh_window_start);
    try std.testing.expectEqual(@as(i64, 5), app.update_ctx.refresh_window_end);
    try std.testing.expect(app.update_ctx.refresh_thread == null);
    try std.testing.expect(app.file_ctx.observer == .none);
    try std.testing.expect(app.file_ctx.observer_thread == null);
    try std.testing.expect(file_manager_component.FileCtx.pathExcluded(app.file_ctx.excludes, "gcodes", ".mod"));
    try std.testing.expect(file_manager_component.FileCtx.pathExcluded(app.file_ctx.excludes, "gcodes", "logFiles/a.log"));
    try std.testing.expect(!app.update_ctx.tickAutoRefresh(alloc, 2));
    try std.testing.expectEqual(@as(usize, 2), app.printer_ctx.hidden_objects.len);
    try std.testing.expectEqualStrings("output_pin level_h1", app.printer_ctx.hidden_objects[0]);
    try std.testing.expectEqualStrings("output_pin power_off", app.printer_ctx.hidden_objects[1]);
}

test "setConfig [paneldue] processPanelDueLine strips checksummed file commands" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg_path = ".zig-cache/phobos-paneldue-test.cfg";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[paneldue]\nenable_checksum: true\n" });
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);

    const body = "N10 M32  plate.gco  ";
    var sum: u8 = 0;
    for (body) |c| sum ^= c;
    var core: [64]u8 = undefined;
    const checksummed = std.fmt.bufPrint(&core, "{s}*{d}", .{ body, sum }) catch unreachable;
    var wrapped: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&wrapped, "  {s}\r\n", .{checksummed}) catch unreachable;

    try app.processPanelDueLine(line);
    try std.testing.expectEqual(@as(usize, 2), app.paneldue.part_count);
    try std.testing.expectEqualStrings("M32", app.paneldue.parts[0]);
    try std.testing.expectEqualStrings("plate.gco", app.paneldue.parts[1]);

    const bare = "M98";
    sum = 0;
    for (bare) |c| sum ^= c;
    const m98 = std.fmt.bufPrint(&core, "{s}*{d}", .{ bare, sum }) catch unreachable;
    try app.processPanelDueLine(m98);
    try std.testing.expectEqual(@as(usize, 1), app.paneldue.part_count);
    try std.testing.expectEqualStrings("M98", app.paneldue.parts[0]);

    try std.testing.expectError(error.InvalidChecksum, app.processPanelDueLine("N1 M30 my file.gco*0"));
}

test "setConfig loads an analysis platform and a notifier record" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg_path = ".zig-cache/phobos-analysis-notifier-test.cfg";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data =
        \\[analysis]
        \\platform: linux
        \\
        \\[notifier desk]
        \\url: tgram://token/chat
        \\title: hi
        \\body: there
        \\body_format: text
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);
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
    var params: std.json.ObjectMap = .empty;
    try params.put(a, "name", .{ .string = "desk" });
    try std.testing.expectError(error.AppriseNotAvailable, notifier_component.handleNotifierTest(@ptrCast(app.notifier_ctx), .{ .object = params }, a));
}

test "canonicalPath follows a directory symlink" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const base = ".scratch/phobos-canon-root";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base ++ "/real/config");
    const target = try std.Io.Dir.cwd().realPathFileAlloc(io, base ++ "/real", alloc);
    defer alloc.free(target);
    const link = try alloc.dupeSentinel(u8, base ++ "/data", 0);
    defer alloc.free(link);
    const rc = std.os.linux.symlink(target.ptr, link.ptr);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    const joined = try std.fs.path.join(alloc, &.{ base, "data", "config" });
    const got = canonicalPath(alloc, joined);
    defer alloc.free(got);
    try std.testing.expect(std.mem.endsWith(u8, got, "/real/config"));
}

test "registerKlipperRoots adds config_examples and docs when those directories exist" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var app = try App.init(alloc);
    defer app.deinit(io);
    app.file_ctx.setIo(io);
    const relative_base = ".scratch/phobos-klipper-roots-test";
    try std.Io.Dir.cwd().createDirPath(io, relative_base ++ "/config");
    try std.Io.Dir.cwd().createDirPath(io, relative_base ++ "/docs");
    defer std.Io.Dir.cwd().deleteTree(io, relative_base) catch {};
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, relative_base, alloc);
    defer alloc.free(base);
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

    const cfg_path = "/tmp/phobos-sensor-config-test.cfg";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data = "[sensor chamber]\n" ++
        "type: mqtt\n" ++
        "state_topic: test/chamber\n" ++
        "state_response_template: {% set d = payload|fromjson %}{ set_result(\"temp\", d.t|float) }\n" });
    defer std.Io.Dir.cwd().deleteFile(io, cfg_path) catch {};

    var app = try App.init(alloc);
    defer app.deinit(io);
    app.setConfig(io, cfg_path);

    // Sensor registered with its topic + template.
    const s = app.sensor_ctx.findSensor("chamber") orelse return error.SensorNotRegistered;
    try std.testing.expectEqualStrings("test/chamber", s.state_topic.?);
    try std.testing.expect(s.state_response_template != null);

    // A payload on its topic flows through the template into a measurement.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    app.sensor_ctx.ingestMqttMessage("test/chamber", "{\"t\": 42.5}", arena.allocator());
    try std.testing.expectEqual(@as(f64, 42.5), s.last_measurements.get("temp").?);
}

test "initWithStore: file backend builds + database round-trips" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.initWithStore(alloc, .file, io, null, null);
    defer app.deinit(io);
    try std.testing.expect(app.db_store == .file);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try app.db_ctx.store.insertItem(a, "moonraker", "file_manager.version", .{ .integer = 7 });
    const got = (try app.db_ctx.store.getItem(a, "moonraker", "file_manager.version")).?;
    try std.testing.expectEqual(@as(i64, 7), got.integer);
}

test "initWithStore: data_path sets the datadir (Moonraker -d); null uses a temp dir" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dp = "/tmp/phobos-datadir-test-xyz";
    var app1 = try App.initWithStore(alloc, .sqlite, null, null, dp);
    defer app1.deinit(io);
    try std.testing.expectEqualStrings(dp, app1.datadir);

    var app2 = try App.initWithStore(alloc, .sqlite, null, null, null);
    defer app2.deinit(io);
    // No data_path → a per-instance /tmp dir, never the configured one.
    try std.testing.expect(std.mem.startsWith(u8, app2.datadir, "/tmp/phobos-data-"));
    try std.testing.expect(!std.mem.eql(u8, app2.datadir, dp));
}

test "initWithStore: relative data_path is rejected at startup" {
    const alloc = std.testing.allocator;
    // A relative -d would resolve against an unpredictable cwd — fail-fast.
    try std.testing.expectError(error.InvalidDataPath, App.initWithStore(alloc, .sqlite, null, null, "relative/datadir"));
}

test "initWithStore: nested absolute data_path is created (mkdir -p)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Parent does not exist yet — ensureDirPathRaw must create the whole chain,
    // and each gcodes/config/logs root under it (mkdirChecked). If any step
    // failed, initWithStore would return an error rather than reach here.
    const dp = "/tmp/phobos-ddtest-a/b/c";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "/tmp/phobos-ddtest-a") catch {};
    defer cwd.deleteTree(io, "/tmp/phobos-ddtest-a") catch {};
    var app = try App.initWithStore(alloc, .sqlite, null, null, dp);
    defer app.deinit(io);
    try std.testing.expectEqualStrings(dp, app.datadir);
    // The gcodes root beneath the nested datadir must now be openable.
    var d = try cwd.openDir(io, "/tmp/phobos-ddtest-a/b/c/gcodes", .{});
    d.close(io);
}

test "App.init registers WS-only methods in the dispatcher" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
    defer app.deinit(io);

    try std.testing.expect(app.dispatcher.methods.get("server.connection.identify") != null);
    try std.testing.expect(app.dispatcher.methods.get("server.websocket.id") != null);
}

test "App.init: dispatcher has exactly the expected methods" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(alloc);
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
    var a = try App.init(alloc);
    var b = try App.init(alloc);
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

            var app = try App.init(std.heap.smp_allocator);
            app.deinit(io);
        }
    }.run, .{});
}

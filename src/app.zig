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
const build_options = @import("build_options");

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
const ds = @import("store/datastore.zig");
const config_helper = @import("config/confighelper.zig");

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

// ---------------------------------------------------------------------------
// Null DataStore — used when LMDB is compiled out. Handlers are still
// registered (so --dump-api and tests enumerate all endpoints), but every
// operation returns an error or empty result. This keeps the no-lmdb build
// compiling and allows the coverage dump to enumerate routes.
// ---------------------------------------------------------------------------

const NullStore = struct {
    fn vtGetItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!?std.json.Value {
        return null;
    }
    fn vtInsertItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds.Error!void {
        return ds.Error.BackendError;
    }
    fn vtUpdateItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds.Error!void {
        return ds.Error.BackendError;
    }
    fn vtDeleteItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!std.json.Value {
        return ds.Error.KeyNotFound;
    }
    fn vtListNamespaces(_: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }
    fn vtGetNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds.Error!std.json.Value {
        return .{ .object = .empty };
    }

    const vtable: ds.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };

    // A stable-lifetime singleton ctx pointer. The NullStore has no mutable
    // state; any non-null pointer works. We use a single-byte global.
    var _ctx: u8 = 0;

    pub fn dataStore() ds.DataStore {
        return .{ .ctx = @ptrCast(&_ctx), .vtable = &vtable };
    }
};

/// Create a directory via the raw mkdir syscall (App.init has no live io yet).
/// Ignores already-exists; other failures are non-fatal (the file_manager
/// handlers will surface I/O errors at request time).
fn mkdirRaw(path_z: [:0]const u8) void {
    const rc = std.os.linux.mkdir(path_z.ptr, 0o755);
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) {}
}

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
    file_roots: []FileRoot,
    /// Owns the LMDB environment when with_lmdb=true; void otherwise.
    lmdb_store_ptr: if (build_options.with_lmdb) *@import("store/lmdb_store.zig").LmdbStore else void,
    /// Parsed config, populated by setConfig(). Null when no config file was
    /// loaded (dump-api, tests). Owned; freed in deinit.
    cfg: ?*config_helper.ConfigParser = null,

    pub fn init(alloc: std.mem.Allocator) !App {
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

        // Build the DataStore. When LMDB is enabled, open a temporary directory
        // for tests/dump-api. For no-lmdb builds, use the NullStore which
        // satisfies the vtable without touching the filesystem.
        const lmdb_ptr: if (build_options.with_lmdb) *@import("store/lmdb_store.zig").LmdbStore else void =
            if (build_options.with_lmdb) blk: {
            const LmdbStore = @import("store/lmdb_store.zig").LmdbStore;
            const store_ptr = try alloc.create(LmdbStore);
            errdefer alloc.destroy(store_ptr);
            var path_buf: [256]u8 = undefined;
            const tmp_path = try std.fmt.bufPrintZ(
                &path_buf,
                "/tmp/phobos-db-{x}",
                .{@intFromPtr(store_ptr)},
            );
            const rc = std.os.linux.mkdir(tmp_path.ptr, 0o755);
            if (std.os.linux.errno(rc) != .SUCCESS and std.os.linux.errno(rc) != .EXIST) {
                return error.MkdirFailed;
            }
            store_ptr.* = LmdbStore.open(tmp_path, false) catch |e| {
                alloc.destroy(store_ptr);
                return e;
            };
            db_ctx.* = .{ .store = store_ptr.dataStore() };
            break :blk store_ptr;
        } else {};

        if (!build_options.with_lmdb) {
            db_ctx.* = .{ .store = NullStore.dataStore() };
        }

        // --- History context ---
        const history_ctx = try alloc.create(HistoryCtx);
        errdefer alloc.destroy(history_ctx);
        history_ctx.* = HistoryCtx{
            .store = db_ctx.store,
            .bus = bus,
            .io = null,
            .current_job_id = null,
            .job_user = "No User",
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
        history_ctx.markInterruptedJobs() catch {};

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
        const spoolman_ctx = try alloc.create(SpoolmanCtx);
        errdefer alloc.destroy(spoolman_ctx);
        spoolman_ctx.* = SpoolmanCtx.init(alloc, db_ctx.store, bus);

        // --- MQTT context (no broker; faithful endpoint shapes) ---
        const mqtt_ctx = try alloc.create(MqttCtx);
        errdefer alloc.destroy(mqtt_ctx);
        mqtt_ctx.* = .{};

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
        const dd_tmp = try std.fmt.bufPrintZ(&dd_buf, "/tmp/phobos-data-{x}", .{@intFromPtr(analysis_ctx)});
        mkdirRaw(dd_tmp);
        const datadir = try alloc.dupe(u8, dd_tmp);
        errdefer alloc.free(datadir);

        const root_specs = [_]struct { name: []const u8, full: bool }{
            .{ .name = "gcodes", .full = true },
            .{ .name = "config", .full = true },
            .{ .name = "logs", .full = false },
        };
        const file_roots = try alloc.alloc(FileRoot, root_specs.len);
        errdefer alloc.free(file_roots);
        for (root_specs, 0..) |spec, i| {
            const p = try std.fs.path.join(alloc, &.{ datadir, spec.name });
            const pz = try alloc.dupeZ(u8, p);
            defer alloc.free(pz);
            mkdirRaw(pz);
            file_roots[i] = .{ .name = spec.name, .path = p, .full_access = spec.full };
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
            .sources = &update_manager_component.default_sources,
            .bus = bus,
        };

        // --- Power device context (machine.device_power.*) ---
        // No [power <name>] sections in the spine configuration → empty device
        // list. Real GPIO/network control is STUBBED (see power.zig).
        const power_ctx = try alloc.create(PowerCtx);
        errdefer alloc.destroy(power_ctx);
        power_ctx.* = PowerCtx.init(alloc, bus);

        // --- WLED context (machine.wled.*) ---
        // No [wled <name>] sections in the spine → empty strip list.
        // Real WLED HTTP/serial control is STUBBED (see wled.zig).
        const wled_ctx = try alloc.create(WledCtx);
        errdefer alloc.destroy(wled_ctx);
        wled_ctx.* = WledCtx.init(alloc);

        // --- TD-1 context (machine.td1.*) ---
        // No USB TD-1 devices are enumerated in phobos. Serial port
        // interaction is STUBBED (see td1.zig).
        const td1_ctx = try alloc.create(Td1Ctx);
        errdefer alloc.destroy(td1_ctx);
        td1_ctx.* = .{};

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

        // Wire Klippy dispatch into the job queue so it can start/pause prints.
        job_queue_ctx.setKlippyDispatch(@ptrCast(klippy_ctx), &jobQueueKlippyDispatch);

        // --- OctoPrint compatibility context (/api/*) ---
        const octoprint_ctx = try alloc.create(OctoPrintCtx);
        errdefer alloc.destroy(octoprint_ctx);
        octoprint_ctx.* = .{};

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
            .lmdb_store_ptr = lmdb_ptr,
        };

        try app.registerAll();
        return app;
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
    }

    /// Free all owned resources. `io` is required only for the Connections
    /// registry teardown which needs an Io-aware mutex; pass a threaded io or
    /// use `deinitNoIo` in pure unit tests where no event loop is running.
    pub fn deinit(self: *App, io: std.Io) void {
        self.history_ctx.handleServerExit(self.job_state_ctx.getLastStats());
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
        self.alloc.free(self.datadir);
        self.alloc.destroy(self.file_ctx);
        self.alloc.destroy(self.update_ctx);
        self.power_ctx.deinit();
        self.alloc.destroy(self.power_ctx);
        self.wled_ctx.deinit();
        self.alloc.destroy(self.wled_ctx);
        self.alloc.destroy(self.td1_ctx);
        self.button_ctx.deinit();
        self.alloc.destroy(self.button_ctx);
        self.alloc.destroy(self.printer_ctx);
        self.klippy_ctx.deinit();
        self.alloc.destroy(self.klippy_ctx);
        self.alloc.destroy(self.octoprint_ctx);
        self.alloc.destroy(self.zeroconf_ctx);
        self.alloc.destroy(self.analysis_ctx);
        self.alloc.destroy(self.mqtt_ctx);
        self.alloc.destroy(self.spoolman_ctx);
        if (build_options.with_lmdb) {
            self.lmdb_store_ptr.close();
            self.alloc.destroy(self.lmdb_store_ptr);
        }
        self.sensor_ctx.deinit();
        self.alloc.destroy(self.sensor_ctx);
        self.webcam_ctx.deinit();
        self.alloc.destroy(self.webcam_ctx);
        self.notifier_ctx.* = .{};
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
    }

    /// Returns the HTTP transport Server configured with this App's components.
    /// The caller must supply a live `io` (from a threaded event loop). The
    /// returned Server borrows all App-owned pointers; the App must outlive it.
    pub fn httpServer(self: *App, io: std.Io) http_transport.Server {
        // Wire the live io into the spoolman component so it can emit
        // notify_active_spool_set to connected WebSocket clients.
        self.spoolman_ctx.setIo(io);
        // Wire io into the file manager so it can emit notify_filelist_changed.
        self.file_ctx.setIo(io);
        // Wire io into the machine component for /proc & /sys reads.
        self.machine_ctx.setIo(io);
        // Wire io into the update manager so it can emit notify_update_response /
        // notify_update_refreshed to connected WebSocket clients.
        self.update_ctx.setIo(io);
        // Wire io into the power component so it can emit notify_power_changed.
        self.power_ctx.setIo(io);
        // Wire io into the button component so it can emit notify_button_event.
        self.button_ctx.setIo(io);
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
        };
    }
};

/// Placeholder handler for WS-only methods registered in the dispatcher for
/// reflection purposes. The real implementations in `transport/ws.zig`
/// intercept those method names before the dispatcher is consulted.
fn wsStubHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.WsOnlyMethod;
}

/// Dispatches a gcode request to Klippy on behalf of the job_queue component.
/// This is the adapter that bridges job_queue's anyopaque dispatch to
/// KlippyCtx.request(). Called via JobQueueCtx.setKlippyDispatch.
fn jobQueueKlippyDispatch(klippy_opaque: *anyopaque, method: []const u8, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const k: *KlippyConnectionCtx = @ptrCast(@alignCast(klippy_opaque));
    return k.request(method, params, alloc);
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
        "server.database.item",
        "server.database.compact",
        "server.database.post_backup",
        "server.database.delete_backup",
        "server.database.restore",
        // Database debug
        "debug.database.list",
        "debug.database.item",
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
        // Webcam (item endpoint follows single-method pattern like database.item)
        "server.webcams.list",
        "server.webcams.item",
        "server.webcams.test",
        // Sensor
        "server.sensors.list",
        "server.sensors.info",
        "server.sensors.measurements",
        // Authorization (access.*)
        "access.login",
        "access.logout",
        "access.refresh_jwt",
        "access.user",
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
        "server.files.directory",
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
        // WS-only stubs
        "server.connection.identify",
        "server.websocket.id",
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

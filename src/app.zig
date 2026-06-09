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


/// Create a directory via the raw mkdir syscall (App.init has no live io yet).
/// Ignores already-exists; other failures are non-fatal (the file_manager
/// handlers will surface I/O errors at request time).
fn mkdirRaw(path_z: [:0]const u8) void {
    const rc = std.os.linux.mkdir(path_z.ptr, 0o755);
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS and e != .EXIST) {}
}

/// Which DataStore backend to use. `sqlite` (default) is Moonraker
/// `moonraker-sql.db`-compatible and needs no `io` handle; `file` is the pure-Zig
/// atomic-rename JSON backend (no C dependency) and requires an `io` handle.
/// Selected via `[database] backend` in the config.
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
    file_roots: []FileRoot,
    /// Owns the active DataStore backend (SQLite or atomic-rename file).
    db_store: StoreHolder,
    /// Parsed config, populated by setConfig(). Null when no config file was
    /// loaded (dump-api, tests). Owned; freed in deinit.
    cfg: ?*config_helper.ConfigParser = null,
    /// Allowed CORS origins from `[authorization] cors_domains`. Each slice + the
    /// outer array are gpa-owned; freed in deinit. Passed to the HTTP server.
    cors_domains: [][]const u8 = &.{},

    /// Default entry point: SQLite backend, no io needed at init time.
    pub fn init(alloc: std.mem.Allocator) !App {
        return initWithStore(alloc, .sqlite, null, null);
    }

    /// Assemble the App with an explicit DataStore backend. The `file` backend
    /// needs a live `io` handle (filesystem); `sqlite` ignores it.
    pub fn initWithStore(alloc: std.mem.Allocator, db_backend: StoreBackend, db_io: ?std.Io, db_path: ?[]const u8) !App {
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
                        try std.fmt.bufPrintZ(&path_buf, "{s}", .{p})
                    else
                        try std.fmt.bufPrintZ(&path_buf, "/tmp/phobos-db-{x}.db", .{@intFromPtr(db_ctx)});
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
        klippy_ctx.octoprint = octoprint_ctx;
        klippy_ctx.temp_store = data_store_ctx;

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

        // Wire job_queue transition gcode/delay from [job_queue] section.
        if (cfg.hasSection("job_queue")) {
            const tg = cfg.get("job_queue", "job_transition_gcode");
            const td: f64 = cfg.getFloat("job_queue", "job_transition_delay") catch 0.0;
            self.job_queue_ctx.setTransitionConfig(tg, td);
        }

        // Wire MQTT broker config from [mqtt] section.
        if (cfg.hasSection("mqtt")) {
            const host = cfg.get("mqtt", "host") orelse "localhost";
            const port: u16 = @intCast(cfg.getInt("mqtt", "port") catch @as(i64, 1883));
            const username = cfg.get("mqtt", "username");
            const password = cfg.get("mqtt", "password");
            self.mqtt_ctx.setConfig(host, port, username, password) catch {};
            if (cfg.get("mqtt", "instance_name")) |iname| {
                self.mqtt_ctx.setInstanceName(iname) catch {};
            }
            if (cfg.get("mqtt", "client_id")) |cid| {
                self.mqtt_ctx.setClientId(cid) catch {};
            }
            if (cfg.get("mqtt", "default_qos")) |qos_str| {
                const qos: u8 = @intCast(std.fmt.parseInt(i64, qos_str, 10) catch @as(i64, 0));
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

        // Wire WLED strips from [wled <name>] sections.
        if (cfg.sectionNames(self.alloc)) |names| {
            defer self.alloc.free(names);
            for (names) |sect| {
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
                const port: u16 = @intCast(cfg.getInt(sect, "port") catch @as(i64, 80));
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
                    if (cfg.get(sect, "state_topic")) |t| self.sensor_ctx.setSensorTopic(sname, t) catch {};
                    if (cfg.get(sect, "state_response_template")) |tm| self.sensor_ctx.setSensorTemplate(sname, tm) catch {};
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
        self.alloc.free(self.datadir);
        self.alloc.destroy(self.file_ctx);
        self.alloc.destroy(self.update_ctx);
        self.power_ctx.deinit();
        self.alloc.destroy(self.power_ctx);
        self.wled_ctx.deinit();
        self.alloc.destroy(self.wled_ctx);
        self.td1_ctx.deinit();
        self.alloc.destroy(self.td1_ctx);
        self.button_ctx.deinit();
        self.alloc.destroy(self.button_ctx);
        self.alloc.destroy(self.printer_ctx);
        self.klippy_ctx.deinit();
        self.alloc.destroy(self.klippy_ctx);
        self.alloc.destroy(self.octoprint_ctx);
        self.alloc.destroy(self.zeroconf_ctx);
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
    }

    /// Returns the HTTP transport Server configured with this App's components.
    /// The caller must supply a live `io` (from a threaded event loop). The
    /// returned Server borrows all App-owned pointers; the App must outlive it.
    pub fn httpServer(self: *App, io: std.Io) http_transport.Server {
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
    const io = app.mqtt_ctx.io orelse return error.NotReady;
    return app.core.run(io, Dispatcher.handle, .{ app.dispatcher, payload, alloc });
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

test "setConfig parses [sensor <name>] and wires topic + state_response_template" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg_path = "/tmp/phobos-sensor-config-test.cfg";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfg_path, .data =
        "[sensor chamber]\n" ++
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

    var app = try App.initWithStore(alloc, .file, io, null);
    defer app.deinit(io);
    try std.testing.expect(app.db_store == .file);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try app.db_ctx.store.insertItem(a, "moonraker", "file_manager.version", .{ .integer = 7 });
    const got = (try app.db_ctx.store.getItem(a, "moonraker", "file_manager.version")).?;
    try std.testing.expectEqual(@as(i64, 7), got.integer);
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

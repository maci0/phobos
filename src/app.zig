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
const ds = @import("store/datastore.zig");

const Registry = registry.Registry;
const Dispatcher = jsonrpc.Dispatcher;
const Connections = connections.Connections;
const NotifyBus = notify.NotifyBus;
const ServerInfo = methods.ServerInfo;
const DbCtx = db_component.DbCtx;

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
    /// Owns the LMDB environment when with_lmdb=true; void otherwise.
    lmdb_store_ptr: if (build_options.with_lmdb) *@import("store/lmdb_store.zig").LmdbStore else void,

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

        var app = App{
            .alloc = alloc,
            .core = core,
            .dispatcher = dispatcher,
            .reg = reg,
            .info = info,
            .conns = conns,
            .bus = bus,
            .db_ctx = db_ctx,
            .lmdb_store_ptr = lmdb_ptr,
        };

        try app.registerAll();
        return app;
    }

    /// Free all owned resources. `io` is required only for the Connections
    /// registry teardown which needs an Io-aware mutex; pass a threaded io or
    /// use `deinitNoIo` in pure unit tests where no event loop is running.
    pub fn deinit(self: *App, io: std.Io) void {
        self.conns.deinit(io);
        self.reg.deinit();
        self.dispatcher.deinit();
        if (build_options.with_lmdb) {
            self.lmdb_store_ptr.close();
            self.alloc.destroy(self.lmdb_store_ptr);
        }
        self.alloc.destroy(self.bus);
        self.alloc.destroy(self.conns);
        self.alloc.destroy(self.info);
        self.alloc.destroy(self.db_ctx);
        self.alloc.destroy(self.reg);
        self.alloc.destroy(self.dispatcher);
        self.alloc.destroy(self.core);
    }

    /// Register ALL currently-implemented endpoints, JSON-RPC methods, and
    /// transport routes in one place. This is the single authoritative list of
    /// what phobos exposes. Extend this function when adding new handlers.
    fn registerAll(self: *App) !void {
        // Core HTTP + JSON-RPC endpoints: server.info, server.config.
        try methods.registerCore(self.reg, self.info);

        // Database component: server.database.* endpoints.
        try db_component.registerDatabase(self.reg, self.db_ctx);

        // WS-only methods (server.connection.identify, server.websocket.id)
        // are handled inside the WS transport layer per-connection (they need
        // the live *Connection). Register them in the dispatcher so the
        // --dump-api reflection sees them, pointing at a no-op ctx for now.
        try self.dispatcher.register(
            ws.identify_method,
            @ptrCast(self.info),
            wsStubHandler,
        );
        try self.dispatcher.register(
            ws.websocket_id_method,
            @ptrCast(self.info),
            wsStubHandler,
        );
    }

    /// Returns the HTTP transport Server configured with this App's components.
    /// The caller must supply a live `io` (from a threaded event loop). The
    /// returned Server borrows all App-owned pointers; the App must outlive it.
    pub fn httpServer(self: *App, io: std.Io) http_transport.Server {
        return .{
            .io = io,
            .core = self.core,
            .reg = self.reg,
            .dispatcher = self.dispatcher,
            .conns = self.conns,
        };
    }
};

/// Placeholder handler for WS-only methods registered in the dispatcher for
/// reflection purposes. The real implementations in `transport/ws.zig`
/// intercept those method names before the dispatcher is consulted.
fn wsStubHandler(_: *anyopaque, _: std.json.Value, _: std.mem.Allocator) anyerror!std.json.Value {
    return error.WsOnlyMethod;
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

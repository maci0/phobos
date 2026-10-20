//! server.analysis.* API component — Moonraker-compatible GCode analysis.
//!
//! Matches the endpoints registered in
//! `vendor/moonraker/moonraker/components/analysis.py` (GcodeAnalysis):
//!
//!   GET  /server/analysis/status      → server.analysis.status
//!   POST /server/analysis/estimate    → server.analysis.estimate
//!   POST /server/analysis/process     → server.analysis.process
//!   POST /server/analysis/dump_config → server.analysis.dump_config
//!
//! Execution requires an injected Runner. Commands run serially outside Core
//! with a cancel-and-join deadline. Request files are copied to a private
//! workspace; post-processing commits atomically after rechecking the source.
//! No executable is downloaded and no default process runner is installed.

const std = @import("std");
const webreq = @import("../json/params.zig");
const registry = @import("../server/registry.zig");
const file_manager = @import("file_manager.zig");
const Core = @import("../server/core.zig").Core;
const jv = @import("../json/value.zig");
const Io = std.Io;

const Registry = registry.Registry;

pub const Runner = struct {
    context: *anyopaque,
    /// Return stdout owned by `alloc`, bounded by max_output_bytes. Honor I/O
    /// cancellation and join children; argv contains private paths, no secrets.
    run: *const fn (*anyopaque, Io, std.mem.Allocator, []const []const u8) anyerror![]u8,
};

pub const default_estimator_timeout: Io.Duration = .fromSeconds(600);
const probe_timeout: Io.Duration = .fromSeconds(10);
pub const max_output_bytes = 1024 * 1024;
const footer_bytes = 64 * 1024;
const default_config_name = "default_estimator_cfg.json";
const max_version_bytes = 64;

pub const AnalysisCtx = struct {
    /// Borrowed datadir; workspaces must remain outside API-writable roots.
    data_path: []const u8 = "",
    /// Path to the `klipper_estimator` binary. Empty means `[analysis]` is absent.
    estimator_path: []const u8 = "",
    /// Estimator config file reported by status.
    estimator_config: []const u8 = "",
    /// True when `estimator_path` and `estimator_config` are allocator-owned.
    paths_owned: bool = false,
    io: ?std.Io = null,
    /// Resolves request filenames under the gcodes root. Borrowed from the App.
    files: ?*const file_manager.FileCtx = null,
    /// Runtime handlers enter with Core held. Direct pre-runtime calls leave it null.
    core: ?*Core = null,
    klippy_ready: bool = false,
    runner: ?Runner = null,
    timeout: Io.Duration = default_estimator_timeout,
    command_mutex: Io.Mutex = .init,
    version_checked: bool = false,
    ready: bool = false,
    version_buf: [max_version_bytes]u8 = undefined,
    version_len: usize = 0,

    /// Configure before serving requests. The embedding owns the runner context.
    pub fn setRunner(self: *AnalysisCtx, runner: ?Runner) void {
        self.runner = runner;
        self.version_checked = false;
        self.ready = false;
        self.version_len = 0;
    }

    pub fn deinit(self: *AnalysisCtx, alloc: std.mem.Allocator) void {
        if (!self.paths_owned) return;
        alloc.free(self.estimator_path);
        alloc.free(self.estimator_config);
        self.estimator_path = "";
        self.estimator_config = "";
        self.paths_owned = false;
    }

    fn begin(self: *AnalysisCtx, io: Io) !void {
        if (self.core) |core| core.unlock(io);
        errdefer if (self.core) |core| core.lock(io);
        try self.command_mutex.lock(io);
    }

    fn end(self: *AnalysisCtx, io: Io) void {
        self.command_mutex.unlock(io);
        if (self.core) |core| core.lock(io);
    }

    fn version(self: *const AnalysisCtx) []const u8 {
        return if (self.ready) self.version_buf[0..self.version_len] else "?";
    }
};

/// Caller owns returned stdout. The background callback only receives smp_allocator.
fn runCommand(ctx: *AnalysisCtx, io: Io, alloc: std.mem.Allocator, argv: []const []const u8, timeout: Io.Duration) ![]u8 {
    const Call = struct {
        runner: Runner,
        io: Io,
        argv: []const []const u8,
        output: ?[]u8 = null,
        fn invoke(self: *@This()) !void {
            self.output = try self.runner.run(self.runner.context, self.io, std.heap.smp_allocator, self.argv);
        }
    };
    var call: Call = .{ .runner = ctx.runner orelse return error.EstimatorNotAvailable, .io = io, .argv = argv };
    defer if (call.output) |output| std.heap.smp_allocator.free(output);
    const Outcome = union(enum) { done: anyerror!void, expired: Io.Cancelable!void };
    var outcomes: [2]Outcome = undefined;
    var tasks: Io.Select(Outcome) = .init(io, &outcomes);
    defer tasks.cancelDiscard();
    try tasks.concurrent(.done, Call.invoke, .{&call});
    try tasks.concurrent(.expired, Io.sleep, .{ io, timeout, .awake });
    switch (try tasks.await()) {
        .expired => |result| {
            try result;
            return error.EstimatorTimedOut;
        },
        .done => |result| result catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return error.EstimatorCommandFailed,
        },
    }
    tasks.cancelDiscard();
    const output = call.output.?;
    if (output.len > max_output_bytes or !std.unicode.utf8ValidateSlice(output)) return error.EstimatorInvalidOutput;
    return alloc.dupe(u8, output);
}

fn versionToken(text: []const u8) ?[]const u8 {
    var i: usize = if (std.mem.startsWith(u8, text, "v")) 1 else 0;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i == start) return null;
    while (i + 1 < text.len and text[i] == '.' and std.ascii.isDigit(text[i + 1])) {
        i += 2;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    }
    if (i > max_version_bytes) return null;
    return text[0..i];
}

fn ensureReady(ctx: *AnalysisCtx, io: Io, alloc: std.mem.Allocator) !bool {
    if (ctx.runner == null or ctx.estimator_path.len == 0) return false;
    if (ctx.version_checked) return ctx.ready;
    const output = runCommand(ctx, io, alloc, &.{ ctx.estimator_path, "--version" }, probe_timeout) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => {
            ctx.version_checked = true;
            return false;
        },
    };
    defer alloc.free(output);
    ctx.version_checked = true;
    const prefix = "klipper_estimator ";
    if (!std.mem.startsWith(u8, output, prefix)) return false;
    const version = versionToken(output[prefix.len..]) orelse return false;
    @memcpy(ctx.version_buf[0..version.len], version);
    ctx.version_len = version.len;
    ctx.ready = true;
    return true;
}

fn parseOutput(alloc: std.mem.Allocator, output: []const u8) !std.json.Value {
    if (output.len > max_output_bytes or !std.unicode.utf8ValidateSlice(output)) return error.EstimatorInvalidOutput;
    const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.EstimatorInvalidOutput,
    };
    if (value != .object or jv.exceedsDepth(value, jv.max_value_depth)) return error.EstimatorInvalidOutput;
    return value;
}

fn rootPath(ctx: *const AnalysisCtx, alloc: std.mem.Allocator, root: []const u8, path: []const u8) !file_manager.Resolved {
    const files = ctx.files orelse return error.EstimatorNotAvailable;
    return file_manager.resolveRequestPath(files, alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, std.mem.trim(u8, path, "/") }));
}

fn toolPath(ctx: *const AnalysisCtx, alloc: std.mem.Allocator, name: []const u8) !file_manager.Resolved {
    if (ctx.data_path.len == 0) return error.EstimatorNotAvailable;
    return .{
        .root = .{ .name = "analysis", .path = ctx.data_path, .full_access = true },
        .rel = try std.fs.path.join(alloc, &.{ "tools/klipper_estimator", name }),
        .abs = try std.fs.path.join(alloc, &.{ ctx.data_path, "tools/klipper_estimator", name }),
    };
}

fn usingDefault(ctx: *const AnalysisCtx) bool {
    if (ctx.estimator_config.len == 0) return true;
    return std.mem.eql(u8, std.fs.path.basename(ctx.estimator_config), default_config_name) and
        std.mem.eql(u8, std.fs.path.dirname(ctx.estimator_path) orelse "", std.fs.path.dirname(ctx.estimator_config) orelse "");
}

fn configPath(ctx: *const AnalysisCtx, alloc: std.mem.Allocator, override: ?[]const u8) !file_manager.Resolved {
    if (override) |path| return rootPath(ctx, alloc, "config", path);
    if (usingDefault(ctx) and ctx.data_path.len != 0) return toolPath(ctx, alloc, default_config_name);
    // Configured absolute paths are startup-owned, never request paths.
    if (ctx.estimator_config.len == 0) return error.EstimatorConfigNotFound;
    if (ctx.files) |files| {
        const root = files.findRoot("config") orelse return error.EstimatorConfigNotFound;
        if (!std.mem.startsWith(u8, ctx.estimator_config, root.path) or ctx.estimator_config.len <= root.path.len or ctx.estimator_config[root.path.len] != '/') return error.Forbidden;
        return rootPath(ctx, alloc, "config", ctx.estimator_config[root.path.len + 1 ..]);
    }
    return .{
        .root = .{ .name = "config", .path = std.fs.path.dirname(ctx.estimator_config) orelse ".", .full_access = true },
        .rel = std.fs.path.basename(ctx.estimator_config),
        .abs = ctx.estimator_config,
    };
}

fn copyOpen(io: Io, source: Io.File, destination: file_manager.Resolved, alloc: std.mem.Allocator) !void {
    const stat = try source.stat(io);
    var parent = try destination.parent(io, alloc, .{ .make_path = true });
    defer parent.close(io);
    var output = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true, .permissions = stat.permissions });
    defer output.deinit(io);
    try copyContents(io, source, output.file);
    try output.replace(io);
}

fn copyContents(io: Io, source: Io.File, destination: Io.File) !void {
    const stat = try source.stat(io);
    var reader: Io.File.Reader = .initSize(source, io, &.{}, stat.size);
    var buffer: [4096]u8 = undefined;
    var writer = destination.writer(io, &buffer);
    try reader.interface.streamExact64(&writer.interface, stat.size);
    try writer.flush();
    try destination.sync(io);
}

const Workspace = struct {
    base: Io.Dir,
    dir: Io.Dir,
    name: [32]u8,
    path: []const u8,

    fn init(ctx: *const AnalysisCtx, io: Io, alloc: std.mem.Allocator) !Workspace {
        const tool = try toolPath(ctx, alloc, ".");
        var parent = try tool.parent(io, alloc, .{ .make_path = true });
        defer parent.close(io);
        parent.dir.createDir(io, parent.name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const base = try parent.dir.openDir(io, parent.name, .{ .follow_symlinks = false });
        errdefer base.close(io);
        var canonical: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = canonical[0..try base.realPath(io, &canonical)];
        if (ctx.files) |files| for (files.roots) |root| {
            if (!root.full_access) continue;
            if (std.mem.eql(u8, root.path, "/") or std.mem.eql(u8, path, root.path) or (std.mem.startsWith(u8, path, root.path) and path.len > root.path.len and path[root.path.len] == '/')) return error.Forbidden;
        };
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        try base.createDir(io, &name, .fromMode(0o700));
        errdefer base.deleteTree(io, &name) catch {};
        const dir = try base.openDir(io, &name, .{ .follow_symlinks = false });
        errdefer dir.close(io);
        return .{ .base = base, .dir = dir, .name = name, .path = try std.fs.path.join(alloc, &.{ path, &name }) };
    }

    fn deinit(self: *Workspace, io: Io) void {
        self.dir.close(io);
        self.base.deleteTree(io, &self.name) catch |err| std.log.warn("analysis workspace cleanup: {}", .{err});
        self.base.close(io);
    }

    fn resolve(self: *const Workspace, alloc: std.mem.Allocator, name: []const u8) !file_manager.Resolved {
        return .{ .root = .{ .name = "analysis", .path = self.path, .full_access = true }, .rel = name, .abs = try std.fs.path.join(alloc, &.{ self.path, name }) };
    }
};

fn processedVersion(io: Io, file: Io.File, alloc: std.mem.Allocator) !?[]const u8 {
    const stat = try file.stat(io);
    var buffer: [footer_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, stat.size -| footer_bytes);
    // Match Python's decode(errors="ignore") without allocating another footer.
    var read: usize = 0;
    var written: usize = 0;
    while (read < count) {
        const length = std.unicode.utf8ByteSequenceLength(buffer[read]) catch {
            read += 1;
            continue;
        };
        if (length > count - read) {
            read += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(buffer[read..][0..length]) catch {
            read += 1;
            continue;
        };
        std.mem.copyForwards(u8, buffer[written..][0..length], buffer[read..][0..length]);
        read += length;
        written += length;
    }
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, buffer[0..written], '\n');
    const prefix = "; Processed by klipper_estimator ";
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            if (versionToken(line[prefix.len..])) |version| result = version;
        }
    }
    return if (result) |version| try alloc.dupe(u8, version) else null;
}

fn checkWritable(ctx: *const AnalysisCtx, io: Io, path: file_manager.Resolved, source: Io.File, alloc: std.mem.Allocator) !void {
    const files = ctx.files orelse return error.EstimatorNotAvailable;
    if (!path.root.full_access) return error.Forbidden;
    try files.checkInUse(path, false);
    const jobs = files.job_state orelse return;
    if (!jobs.isActive()) return;
    const loaded = jobs.getLastStats().get("filename") orelse return;
    if (loaded != .string or loaded.string.len == 0) return;
    const active_path = try rootPath(ctx, alloc, "gcodes", loaded.string);
    const active = active_path.openFile(io, alloc) catch return error.FileInUse;
    defer active.close(io);
    if ((try active.stat(io)).inode == (try source.stat(io)).inode) return error.FileInUse;
}

/// Moonraker rejects `..` path segments in estimator_config and dest_config.
fn hasDotDot(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /server/analysis/status
pub fn handleStatus(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const aio = ctx.io;
    if (aio) |io| try ctx.begin(io);
    defer if (aio) |io| ctx.end(io);
    if (aio) |io| _ = try ensureReady(ctx, io, alloc);
    const exec: []const u8 = if (ctx.estimator_path.len == 0) "unknown" else std.fs.path.basename(ctx.estimator_path);
    const cfg_exists = if (aio) |io| exists: {
        const path = configPath(ctx, alloc, null) catch break :exists false;
        const file = path.openFile(io, alloc) catch break :exists false;
        file.close(io);
        break :exists true;
    } else false;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "estimator_executable", .{ .string = exec });
    try obj.put(alloc, "estimator_ready", .{ .bool = ctx.ready });
    try obj.put(alloc, "estimator_version", .{ .string = try alloc.dupe(u8, ctx.version()) });
    try obj.put(alloc, "estimator_config_exists", .{ .bool = cfg_exists });
    try obj.put(alloc, "using_default_config", .{ .bool = usingDefault(ctx) });
    return .{ .object = obj };
}

/// POST /server/analysis/estimate and /server/analysis/process
/// (analysis.py `_handle_estimator_request`). params: filename (required),
/// estimator_config (optional, under the config root).
pub fn handleEstimate(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return runFile(ctx_ptr, params, alloc, false);
}

pub fn handleProcess(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    return runFile(ctx_ptr, params, alloc, true);
}

fn runFile(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator, process: bool) !std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const raw = (try webreq.optional([]const u8, params, "filename")) orelse return error.InvalidParams;
    const filename = std.mem.trim(u8, raw, "/");
    const files = ctx.files orelse return error.GcodeNotFound;
    const io = ctx.io orelse files.io orelse return error.GcodeNotFound;
    const path = rootPath(ctx, alloc, "gcodes", filename) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GcodeNotFound,
    };
    const source = path.openFile(io, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GcodeNotFound,
    };
    defer source.close(io);
    const override = try webreq.optional([]const u8, params, "estimator_config");
    if (override) |cfg| {
        if (hasDotDot(cfg)) return error.InvalidParams;
    }
    const force = if (process) (try webreq.optional(bool, params, "force")) orelse false else false;
    if (ctx.runner == null or ctx.estimator_path.len == 0) return error.EstimatorNotAvailable;
    if (process) try checkWritable(ctx, io, path, source, alloc);
    try ctx.begin(io);
    defer ctx.end(io);
    if (!try ensureReady(ctx, io, alloc)) return error.EstimatorNotAvailable;
    const config = try configPath(ctx, alloc, override);
    const cfg = config.openFile(io, alloc) catch return error.EstimatorConfigNotFound;
    defer cfg.close(io);
    const previous = if (process) try processedVersion(io, source, alloc) else null;
    const bypassed = previous != null and !force;
    var result: std.json.ObjectMap = .empty;
    if (process) {
        try result.put(alloc, "prev_processed", .{ .bool = previous != null });
        try result.put(alloc, "version", .{ .string = if (bypassed) previous.? else try alloc.dupe(u8, ctx.version()) });
        try result.put(alloc, "bypassed", .{ .bool = bypassed });
    }
    if (!bypassed) {
        const before = try source.stat(io);
        var workspace = try Workspace.init(ctx, io, alloc);
        defer workspace.deinit(io);
        const input = try workspace.resolve(alloc, "input.gcode");
        const config_copy = try workspace.resolve(alloc, "config.json");
        try copyOpen(io, source, input, alloc);
        try copyOpen(io, cfg, config_copy, alloc);
        const argv: []const []const u8 = if (process)
            &.{ ctx.estimator_path, "--config_file", config_copy.abs, "post-process", input.abs }
        else
            &.{ ctx.estimator_path, "--config_file", config_copy.abs, "estimate", "-f", "json", input.abs };
        const output = try runCommand(ctx, io, alloc, argv, ctx.timeout);
        if (!process) {
            const value = try parseOutput(alloc, output);
            const sequences = value.object.get("sequences") orelse return error.EstimatorInvalidOutput;
            if (sequences != .array or sequences.array.items.len == 0 or sequences.array.items[0] != .object) return error.EstimatorInvalidOutput;
            return sequences.array.items[0];
        }
        const processed = try input.openFile(io, alloc);
        defer processed.close(io);
        var parent = try path.parent(io, alloc, .{});
        defer parent.close(io);
        var pending = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true, .permissions = before.permissions });
        defer pending.deinit(io);
        try copyContents(io, processed, pending.file);
        // Commit under Core so a print cannot start between its check and replace.
        if (ctx.core) |core| core.lock(io);
        defer if (ctx.core) |core| core.unlock(io);
        try checkWritable(ctx, io, path, source, alloc);
        const current = try path.stat(io, alloc);
        if (current.inode != before.inode or current.size != before.size or current.mtime.nanoseconds != before.mtime.nanoseconds or current.ctime.nanoseconds != before.ctime.nanoseconds) return error.EstimatorFileChanged;
        var current_parent = try path.parent(io, alloc, .{});
        defer current_parent.close(io);
        if ((try current_parent.dir.stat(io)).inode != (try parent.dir.stat(io)).inode) return error.EstimatorFileChanged;
        try pending.replace(io);
    }
    return .{ .object = result };
}

/// POST /server/analysis/dump_config. params: dest_config (optional).
pub fn handleDumpConfig(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *AnalysisCtx = @ptrCast(@alignCast(ctx_ptr));
    const dest = try webreq.optional([]const u8, params, "dest_config");
    if (dest) |name| {
        if (hasDotDot(name)) return error.InvalidParams;
    }
    const io = ctx.io orelse return error.EstimatorNotAvailable;
    try ctx.begin(io);
    defer ctx.end(io);
    if (!try ensureReady(ctx, io, alloc)) return error.EstimatorNotAvailable;
    if (ctx.core) |core| core.lock(io);
    const ready = ctx.klippy_ready;
    if (ctx.core) |core| core.unlock(io);
    if (!ready) return error.EstimatorKlippyNotReady;
    const path = if (dest) |name| try rootPath(ctx, alloc, "config", name) else try toolPath(ctx, alloc, default_config_name);
    if (!path.root.full_access or path.rel.len == 0) return error.Forbidden;
    const output = try runCommand(ctx, io, alloc, &.{ ctx.estimator_path, "dump-config" }, probe_timeout);
    const value = try parseOutput(alloc, output);
    var result: std.json.ObjectMap = .empty;
    try result.put(alloc, "dest_root", if (dest != null) .{ .string = "config" } else .null);
    try result.put(alloc, "dest_config_path", .{ .string = if (dest) |name| std.mem.trim(u8, name, "/") else default_config_name });
    try result.put(alloc, "klipper_estimator_config", value);
    var parent = try path.parent(io, alloc, .{ .make_path = true });
    defer parent.close(io);
    var file = try parent.dir.createFileAtomic(io, parent.name, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writePositionalAll(io, output, 0);
    try file.file.sync(io);
    if (ctx.core) |core| core.lock(io);
    defer if (ctx.core) |core| core.unlock(io);
    if (!ctx.klippy_ready) return error.EstimatorKlippyNotReady;
    var current_parent = try path.parent(io, alloc, .{});
    defer current_parent.close(io);
    if ((try current_parent.dir.stat(io)).inode != (try parent.dir.stat(io)).inode) return error.Conflict;
    try file.replace(io);
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerAnalysis(reg: *Registry, ctx: *AnalysisCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);
    try reg.registerEndpoint(.{ .path = "/server/analysis/status", .methods = &.{.GET} }, c, handleStatus);
    try reg.registerEndpoint(.{ .path = "/server/analysis/estimate", .methods = &.{.POST} }, c, handleEstimate);
    try reg.registerEndpoint(.{ .path = "/server/analysis/process", .methods = &.{.POST} }, c, handleProcess);
    try reg.registerEndpoint(.{ .path = "/server/analysis/dump_config", .methods = &.{.POST} }, c, handleDumpConfig);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

test "handleStatus: estimator is never ready; config existence is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = AnalysisCtx{};
    const empty = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("unknown", empty.object.get("estimator_executable").?.string);
    try testing.expectEqual(false, empty.object.get("estimator_ready").?.bool);
    try testing.expectEqualStrings("?", empty.object.get("estimator_version").?.string);
    try testing.expectEqual(false, empty.object.get("estimator_config_exists").?.bool);
    try testing.expectEqual(true, empty.object.get("using_default_config").?.bool);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "est", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "custom.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    ctx = .{
        .estimator_path = try std.fs.path.join(a, &.{ root, "est" }),
        .estimator_config = try std.fs.path.join(a, &.{ root, "custom.json" }),
        .io = testing.io,
    };
    const present = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("est", present.object.get("estimator_executable").?.string);
    try testing.expectEqual(false, present.object.get("estimator_ready").?.bool);
    try testing.expectEqual(true, present.object.get("estimator_config_exists").?.bool);
    try testing.expectEqual(false, present.object.get("using_default_config").?.bool);
}

test "handleEstimate: filename resolves under the gcodes root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "gcodes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gcodes/job.gcode", .data = "G1 X1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.gcode", .data = "G1 X1\n" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const roots = [_]file_manager.Root{.{ .name = "gcodes", .path = try std.fs.path.join(a, &.{ base, "gcodes" }), .full_access = true }};
    const files: file_manager.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = testing.io };
    var ctx = AnalysisCtx{ .files = &files };

    try testing.expectError(error.InvalidParams, handleEstimate(@ptrCast(&ctx), .null, a));
    // A path outside the gcodes root, even one that exists relative to cwd,
    // is not found.
    const outside = try std.fmt.allocPrint(a, "{{\"filename\":\"{s}/outside.gcode\"}}", .{base});
    try testing.expectError(error.GcodeNotFound, handleEstimate(@ptrCast(&ctx), try mkParams(a, outside), a));
    try testing.expectError(error.GcodeNotFound, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"../outside.gcode\"}"), a));
    try testing.expectError(error.InvalidParams, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"/job.gcode\",\"estimator_config\":\"../x.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleEstimate(@ptrCast(&ctx), try mkParams(a, "{\"filename\":\"/job.gcode\",\"force\":true}"), a));
}

test "handleDumpConfig: dotdot is rejected, otherwise EstimatorNotAvailable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = AnalysisCtx{};
    try testing.expectError(error.InvalidParams, handleDumpConfig(@ptrCast(&ctx), try mkParams(a, "{\"dest_config\":\"a/../secret.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), try mkParams(a, "{\"dest_config\":\"my..config.json\"}"), a));
    try testing.expectError(error.EstimatorNotAvailable, handleDumpConfig(@ptrCast(&ctx), .null, a));
}

test "registerAnalysis: wires expected routes and JSON-RPC methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");

    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var ctx = AnalysisCtx{};
    try registerAnalysis(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/server/analysis/status") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/estimate") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/process") != null);
    try testing.expect(reg.lookup(.POST, "/server/analysis/dump_config") != null);

    try testing.expect(d.methods.get("server.analysis.status") != null);
    try testing.expect(d.methods.get("server.analysis.estimate") != null);
    try testing.expect(d.methods.get("server.analysis.process") != null);
    try testing.expect(d.methods.get("server.analysis.dump_config") != null);
}

test "analysis injected runner detects readiness and version" {
    const Backend = struct {
        fn run(_: *anyopaque, _: Io, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
            try testing.expectEqual(2, argv.len);
            try testing.expectEqualStrings("--version", argv[1]);
            return alloc.dupe(u8, "klipper_estimator v0.4.0\n");
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    var ctx: AnalysisCtx = .{ .io = testing.io, .estimator_path = "/injected/klipper_estimator" };
    ctx.setRunner(.{ .context = &dummy, .run = Backend.run });
    const status = try handleStatus(&ctx, .null, arena.allocator());
    try testing.expect(status.object.get("estimator_ready").?.bool);
    try testing.expectEqualStrings("v0.4.0", status.object.get("estimator_version").?.string);
}

const fixture_script =
    \\#!/bin/sh
    \\if [ "$1" = "--version" ]; then printf '%s\n' 'klipper_estimator v0.4.0'; exit 0; fi
    \\if [ "$1" = "dump-config" ]; then printf '%s' '{"printer":{"max_velocity":300}}'; exit 0; fi
    \\[ "$1" = "--config_file" ] && [ -f "$2" ] || exit 2
    \\case "$3" in
    \\  estimate) [ "$4" = "-f" ] && [ "$5" = "json" ] && [ -f "$6" ] || exit 3
    \\    printf '%s' '{"sequences":[{"total_time":42.5,"filament":2},{"total_time":99}]}' ;;
    \\  post-process) printf '\n%s\n' '; Processed by klipper_estimator v0.4.0' >> "$4" ;;
    \\  *) exit 4 ;;
    \\esac
;

const NativeFixture = struct {
    fn run(_: *anyopaque, io: Io, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
        for (argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "--config_moonraker_api_key"));
        const result = try std.process.run(alloc, io, .{ .argv = argv, .stdout_limit = .limited(max_output_bytes), .stderr_limit = .limited(4096) });
        defer alloc.free(result.stderr);
        errdefer alloc.free(result.stdout);
        if (result.term != .exited or result.term.exited != 0) return error.FixtureCommandFailed;
        return result.stdout;
    }
};

fn fixtureServer() !*@import("../testutil/server.zig").TestServer {
    const TestServer = @import("../testutil/server.zig").TestServer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "analysis.cfg", .data = "[analysis]\nplatform: linux\nestimator_timeout: 2\n" });
    const config = try tmp.dir.realPathFileAlloc(testing.io, "analysis.cfg", testing.allocator);
    defer testing.allocator.free(config);
    const ts = try TestServer.initWithConfig(testing.allocator, config);
    errdefer ts.stop();
    try ts.tmp.dir.createDirPath(ts.io, "tools/klipper_estimator");
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "tools/klipper_estimator/klipper_estimator_linux", .data = fixture_script, .flags = .{ .permissions = .executable_file } });
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "tools/klipper_estimator/default_estimator_cfg.json", .data = "{\"printer\":{}}" });
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "gcodes/job ; $(touch nope).gcode", .data = "G1 X1\n" });
    ts.app.setAnalysisRunner(.{ .context = ts, .run = NativeFixture.run });
    return ts;
}

test "analysis endpoints run native injected commands over private snapshots" {
    const ts = try fixtureServer();
    defer ts.stop();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const status = try mkParams(a, try ts.get(a, "/server/analysis/status"));
    try testing.expect(status.object.get("result").?.object.get("estimator_ready").?.bool);
    try testing.expectEqualStrings("v0.4.0", status.object.get("result").?.object.get("estimator_version").?.string);
    const request = "{\"filename\":\"job ; $(touch nope).gcode\"}";
    const estimate = try mkParams(a, try ts.postJson(a, "/server/analysis/estimate", request));
    const sequence = estimate.object.get("result").?;
    try testing.expectEqual(@as(f64, 42.5), sequence.object.get("total_time").?.float);
    try testing.expect(!sequence.object.contains("sequences"));
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "config/custom settings.json", .data = "{\"printer\":{\"max_velocity\":50}}" });
    const custom = try mkParams(a, try ts.postJson(a, "/server/analysis/estimate", "{\"filename\":\"job ; $(touch nope).gcode\",\"estimator_config\":\"/custom settings.json/\"}"));
    try testing.expectEqual(@as(f64, 42.5), custom.object.get("result").?.object.get("total_time").?.float);
    for ([_]bool{ false, true }) |previous| {
        const response = try mkParams(a, try ts.postJson(a, "/server/analysis/process", request));
        const result = response.object.get("result").?;
        try testing.expectEqual(previous, result.object.get("prev_processed").?.bool);
        try testing.expectEqual(previous, result.object.get("bypassed").?.bool);
        try testing.expectEqualStrings("v0.4.0", result.object.get("version").?.string);
    }
    const processed = try ts.tmp.dir.readFileAlloc(ts.io, "gcodes/job ; $(touch nope).gcode", a, .limited(1024));
    try testing.expect(std.mem.startsWith(u8, processed, "G1 X1\n"));
    try testing.expect(std.mem.indexOf(u8, processed, "; Processed by klipper_estimator v0.4.0") != null);
    const forced = try mkParams(a, try ts.postJson(a, "/server/analysis/process", "{\"filename\":\"job ; $(touch nope).gcode\",\"force\":true}"));
    try testing.expect(!forced.object.get("result").?.object.get("bypassed").?.bool);
    const unavailable = try mkParams(a, try ts.postJson(a, "/server/analysis/dump_config", "{}"));
    try testing.expectEqual(504, unavailable.object.get("error").?.object.get("code").?.integer);
    ts.app.core.lock(ts.io);
    ts.app.analysis_ctx.klippy_ready = true;
    ts.app.core.unlock(ts.io);
    const dump = try mkParams(a, try ts.postJson(a, "/server/analysis/dump_config", "{\"dest_config\":\"/sub/printer.json/\"}"));
    const result = dump.object.get("result").?;
    try testing.expectEqual(3, result.object.count());
    try testing.expectEqualStrings("config", result.object.get("dest_root").?.string);
    try testing.expectEqualStrings("sub/printer.json", result.object.get("dest_config_path").?.string);
    try testing.expectEqual(300, result.object.get("klipper_estimator_config").?.object.get("printer").?.object.get("max_velocity").?.integer);
    const stored = try ts.tmp.dir.readFileAlloc(ts.io, "config/sub/printer.json", a, .limited(1024));
    try testing.expectEqualStrings("{\"printer\":{\"max_velocity\":300}}", stored);
    const default_dump = try mkParams(a, try ts.postJson(a, "/server/analysis/dump_config", "{}"));
    try testing.expect(default_dump.object.get("result").?.object.get("dest_root").? == .null);
    try testing.expectEqualStrings(default_config_name, default_dump.object.get("result").?.object.get("dest_config_path").?.string);
    const tools = try ts.tmp.dir.openDir(ts.io, "tools/klipper_estimator", .{ .iterate = true });
    defer tools.close(ts.io);
    var iterator = tools.iterate();
    var directories: usize = 0;
    while (try iterator.next(ts.io)) |entry| if (entry.kind == .directory) {
        directories += 1;
    };
    try testing.expectEqual(0, directories);
}

test "analysis native runner timeout cancels the child and leaves the source untouched" {
    const ts = try fixtureServer();
    defer ts.stop();
    ts.app.analysis_ctx.timeout = .fromMilliseconds(50);
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "tools/klipper_estimator/klipper_estimator_linux", .data = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf '%s\\n' 'klipper_estimator v0.4.0'; else exec sleep 30; fi\n", .flags = .{ .permissions = .executable_file } });
    const start = Io.Clock.Timestamp.now(ts.io, .awake);
    const response = try ts.postJson(testing.allocator, "/server/analysis/process", "{\"filename\":\"job ; $(touch nope).gcode\"}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "Klipper Estimator timed out") != null);
    try testing.expect(start.untilNow(ts.io).raw.toMilliseconds() < 3000);
    const original = try ts.tmp.dir.readFileAlloc(ts.io, "gcodes/job ; $(touch nope).gcode", testing.allocator, .limited(1024));
    defer testing.allocator.free(original);
    try testing.expectEqualStrings("G1 X1\n", original);
    const info = try ts.get(testing.allocator, "/server/info");
    defer testing.allocator.free(info);
    try testing.expect(std.mem.indexOf(u8, info, "\"result\"") != null);
}

test "analysis releases Core and refuses changed or newly printing source files" {
    const ts = try fixtureServer();
    defer ts.stop();
    const Backend = struct {
        ts: *@import("../testutil/server.zig").TestServer,
        start_print: bool = false,
        entered: bool = false,
        fn run(ptr: *anyopaque, io: Io, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const output = try NativeFixture.run(ptr, io, alloc, argv);
            errdefer alloc.free(output);
            if (!std.mem.eql(u8, argv[1], "--version")) {
                try testing.expect(self.ts.app.core.mutex.tryLock());
                defer self.ts.app.core.unlock(io);
                self.entered = true;
                if (self.start_print) {
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    self.ts.app.job_state_ctx.statusUpdate(try mkParams(arena.allocator(), "{\"state\":\"printing\",\"filename\":\"job ; $(touch nope).gcode\"}"));
                } else {
                    try self.ts.tmp.dir.writeFile(io, .{ .sub_path = "gcodes/job ; $(touch nope).gcode", .data = "newer contents\n" });
                }
            }
            return output;
        }
    };
    var backend: Backend = .{ .ts = ts };
    ts.app.setAnalysisRunner(.{ .context = &backend, .run = Backend.run });
    const response = try ts.postJson(testing.allocator, "/server/analysis/process", "{\"filename\":\"job ; $(touch nope).gcode\"}");
    defer testing.allocator.free(response);
    try testing.expect(backend.entered);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":409") != null);
    const changed = try ts.tmp.dir.readFileAlloc(ts.io, "gcodes/job ; $(touch nope).gcode", testing.allocator, .limited(1024));
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings("newer contents\n", changed);
    backend.start_print = true;
    backend.entered = false;
    const printing = try ts.postJson(testing.allocator, "/server/analysis/process", "{\"filename\":\"job ; $(touch nope).gcode\"}");
    defer testing.allocator.free(printing);
    try testing.expect(backend.entered);
    try testing.expect(std.mem.indexOf(u8, printing, "File currently in use") != null);
    const preserved = try ts.tmp.dir.readFileAlloc(ts.io, "gcodes/job ; $(touch nope).gcode", testing.allocator, .limited(1024));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings("newer contents\n", preserved);
    backend.entered = false;
    const already_printing = try ts.postJson(testing.allocator, "/server/analysis/process", "{\"filename\":\"job ; $(touch nope).gcode\"}");
    defer testing.allocator.free(already_printing);
    try testing.expect(!backend.entered);
    try testing.expect(std.mem.indexOf(u8, already_printing, "File currently in use") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var unavailable: AnalysisCtx = .{ .io = ts.io, .files = ts.app.file_ctx };
    ts.app.core.lock(ts.io);
    defer ts.app.core.unlock(ts.io);
    try testing.expectError(error.EstimatorNotAvailable, handleProcess(&unavailable, try mkParams(arena.allocator(), "{\"filename\":\"job ; $(touch nope).gcode\"}"), arena.allocator()));
}

test "analysis validates runner JSON before returning or replacing a config" {
    const ts = try fixtureServer();
    defer ts.stop();
    const Backend = struct {
        output: []const u8,
        fn run(ptr: *anyopaque, _: Io, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try testing.expectEqual(std.heap.smp_allocator.ptr, alloc.ptr);
            return alloc.dupe(u8, if (std.mem.eql(u8, argv[1], "--version")) "klipper_estimator v1.0" else self.output);
        }
    };
    var backend: Backend = .{ .output = "[]" };
    ts.app.setAnalysisRunner(.{ .context = &backend, .run = Backend.run });
    ts.app.analysis_ctx.klippy_ready = true;
    try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "config/retained.json", .data = "{\"old\":true}" });
    for ([_][]const u8{ "[]", "{", "\xff", "{\"sequences\":[]}", "{\"sequences\":[5]}" }) |output| {
        backend.output = output;
        const result = try ts.postJson(testing.allocator, "/server/analysis/estimate", "{\"filename\":\"job ; $(touch nope).gcode\"}");
        defer testing.allocator.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "Invalid Klipper Estimator output") != null);
    }
    backend.output = "[]";
    const result = try ts.postJson(testing.allocator, "/server/analysis/dump_config", "{\"dest_config\":\"retained.json\"}");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "Invalid Klipper Estimator output") != null);
    const retained = try ts.tmp.dir.readFileAlloc(ts.io, "config/retained.json", testing.allocator, .limited(1024));
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings("{\"old\":true}", retained);
    backend.output = "{}";
    try ts.tmp.dir.createDirPath(ts.io, "outside");
    const outside = try ts.tmp.dir.realPathFileAlloc(ts.io, "outside", testing.allocator);
    defer testing.allocator.free(outside);
    try ts.tmp.dir.symLink(ts.io, outside, "config/escape", .{ .is_directory = true });
    const escape = try ts.postJson(testing.allocator, "/server/analysis/dump_config", "{\"dest_config\":\"escape/unsafe.json\"}");
    defer testing.allocator.free(escape);
    try testing.expect(std.mem.indexOf(u8, escape, "Forbidden") != null);
    try testing.expectError(error.FileNotFound, ts.tmp.dir.openFile(ts.io, "outside/unsafe.json", .{}));
}

test "analysis command waits release Core and serialize concurrent runner invocations" {
    const ts = try fixtureServer();
    defer ts.stop();
    const Backend = struct {
        active: std.atomic.Value(u32) = .init(0),
        peak: std.atomic.Value(u32) = .init(0),
        calls: std.atomic.Value(u32) = .init(0),
        fn run(ptr: *anyopaque, io: Io, alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .acq_rel);
            _ = self.peak.fetchMax(active, .acq_rel);
            if (!std.mem.eql(u8, argv[1], "--version")) {
                _ = self.calls.fetchAdd(1, .acq_rel);
                try io.sleep(.fromMilliseconds(20), .awake);
            }
            return NativeFixture.run(ptr, io, alloc, argv);
        }
    };
    var backend: Backend = .{};
    ts.app.setAnalysisRunner(.{ .context = &backend, .run = Backend.run });
    const Requests = struct {
        ts: *@import("../testutil/server.zig").TestServer,
        replies: [2]?[]u8 = @splat(null),
        fn run(self: *@This(), index: usize) !void {
            self.replies[index] = try self.ts.postJson(std.heap.smp_allocator, "/server/analysis/estimate", "{\"filename\":\"job ; $(touch nope).gcode\"}");
        }
    };
    var requests: Requests = .{ .ts = ts };
    defer for (requests.replies) |reply| if (reply) |bytes| std.heap.smp_allocator.free(bytes);
    var first = try ts.io.concurrent(Requests.run, .{ &requests, 0 });
    defer first.cancel(ts.io) catch {};
    var second = try ts.io.concurrent(Requests.run, .{ &requests, 1 });
    defer second.cancel(ts.io) catch {};
    try first.await(ts.io);
    try second.await(ts.io);
    try testing.expectEqual(@as(u32, 1), backend.peak.load(.acquire));
    try testing.expectEqual(@as(u32, 2), backend.calls.load(.acquire));
    for (requests.replies) |reply| try testing.expect(std.mem.indexOf(u8, reply.?, "\"total_time\":42.5") != null);
}

test "analysis timeout joins a callback that returns output while cancellation is pending" {
    const Backend = struct {
        joined: std.atomic.Value(bool) = .init(false),
        fn run(ptr: *anyopaque, io: Io, alloc: std.mem.Allocator, _: []const []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            io.sleep(.fromSeconds(30), .awake) catch |err| switch (err) {
                error.Canceled => {},
            };
            self.joined.store(true, .release);
            return alloc.dupe(u8, "late output");
        }
    };
    var backend: Backend = .{};
    var ctx: AnalysisCtx = .{ .runner = .{ .context = &backend, .run = Backend.run } };
    try testing.expectError(error.EstimatorTimedOut, runCommand(&ctx, testing.io, testing.allocator, &.{"fixture"}, .fromMilliseconds(20)));
    try testing.expect(backend.joined.load(.acquire));
}

test "analysis refuses snapshot workspaces visible to file write APIs" {
    const ts = try fixtureServer();
    defer ts.stop();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const roots = [_]file_manager.Root{.{ .name = "gcodes", .path = ts.app.datadir, .full_access = true }};
    const files: file_manager.FileCtx = .{ .gpa = testing.allocator, .roots = &roots, .bus = null, .io = ts.io };
    var ctx: AnalysisCtx = .{
        .data_path = ts.app.datadir,
        .estimator_path = ts.app.analysis_ctx.estimator_path,
        .estimator_config = ts.app.analysis_ctx.estimator_config,
        .files = &files,
        .io = ts.io,
        .runner = .{ .context = ts, .run = NativeFixture.run },
    };
    try testing.expectError(error.Forbidden, handleEstimate(&ctx, try mkParams(arena.allocator(), "{\"filename\":\"gcodes/job ; $(touch nope).gcode\"}"), arena.allocator()));
}

test "analysis output rejects oversized malformed and deeply nested JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "null", "[]", "5", "{", "\xff", "{\"x\":\"\\ud800\"}" }) |output|
        try testing.expectError(error.EstimatorInvalidOutput, parseOutput(a, output));
    const good = try parseOutput(a, "{\"printer\":{\"max_velocity\":300}}");
    try testing.expectEqual(300, good.object.get("printer").?.object.get("max_velocity").?.integer);
    var nested: Io.Writer.Allocating = .init(a);
    try nested.writer.writeAll("{\"value\":");
    try nested.writer.splatByteAll('[', jv.max_value_depth);
    try nested.writer.writeAll("0");
    try nested.writer.splatByteAll(']', jv.max_value_depth);
    try nested.writer.writeAll("}");
    try testing.expectError(error.EstimatorInvalidOutput, parseOutput(a, nested.written()));
    const too_long = try a.alloc(u8, max_output_bytes + 1);
    @memset(too_long, ' ');
    try testing.expectError(error.EstimatorInvalidOutput, parseOutput(a, too_long));
}

test "analysis version tokens and footer choose the last identifier in the last64KiB" {
    try testing.expectEqualStrings("v1.2.3", versionToken("v1.2.3-beta").?);
    try testing.expectEqualStrings("1", versionToken("1.").?);
    try testing.expectEqual(null, versionToken("vnext"));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "footer.gcode", .data = "; Processed by klipper_estimator v1.0\n; Processed by klipper_estimator v2.4\n" });
    const file = try tmp.dir.openFile(testing.io, "footer.gcode", .{});
    defer file.close(testing.io);
    const version = (try processedVersion(testing.io, file, testing.allocator)).?;
    defer testing.allocator.free(version);
    try testing.expectEqualStrings("v2.4", version);
    var padding: [footer_bytes + 128]u8 = @splat('x');
    const marker = "; Processed by klipper_estimator v3.0\n";
    @memcpy(padding[0..marker.len], marker);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.gcode", .data = &padding });
    const large = try tmp.dir.openFile(testing.io, "large.gcode", .{});
    defer large.close(testing.io);
    try testing.expectEqual(null, try processedVersion(testing.io, large, testing.allocator));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "invalid-utf8.gcode", .data = "; Processed by klipper_\xffestimator v5.0\n" });
    const invalid = try tmp.dir.openFile(testing.io, "invalid-utf8.gcode", .{});
    defer invalid.close(testing.io);
    const ignored = (try processedVersion(testing.io, invalid, testing.allocator)) orelse return error.MissingVersion;
    defer testing.allocator.free(ignored);
    try testing.expectEqualStrings("v5.0", ignored);
}

// --- Fuzz tests ---

test "fuzz hasDotDot: matches a whole-segment scan" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            const alphabet = "./a";
            for (&buf) |*c| c.* = alphabet[smith.value(u8) % alphabet.len];
            const path = buf[0 .. smith.value(u8) % (buf.len + 1)];
            const expected = std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../") or
                std.mem.endsWith(u8, path, "/..") or std.mem.indexOf(u8, path, "/../") != null;
            try testing.expectEqual(expected, hasDotDot(path));
        }
    }.run, .{});
}

test "fuzz analysis handlers: never panic on arbitrary params" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const strs = [_][]const u8{
                "null",
                "{}",
                "{\"filename\": \"test.gcode\"}",
                "{\"filename\": 5}",
                "{\"filename\": \"a.gcode\", \"estimator_config\": \"../cfg.json\"}",
                "{\"dest_config\": \"../x\"}",
            };
            const p = try std.json.parseFromSlice(std.json.Value, a, strs[smith.value(u8) % strs.len], .{});
            var ctx = AnalysisCtx{};
            const handlers = [_]registry.HandlerFn{ handleStatus, handleEstimate, handleProcess, handleDumpConfig };
            const r = handlers[smith.value(u8) % handlers.len](@ptrCast(&ctx), p.value, a) catch return;
            try testing.expect(r == .object);
        }
    }.run, .{});
}

test "fuzz estimator output and version parsing stay bounded" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [512]u8 = undefined;
            const len = smith.valueRangeAtMostWithHash(u16, 0, bytes.len, 0);
            smith.bytesWithHash(bytes[0..len], 1);
            if (versionToken(bytes[0..len])) |version| {
                try testing.expect(version.len <= max_version_bytes);
                try testing.expect(std.mem.startsWith(u8, bytes[0..len], version));
                try testing.expect(std.unicode.utf8ValidateSlice(version));
            }
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const result = parseOutput(arena.allocator(), bytes[0..len]) catch |err| switch (err) {
                error.EstimatorInvalidOutput => return,
                else => return err,
            };
            try testing.expect(result == .object);
            try testing.expect(!jv.exceedsDepth(result, jv.max_value_depth));
            const rendered = try std.json.Stringify.valueAlloc(arena.allocator(), result, .{});
            try testing.expect(std.unicode.utf8ValidateSlice(rendered));
        }
    }.run, .{});
}

test "fuzz estimator footer snapshots retain only the final matching version" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var bytes: [512]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const version_number = smith.valueRangeAtMostWithHash(u16, 0, 65535, 1);
            var output: Io.Writer.Allocating = .init(testing.allocator);
            defer output.deinit();
            try output.writer.writeAll(&bytes);
            try output.writer.print("\n; Processed by klipper_estimator v1.0\n; Processed by klipper_estimator v2.{d}\n", .{version_number});
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "job.gcode", .data = output.written() });
            const file = try tmp.dir.openFile(testing.io, "job.gcode", .{});
            defer file.close(testing.io);
            const actual = (try processedVersion(testing.io, file, testing.allocator)).?;
            defer testing.allocator.free(actual);
            var expected: [32]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "v2.{d}", .{version_number}), actual);
        }
    }.run, .{});
}

test "fuzz injected estimate and processing use checked snapshots and retain bypass semantics" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const ts = try fixtureServer();
            defer ts.stop();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const previous = smith.value(bool);
            const force = smith.value(bool);
            const marker = if (previous) "G1 X1\n; Processed by klipper_estimator v1.0\n" else "G1 X1\n";
            try ts.tmp.dir.writeFile(ts.io, .{ .sub_path = "gcodes/job ; $(touch nope).gcode", .data = marker });
            const request = try std.fmt.allocPrint(a, "{{\"filename\":\"job ; $(touch nope).gcode\",\"force\":{s}}}", .{if (force) "true" else "false"});
            const response = try mkParams(a, try ts.postJson(a, "/server/analysis/process", request));
            const result = response.object.get("result").?;
            try testing.expectEqual(previous, result.object.get("prev_processed").?.bool);
            try testing.expectEqual(previous and !force, result.object.get("bypassed").?.bool);
            try testing.expectEqualStrings(if (previous and !force) "v1.0" else "v0.4.0", result.object.get("version").?.string);
            const estimate = try mkParams(a, try ts.postJson(a, "/server/analysis/estimate", request));
            try testing.expectEqual(@as(f64, 42.5), estimate.object.get("result").?.object.get("total_time").?.float);
        }
    }.run, .{});
}

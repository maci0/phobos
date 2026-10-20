//! machine.update.* (update_manager) API component — Moonraker-compatible
//! software update endpoints.
//!
//! Mirrors the endpoints registered in
//! `vendor/moonraker/moonraker/components/update_manager/update_manager.py`:
//!
//!   GET  /machine/update/status     → machine.update.status
//!   POST /machine/update/refresh    → machine.update.refresh
//!   POST /machine/update/upgrade    → machine.update.upgrade
//!   POST /machine/update/full       → machine.update.full
//!   POST /machine/update/moonraker  → machine.update.moonraker
//!   POST /machine/update/klipper    → machine.update.klipper
//!   POST /machine/update/system     → machine.update.system
//!   POST /machine/update/client     → machine.update.client
//!   POST /machine/update/recover    → machine.update.recover
//!   POST /machine/update/rollback   → machine.update.rollback
//!
//! COMMANDS. git runs only when `io` is set and the source has a `repo_path`:
//! refresh and `status?refresh=true` run `git fetch origin --prune`; a single
//! update runs fetch and `git reset --hard origin/<branch>`; recover and
//! rollback run the `git reset`/`clean`/`checkout` steps documented at their
//! handlers. apt-get and pip lines go only to an installed `shell` runner; the
//! daemon installs none, so system and requirements updates are refused with
//! error.NoPackageProvider. Each handler emits Moonraker's
//! `notify_update_response` lines and returns the bare "ok" ack. Tests fetch
//! only local temporary repositories.
//!
//! The `status`/`refresh` responses carry the full Moonraker
//! `version_info` map. For each configured source we report the exact per-source
//! shape Moonraker emits (`get_update_status`):
//!   * moonraker / klipper → git_repo type (GitDeploy.get_repo_status merged
//!     with AppDeploy.get_update_status)
//!   * system              → system/package type (PackageDeploy)
//! Without live git/package state the version fields carry honest default /
//! "unknown" values (current==remote so nothing appears out of date). The SHAPE
//! matches upstream key-for-key.
//!
//! NOTIFICATIONS. `refresh`/`status(refresh=true)` emit `notify_update_refreshed`
//! with `{ ...rate_limit_stats, version_info, busy }` (1-element params array).
//! The update/recover/rollback handlers emit `notify_update_response` with
//! `{ application, proc_id, message, complete }` (Moonraker's CommandHelper
//! notification shape). All command handlers run outside Core and serialize
//! command stages with `commands`. Notifications use `bus.emit` after the
//! command mutex is released. io is wired after the event loop starts via
//! `setIo`; emission is a no-op until then (pure unit tests).

const std = @import("std");
const webreq = @import("../json/params.zig");
const sleep = @import("../util/sleep.zig");
const clock = @import("../util/clock.zig");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const config_helper = @import("../config/confighelper.zig");
const DataStore = @import("../store/datastore.zig").DataStore;
const NotifyBus = @import("../server/notify.zig").NotifyBus;
const process = @import("../util/process.zig");
const net_update = @import("update_net.zig");

const Registry = registry.Registry;
const status_refresh_interval_s = 60;
extern fn phobos_local_hour(seconds: i64, hour: *c_int) c_int;

fn localHour(seconds: i64) !i64 {
    var hour: c_int = undefined;
    if (phobos_local_hour(seconds, &hour) != 0) return error.LocalTimeUnavailable;
    return hour;
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

/// The kind of an update source, controlling which status shape it emits.
pub const SourceType = enum {
    git_repo,
    system,
    web,
    zip,
};

/// A configured update source. The `moonraker`, `klipper` and `system` sources
/// are always present; `client` sources come from `[update_manager <name>]`
/// config sections (none in the phobos spine, but the shape supports them).
pub const Source = struct {
    /// The key under `version_info` (e.g. "moonraker", "klipper", "system").
    name: []const u8,
    type: SourceType,
    /// Repo owner (git/web sources). Empty for system.
    owner: []const u8 = "?",
    /// Repo name (git/web sources). Empty for system.
    repo_name: []const u8 = "?",
    /// Tracked branch (git sources).
    branch: []const u8 = "master",
    /// Filesystem path to the git working directory. Empty string means the
    /// repo is not present on this host. When non-empty AND io is available,
    /// buildGitStatus runs real git commands to populate version/hash/branch.
    repo_path: []const u8 = "",
    /// Python requirements file. When set, a git update also runs
    /// `pip install -r <path>` (Moonraker `_update_python_requirements`).
    requirements: []const u8 = "",
    /// Moonraker `channel` (`dev` / `stable`). Empty means the type default.
    channel: []const u8 = "",
    /// Explicit git remote. Empty means `https://github.com/<owner>/<repo>.git`.
    origin: []const u8 = "",
    /// Versions used when the repo is not on disk. Empty keeps the "?" default.
    pinned_version: []const u8 = "",
    pinned_remote_version: []const u8 = "",
    pinned_hash: []const u8 = "",
    pinned_remote_hash: []const u8 = "",
    pinned_behind: i64 = 0,
    /// Commit `rollback` resets to. Empty means rollback is not performed.
    rollback_ref: []const u8 = "",
    managed_services: []const []const u8 = &.{},
    persistent_files: []const []const u8 = &.{},
    /// Whether this source is a git repository eligible for recover/rollback.
    pub fn isGit(self: Source) bool {
        return self.type == .git_repo;
    }
};

/// The default source set Moonraker creates: system (package), moonraker and
/// klipper (git repos). Mirrors UpdateManager.__init__.
pub const default_sources = [_]Source{
    .{ .name = "system", .type = .system, .owner = "", .repo_name = "" },
    .{ .name = "moonraker", .type = .git_repo, .owner = "Arksine", .repo_name = "moonraker", .branch = "master", .managed_services = &.{"moonraker"} },
    .{ .name = "klipper", .type = .git_repo, .owner = "Klipper3d", .repo_name = "klipper", .branch = "master", .managed_services = &.{"klipper"} },
};

/// `github.com/<owner>/<repo>` from an origin URL. Slices borrow `origin`.
fn githubOwnerRepo(origin: []const u8) struct { owner: []const u8, repo: []const u8 } {
    const marker = "github.com/";
    const at = std.mem.indexOf(u8, origin, marker) orelse return .{ .owner = "?", .repo = "?" };
    var rest = origin[at + marker.len ..];
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .owner = "?", .repo = "?" };
    if (slash + 1 >= rest.len) return .{ .owner = "?", .repo = "?" };
    return .{ .owner = rest[0..slash], .repo = rest[slash + 1 ..] };
}

/// Moonraker's updater set: `system` only when `enable_system_updates` is true
/// (default true), plus moonraker, klipper, and each `[update_manager <name>]`.
/// `arena` owns the result and every config string in it; the caller frees
/// them together by freeing the arena (nothing is freed individually, so an
/// error part-way leaks nothing beyond the arena). Default sources keep their
/// static strings.
pub fn sourcesFromConfig(arena: std.mem.Allocator, cfg: *const config_helper.ConfigParser) ![]Source {
    var list: std.ArrayList(Source) = .empty;
    const system_on = cfg.getBoolean("update_manager", "enable_system_updates") catch true;
    if (system_on) try list.append(arena, default_sources[0]);
    try list.appendSlice(arena, default_sources[1..]);

    const names = cfg.sectionNames(arena) catch return list.items;
    const prefix = "update_manager ";
    for (names) |sect| {
        if (!std.mem.startsWith(u8, sect, prefix)) continue;
        const name = sect[prefix.len..];
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "moonraker") or std.mem.eql(u8, name, "klipper")) continue;
        const typ_raw = cfg.get(sect, "type") orelse "git_repo";
        const stype: SourceType = if (std.mem.eql(u8, typ_raw, "web"))
            .web
        else if (std.mem.eql(u8, typ_raw, "zip"))
            .zip
        else if (std.mem.eql(u8, typ_raw, "git_repo"))
            .git_repo
        else
            continue;
        const repo = cfg.get(sect, "repo") orelse "";
        const origin = cfg.get(sect, "origin") orelse "";
        var owner: []const u8 = "?";
        var repo_name: []const u8 = "?";
        if (std.mem.indexOfScalar(u8, repo, '/')) |slash| {
            owner = repo[0..slash];
            repo_name = repo[slash + 1 ..];
        } else if (origin.len > 0) {
            const parsed = githubOwnerRepo(origin);
            owner = parsed.owner;
            repo_name = parsed.repo;
        }
        const branch = cfg.get(sect, "primary_branch") orelse if (stype == .git_repo) "master" else "";
        const channel = cfg.get(sect, "channel") orelse if (stype == .git_repo) "dev" else "stable";
        const path = cfg.get(sect, "path") orelse "";
        var services: std.ArrayList([]const u8) = .empty;
        var persistent: std.ArrayList([]const u8) = .empty;
        if (cfg.get(sect, "persistent_files")) |raw| {
            var paths = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
            while (paths.next()) |file| {
                if (!net_update.validRelative(file) or std.mem.eql(u8, file, ".version") or std.mem.eql(u8, file, "release_info.json")) return error.InvalidPersistentFile;
                try persistent.append(arena, try arena.dupe(u8, file));
            }
        }
        if (stype != .web) {
            if (cfg.get(sect, "managed_services")) |raw| {
                var names_iter = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
                while (names_iter.next()) |service| {
                    if (!std.mem.eql(u8, service, name) and !std.mem.eql(u8, service, "klipper") and !std.mem.eql(u8, service, "moonraker")) return error.InvalidManagedService;
                    try services.append(arena, try arena.dupe(u8, service));
                }
            } else if ((cfg.getBoolean(sect, "is_system_service") catch true) and @import("machine.zig").isServiceAllowed(name)) {
                try services.append(arena, try arena.dupe(u8, name));
            }
        }
        try list.append(arena, .{
            .name = try arena.dupe(u8, name),
            .type = stype,
            .owner = try arena.dupe(u8, owner),
            .repo_name = try arena.dupe(u8, repo_name),
            .branch = try arena.dupe(u8, branch),
            .repo_path = try arena.dupe(u8, path),
            .channel = try arena.dupe(u8, channel),
            .origin = try arena.dupe(u8, origin),
            .managed_services = try services.toOwnedSlice(arena),
            .persistent_files = try persistent.toOwnedSlice(arena),
        });
    }
    return list.items;
}

test "sourcesFromConfig: forge-x clients and system updates off" {
    const alloc = std.testing.allocator;
    const body =
        \\[update_manager]
        \\enable_system_updates: False
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
        \\[update_manager guppyscreen]
        \\type: zip
        \\channel: stable
        \\repo: DrA1ex/guppyscreen
        \\path: /no/such/guppy
        \\
    ;
    var cfg = config_helper.ConfigParser.init(alloc);
    defer cfg.deinit();
    try cfg.parseString(body, "<test>");
    var sources_arena = std.heap.ArenaAllocator.init(alloc);
    defer sources_arena.deinit();
    const sources = try sourcesFromConfig(sources_arena.allocator(), &cfg);
    // Sources must not borrow the parser's strings.
    cfg.deinit();
    cfg = config_helper.ConfigParser.init(alloc);

    var saw_system = false;
    var forge: ?Source = null;
    var fluidd: ?Source = null;
    var guppy: ?Source = null;
    for (sources) |s| {
        if (std.mem.eql(u8, s.name, "system")) saw_system = true;
        if (std.mem.eql(u8, s.name, "forge-x")) forge = s;
        if (std.mem.eql(u8, s.name, "fluidd")) fluidd = s;
        if (std.mem.eql(u8, s.name, "guppyscreen")) guppy = s;
    }
    try std.testing.expect(!saw_system);
    try std.testing.expectEqualStrings("DrA1ex", forge.?.owner);
    try std.testing.expectEqualStrings("ff5m", forge.?.repo_name);
    try std.testing.expectEqualStrings("1.4.2", forge.?.branch);
    try std.testing.expectEqualStrings("dev", forge.?.channel);
    try std.testing.expectEqualStrings("https://github.com/DrA1ex/ff5m.git", forge.?.origin);
    try std.testing.expect(fluidd.?.type == .web);
    try std.testing.expectEqualStrings("fluidd-core", fluidd.?.owner);
    try std.testing.expect(guppy.?.type == .zip);
    try std.testing.expectEqualStrings("stable", guppy.?.channel);

    var ctx = UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = sources, .bus = null, .io = null };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const status = try handleStatus(@ptrCast(&ctx), .null, arena.allocator());
    const info = status.object.get("version_info").?.object;
    try std.testing.expect(info.get("system") == null);
    try std.testing.expectEqualStrings("git_repo", info.get("forge-x").?.object.get("configured_type").?.string);
    try std.testing.expectEqualStrings("dev", info.get("forge-x").?.object.get("channel").?.string);
    try std.testing.expectEqualStrings("1.4.2", info.get("forge-x").?.object.get("branch").?.string);
    try std.testing.expectEqualStrings("https://github.com/DrA1ex/ff5m.git", info.get("forge-x").?.object.get("remote_url").?.string);
    try std.testing.expectEqualStrings("web", info.get("fluidd").?.object.get("configured_type").?.string);
    try std.testing.expectEqualStrings("zip", info.get("guppyscreen").?.object.get("configured_type").?.string);
}

test "source persistent files retain relative names and reject reserved paths" {
    var cfg = config_helper.ConfigParser.init(testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[update_manager client]\ntype: zip\npersistent_files: settings/theme, local.json\n", "<test>");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sources = try sourcesFromConfig(arena.allocator(), &cfg);
    const paths = sources[sources.len - 1].persistent_files;
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("settings/theme", paths[0]);
    try testing.expectEqualStrings("local.json", paths[1]);
    for ([_][]const u8{ ".version", "release_info.json", "../escape", ".git/config" }) |path| {
        cfg.deinit();
        cfg = config_helper.ConfigParser.init(testing.allocator);
        const body = try std.fmt.allocPrint(arena.allocator(), "[update_manager client]\ntype: zip\npersistent_files: {s}\n", .{path});
        try cfg.parseString(body, "<test>");
        try testing.expectError(error.InvalidPersistentFile, sourcesFromConfig(arena.allocator(), &cfg));
    }
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const UpdateCtx = struct {
    clock_io: std.Io,
    gpa: std.mem.Allocator,
    /// Configured sources. Borrowed; owned by the App (or a test).
    sources: []const Source,
    store: ?DataStore = null,
    bus: ?*NotifyBus,
    /// Live io for notification emission. Set after the event loop starts (via
    /// setIo). Emission is a no-op while absent.
    io: ?std.Io = null,
    /// Git commands serialize outside Core; notifications take Core only after
    /// releasing this mutex.
    commands: std.Io.Mutex = .init,
    last_status_refresh: ?std.Io.Clock.Timestamp = null,
    /// Tracks whether an update or recovery is currently in progress.
    busy: std.atomic.Value(bool) = .init(false),
    /// Startup environment without inherited Git repository/config overrides.
    /// Owned by this context and immutable once request workers start.
    git_environment: ?std.process.Environ.Map = null,
    /// Optional printing-state check. When it returns true, mutating update
    /// operations are refused (Moonraker: 503 "Update Refused: Klippy is
    /// printing"). Must read an atomic flag without taking Core.
    printing_check: ?*const fn (*anyopaque) bool = null,
    printing_ctx: ?*anyopaque = null,
    /// Runs one shell command. System updates use Moonraker's apt-get lines;
    /// git sources with `requirements` set run `pip install -r`. Null means
    /// no package provider (Moonraker: "Cannot upgrade packages, no provider set").
    shell: ?ShellFn = null,
    shell_ctx: ?*anyopaque = null,
    restart_service: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void = null,
    service_ctx: ?*anyopaque = null,
    github_api_base: []const u8 = "https://api.github.com",
    /// `[update_manager] enable_auto_refresh`. False does not start a timer
    /// and `tickAutoRefresh` does not refresh. The printer sets this false.
    auto_refresh: bool = false,
    /// Hours between refreshes. Moonraker default 168.
    refresh_interval_hours: i64 = 168,
    /// Inclusive start hour and exclusive end hour in the host's local time.
    refresh_window_start: i64 = 0,
    refresh_window_end: i64 = 5,
    /// Moonraker's first auto-refresh ignores the window. Later ones do not.
    initial_refresh_done: bool = false,
    /// Unix seconds of the last auto-refresh. 0 means never.
    last_auto_refresh_s: i64 = 0,
    refresh_stop: std.Io.Event = .unset,
    refresh_thread: ?std.Thread = null,

    pub const ShellFn = *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void;

    /// Moonraker `_is_within_refresh_window`. A window that wraps midnight
    /// (start > end) matches `hour >= start` or `hour < end`.
    pub fn inRefreshWindow(start: i64, end: i64, hour: i64) bool {
        if (start < end) return hour >= start and hour < end;
        return hour >= start or hour < end;
    }

    /// True when an enabled auto-refresh should run at `hour`.
    /// Disabled stays false. The first due check ignores the window.
    /// Later checks refuse while printing, outside the window, or before
    /// `refresh_interval_hours` have passed.
    pub fn autoRefreshDue(self: *const UpdateCtx, hour: i64, printing: bool) bool {
        if (!self.auto_refresh or printing or self.busy.load(.acquire)) return false;
        if (!self.initial_refresh_done) return true;
        if (!inRefreshWindow(self.refresh_window_start, self.refresh_window_end, hour)) return false;
        const now = clock.wallSecondsInt(self.clock_io);
        const wait_s = self.refresh_interval_hours * 3600;
        if (wait_s > 0 and self.last_auto_refresh_s > 0 and now < self.last_auto_refresh_s + wait_s) return false;
        return true;
    }

    /// Record an auto-refresh when one is due at `hour` and return whether it
    /// is. Runs under Core; the caller refreshes after releasing it.
    pub fn tickAutoRefresh(self: *UpdateCtx, hour: i64) bool {
        if (!self.autoRefreshDue(hour, self.isPrinting())) return false;
        self.initial_refresh_done = true;
        self.last_auto_refresh_s = clock.wallSecondsInt(self.clock_io);
        return true;
    }

    pub fn startAutoRefresh(self: *UpdateCtx) void {
        if (!self.auto_refresh or self.refresh_thread != null) return;
        self.refresh_stop.reset();
        self.refresh_thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, autoRefreshThread, .{self}) catch null;
    }

    pub fn stopAutoRefresh(self: *UpdateCtx) void {
        self.refresh_stop.set(self.clock_io);
        if (self.refresh_thread) |th| {
            th.join();
            self.refresh_thread = null;
        }
    }

    pub fn setIo(self: *UpdateCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn setGitEnvironment(self: *UpdateCtx, environment: *const std.process.Environ.Map) !void {
        var copy = std.process.Environ.Map.init(self.gpa);
        errdefer copy.deinit();
        for (environment.keys(), environment.values()) |key, value| {
            if (!std.mem.startsWith(u8, key, "GIT_")) try copy.put(key, value);
        }
        if (self.git_environment) |*previous| previous.deinit();
        self.git_environment = copy;
    }

    pub fn gitEnvironment(self: *const UpdateCtx) ?*const std.process.Environ.Map {
        return if (self.git_environment) |*environment| environment else null;
    }

    pub fn deinit(self: *UpdateCtx) void {
        self.stopAutoRefresh();
        if (self.git_environment) |*environment| environment.deinit();
        self.git_environment = null;
    }

    pub fn beginMutation(self: *UpdateCtx) !void {
        if (self.isPrinting()) return error.UpdateRefusedPrinting;
        if (self.busy.swap(true, .acq_rel)) return error.UpdateBusy;
    }

    /// True if a print is currently in progress (via the wired callback).
    pub fn isPrinting(self: *const UpdateCtx) bool {
        const f = self.printing_check orelse return false;
        const c = self.printing_ctx orelse return false;
        return f(c);
    }

    pub fn findSource(self: *const UpdateCtx, name: []const u8) ?Source {
        for (self.sources) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

fn autoRefreshThread(ctx: *UpdateCtx) void {
    const io = ctx.io orelse return;
    const bus = ctx.bus orelse return;
    // Wait out the check interval before the first refresh so process
    // startup does not fetch. Tests call `tickAutoRefresh` directly.
    while (!ctx.refresh_stop.isSet()) {
        if (sleep.untilStopped(io, .fromSeconds(3600), &ctx.refresh_stop)) break;
        const now = clock.wallSecondsInt(ctx.clock_io);
        const hour = localHour(now) catch |err| {
            std.debug.print("phobos: update refresh time unavailable: {}\n", .{err});
            continue;
        };
        if (!bus.core.run(io, UpdateCtx.tickAutoRefresh, .{ ctx, hour })) continue;
        var request_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer request_arena.deinit();
        _ = handleRefresh(@ptrCast(ctx), .null, request_arena.allocator()) catch {};
    }
}

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Git child-process helper
// ---------------------------------------------------------------------------

/// Kill bound for a local git command, in seconds (Moonraker `_run_git_cmd`).
const git_local_timeout_s = 20;
/// Kill bound for `git fetch`, in seconds; the command runs outside Core.
pub const git_fetch_timeout_s = 60;
/// Cap on the stdout and on the stderr bytes one git command may buffer.
const git_output_limit = 512 * 1024;

/// Run `git -C <repo_path> <args...>` killed after `timeout_s` seconds, with
/// stdout and stderr capped at `git_output_limit` (error.StreamTooLong).
/// Caller owns the result's stdout and stderr.
pub fn gitRun(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8, timeout_s: i64, environment: ?*const std.process.Environ.Map) !std.process.RunResult {
    const args = try std.mem.concat(alloc, []const u8, &.{ &.{ "git", "-C", repo_path }, argv });
    defer alloc.free(args);
    const empty_environment = std.process.Environ.Map.init(alloc);
    return process.run(alloc, io, .{
        .argv = args,
        .environ_map = environment orelse &empty_environment,
        .stdout_limit = .limited(git_output_limit),
        .stderr_limit = .limited(git_output_limit),
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(timeout_s), .clock = .awake }) },
    });
}

/// Run `git -C <repo_path> <args...>` and return stdout (trimmed, caller owns).
/// Returns null on any error (spawn failure, timeout, oversized output,
/// non-zero exit, empty stdout).
fn gitOutput(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8, environment: ?*const std.process.Environ.Map) ?[]const u8 {
    if (repo_path.len == 0) return null;

    const result = gitRun(io, alloc, repo_path, argv, git_local_timeout_s, environment) catch return null;
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return null;
    }
    if (result.stdout.len == 0 or !std.unicode.utf8ValidateSlice(result.stdout)) {
        alloc.free(result.stdout);
        return null;
    }
    // Trim trailing newline that some git commands emit.
    const trimmed = if (result.stdout.len > 0 and result.stdout[result.stdout.len - 1] == '\n')
        result.stdout[0 .. result.stdout.len - 1]
    else
        result.stdout;
    // Realloc to trimmed size (may shrink or return same pointer).
    if (alloc.resize(result.stdout, trimmed.len)) {
        return result.stdout.ptr[0..trimmed.len];
    }
    const duped = alloc.dupe(u8, trimmed) catch {
        alloc.free(result.stdout);
        return null;
    };
    alloc.free(result.stdout);
    return duped;
}

/// Run `git -C <repo_path> <args...>` and return true on exit 0, false otherwise.
fn gitCheck(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8, environment: ?*const std.process.Environ.Map) bool {
    if (repo_path.len == 0) return false;
    const result = gitRun(io, alloc, repo_path, argv, git_local_timeout_s, environment) catch return false;
    return exitedZero(alloc, result);
}

/// True when `result` exited 0. Frees its output.
fn exitedZero(alloc: std.mem.Allocator, result: std.process.RunResult) bool {
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

/// Run `git fetch origin --prune` in a repo to update remote tracking refs,
/// killed after `git_fetch_timeout_s`. Fetch never modifies the working tree or
/// local branches. Returns true on success, false when a repo_path is empty,
/// io is unavailable, or fetch fails (non-zero exit, spawn failure, timeout).
fn gitFetch(io: ?std.Io, alloc: std.mem.Allocator, repo_path: []const u8, environment: ?*const std.process.Environ.Map) bool {
    const live_io = io orelse return false;
    if (repo_path.len == 0) return false;
    const result = gitRun(live_io, alloc, repo_path, &.{ "fetch", "origin", "--prune" }, git_fetch_timeout_s, environment) catch return false;
    return exitedZero(alloc, result);
}

/// Run `git reset --hard <ref>` in a repo. Destructive: overwrites local
/// changes. Returns true on success, false on failure.
fn gitReset(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, ref: []const u8, environment: ?*const std.process.Environ.Map) bool {
    if (repo_path.len == 0) return false;
    return gitCheck(io, alloc, repo_path, &.{ "reset", "--hard", ref }, environment);
}

// ---------------------------------------------------------------------------
// Per-source status shape (get_update_status)
// ---------------------------------------------------------------------------

/// Build the git_repo status shape: AppDeploy.get_update_status merged with
/// GitDeploy.repo.get_repo_status. Every key Moonraker emits is present. When
/// io is available and src.repo_path is non-empty, runs real git commands to
/// populate version, hash, branch, and dirty/detached state. Falls back to
/// honest "?" defaults when the repo is absent (unit tests, dev workstation).
fn buildGitStatus(io: ?std.Io, alloc: std.mem.Allocator, src: Source, environment: ?*const std.process.Environ.Map) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    // --- AppDeploy.get_update_status base keys ---
    const channel = if (src.channel.len > 0) src.channel else "dev";
    try obj.put(alloc, "channel", .{ .string = channel });
    try obj.put(alloc, "debug_enabled", .{ .bool = false });
    try obj.put(alloc, "channel_invalid", .{ .bool = false });
    try obj.put(alloc, "is_valid", .{ .bool = true });
    try obj.put(alloc, "configured_type", .{ .string = "git_repo" });
    try obj.put(alloc, "info_tags", .{ .array = .init(alloc) });

    // --- GitDeploy.get_repo_status keys ---
    try obj.put(alloc, "detected_type", .{ .string = "git_repo" });
    try obj.put(alloc, "remote_alias", .{ .string = "origin" });

    const remote_url = if (src.origin.len > 0)
        src.origin
    else
        try std.fmt.allocPrint(alloc, "https://github.com/{s}/{s}.git", .{ src.owner, src.repo_name });
    try obj.put(alloc, "remote_url", .{ .string = remote_url });
    try obj.put(alloc, "recovery_url", .{ .string = remote_url });
    try obj.put(alloc, "owner", .{ .string = src.owner });
    try obj.put(alloc, "repo_name", .{ .string = src.repo_name });

    var branch: []const u8 = src.branch;
    var version: []const u8 = if (src.pinned_version.len > 0) src.pinned_version else "?";
    var remote_version: []const u8 = if (src.pinned_remote_version.len > 0) src.pinned_remote_version else "?";
    var current_hash: []const u8 = if (src.pinned_hash.len > 0) src.pinned_hash else "?";
    var remote_hash: []const u8 = if (src.pinned_remote_hash.len > 0) src.pinned_remote_hash else "?";
    var is_dirty: bool = false;
    var detached: bool = false;
    var commits_behind_count: i64 = src.pinned_behind;
    var commits_behind: std.json.Array = .init(alloc);

    if (io) |live_io| {
        if (src.repo_path.len > 0) {
            // branch: git rev-parse --abbrev-ref HEAD
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", "--abbrev-ref", "HEAD" }, environment)) |b| {
                if (!std.mem.eql(u8, b, "HEAD")) branch = b;
            }

            // version: git describe --tags --always --long --dirty
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "describe", "--tags", "--always", "--long", "--dirty" }, environment)) |v| {
                version = v;
            }

            // full_version_string: git describe --tags --always --long --dirty
            // (same as version; Moonraker's get_version_from_git returns this)
            try obj.put(alloc, "full_version_string", .{ .string = try alloc.dupe(u8, version) });

            // remote_version: git describe --tags origin/<branch> --always
            const remote_ref = try std.fmt.allocPrint(alloc, "origin/{s}", .{branch});
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "describe", "--tags", remote_ref, "--always" }, environment)) |rv| {
                remote_version = rv;
            }

            // current_hash: git rev-parse HEAD
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", "HEAD" }, environment)) |ch| {
                current_hash = ch;
            }

            // remote_hash: git rev-parse origin/<branch>
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", remote_ref }, environment)) |rh| {
                remote_hash = rh;
            }

            // is_dirty: git status --porcelain has any output. Output past
            // the cap is output too, so a large change set stays dirty.
            if (gitRun(live_io, alloc, src.repo_path, &.{ "status", "--porcelain" }, git_local_timeout_s, environment)) |porcelain| {
                defer alloc.free(porcelain.stdout);
                defer alloc.free(porcelain.stderr);
                is_dirty = porcelain.term == .exited and porcelain.term.exited == 0 and porcelain.stdout.len > 0;
            } else |err| {
                is_dirty = err == error.StreamTooLong;
            }

            // detached: git symbolic-ref -q HEAD fails
            detached = !gitCheck(live_io, alloc, src.repo_path, &.{ "symbolic-ref", "-q", "HEAD" }, environment);

            // commits_behind: git log HEAD..origin/<branch> with Moonraker's
            // format (unit separator \x1D between fields, record separator
            // \x1E between commits). Max 100 entries to match Moonraker.
            const behind_range = try std.fmt.allocPrint(alloc, "HEAD..{s}", .{remote_ref});
            const log_fmt_arg = try std.fmt.allocPrint(alloc, "--format=sha:%H\x1Dauthor:%an\x1Ddate:%ct\x1Dsubject:%s\x1Dmessage:%b\x1E", .{});
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "log", behind_range, log_fmt_arg, "--max-count=100" }, environment)) |behind| {
                if (behind.len > 0) {
                    var records = std.mem.splitSequence(u8, behind, "\x1E");
                    while (records.next()) |record| {
                        if (record.len == 0) continue;
                        var commit_obj: std.json.ObjectMap = .empty;
                        var fields = std.mem.splitSequence(u8, record, "\x1D");
                        while (fields.next()) |field| {
                            if (field.len == 0) continue;
                            if (std.mem.indexOfScalar(u8, field, ':')) |colon| {
                                const key = field[0..colon];
                                const val = field[colon + 1 ..];
                                if (std.mem.eql(u8, key, "date")) {
                                    // Moonraker returns date as a string (unix timestamp).
                                    try commit_obj.put(alloc, key, .{ .string = try alloc.dupe(u8, val) });
                                } else if (std.mem.eql(u8, key, "subject") or
                                    std.mem.eql(u8, key, "message") or
                                    std.mem.eql(u8, key, "sha") or
                                    std.mem.eql(u8, key, "author"))
                                {
                                    try commit_obj.put(alloc, key, .{ .string = try alloc.dupe(u8, val) });
                                }
                            }
                        }
                        // Add tag field (always null — tag detection requires
                        // additional git commands that Moonraker gates on
                        // channel != dev).
                        try commit_obj.put(alloc, "tag", .null);
                        try commits_behind.append(.{ .object = commit_obj });
                        commits_behind_count += 1;
                    }
                }
            }
        } else {
            try obj.put(alloc, "full_version_string", .{ .string = "?" });
        }
    } else {
        try obj.put(alloc, "full_version_string", .{ .string = "?" });
    }

    try obj.put(alloc, "branch", .{ .string = try alloc.dupe(u8, branch) });
    try obj.put(alloc, "version", .{ .string = try alloc.dupe(u8, version) });
    try obj.put(alloc, "remote_version", .{ .string = try alloc.dupe(u8, remote_version) });
    try obj.put(alloc, "rollback_version", .{ .string = "?" });
    try obj.put(alloc, "current_hash", .{ .string = try alloc.dupe(u8, current_hash) });
    try obj.put(alloc, "remote_hash", .{ .string = try alloc.dupe(u8, remote_hash) });
    try obj.put(alloc, "is_dirty", .{ .bool = is_dirty });
    try obj.put(alloc, "detached", .{ .bool = detached });
    try obj.put(alloc, "commits_behind", .{ .array = commits_behind });
    try obj.put(alloc, "commits_behind_count", .{ .integer = commits_behind_count });
    try obj.put(alloc, "git_messages", .{ .array = .init(alloc) });
    try obj.put(alloc, "pristine", .{ .bool = !is_dirty and !detached });
    try obj.put(alloc, "corrupt", .{ .bool = false });
    try obj.put(alloc, "warnings", .{ .array = .init(alloc) });
    try obj.put(alloc, "anomalies", .{ .array = .init(alloc) });

    // GitDeploy appends `name` last.
    try obj.put(alloc, "name", .{ .string = src.name });
    return .{ .object = obj };
}

/// Build the system/package status shape (PackageDeploy.get_update_status).
/// No live package cache → zero pending packages.
fn buildSystemStatus(alloc: std.mem.Allocator, src: Source) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "name", .{ .string = src.name });
    try obj.put(alloc, "configured_type", .{ .string = "system" });
    try obj.put(alloc, "package_count", .{ .integer = 0 });
    try obj.put(alloc, "package_list", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

/// Build the web/zip status shape (NetDeploy.get_update_status). Not used by the
/// default sources but supported for `[update_manager <name>]` web clients.
fn buildWebStatus(alloc: std.mem.Allocator, src: Source) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    // AppDeploy base keys.
    const channel = if (src.channel.len > 0) src.channel else "stable";
    try obj.put(alloc, "channel", .{ .string = channel });
    try obj.put(alloc, "debug_enabled", .{ .bool = false });
    try obj.put(alloc, "channel_invalid", .{ .bool = false });
    try obj.put(alloc, "is_valid", .{ .bool = true });
    try obj.put(alloc, "configured_type", .{ .string = if (src.type == .zip) "zip" else "web" });
    try obj.put(alloc, "info_tags", .{ .array = .init(alloc) });
    // NetDeploy keys.
    try obj.put(alloc, "name", .{ .string = src.name });
    try obj.put(alloc, "repo_name", .{ .string = src.repo_name });
    try obj.put(alloc, "owner", .{ .string = src.owner });
    try obj.put(alloc, "version", .{ .string = "?" });
    try obj.put(alloc, "remote_version", .{ .string = "?" });
    try obj.put(alloc, "rollback_version", .{ .string = "?" });
    try obj.put(alloc, "last_error", .{ .string = "" });
    try obj.put(alloc, "warnings", .{ .array = .init(alloc) });
    try obj.put(alloc, "anomalies", .{ .array = .init(alloc) });
    return .{ .object = obj };
}

fn buildSourceStatus(io: ?std.Io, alloc: std.mem.Allocator, src: Source, environment: ?*const std.process.Environ.Map) !std.json.Value {
    return switch (src.type) {
        .git_repo => buildGitStatus(io, alloc, src, environment),
        .system => buildSystemStatus(alloc, src),
        .web, .zip => buildWebStatus(alloc, src),
    };
}

/// Cached git-describe versions retain the tag and commit count in API output.
fn shortGitVersion(version: []const u8) []const u8 {
    const hash_at = std.mem.lastIndexOf(u8, version, "-g") orelse return version;
    const suffix = version[hash_at + 2 ..];
    const hash = if (std.mem.indexOfScalar(u8, suffix, '-')) |end| suffix[0..end] else suffix;
    if (hash.len == 0) return "?";
    for (hash) |ch| if (!std.ascii.isHex(ch)) return "?";
    return version[0..hash_at];
}

/// Restore Moonraker's update_manager namespace without contacting remotes.
fn buildCachedStatus(alloc: std.mem.Allocator, src: Source, cache: std.json.Value) !std.json.Value {
    var result = try buildSourceStatus(null, alloc, src, null);
    if (cache != .object) return result;
    const fields = if (src.type == .git_repo) &[_][2][]const u8{
        .{ "is_valid", "is_valid" },                   .{ "owner", "git_owner" },
        .{ "repo_name", "git_repo_name" },             .{ "remote_alias", "git_remote" },
        .{ "branch", "git_branch" },                   .{ "remote_url", "upstream_url" },
        .{ "recovery_url", "recovery_url" },           .{ "current_hash", "current_commit" },
        .{ "remote_hash", "upstream_commit" },         .{ "detached", "head_detached" },
        .{ "commits_behind", "commits_behind" },       .{ "commits_behind_count", "cbh_count" },
        .{ "git_messages", "git_messages" },           .{ "corrupt", "corrupt" },
        .{ "full_version_string", "current_version" }, .{ "full_version_string", "full_version_string" },
        .{ "version", "current_version" },             .{ "version", "full_version_string" },
        .{ "remote_version", "upstream_version" },     .{ "rollback_version", "rollback_version" },
    } else &[_][2][]const u8{
        .{ "is_valid", "is_valid" },             .{ "version", "version" },
        .{ "remote_version", "remote_version" }, .{ "rollback_version", "rollback_version" },
        .{ "last_error", "last_error" },
    };
    for (fields) |field| {
        var value = cache.object.get(field[1]) orelse continue;
        const default = result.object.get(field[0]) orelse continue;
        if (std.meta.activeTag(value) != std.meta.activeTag(default)) continue;
        if (src.type == .git_repo and
            (std.mem.eql(u8, field[0], "version") or std.mem.eql(u8, field[0], "remote_version") or std.mem.eql(u8, field[0], "rollback_version")))
            value = .{ .string = shortGitVersion(value.string) };
        try result.object.put(alloc, field[0], value);
    }
    if (src.type == .git_repo) {
        const dirty = std.mem.endsWith(u8, result.object.get("full_version_string").?.string, "-dirty");
        const untracked = cache.object.get("untracked_files") orelse .null;
        try result.object.put(alloc, "is_dirty", .{ .bool = dirty });
        try result.object.put(alloc, "pristine", .{ .bool = !dirty and (untracked != .array or untracked.array.items.len == 0) });
    }
    return result;
}

/// Build the full status payload Moonraker returns from `_handle_status_request`
/// and `_handle_refresh_request`:
///   { github_rate_limit, github_requests_remaining, github_limit_reset_time,
///     version_info: { <name>: {...} }, busy }
///
/// The GitHub rate-limit stats are null until phobos makes a GitHub API request
/// (it never does in the spine), matching HttpClient.github_api_stats on a fresh
/// process.
fn buildStatusPayload(ctx: *UpdateCtx, alloc: std.mem.Allocator) !std.json.Value {
    const cached = if (ctx.store) |store| try store.getNamespace(alloc, "update_manager") else .null;
    var version_info: std.json.ObjectMap = .empty;
    for (ctx.sources) |src| {
        const entry = if (cached == .object) cached.object.get(src.name) else null;
        var status = if (entry) |value|
            try buildCachedStatus(alloc, src, value)
        else if (ctx.store != null and src.type == .git_repo and src.repo_path.len == 0)
            std.json.Value{ .object = .empty }
        else
            try buildSourceStatus(ctx.io, alloc, src, ctx.gitEnvironment());
        if ((src.type == .web or src.type == .zip) and src.repo_path.len > 0) if (ctx.io) |io| {
            const target = net_update.Target.open(alloc, io, src.repo_path, ctx.gitEnvironment()) catch {
                try status.object.put(alloc, "is_valid", .{ .bool = false });
                try version_info.put(alloc, src.name, status);
                continue;
            };
            defer target.close(io);
            if (target.read(alloc, io, src)) |current| {
                try status.object.put(alloc, "version", .{ .string = current.version });
                try status.object.put(alloc, "is_valid", .{ .bool = true });
            } else |_| try status.object.put(alloc, "is_valid", .{ .bool = false });
            if (target.parent.openDir(io, target.backup, .{ .follow_symlinks = false })) |backup| {
                defer backup.close(io);
                if (net_update.installed(alloc, io, backup, src)) |old| try status.object.put(alloc, "rollback_version", .{ .string = old.version }) else |_| {}
            } else |_| {}
        };
        try version_info.put(alloc, src.name, status);
    }

    var out: std.json.ObjectMap = .empty;
    // get_rate_limit_stats() — null on a process that has made no GitHub calls.
    try out.put(alloc, "github_rate_limit", .null);
    try out.put(alloc, "github_requests_remaining", .null);
    try out.put(alloc, "github_limit_reset_time", .null);
    try out.put(alloc, "version_info", .{ .object = version_info });
    try out.put(alloc, "busy", .{ .bool = ctx.busy.load(.monotonic) });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Notification emission
// ---------------------------------------------------------------------------

/// Emit `notify_update_refreshed` with `[status_payload]` params. No-op when the
/// bus or io is unavailable (unit tests). Takes Core: the status and refresh
/// handlers run off it.
fn emitRefreshed(ctx: *UpdateCtx, alloc: std.mem.Allocator, payload: std.json.Value) void {
    const bus = ctx.bus orelse return;
    const io = ctx.io orelse return;
    var arr: std.json.Array = .init(alloc);
    arr.append(payload) catch return;
    bus.emit(io, notify.names.update_refreshed, .{ .array = arr }) catch {};
}

/// Build the `notify_update_response` notification object (CommandHelper
/// notification shape): `{ message, application, proc_id, complete }`. proc_id
/// mirrors Moonraker's `id(web_request)` — a stable per-request integer; phobos
/// uses a monotonic counter.
fn buildResponseNotification(
    alloc: std.mem.Allocator,
    application: []const u8,
    proc_id: i64,
    message: []const u8,
    complete: bool,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "message", .{ .string = message });
    try obj.put(alloc, "application", .{ .string = application });
    try obj.put(alloc, "proc_id", .{ .integer = proc_id });
    try obj.put(alloc, "complete", .{ .bool = complete });
    return .{ .object = obj };
}

/// Emit `notify_update_response` with `[notification]` params. No-op without
/// bus/io. Returns the notification object so handlers can reuse it (and tests
/// can assert on the shape even without a live bus).
fn emitResponse(
    ctx: *UpdateCtx,
    alloc: std.mem.Allocator,
    notification: std.json.Value,
) void {
    const bus = ctx.bus orelse return;
    const io = ctx.io orelse return;
    var arr: std.json.Array = .init(alloc);
    arr.append(notification) catch return;
    bus.emit(io, notify.names.update_response, .{ .array = arr }) catch {};
}

/// Monotonic proc-id source (stands in for Moonraker's `id(web_request)`).
// u32 (not i64): 32-bit ARM has no 64-bit atomic RMW, and a u32 id space is
// ample for a monotonic proc counter.
var proc_counter: std.atomic.Value(u32) = .init(1);
fn nextProcId() i64 {
    return proc_counter.fetchAdd(1, .monotonic);
}

// ---------------------------------------------------------------------------
// GET /machine/update/status → machine.update.status
// ---------------------------------------------------------------------------

/// Returns the full version_info status payload. When `refresh` is true, runs
/// `git fetch origin --prune` for each git_repo source with a live repo_path
/// before building the payload, so remote tracking refs are up-to-date. Also
/// emits `notify_update_refreshed` so subscribers see the refresh completion.
pub fn handleStatus(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const requested_refresh = (try webreq.optional(bool, params, "refresh")) orelse false;
    var refresh = false;
    const payload = blk: {
        try ctx.commands.lock(ctx.clock_io);
        defer ctx.commands.unlock(ctx.clock_io);
        const recent = if (ctx.last_status_refresh) |last| last.untilNow(ctx.clock_io).raw.toSeconds() < status_refresh_interval_s else false;
        refresh = requested_refresh and !ctx.busy.load(.acquire) and !ctx.isPrinting() and !recent;
        if (refresh) {
            for (ctx.sources) |src| {
                if (src.type == .git_repo and src.repo_path.len > 0) {
                    _ = gitFetch(ctx.io, alloc, src.repo_path, ctx.gitEnvironment());
                } else if (src.type == .web or src.type == .zip) try refreshNet(ctx, alloc, src);
            }
            ctx.last_status_refresh = .now(ctx.clock_io, .awake);
        }
        break :blk try buildStatusPayload(ctx, alloc);
    };
    if (refresh) emitRefreshed(ctx, alloc, payload);
    return payload;
}

// ---------------------------------------------------------------------------
// POST /machine/update/refresh → machine.update.refresh
// ---------------------------------------------------------------------------

/// Refresh one source (when `name` is given) or all sources, then return the
/// status payload and emit `notify_update_refreshed`. For git_repo sources with
/// a non-empty repo_path and a live io, runs `git fetch origin --prune` to
/// update remote tracking refs so the subsequent status payload reflects
/// accurate behind/ahead counts. Falls back to a no-op when io is null
/// (unit tests) or repo_path is empty (dev workstation).
pub fn handleRefresh(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const name = (try webreq.optional([]const u8, params, "name"));
    if (name) |n| {
        if (ctx.findSource(n) == null) return error.InvalidParams;
    }
    if (ctx.busy.load(.acquire) or ctx.isPrinting()) return error.UpdateBusy;
    const payload = blk: {
        try ctx.commands.lock(ctx.clock_io);
        defer ctx.commands.unlock(ctx.clock_io);
        if (ctx.busy.load(.acquire) or ctx.isPrinting()) return error.UpdateBusy;
        for (ctx.sources) |src| {
            if (name) |n| if (!std.mem.eql(u8, src.name, n)) continue;
            if (src.type == .git_repo) _ = gitFetch(ctx.io, alloc, src.repo_path, ctx.gitEnvironment());
            if (src.type == .web or src.type == .zip) try refreshNet(ctx, alloc, src);
        }
        ctx.last_status_refresh = .now(ctx.clock_io, .awake);
        break :blk try buildStatusPayload(ctx, alloc);
    };
    emitRefreshed(ctx, alloc, payload);
    return payload;
}

// ---------------------------------------------------------------------------
// Update handlers
// ---------------------------------------------------------------------------

/// Send one `notify_update_response` line. Allocation failure drops the line;
/// the handler's own result still reaches the client.
fn notifyLine(ctx: *UpdateCtx, alloc: std.mem.Allocator, app: []const u8, proc_id: i64, complete: bool, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch return;
    emitResponse(ctx, alloc, buildResponseNotification(alloc, app, proc_id, msg, complete) catch return);
}

/// Run a single-target update for `app`. With io and a repo_path, a git_repo
/// source runs `git fetch origin --prune` then `git reset --hard
/// origin/<branch>`; either failing is error.GitFailed. The system source runs
/// apt-get through `shell`, and a source with `requirements` runs pip. A
/// failure after the start line sends Moonraker's "Error updating <app>: <err>"
/// completion line.
fn runUpdate(ctx: *UpdateCtx, alloc: std.mem.Allocator, app: []const u8) anyerror!std.json.Value {
    if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
    const src = ctx.findSource(app) orelse return error.NotFound;
    if ((src.type == .system or src.requirements.len > 0) and ctx.shell == null) return error.NoPackageProvider;
    const proc_id = nextProcId();
    try ctx.beginMutation();
    defer ctx.busy.store(false, .release);

    notifyLine(ctx, alloc, app, proc_id, false, "Updating {s}...", .{app});
    updateSource(ctx, alloc, src) catch |err| {
        notifyLine(ctx, alloc, app, proc_id, true, "Error updating {s}: {s}", .{ app, @errorName(err) });
        return err;
    };
    notifyLine(ctx, alloc, app, proc_id, true, "{s} update finished", .{app});
    return .{ .string = "ok" };
}

/// The commands of one single-target update (see `runUpdate`).
fn updateSource(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source) !void {
    var changed = false;
    {
        try ctx.commands.lock(ctx.clock_io);
        defer ctx.commands.unlock(ctx.clock_io);
        if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
        if (src.type == .git_repo and src.repo_path.len > 0) {
            if (ctx.io) |io| {
                const previous = gitOutput(io, alloc, src.repo_path, &.{ "rev-parse", "HEAD" }, ctx.gitEnvironment()) orelse return error.GitFailed;
                defer alloc.free(previous);
                const dirty = gitOutput(io, alloc, src.repo_path, &.{ "status", "--porcelain" }, ctx.gitEnvironment());
                defer if (dirty) |bytes| alloc.free(bytes);
                if (!gitFetch(io, alloc, src.repo_path, ctx.gitEnvironment())) return error.GitFailed;
                const ref = try std.fmt.allocPrint(alloc, "origin/{s}", .{src.branch});
                defer alloc.free(ref);
                if (!gitReset(io, alloc, src.repo_path, ref, ctx.gitEnvironment())) return error.GitFailed;
                const current = gitOutput(io, alloc, src.repo_path, &.{ "rev-parse", "HEAD" }, ctx.gitEnvironment()) orelse return error.GitFailed;
                defer alloc.free(current);
                changed = !std.mem.eql(u8, previous, current) or (dirty != null and dirty.?.len > 0);
            }
        }
        if (src.type == .web or src.type == .zip) {
            const io = ctx.io orelse return error.IoUnavailable;
            const target = try net_update.Target.open(alloc, io, src.repo_path, ctx.gitEnvironment());
            defer target.close(io);
            const current = try target.read(alloc, io, src);
            const cache = if (ctx.store) |store| (try store.getItem(alloc, "update_manager", src.name)) orelse .null else .null;
            const release = net_update.cachedRelease(cache) orelse try net_update.refresh(alloc, io, src, current, ctx.github_api_base);
            changed = try net_update.install(alloc, io, target, src, release);
            try saveNetCache(ctx, alloc, src, release, (try target.read(alloc, io, src)).version);
        }
        try updatePackages(ctx, alloc, src);
    }
    if (changed) try restartServices(ctx, alloc, src);
}

fn saveNetCache(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source, release: net_update.Release, version: []const u8) !void {
    const store = ctx.store orelse return;
    var cache: std.json.ObjectMap = .empty;
    try cache.put(alloc, "version", .{ .string = version });
    try cache.put(alloc, "remote_version", .{ .string = release.version });
    try cache.put(alloc, "is_valid", .{ .bool = true });
    try cache.put(alloc, "last_error", .{ .string = "" });
    var info: std.json.Array = .init(alloc);
    try info.append(.{ .string = release.url });
    try info.append(.{ .string = "application/zip" });
    try info.append(.{ .integer = @intCast(release.size) });
    try cache.put(alloc, "dl_info", .{ .array = info });
    try store.insertItem(alloc, "update_manager", src.name, .{ .object = cache });
}

fn refreshNet(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source) !void {
    const io = ctx.io orelse return;
    if (src.repo_path.len == 0) return;
    const target = net_update.Target.open(alloc, io, src.repo_path, ctx.gitEnvironment()) catch return;
    defer target.close(io);
    const current = target.read(alloc, io, src) catch return;
    const release = try net_update.refresh(alloc, io, src, current, ctx.github_api_base);
    try saveNetCache(ctx, alloc, src, release, current.version);
}

fn restartServices(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source) !void {
    if (src.managed_services.len == 0) return;
    const restart = ctx.restart_service orelse return error.ServiceUnavailable;
    const service_ctx = ctx.service_ctx orelse return error.ServiceUnavailable;
    for (src.managed_services) |service| try restart(service_ctx, alloc, service);
}

/// apt-get for the system source, then pip for a source with `requirements`.
fn updatePackages(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source) !void {
    if (src.type == .system) try upgradePackages(ctx, alloc);
    if (src.requirements.len > 0) try pipInstallRequirements(ctx, alloc, src.requirements);
}

/// POST /machine/update/moonraker → "ok".
pub fn handleUpdateMoonraker(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runUpdate(ctx, alloc, "moonraker");
}

/// POST /machine/update/klipper → "ok".
pub fn handleUpdateKlipper(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runUpdate(ctx, alloc, "klipper");
}

/// Moonraker `AptCliProvider`: `apt-get update` then `apt-get upgrade --yes`,
/// both under `sudo DEBIAN_FRONTEND=noninteractive`.
pub fn upgradePackages(ctx: *UpdateCtx, alloc: std.mem.Allocator) !void {
    const sh = ctx.shell orelse return error.NoPackageProvider;
    const shell_ctx = ctx.shell_ctx orelse return error.NoPackageProvider;
    try sh(shell_ctx, alloc, "sudo DEBIAN_FRONTEND=noninteractive apt-get update");
    try sh(shell_ctx, alloc, "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade --yes");
}

/// Moonraker `AsyncPipExecutor.install_packages` for a requirements file:
/// `pip install -r <path>`.
pub fn pipInstallRequirements(ctx: *UpdateCtx, alloc: std.mem.Allocator, requirements: []const u8) !void {
    const sh = ctx.shell orelse return error.NoPackageProvider;
    const shell_ctx = ctx.shell_ctx orelse return error.NoPackageProvider;
    const cmd = try std.fmt.allocPrint(alloc, "pip install -r {s}", .{requirements});
    try sh(shell_ctx, alloc, cmd);
}

/// POST /machine/update/system → "ok" after apt-get update and upgrade.
pub fn handleUpdateSystem(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runUpdate(ctx, alloc, "system");
}

/// POST /machine/update/client?name=<name> → "ok". Without a `name` param
/// Moonraker treats it as a full update; phobos does likewise.
pub fn handleUpdateClient(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const name = (try webreq.optional([]const u8, params, "name")) orelse return runFullUpdate(ctx, alloc);
    return runUpdate(ctx, alloc, name);
}

/// POST /machine/update/upgrade?name=<name> → "ok". Like `client`, a
/// missing `name` falls back to a full update (matches `_handle_update_request`
/// where app in ("upgrade","client") routes to full when name is None).
pub fn handleUpgrade(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const name = (try webreq.optional([]const u8, params, "name")) orelse return runFullUpdate(ctx, alloc);
    return runUpdate(ctx, alloc, name);
}

/// Full update across every source, with the same Git and package commands as
/// a single-source update. A failure sends "Error updating <source>: <err>".
fn runFullUpdate(ctx: *UpdateCtx, alloc: std.mem.Allocator) anyerror!std.json.Value {
    if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
    for (ctx.sources) |src| {
        if ((src.type == .system or src.requirements.len > 0) and ctx.shell == null) return error.NoPackageProvider;
    }
    const proc_id = nextProcId();
    try ctx.beginMutation();
    defer ctx.busy.store(false, .release);

    notifyLine(ctx, alloc, "full", proc_id, false, "Preparing full software update...", .{});
    for (ctx.sources) |src| {
        notifyLine(ctx, alloc, "full", proc_id, false, "Updating {s}...", .{src.name});
        updateSource(ctx, alloc, src) catch |err| {
            notifyLine(ctx, alloc, "full", proc_id, true, "Error updating {s}: {s}", .{ src.name, @errorName(err) });
            return err;
        };
    }
    notifyLine(ctx, alloc, "full", proc_id, true, "Full Update Complete", .{});
    return .{ .string = "ok" };
}

/// POST /machine/update/full → "ok". See `runFullUpdate`.
pub fn handleFull(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runFullUpdate(ctx, alloc);
}

// ---------------------------------------------------------------------------
// POST /machine/update/recover → machine.update.recover
// ---------------------------------------------------------------------------

/// Recover a git source (`_handle_repo_recovery`). With io and a repo_path,
/// a hard recover runs `git reset --hard HEAD` and `git clean -fd`; a soft one
/// runs `git checkout <branch>` and `git reset --hard origin/<branch>`. There
/// is no reclone. A failure sends "Error Recovering <app>" and the error as
/// the completion line.
pub fn handleRecover(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
    const app = try webreq.required([]const u8, params, "name");
    const hard = ((try webreq.optional(bool, params, "hard")) orelse false);
    _ = ((try webreq.optional(bool, params, "update_deps")) orelse false);
    const src = ctx.findSource(app) orelse return error.NotFound;
    if (!src.isGit()) return error.InvalidParams;

    const proc_id = nextProcId();
    try ctx.beginMutation();
    defer ctx.busy.store(false, .release);

    notifyLine(ctx, alloc, app, proc_id, false, "Recovering {s}...", .{app});
    // Git runs only when io and a repo path are set. Unit tests leave io null.
    if (ctx.io != null) {
        if (src.repo_path.len > 0) recoverRepo(ctx, alloc, src, hard) catch |err| {
            notifyLine(ctx, alloc, app, proc_id, false, "Error Recovering {s}", .{app});
            notifyLine(ctx, alloc, app, proc_id, true, "{s}", .{@errorName(err)});
            return err;
        };
    }
    notifyLine(ctx, alloc, app, proc_id, true, "{s} recovery finished", .{app});
    return .{ .string = "ok" };
}

fn recoverRepo(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source, hard: bool) !void {
    const io = ctx.io orelse return;
    {
        try ctx.commands.lock(ctx.clock_io);
        defer ctx.commands.unlock(ctx.clock_io);
        if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
        if (hard) {
            if (!gitCheck(io, alloc, src.repo_path, &.{ "reset", "--hard", "HEAD" }, ctx.gitEnvironment())) return error.GitFailed;
            if (!gitCheck(io, alloc, src.repo_path, &.{ "clean", "-fd" }, ctx.gitEnvironment())) return error.GitFailed;
        } else {
            const ref = try std.fmt.allocPrint(alloc, "origin/{s}", .{src.branch});
            defer alloc.free(ref);
            if (!gitCheck(io, alloc, src.repo_path, &.{ "checkout", src.branch }, ctx.gitEnvironment())) return error.GitFailed;
            if (!gitReset(io, alloc, src.repo_path, ref, ctx.gitEnvironment())) return error.GitFailed;
        }
    }
    try restartServices(ctx, alloc, src);
}

// ---------------------------------------------------------------------------
// POST /machine/update/rollback → machine.update.rollback
// ---------------------------------------------------------------------------

/// Roll a git source back (`_handle_rollback`): with io and a repo_path,
/// `git reset --hard <rollback_ref>`. An empty `rollback_ref` runs nothing and
/// completes with "Rollback not performed". A failure sends "Error Rolling
/// Back <app>" and the error as the completion line.
pub fn handleRollback(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
    const app = try webreq.required([]const u8, params, "name");
    const src = ctx.findSource(app) orelse return error.NotFound;
    if (src.type == .system) return error.InvalidParams;

    const proc_id = nextProcId();
    try ctx.beginMutation();
    defer ctx.busy.store(false, .release);

    notifyLine(ctx, alloc, app, proc_id, false, "Rolling Back {s}...", .{app});
    if (src.type == .web or src.type == .zip) {
        rollbackNet(ctx, alloc, src) catch |err| {
            notifyLine(ctx, alloc, app, proc_id, false, "Error Rolling Back {s}", .{app});
            notifyLine(ctx, alloc, app, proc_id, true, "{s}", .{@errorName(err)});
            return err;
        };
        notifyLine(ctx, alloc, app, proc_id, true, "{s} rollback finished", .{app});
        return .{ .string = "ok" };
    }
    if (src.rollback_ref.len == 0) {
        notifyLine(ctx, alloc, app, proc_id, true, "Rollback not performed", .{});
        return .{ .string = "ok" };
    }
    if (ctx.io) |io| {
        const reset = blk: {
            try ctx.commands.lock(ctx.clock_io);
            defer ctx.commands.unlock(ctx.clock_io);
            if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
            break :blk src.repo_path.len == 0 or gitReset(io, alloc, src.repo_path, src.rollback_ref, ctx.gitEnvironment());
        };
        if (!reset) {
            notifyLine(ctx, alloc, app, proc_id, false, "Error Rolling Back {s}", .{app});
            notifyLine(ctx, alloc, app, proc_id, true, "GitFailed", .{});
            return error.GitFailed;
        }
        if (src.repo_path.len > 0) restartServices(ctx, alloc, src) catch |err| {
            notifyLine(ctx, alloc, app, proc_id, false, "Error Rolling Back {s}", .{app});
            notifyLine(ctx, alloc, app, proc_id, true, "{s}", .{@errorName(err)});
            return err;
        };
    }
    notifyLine(ctx, alloc, app, proc_id, true, "{s} rollback finished", .{app});
    return .{ .string = "ok" };
}

fn rollbackNet(ctx: *UpdateCtx, alloc: std.mem.Allocator, src: Source) !void {
    const io = ctx.io orelse return error.IoUnavailable;
    {
        try ctx.commands.lock(ctx.clock_io);
        defer ctx.commands.unlock(ctx.clock_io);
        if (ctx.isPrinting()) return error.UpdateRefusedPrinting;
        const target = try net_update.Target.open(alloc, io, src.repo_path, ctx.gitEnvironment());
        defer target.close(io);
        try net_update.rollback(alloc, io, target, src);
    }
    try restartServices(ctx, alloc, src);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
//
// Every path is registered POST-only (except status which is GET-only), so each
// derives a single dotted JSON-RPC method name matching Moonraker:
//   /machine/update/status   GET  → machine.update.status
//   /machine/update/refresh  POST → machine.update.refresh
//   ... etc.

pub fn registerUpdateManager(reg: *Registry, ctx: *UpdateCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    // Command state has its own mutex; subprocess waits never hold Core.
    try reg.registerEndpoint(.{ .path = "/machine/update/status", .methods = &.{.GET}, .off_core = true }, c, handleStatus);
    try reg.registerEndpoint(.{ .path = "/machine/update/refresh", .methods = &.{.POST}, .off_core = true }, c, handleRefresh);
    try reg.registerEndpoint(.{ .path = "/machine/update/upgrade", .methods = &.{.POST}, .off_core = true }, c, handleUpgrade);
    try reg.registerEndpoint(.{ .path = "/machine/update/full", .methods = &.{.POST}, .off_core = true }, c, handleFull);
    try reg.registerEndpoint(.{ .path = "/machine/update/moonraker", .methods = &.{.POST}, .off_core = true }, c, handleUpdateMoonraker);
    try reg.registerEndpoint(.{ .path = "/machine/update/klipper", .methods = &.{.POST}, .off_core = true }, c, handleUpdateKlipper);
    try reg.registerEndpoint(.{ .path = "/machine/update/system", .methods = &.{.POST}, .off_core = true }, c, handleUpdateSystem);
    try reg.registerEndpoint(.{ .path = "/machine/update/client", .methods = &.{.POST}, .off_core = true }, c, handleUpdateClient);
    try reg.registerEndpoint(.{ .path = "/machine/update/recover", .methods = &.{.POST}, .off_core = true }, c, handleRecover);
    try reg.registerEndpoint(.{ .path = "/machine/update/rollback", .methods = &.{.POST}, .off_core = true }, c, handleRollback);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn objParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

fn testCtx() UpdateCtx {
    return .{ .clock_io = testing.io, .gpa = testing.allocator, .sources = &default_sources, .bus = null, .io = null };
}

test "status reads persistent git and web versions without refreshing" {
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(testing.io, ":memory:");
    defer db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const store = db.dataStore();
    try store.insertItem(a, "update_manager", "forge-x", try objParams(a,
        \\{"is_valid":true,"git_owner":"DrA1ex","git_repo_name":"ff5m","git_remote":"origin","git_branch":"1.4.2","current_version":"1.4.2-beta-4-16-g69663338","upstream_version":"1.4.2-beta-4-16-g69663338","rollback_version":"1.4.2-beta-4-0-g95d1771d","current_commit":"69663338","upstream_commit":"69663338","head_detached":false,"modified_files":[],"untracked_files":[],"commits_behind":[],"cbh_count":0,"git_messages":[],"corrupt":false}
    ));
    try store.insertItem(a, "update_manager", "fluidd", try objParams(a,
        \\{"is_valid":true,"version":"v1.37.7","remote_version":"1.37.7","rollback_version":"v1.37.6","last_error":""}
    ));
    const sources = [_]Source{
        default_sources[1],
        .{ .name = "forge-x", .type = .git_repo, .owner = "DrA1ex", .repo_name = "ff5m", .repo_path = "/no/such/repo", .branch = "1.4.2" },
        .{ .name = "fluidd", .type = .web, .owner = "fluidd-core", .repo_name = "fluidd" },
    };
    var ctx = UpdateCtx{ .clock_io = std.testing.io, .gpa = testing.allocator, .sources = &sources, .store = store, .bus = null };
    const result = try handleStatus(&ctx, .null, a);
    const info = result.object.get("version_info").?.object;
    const git = info.get("forge-x").?.object;
    try testing.expectEqualStrings("1.4.2-beta-4-16-g69663338", git.get("full_version_string").?.string);
    try testing.expectEqualStrings("1.4.2-beta-4-16", git.get("version").?.string);
    try testing.expectEqualStrings("1.4.2-beta-4-16", git.get("remote_version").?.string);
    try testing.expectEqualStrings("1.4.2-beta-4-0", git.get("rollback_version").?.string);
    try testing.expectEqualStrings("69663338", git.get("current_hash").?.string);
    try testing.expect(git.get("repo_detected") == null);
    const web = info.get("fluidd").?.object;
    try testing.expectEqualStrings("v1.37.7", web.get("version").?.string);
    try testing.expectEqualStrings("1.37.7", web.get("remote_version").?.string);
    try testing.expectEqualStrings("v1.37.6", web.get("rollback_version").?.string);
    try testing.expectEqual(@as(usize, 0), info.get("moonraker").?.object.count());
    try testing.expect(!ctx.initial_refresh_done);
}

test "cached git versions keep the tag count and full hash separately" {
    try testing.expectEqualStrings("v0.10.1-20", shortGitVersion("v0.10.1-20-g900848584374"));
    try testing.expectEqualStrings("v1.0-0", shortGitVersion("v1.0-0-gabcdef-dirty"));
    try testing.expectEqualStrings("?", shortGitVersion("v1.0-0-g"));
    try testing.expectEqualStrings("?", shortGitVersion("v1.0-0-gxyz"));
    try testing.expectEqualStrings("?", shortGitVersion("?"));
}

test "fuzz cached update status: malformed fields keep their declared types" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = shortGitVersion(&buf);
            var cache: std.json.ObjectMap = .empty;
            try cache.put(a, "current_version", .{ .string = &buf });
            try cache.put(a, "upstream_version", .{ .integer = 42 });
            try cache.put(a, "head_detached", .{ .string = "wrong" });
            try cache.put(a, "untracked_files", .{ .integer = 1 });
            for ([_]SourceType{ .git_repo, .web, .zip }) |kind| {
                var src = default_sources[1];
                src.type = kind;
                const result = try buildCachedStatus(a, src, .{ .object = cache });
                try testing.expect(result.object.get("version").? == .string);
                try testing.expect(result.object.get("remote_version").? == .string);
                if (kind == .git_repo) try testing.expect(result.object.get("detached").? == .bool);
                _ = try buildCachedStatus(a, src, .null);
            }
        }
    }.run, .{});
}

var test_printing_flag: bool = false;
fn testPrintingCheck(_: *anyopaque) bool {
    return test_printing_flag;
}

test "update refused while printing (U1): 503-mapped error, allowed otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    var ctx = testCtx();
    var sink: u8 = 0;
    ctx.shell = okShell;
    ctx.shell_ctx = &sink;
    ctx.printing_check = testPrintingCheck;
    ctx.printing_ctx = &dummy;

    // Not printing → updates proceed.
    test_printing_flag = false;
    try testing.expectEqualStrings("ok", (try handleUpdateMoonraker(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleFull(@ptrCast(&ctx), .null, a)).string);

    // Printing → every mutating op is refused with error.UpdateRefusedPrinting.
    test_printing_flag = true;
    try testing.expectError(error.UpdateRefusedPrinting, handleUpdateMoonraker(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.UpdateRefusedPrinting, handleUpdateKlipper(@ptrCast(&ctx), .null, a));
    try testing.expectError(error.UpdateRefusedPrinting, handleFull(@ptrCast(&ctx), .null, a));
    const recover_params = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"klipper\"}", .{});
    try testing.expectError(error.UpdateRefusedPrinting, handleRecover(@ptrCast(&ctx), recover_params.value, a));
    try testing.expectError(error.UpdateRefusedPrinting, handleRollback(@ptrCast(&ctx), recover_params.value, a));
    test_printing_flag = false; // reset for other tests
}

test "isPrinting: false without a wired check" {
    var ctx = testCtx();
    try testing.expect(!ctx.isPrinting());
}

test "fuzz isPrinting: never crashes regardless of flag" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var dummy: u8 = 0;
            var ctx = testCtx();
            const wired = smith.valueWithHash(bool, 0);
            if (wired) {
                ctx.printing_check = testPrintingCheck;
                ctx.printing_ctx = &dummy;
                test_printing_flag = smith.valueWithHash(bool, 1);
            }
            _ = ctx.isPrinting();
            test_printing_flag = false;
        }
    }.run, .{});
}

// ---- buildSourceStatus / version_info shape ----

test "buildGitStatus: full git_repo key set present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildGitStatus(null, a, default_sources[1], null); // moonraker
    const o = v.object;
    for ([_][]const u8{
        "channel",         "debug_enabled",        "channel_invalid", "is_valid",
        "configured_type", "info_tags",            "detected_type",   "remote_alias",
        "branch",          "owner",                "repo_name",       "remote_url",
        "recovery_url",    "version",              "remote_version",  "rollback_version",
        "current_hash",    "remote_hash",          "is_dirty",        "detached",
        "commits_behind",  "commits_behind_count", "git_messages",    "full_version_string",
        "pristine",        "corrupt",              "warnings",        "anomalies",
        "name",
    }) |k| {
        try testing.expect(o.get(k) != null);
    }
    try testing.expectEqualStrings("git_repo", o.get("detected_type").?.string);
    try testing.expectEqualStrings("moonraker", o.get("name").?.string);
    try testing.expectEqualStrings("Arksine", o.get("owner").?.string);
    try testing.expectEqual(@as(i64, 0), o.get("commits_behind_count").?.integer);
}

test "buildSystemStatus: package key set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildSystemStatus(a, default_sources[0]);
    const o = v.object;
    try testing.expectEqualStrings("system", o.get("name").?.string);
    try testing.expectEqualStrings("system", o.get("configured_type").?.string);
    try testing.expectEqual(@as(i64, 0), o.get("package_count").?.integer);
    try testing.expect(o.get("package_list").? == .array);
}

test "buildWebStatus: web key set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src: Source = .{ .name = "mainsail", .type = .web, .owner = "mainsail-crew", .repo_name = "mainsail" };
    const v = try buildWebStatus(a, src);
    const o = v.object;
    try testing.expectEqualStrings("web", o.get("configured_type").?.string);
    try testing.expectEqualStrings("mainsail", o.get("name").?.string);
    try testing.expect(o.get("last_error") != null);
    try testing.expect(o.get("warnings").? == .array);
}

test "buildStatusPayload: version_info has all sources + rate-limit keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    const v = try buildStatusPayload(&ctx, a);
    const o = v.object;
    try testing.expect(o.get("github_rate_limit").? == .null);
    try testing.expect(o.get("github_requests_remaining").? == .null);
    try testing.expect(o.get("github_limit_reset_time").? == .null);
    try testing.expectEqual(false, o.get("busy").?.bool);
    const vi = o.get("version_info").?.object;
    try testing.expect(vi.get("moonraker") != null);
    try testing.expect(vi.get("klipper") != null);
    try testing.expect(vi.get("system") != null);
    try testing.expectEqualStrings("git_repo", vi.get("klipper").?.object.get("detected_type").?.string);
    try testing.expectEqualStrings("system", vi.get("system").?.object.get("configured_type").?.string);
}

// ---- handleStatus ----

test "handleStatus: returns payload, refresh=false no error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    const v = try handleStatus(@ptrCast(&ctx), .null, a);
    try testing.expect(v.object.get("version_info") != null);
    const v2 = try handleStatus(@ptrCast(&ctx), try objParams(a, "{\"refresh\":true}"), a);
    try testing.expect(v2.object.get("version_info") != null);
}

// ---- handleRefresh ----

test "handleRefresh: all sources returns payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    const v = try handleRefresh(@ptrCast(&ctx), .null, a);
    try testing.expect(v.object.get("version_info").?.object.get("moonraker") != null);
}

test "handleRefresh: named source ok; unknown source InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    const v = try handleRefresh(@ptrCast(&ctx), try objParams(a, "{\"name\":\"klipper\"}"), a);
    try testing.expect(v.object.get("version_info") != null);
    try testing.expectError(error.InvalidParams, handleRefresh(@ptrCast(&ctx), try objParams(a, "{\"name\":\"nope\"}"), a));
}

// ---- update handlers ----

fn okShell(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {}

const CmdLog = struct {
    cmds: [4][]const u8 = .{ "", "", "", "" },
    n: usize = 0,
    fn run(ctx: *anyopaque, alloc: std.mem.Allocator, cmd: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.n >= self.cmds.len) return error.TooManyCommands;
        self.cmds[self.n] = try alloc.dupe(u8, cmd);
        self.n += 1;
    }
};

test "handleUpdateMoonraker/Klipper: return ok ack; system needs a package provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    try testing.expectEqualStrings("ok", (try handleUpdateMoonraker(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleUpdateKlipper(@ptrCast(&ctx), .null, a)).string);
    try testing.expectError(error.NoPackageProvider, handleUpdateSystem(@ptrCast(&ctx), .null, a));
}

test "handleUpdateSystem: runs apt-get update then apt-get upgrade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var log = CmdLog{};
    var ctx = testCtx();
    ctx.shell = CmdLog.run;
    ctx.shell_ctx = &log;
    try testing.expectEqualStrings("ok", (try handleUpdateSystem(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqual(@as(usize, 2), log.n);
    try testing.expectEqualStrings("sudo DEBIAN_FRONTEND=noninteractive apt-get update", log.cmds[0]);
    try testing.expectEqualStrings("sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade --yes", log.cmds[1]);
}

test "git update with requirements runs pip install -r" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_]Source{.{
        .name = "moonraker",
        .type = .git_repo,
        .owner = "Arksine",
        .repo_name = "moonraker",
        .requirements = "scripts/moonraker-requirements.txt",
    }};
    var log = CmdLog{};
    var ctx = testCtx();
    ctx.sources = &sources;
    ctx.shell = CmdLog.run;
    ctx.shell_ctx = &log;
    try testing.expectEqualStrings("ok", (try handleUpdateMoonraker(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqual(@as(usize, 1), log.n);
    try testing.expectEqualStrings("pip install -r scripts/moonraker-requirements.txt", log.cmds[0]);
}

test "handleUpgrade/Client: name=source ok; no name → full update ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    var sink: u8 = 0;
    ctx.shell = okShell;
    ctx.shell_ctx = &sink;
    try testing.expectEqualStrings("ok", (try handleUpgrade(@ptrCast(&ctx), try objParams(a, "{\"name\":\"moonraker\"}"), a)).string);
    try testing.expectEqualStrings("ok", (try handleUpgrade(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleUpdateClient(@ptrCast(&ctx), .null, a)).string);
    try testing.expectError(error.NotFound, handleUpgrade(@ptrCast(&ctx), try objParams(a, "{\"name\":\"ghost\"}"), a));
}

test "handleFull: returns ok ack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    var sink: u8 = 0;
    ctx.shell = okShell;
    ctx.shell_ctx = &sink;
    try testing.expectEqualStrings("ok", (try handleFull(@ptrCast(&ctx), .null, a)).string);
}

// ---- recover / rollback ----

test "handleRecover: git source ok; system source InvalidParams; missing name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    try testing.expectEqualStrings("ok", (try handleRecover(@ptrCast(&ctx), try objParams(a, "{\"name\":\"klipper\"}"), a)).string);
    // system is not a git repo
    try testing.expectError(error.InvalidParams, handleRecover(@ptrCast(&ctx), try objParams(a, "{\"name\":\"system\"}"), a));
    // unknown source
    try testing.expectError(error.NotFound, handleRecover(@ptrCast(&ctx), try objParams(a, "{\"name\":\"ghost\"}"), a));
    // missing name param
    try testing.expectError(error.InvalidParams, handleRecover(@ptrCast(&ctx), .null, a));
}

test "handleRollback: known source ok; unknown NotFound; non-git InvalidParams" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    try testing.expectEqualStrings("ok", (try handleRollback(@ptrCast(&ctx), try objParams(a, "{\"name\":\"moonraker\"}"), a)).string);
    try testing.expectError(error.NotFound, handleRollback(@ptrCast(&ctx), try objParams(a, "{\"name\":\"ghost\"}"), a));
    try testing.expectError(error.InvalidParams, handleRollback(@ptrCast(&ctx), .null, a));
    // system is not a git repo — rollback must reject.
    try testing.expectError(error.InvalidParams, handleRollback(@ptrCast(&ctx), try objParams(a, "{\"name\":\"system\"}"), a));
}

// ---- buildResponseNotification ----

test "buildResponseNotification: exact CommandHelper shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildResponseNotification(a, "klipper", 7, "Updating klipper...", false);
    const o = v.object;
    try testing.expectEqualStrings("klipper", o.get("application").?.string);
    try testing.expectEqual(@as(i64, 7), o.get("proc_id").?.integer);
    try testing.expectEqualStrings("Updating klipper...", o.get("message").?.string);
    try testing.expectEqual(false, o.get("complete").?.bool);
}

// ---- param helpers ----

test "request booleans accept bools and strings and reject integers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    try testing.expect(((try webreq.optional(bool, try objParams(a, "{\"x\":true}"), "x")) orelse false));
    try testing.expect(((try webreq.optional(bool, try objParams(a, "{\"x\":\"true\"}"), "x")) orelse false));
    try testing.expectError(error.InvalidParams, handleStatus(&ctx, try objParams(a, "{\"refresh\":1}"), a));
    try testing.expect(!((try webreq.optional(bool, try objParams(a, "{\"x\":false}"), "x")) orelse true));
    try testing.expect(((try webreq.optional(bool, .null, "x")) orelse true));
}

test "registerUpdateManager: wires expected routes and JSON-RPC methods" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = testCtx();
    try registerUpdateManager(&reg, &ctx);

    try testing.expect(reg.lookup(.GET, "/machine/update/status") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/refresh") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/upgrade") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/full") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/moonraker") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/klipper") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/system") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/client") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/recover") != null);
    try testing.expect(reg.lookup(.POST, "/machine/update/rollback") != null);
    // git status and fetch must not hold Core.
    try testing.expect(d.methods.get("machine.update.status").?.off_core);
    try testing.expect(d.methods.get("machine.update.refresh").?.off_core);
    try testing.expect(d.methods.get("machine.update.client").?.off_core);
}

// ---- git status with real io ----

test "buildGitStatus: empty repo_path with null io returns defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildGitStatus(null, a, default_sources[1], null); // moonraker, no repo_path
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
    try testing.expectEqual(false, o.get("detached").?.bool);
    try testing.expect(o.get("repo_detected") == null);
}

test "buildGitStatus: empty repo_path with non-null io still returns defaults" {
    // No real StdIo needed; we test with our own project path that has no
    // repo_path set, so gitOutput/gitCheck are never called.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_no_path: Source = .{
        .name = "test_git",
        .type = .git_repo,
        .owner = "test",
        .repo_name = "test",
        .branch = "main",
        .repo_path = "",
    };
    const v = try buildGitStatus(null, a, src_no_path, null);
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
    try testing.expect(o.get("repo_detected") == null);
}

test "buildGitStatus: with repo_path set honors defaults when io is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_with_path: Source = .{
        .name = "test_git",
        .type = .git_repo,
        .owner = "test",
        .repo_name = "test",
        .branch = "main",
        .repo_path = "/nonexistent",
    };
    // io is null, so git commands are never run; "?" defaults are used.
    const v = try buildGitStatus(null, a, src_with_path, null);
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
    try testing.expect(o.get("repo_detected") == null);
}

// ---- gitFetch ----

test "gitFetch: returns false with empty repo_path" {
    try testing.expect(!gitFetch(null, testing.allocator, "", null));
    try testing.expect(!gitFetch(@as(?std.Io, undefined), testing.allocator, "", null));
}

test "gitFetch: returns false when io is null" {
    try testing.expect(!gitFetch(null, testing.allocator, "/some/repo", null));
}

test "gitFetch: returns false for nonexistent repo" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    try testing.expect(!gitFetch(threaded.io(), std.heap.smp_allocator, "/nonexistent/path", null));
}

const TestRepo = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn init() !TestRepo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(path);
        try testing.expect(gitCheck(testing.io, testing.allocator, path, &.{ "init", "--initial-branch=main" }, null));
        try testing.expect(gitCheck(testing.io, testing.allocator, path, &.{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial" }, null));
        try testing.expect(gitCheck(testing.io, testing.allocator, path, &.{ "remote", "add", "origin", path }, null));
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TestRepo) void {
        self.tmp.cleanup();
        testing.allocator.free(self.path);
    }
};

test "gitFetch: fetches only the local fixture origin" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var repo = try TestRepo.init();
    defer repo.deinit();
    try testing.expect(gitFetch(io, testing.allocator, repo.path, null));
    const head = gitOutput(io, testing.allocator, repo.path, &.{ "rev-parse", "HEAD" }, null).?;
    defer testing.allocator.free(head);
    const remote = gitOutput(io, testing.allocator, repo.path, &.{ "rev-parse", "origin/main" }, null).?;
    defer testing.allocator.free(remote);
    try testing.expectEqualStrings(head, remote);
}

test "gitOutput rejects invalid UTF8 version names before JSON serialization" {
    var repo = try TestRepo.init();
    defer repo.deinit();
    try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "tag", "release-\xff" }, null));
    const output = gitOutput(testing.io, testing.allocator, repo.path, &.{ "describe", "--tags", "--always" }, null);
    defer if (output) |bytes| testing.allocator.free(bytes);
    try testing.expectEqual(null, output);
}

test "fuzz Git version output is valid UTF8 or unavailable" {
    try testing.fuzz({}, struct {
        fn check(_: void, smith: *testing.Smith) !void {
            var repo = try TestRepo.init();
            defer repo.deinit();
            var tag: [18]u8 = undefined;
            tag[0] = 'v';
            tag[1] = '-';
            smith.bytes(tag[2..]);
            for (tag[2..]) |*byte| {
                if (byte.* < 0x80) byte.* = 'a' + byte.* % 26;
            }
            try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "tag", &tag }, null));
            const output = gitOutput(testing.io, testing.allocator, repo.path, &.{ "describe", "--tags", "--always" }, null);
            defer if (output) |bytes| testing.allocator.free(bytes);
            if (std.unicode.utf8ValidateSlice(&tag)) {
                try testing.expectEqualStrings(&tag, output orelse return error.MissingGitOutput);
            } else {
                try testing.expectEqual(null, output);
            }
        }
    }.check, .{});
}

test "Git ignores inherited repository overrides and preserves connection environment" {
    var repo = try TestRepo.init();
    defer repo.deinit();
    var other = try TestRepo.init();
    defer other.deinit();
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    const other_git = try std.fs.path.join(testing.allocator, &.{ other.path, ".git" });
    defer testing.allocator.free(other_git);
    try environment.put("GIT_DIR", other_git);
    try environment.put("GIT_WORK_TREE", other.path);
    try environment.put("GIT_INDEX_FILE", "unused-index");
    try environment.put("HOME", repo.path);
    try environment.put("HTTPS_PROXY", "http://proxy.invalid:8080");
    try environment.put("SSH_AUTH_SOCK", "/nonexistent/fixture-agent");
    const block = try environment.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .{ .block = block } });
    defer threaded.deinit();
    const io = threaded.io();
    const output = gitOutput(io, testing.allocator, repo.path, &.{ "rev-parse", "--show-toplevel" }, null) orelse return error.MissingGitOutput;
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(repo.path, output);

    var ctx = testCtx();
    defer ctx.deinit();
    try ctx.setGitEnvironment(&environment);
    const sanitized = ctx.gitEnvironment().?;
    try testing.expectEqualStrings(repo.path, sanitized.get("HOME").?);
    try testing.expectEqualStrings("http://proxy.invalid:8080", sanitized.get("HTTPS_PROXY").?);
    try testing.expectEqualStrings("/nonexistent/fixture-agent", sanitized.get("SSH_AUTH_SOCK").?);
    for (sanitized.keys()) |key| try testing.expect(!std.mem.startsWith(u8, key, "GIT_"));
    const configured_output = gitOutput(io, testing.allocator, repo.path, &.{ "rev-parse", "--show-toplevel" }, sanitized) orelse return error.MissingGitOutput;
    defer testing.allocator.free(configured_output);
    try testing.expectEqualStrings(repo.path, configured_output);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn check(alloc: std.mem.Allocator, original: *const std.process.Environ.Map) !void {
            var updates: UpdateCtx = .{ .clock_io = testing.io, .gpa = alloc, .sources = &.{}, .bus = null };
            defer updates.deinit();
            try updates.setGitEnvironment(original);
            try updates.setGitEnvironment(original);
            try testing.expectEqualStrings(original.get("HOME").?, updates.gitEnvironment().?.get("HOME").?);
        }
    }.check, .{&environment});
}

test "fuzz Git environment filtering preserves owned ordinary entries" {
    try testing.fuzz({}, struct {
        fn check(_: void, smith: *testing.Smith) !void {
            var bytes: [48]u8 = undefined;
            smith.bytes(&bytes);
            var original = std.process.Environ.Map.init(testing.allocator);
            defer original.deinit();
            try original.put("HOME", &bytes);
            try original.put("GIT_DIR", &bytes);
            var updates = testCtx();
            defer updates.deinit();
            try updates.setGitEnvironment(&original);
            original.clearRetainingCapacity();
            const copy = updates.gitEnvironment().?;
            try testing.expectEqualStrings(&bytes, copy.get("HOME").?);
            try testing.expect(copy.get("GIT_DIR") == null);
        }
    }.check, .{});
}

test "fuzz git command arguments: long read-only lists retain every argument" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var repo = try TestRepo.init();
            defer repo.deinit();
            var args: [32][]const u8 = @splat("--is-inside-work-tree");
            args[0] = "rev-parse";
            const count = 2 + @as(usize, smith.value(u8) % 31);
            try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, args[0..count], null));
            const output = gitOutput(testing.io, testing.allocator, repo.path, args[0..count], null) orelse return error.MissingGitOutput;
            defer testing.allocator.free(output);
            try testing.expectEqual(count - 1, std.mem.count(u8, output, "true"));
        }
    }.run, .{});
}

test "handleRefresh: fetches sources from a local repository" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var repo = try TestRepo.init();
    defer repo.deinit();
    const test_sources = [_]Source{
        .{ .name = "system", .type = .system },
        .{ .name = "moonraker", .type = .git_repo, .owner = "test", .repo_name = "test", .repo_path = repo.path, .branch = "main" },
    };
    var ctx: UpdateCtx = .{ .clock_io = std.testing.io, .gpa = std.heap.smp_allocator, .sources = &test_sources, .bus = null, .io = io };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try handleRefresh(@ptrCast(&ctx), .null, a);
    try testing.expect(v.object.get("version_info") != null);
    try testing.expect(v.object.get("version_info").?.object.get("moonraker") != null);
    try testing.expect(gitCheck(io, testing.allocator, repo.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
}

test "handleStatus: refresh=true fetches before building payload" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var repo = try TestRepo.init();
    defer repo.deinit();
    const test_sources = [_]Source{
        .{ .name = "system", .type = .system },
        .{ .name = "moonraker", .type = .git_repo, .owner = "test", .repo_name = "test", .repo_path = repo.path, .branch = "main" },
    };
    var ctx: UpdateCtx = .{ .clock_io = std.testing.io, .gpa = std.heap.smp_allocator, .sources = &test_sources, .bus = null, .io = io };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try handleStatus(@ptrCast(&ctx), try objParams(a, "{\"refresh\":true}"), a);
    try testing.expect(v.object.get("version_info") != null);
    try testing.expect(v.object.get("version_info").?.object.get("moonraker") != null);
    try testing.expect(gitCheck(io, testing.allocator, repo.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
}

test "refresh refuses busy and printing states and status refresh is throttled" {
    var repo = try TestRepo.init();
    defer repo.deinit();
    const sources = [_]Source{.{ .name = "fixture", .type = .git_repo, .repo_path = repo.path, .branch = "main" }};
    var printing = true;
    var ctx: UpdateCtx = .{
        .clock_io = testing.io,
        .gpa = testing.allocator,
        .sources = &sources,
        .bus = null,
        .io = testing.io,
        .printing_ctx = &printing,
        .printing_check = struct {
            fn check(raw: *anyopaque) bool {
                return @as(*bool, @ptrCast(@alignCast(raw))).*;
            }
        }.check,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const refresh = try objParams(alloc, "{\"refresh\":true}");
    try testing.expectError(error.UpdateBusy, handleRefresh(&ctx, .null, alloc));
    _ = try handleStatus(&ctx, refresh, alloc);
    try testing.expectEqual(null, ctx.last_status_refresh);
    printing = false;
    ctx.busy.store(true, .release);
    try testing.expectError(error.UpdateBusy, handleRefresh(&ctx, .null, alloc));
    _ = try handleStatus(&ctx, refresh, alloc);
    try testing.expectEqual(null, ctx.last_status_refresh);
    ctx.busy.store(false, .release);
    _ = try handleStatus(&ctx, refresh, alloc);
    try testing.expect(ctx.last_status_refresh != null);
    try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "update-ref", "-d", "refs/remotes/origin/main" }, null));
    _ = try handleStatus(&ctx, refresh, alloc);
    try testing.expect(!gitCheck(testing.io, testing.allocator, repo.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
    _ = try handleRefresh(&ctx, .null, alloc);
    try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
}

test "update dispatcher runs commands outside Core and serializes the operation" {
    const Core = @import("../server/core.zig").Core;
    const Runner = struct {
        ctx: *UpdateCtx,
        core: *Core,
        calls: usize = 0,
        fn run(raw: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try testing.expect(self.core.mutex.tryLock());
            self.core.unlock(testing.io);
            try testing.expect(!self.ctx.commands.tryLock());
            try testing.expect(self.ctx.busy.load(.acquire));
            try testing.expectError(error.UpdateBusy, self.ctx.beginMutation());
            self.calls += 1;
        }
    };
    var core: Core = .init();
    var ctx = testCtx();
    var runner: Runner = .{ .ctx = &ctx, .core = &core };
    ctx.shell = Runner.run;
    ctx.shell_ctx = &runner;
    var dispatcher = @import("../jsonrpc.zig").Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    dispatcher.setRuntime(&core, testing.io);
    var registry_instance = Registry.init(testing.allocator, &dispatcher);
    defer registry_instance.deinit();
    try registerUpdateManager(&registry_instance, &ctx);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const reply = try dispatcher.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"machine.update.system\"}", alloc);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, reply, .{});
    try testing.expectEqualStrings("ok", parsed.object.get("result").?.string);
    try testing.expect(runner.calls >= 2);
    try testing.expect(!ctx.busy.load(.acquire));
    try testing.expect(ctx.commands.tryLock());
    ctx.commands.unlock(testing.io);
}

test "full update applies the Git source in a local fixture" {
    const Restart = struct {
        ctx: *UpdateCtx,
        calls: usize = 0,
        fn run(raw: *anyopaque, _: std.mem.Allocator, service: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try testing.expectEqualStrings("klipper", service);
            try testing.expect(self.ctx.commands.tryLock());
            self.ctx.commands.unlock(testing.io);
            try testing.expect(self.ctx.busy.load(.acquire));
            self.calls += 1;
        }
    };
    var repo = try TestRepo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked", .data = "original" });
    try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "add", "tracked" }, null));
    try testing.expect(gitCheck(testing.io, testing.allocator, repo.path, &.{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "tracked" }, null));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "tracked", .data = "modified" });
    const sources = [_]Source{.{ .name = "fixture", .type = .git_repo, .repo_path = repo.path, .branch = "main", .managed_services = &.{"klipper"} }};
    var ctx: UpdateCtx = .{ .clock_io = testing.io, .gpa = testing.allocator, .sources = &sources, .bus = null, .io = testing.io };
    var restarted: Restart = .{ .ctx = &ctx };
    ctx.restart_service = Restart.run;
    ctx.service_ctx = &restarted;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("ok", (try handleFull(&ctx, .null, arena_state.allocator())).string);
    var bytes: [32]u8 = undefined;
    const data = try repo.tmp.dir.readFile(testing.io, "tracked", &bytes);
    try testing.expectEqualStrings("original", data);
    try testing.expectEqual(@as(usize, 1), restarted.calls);
    _ = try handleFull(&ctx, .null, arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), restarted.calls);
}

test "source services parse explicit choices and disabled defaults" {
    var cfg = config_helper.ConfigParser.init(testing.allocator);
    defer cfg.deinit();
    try cfg.parseString(
        \\[update_manager moonraker-2]
        \\type: git_repo
        \\[update_manager disabled]
        \\type: zip
        \\is_system_service: false
        \\[update_manager client]
        \\type: zip
        \\managed_services: klipper, moonraker
        \\[update_manager web]
        \\type: web
        \\managed_services: moonraker
    , "<test>");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sources = try sourcesFromConfig(arena_state.allocator(), &cfg);
    var ctx: UpdateCtx = .{ .clock_io = testing.io, .gpa = testing.allocator, .sources = sources, .bus = null };
    try testing.expectEqualStrings("moonraker-2", ctx.findSource("moonraker-2").?.managed_services[0]);
    try testing.expectEqual(@as(usize, 0), ctx.findSource("disabled").?.managed_services.len);
    try testing.expectEqual(@as(usize, 2), ctx.findSource("client").?.managed_services.len);
    try testing.expectEqual(@as(usize, 0), ctx.findSource("web").?.managed_services.len);
    try cfg.parseString("[update_manager invalid]\ntype: zip\nmanaged_services: shutdown\n", "<invalid>");
    try testing.expectError(error.InvalidManagedService, sourcesFromConfig(arena_state.allocator(), &cfg));
}

test "fuzz service restart callbacks propagate failures without a command lock" {
    try testing.fuzz({}, struct {
        fn check(_: void, smith: *testing.Smith) !void {
            const Runner = struct {
                fail: bool,
                ctx: *UpdateCtx,
                fn run(raw: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    try testing.expect(self.ctx.commands.tryLock());
                    self.ctx.commands.unlock(testing.io);
                    if (self.fail) return error.ServiceFailed;
                }
            };
            var ctx = testCtx();
            var runner: Runner = .{ .fail = smith.value(bool), .ctx = &ctx };
            ctx.restart_service = Runner.run;
            ctx.service_ctx = &runner;
            const source: Source = .{ .name = "fixture", .type = .git_repo, .managed_services = &.{"klipper"} };
            if (runner.fail) {
                try testing.expectError(error.ServiceFailed, restartServices(&ctx, testing.allocator, source));
            } else try restartServices(&ctx, testing.allocator, source);
        }
    }.check, .{});
}

test "fuzz update operation admission retains the current busy owner" {
    try testing.fuzz({}, struct {
        fn check(_: void, smith: *testing.Smith) !void {
            const already_busy = smith.value(bool);
            var ctx = testCtx();
            ctx.busy.store(already_busy, .release);
            if (already_busy) {
                try testing.expectError(error.UpdateBusy, ctx.beginMutation());
            } else {
                try ctx.beginMutation();
            }
            try testing.expect(ctx.busy.load(.acquire));
        }
    }.check, .{});
}

// ---- fuzz ----

test "fuzz_status: arbitrary params never crash handleStatus, always payload" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx: UpdateCtx = .{ .clock_io = std.testing.io, .gpa = a, .sources = &default_sources, .bus = null, .io = null };
            const refresh = (buf[0] & 1) == 0;
            const params: std.json.Value = if (refresh) .{ .bool = true } else .null;
            const v = try handleStatus(@ptrCast(&ctx), params, a);
            try std.testing.expect(v.object.get("version_info") != null);
            try std.testing.expect(v.object.get("busy") != null);
        }
    }.run, .{});
}

test "fuzz_handlers: arbitrary name params never crash update/recover/rollback" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [24]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx: UpdateCtx = .{ .clock_io = std.testing.io, .gpa = a, .sources = &default_sources, .bus = null, .io = null };

            // Build a random-ish name from a safe alphabet.
            const alphabet = "abcklmnopr_";
            var name_buf: [24]u8 = undefined;
            var n: usize = 0;
            for (buf) |b| {
                name_buf[n] = alphabet[b % alphabet.len];
                n += 1;
            }
            const params = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\"}}", .{name_buf[0..n]});
            const pv = try objParams(a, params);

            // None of these may panic; they return either ok or a mapped error.
            _ = handleUpgrade(@ptrCast(&ctx), pv, a) catch {};
            _ = handleUpdateClient(@ptrCast(&ctx), pv, a) catch {};
            _ = handleRecover(@ptrCast(&ctx), pv, a) catch {};
            _ = handleRollback(@ptrCast(&ctx), pv, a) catch {};
            _ = handleRefresh(@ptrCast(&ctx), pv, a) catch {};
        }
    }.run, .{});
}

test "fuzz_handlers_update_full_system: never crash on update_moonraker/klipper/system/full" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [24]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx: UpdateCtx = .{ .clock_io = std.testing.io, .gpa = a, .sources = &default_sources, .bus = null, .io = null };

            _ = handleUpdateMoonraker(@ptrCast(&ctx), .null, a) catch {};
            _ = handleUpdateKlipper(@ptrCast(&ctx), .null, a) catch {};
            _ = handleUpdateSystem(@ptrCast(&ctx), .null, a) catch {};
            _ = handleFull(@ptrCast(&ctx), .null, a) catch {};
        }
    }.run, .{});
}

test "fuzz_buildGitStatus: arbitrary source fields never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const alphabet = "abcdefghijklmnopqrstuvwxyz./_-";
            var name: [16]u8 = undefined;
            var owner: [16]u8 = undefined;
            var repo: [16]u8 = undefined;
            var rpath: [32]u8 = undefined;
            for (&name, 0..) |*c, i| c.* = alphabet[buf[i % 32] % alphabet.len];
            for (&owner, 0..) |*c, i| c.* = alphabet[buf[16 + i % 16] % alphabet.len];
            for (&repo, 0..) |*c, i| c.* = alphabet[buf[24 + i % 16] % alphabet.len];
            for (&rpath, 0..) |*c, i| c.* = alphabet[buf[32 + i % 32] % alphabet.len];

            const rpath_len = @as(usize, buf[48]) % rpath.len;
            const src: Source = .{
                .name = &name,
                .type = .git_repo,
                .owner = &owner,
                .repo_name = &repo,
                .branch = "main",
                .repo_path = rpath[0..rpath_len],
            };
            // io is always null → never runs real git; must not crash.
            _ = try buildGitStatus(null, a, src, null);
        }
    }.run, .{});
}

test "gitOutput: returns null for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = gitOutput(io, testing.allocator, "", &.{}, null);
    try testing.expect(result == null);
}

test "gitOutput: returns null for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = gitOutput(io, testing.allocator, "/nonexistent/path/repo", &.{ "rev-parse", "HEAD" }, null);
    try testing.expect(result == null);
}

test "gitCheck: returns false for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(false, gitCheck(io, testing.allocator, "", &.{ "rev-parse", "HEAD" }, null));
}

test "gitCheck: returns false for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(false, gitCheck(io, testing.allocator, "/nonexistent/path/repo", &.{ "rev-parse", "HEAD" }, null));
}

test "git helpers pass a repo path with shell metacharacters as one argument" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "re po 'q\"$(x);";
    try tmp.dir.createDirPath(testing.io, name);
    const path = try tmp.dir.realPathFileAlloc(testing.io, name, testing.allocator);
    defer testing.allocator.free(path);
    try testing.expect(gitCheck(testing.io, testing.allocator, path, &.{"init"}, null));
    const inside = gitOutput(testing.io, testing.allocator, path, &.{ "rev-parse", "--is-inside-work-tree" }, null) orelse return error.MissingGitOutput;
    defer testing.allocator.free(inside);
    try testing.expectEqualStrings("true", inside);
    // A NUL byte cannot reach argv: the spawn fails instead.
    try testing.expect(gitOutput(testing.io, testing.allocator, "/p\x00ath/null", &.{"status"}, null) == null);
    try testing.expect(!gitCheck(testing.io, testing.allocator, "/p\x00ath/null", &.{"status"}, null));
}

test "update failures send Moonraker's completion lines" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Rec = struct {
        frames: std.ArrayList([]u8) = .empty,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.frames.append(testing.allocator, try testing.allocator.dupe(u8, bytes));
        }
        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| testing.allocator.free(f);
            self.frames.deinit(testing.allocator);
        }
        /// `params[0]` of frame `i` from the end, as (message, complete).
        fn line(self: *@This(), a: std.mem.Allocator, from_end: usize) !struct { []const u8, bool } {
            const frame = self.frames.items[self.frames.items.len - 1 - from_end];
            const v = try std.json.parseFromSliceLeaky(std.json.Value, a, frame, .{});
            const n = v.object.get("params").?.array.items[0].object;
            return .{ n.get("message").?.string, n.get("complete").?.bool };
        }
        fn failShell(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {
            return error.ShellFailed;
        }
    };
    var rec: Rec = .{};
    defer rec.deinit();
    var core: @import("../server/core.zig").Core = .init();
    var conns = @import("../server/connections.zig").Connections.init(testing.allocator, &core);
    defer conns.deinit(io);
    conns.attachWriter(io, try conns.add(io, false), &rec, Rec.write);
    var bus = NotifyBus.init(&core, &conns);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var repo = try TestRepo.init();
    defer repo.deinit();
    var sources = [_]Source{
        .{ .name = "system", .type = .system },
        // origin/missing does not exist, so the reset after the fetch fails.
        .{ .name = "moonraker", .type = .git_repo, .repo_path = repo.path, .branch = "missing", .rollback_ref = "missing" },
        .{ .name = "client", .type = .zip, .repo_path = repo.path },
    };
    var dummy: u8 = 0;
    var ctx: UpdateCtx = .{ .clock_io = io, .gpa = testing.allocator, .sources = &sources, .bus = &bus, .io = io, .shell = Rec.failShell, .shell_ctx = &dummy };

    try testing.expectError(error.ShellFailed, handleUpdateSystem(&ctx, .null, a));
    var l = try rec.line(a, 0);
    try testing.expectEqualStrings("Error updating system: ShellFailed", l[0]);
    try testing.expect(l[1]);

    try testing.expectError(error.GitFailed, handleUpdateMoonraker(&ctx, .null, a));
    l = try rec.line(a, 0);
    try testing.expectEqualStrings("Error updating moonraker: GitFailed", l[0]);
    try testing.expect(l[1]);
    try testing.expect(!ctx.busy.load(.monotonic));

    try testing.expectError(error.GitFailed, handleRollback(&ctx, try objParams(a, "{\"name\":\"moonraker\"}"), a));
    l = try rec.line(a, 1);
    try testing.expectEqualStrings("Error Rolling Back moonraker", l[0]);
    try testing.expect(!l[1]);
    l = try rec.line(a, 0);
    try testing.expectEqualStrings("GitFailed", l[0]);
    try testing.expect(l[1]);

    try testing.expectError(error.GitDirectory, handleRollback(&ctx, try objParams(a, "{\"name\":\"client\"}"), a));
    l = try rec.line(a, 1);
    try testing.expectEqualStrings("Error Rolling Back client", l[0]);
    try testing.expect(!l[1]);
    l = try rec.line(a, 0);
    try testing.expectEqualStrings("GitDirectory", l[0]);
    try testing.expect(l[1]);

    sources[1].rollback_ref = "HEAD";
    sources[1].managed_services = &.{"klipper"};
    ctx.restart_service = Rec.failShell;
    ctx.service_ctx = &dummy;
    try testing.expectError(error.ShellFailed, handleRollback(&ctx, try objParams(a, "{\"name\":\"moonraker\"}"), a));
    l = try rec.line(a, 0);
    try testing.expectEqualStrings("ShellFailed", l[0]);
    try testing.expect(l[1]);
    try testing.expect(!ctx.busy.load(.acquire));
}

test "refresh with a name fetches only that source" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var first = try TestRepo.init();
    defer first.deinit();
    var second = try TestRepo.init();
    defer second.deinit();
    const sources = [_]Source{
        .{ .name = "first", .type = .git_repo, .repo_path = first.path, .branch = "main" },
        .{ .name = "second", .type = .git_repo, .repo_path = second.path, .branch = "main" },
    };
    var ctx: UpdateCtx = .{ .clock_io = io, .gpa = testing.allocator, .sources = &sources, .bus = null, .io = io };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try handleRefresh(&ctx, try objParams(a, "{\"name\":\"second\"}"), a);
    try testing.expect(gitCheck(io, testing.allocator, second.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
    try testing.expect(!gitCheck(io, testing.allocator, first.path, &.{ "show-ref", "--verify", "refs/remotes/origin/main" }, null));
}

test "is_dirty: oversized status output still reads as dirty" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var repo = try TestRepo.init();
    defer repo.deinit();
    // Each untracked file is one porcelain line; enough of them pass the cap.
    var name_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i * 40 <= git_output_limit) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "untracked-file-with-a-long-name-{d:0>6}", .{i});
        try repo.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src: Source = .{ .name = "moonraker", .type = .git_repo, .repo_path = repo.path, .branch = "main" };
    const status = try buildGitStatus(io, arena.allocator(), src, null);
    try testing.expect(status.object.get("is_dirty").?.bool);
}

test "gitReset: returns false for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(!gitReset(io, testing.allocator, "", "origin/master", null));
}

test "gitReset: returns false for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(!gitReset(io, testing.allocator, "/nonexistent/repo", "origin/master", null));
}

test "fuzz_gitReset: arbitrary ref strings never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @min(buf.len, @as(usize, @intCast(smith.valueRangeAtMostWithHash(u8, 0, 64, 1))));
            const ref = buf[0..n];

            _ = gitReset(io, std.heap.smp_allocator, "/nonexistent/repo", ref, null);
        }
    }.run, .{});
}

// --- Fuzz tests for internal builders ---

test "fuzz buildSystemStatus: never panics, returns expected shape" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const alphabet = "abcdefghijklmnopqrstuvwxyz_-";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const s: Source = .{ .name = name_buf[0..@max(1, buf[0] % 8)], .type = .system };

            const result = try buildSystemStatus(a, s);
            try testing.expectEqualStrings(s.name, result.object.get("name").?.string);
            try testing.expect(result.object.get("package_count") != null);
            try testing.expect(result.object.get("package_list") != null);
        }
    }.run, .{});
}

test "fuzz buildWebStatus: never panics, returns expected shape" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [32]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const alphabet = "abcdefghijklmnopqrstuvwxyz._-";
            var name_buf: [12]u8 = undefined;
            for (buf[0..@min(8, buf.len)], 0..) |b, i| {
                name_buf[i] = alphabet[b % alphabet.len];
            }
            const t: SourceType = if (buf[0] % 2 == 0) .web else .zip;
            const s: Source = .{
                .name = name_buf[0..@max(1, buf[0] % 8)],
                .type = t,
                .owner = "owner",
                .repo_name = "repo",
            };

            const result = try buildWebStatus(a, s);
            try testing.expect(result.object.get("name") != null);
            try testing.expect(result.object.get("version") != null);
            try testing.expect(result.object.get("remote_version") != null);
            try testing.expect(result.object.get("owner") != null);
            try testing.expect(result.object.get("repo_name") != null);
        }
    }.run, .{});
}

test "fuzz buildSourceStatus: dispatches correctly by source type" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const source_type_val = smith.valueRangeLessThanWithHash(i64, 0, 4, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const st: SourceType = @fromBackingInt(@intCast(@as(u2, @intCast(source_type_val))));
            const s: Source = switch (st) {
                .git_repo => .{ .name = "moonraker", .type = .git_repo, .owner = "Arksine", .repo_name = "moonraker" },
                .system => .{ .name = "system", .type = .system },
                .web => .{ .name = "client", .type = .web, .owner = "owner", .repo_name = "repo" },
                .zip => .{ .name = "client", .type = .zip, .owner = "owner", .repo_name = "repo" },
            };

            // io is null → git just returns "?" defaults safely
            const result = try buildSourceStatus(null, a, s, null);
            try testing.expect(result.object.get("name") != null);
        }
    }.run, .{});
}

test "fuzz buildStatusPayload: never panics with any source set" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            // Use a varying subset of default sources
            const all = default_sources;
            const start: usize = buf[0] % all.len;
            const end: usize = @min(all.len, start + @as(usize, buf[1]) % 3 + 1);
            const sources: []const Source = all[start..end];

            var ctx = UpdateCtx{ .clock_io = std.testing.io, .gpa = a, .sources = sources, .bus = null, .io = null, .busy = .init(buf[2] % 2 == 0) };
            const payload = try buildStatusPayload(&ctx, a);

            try testing.expect(payload.object.get("version_info") != null);
            try testing.expect(payload.object.get("busy") != null);
            try testing.expect(payload.object.get("github_rate_limit") != null);
        }
    }.run, .{});
}

test "fuzz buildResponseNotification: never panics, correct shape" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const apps = [_][]const u8{ "moonraker", "klipper", "system", "client" };
            const msgs = [_][]const u8{ "Updating...", "Update complete", "Error" };
            const app = apps[buf[0] % apps.len];
            const msg = msgs[buf[1] % msgs.len];
            const proc_id = @as(i64, @intCast(buf[2]));
            const complete = buf[3] % 2 == 0;

            const n = try buildResponseNotification(a, app, proc_id, msg, complete);
            try testing.expectEqualStrings(app, n.object.get("application").?.string);
            try testing.expectEqualStrings(msg, n.object.get("message").?.string);
            try testing.expectEqual(proc_id, n.object.get("proc_id").?.integer);
            try testing.expectEqual(complete, n.object.get("complete").?.bool);
        }
    }.run, .{});
}

test "fuzz nextProcId: monotonic, never wraps" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            const n = smith.valueRangeLessThanWithHash(i64, 1, 100, 0);
            var last: i64 = nextProcId() -| 1; // ~monotonic baseline
            for (0..@as(usize, @intCast(n))) |_| {
                const curr = nextProcId();
                try testing.expect(curr > last);
                last = curr;
            }
        }
    }.run, .{});
}

test "tickAutoRefresh: disabled and out of window do not refresh" {
    var ctx = testCtx();
    ctx.io = null;
    try testing.expect(!ctx.tickAutoRefresh(2));

    ctx.auto_refresh = true;
    try testing.expect(ctx.tickAutoRefresh(23));
    try testing.expect(ctx.initial_refresh_done);

    ctx.last_auto_refresh_s = clock.wallSecondsInt(ctx.clock_io);
    try testing.expect(!ctx.tickAutoRefresh(2));

    ctx.last_auto_refresh_s = 0;
    try testing.expect(ctx.tickAutoRefresh(2));

    ctx.last_auto_refresh_s = 0;
    var dummy: u8 = 0;
    ctx.printing_check = testPrintingCheck;
    ctx.printing_ctx = &dummy;
    test_printing_flag = true;
    defer test_printing_flag = false;
    try testing.expect(!ctx.tickAutoRefresh(2));
    try testing.expect(!UpdateCtx.inRefreshWindow(0, 5, 12));
    try testing.expect(UpdateCtx.inRefreshWindow(0, 5, 0));
    try testing.expect(UpdateCtx.inRefreshWindow(22, 5, 23));
}

test "refresh hours follow local offsets and daylight saving without global TZ mutation" {
    const Case = struct { zone: []const u8, timestamp: []const u8, hour: []const u8 };
    for ([_]Case{
        .{ .zone = "UTC0", .timestamp = "0", .hour = "0\n" },
        .{ .zone = "UTC0", .timestamp = "-1", .hour = "23\n" },
        .{ .zone = "EST5EDT,M3.2.0/2,M11.1.0/2", .timestamp = "1705320000", .hour = "7\n" },
        .{ .zone = "EST5EDT,M3.2.0/2,M11.1.0/2", .timestamp = "1721044800", .hour = "8\n" },
        .{ .zone = "EST5EDT,M3.2.0/2,M11.1.0/2", .timestamp = "2541499200", .hour = "8\n" },
        .{ .zone = "NST3:30", .timestamp = "0", .hour = "20\n" },
    }) |case| {
        var environment = std.process.Environ.Map.init(testing.allocator);
        defer environment.deinit();
        try environment.put("TZ", case.zone);
        const result = try process.run(testing.allocator, testing.io, .{
            .argv = &.{ @import("build_options").local_time_probe, case.timestamp },
            .environ_map = &environment,
            .stdout_limit = .limited(32),
            .stderr_limit = .limited(256),
            .timeout = .{ .deadline = .fromNow(testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) },
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try testing.expectEqualStrings(case.hour, result.stdout);
    }
    const hour = try localHour(clock.wallSecondsInt(testing.io));
    try testing.expect(hour >= 0 and hour < 24);
}

test "fuzz local refresh hours stay within a day" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const seconds = smith.valueRangeAtMost(i64, -2208988800, 4102444800);
            const hour = try localHour(seconds);
            try testing.expect(hour >= 0 and hour < 24);
        }
    }.run, .{});
}

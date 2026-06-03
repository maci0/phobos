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
//! REAL UPDATE OPERATIONS ARE STUBBED. phobos must never run git/pip/apt on the
//! development machine, so every "do an update" handler validates inputs, emits
//! faithfully-shaped `notify_update_response` progress events, and returns
//! Moonraker's bare "ok" ack. No repository is fetched, no package is installed.
//! Each stub is noted at its handler.
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
//! notification shape). Both go through `bus.emitLocked` because handlers run
//! inside `Core.run` which already holds the Core lock (calling `emit` would
//! deadlock the non-reentrant mutex). io is wired after the event loop starts
//! via `setIo`; emission is a no-op until then (pure unit tests).

const std = @import("std");
const registry = @import("../server/registry.zig");
const notify = @import("../server/notify.zig");
const NotifyBus = @import("../server/notify.zig").NotifyBus;

const Registry = registry.Registry;

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
    /// Whether this source is a git repository eligible for recover/rollback.
    pub fn isGit(self: Source) bool {
        return self.type == .git_repo;
    }
};

/// The default source set Moonraker creates: system (package), moonraker and
/// klipper (git repos). Mirrors UpdateManager.__init__.
pub const default_sources = [_]Source{
    .{ .name = "system", .type = .system, .owner = "", .repo_name = "" },
    .{ .name = "moonraker", .type = .git_repo, .owner = "Arksine", .repo_name = "moonraker", .branch = "master" },
    .{ .name = "klipper", .type = .git_repo, .owner = "Klipper3d", .repo_name = "klipper", .branch = "master" },
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const UpdateCtx = struct {
    gpa: std.mem.Allocator,
    /// Configured sources. Borrowed; owned by the App (or a test).
    sources: []const Source,
    bus: ?*NotifyBus,
    /// Live io for notification emission. Set after the event loop starts (via
    /// setIo). Emission is a no-op while absent.
    io: ?std.Io = null,
    /// Tracks whether an update is currently in progress (CommandHelper.busy).
    /// phobos updates are stubbed and synchronous, so this is only ever briefly
    /// true within a handler; it is reported in the status `busy` field.
    busy: bool = false,

    pub fn setIo(self: *UpdateCtx, io: std.Io) void {
        self.io = io;
    }

    pub fn findSource(self: *const UpdateCtx, name: []const u8) ?Source {
        for (self.sources) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

fn getOptStr(params: std.json.Value, field: []const u8) ?[]const u8 {
    switch (params) {
        .object => |obj| {
            const v = obj.get(field) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getStr(params: std.json.Value, field: []const u8) error{InvalidParams}![]const u8 {
    return getOptStr(params, field) orelse error.InvalidParams;
}

fn getBool(params: std.json.Value, field: []const u8, default_val: bool) bool {
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

// ---------------------------------------------------------------------------
// Git child-process helper
// ---------------------------------------------------------------------------

/// Run `git -C <repo_path> <args...>` and return stdout (trimmed, caller owns).
/// Returns null on any error (spawn failure, non-zero exit, empty stdout).
fn gitOutput(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8) ?[]const u8 {
    if (repo_path.len == 0) return null;

    var arg_buf: [8][]const u8 = undefined;
    var n: usize = 0;
    arg_buf[n] = "git"; n += 1;
    arg_buf[n] = "-C"; n += 1;
    arg_buf[n] = repo_path; n += 1;
    for (argv) |a| { arg_buf[n] = a; n += 1; }

    const result = std.process.run(alloc, io, .{
        .argv = arg_buf[0..n],
    }) catch return null;
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return null;
    }
    if (result.stdout.len == 0) {
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
fn gitCheck(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8) bool {
    if (repo_path.len == 0) return false;

    var arg_buf: [8][]const u8 = undefined;
    var n: usize = 0;
    arg_buf[n] = "git"; n += 1;
    arg_buf[n] = "-C"; n += 1;
    arg_buf[n] = repo_path; n += 1;
    for (argv) |a| { arg_buf[n] = a; n += 1; }

    const result = std.process.run(alloc, io, .{
        .argv = arg_buf[0..n],
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

/// Run `git fetch origin --prune` in a repo to update remote tracking refs.
/// Safe: fetch never modifies the working tree or local branches. Returns true
/// on success, false when a repo_path is empty, io is unavailable, or fetch
/// fails (non-zero exit, spawn failure). No-op without io (unit tests).
fn gitFetch(io: ?std.Io, alloc: std.mem.Allocator, repo_path: []const u8) bool {
    if (repo_path.len == 0) return false;
    const live_io = io orelse return false;
    return gitCheck(live_io, alloc, repo_path, &.{ "fetch", "origin", "--prune" });
}

/// Run `git reset --hard <ref>` in a repo. Destructive: overwrites local
/// changes. Returns true on success, false on failure.
fn gitReset(io: std.Io, alloc: std.mem.Allocator, repo_path: []const u8, ref: []const u8) bool {
    if (repo_path.len == 0) return false;
    return gitCheck(io, alloc, repo_path, &.{ "reset", "--hard", ref });
}

// ---------------------------------------------------------------------------
// Per-source status shape (get_update_status)
// ---------------------------------------------------------------------------

/// Build the git_repo status shape: AppDeploy.get_update_status merged with
/// GitDeploy.repo.get_repo_status. Every key Moonraker emits is present. When
/// io is available and src.repo_path is non-empty, runs real git commands to
/// populate version, hash, branch, and dirty/detached state. Falls back to
/// honest "?" defaults when the repo is absent (unit tests, dev workstation).
fn buildGitStatus(io: ?std.Io, alloc: std.mem.Allocator, src: Source) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;

    // --- AppDeploy.get_update_status base keys ---
    try obj.put(alloc, "channel", .{ .string = "dev" });
    try obj.put(alloc, "debug_enabled", .{ .bool = false });
    try obj.put(alloc, "channel_invalid", .{ .bool = false });
    try obj.put(alloc, "is_valid", .{ .bool = true });
    try obj.put(alloc, "configured_type", .{ .string = "git_repo" });
    try obj.put(alloc, "info_tags", .{ .array = .init(alloc) });

    // --- GitDeploy.get_repo_status keys ---
    try obj.put(alloc, "detected_type", .{ .string = "git_repo" });
    try obj.put(alloc, "remote_alias", .{ .string = "origin" });

    const remote_url = try std.fmt.allocPrint(alloc, "https://github.com/{s}/{s}.git", .{ src.owner, src.repo_name });
    try obj.put(alloc, "remote_url", .{ .string = remote_url });
    try obj.put(alloc, "recovery_url", .{ .string = remote_url });
    try obj.put(alloc, "owner", .{ .string = src.owner });
    try obj.put(alloc, "repo_name", .{ .string = src.repo_name });

    var branch: []const u8 = src.branch;
    var version: []const u8 = "?";
    var remote_version: []const u8 = "?";
    var current_hash: []const u8 = "?";
    var remote_hash: []const u8 = "?";
    var is_dirty: bool = false;
    var detached: bool = false;
    var commits_behind_count: i64 = 0;
    var commits_behind: std.json.Array = .init(alloc);

    if (io) |live_io| {
        if (src.repo_path.len > 0) {
            // branch: git rev-parse --abbrev-ref HEAD
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", "--abbrev-ref", "HEAD" })) |b| {
                if (!std.mem.eql(u8, b, "HEAD")) branch = b;
            }

            // version: git describe --tags --always --long --dirty
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "describe", "--tags", "--always", "--long", "--dirty" })) |v| {
                version = v;
            }

            // full_version_string: git describe --tags --always --long --dirty
            // (same as version; Moonraker's get_version_from_git returns this)
            try obj.put(alloc, "full_version_string", .{ .string = try alloc.dupe(u8, version) });

            // remote_version: git describe --tags origin/<branch> --always
            const remote_ref = try std.fmt.allocPrint(alloc, "origin/{s}", .{branch});
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "describe", "--tags", remote_ref, "--always" })) |rv| {
                remote_version = rv;
            }

            // current_hash: git rev-parse HEAD
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", "HEAD" })) |ch| {
                current_hash = ch;
            }

            // remote_hash: git rev-parse origin/<branch>
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "rev-parse", remote_ref })) |rh| {
                remote_hash = rh;
            }

            // is_dirty: git status --porcelain has any output
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "status", "--porcelain" })) |porcelain| {
                is_dirty = porcelain.len > 0;
            }

            // detached: git symbolic-ref -q HEAD fails
            detached = !gitCheck(live_io, alloc, src.repo_path, &.{ "symbolic-ref", "-q", "HEAD" });

            // commits_behind: git log HEAD..origin/<branch> with Moonraker's
            // format (unit separator \x1D between fields, record separator
            // \x1E between commits). Max 100 entries to match Moonraker.
            const behind_range = try std.fmt.allocPrint(alloc, "HEAD..{s}", .{remote_ref});
            const log_fmt_arg = try std.fmt.allocPrint(alloc, "--format=sha:%H\x1Dauthor:%an\x1Ddate:%ct\x1Dsubject:%s\x1Dmessage:%b\x1E", .{});
            if (gitOutput(live_io, alloc, src.repo_path, &.{ "log", behind_range, log_fmt_arg, "--max-count=100" })) |behind| {
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
    try obj.put(alloc, "channel", .{ .string = "stable" });
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

fn buildSourceStatus(io: ?std.Io, alloc: std.mem.Allocator, src: Source) !std.json.Value {
    return switch (src.type) {
        .git_repo => buildGitStatus(io, alloc, src),
        .system => buildSystemStatus(alloc, src),
        .web, .zip => buildWebStatus(alloc, src),
    };
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
    var version_info: std.json.ObjectMap = .empty;
    for (ctx.sources) |src| {
        try version_info.put(alloc, src.name, try buildSourceStatus(ctx.io, alloc, src));
    }

    var out: std.json.ObjectMap = .empty;
    // get_rate_limit_stats() — null on a process that has made no GitHub calls.
    try out.put(alloc, "github_rate_limit", .null);
    try out.put(alloc, "github_requests_remaining", .null);
    try out.put(alloc, "github_limit_reset_time", .null);
    try out.put(alloc, "version_info", .{ .object = version_info });
    try out.put(alloc, "busy", .{ .bool = ctx.busy });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------
// Notification emission
// ---------------------------------------------------------------------------

/// Emit `notify_update_refreshed` with `[status_payload]` params. No-op when the
/// bus or io is unavailable (unit tests). Uses emitLocked (handlers run under
/// the held Core lock).
fn emitRefreshed(ctx: *UpdateCtx, alloc: std.mem.Allocator, payload: std.json.Value) void {
    const bus = ctx.bus orelse return;
    const io = ctx.io orelse return;
    var arr: std.json.Array = .init(alloc);
    arr.append(payload) catch return;
    bus.emitLocked(io, notify.names.update_refreshed, .{ .array = arr }) catch {};
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
    bus.emitLocked(io, notify.names.update_response, .{ .array = arr }) catch {};
}

/// Monotonic proc-id source (stands in for Moonraker's `id(web_request)`).
var proc_counter: std.atomic.Value(i64) = .init(1);
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
    const refresh = getBool(params, "refresh", false);
    if (refresh) {
        for (ctx.sources) |src| {
            if (src.type == .git_repo and src.repo_path.len > 0) {
                _ = gitFetch(ctx.io, alloc, src.repo_path);
            }
        }
    }
    const payload = try buildStatusPayload(ctx, alloc);
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
    if (getOptStr(params, "name")) |name| {
        if (ctx.findSource(name) == null) return error.InvalidParams;
    }
    // Run git fetch for git_repo sources so the status reflects live remotes.
    for (ctx.sources) |src| {
        if (src.type == .git_repo and src.repo_path.len > 0) {
            _ = gitFetch(ctx.io, alloc, src.repo_path);
        }
    }
    const payload = try buildStatusPayload(ctx, alloc);
    emitRefreshed(ctx, alloc, payload);
    return payload;
}

// ---------------------------------------------------------------------------
// Update handlers
// ---------------------------------------------------------------------------

/// Run a single-target update for `app`. For git_repo sources with a configured
/// repo_path, runs `git fetch origin --prune` + `git reset --hard origin/<branch>`.
/// For non-git sources (system, web, zip), emits notifications but performs no
/// real installation (apt/pip are not invoked — phobos does not touch the host
/// package manager).
fn runUpdate(ctx: *UpdateCtx, alloc: std.mem.Allocator, app: []const u8) anyerror!std.json.Value {
    const src = ctx.findSource(app) orelse return error.NotFound;
    const proc_id = nextProcId();
    ctx.busy = true;
    defer ctx.busy = false;

    const start_msg = try std.fmt.allocPrint(alloc, "Updating {s}...", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, start_msg, false));

    if (src.type == .git_repo and src.repo_path.len > 0) {
        if (ctx.io) |io| {
            // Fetch latest remotes, then hard-reset to origin/<branch>.
            _ = gitFetch(ctx.io, alloc, src.repo_path);
            const ref = try std.fmt.allocPrint(alloc, "origin/{s}", .{src.branch});
            defer alloc.free(ref);
            _ = gitReset(io, alloc, src.repo_path, ref);
        }
    }

    const done_msg = try std.fmt.allocPrint(alloc, "{s} update finished", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, done_msg, true));
    return .{ .string = "ok" };
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

/// POST /machine/update/system → "ok". Emits notification but performs no
/// real package-manager operation (phobos does not touch apt/pip).
pub fn handleUpdateSystem(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runUpdate(ctx, alloc, "system");
}

/// POST /machine/update/client?name=<name> → "ok". Without a `name` param
/// Moonraker treats it as a full update; phobos does likewise.
pub fn handleUpdateClient(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const name = getOptStr(params, "name") orelse return runFullUpdate(ctx, alloc);
    return runUpdate(ctx, alloc, name);
}

/// POST /machine/update/upgrade?name=<name> → "ok". Like `client`, a
/// missing `name` falls back to a full update (matches `_handle_update_request`
/// where app in ("upgrade","client") routes to full when name is None).
pub fn handleUpgrade(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const name = getOptStr(params, "name") orelse return runFullUpdate(ctx, alloc);
    return runUpdate(ctx, alloc, name);
}

/// Run a stubbed full update across every source, emitting the Moonraker
/// progress sequence ("Preparing full software update..." → per-source →
/// "Full Update Complete"). STUB: does not run real updates; phobos never
/// invokes apt/pip.
fn runFullUpdate(ctx: *UpdateCtx, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const proc_id = nextProcId();
    ctx.busy = true;
    defer ctx.busy = false;

    emitResponse(ctx, alloc, try buildResponseNotification(alloc, "full", proc_id, "Preparing full software update...", false));
    // STUB: phobos performs no real updates. We still walk the sources so the
    // notification sequence matches Moonraker (system, then clients, then
    // klipper/moonraker).
    for (ctx.sources) |src| {
        const msg = try std.fmt.allocPrint(alloc, "Updating {s}...", .{src.name});
        emitResponse(ctx, alloc, try buildResponseNotification(alloc, "full", proc_id, msg, false));
    }
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, "full", proc_id, "Full Update Complete", true));
    return .{ .string = "ok" };
}

/// POST /machine/update/full → "ok". STUB.
pub fn handleFull(ctx_ptr: *anyopaque, _: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    return runFullUpdate(ctx, alloc);
}

// ---------------------------------------------------------------------------
// POST /machine/update/recover → machine.update.recover
// ---------------------------------------------------------------------------

/// Recover a corrupted git repo. STUB: validates `name` refers to a git source,
/// emits the recovery `notify_update_response` pair, returns "ok". A real
/// implementation re-clones or `git reset`s the repo. Mirrors
/// `_handle_repo_recovery`.
pub fn handleRecover(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const app = try getStr(params, "name");
    _ = getBool(params, "hard", false); // accepted, unused (stub)
    _ = getBool(params, "update_deps", false); // accepted, unused (stub)
    const src = ctx.findSource(app) orelse return error.NotFound;
    if (!src.isGit()) return error.InvalidParams; // "Updater <x> is not a Git Repo Type"

    const proc_id = nextProcId();
    ctx.busy = true;
    defer ctx.busy = false;

    const msg = try std.fmt.allocPrint(alloc, "Recovering {s}...", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, msg, false));
    // STUB: no real git recovery performed.
    const done = try std.fmt.allocPrint(alloc, "{s} recovery finished", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, done, true));
    return .{ .string = "ok" };
}

// ---------------------------------------------------------------------------
// POST /machine/update/rollback → machine.update.rollback
// ---------------------------------------------------------------------------

/// Roll a source back to its previous version. STUB: validates `name`, emits the
/// rollback `notify_update_response` pair, returns "ok". Mirrors
/// `_handle_rollback`.
pub fn handleRollback(ctx_ptr: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const ctx: *UpdateCtx = @ptrCast(@alignCast(ctx_ptr));
    const app = try getStr(params, "name");
    const src = ctx.findSource(app) orelse return error.NotFound;
    if (!src.isGit()) return error.InvalidParams; // "Updater <x> is not a Git Repo Type"

    const proc_id = nextProcId();
    ctx.busy = true;
    defer ctx.busy = false;

    const msg = try std.fmt.allocPrint(alloc, "Rolling Back {s}...", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, msg, false));
    // STUB: no real rollback performed.
    const done = try std.fmt.allocPrint(alloc, "{s} rollback finished", .{app});
    emitResponse(ctx, alloc, try buildResponseNotification(alloc, app, proc_id, done, true));
    return .{ .string = "ok" };
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

    try reg.registerEndpoint(.{ .path = "/machine/update/status", .methods = &.{.GET} }, c, handleStatus);
    try reg.registerEndpoint(.{ .path = "/machine/update/refresh", .methods = &.{.POST} }, c, handleRefresh);
    try reg.registerEndpoint(.{ .path = "/machine/update/upgrade", .methods = &.{.POST} }, c, handleUpgrade);
    try reg.registerEndpoint(.{ .path = "/machine/update/full", .methods = &.{.POST} }, c, handleFull);
    try reg.registerEndpoint(.{ .path = "/machine/update/moonraker", .methods = &.{.POST} }, c, handleUpdateMoonraker);
    try reg.registerEndpoint(.{ .path = "/machine/update/klipper", .methods = &.{.POST} }, c, handleUpdateKlipper);
    try reg.registerEndpoint(.{ .path = "/machine/update/system", .methods = &.{.POST} }, c, handleUpdateSystem);
    try reg.registerEndpoint(.{ .path = "/machine/update/client", .methods = &.{.POST} }, c, handleUpdateClient);
    try reg.registerEndpoint(.{ .path = "/machine/update/recover", .methods = &.{.POST} }, c, handleRecover);
    try reg.registerEndpoint(.{ .path = "/machine/update/rollback", .methods = &.{.POST} }, c, handleRollback);
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
    return .{ .gpa = testing.allocator, .sources = &default_sources, .bus = null, .io = null };
}

// ---- buildSourceStatus / version_info shape ----

test "buildGitStatus: full git_repo key set present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildGitStatus(null, a, default_sources[1]); // moonraker
    const o = v.object;
    for ([_][]const u8{
        "channel",          "debug_enabled",   "channel_invalid",      "is_valid",
        "configured_type",  "info_tags",       "detected_type",        "remote_alias",
        "branch",           "owner",           "repo_name",            "remote_url",
        "recovery_url",     "version",         "remote_version",       "rollback_version",
        "current_hash",     "remote_hash",     "is_dirty",             "detached",
        "commits_behind",   "commits_behind_count", "git_messages",    "full_version_string",
        "pristine",         "corrupt",         "warnings",             "anomalies",
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

test "handleUpdateMoonraker/Klipper/System: return ok ack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
    try testing.expectEqualStrings("ok", (try handleUpdateMoonraker(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleUpdateKlipper(@ptrCast(&ctx), .null, a)).string);
    try testing.expectEqualStrings("ok", (try handleUpdateSystem(@ptrCast(&ctx), .null, a)).string);
}

test "handleUpgrade/Client: name=source ok; no name → full update ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = testCtx();
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

test "getBool: parses bool/string/int/default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(getBool(try objParams(a, "{\"x\":true}"), "x", false));
    try testing.expect(getBool(try objParams(a, "{\"x\":\"true\"}"), "x", false));
    try testing.expect(getBool(try objParams(a, "{\"x\":1}"), "x", false));
    try testing.expect(!getBool(try objParams(a, "{\"x\":false}"), "x", true));
    try testing.expect(getBool(.null, "x", true));
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
}

// ---- git status with real io ----

test "buildGitStatus: empty repo_path with null io returns defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try buildGitStatus(null, a, default_sources[1]); // moonraker, no repo_path
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
    try testing.expectEqual(false, o.get("detached").?.bool);
}

test "buildGitStatus: empty repo_path with non-null io still returns defaults" {
    // No real StdIo needed; we test with our own project path that has no
    // repo_path set, so gitOutput/gitCheck are never called.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_no_path: Source = .{
        .name = "test_git", .type = .git_repo,
        .owner = "test", .repo_name = "test", .branch = "main", .repo_path = "",
    };
    const v = try buildGitStatus(null, a, src_no_path);
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
}

test "buildGitStatus: with repo_path set honors defaults when io is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_with_path: Source = .{
        .name = "test_git", .type = .git_repo,
        .owner = "test", .repo_name = "test", .branch = "main", .repo_path = "/nonexistent",
    };
    // io is null, so git commands are never run; "?" defaults are used.
    const v = try buildGitStatus(null, a, src_with_path);
    const o = v.object;
    try testing.expectEqualStrings("?", o.get("version").?.string);
    try testing.expectEqualStrings("?", o.get("current_hash").?.string);
    try testing.expectEqual(false, o.get("is_dirty").?.bool);
}

// ---- gitFetch ----

test "gitFetch: returns false with empty repo_path" {
    try testing.expect(!gitFetch(null, testing.allocator, ""));
    try testing.expect(!gitFetch(@as(?std.Io, undefined), testing.allocator, ""));
}

test "gitFetch: returns false when io is null" {
    try testing.expect(!gitFetch(null, testing.allocator, "/some/repo"));
}

test "gitFetch: returns false for nonexistent repo" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    try testing.expect(!gitFetch(threaded.io(), std.heap.smp_allocator, "/nonexistent/path"));
}

test "gitFetch: succeeds for real repo" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Use the project's own git repo (always available during dev/test).
    // Skip if no origin remote — git fetch needs a remote to succeed.
    if (!gitCheck(io, std.heap.smp_allocator, ".", &.{ "remote", "get-url", "origin" })) {
        return error.SkipZigTest;
    }
    try testing.expect(gitFetch(io, std.heap.smp_allocator, "."));
}

test "handleRefresh: runs gitFetch for sources with repo_path set (real repo)" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Skip if no origin remote — git fetch needs a remote to succeed.
    if (!gitCheck(io, std.heap.smp_allocator, ".", &.{ "remote", "get-url", "origin" })) {
        return error.SkipZigTest;
    }
    // Use the current directory as repo_path so gitFetch actually works.
    const test_sources = [_]Source{
        .{ .name = "system", .type = .system },
        .{ .name = "moonraker", .type = .git_repo, .owner = "test", .repo_name = "test", .repo_path = "." },
    };
    var ctx: UpdateCtx = .{ .gpa = std.heap.smp_allocator, .sources = &test_sources, .bus = null, .io = io };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try handleRefresh(@ptrCast(&ctx), .null, a);
    try testing.expect(v.object.get("version_info") != null);
    try testing.expect(v.object.get("version_info").?.object.get("moonraker") != null);
}

test "handleStatus: refresh=true fetches before building payload" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const test_sources = [_]Source{
        .{ .name = "system", .type = .system },
        .{ .name = "moonraker", .type = .git_repo, .owner = "test", .repo_name = "test", .repo_path = "." },
    };
    var ctx: UpdateCtx = .{ .gpa = std.heap.smp_allocator, .sources = &test_sources, .bus = null, .io = io };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try handleStatus(@ptrCast(&ctx), .{ .bool = true }, a);
    try testing.expect(v.object.get("version_info") != null);
    try testing.expect(v.object.get("version_info").?.object.get("moonraker") != null);
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
            var ctx: UpdateCtx = .{ .gpa = a, .sources = &default_sources, .bus = null, .io = null };
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
            var ctx: UpdateCtx = .{ .gpa = a, .sources = &default_sources, .bus = null, .io = null };

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
                .name = &name, .type = .git_repo,
                .owner = &owner, .repo_name = &repo,
                .branch = "main", .repo_path = rpath[0..rpath_len],
            };
            // io is always null → never runs real git; must not crash.
            _ = try buildGitStatus(null, a, src);
        }
    }.run, .{});
}

test "gitOutput: returns null for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = gitOutput(io, testing.allocator, "", &.{});
    try testing.expect(result == null);
}

test "gitOutput: returns null for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = gitOutput(io, testing.allocator, "/nonexistent/path/repo", &.{"rev-parse", "HEAD"});
    try testing.expect(result == null);
}

test "gitCheck: returns false for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(false, gitCheck(io, testing.allocator, "", &.{"rev-parse", "HEAD"}));
}

test "gitCheck: returns false for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(false, gitCheck(io, testing.allocator, "/nonexistent/path/repo", &.{"rev-parse", "HEAD"}));
}

test "gitOutput: special characters in repo_path safe" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Paths with spaces, quotes, etc. should not cause crashes.
    _ = gitOutput(io, testing.allocator, "/path with spaces/repo", &.{});
    _ = gitOutput(io, testing.allocator, "/p'ath/qu\"oted", &.{});
    _ = gitOutput(io, testing.allocator, "/p\x00ath/null", &.{});
}

test "gitCheck: special characters in repo_path safe" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    _ = gitCheck(io, testing.allocator, "/path with spaces/repo", &.{});
    _ = gitCheck(io, testing.allocator, "/p'ath/qu\"oted", &.{});
    _ = gitCheck(io, testing.allocator, "/p\x00ath/null", &.{});
}

test "gitReset: returns false for empty repo_path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(!gitReset(io, testing.allocator, "", "origin/master"));
}

test "gitReset: returns false for nonexistent path" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expect(!gitReset(io, testing.allocator, "/nonexistent/repo", "origin/master"));
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

            _ = gitReset(io, std.heap.smp_allocator, "/nonexistent/repo", ref);
        }
    }.run, .{});
}

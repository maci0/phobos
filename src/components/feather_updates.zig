//! Forge-X Feather update adapter.
//!
//! Mirrors `forge-x` `feather_updates.py`: a bounded snapshot of one
//! `[update_manager <key>]` source, plus status/update/reset decisions.
//! Update and reset refuse unless the printer is idle. They do not reboot
//! the host. Reset runs `git reset --hard HEAD` and `git clean -fd` only
//! through the injectable command runner. Update runs `machine.update.client`
//! through that same runner. Tests install a recorder, so neither path
//! spawns git on the machine running the tests.

const std = @import("std");
const update_manager = @import("update_manager.zig");

pub const FeatherError = error{InvalidStatus};

pub const CmdFn = *const fn (*anyopaque, std.mem.Allocator, []const []const u8) anyerror!void;
pub const KlippySendFn = *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value) anyerror!void;

/// Remote methods Forge-X registers with Klippy.
pub const remote_methods = [_][]const u8{
    "feather_request_forge_x_update_status",
    "feather_start_forge_x_update",
    "feather_reset_forge_x_update",
};

pub const FeatherCtx = struct {
    update_key: []const u8 = "forge-x",
    enabled: bool = false,
    updates: ?*update_manager.UpdateCtx = null,
    /// Returns true only when Klippy is ready and no job is active.
    /// Null means "not idle", so an update is refused.
    idle: ?*const fn (*anyopaque) bool = null,
    idle_ctx: ?*anyopaque = null,
    /// Runs git / client-update commands. Tests install a recorder. A null
    /// runner refuses the operation instead of spawning a host process.
    cmd: ?CmdFn = null,
    cmd_ctx: ?*anyopaque = null,
    /// Sends `feather/update_status` and `feather/update_progress` to Klippy.
    klippy_send: ?KlippySendFn = null,
    klippy_send_ctx: ?*anyopaque = null,

    pub fn printerIdle(self: *const FeatherCtx) bool {
        const pred = self.idle orelse return false;
        const ctx = self.idle_ctx orelse return false;
        return pred(ctx);
    }
};

fn versionOf(value: std.json.Value) ?[]const u8 {
    if (value != .string) return null;
    const s = std.mem.trim(u8, value.string, " \t\r\n");
    if (s.len == 0 or std.mem.eql(u8, s, "?")) return null;
    return s;
}

fn field(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

/// `forge_x_update_snapshot`. `info` is one `version_info` entry.
pub fn forgeXUpdateSnapshot(alloc: std.mem.Allocator, info: std.json.Value) !std.json.Value {
    if (info != .object) return error.InvalidStatus;
    const o = info.object;
    const installed = versionOf(field(o, "version") orelse .null) orelse return error.InvalidStatus;
    const remote = versionOf(field(o, "remote_version") orelse .null) orelse return error.InvalidStatus;
    const behind_v = field(o, "commits_behind_count") orelse std.json.Value{ .integer = 0 };
    const behind: i64 = switch (behind_v) {
        .integer => |n| @max(n, 0),
        else => return error.InvalidStatus,
    };
    const current_rev = if (field(o, "current_hash")) |v| versionOf(v) else null;
    const remote_rev = if (field(o, "remote_hash")) |v| versionOf(v) else null;
    const valid = if (field(o, "is_valid")) |v| v == .bool and v.bool else false;
    const corrupt = if (field(o, "corrupt")) |v| v == .bool and v.bool else false;
    const dirty = if (field(o, "is_dirty")) |v| v == .bool and v.bool else false;
    const available = valid and !corrupt and !dirty and !std.mem.eql(u8, installed, remote) and behind > 0 and current_rev != null and remote_rev != null and !std.mem.eql(u8, current_rev.?, remote_rev.?);

    var changes: std.json.Array = .init(alloc);
    if (field(o, "commits_behind")) |commits| {
        if (commits == .array) {
            for (commits.array.items, 0..) |commit, i| {
                if (i >= 24) break;
                if (commit != .object) continue;
                const subject = commit.object.get("subject") orelse continue;
                if (subject != .string) continue;
                const trimmed = std.mem.trim(u8, subject.string, " \t\r\n");
                if (trimmed.len == 0) continue;
                const n = @min(trimmed.len, 160);
                try changes.append(.{ .string = try alloc.dupe(u8, trimmed[0..n]) });
            }
        }
    }

    var out: std.json.ObjectMap = .empty;
    try out.put(alloc, "available", .{ .bool = available });
    try out.put(alloc, "installed_version", .{ .string = try alloc.dupe(u8, installed) });
    try out.put(alloc, "available_version", .{ .string = try alloc.dupe(u8, remote) });
    try out.put(alloc, "available_revision", .{ .string = try alloc.dupe(u8, remote_rev orelse "") });
    try out.put(alloc, "changes", .{ .array = changes });
    try out.put(alloc, "changes_total", .{ .integer = behind });
    return .{ .object = out };
}

/// Lines Git prints as blocking a merge, tagged `UNTRACKED` or `MODIFIED`.
pub fn gitConflictingFiles(alloc: std.mem.Allocator, message: []const u8) ![]const []const u8 {
    const markers = [_]struct { []const u8, []const u8 }{
        .{ "The following untracked working tree files would be overwritten by merge:", "UNTRACKED" },
        .{ "Your local changes to the following files would be overwritten by merge:", "MODIFIED" },
    };
    var kind: ?[]const u8 = null;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var matched: ?[]const u8 = null;
        for (markers) |m| {
            if (std.mem.indexOf(u8, line, m[0]) != null) matched = m[1];
        }
        if (matched) |label| {
            kind = label;
            continue;
        }
        const tag = kind orelse continue;
        if (line.len == 0 or std.mem.startsWith(u8, line, "Please ") or std.mem.eql(u8, line, "Aborting") or std.mem.startsWith(u8, line, "error:")) {
            kind = null;
            continue;
        }
        const path_n = @min(line.len, 160);
        const entry = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ tag, line[0..path_n] });
        if (out.items.len >= 64) {
            alloc.free(entry);
            break;
        }
        try out.append(alloc, entry);
    }
    return out.toOwnedSlice(alloc);
}

fn sourceInfo(status: std.json.Value, key: []const u8) ?std.json.Value {
    if (status != .object) return null;
    const versions = status.object.get("version_info") orelse return null;
    if (versions != .object) return null;
    return versions.object.get(key);
}

/// Cached Forge-X snapshot. Does not `git fetch`. `token` is Feather's
/// request id. On failure `error` is set and the snapshot keys are absent.
pub fn statusResponse(self: *FeatherCtx, alloc: std.mem.Allocator, token: i64) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "token", .{ .integer = token });
    try obj.put(alloc, "error", .{ .string = "" });
    const updates = self.updates orelse {
        try obj.put(alloc, "error", .{ .string = "Moonraker update status is unavailable" });
        return .{ .object = obj };
    };
    const status = update_manager.handleStatus(updates, .null, alloc) catch {
        try obj.put(alloc, "error", .{ .string = "Moonraker update status is unavailable" });
        return .{ .object = obj };
    };
    const info = sourceInfo(status, self.update_key) orelse {
        const msg = try std.fmt.allocPrint(alloc, "Configured update source is unavailable: {s}", .{self.update_key});
        try obj.put(alloc, "error", .{ .string = msg });
        return .{ .object = obj };
    };
    const snap = forgeXUpdateSnapshot(alloc, info) catch |err| {
        try obj.put(alloc, "error", .{ .string = @errorName(err) });
        return .{ .object = obj };
    };
    if (snap == .object) {
        var it = snap.object.iterator();
        while (it.next()) |e| try obj.put(alloc, e.key_ptr.*, e.value_ptr.*);
    }
    return .{ .object = obj };
}

fn failState(alloc: std.mem.Allocator, token: i64, message: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "token", .{ .integer = token });
    try obj.put(alloc, "state", .{ .string = "failed" });
    try obj.put(alloc, "message", .{ .string = message });
    return .{ .object = obj };
}

fn sendProgress(self: *FeatherCtx, alloc: std.mem.Allocator, payload: std.json.Value) void {
    const send = self.klippy_send orelse return;
    const ctx = self.klippy_send_ctx orelse return;
    send(ctx, alloc, "feather/update_progress", payload) catch {};
}

fn runCmd(self: *FeatherCtx, alloc: std.mem.Allocator, argv: []const []const u8) !void {
    const cmd = self.cmd orelse return error.NoCommandRunner;
    const ctx = self.cmd_ctx orelse return error.NoCommandRunner;
    try cmd(ctx, alloc, argv);
}

/// Refuses unless the printer is idle and the offered version still matches.
/// On a match, the command runner performs `machine.update.client` (the
/// daemon calls `handleUpdateClient`; a test recorder only records the argv).
/// No runner means failure. Never reboots the host.
pub fn updateResponse(self: *FeatherCtx, alloc: std.mem.Allocator, expected_version: []const u8, expected_revision: []const u8, token: i64) !std.json.Value {
    if (!self.printerIdle()) return failState(alloc, token, "Printer is not safely idle");
    if (expected_version.len == 0 or expected_revision.len == 0 or std.mem.eql(u8, expected_version, "?")) {
        return failState(alloc, token, "Invalid update offer; check again");
    }
    const status = statusResponse(self, alloc, token) catch return failState(alloc, token, "InvalidStatus");
    if (status != .object) return failState(alloc, token, "InvalidStatus");
    const err = status.object.get("error") orelse return failState(alloc, token, "InvalidStatus");
    if (err != .string or err.string.len != 0) return failState(alloc, token, if (err == .string) err.string else "InvalidStatus");
    const available = status.object.get("available") orelse return failState(alloc, token, "Available update changed; check again");
    const ver = status.object.get("available_version") orelse .null;
    const rev = status.object.get("available_revision") orelse .null;
    const offer_ok = available == .bool and available.bool and ver == .string and rev == .string and std.mem.eql(u8, ver.string, expected_version) and std.mem.eql(u8, rev.string, expected_revision);
    if (!offer_ok) return failState(alloc, token, "Available update changed; check again");
    if (!self.printerIdle()) return failState(alloc, token, "Printer is not safely idle");

    const accepted = try progressState(alloc, token, "accepted", "PREPARING FORGE-X UPDATE...");
    sendProgress(self, alloc, accepted);
    runCmd(self, alloc, &.{ "machine.update.client", self.update_key }) catch |cmd_err| {
        const msg: []const u8 = if (cmd_err == error.UpdateFailed) "machine.update.client failed" else "Cannot update, no command runner";
        return failState(alloc, token, msg);
    };
    return progressState(alloc, token, "complete", "UPDATE COMPLETE. RESTARTING PRINTER...");
}

/// Refuses unless the printer is idle. A reset reports complete only after
/// the runner has executed `git reset --hard HEAD` and `git clean -fd`.
pub fn resetResponse(self: *FeatherCtx, alloc: std.mem.Allocator, token: i64) !std.json.Value {
    if (!self.printerIdle()) return failState(alloc, token, "Printer is not safely idle");
    const updates = self.updates orelse return failState(alloc, token, "Moonraker update status is unavailable");
    if (updates.busy) return failState(alloc, token, "Moonraker update manager is busy");
    runCmd(self, alloc, &.{ "git", "reset", "--hard", "HEAD" }) catch {
        return failState(alloc, token, "git reset failed");
    };
    runCmd(self, alloc, &.{ "git", "clean", "-fd" }) catch {
        return failState(alloc, token, "git clean failed");
    };
    return progressState(alloc, token, "reset_complete", "FORGE-X RESET COMPLETE");
}

fn progressState(alloc: std.mem.Allocator, token: i64, state: []const u8, message: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "token", .{ .integer = token });
    try obj.put(alloc, "state", .{ .string = state });
    try obj.put(alloc, "message", .{ .string = message });
    return .{ .object = obj };
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// Klippy remote-method entry. `dispatchFrame` routes an id-less
/// `call_remote_method` payload here. Replies are `feather/update_status`
/// or `feather/update_progress`.
pub fn onKlippyMethod(ctx: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
    const self: *FeatherCtx = @ptrCast(@alignCast(ctx));
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const obj = if (params == .object) params.object else null;
    const token = if (obj) |o| (if (o.get("token")) |t| jsonInt(t) orelse 0 else 0) else 0;
    if (std.mem.eql(u8, method, "feather_request_forge_x_update_status")) {
        const payload = try statusResponse(self, a, token);
        const send = self.klippy_send orelse return;
        const sctx = self.klippy_send_ctx orelse return;
        try send(sctx, a, "feather/update_status", payload);
        return;
    }
    if (std.mem.eql(u8, method, "feather_start_forge_x_update")) {
        const ver = if (obj) |o| jsonStr(o, "expected_version") else "";
        const rev = if (obj) |o| jsonStr(o, "expected_revision") else "";
        const payload = try updateResponse(self, a, ver, rev, token);
        sendProgress(self, a, payload);
        return;
    }
    if (std.mem.eql(u8, method, "feather_reset_forge_x_update")) {
        const payload = try resetResponse(self, a, token);
        sendProgress(self, a, payload);
        return;
    }
}

test "forgeXUpdateSnapshot: available only when versions and revisions differ" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var info: std.json.ObjectMap = .empty;
    try info.put(arena, "version", .{ .string = "1.4.2" });
    try info.put(arena, "remote_version", .{ .string = "1.4.3" });
    try info.put(arena, "commits_behind_count", .{ .integer = 2 });
    try info.put(arena, "current_hash", .{ .string = "aaa" });
    try info.put(arena, "remote_hash", .{ .string = "bbb" });
    try info.put(arena, "is_valid", .{ .bool = true });
    try info.put(arena, "corrupt", .{ .bool = false });
    try info.put(arena, "is_dirty", .{ .bool = false });
    var commits: std.json.Array = .init(arena);
    var one: std.json.ObjectMap = .empty;
    try one.put(arena, "subject", .{ .string = "fix heater" });
    try commits.append(.{ .object = one });
    try info.put(arena, "commits_behind", .{ .array = commits });

    const snap = try forgeXUpdateSnapshot(arena, .{ .object = info });
    try std.testing.expect(snap.object.get("available").?.bool);
    try std.testing.expectEqualStrings("1.4.3", snap.object.get("available_version").?.string);
    try std.testing.expectEqual(@as(i64, 2), snap.object.get("changes_total").?.integer);
    try std.testing.expectEqualStrings("fix heater", snap.object.get("changes").?.array.items[0].string);

    try info.put(arena, "remote_version", .{ .string = "1.4.2" });
    const same = try forgeXUpdateSnapshot(arena, .{ .object = info });
    try std.testing.expect(!same.object.get("available").?.bool);
}

test "gitConflictingFiles: tags untracked and modified paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const msg =
        \\The following untracked working tree files would be overwritten by merge:
        \\ printer.cfg
        \\Please move or remove them before you merge.
        \\Your local changes to the following files would be overwritten by merge:
        \\ moonraker.conf
        \\Aborting
    ;
    const files = try gitConflictingFiles(alloc, msg);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("UNTRACKED: printer.cfg", files[0]);
    try std.testing.expectEqualStrings("MODIFIED: moonraker.conf", files[1]);
}

const Recorder = struct {
    cmds: std.ArrayList([]const u8),
    methods: std.ArrayList([]const u8),
    states: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,

    fn cmd(ctx: *anyopaque, alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        for (argv, 0..) |arg, i| {
            if (i != 0) try buf.append(alloc, ' ');
            try buf.appendSlice(alloc, arg);
        }
        try self.cmds.append(self.alloc, try self.alloc.dupe(u8, buf.items));
    }

    fn send(ctx: *anyopaque, alloc: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror!void {
        _ = alloc;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.methods.append(self.alloc, try self.alloc.dupe(u8, method));
        if (params == .object) {
            if (params.object.get("state")) |st| {
                if (st == .string) try self.states.append(self.alloc, try self.alloc.dupe(u8, st.string));
            }
        }
    }
};

fn idleYes(_: *anyopaque) bool {
    return true;
}

test "dispatchRemoteMethod: reset runs git through the runner before reset_complete" {
    const alloc = std.testing.allocator;
    var json_arena = std.heap.ArenaAllocator.init(alloc);
    defer json_arena.deinit();
    const ja = json_arena.allocator();
    var rec = Recorder{
        .cmds = .empty,
        .methods = .empty,
        .states = .empty,
        .alloc = alloc,
    };
    defer {
        for (rec.cmds.items) |s| alloc.free(s);
        rec.cmds.deinit(alloc);
        for (rec.methods.items) |s| alloc.free(s);
        rec.methods.deinit(alloc);
        for (rec.states.items) |s| alloc.free(s);
        rec.states.deinit(alloc);
    }
    var updates = update_manager.UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = &update_manager.default_sources, .bus = null, .io = null };
    var feather = FeatherCtx{
        .updates = &updates,
        .idle = idleYes,
        .idle_ctx = &rec,
        .cmd = Recorder.cmd,
        .cmd_ctx = &rec,
        .klippy_send = Recorder.send,
        .klippy_send_ctx = &rec,
    };
    const klippy = @import("klippy_connection.zig");
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var kctx = klippy.KlippyCtx{
        .gpa = alloc,
        .bus = undefined,
        .uds_path = "/no/such/klippy.sock",
        .remote_handler = onKlippyMethod,
        .remote_handler_ctx = &feather,
    };

    var params: std.json.ObjectMap = .empty;
    try params.put(ja, "token", .{ .integer = 9 });
    var frame: std.json.ObjectMap = .empty;
    try frame.put(ja, "method", .{ .string = "feather_reset_forge_x_update" });
    try frame.put(ja, "params", .{ .object = params });
    try kctx.dispatchRemoteMethod(threaded.io(), "feather_reset_forge_x_update", .{ .object = frame });

    try std.testing.expectEqual(@as(usize, 2), rec.cmds.items.len);
    try std.testing.expectEqualStrings("git reset --hard HEAD", rec.cmds.items[0]);
    try std.testing.expectEqualStrings("git clean -fd", rec.cmds.items[1]);
    try std.testing.expectEqual(@as(usize, 1), rec.methods.items.len);
    try std.testing.expectEqualStrings("feather/update_progress", rec.methods.items[0]);
    try std.testing.expectEqualStrings("reset_complete", rec.states.items[0]);
}

test "dispatchRemoteMethod: idle refusal does not run git" {
    const alloc = std.testing.allocator;
    var json_arena = std.heap.ArenaAllocator.init(alloc);
    defer json_arena.deinit();
    const ja = json_arena.allocator();
    var rec = Recorder{ .cmds = .empty, .methods = .empty, .states = .empty, .alloc = alloc };
    defer {
        for (rec.cmds.items) |s| alloc.free(s);
        rec.cmds.deinit(alloc);
        for (rec.methods.items) |s| alloc.free(s);
        rec.methods.deinit(alloc);
        for (rec.states.items) |s| alloc.free(s);
        rec.states.deinit(alloc);
    }
    var updates = update_manager.UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = &update_manager.default_sources, .bus = null, .io = null };
    var feather = FeatherCtx{
        .updates = &updates,
        .cmd = Recorder.cmd,
        .cmd_ctx = &rec,
        .klippy_send = Recorder.send,
        .klippy_send_ctx = &rec,
    };
    const klippy = @import("klippy_connection.zig");
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var kctx = klippy.KlippyCtx{
        .gpa = alloc,
        .bus = undefined,
        .uds_path = "/no/such/klippy.sock",
        .remote_handler = onKlippyMethod,
        .remote_handler_ctx = &feather,
    };
    var params: std.json.ObjectMap = .empty;
    try params.put(ja, "token", .{ .integer = 4 });
    var frame: std.json.ObjectMap = .empty;
    try frame.put(ja, "params", .{ .object = params });
    try kctx.dispatchRemoteMethod(threaded.io(), "feather_reset_forge_x_update", .{ .object = frame });
    try std.testing.expectEqual(@as(usize, 0), rec.cmds.items.len);
    try std.testing.expectEqualStrings("feather/update_progress", rec.methods.items[0]);
    try std.testing.expectEqualStrings("failed", rec.states.items[0]);
}

test "dispatchRemoteMethod: update calls machine.update.client before complete" {
    const alloc = std.testing.allocator;
    var json_arena = std.heap.ArenaAllocator.init(alloc);
    defer json_arena.deinit();
    const ja = json_arena.allocator();
    var rec = Recorder{ .cmds = .empty, .methods = .empty, .states = .empty, .alloc = alloc };
    defer {
        for (rec.cmds.items) |s| alloc.free(s);
        rec.cmds.deinit(alloc);
        for (rec.methods.items) |s| alloc.free(s);
        rec.methods.deinit(alloc);
        for (rec.states.items) |s| alloc.free(s);
        rec.states.deinit(alloc);
    }
    const sources = [_]update_manager.Source{.{
        .name = "forge-x",
        .type = .git_repo,
        .owner = "DrA1ex",
        .repo_name = "ff5m",
        .branch = "1.4.2",
        .pinned_version = "1.4.2",
        .pinned_remote_version = "1.4.3",
        .pinned_hash = "aaa",
        .pinned_remote_hash = "bbb",
        .pinned_behind = 2,
    }};
    var updates = update_manager.UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = &sources, .bus = null, .io = null };
    var feather = FeatherCtx{
        .update_key = "forge-x",
        .updates = &updates,
        .idle = idleYes,
        .idle_ctx = &rec,
        .cmd = Recorder.cmd,
        .cmd_ctx = &rec,
        .klippy_send = Recorder.send,
        .klippy_send_ctx = &rec,
    };
    const klippy = @import("klippy_connection.zig");
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var kctx = klippy.KlippyCtx{
        .gpa = alloc,
        .bus = undefined,
        .uds_path = "/no/such/klippy.sock",
        .remote_handler = onKlippyMethod,
        .remote_handler_ctx = &feather,
    };
    var params: std.json.ObjectMap = .empty;
    try params.put(ja, "token", .{ .integer = 11 });
    try params.put(ja, "expected_version", .{ .string = "1.4.3" });
    try params.put(ja, "expected_revision", .{ .string = "bbb" });
    var frame: std.json.ObjectMap = .empty;
    try frame.put(ja, "params", .{ .object = params });
    try kctx.dispatchRemoteMethod(threaded.io(), "feather_start_forge_x_update", .{ .object = frame });
    try std.testing.expectEqualStrings("machine.update.client forge-x", rec.cmds.items[0]);
    try std.testing.expectEqualStrings("accepted", rec.states.items[0]);
    try std.testing.expectEqualStrings("complete", rec.states.items[rec.states.items.len - 1]);
    try std.testing.expectEqualStrings("feather/update_progress", rec.methods.items[0]);
}

test "dispatchFrame: id-less feather reset reaches onKlippyMethod" {
    const alloc = std.testing.allocator;
    var rec = Recorder{ .cmds = .empty, .methods = .empty, .states = .empty, .alloc = alloc };
    defer {
        for (rec.cmds.items) |s| alloc.free(s);
        rec.cmds.deinit(alloc);
        for (rec.methods.items) |s| alloc.free(s);
        rec.methods.deinit(alloc);
        for (rec.states.items) |s| alloc.free(s);
        rec.states.deinit(alloc);
    }
    var updates = update_manager.UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = &update_manager.default_sources, .bus = null, .io = null };
    var feather = FeatherCtx{
        .updates = &updates,
        .idle = idleYes,
        .idle_ctx = &rec,
        .cmd = Recorder.cmd,
        .cmd_ctx = &rec,
        .klippy_send = Recorder.send,
        .klippy_send_ctx = &rec,
    };
    const klippy = @import("klippy_connection.zig");
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var kctx = klippy.KlippyCtx{
        .gpa = alloc,
        .bus = undefined,
        .uds_path = "/no/such/klippy.sock",
        .remote_handler = onKlippyMethod,
        .remote_handler_ctx = &feather,
    };
    // Klippy call_remote_method shape: response_template method plus params, no id.
    const payload = "{\"method\":\"feather_reset_forge_x_update\",\"params\":{\"token\":5}}";
    try kctx.dispatchFrame(threaded.io(), payload);
    try std.testing.expectEqual(@as(usize, 2), rec.cmds.items.len);
    try std.testing.expectEqualStrings("git reset --hard HEAD", rec.cmds.items[0]);
    try std.testing.expectEqualStrings("git clean -fd", rec.cmds.items[1]);
    try std.testing.expectEqualStrings("feather/update_progress", rec.methods.items[0]);
    try std.testing.expectEqualStrings("reset_complete", rec.states.items[0]);
}

test "dispatchRemoteMethod: no runner does not report reset_complete" {
    const alloc = std.testing.allocator;
    var json_arena = std.heap.ArenaAllocator.init(alloc);
    defer json_arena.deinit();
    const ja = json_arena.allocator();
    var rec = Recorder{ .cmds = .empty, .methods = .empty, .states = .empty, .alloc = alloc };
    defer {
        for (rec.methods.items) |s| alloc.free(s);
        rec.methods.deinit(alloc);
        for (rec.states.items) |s| alloc.free(s);
        rec.states.deinit(alloc);
        rec.cmds.deinit(alloc);
    }
    var updates = update_manager.UpdateCtx{ .clock_io = std.testing.io, .gpa = alloc, .sources = &update_manager.default_sources, .bus = null, .io = null };
    var feather = FeatherCtx{
        .updates = &updates,
        .idle = idleYes,
        .idle_ctx = &rec,
        .klippy_send = Recorder.send,
        .klippy_send_ctx = &rec,
    };
    const klippy = @import("klippy_connection.zig");
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var kctx = klippy.KlippyCtx{
        .gpa = alloc,
        .bus = undefined,
        .uds_path = "/no/such/klippy.sock",
        .remote_handler = onKlippyMethod,
        .remote_handler_ctx = &feather,
    };
    var params: std.json.ObjectMap = .empty;
    try params.put(ja, "token", .{ .integer = 5 });
    var frame: std.json.ObjectMap = .empty;
    try frame.put(ja, "params", .{ .object = params });
    try kctx.dispatchRemoteMethod(threaded.io(), "feather_reset_forge_x_update", .{ .object = frame });
    try std.testing.expectEqual(@as(usize, 0), rec.cmds.items.len);
    try std.testing.expectEqualStrings("failed", rec.states.items[0]);
    try std.testing.expect(rec.states.items[0].len > 0);
    for (rec.states.items) |st| try std.testing.expect(!std.mem.eql(u8, st, "reset_complete"));
}

test "updateResponse: refuses while the printer is not idle" {
    var ctx = FeatherCtx{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const res = try updateResponse(&ctx, alloc, "1.4.3", "bbb", 7);
    try std.testing.expectEqualStrings("failed", res.object.get("state").?.string);
    try std.testing.expectEqualStrings("Printer is not safely idle", res.object.get("message").?.string);
    const reset = try resetResponse(&ctx, alloc, 7);
    try std.testing.expectEqualStrings("failed", reset.object.get("state").?.string);
}

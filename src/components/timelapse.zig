//! Forge-X timelapse capture and export. Workers are owned by App's remote queue.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const params = @import("../json/params.zig");
const values = @import("../json/value.zig");
const config = @import("../config/confighelper.zig");
const datastore = @import("../store/datastore.zig");
const notify = @import("../server/notify.zig");
const registry = @import("../server/registry.zig");
const process = @import("../util/process.zig");
const clock = @import("../util/clock.zig");
const http_get = @import("http_get.zig");
const files = @import("file_manager.zig");
const max_frames = 1000;
const max_snapshot_bytes = 8 * 1024 * 1024;
const reserve_bytes = 128 * 1024 * 1024;
const max_setting_bytes = 4096;
const max_command_output = 64 * 1024;
const snapshot_timeout_seconds = 3;
const finish_wait_steps = 100;
const finish_wait_ms = 100;
const max_extra_arguments = 64;
const max_collision_attempts = 10000;
const max_frame_number = 999999;
const max_fps = 240;
const max_stream_delay_seconds = 60;
const max_park_seconds = 3600;
const max_render_seconds = 86400;
const max_crf = 51;
const max_rotation = 360;

pub const remote_methods = [_][]const u8{ "timelapse_newframe", "timelapse_saveFrames", "timelapse_render", "timelapse_cancel_render" };
pub const internal_methods = [_][]const u8{ "_timelapse_setup", "_timelapse_begin", "_timelapse_finish", "_timelapse_stop" };
pub const RpcFn = *const fn (*anyopaque, Allocator, []const u8, Value) anyerror!Value;
pub const QueueFn = *const fn (*anyopaque, []const u8) anyerror!void;
pub const RunFn = *const fn (?*anyopaque, Allocator, Io, std.process.RunOptions) anyerror!std.process.RunResult;
pub const SnapshotFn = *const fn (?*anyopaque, Allocator, Io, []const u8, Io.File) anyerror!void;

pub const Settings = struct {
    enabled: bool = true,
    mode: []const u8 = "layermacro",
    camera: []const u8 = "",
    snapshoturl: []const u8 = "http://localhost:8080/?action=snapshot",
    stream_delay_compensation: f64 = 0.05,
    gcode_verbose: bool = false,
    parkhead: bool = false,
    parkpos: []const u8 = "back_left",
    park_custom_pos_x: f64 = 10,
    park_custom_pos_y: f64 = 10,
    park_custom_pos_dz: f64 = 0,
    park_travel_speed: i64 = 100,
    park_retract_speed: i64 = 15,
    park_extrude_speed: i64 = 15,
    park_retract_distance: f64 = 1,
    park_extrude_distance: f64 = 1,
    park_time: f64 = 0.1,
    fw_retract: bool = false,
    hyperlapse_cycle: i64 = 30,
    autorender: bool = true,
    constant_rate_factor: i64 = 23,
    output_framerate: i64 = 30,
    pixelformat: []const u8 = "yuv420p",
    time_format_code: []const u8 = "%Y%m%d_%H%M",
    extraoutputparams: []const u8 = "",
    variable_fps: bool = false,
    targetlength: i64 = 10,
    variable_fps_min: i64 = 5,
    variable_fps_max: i64 = 60,
    rotation: i64 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    duplicatelastframe: i64 = 5,
    previewimage: bool = true,
    saveframes: bool = false,
};

fn validate(s: Settings) !void {
    inline for (comptime std.meta.fieldNames(Settings)) |name| {
        const T = @FieldType(Settings, name);
        const v = @field(s, name);
        if (T == []const u8) {
            if (v.len > max_setting_bytes or !std.unicode.utf8ValidateSlice(v) or std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidParams;
        } else if (T == f64) {
            if (!std.math.isFinite(v)) return error.InvalidParams;
        }
    }
    if (!std.mem.eql(u8, s.mode, "layermacro") and !std.mem.eql(u8, s.mode, "hyperlapse")) return error.InvalidParams;
    if (!safeWord(s.parkpos) or !safeWord(s.pixelformat)) return error.InvalidParams;
    if (s.targetlength <= 0 or s.output_framerate <= 0 or s.output_framerate > max_fps or s.variable_fps_min <= 0 or s.variable_fps_max < s.variable_fps_min or s.variable_fps_max > max_fps) return error.InvalidParams;
    if (s.stream_delay_compensation < 0 or s.stream_delay_compensation > max_stream_delay_seconds or s.park_time < 0 or s.park_time > max_park_seconds or s.hyperlapse_cycle <= 0) return error.InvalidParams;
    if (s.park_travel_speed <= 0 or s.park_retract_speed <= 0 or s.park_extrude_speed <= 0 or s.park_retract_distance < 0 or s.park_extrude_distance < 0) return error.InvalidParams;
    if (s.constant_rate_factor < 0 or s.constant_rate_factor > max_crf or s.rotation < 0 or s.rotation > max_rotation or s.duplicatelastframe < 0 or s.duplicatelastframe > max_frames) return error.InvalidParams;
    const uri = std.Uri.parse(s.snapshoturl) catch return error.InvalidParams;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidParams;
    if (uri.host == null) return error.InvalidParams;
    if (std.mem.indexOfAny(u8, s.time_format_code, "/\\\r\n") != null) return error.InvalidParams;
}

fn safeWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn json(a: Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{});
}

fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn string(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn truth(value: Value) bool {
    return switch (value) {
        .bool => value.bool,
        .integer => value.integer != 0,
        .string => std.ascii.eqlIgnoreCase(value.string, "true"),
        else => false,
    };
}

const Operation = enum { idle, capture, render, save };
pub const Timelapse = struct {
    gpa: Allocator,
    io: Io,
    store: ?datastore.DataStore = null,
    bus: ?*notify.NotifyBus = null,
    enabled: bool = false,
    mutex: Io.Mutex = .init,
    lifecycle: Io.Mutex = .init,
    settings: Settings = .{},
    settings_arena: ?std.heap.ArenaAllocator = null,
    blocked: [std.meta.fieldNames(Settings).len]bool = @splat(false),
    frame_path: [:0]const u8 = "",
    output_path: [:0]const u8 = "",
    ffmpeg: []const u8 = "/usr/bin/ffmpeg",
    ffmpeg_owned: bool = false,
    render_timeout: f64 = 3600,
    operation: Operation = .idle,
    generation: u32 = 0,
    cancel: Io.Event = .unset,
    finalizing: bool = false,
    pending: bool = false,
    printing: bool = false,
    framecount: u32 = 0,
    lastframe: u32 = 0,
    filename: [1024]u8 = undefined,
    filename_len: usize = 0,
    final_filename: [1024]u8 = undefined,
    final_filename_len: usize = 0,
    rpc: ?RpcFn = null,
    rpc_ctx: ?*anyopaque = null,
    queue: ?QueueFn = null,
    queue_ctx: ?*anyopaque = null,
    run: RunFn = runProcess,
    run_ctx: ?*anyopaque = null,
    snapshot: SnapshotFn = downloadSnapshot,
    snapshot_ctx: ?*anyopaque = null,
    webcams: ?*@import("webcam.zig").WebcamCtx = null,

    pub fn deinit(self: *Timelapse) void {
        if (self.settings_arena) |*owned| owned.deinit();
        if (self.frame_path.len != 0) self.gpa.free(self.frame_path);
        if (self.output_path.len != 0) self.gpa.free(self.output_path);
        if (self.ffmpeg_owned) self.gpa.free(self.ffmpeg);
    }

    pub fn configure(self: *Timelapse, cfg: *const config.ConfigParser, datadir: []const u8, home: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        errdefer scratch.deinit();
        const a = scratch.allocator();
        var s: Settings = .{};
        if (self.store) |db| {
            const saved = (try db.getItem(a, "timelapse", "config")) orelse .null;
            if (saved == .object) inline for (comptime std.meta.fieldNames(Settings)) |name| {
                if (try params.optional(@FieldType(Settings, name), saved, name)) |v| @field(s, name) = v;
            };
        }
        inline for (comptime std.meta.fieldNames(Settings), 0..) |name, index| {
            const T = @FieldType(Settings, name);
            if (cfg.get("timelapse", name)) |text| {
                @field(s, name) = if (T == []const u8) try a.dupe(u8, text) else if (T == bool) try cfg.getBoolean("timelapse", name) else if (T == i64) try cfg.getInt("timelapse", name) else try cfg.getFloat("timelapse", name);
                self.blocked[index] = true;
            }
        }
        if (std.mem.indexOf(u8, s.snapshoturl, "://") == null)
            s.snapshoturl = try std.fmt.allocPrint(a, "http://localhost{s}{s}", .{ if (std.mem.startsWith(u8, s.snapshoturl, "/")) "" else "/", s.snapshoturl });
        try validate(s);
        self.ffmpeg = try self.gpa.dupe(u8, cfg.get("timelapse", "ffmpeg_binary_path") orelse self.ffmpeg);
        self.ffmpeg_owned = true;
        if (cfg.get("timelapse", "render_timeout") != null) self.render_timeout = try cfg.getFloat("timelapse", "render_timeout");
        if (!std.math.isFinite(self.render_timeout) or self.render_timeout <= 0 or self.render_timeout > max_render_seconds) return error.InvalidConfig;
        const frame = try expandedPath(a, cfg.get("timelapse", "frame_path") orelse "/tmp/timelapse/", datadir, home);
        const output = try expandedPath(a, cfg.get("timelapse", "output_path") orelse "~/timelapse/", datadir, home);
        try Io.Dir.cwd().createDirPath(self.io, frame);
        try Io.Dir.cwd().createDirPath(self.io, output);
        self.frame_path = try Io.Dir.cwd().realPathFileAlloc(self.io, frame, self.gpa);
        errdefer {
            self.gpa.free(self.frame_path);
            self.frame_path = "";
        }
        self.output_path = try Io.Dir.cwd().realPathFileAlloc(self.io, output, self.gpa);
        errdefer {
            self.gpa.free(self.output_path);
            self.output_path = "";
        }
        if (std.mem.eql(u8, self.frame_path, self.output_path)) return error.InvalidConfig;
        Io.Dir.cwd().access(self.io, self.ffmpeg, .{}) catch {
            s.autorender = false;
        };
        var dir = try self.frameDir();
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| if (frameNumber(entry.name)) |number| {
            if (entry.kind != .file or self.framecount == max_frames) return error.InvalidFrameDirectory;
            self.framecount += 1;
            self.lastframe = @max(self.lastframe, number);
        };
        self.settings = s;
        self.settings_arena = scratch;
        self.enabled = true;
    }

    fn frameDir(self: *Timelapse) !Io.Dir {
        return Io.Dir.cwd().openDir(self.io, self.frame_path, .{ .iterate = true });
    }
    fn settingsCopy(self: *Timelapse, a: Allocator) !Settings {
        self.mutex.lockUncancelable(self.io);
        const copied = blk: {
            defer self.mutex.unlock(self.io);
            break :blk try std.json.parseFromSliceLeaky(Settings, a, try std.json.Stringify.valueAlloc(a, self.settings, .{}), .{});
        };
        var s = copied;
        if (self.bus) |bus| try bus.core.run(self.io, applyCamera, .{ self, a, &s }) else try self.applyCamera(a, &s);
        return s;
    }
    fn applyCamera(self: *Timelapse, a: Allocator, s: *Settings) !void {
        const cams = self.webcams orelse return;
        var chosen: ?@import("webcam.zig").Webcam = null;
        for (cams.order.items) |uid| {
            const cam = cams.cams.get(uid) orelse continue;
            if (chosen == null) chosen = cam;
            if (std.mem.eql(u8, cam.name, s.camera)) {
                chosen = cam;
                break;
            }
        }
        const cam = chosen orelse return;
        inline for (comptime std.meta.fieldNames(Settings), 0..) |name, index| {
            if (!self.blocked[index]) {
                if (comptime std.mem.eql(u8, name, "snapshoturl")) {
                    if (cam.snapshot_url.len != 0) s.snapshoturl = if (std.mem.startsWith(u8, cam.snapshot_url, "/"))
                        try std.fmt.allocPrint(a, "http://localhost{s}", .{cam.snapshot_url})
                    else if (std.mem.indexOf(u8, cam.snapshot_url, "://") == null)
                        try std.fmt.allocPrint(a, "http://localhost/{s}", .{cam.snapshot_url})
                    else
                        try a.dupe(u8, cam.snapshot_url);
                }
                if (comptime std.mem.eql(u8, name, "flip_x")) s.flip_x = cam.flip_horizontal;
                if (comptime std.mem.eql(u8, name, "flip_y")) s.flip_y = cam.flip_vertical;
                if (comptime std.mem.eql(u8, name, "rotation")) s.rotation = cam.rotation;
            }
        }
    }
    fn enqueue(self: *Timelapse, method: []const u8) void {
        const callback = self.queue orelse return;
        callback(self.queue_ctx orelse return, method) catch |err| std.debug.print("phobos: timelapse queue: {}\n", .{err});
    }
    fn call(self: *Timelapse, a: Allocator, method: []const u8, args: Value) !Value {
        return (self.rpc orelse return error.KlippyDisconnected)(self.rpc_ctx orelse return error.KlippyDisconnected, a, method, args);
    }
    fn gcode(self: *Timelapse, a: Allocator, script: []const u8) !void {
        _ = try self.call(a, "gcode/script", try json(a, .{ .script = script }));
    }
    fn query(self: *Timelapse, a: Allocator, objects: anytype) !Value {
        const response = try self.call(a, "objects/query", try json(a, .{ .objects = objects }));
        return field(response, "status");
    }
    fn emit(self: *Timelapse, a: Allocator, value: Value) void {
        const bus = self.bus orelse return;
        var args: std.json.Array = .init(a);
        args.append(value) catch return;
        bus.emit(self.io, notify.names.timelapse_event, .{ .array = args }) catch |err| std.debug.print("phobos: timelapse notification: {}\n", .{err});
    }
    fn console(self: *Timelapse, a: Allocator, text: []const u8) void {
        const bus = self.bus orelse return;
        var args: std.json.Array = .init(a);
        args.append(.{ .string = text }) catch return;
        bus.emit(self.io, notify.names.gcode_response, .{ .array = args }) catch |err| std.debug.print("phobos: timelapse console: {}\n", .{err});
    }
    fn result(self: *Timelapse, a: Allocator, action: []const u8, status: []const u8, msg: []const u8) !Value {
        const value = try json(a, .{ .action = action, .status = status, .msg = msg });
        self.emit(a, value);
        return value;
    }
    fn validGeneration(self: *Timelapse, generation: u32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.generation == generation;
    }
    fn claim(self: *Timelapse, operation: Operation) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.operation != .idle) return null;
        self.operation = operation;
        self.cancel.reset();
        return self.generation;
    }
    fn release(self: *Timelapse) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.operation = .idle;
    }

    pub fn cancelOperation(self: *Timelapse) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generation +%= 1;
        self.finalizing = false;
        self.cancel.set(self.io);
    }

    pub fn statusUpdate(self: *Timelapse, status: Value) void {
        if (!self.enabled) return;
        const stats = field(status, "print_stats");
        const name = string(field(stats, "filename"));
        const state = string(field(stats, "state"));
        self.mutex.lockUncancelable(self.io);
        if (name.len != 0 and !self.finalizing) {
            self.filename_len = @min(name.len, self.filename.len);
            @memcpy(self.filename[0..self.filename_len], name[0..self.filename_len]);
        }
        const begin = std.mem.eql(u8, state, "printing") or std.mem.eql(u8, state, "paused") or truth(field(field(status, "gcode_macro _START_PRINT"), "print_active"));
        const stopped = std.mem.eql(u8, state, "cancelled");
        if (stopped) {
            self.printing = false;
            self.pending = false;
        }
        self.mutex.unlock(self.io);
        if (begin) self.enqueue("_timelapse_begin");
        if (stopped) self.enqueue("_timelapse_stop");
    }

    pub fn gcodeResponse(self: *Timelapse, response: []const u8) void {
        if (!self.enabled) return;
        self.mutex.lockUncancelable(self.io);
        if (std.mem.eql(u8, response, "File selected")) self.pending = true;
        const finish = std.mem.eql(u8, response, "Done printing file") and !self.finalizing;
        const generation = self.generation;
        if (finish) {
            self.printing = false;
            self.finalizing = true;
            self.final_filename_len = self.filename_len;
            @memcpy(self.final_filename[0..self.filename_len], self.filename[0..self.filename_len]);
        }
        self.mutex.unlock(self.io);
        if (finish) {
            const callback = self.queue orelse return;
            callback(self.queue_ctx orelse return, "_timelapse_finish") catch |err| {
                self.mutex.lockUncancelable(self.io);
                if (generation == self.generation) self.finalizing = false;
                self.mutex.unlock(self.io);
                std.debug.print("phobos: timelapse finalization queue: {}\n", .{err});
            };
        }
    }

    pub fn setup(self: *Timelapse, a: Allocator) !void {
        const s = try self.settingsCopy(a);
        const script = try std.fmt.allocPrint(a, "_SET_TIMELAPSE_SETUP ENABLE={s} VERBOSE={s} PARK_ENABLE={s} PARK_POS={s} CUSTOM_POS_X={d} CUSTOM_POS_Y={d} CUSTOM_POS_DZ={d} TRAVEL_SPEED={d} RETRACT_SPEED={d} EXTRUDE_SPEED={d} RETRACT_DISTANCE={d} EXTRUDE_DISTANCE={d} PARK_TIME={d} FW_RETRACT={s}", .{
            boolWord(s.enabled), boolWord(s.gcode_verbose), boolWord(s.parkhead), s.parkpos, s.park_custom_pos_x, s.park_custom_pos_y, s.park_custom_pos_dz, s.park_travel_speed, s.park_retract_speed, s.park_extrude_speed, s.park_retract_distance, s.park_extrude_distance, s.park_time, boolWord(s.fw_retract),
        });
        try self.gcode(a, script);
        try self.gcode(a, "HYPERLAPSE ACTION=STOP");
        self.mutex.lockUncancelable(self.io);
        const printing = self.printing;
        self.mutex.unlock(self.io);
        if (printing) try self.hyperlapse(a, s);
    }
    fn hyperlapse(self: *Timelapse, a: Allocator, s: Settings) !void {
        if (s.enabled and std.mem.eql(u8, s.mode, "hyperlapse") and @as(f64, @floatFromInt(s.hyperlapse_cycle)) - s.park_time >= 1)
            try self.gcode(a, try std.fmt.allocPrint(a, "HYPERLAPSE ACTION=START CYCLE={d}", .{s.hyperlapse_cycle}));
    }
    pub fn beginPrint(self: *Timelapse, a: Allocator) !void {
        if (!self.lifecycle.tryLock()) return;
        defer self.lifecycle.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        if (self.finalizing or self.operation != .idle) {
            self.mutex.unlock(self.io);
            return;
        }
        self.printing = true;
        const clean = self.pending;
        if (clean) {
            self.generation +%= 1;
            self.pending = false;
            self.framecount = 0;
            self.lastframe = 0;
            // Reserve frame ownership until cleanup completes.
            self.operation = .capture;
        }
        self.mutex.unlock(self.io);
        if (clean) {
            defer self.release();
            var dir = try self.frameDir();
            defer dir.close(self.io);
            var iterator = dir.iterate();
            while (try iterator.next(self.io)) |entry| if (frameNumber(entry.name) != null) try dir.deleteFile(self.io, entry.name);
            try self.hyperlapse(a, try self.settingsCopy(a));
        }
    }

    pub fn capture(self: *Timelapse, a: Allocator, args: Value, final: bool) !Value {
        const s = try self.settingsCopy(a);
        var parked = truth(field(args, "parked"));
        const macropark = field(args, "macropark");
        if (macropark != .null) parked = truth(if (macropark == .object) field(macropark, "enable") else macropark);
        self.mutex.lockUncancelable(self.io);
        const declined = self.pending or (!final and self.finalizing);
        self.mutex.unlock(self.io);
        if (!s.enabled or declined or (!final and std.mem.eql(u8, s.mode, "hyperlapse") and !truth(field(args, "hyperlapse")))) {
            if (parked) self.releaseParked(a);
            return self.result(a, "newframe", "skipped", "Capture declined");
        }
        const generation = self.claim(.capture) orelse {
            if (parked) self.releaseParked(a);
            return self.result(a, "newframe", "running", "Frame capture or export is running");
        };
        defer {
            if (parked and self.validGeneration(generation)) self.releaseParked(a);
            self.release();
        }
        return self.captureOwned(a, s, generation) catch |err| self.result(a, "newframe", if (err == error.Canceled) "skipped" else "error", @errorName(err));
    }
    fn releaseParked(self: *Timelapse, a: Allocator) void {
        self.gcode(a, "SET_GCODE_VARIABLE MACRO=TIMELAPSE_TAKE_FRAME VARIABLE=takingframe VALUE=False") catch |err| std.debug.print("phobos: timelapse parked acknowledgement: {}\n", .{err});
    }
    fn captureOwned(self: *Timelapse, a: Allocator, s: Settings, generation: u32) !Value {
        self.mutex.lockUncancelable(self.io);
        const count = self.framecount;
        const next = self.lastframe + 1;
        self.mutex.unlock(self.io);
        if (count >= max_frames or next > max_frame_number) return error.FrameLimit;
        var dir = try self.frameDir();
        defer dir.close(self.io);
        if (try files.availableBytes(dir) < reserve_bytes + max_snapshot_bytes) return error.InsufficientSpace;
        const name = try frameName(a, next);
        var atomic = try dir.createFileAtomic(self.io, name, .{ .replace = true });
        defer atomic.deinit(self.io);
        const Task = union(enum) { capture: anyerror!void, canceled: Io.Cancelable!void, deadline: Io.Cancelable!void };
        var buffer: [3]Task = undefined;
        var tasks = Io.Select(Task).init(self.io, &buffer);
        defer while (tasks.cancel()) |_| {};
        try tasks.concurrent(.capture, delayedSnapshot, .{ self, a, s, atomic.file });
        try tasks.concurrent(.canceled, Io.Event.wait, .{ &self.cancel, self.io });
        try tasks.concurrent(.deadline, Io.Timeout.sleep, .{ Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(@intFromFloat((s.stream_delay_compensation + snapshot_timeout_seconds) * 1000)), .clock = .awake } }, self.io });
        switch (try tasks.await()) {
            .capture => |done| try done,
            .canceled => return error.Canceled,
            .deadline => return error.Timeout,
        }
        const size = (try atomic.file.stat(self.io)).size;
        if (size == 0 or size > max_snapshot_bytes) return error.InvalidSnapshot;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (generation != self.generation) return error.Canceled;
        try atomic.link(self.io);
        self.framecount += 1;
        self.lastframe = next;
        const value = try json(a, .{ .action = "newframe", .status = "success", .frame = try std.fmt.allocPrint(a, "{d}", .{self.framecount}), .framefile = name });
        // Emit after releasing state; Core callbacks may inspect it.
        self.mutex.unlock(self.io);
        self.emit(a, value);
        self.mutex.lockUncancelable(self.io);
        return value;
    }

    fn idleStatus(self: *Timelapse, a: Allocator) !Value {
        const status = try self.query(a, .{ .print_stats = @as(?bool, null), .virtual_sdcard = @as(?bool, null), .timelapse_state = &.{"phase"} });
        const state = string(field(field(status, "print_stats"), "state"));
        const active = field(field(status, "virtual_sdcard"), "is_active");
        if (active != .bool or active.bool) return error.PrinterNotIdle;
        self.mutex.lockUncancelable(self.io);
        const finishing = self.finalizing;
        self.mutex.unlock(self.io);
        if (!std.mem.eql(u8, state, "complete") and !std.mem.eql(u8, state, "cancelled") and !std.mem.eql(u8, state, "standby") and !(finishing and std.mem.eql(u8, state, "paused") and std.mem.eql(u8, string(field(field(status, "timelapse_state"), "phase")), "WAITING"))) return error.PrinterNotIdle;
        return status;
    }

    pub fn render(self: *Timelapse, a: Allocator, args: Value) !Value {
        const macro = truth(field(args, "byrendermacro"));
        defer if (macro) self.gcode(a, "SET_GCODE_VARIABLE MACRO=TIMELAPSE_RENDER VARIABLE=render VALUE=False") catch |err| std.debug.print("phobos: timelapse render acknowledgement: {}\n", .{err});
        const generation = self.claim(.render) orelse return self.result(a, "render", "running", "Capture or export is running");
        defer self.release();
        return self.renderOwned(a, generation) catch |err| blk: {
            self.console(a, "// Timelapse: video generation failed");
            break :blk self.result(a, "render", if (err == error.Canceled) "skipped" else "error", @errorName(err));
        };
    }

    fn renderOwned(self: *Timelapse, a: Allocator, generation: u32) !Value {
        const status = try self.idleStatus(a);
        const s = try self.settingsCopy(a);
        var dir = try self.frameDir();
        defer dir.close(self.io);
        const frames = try self.frameList(a, dir);
        if (frames.len == 0) return self.result(a, "render", "skipped", "no frames to render, skip");
        if (frames.len + @as(usize, @intCast(s.duplicatelastframe)) > max_frames) return error.FrameLimit;
        var out = try Io.Dir.cwd().openDir(self.io, self.output_path, .{});
        defer out.close(self.io);
        try self.checkSpace(out, dir, frames);
        const base = try self.outputName(a, out, status, s.time_format_code, ".mp4");
        const video_name = try std.fmt.allocPrint(a, "{s}.mp4", .{base});
        const preview_name = try std.fmt.allocPrint(a, "{s}.jpg", .{base});
        var video = try out.createFileAtomic(self.io, video_name, .{ .replace = true });
        defer video.deinit(self.io);
        const video_path = try std.fs.path.join(a, &.{ self.output_path, &std.fmt.hex(video.file_basename_hex) });
        const last = frames[frames.len - 1];
        if (frameNumber(last).? + @as(u32, @intCast(s.duplicatelastframe)) > max_frame_number) return error.FrameLimit;
        {
            const input = try dir.openFile(self.io, last, .{ .allow_directory = false, .follow_symlinks = false });
            defer input.close(self.io);
            const duplicates_bytes = (try input.stat(self.io)).size * @as(u64, @intCast(s.duplicatelastframe));
            if (try files.availableBytes(dir) < reserve_bytes + duplicates_bytes) return error.InsufficientSpace;
        }
        var duplicates: std.ArrayList([]const u8) = .empty;
        defer for (duplicates.items) |name| {
            dir.deleteFile(self.io, name) catch |err| std.debug.print("phobos: timelapse duplicate cleanup: {}\n", .{err});
        };
        for (0..@intCast(s.duplicatelastframe)) |index| {
            if (!self.validGeneration(generation)) return error.Canceled;
            const name = try frameName(a, frameNumber(last).? + @as(u32, @intCast(index)) + 1);
            // Exclusive creation protects recovered frames and another writer.
            try self.copyFrame(a, dir, last, dir, name);
            try duplicates.append(a, name);
        }
        const framecount = frames.len + duplicates.items.len;
        const fps = if (s.variable_fps) std.math.clamp(@divTrunc(@as(i64, @intCast(framecount)), s.targetlength), s.variable_fps_min, s.variable_fps_max) else s.output_framerate;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostats", "-r", try std.fmt.allocPrint(a, "{d}", .{fps}), "-start_number", try std.fmt.allocPrint(a, "{d}", .{frameNumber(frames[0]).?}), "-i", try std.fs.path.join(a, &.{ self.frame_path, "frame%06d.jpg" }) });
        const filter = try videoFilter(a, s);
        if (filter.len != 0) try argv.appendSlice(a, &.{ "-vf", filter });
        try argv.appendSlice(a, &.{ "-threads", "1", "-preset", "ultrafast", "-g", "5", "-crf", try std.fmt.allocPrint(a, "{d}", .{s.constant_rate_factor}), "-vcodec", "libx264", "-pix_fmt", s.pixelformat, "-an" });
        try argv.appendSlice(a, try extraArguments(a, s.extraoutputparams));
        try argv.appendSlice(a, &.{ "-f", "mp4", video_path, "-y" });
        const started = try json(a, .{ .action = "render", .status = "started", .framecount = try std.fmt.allocPrint(a, "{d}", .{framecount}), .settings = .{ .framerate = fps, .crf = s.constant_rate_factor, .pixelformat = s.pixelformat } });
        self.emit(a, started);
        self.console(a, "// Timelapse: video generation started");
        const output = try self.runCancelable(a, argv.items);
        if (output.term != .exited or output.term.exited != 0) {
            var failed = try json(a, .{ .action = "render", .status = "error", .msg = "FFmpeg failed" });
            try failed.object.put(a, "cmd", .{ .string = try std.mem.join(a, " ", argv.items) });
            const tail = output.stderr[output.stderr.len - @min(output.stderr.len, 1024) ..];
            try failed.object.put(a, "ffmpeg", .{ .string = try safeOutput(a, tail) });
            self.emit(a, failed);
            return failed;
        }
        try self.checkCandidate(out, &video);
        var preview = try out.createFileAtomic(self.io, preview_name, .{ .replace = true });
        defer preview.deinit(self.io);
        const preview_path = try std.fs.path.join(a, &.{ self.output_path, &std.fmt.hex(preview.file_basename_hex) });
        if (s.previewimage) {
            var preview_argv: std.ArrayList([]const u8) = .empty;
            try preview_argv.appendSlice(a, &.{ self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostats", "-i", try std.fs.path.join(a, &.{ self.frame_path, last }) });
            if (filter.len != 0) try preview_argv.appendSlice(a, &.{ "-vf", filter });
            try preview_argv.appendSlice(a, &.{ "-frames:v", "1", "-update", "1", "-threads", "1", "-an", "-f", "image2", preview_path, "-y" });
            const thumbnail = try self.runCancelable(a, preview_argv.items);
            if (thumbnail.term != .exited or thumbnail.term.exited != 0) return error.PreviewFailed;
        } else {
            const input = try dir.openFile(self.io, last, .{ .allow_directory = false, .follow_symlinks = false });
            defer input.close(self.io);
            try copyContents(self.io, input, preview.file);
        }
        try self.checkCandidate(out, &preview);
        _ = try self.idleStatus(a);
        self.mutex.lockUncancelable(self.io);
        if (generation != self.generation) {
            self.mutex.unlock(self.io);
            return error.Canceled;
        }
        // Both candidates are complete before either name becomes visible.
        preview.link(self.io) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        video.link(self.io) catch |err| {
            out.deleteFile(self.io, preview_name) catch |cleanup| std.debug.print("phobos: timelapse preview cleanup: {}\n", .{cleanup});
            self.mutex.unlock(self.io);
            return err;
        };
        const printfile = blk: {
            defer self.mutex.unlock(self.io);
            break :blk try a.dupe(u8, if (self.finalizing and self.final_filename_len != 0) self.final_filename[0..self.final_filename_len] else string(field(field(status, "print_stats"), "filename")));
        };
        const value = try json(a, .{ .action = "render", .status = "success", .filename = video_name, .printfile = printfile, .msg = try std.fmt.allocPrint(a, "Rendering Video successful: {s}", .{video_name}) });
        self.emit(a, value);
        self.console(a, "// Timelapse: video generation finished");
        return value;
    }

    fn checkCandidate(self: *Timelapse, dir: Io.Dir, candidate: *Io.File.Atomic) !void {
        const file = try dir.openFile(self.io, &std.fmt.hex(candidate.file_basename_hex), .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size == 0 or stat.inode != (try candidate.file.stat(self.io)).inode) return error.InvalidOutput;
        try file.sync(self.io);
    }
    fn copyFrame(self: *Timelapse, a: Allocator, source_dir: Io.Dir, source: []const u8, dest_dir: Io.Dir, dest: []const u8) !void {
        _ = a;
        const input = try source_dir.openFile(self.io, source, .{ .allow_directory = false, .follow_symlinks = false });
        defer input.close(self.io);
        var output = try dest_dir.createFileAtomic(self.io, dest, .{ .replace = true });
        defer output.deinit(self.io);
        try copyContents(self.io, input, output.file);
        try output.file.sync(self.io);
        try output.link(self.io);
    }
    fn runCancelable(self: *Timelapse, a: Allocator, argv: []const []const u8) !std.process.RunResult {
        const Task = union(enum) { child: anyerror!std.process.RunResult, canceled: Io.Cancelable!void };
        var buffer: [2]Task = undefined;
        var tasks = Io.Select(Task).init(self.io, &buffer);
        defer while (tasks.cancel()) |done| {
            if (done == .child) if (done.child) |output| {
                a.free(output.stdout);
                a.free(output.stderr);
            } else |_| {};
        };
        const options: std.process.RunOptions = .{ .argv = argv, .stdout_limit = .limited(max_command_output), .stderr_limit = .limited(max_command_output), .timeout = .{ .deadline = .fromNow(self.io, .{ .raw = .fromMilliseconds(@intFromFloat(self.render_timeout * 1000)), .clock = .awake }) } };
        try tasks.concurrent(.child, runCommand, .{ self, a, options });
        try tasks.concurrent(.canceled, Io.Event.wait, .{ &self.cancel, self.io });
        return switch (try tasks.await()) {
            .child => |output| output,
            .canceled => error.Canceled,
        };
    }

    pub fn finishPrint(self: *Timelapse, a: Allocator) !void {
        self.lifecycle.lockUncancelable(self.io);
        defer self.lifecycle.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        const cleanup = self.finalizing and self.pending and self.operation == .idle;
        if (cleanup) {
            self.generation +%= 1;
            self.pending = false;
            self.framecount = 0;
            self.lastframe = 0;
            self.operation = .capture;
        }
        const generation = self.generation;
        const finishing = self.finalizing;
        self.mutex.unlock(self.io);
        if (!finishing) return;
        defer {
            self.mutex.lockUncancelable(self.io);
            if (self.generation == generation) self.finalizing = false;
            self.mutex.unlock(self.io);
            self.enqueue("_timelapse_begin");
        }
        if (cleanup) {
            defer self.release();
            var dir = try self.frameDir();
            defer dir.close(self.io);
            var iterator = dir.iterate();
            while (try iterator.next(self.io)) |entry| if (frameNumber(entry.name) != null) try dir.deleteFile(self.io, entry.name);
        }
        try self.gcode(a, "HYPERLAPSE ACTION=STOP");
        const s = try self.settingsCopy(a);
        if (!s.enabled) return;
        for (0..finish_wait_steps) |_| {
            self.mutex.lockUncancelable(self.io);
            const capture_running = self.operation == .capture;
            self.mutex.unlock(self.io);
            if (!self.validGeneration(generation)) return;
            if (!capture_running) break;
            try Io.sleep(self.io, .fromMilliseconds(finish_wait_ms), .awake);
        }
        if (!self.validGeneration(generation)) return;
        const status = self.query(a, .{ .mod_params = &.{"variables"}, .@"gcode_macro _TIMELAPSE_LAYER_CAPTURE" = &.{"last_layer"}, .@"gcode_macro TIMELAPSE_PRINT" = &.{"enable"} }) catch .null;
        const variables = field(field(status, "mod_params"), "variables");
        const print_enable = field(field(status, "gcode_macro TIMELAPSE_PRINT"), "enable");
        const capture_enabled = print_enable == .null or truth(print_enable);
        const last_layer = field(field(status, "gcode_macro _TIMELAPSE_LAYER_CAPTURE"), "last_layer");
        self.mutex.lockUncancelable(self.io);
        const no_frames = self.framecount == 0;
        const capture_busy = self.operation == .capture;
        self.mutex.unlock(self.io);
        if (capture_busy) return;
        if (truth(field(variables, "timelapse")) and capture_enabled) {
            if (no_frames and std.mem.eql(u8, string(field(variables, "timelapse_mode")), "LAYER") and (last_layer == .null or (last_layer == .integer and last_layer.integer == 0))) self.console(a, "!! Timelapse: no layer updates were received. Configure SET_PRINT_STATS_INFO in the slicer or choose time/progress capture.");
            if (truth(field(variables, "timelapse_final_frame"))) _ = try self.capture(a, .null, true);
        }
        if (!self.validGeneration(generation)) return;
        if (s.saveframes) _ = try self.save(a);
        if (s.autorender and self.validGeneration(generation)) _ = try self.render(a, .null);
    }

    pub fn remote(self: *Timelapse, a: Allocator, method: []const u8, args: Value) !void {
        if (!self.enabled) return;
        if (std.mem.eql(u8, method, "timelapse_cancel_render")) {
            self.cancelOperation();
            return;
        }
        if (std.mem.eql(u8, method, "timelapse_newframe")) {
            _ = try self.capture(a, args, false);
            return;
        }
        if (std.mem.eql(u8, method, "timelapse_render")) {
            _ = try self.render(a, args);
            return;
        }
        if (std.mem.eql(u8, method, "timelapse_saveFrames")) {
            _ = try self.save(a);
            return;
        }
        if (std.mem.eql(u8, method, "_timelapse_setup")) return self.setup(a);
        if (std.mem.eql(u8, method, "_timelapse_finish")) return self.finishPrint(a);
        if (std.mem.eql(u8, method, "_timelapse_stop")) return self.gcode(a, "HYPERLAPSE ACTION=STOP");
        if (std.mem.eql(u8, method, "_timelapse_begin")) {
            const status = try self.query(a, .{ .print_stats = &.{ "state", "filename" }, .@"gcode_macro _START_PRINT" = &.{"print_active"} });
            const state = string(field(field(status, "print_stats"), "state"));
            if (std.mem.eql(u8, state, "printing") or std.mem.eql(u8, state, "paused") or truth(field(field(status, "gcode_macro _START_PRINT"), "print_active"))) {
                const filename = string(field(field(status, "print_stats"), "filename"));
                self.mutex.lockUncancelable(self.io);
                if (!self.finalizing and filename.len != 0) {
                    self.filename_len = @min(filename.len, self.filename.len);
                    @memcpy(self.filename[0..self.filename_len], filename[0..self.filename_len]);
                }
                self.mutex.unlock(self.io);
                try self.beginPrint(a);
            }
        }
    }

    pub fn save(self: *Timelapse, a: Allocator) !Value {
        const generation = self.claim(.save) orelse return self.result(a, "saveframes", "running", "Capture or export is running");
        defer self.release();
        return self.exportFrames(a, generation) catch |err| self.result(a, "saveframes", if (err == error.Canceled) "skipped" else "error", @errorName(err));
    }
    fn exportFrames(self: *Timelapse, a: Allocator, generation: u32) !Value {
        const status = try self.idleStatus(a);
        const s = try self.settingsCopy(a);
        var dir = try self.frameDir();
        defer dir.close(self.io);
        const frames = try self.frameList(a, dir);
        if (frames.len == 0) return self.result(a, "saveframes", "skipped", "no frames to save");
        var out = try Io.Dir.cwd().openDir(self.io, self.output_path, .{});
        defer out.close(self.io);
        try self.checkSpace(out, dir, frames);
        const base = try self.outputName(a, out, status, s.time_format_code, "_frames.zip");
        const name = try std.fmt.allocPrint(a, "{s}_frames.zip", .{base});
        var atomic = try out.createFileAtomic(self.io, name, .{ .replace = true });
        defer atomic.deinit(self.io);
        var buffer: [32768]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        var archive = @import("../zip_writer.zig").Archive.init(a, &writer, true);
        defer archive.deinit();
        for (frames) |frame| {
            try Io.checkCancel(self.io);
            if (!self.validGeneration(generation)) return error.Canceled;
            const input = try dir.openFile(self.io, frame, .{ .allow_directory = false, .follow_symlinks = false });
            defer input.close(self.io);
            try archive.addFile(input, frame);
        }
        try archive.finish();
        try writer.end();
        try atomic.file.sync(self.io);
        _ = try self.idleStatus(a);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (generation != self.generation) return error.Canceled;
        try atomic.link(self.io);
        const value = try json(a, .{ .action = "saveframes", .status = "finished", .zipfile = name });
        self.mutex.unlock(self.io);
        self.emit(a, value);
        self.mutex.lockUncancelable(self.io);
        return value;
    }

    fn frameList(self: *Timelapse, a: Allocator, dir: Io.Dir) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (frameNumber(entry.name) == null) continue;
            if (entry.kind != .file or list.items.len == max_frames) return error.InvalidFrameDirectory;
            try list.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, list.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        return list.toOwnedSlice(a);
    }
    fn checkSpace(self: *Timelapse, out: Io.Dir, dir: Io.Dir, frames: []const []const u8) !void {
        var bytes: u64 = reserve_bytes;
        for (frames) |name| {
            const file = try dir.openFile(self.io, name, .{ .allow_directory = false, .follow_symlinks = false });
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            if (stat.kind != .file or stat.size > max_snapshot_bytes) return error.InvalidSnapshot;
            bytes += stat.size;
        }
        if (try files.availableBytes(out) < bytes) return error.InsufficientSpace;
    }
    fn outputName(self: *Timelapse, a: Allocator, dir: Io.Dir, status: Value, format: []const u8, suffix: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        const printfile = blk: {
            defer self.mutex.unlock(self.io);
            break :blk try a.dupe(u8, if (self.finalizing and self.final_filename_len != 0) self.final_filename[0..self.final_filename_len] else string(field(field(status, "print_stats"), "filename")));
        };
        const filename = std.fs.path.stem(std.fs.path.basename(printfile));
        var safe: [128]u8 = undefined;
        const count = @min(filename.len, safe.len);
        for (filename[0..count], 0..) |byte, i| safe[i] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') byte else '_';
        var time: [128]u8 = undefined;
        const time_len = phobos_local_strftime(clock.wallSecondsInt(self.io), &time, time.len, try a.dupeSentinel(u8, format, 0));
        if (time_len == 0) return error.InvalidTimeFormat;
        if (std.mem.indexOfAny(u8, time[0..time_len], "/\\\r\n\x00") != null) return error.InvalidTimeFormat;
        const stem = try std.fmt.allocPrint(a, "timelapse_{s}_{s}", .{ safe[0..count], time[0..time_len] });
        for (0..max_collision_attempts) |index| {
            const candidate = if (index == 0) stem else try std.fmt.allocPrint(a, "{s}_{d}", .{ stem, index + 1 });
            const name = try std.fmt.allocPrint(a, "{s}{s}", .{ candidate, suffix });
            dir.access(self.io, name, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const preview = try std.fmt.allocPrint(a, "{s}.jpg", .{candidate});
                    dir.access(self.io, preview, .{}) catch |preview_err| switch (preview_err) {
                        error.FileNotFound => return candidate,
                        else => return preview_err,
                    };
                    continue;
                },
                else => return err,
            };
        }
        return error.PathAlreadyExists;
    }
};

fn boolWord(value: bool) []const u8 {
    return if (value) "True" else "False";
}
fn expandedPath(a: Allocator, path: []const u8, datadir: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(a, &.{ home, path[2..] });
    return std.fs.path.resolve(a, &.{ datadir, path });
}
fn frameNumber(name: []const u8) ?u32 {
    if (name.len != "frame000001.jpg".len or !std.mem.startsWith(u8, name, "frame") or !std.mem.endsWith(u8, name, ".jpg")) return null;
    for (name[5..11]) |byte| if (!std.ascii.isDigit(byte)) return null;
    const n = std.fmt.parseInt(u32, name[5..11], 10) catch return null;
    return if (n == 0) null else n;
}
fn frameName(a: Allocator, number: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "frame{d:0>6}.jpg", .{number});
}
fn copyContents(io: Io, input: Io.File, output: Io.File) !void {
    var read_buffer: [32768]u8 = undefined;
    var reader = input.reader(io, &read_buffer);
    var write_buffer: [32768]u8 = undefined;
    var writer = output.writer(io, &write_buffer);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.end();
}
fn videoFilter(a: Allocator, s: Settings) ![]const u8 {
    return switch (s.rotation) {
        90 => if (s.flip_y) "transpose=3" else "transpose=1",
        180 => "hflip,vflip",
        270 => if (s.flip_y) "transpose=0" else "transpose=2",
        0 => if (s.flip_x and s.flip_y) "hflip,vflip" else if (s.flip_x) "hflip" else if (s.flip_y) "vflip" else "",
        else => try std.fmt.allocPrint(a, "rotate={d}", .{@as(f64, @floatFromInt(s.rotation)) * std.math.pi / 180}),
    };
}
fn safeOutput(a: Allocator, text: []const u8) ![]const u8 {
    const copy = try a.dupe(u8, text);
    for (copy) |*byte| if (byte.* < 32 and byte.* != '\n' and byte.* != '\t') {
        byte.* = ' ';
    };
    if (!std.unicode.utf8ValidateSlice(copy)) for (copy) |*byte| {
        if (byte.* >= 128) byte.* = '?';
    };
    return copy;
}
fn extraArguments(a: Allocator, text: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var escape = false;
    var started = false;
    for (text) |byte| {
        if (escape) {
            try word.append(a, byte);
            escape = false;
            started = true;
            continue;
        }
        if (byte == '\\' and quote != '\'') {
            escape = true;
            started = true;
            continue;
        }
        if (quote) |q| {
            if (byte == q) quote = null else try word.append(a, byte);
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            started = true;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) {
            if (started) {
                if (result.items.len == max_extra_arguments) return error.TooManyArguments;
                try result.append(a, try word.toOwnedSlice(a));
                started = false;
            }
        } else {
            try word.append(a, byte);
            started = true;
        }
    }
    if (escape or quote != null) return error.InvalidParams;
    if (started) {
        if (result.items.len == max_extra_arguments) return error.TooManyArguments;
        try result.append(a, try word.toOwnedSlice(a));
    }
    return result.toOwnedSlice(a);
}
fn runProcess(_: ?*anyopaque, a: Allocator, io: Io, options: std.process.RunOptions) !std.process.RunResult {
    return process.run(a, io, options);
}
fn runCommand(self: *Timelapse, a: Allocator, options: std.process.RunOptions) !std.process.RunResult {
    return self.run(self.run_ctx, a, self.io, options);
}
fn delayedSnapshot(self: *Timelapse, a: Allocator, s: Settings, output: Io.File) !void {
    try Io.sleep(self.io, .fromMilliseconds(@intFromFloat(s.stream_delay_compensation * 1000)), .awake);
    try self.snapshot(self.snapshot_ctx, a, self.io, s.snapshoturl, output);
}
fn downloadSnapshot(_: ?*anyopaque, a: Allocator, io: Io, url: []const u8, output: Io.File) !void {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var req = try client.request(.GET, try std.Uri.parse(url), .{ .headers = http_get.identity_headers, .keep_alive = false, .redirect_behavior = @fromBackingInt(3) });
    defer req.deinit();
    req.accept_encoding = http_get.identity_only;
    try req.sendBodiless();
    var head: [8192]u8 = undefined;
    var response = try req.receiveHead(&head);
    if (response.head.status.class() != .success) return error.HttpStatus;
    var transfer: [16384]u8 = undefined;
    const reader = response.reader(&transfer);
    var limited = reader.limited(.limited(max_snapshot_bytes), &.{});
    var output_buffer: [32768]u8 = undefined;
    var writer = output.writer(io, &output_buffer);
    const size = try limited.interface.streamRemaining(&writer.interface);
    if (size == 0) return error.InvalidSnapshot;
    _ = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => {
            try writer.end();
            try output.sync(io);
            return;
        },
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
    };
    return error.SnapshotTooLarge;
}
extern "c" fn phobos_local_strftime(seconds: i64, buffer: [*]u8, capacity: usize, format: [*:0]const u8) usize;

pub fn handleSettings(raw: *anyopaque, args: Value, a: Allocator) anyerror!Value {
    const self: *Timelapse = @ptrCast(@alignCast(raw));
    if (!self.enabled) return error.NotReady;
    self.lifecycle.lockUncancelable(self.io);
    defer self.lifecycle.unlock(self.io);
    const post = std.mem.eql(u8, string(field(args, "_method")), "POST");
    var owned = std.heap.ArenaAllocator.init(self.gpa);
    defer owned.deinit();
    var s = try self.settingsCopy(owned.allocator());
    if (post) {
        inline for (comptime std.meta.fieldNames(Settings), 0..) |name, index| {
            const T = @FieldType(Settings, name);
            if (!std.mem.eql(u8, name, "snapshoturl") and !self.blocked[index]) {
                if (try params.optional(T, args, name)) |v| @field(s, name) = if (T == []const u8) try owned.allocator().dupe(u8, v) else v;
            }
        }
        try validate(s);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.store) |db| try db.insertItem(a, "timelapse", "config", try json(a, s));
        if (self.settings_arena) |*previous| previous.deinit();
        self.settings_arena = owned;
        owned = std.heap.ArenaAllocator.init(self.gpa);
        self.settings = s;
        self.enqueue("_timelapse_setup");
    }
    var result = try json(a, s);
    var blocked: std.json.Array = .init(a);
    inline for (comptime std.meta.fieldNames(Settings), 0..) |name, index| if (self.blocked[index]) try blocked.append(.{ .string = name });
    try result.object.put(a, "blockedsettings", .{ .array = blocked });
    return result;
}

pub fn handleInfo(raw: *anyopaque, _: Value, a: Allocator) anyerror!Value {
    const self: *Timelapse = @ptrCast(@alignCast(raw));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return json(a, .{ .framecount = self.framecount, .lastframefile = if (self.lastframe == 0) "" else try frameName(a, self.lastframe), .rendering = self.operation == .render, .busy = self.operation != .idle or self.finalizing });
}
pub fn handleSave(raw: *anyopaque, _: Value, a: Allocator) anyerror!Value {
    const self: *Timelapse = @ptrCast(@alignCast(raw));
    if (!self.enabled) return error.NotReady;
    return self.save(a);
}
pub fn handleRender(raw: *anyopaque, args: Value, a: Allocator) anyerror!Value {
    const self: *Timelapse = @ptrCast(@alignCast(raw));
    if (!self.enabled) return error.NotReady;
    return self.render(a, args);
}
pub fn register(reg: *registry.Registry, self: *Timelapse) !void {
    try reg.registerEndpoint(.{ .path = "/machine/timelapse/settings", .methods = &.{ .GET, .POST }, .off_core = true }, self, handleSettings);
    try reg.registerEndpoint(.{ .path = "/machine/timelapse/lastframeinfo", .methods = &.{.GET}, .off_core = true }, self, handleInfo);
    try reg.registerEndpoint(.{ .path = "/machine/timelapse/saveframes", .methods = &.{.POST}, .off_core = true }, self, handleSave);
    try reg.registerEndpoint(.{ .path = "/machine/timelapse/render", .methods = &.{.POST}, .off_core = true }, self, handleRender);
}

const Fixture = struct {
    allocator: std.heap.DebugAllocator(.{}) = .init,
    tmp: std.testing.TmpDir,
    ctx: Timelapse,
    rpc_calls: usize = 0,
    parked_releases: usize = 0,
    render_releases: usize = 0,
    start_hyperlapse: usize = 0,
    fail_snapshot: bool = false,
    fail_encoder: bool = false,
    printing: bool = false,
    cancel_encoder: bool = false,
    cancel_snapshot: bool = false,
    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .ctx = undefined };
        errdefer {
            self.tmp.cleanup();
            _ = self.allocator.deinit();
            std.testing.allocator.destroy(self);
        }
        const a = self.allocator.allocator();
        const io = std.testing.io;
        const root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        var cfg = config.ConfigParser.init(a);
        defer cfg.deinit();
        try cfg.parseString("[timelapse]\nframe_path: frames\noutput_path: output\nffmpeg_binary_path: missing-encoder\nstream_delay_compensation: 0\ntime_format_code: test\n", "timelapse-fixture");
        self.ctx = .{ .gpa = a, .io = io, .rpc = rpc, .rpc_ctx = self, .run = encoder, .run_ctx = self, .snapshot = snapshot, .snapshot_ctx = self };
        errdefer self.ctx.deinit();
        try self.ctx.configure(&cfg, root, root);
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.tmp.cleanup();
        std.testing.expectEqual(.ok, self.allocator.deinit()) catch @panic("timelapse fixture leaked");
        std.testing.allocator.destroy(self);
    }
    fn rpc(raw: *anyopaque, a: Allocator, method: []const u8, args: Value) !Value {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.rpc_calls += 1;
        if (std.mem.eql(u8, method, "objects/query")) return json(a, .{ .status = .{
            .print_stats = .{ .state = if (self.printing) "printing" else "complete", .filename = "folder/part.gcode" },
            .virtual_sdcard = .{ .is_active = self.printing },
            .timelapse_state = .{ .phase = "WAITING" },
            .mod_params = .{ .variables = .{ .timelapse = true, .timelapse_final_frame = true } },
            .@"gcode_macro TIMELAPSE_PRINT" = .{ .enable = true },
        } });
        const script = string(field(args, "script"));
        if (std.mem.indexOf(u8, script, "MACRO=TIMELAPSE_TAKE_FRAME") != null) self.parked_releases += 1;
        if (std.mem.indexOf(u8, script, "MACRO=TIMELAPSE_RENDER") != null) self.render_releases += 1;
        if (std.mem.startsWith(u8, script, "HYPERLAPSE ACTION=START")) self.start_hyperlapse += 1;
        return .null;
    }
    fn snapshot(raw: ?*anyopaque, _: Allocator, io: Io, _: []const u8, file: Io.File) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.cancel_snapshot) {
            self.ctx.cancelOperation();
            try Io.sleep(io, .fromSeconds(5), .awake);
        }
        if (self.fail_snapshot) return error.CameraOffline;
        try file.writeStreamingAll(io, "\xff\xd8jpeg\xff\xd9");
    }
    fn encoder(raw: ?*anyopaque, a: Allocator, io: Io, options: std.process.RunOptions) !std.process.RunResult {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.cancel_encoder) self.ctx.cancelOperation();
        if (!self.fail_encoder) {
            const path = options.argv[options.argv.len - 2];
            const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only, .follow_symlinks = false });
            defer file.close(io);
            try file.writeStreamingAll(io, "encoded");
        }
        return .{ .term = .{ .exited = if (self.fail_encoder) 1 else 0 }, .stdout = try a.dupe(u8, ""), .stderr = try a.dupe(u8, "encoder stderr") };
    }
};

test "timelapse captures, restores frame count, exports ZIP and renders collision-safe files" {
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const captured = try f.ctx.capture(a, .null, false);
    try std.testing.expectEqualStrings("success", string(field(captured, "status")));
    try std.testing.expectEqualStrings("frame000001.jpg", string(field(captured, "framefile")));
    try std.testing.expectEqual(@as(usize, 0), f.parked_releases);
    {
        const root = try f.tmp.dir.realPathFileAlloc(f.ctx.io, ".", a);
        var cfg = config.ConfigParser.init(a);
        defer cfg.deinit();
        try cfg.parseString("[timelapse]\nframe_path: frames\noutput_path: output\n", "restored");
        var restored: Timelapse = .{ .gpa = f.allocator.allocator(), .io = f.ctx.io };
        defer restored.deinit();
        try restored.configure(&cfg, root, root);
        try std.testing.expectEqual(@as(u32, 1), restored.framecount);
        try std.testing.expectEqual(@as(u32, 1), restored.lastframe);
    }
    const info = try handleInfo(&f.ctx, .null, a);
    try std.testing.expectEqual(@as(i64, 1), field(info, "framecount").integer);
    try std.testing.expect(!field(info, "busy").bool);
    const saved = try handleSave(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("finished", string(field(saved, "status")));
    const archive = try Io.Dir.cwd().openFile(f.ctx.io, try std.fs.path.join(a, &.{ f.ctx.output_path, string(field(saved, "zipfile")) }), .{});
    defer archive.close(f.ctx.io);
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(f.ctx.io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    const entry = (try iterator.next()).?;
    var name_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("frame000001.jpg", try entry.getFilename(&reader, &name_buffer, .{}));
    try std.testing.expectEqual(@as(u64, 8), entry.uncompressed_size);
    const rendered = try handleRender(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("success", string(field(rendered, "status")));
    const rendered_again = try handleRender(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("timelapse_part_test_2.mp4", string(field(rendered_again, "filename")));
    var dir = try f.ctx.frameDir();
    defer dir.close(f.ctx.io);
    try std.testing.expectEqual(@as(usize, 1), (try f.ctx.frameList(a, dir)).len);
    try std.testing.expectEqualStrings("success", string(field(rendered_again, "status")));
}

test "timelapse failures release macros and preserve frames and existing outputs" {
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parked = try json(a, .{ .macropark = .{ .enable = true } });
    f.ctx.settings.enabled = false;
    _ = try f.ctx.capture(a, parked, false);
    try std.testing.expectEqual(@as(usize, 1), f.parked_releases);
    f.ctx.settings.enabled = true;
    f.fail_snapshot = true;
    const failed = try f.ctx.capture(a, parked, false);
    try std.testing.expectEqualStrings("error", string(field(failed, "status")));
    try std.testing.expectEqual(@as(u32, 0), f.ctx.framecount);
    try std.testing.expectEqual(@as(usize, 2), f.parked_releases);
    f.fail_snapshot = false;
    _ = try f.ctx.capture(a, .null, false);
    f.printing = true;
    const busy = try handleRender(&f.ctx, try json(a, .{ .byrendermacro = true }), a);
    try std.testing.expectEqualStrings("error", string(field(busy, "status")));
    try std.testing.expectEqual(@as(usize, 1), f.render_releases);
    f.printing = false;
    f.fail_encoder = true;
    const encoder_failed = try handleRender(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("error", string(field(encoder_failed, "status")));
    try std.testing.expectEqualStrings("encoder stderr", string(field(encoder_failed, "ffmpeg")));
    f.fail_encoder = false;
    f.cancel_encoder = true;
    const canceled = try handleRender(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("skipped", string(field(canceled, "status")));
    var dir = try f.ctx.frameDir();
    defer dir.close(f.ctx.io);
    try std.testing.expectEqual(@as(usize, 1), (try f.ctx.frameList(a, dir)).len);
    try std.testing.expectEqual(@as(u32, 1), f.ctx.framecount);
}

test "timelapse settings validate, persist typed values and protect configured fields" {
    const f = try Fixture.init();
    defer f.deinit();
    var db = try @import("../store/sqlite_store.zig").SqliteStore.open(std.testing.io, ":memory:");
    defer db.deinit();
    f.ctx.store = db.dataStore();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const updated = try handleSettings(&f.ctx, try json(a, .{ ._method = "POST", .output_framerate = "24", .flip_x = true, .time_format_code = "changed", .snapshoturl = "http://wrong/" }), a);
    try std.testing.expectEqual(@as(i64, 24), field(updated, "output_framerate").integer);
    try std.testing.expectEqualStrings("test", string(field(updated, "time_format_code")));
    try std.testing.expectEqualStrings("http://localhost:8080/?action=snapshot", string(field(updated, "snapshoturl")));
    try std.testing.expect(field(updated, "flip_x").bool);
    const persisted = (try db.dataStore().getItem(a, "timelapse", "config.output_framerate")).?;
    try std.testing.expectEqual(@as(i64, 24), persisted.integer);
    try std.testing.expectError(error.InvalidParams, handleSettings(&f.ctx, try json(a, .{ ._method = "POST", .targetlength = 0 }), a));
    try std.testing.expectEqual(@as(i64, 10), f.ctx.settings.targetlength);
    try std.testing.expectError(error.InvalidParams, handleSettings(&f.ctx, try json(a, .{ ._method = "POST", .parkpos = "left\nM112" }), a));
}

test "timelapse session selection preserves frames until printing and finalization captures the last frame" {
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try f.ctx.capture(a, .null, false);
    f.ctx.gcodeResponse("File selected");
    try std.testing.expectEqual(@as(u32, 1), f.ctx.framecount);
    try f.ctx.beginPrint(a);
    try std.testing.expectEqual(@as(u32, 0), f.ctx.framecount);
    f.ctx.gcodeResponse("Done printing file");
    try f.ctx.finishPrint(a);
    try std.testing.expect(!f.ctx.finalizing);
    try std.testing.expectEqual(@as(u32, 1), f.ctx.framecount);
    try f.ctx.setup(a);
    f.ctx.gcodeResponse("File selected");
    f.ctx.gcodeResponse("Done printing file");
    try f.ctx.finishPrint(a);
    try std.testing.expectEqual(@as(u32, 1), f.ctx.framecount);
}

test "timelapse configuration frees every partial allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var cfg = config.ConfigParser.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[timelapse]\nframe_path: frames\noutput_path: output\nsnapshoturl: /snapshot\n", "allocation-fixture");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: Allocator, path: []const u8, configuration: *const config.ConfigParser) !void {
            var ctx: Timelapse = .{ .gpa = a, .io = std.testing.io };
            defer ctx.deinit();
            try ctx.configure(configuration, path, path);
            try std.testing.expectEqualStrings("http://localhost/snapshot", ctx.settings.snapshoturl);
        }
    }.run, .{ root, &cfg });
}

test "canceling a parked capture cannot publish or acknowledge a later generation" {
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    f.cancel_snapshot = true;
    const canceled = try f.ctx.capture(a, try json(a, .{ .parked = true }), false);
    try std.testing.expectEqualStrings("skipped", string(field(canceled, "status")));
    try std.testing.expectEqual(@as(u32, 0), f.ctx.framecount);
    try std.testing.expectEqual(@as(usize, 0), f.parked_releases);
    f.cancel_snapshot = false;
    const next = try f.ctx.capture(a, try json(a, .{ .parked = true }), false);
    try std.testing.expectEqualStrings("success", string(field(next, "status")));
    try std.testing.expectEqual(@as(usize, 1), f.parked_releases);
}

test "snapshot HTTP streams bounded bodies and preserves failed destinations" {
    const Peer = struct {
        fn serve(server: *Io.net.Server, size: usize) void {
            const aio = std.testing.io;
            const stream = server.accept(aio) catch return;
            defer stream.close(aio);
            var input: [4096]u8 = undefined;
            var reader = stream.reader(aio, &input);
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            var output: [4096]u8 = undefined;
            var writer = stream.writer(aio, &output);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{size}) catch return;
            writer.interface.splatByteAll('J', size) catch return;
            writer.interface.flush() catch return;
        }
    };
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const aio = std.testing.io;
    for ([_]usize{ 16, max_snapshot_bytes + 1 }) |size| {
        var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(aio, .{});
        defer server.deinit(aio);
        var task = try aio.concurrent(Peer.serve, .{ &server, size });
        defer task.cancel(aio);
        var output = try f.tmp.dir.createFileAtomic(aio, "snapshot.jpg", .{ .replace = true });
        defer output.deinit(aio);
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/snapshot", .{server.socket.address.getPort()});
        if (size > max_snapshot_bytes) {
            try std.testing.expectError(error.SnapshotTooLarge, downloadSnapshot(null, a, aio, url, output.file));
        } else {
            try downloadSnapshot(null, a, aio, url, output.file);
            try output.replace(aio);
        }
        task.await(aio);
        const saved = try f.tmp.dir.readFileAlloc(aio, "snapshot.jpg", a, .limited(32));
        try std.testing.expectEqual(@as(usize, 16), saved.len);
    }
}

test "timelapse frame names, encoder arguments and filters reject malformed input" {
    try std.testing.expect(frameNumber("../frame000001.jpg") == null);
    try std.testing.expect(frameNumber("frame000000.jpg") == null);
    try std.testing.expectEqual(@as(?u32, 17), frameNumber("frame000017.jpg"));
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const args = try extraArguments(a, "-vf 'scale=640:480' -metadata \"title=it's mine\"");
    try std.testing.expectEqualStrings("title=it's mine", args[3]);
    try std.testing.expectError(error.InvalidParams, extraArguments(a, "'unterminated"));
    try std.testing.expectEqualStrings("transpose=3", try videoFilter(a, .{ .rotation = 90, .flip_y = true }));
    try std.testing.expectEqualStrings("hflip", try videoFilter(a, .{ .flip_x = true }));
    try validate(.{});
}

test "fuzz timelapse settings, archive names and argument parsing remain bounded" {
    try std.testing.fuzz({}, struct {
        fn check(_: void, smith: *std.testing.Smith) !void {
            var data: [128]u8 = undefined;
            smith.bytesWithHash(&data, 0);
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const a = arena_state.allocator();
            _ = frameNumber(&data);
            _ = extraArguments(a, &data) catch {};
            validate(.{ .parkpos = &data }) catch {};
            const escaped = try safeOutput(a, &data);
            try std.testing.expect(std.unicode.utf8ValidateSlice(escaped));
        }
    }.check, .{});
}

test "native FFmpeg renders a decodable video and transformed preview" {
    Io.Dir.cwd().access(std.testing.io, "/usr/bin/ffmpeg", .{}) catch return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    var arena_state = std.heap.ArenaAllocator.init(f.allocator.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const image = try std.fs.path.join(a, &.{ f.ctx.frame_path, "frame000001.jpg" });
    const create = try process.run(a, f.ctx.io, .{
        .argv = &.{ "/usr/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=16x16", "-frames:v", "1", "-threads", "1", image, "-y" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, create.term);
    f.ctx.gpa.free(f.ctx.ffmpeg);
    f.ctx.ffmpeg = try f.ctx.gpa.dupe(u8, "/usr/bin/ffmpeg");
    f.ctx.run = runProcess;
    f.ctx.framecount = 1;
    f.ctx.lastframe = 1;
    f.ctx.settings.duplicatelastframe = 1;
    f.ctx.settings.rotation = 90;
    const rendered = try handleRender(&f.ctx, .null, a);
    try std.testing.expectEqualStrings("success", string(field(rendered, "status")));
    const video = try std.fs.path.join(a, &.{ f.ctx.output_path, string(field(rendered, "filename")) });
    const decoded = try process.run(a, f.ctx.io, .{
        .argv = &.{ "/usr/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-i", video, "-f", "null", "-" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, decoded.term);
    var dir = try Io.Dir.cwd().openDir(f.ctx.io, f.ctx.output_path, .{});
    defer dir.close(f.ctx.io);
    const preview = try dir.readFileAlloc(f.ctx.io, "timelapse_part_test.jpg", a, .limited(max_snapshot_bytes));
    try std.testing.expect(preview.len > 2 and preview[0] == 0xff and preview[1] == 0xd8);
}

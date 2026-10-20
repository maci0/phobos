//! PanelDue serial protocol, command queues and Repetier-compatible responses.
//! Reference: vendor/moonraker/moonraker/components/paneldue.py.
const std = @import("std");

pub const ParseError = error{InvalidChecksum};

const file_cmds = [_][]const u8{ "M23", "M30", "M32", "M36", "M37", "M98" };

fn isFileCmd(cmd: []const u8) bool {
    for (file_cmds) |c| if (std.mem.eql(u8, c, cmd)) return true;
    return false;
}

const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Core = @import("../server/core.zig").Core;
const Klippy = @import("klippy_connection.zig");
const Files = @import("file_manager.zig");
const ConfigParser = @import("../config/confighelper.zig").ConfigParser;
const Serial = @import("serial.zig").Serial;
const clock = @import("../util/clock.zig");
const webreq = @import("../json/params.zig");

pub const max_line = 4096;
const queue_capacity = 32;
const max_response = 64 * 1024;
const scratch_size = 512 * 1024;
const max_macros = 64;
const max_heaters = 32;
const max_files = 256;
const reconnect_delay: Io.Duration = .fromSeconds(2);
const serial_timeout: Io.Duration = .fromMilliseconds(100);
const write_timeout: Io.Duration = .fromSeconds(2);
const initialize_timeout = 10;
const request_timeout: Io.Duration = .fromSeconds(20);
const initialize_attempts = 10;
const initialize_retry: Io.Duration = .fromSeconds(1);
const emergency_word = std.mem.readInt(u32, "M112", .big);
const subscription_objects = [_][]const u8{ "motion_report", "gcode_move", "toolhead", "virtual_sdcard", "fan", "display_status", "print_stats", "idle_timeout", "gcode_macro PANELDUE_BEEP" };

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, capacity);
            if (self.len < text.len) while (self.len > 0 and text[self.len] & 0xc0 == 0x80) {
                self.len -= 1;
            };
            @memcpy(self.bytes[0..self.len], text[0..self.len]);
        }
        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
const Macro = struct { name: []const u8, script: []const u8, confirmed: bool };
const Heater = struct { name: Text(128) = .{}, temperature: f64 = 0, target: f64 = 0 };
const Work = union(enum) { initialize, script: []u8 };

pub const PanelDue = struct {
    enable_checksum: bool = false,
    /// Parts borrow the last processLine argument, retained for parser callers.
    parts: [32][]const u8 = undefined,
    part_count: usize = 0,
    emergency_stop: bool = false,
    serial_path: ?[]const u8 = null,
    baud: u32 = 57600,
    machine_name: []const u8 = "Klipper",
    macros: [max_macros]Macro = undefined,
    macro_count: usize = 0,
    non_trivial_keys: []const u8 = "Klipper state",
    configured: bool = false,
    confirmed_gcode: []const u8 = "",
    mbox_sequence: i64 = 0,
    io: ?Io = null,
    gpa: Allocator = undefined,
    core: ?*Core = null,
    klippy: ?*Klippy.KlippyCtx = null,
    files: ?*Files.FileCtx = null,
    bound: bool = false,
    output: Io.Queue([]u8) = .init(&.{}),
    output_buffer: [queue_capacity][]u8 = undefined,
    gcodes: Io.Queue(Work) = .init(&.{}),
    gcode_buffer: [queue_capacity]Work = undefined,
    serial_worker: ?Io.Future(void) = null,
    gcode_worker: ?Io.Future(void) = null,
    ready: bool = false,
    initialize_pending: bool = false,
    shutdown: bool = false,
    initialized: bool = false,
    last_update: f64 = 0,
    last_status: u8 = 'O',
    firmware: Text(256) = .{},
    geometry: Text(64) = .{},
    heaters: [max_heaters]Heater = @splat(.{}),
    heater_count: usize = 0,
    extruder_count: usize = 0,
    position: [4]f64 = @splat(0),
    homed: [3]u8 = @splat(0),
    origin_z: f64 = 0,
    gcode_z: f64 = 0,
    speed_factor: f64 = 1,
    extrude_factor: f64 = 1,
    progress: f64 = 0,
    duration: f64 = 0,
    filament_used: f64 = 0,
    fan_speed: ?f64 = null,
    sd_active: bool = false,
    printing: bool = false,
    paused: bool = false,
    idle_printing: bool = false,
    extruder: Text(128) = .{},
    filename: Text(max_line) = .{},
    message: Text(1024) = .{},
    last_message: Text(1024) = .{},
    last_response: Text(max_line) = .{},

    /// Config strings borrow cfg, which must outlive this component.
    pub fn configure(self: *PanelDue, cfg: *const ConfigParser) !void {
        self.enable_checksum = cfg.getBoolean("paneldue", "enable_checksum") catch true;
        self.serial_path = cfg.get("paneldue", "serial") orelse return error.InvalidParams;
        if (self.serial_path) |path| if (path.len == 0 or path.len > max_line) return error.InvalidParams;
        self.baud = 57600;
        if (cfg.get("paneldue", "baud") != null) {
            const baud = try cfg.getInt("paneldue", "baud");
            if (baud <= 0 or baud > std.math.maxInt(u32)) return error.InvalidParams;
            self.baud = @intCast(baud);
        }
        _ = try Serial.baudToSpeed(self.baud);
        self.machine_name = cfg.get("paneldue", "machine_name") orelse "Klipper";
        if (self.machine_name.len > max_line) return error.InvalidParams;
        self.non_trivial_keys = cfg.get("paneldue", "non_trivial_keys") orelse "Klipper state";
        self.macro_count = 0;
        try self.addMacros(cfg.get("paneldue", "macros") orelse "", false);
        try self.addMacros(cfg.get("paneldue", "confirmed_macros") orelse "RESTART,FIRMWARE_RESTART", true);
        self.configured = true;
    }

    fn addMacros(self: *PanelDue, list: []const u8, confirmed: bool) !void {
        var it = std.mem.tokenizeAny(u8, list, ",\n");
        while (it.next()) |raw| {
            const script = std.mem.trim(u8, raw, " \t\r");
            if (script.len == 0) continue;
            if (script.len > max_line) return error.InvalidParams;
            var words = std.mem.tokenizeAny(u8, script, " \t");
            const name = words.next().?;
            const index = for (self.macros[0..self.macro_count], 0..) |macro, index| {
                if (std.mem.eql(u8, macro.name, name)) break index;
            } else self.macro_count;
            if (index >= max_macros) return error.InvalidParams;
            self.macros[index] = .{ .name = name, .script = script, .confirmed = confirmed };
            if (index == self.macro_count) self.macro_count += 1;
        }
    }

    /// Call after the owning App reaches its final address, before any workers.
    pub fn bind(self: *PanelDue, io: Io, gpa: Allocator, core: *Core, klippy: *Klippy.KlippyCtx, files: *Files.FileCtx) void {
        self.io = io;
        self.gpa = gpa;
        self.core = core;
        self.klippy = klippy;
        self.files = files;
        if (self.bound) return;
        self.bound = true;
        self.output = .init(&self.output_buffer);
        self.gcodes = .init(&self.gcode_buffer);
        if (!self.configured) self.addMacros("RESTART,FIRMWARE_RESTART", true) catch unreachable;
    }

    pub fn start(self: *PanelDue) !void {
        if (self.serial_path == null or self.serial_worker != null) return;
        const io = self.io orelse return error.NotReady;
        for (subscription_objects) |name| try self.klippy.?.addSubscriptionObject(name);
        self.gcode_worker = try io.concurrent(gcodeLoop, .{self});
        errdefer {
            self.gcode_worker.?.cancel(io);
            self.gcode_worker = null;
        }
        self.serial_worker = try io.concurrent(serialLoop, .{self});
    }

    pub fn deinit(self: *PanelDue) void {
        const io = self.io orelse return;
        self.output.close(io);
        self.gcodes.close(io);
        if (self.serial_worker) |*worker| worker.cancel(io);
        if (self.gcode_worker) |*worker| worker.cancel(io);
        self.serial_worker = null;
        self.gcode_worker = null;
        while (self.output.getOne(io)) |bytes| self.gpa.free(bytes) else |_| {}
        while (self.gcodes.getOne(io)) |work| {
            switch (work) {
                .initialize => {},
                .script => |bytes| self.gpa.free(bytes),
            }
        } else |_| {}
    }

    pub fn processLine(self: *PanelDue, line: []const u8) ParseError!void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.ascii.findIgnoreCase(trimmed, "M112") != null) {
            self.emergency_stop = true;
            self.part_count = 0;
            return;
        }
        self.part_count = 0;
        self.part_count = (try parseLine(trimmed, self.enable_checksum, &self.parts)).len;
    }

    /// Core held. Serial errors become the next sequenced M408 response.
    pub fn receiveLine(self: *PanelDue, line: []const u8) !void {
        if (line.len > max_line) return error.LineTooLong;
        self.emergency_stop = false;
        self.processLine(line) catch |err| {
            self.processingError(line);
            return err;
        };
        if (self.emergency_stop or self.part_count == 0) return;
        var storage: [scratch_size]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const a = fixed.allocator();
        const cmd = self.parts[0];
        const args = self.parts[1..self.part_count];
        if (std.mem.eql(u8, cmd, "M408")) return self.statusResponse(a, args);
        if (std.mem.eql(u8, cmd, "M20")) return self.listResponse(a, args);
        if (std.mem.eql(u8, cmd, "M30")) return self.deleteFile(a, args);
        if (std.mem.eql(u8, cmd, "M36")) return self.fileResponse(a, args);
        const raw = std.mem.trim(u8, line, " \t\r\n");
        const script = if (self.enable_checksum) blk: {
            const end = std.mem.lastIndexOfScalar(u8, raw, '*').?;
            const offset = @intFromPtr(cmd.ptr) - @intFromPtr(raw.ptr);
            break :blk raw[offset..end];
        } else raw;
        const prepared = self.prepare(a, cmd, args, script) catch |err| {
            self.processingError(line);
            return err;
        };
        if (prepared.len == 0) return;
        const owned = try self.gpa.dupe(u8, prepared);
        errdefer self.gpa.free(owned);
        if (try self.gcodes.put(self.io.?, &.{.{ .script = owned }}, 0) == 0) return error.QueueFull;
    }

    fn processingError(self: *PanelDue, line: []const u8) void {
        var buf: [max_line]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "!! GCode Processing Error: {s}", .{line}) catch "!! GCode Processing Error";
        self.last_response.set(text);
    }

    fn prepare(self: *PanelDue, a: Allocator, cmd: []const u8, args: []const []const u8, script: []const u8) ![]const u8 {
        inline for (.{ .{ "M0", "CANCEL_PRINT" }, .{ "M24", "RESUME" }, .{ "M25", "PAUSE" }, .{ "M120", "SAVE_GCODE_STATE STATE=PANELDUE" }, .{ "M121", "RESTORE_GCODE_STATE STATE=PANELDUE" }, .{ "M999", "FIRMWARE_RESTART" } }) |pair| {
            if (std.mem.eql(u8, cmd, pair[0])) return pair[1];
        }
        if (std.mem.eql(u8, cmd, "M23") or std.mem.eql(u8, cmd, "M32")) {
            if (args.len == 0 or args[0].len == 0) return error.InvalidParams;
            const filename = try cleanFilename(a, args[0]);
            if (std.mem.eql(u8, cmd, "M23")) return std.fmt.allocPrint(a, "M23 {s}", .{filename});
            var escaped: std.ArrayList(u8) = .empty;
            for (filename) |byte| {
                if (byte == '"') try escaped.append(a, '\\');
                try escaped.append(a, byte);
            }
            return std.fmt.allocPrint(a, "SDCARD_PRINT_FILE FILENAME=\"{s}\"", .{escaped.items});
        }
        if (std.mem.eql(u8, cmd, "M290")) {
            if (args.len == 0 or args[0].len < 2) return error.InvalidParams;
            return std.fmt.allocPrint(a, "SET_GCODE_OFFSET Z_ADJUST={s} MOVE=1", .{args[0][1..]});
        }
        if (std.mem.eql(u8, cmd, "M292")) {
            if (args.len == 0 or args[0].len < 2) return error.InvalidParams;
            const choice = try std.fmt.parseInt(i64, args[0][1..], 10);
            if (choice != 0) return "";
            const confirmed = self.confirmed_gcode;
            self.confirmed_gcode = "";
            return confirmed;
        }
        if (std.mem.eql(u8, cmd, "M98")) {
            if (args.len == 0 or args[0].len < 2) return error.InvalidParams;
            const path = std.mem.trim(u8, args[0][1..], " \"\t\n");
            const name = std.fs.path.basename(path);
            for (self.macros[0..self.macro_count]) |macro| {
                if (!std.mem.eql(u8, macro.name, name)) continue;
                if (!macro.confirmed) return macro.script;
                self.confirmed_gcode = macro.script;
                self.mbox_sequence +%= 1;
                var response: std.json.ObjectMap = .empty;
                try response.put(a, "msgBox.mode", .{ .integer = 3 });
                try response.put(a, "msgBox.msg", .{ .string = try std.fmt.allocPrint(a, "Please confirm your intent to run {s}. Press OK to continue, or CANCEL to abort.", .{name}) });
                try response.put(a, "msgBox.seq", .{ .integer = self.mbox_sequence });
                try response.put(a, "msgBox.title", .{ .string = "Confirmation Dialog" });
                try response.put(a, "msgBox.controls", .{ .integer = 0 });
                try response.put(a, "msgBox.timeout", .{ .integer = 0 });
                try self.respond(a, Value{ .object = response });
                return "";
            }
            return error.InvalidMacro;
        }
        return script;
    }

    /// Core held. Workers consume response bytes without borrowing caller data.
    fn respond(self: *PanelDue, a: Allocator, response: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(a, response, .{});
        if (encoded.len > max_response) return error.ResponseTooLarge;
        const bytes = try std.fmt.allocPrint(self.gpa, "{s}\r\n", .{encoded});
        errdefer self.gpa.free(bytes);
        if (try self.output.put(self.io.?, &.{bytes}, 0) == 0) return error.QueueFull;
    }

    pub fn beep(self: *PanelDue, params: Value) !void {
        const frequency = try webreq.required(i64, params, "frequency");
        const duration = try webreq.required(f64, params, "duration");
        const millis = duration * 1000;
        if (!std.math.isFinite(millis) or millis < -9.22e18 or millis >= 9.22e18) return error.InvalidParams;
        var storage: [256]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        try self.respond(fixed.allocator(), .{ .beep_freq = frequency, .beep_length = @as(i64, @intFromFloat(millis)) });
    }

    pub fn handleGcodeResponse(self: *PanelDue, response: []const u8) void {
        if (std.mem.startsWith(u8, response, "!!") or std.mem.indexOf(u8, response, "Klipper state") != null) {
            self.last_response.set(response);
            return;
        }
        var keys = std.mem.tokenizeAny(u8, self.non_trivial_keys, ",\n");
        while (keys.next()) |raw| {
            const key = std.mem.trim(u8, raw, " \t\r");
            if (key.len > 0 and std.mem.indexOf(u8, response, key) != null) {
                self.last_response.set(response);
                return;
            }
        }
    }

    pub fn onState(self: *PanelDue, state: Klippy.State) void {
        if (!self.bound or self.serial_path == null) return;
        switch (state) {
            .ready => {
                self.initialize_pending = true;
                _ = self.gcodes.put(self.io.?, &.{.initialize}, 0) catch 0;
            },
            .shutdown => self.shutdown = true,
            .disconnected => {
                self.ready = false;
                self.initialize_pending = false;
                self.shutdown = false;
                self.last_status = 'O';
                var storage: [128]u8 = undefined;
                var fixed = std.heap.FixedBufferAllocator.init(&storage);
                self.respond(fixed.allocator(), .{ .status = "O" }) catch |err| std.debug.print("phobos: PanelDue disconnect response: {}\n", .{err});
            },
            .startup, .@"error" => self.ready = false,
        }
    }

    /// Merge partial subscription updates into bounded, owned state. Core held.
    pub fn statusUpdate(self: *PanelDue, status: Value) void {
        if (status != .object) return;
        if (field(status, "motion_report", "live_position")) |v| updateVector(&self.position, v);
        if (field(status, "gcode_move", "homing_origin")) |v| self.origin_z = vectorNumber(v, 2, self.origin_z);
        if (field(status, "gcode_move", "gcode_position")) |v| self.gcode_z = vectorNumber(v, 2, self.gcode_z);
        if (field(status, "gcode_move", "speed_factor")) |v| self.speed_factor = number(v, self.speed_factor);
        if (field(status, "gcode_move", "extrude_factor")) |v| self.extrude_factor = number(v, self.extrude_factor);
        if (field(status, "toolhead", "homed_axes")) |v| if (v == .string) {
            for ("xyz", &self.homed) |axis, *homed| homed.* = @intFromBool(std.mem.indexOfScalar(u8, v.string, axis) != null);
        };
        if (field(status, "toolhead", "extruder")) |v| if (v == .string) self.extruder.set(v.string);
        if (field(status, "virtual_sdcard", "progress")) |v| self.progress = number(v, self.progress);
        if (field(status, "virtual_sdcard", "is_active")) |v| {
            if (v == .bool) self.sd_active = v.bool;
        }
        if (field(status, "print_stats", "state")) |v| if (v == .string) {
            self.printing = std.mem.eql(u8, v.string, "printing");
            self.paused = std.mem.eql(u8, v.string, "paused");
        };
        if (field(status, "print_stats", "filename")) |v| if (v == .string) self.filename.set(v.string);
        if (field(status, "print_stats", "print_duration")) |v| self.duration = number(v, self.duration);
        if (field(status, "print_stats", "filament_used")) |v| self.filament_used = number(v, self.filament_used);
        if (field(status, "idle_timeout", "state")) |v| {
            if (v == .string) self.idle_printing = std.mem.eql(u8, v.string, "Printing");
        }
        if (field(status, "fan", "speed")) |v| self.fan_speed = number(v, 0);
        if (field(status, "display_status", "message")) |v| {
            if (v == .string) self.message.set(v.string) else if (v == .null) self.message.len = 0;
        }
        for (self.heaters[0..self.heater_count]) |*heater| {
            if (field(status, heater.name.slice(), "temperature")) |v| heater.temperature = number(v, heater.temperature);
            if (field(status, heater.name.slice(), "target")) |v| heater.target = number(v, heater.target);
        }
    }

    fn printerStatus(self: *const PanelDue) u8 {
        if (self.shutdown) return 'S';
        if (self.printing) return if (self.last_status == 'A') 'R' else 'P';
        if (self.paused) return if (self.idle_printing and self.last_status != 'A') 'D' else 'A';
        return 'I';
    }

    fn statusResponse(self: *PanelDue, a: Allocator, args: []const []const u8) !void {
        const params = try directParams(args);
        var response: std.json.ObjectMap = .empty;
        const now = clock.monotonicSeconds(self.io.?);
        if (now - self.last_update > initialize_timeout) self.initialized = false;
        self.last_update = now;
        if (!self.initialized) {
            try response.put(a, "dir", .{ .string = "/macros" });
            try response.put(a, "files", try self.macroFiles(a));
            self.initialized = true;
        }
        if (!self.ready) {
            self.last_status = 'O';
            try response.put(a, "status", .{ .string = "O" });
            return self.respond(a, Value{ .object = response });
        }
        if (params.r) |sequence| if (self.last_response.len > 0) {
            if (sequence == std.math.maxInt(i64)) return error.InvalidParams;
            try response.put(a, "seq", .{ .integer = sequence + 1 });
            try response.put(a, "resp", .{ .string = self.last_response.slice() });
        };
        if ((params.s orelse 1) == 1) {
            try response.put(a, "myName", .{ .string = self.machine_name });
            try response.put(a, "firmwareName", .{ .string = if (self.firmware.len == 0) "Repetier | Klipper" else self.firmware.slice() });
            try response.put(a, "numTools", .{ .integer = @intCast(self.extruder_count) });
            try response.put(a, "geometry", .{ .string = if (self.geometry.len == 0) "none" else self.geometry.slice() });
            try response.put(a, "axes", .{ .integer = 3 });
        }
        self.last_status = self.printerStatus();
        const status = [_]u8{self.last_status};
        try response.put(a, "status", .{ .string = &status });
        try response.put(a, "babystep", .{ .float = rounded(self.origin_z, 3) });
        try response.put(a, "pos", try floats(a, self.position[0..3], 2));
        try response.put(a, "homed", try integers(a, &self.homed));
        try response.put(a, "sfactor", .{ .float = rounded(self.speed_factor * 100, 2) });
        if ((self.printing or self.paused) and self.progress > 0) {
            try response.put(a, "fraction_printed", .{ .float = rounded(self.progress, 3) });
            var times: std.json.Array = .init(a);
            const md = self.metadata(a, self.filename.slice()) catch .null;
            const estimate = number(get(md, "estimated_time"), 0);
            if (estimate > 10) {
                try times.append(.{ .integer = secondsLeft(estimate * (1 - self.progress)) });
                const filament = number(get(md, "filament_total"), 0);
                if (filament > 0) try times.append(.{ .integer = secondsLeft(estimate * (1 - @min(1, self.filament_used / filament))) });
                const height = number(get(md, "object_height"), 0);
                if (height > 0) try times.append(.{ .integer = secondsLeft(estimate * (1 - @min(1, self.gcode_z / height))) });
            } else try times.append(.{ .integer = secondsLeft(self.duration / self.progress - self.duration) });
            try response.put(a, "timesLeft", .{ .array = times });
        }
        if (self.fan_speed) |speed| try response.put(a, "fanPercent", try floats(a, &.{speed * 100}, 1));
        if (self.extruder_count > 0 and self.extruder.len > 0) {
            const name = self.extruder.slice();
            const tool: i64 = if (std.mem.eql(u8, name, "extruder")) 0 else std.fmt.parseInt(i64, name[name.len - 1 ..], 10) catch 0;
            try response.put(a, "tool", .{ .integer = tool });
        }
        if (self.heater_count > 0) {
            var temps: std.json.Array = .init(a);
            var active: std.json.Array = .init(a);
            var hstat: std.json.Array = .init(a);
            var efactor: std.json.Array = .init(a);
            var extr: std.json.Array = .init(a);
            for (self.heaters[0..self.heater_count]) |*heater| {
                try temps.append(.{ .float = rounded(heater.temperature, 1) });
                try active.append(.{ .float = rounded(heater.target, 1) });
                const is_extruder = std.mem.startsWith(u8, heater.name.slice(), "extruder");
                const stat: i64 = if (heater.target == 0) 0 else if (!is_extruder or std.mem.eql(u8, heater.name.slice(), self.extruder.slice())) 2 else 1;
                try hstat.append(.{ .integer = stat });
                if (is_extruder) {
                    try efactor.append(.{ .float = rounded(self.extrude_factor * 100, 2) });
                    try extr.append(.{ .float = rounded(self.position[3], 2) });
                }
            }
            try response.put(a, "heaters", .{ .array = temps });
            try response.put(a, "active", .{ .array = active });
            try response.put(a, "standby", .{ .array = active });
            try response.put(a, "hstat", .{ .array = hstat });
            if (efactor.items.len > 0) {
                try response.put(a, "efactor", .{ .array = efactor });
                try response.put(a, "extr", .{ .array = extr });
            }
        }
        if (self.message.len > 0 and !std.mem.eql(u8, self.message.slice(), self.last_message.slice())) try response.put(a, "message", .{ .string = self.message.slice() });
        try self.respond(a, Value{ .object = response });
        self.last_message.set(self.message.slice());
        if (params.r != null) self.last_response.len = 0;
    }

    fn macroFiles(self: *const PanelDue, a: Allocator) !Value {
        var files: std.json.Array = .init(a);
        for (self.macros[0..self.macro_count]) |macro| try files.append(.{ .string = macro.name });
        return .{ .array = files };
    }

    fn listResponse(self: *PanelDue, a: Allocator, args: []const []const u8) !void {
        const params = try directParams(args);
        if ((params.s orelse 0) != 2) return;
        var path = params.p orelse return error.InvalidParams;
        if (std.mem.startsWith(u8, path, "0:/")) path = path[2..];
        var response: std.json.ObjectMap = .empty;
        try response.put(a, "dir", .{ .string = if (std.mem.eql(u8, path, "/")) "/gcodes" else path });
        if (std.mem.eql(u8, path, "/macros")) {
            try response.put(a, "files", try self.macroFiles(a));
        } else {
            const request_path = if (std.mem.eql(u8, path, "/")) "gcodes" else std.mem.trimStart(u8, path, "/");
            const resolved = try Files.resolveRequestPath(self.files.?, a, request_path);
            var dir = try resolved.openDirectory(self.io.?, a);
            defer dir.close(self.io.?);
            var entries: std.json.Array = .init(a);
            var it = dir.iterate();
            while (try it.next(self.io.?)) |entry| {
                if (entries.items.len == max_files) return error.ResponseTooLarge;
                const child_rel = if (resolved.rel.len == 0) entry.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ resolved.rel, entry.name });
                if (Files.FileCtx.pathExcluded(self.files.?.excludes, resolved.root.name, child_rel)) continue;
                const kind = if (entry.kind == .unknown) (try dir.statFile(self.io.?, entry.name, .{ .follow_symlinks = false })).kind else entry.kind;
                if (kind != .directory and kind != .file) continue;
                if (kind == .file) {
                    const ext = std.fs.path.extension(entry.name);
                    const is_gcode = for (Files.valid_gcode_exts) |valid| {
                        if (std.ascii.eqlIgnoreCase(ext, valid)) break true;
                    } else false;
                    if (!std.mem.eql(u8, resolved.root.name, "gcodes") or !is_gcode) continue;
                }
                try entries.append(.{ .string = if (kind == .directory) try std.fmt.allocPrint(a, "*{s}", .{entry.name}) else try a.dupe(u8, entry.name) });
            }
            std.mem.sort(Value, entries.items, {}, struct {
                fn less(_: void, left: Value, right: Value) bool {
                    return std.mem.lessThan(u8, left.string, right.string);
                }
            }.less);
            try response.put(a, "files", .{ .array = entries });
        }
        try self.respond(a, Value{ .object = response });
    }

    fn deleteFile(self: *PanelDue, a: Allocator, args: []const []const u8) !void {
        const params = try directParams(args);
        var path = params.p orelse return error.InvalidParams;
        if (std.mem.startsWith(u8, path, "0:/")) path = path[3..] else path = std.mem.trimStart(u8, path, "/");
        if (path.len == 0) return error.InvalidParams;
        if (!std.mem.startsWith(u8, path, "gcodes/")) path = try std.fmt.allocPrint(a, "gcodes/{s}", .{path});
        _ = try Files.deleteFileImpl(self.files.?, a, path);
    }

    fn metadata(self: *PanelDue, a: Allocator, raw: []const u8) !Value {
        var path = std.mem.trimStart(u8, raw, "/");
        if (std.mem.startsWith(u8, path, "gcodes/")) path = path[7..];
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "filename", .{ .string = path });
        return Files.handleMetadata(@ptrCast(self.files.?), .{ .object = params }, a);
    }

    fn fileResponse(self: *PanelDue, a: Allocator, args: []const []const u8) !void {
        const params = try directParams(args);
        var response: std.json.ObjectMap = .empty;
        var filename = params.p;
        if (filename == null or filename.?.len == 0) {
            if (!self.sd_active or self.filename.len == 0) return self.respond(a, .{ .err = 1 });
            filename = self.filename.slice();
            try response.put(a, "fileName", .{ .string = std.fs.path.basename(filename.?) });
        }
        const md = self.metadata(a, filename.?) catch return self.respond(a, .{ .err = 1 });
        try response.put(a, "err", .{ .integer = 0 });
        try response.put(a, "size", get(md, "size"));
        try response.put(a, "lastModified", .{ .string = try ctime(a, number(get(md, "modified"), 0)) });
        if (get(md, "slicer") != .null) try response.put(a, "generatedBy", get(md, "slicer"));
        inline for (.{ .{ "object_height", "height" }, .{ "layer_height", "layerHeight" } }) |pair| {
            if (get(md, pair[0]) != .null) try response.put(a, pair[1], .{ .float = rounded(number(get(md, pair[0]), 0), 2) });
        }
        if (get(md, "filament_total") != .null) try response.put(a, "filament", try floats(a, &.{number(get(md, "filament_total"), 0)}, 1));
        if (get(md, "estimated_time") != .null) try response.put(a, "printTime", .{ .integer = secondsLeft(number(get(md, "estimated_time"), 0) + 0.5) });
        try self.respond(a, Value{ .object = response });
    }

    fn gcodeLoop(self: *PanelDue) void {
        const io = self.io.?;
        while (self.gcodes.getOne(io)) |work| {
            defer switch (work) {
                .initialize => {},
                .script => |script| self.gpa.free(script),
            };
            if (self.core.?.run(io, takeInitialization, .{self})) {
                self.initializeWithRetries() catch |err| {
                    if (err == error.Canceled) return;
                    std.debug.print("phobos: PanelDue initialization: {}\n", .{err});
                };
            }
            switch (work) {
                .initialize => {},
                .script => |script| {
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    var params: std.json.ObjectMap = .empty;
                    params.put(arena.allocator(), "script", .{ .string = script }) catch continue;
                    _ = self.request("gcode/script", .{ .object = params }, arena.allocator()) catch |err| {
                        if (err == error.Canceled) return;
                        if (err == error.KlippyDisconnected and (std.mem.eql(u8, script, "RESTART") or std.mem.eql(u8, script, "FIRMWARE_RESTART"))) continue;
                        var buf: [max_line]u8 = undefined;
                        const message = std.fmt.bufPrint(&buf, "!! Error executing script {s}", .{script}) catch "!! Error executing script";
                        self.core.?.run(io, handleGcodeResponse, .{ self, message });
                        continue;
                    };
                },
            }
        } else |_| {}
    }

    fn takeInitialization(self: *PanelDue) bool {
        const pending = self.initialize_pending;
        self.initialize_pending = false;
        return pending;
    }

    fn initializeWithRetries(self: *PanelDue) !void {
        for (0..initialize_attempts) |attempt| {
            self.initialize() catch |err| {
                if (err == error.Canceled or err == error.KlippyDisconnected or attempt + 1 == initialize_attempts) return err;
                try self.io.?.sleep(initialize_retry, .awake);
                continue;
            };
            return;
        }
    }

    fn initialize(self: *PanelDue) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const info = try self.request("info", .null, a);
        var objects: std.json.ObjectMap = .empty;
        try objects.put(a, "configfile", .null);
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "objects", .{ .object = objects });
        const queried = try self.request("objects/query", .{ .object = params }, a);
        const config = get(get(get(queried, "status"), "configfile"), "config");
        try self.core.?.run(self.io.?, initializeConfig, .{ self, a, info, config });
        for (self.heaters[0..self.heater_count]) |*heater| try self.klippy.?.addSubscriptionObject(heater.name.slice());
        try self.klippy.?.refreshSubscriptions(a);
        try self.core.?.run(self.io.?, finishInitialization, .{self});
    }

    fn initializeConfig(self: *PanelDue, a: Allocator, info: Value, config: Value) !void {
        if (self.klippy.?.state != .ready or !self.klippy.?.isConnected()) return error.KlippyDisconnected;
        try self.applyConfig(a, info, config);
    }

    fn finishInitialization(self: *PanelDue) !void {
        if (self.klippy.?.state != .ready or !self.klippy.?.isConnected()) return error.KlippyDisconnected;
        self.ready = true;
        self.shutdown = false;
    }

    fn request(self: *PanelDue, method: []const u8, params: Value, a: Allocator) !Value {
        const Outcome = union(enum) { result: anyerror!Value, expired: Io.Cancelable!void };
        var outcomes: [2]Outcome = undefined;
        var select: Io.Select(Outcome) = .init(self.io.?, &outcomes);
        defer select.cancelDiscard();
        try select.concurrent(.result, Klippy.KlippyCtx.requestOffCore, .{ self.klippy.?, method, params, a });
        try select.concurrent(.expired, Io.sleep, .{ self.io.?, request_timeout, .awake });
        return switch (try select.await()) {
            .result => |result| try result,
            .expired => |result| blk: {
                try result;
                break :blk error.Timeout;
            },
        };
    }

    fn applyConfig(self: *PanelDue, a: Allocator, info: Value, config: Value) !void {
        const version = get(info, "software_version");
        self.firmware.set(try std.fmt.allocPrint(a, "Repetier | Klipper {s}", .{if (version == .string) version.string else ""}));
        const geometry = field(config, "printer", "kinematics") orelse .null;
        self.geometry.set(if (geometry == .string) geometry.string else "none");
        self.heater_count = 0;
        self.extruder_count = 0;
        if (config == .object) {
            var it = config.object.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const extruder = std.mem.startsWith(u8, name, "extruder");
                if (!extruder and !std.mem.eql(u8, name, "heater_bed")) continue;
                if (self.heater_count == max_heaters or name.len > 128) return error.TooManyObjects;
                self.heaters[self.heater_count] = .{};
                self.heaters[self.heater_count].name.set(name);
                self.heater_count += 1;
                if (extruder) self.extruder_count += 1;
            }
            std.mem.sort(Heater, self.heaters[0..self.heater_count], {}, struct {
                fn less(_: void, left: Heater, right: Heater) bool {
                    const lbed = std.mem.eql(u8, left.name.slice(), "heater_bed");
                    const rbed = std.mem.eql(u8, right.name.slice(), "heater_bed");
                    return if (lbed != rbed) lbed else std.mem.lessThan(u8, left.name.slice(), right.name.slice());
                }
            }.less);
        }
    }

    fn serialLoop(self: *PanelDue) void {
        const io = self.io.?;
        while (true) {
            var serial = Serial.open(io, self.serial_path.?, self.baud) catch {
                io.sleep(reconnect_delay, .awake) catch return;
                continue;
            };
            self.serialSession(&serial) catch |err| {
                if (err == error.Canceled) {
                    serial.close();
                    return;
                }
                std.debug.print("phobos: PanelDue serial: {}\n", .{err});
            };
            serial.close();
            self.core.?.run(io, resetSerial, .{self});
            io.sleep(reconnect_delay, .awake) catch return;
        }
    }

    fn resetSerial(self: *PanelDue) void {
        self.initialized = false;
    }

    fn takeEmergency(self: *PanelDue) bool {
        const emergency = self.emergency_stop;
        self.emergency_stop = false;
        return emergency;
    }

    fn serialSession(self: *PanelDue, serial: *Serial) !void {
        const io = self.io.?;
        var line: [max_line]u8 = undefined;
        var length: usize = 0;
        var discard = false;
        var emergency_match: u32 = 0;
        var has_emergency = false;
        var bytes: [1024]u8 = undefined;
        while (true) {
            var pending: [1][]u8 = undefined;
            if (try self.output.get(io, &pending, 0) > 0) {
                defer self.gpa.free(pending[0]);
                try serial.writeTimeout(pending[0], .{ .duration = .{ .raw = write_timeout, .clock = .awake } });
            }
            const count = serial.readSomeTimeout(&bytes, .{ .duration = .{ .raw = serial_timeout, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            };
            if (count == 0) return error.EndOfStream;
            for (bytes[0..count]) |byte| {
                if (byte == '\n') {
                    if (discard and !has_emergency) {
                        self.core.?.run(io, handleGcodeResponse, .{ self, "!! GCode Processing Error: line too long" });
                    } else {
                        var utf8: [max_line]u8 = undefined;
                        const decoded = if (has_emergency) "M112" else validUtf8(line[0..length], &utf8);
                        self.core.?.run(io, receiveLine, .{ self, decoded }) catch |err| {
                            if (err != error.InvalidChecksum) self.core.?.run(io, processingError, .{ self, line[0..length] });
                        };
                        if (self.core.?.run(io, takeEmergency, .{self})) {
                            var arena = std.heap.ArenaAllocator.init(self.gpa);
                            defer arena.deinit();
                            _ = self.request("emergency_stop", .null, arena.allocator()) catch |err| {
                                if (err == error.Canceled) return err;
                                std.debug.print("phobos: PanelDue emergency stop: {}\n", .{err});
                                continue;
                            };
                        }
                    }
                    length = 0;
                    discard = false;
                    emergency_match = 0;
                    has_emergency = false;
                } else if (length < line.len) {
                    line[length] = byte;
                    length += 1;
                } else discard = true;
                emergency_match = (emergency_match << 8) | std.ascii.toUpper(byte);
                if (emergency_match == emergency_word) has_emergency = true;
            }
        }
    }
};

fn cleanFilename(a: Allocator, raw: []const u8) ![]const u8 {
    var name = std.mem.trim(u8, raw, " \"\t\n");
    if (std.mem.startsWith(u8, name, "0:/")) name = name[3..];
    if (std.mem.startsWith(u8, name, "gcodes/")) name = name[7..] else if (std.mem.startsWith(u8, name, "/gcodes/")) name = name[8..];
    if (name.len == 0) return error.InvalidParams;
    return if (name[0] == '/') name else try std.fmt.allocPrint(a, "/{s}", .{name});
}

fn validUtf8(bytes: []const u8, out: []u8) []const u8 {
    var offset: usize = 0;
    var length: usize = 0;
    while (offset < bytes.len) {
        const count = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch {
            offset += 1;
            continue;
        };
        if (count > bytes.len - offset) {
            offset += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(bytes[offset..][0..count]) catch {
            offset += 1;
            continue;
        };
        @memcpy(out[length..][0..count], bytes[offset..][0..count]);
        length += count;
        offset += count;
    }
    return out[0..length];
}

const DirectParams = struct { p: ?[]const u8 = null, s: ?i64 = null, r: ?i64 = null };
fn directParams(args: []const []const u8) !DirectParams {
    var params: DirectParams = .{};
    for (args) |arg| {
        if (arg.len == 0) continue;
        switch (arg[0]) {
            'S' => params.s = try std.fmt.parseInt(i64, arg[1..], 10),
            'R' => params.r = try std.fmt.parseInt(i64, arg[1..], 10),
            'P' => params.p = std.mem.trim(u8, arg[1..], " \"\t\n"),
            else => params.p = std.mem.trim(u8, arg, " \"\t\n"),
        }
    }
    return params;
}
fn get(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn field(value: Value, object: []const u8, key: []const u8) ?Value {
    const obj = get(value, object);
    return if (obj == .object) obj.object.get(key) else null;
}
fn number(value: Value, default: f64) f64 {
    const n = switch (value) {
        .float => value.float,
        .integer => @as(f64, @floatFromInt(value.integer)),
        else => return default,
    };
    return if (std.math.isFinite(n)) n else default;
}
fn vectorNumber(value: Value, index: usize, default: f64) f64 {
    return if (value == .array and value.array.items.len > index) number(value.array.items[index], default) else default;
}
fn updateVector(out: []f64, value: Value) void {
    for (out, 0..) |*n, index| n.* = vectorNumber(value, index, n.*);
}
fn rounded(value: f64, comptime decimals: u8) f64 {
    if (!std.math.isFinite(value)) return 0;
    const factor: f128 = comptime std.math.pow(f64, 10, @floatFromInt(decimals));
    // Extra precision retains binary64's decimal tie direction before rounding.
    const scaled = @as(f128, value) * factor;
    const lower = @floor(scaled);
    const remainder = scaled - lower;
    const even = @floor(lower / 2) == lower / 2;
    const nearest = if (remainder < 0.5 or (remainder == 0.5 and even)) lower else lower + 1;
    const result: f64 = @floatCast(nearest / factor);
    return if (result == 0) std.math.copysign(@as(f64, 0), value) else result;
}
fn floats(a: Allocator, values: []const f64, comptime decimals: u8) !Value {
    var array: std.json.Array = .init(a);
    for (values) |value| try array.append(.{ .float = rounded(value, decimals) });
    return .{ .array = array };
}
fn integers(a: Allocator, values: []const u8) !Value {
    var array: std.json.Array = .init(a);
    for (values) |value| try array.append(.{ .integer = value });
    return .{ .array = array };
}
fn secondsLeft(value: f64) i64 {
    return @intFromFloat(std.math.clamp(value, -9.22e18, 9.22e18));
}
extern "c" fn phobos_local_ctime(seconds: i64, buffer: [*]u8, capacity: usize) usize;

fn ctime(a: Allocator, seconds: f64) ![]const u8 {
    if (!std.math.isFinite(seconds) or seconds < -9.22e18 or seconds >= 9.22e18) return error.InvalidTime;
    var buffer: [64]u8 = undefined;
    const length = phobos_local_ctime(@intFromFloat(seconds), &buffer, buffer.len);
    if (length == 0) return error.InvalidTime;
    return std.fmt.allocPrint(a, "T{s}", .{buffer[0..length]});
}
/// Split a PanelDue line into gcode parts.
/// `out` receives the command and, for file commands, the trimmed rest of the
/// script (spaces preserved, possibly empty). Returns the filled slice of `out`.
pub fn parseLine(line: []const u8, enable_checksum: bool, out: [][]const u8) ParseError![]const []const u8 {
    const script = if (enable_checksum) blk: {
        const cs_index = std.mem.lastIndexOfScalar(u8, line, '*') orelse return error.InvalidChecksum;
        // Moonraker keeps a line number only when `int(line[1:space])` works.
        // Otherwise the script is everything before '*', so `M98*cs` stays M98.
        const start: usize = if (std.mem.indexOfScalar(u8, line, ' ')) |sp| inner: {
            if (sp == 0 or sp > cs_index) break :inner 0;
            _ = std.fmt.parseInt(i64, line[1..sp], 10) catch break :inner 0;
            break :inner sp + 1;
        } else 0;
        var sum: u8 = 0;
        for (line[0..cs_index]) |c| sum ^= c;
        const cs_text = std.mem.trim(u8, line[cs_index + 1 ..], " \r\n");
        const checksum = std.fmt.parseInt(u32, cs_text, 10) catch return error.InvalidChecksum;
        if ((sum & 0xFF) != checksum) return error.InvalidChecksum;
        const raw = if (start <= cs_index) line[start..cs_index] else line[0..0];
        break :blk std.mem.trim(u8, raw, " \t\r\n");
    } else line;

    var it = std.mem.tokenizeAny(u8, script, " \t");
    const cmd = it.next() orelse return out[0..0];
    if (out.len == 0) return out[0..0];
    out[0] = cmd;
    var n: usize = 1;
    if (isFileCmd(cmd)) {
        if (out.len < 2) return out[0..1];
        out[1] = std.mem.trim(u8, it.rest(), " \t\r\n");
        return out[0..2];
    }
    while (it.next()) |tok| {
        if (n >= out.len) break;
        out[n] = tok;
        n += 1;
    }
    return out[0..n];
}

fn checksumLine(buf: []u8, body: []const u8) []const u8 {
    var sum: u8 = 0;
    for (body) |c| sum ^= c;
    const n = std.fmt.bufPrint(buf, "{s}*{d}", .{ body, sum }) catch return body;
    return n;
}

test "processLine: file command keeps spaces and an empty argument" {
    var due = PanelDue{};
    try due.processLine("M23 my file.gco");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M23", due.parts[0]);
    try std.testing.expectEqualStrings("my file.gco", due.parts[1]);

    // paneldue.py always builds `[cmd, arg]` for file commands.
    try due.processLine("M98");
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M98", due.parts[0]);
    try std.testing.expectEqualStrings("", due.parts[1]);

    var out: [2][]const u8 = undefined;
    const parts = try parseLine(" \tM32  a b ", false, &out);
    try std.testing.expectEqualStrings("a b", parts[1]);
    try std.testing.expectEqual(@as(usize, 1), (try parseLine("M32 x", false, out[0..1])).len);
}

test "processLine: checksummed script is stripped before the command is split" {
    var raw: [64]u8 = undefined;
    const line = checksumLine(&raw, "N10 M32  plate.gco");
    var due = PanelDue{ .enable_checksum = true };
    try due.processLine(line);
    try std.testing.expectEqual(@as(usize, 2), due.part_count);
    try std.testing.expectEqualStrings("M32", due.parts[0]);
    try std.testing.expectEqualStrings("plate.gco", due.parts[1]);
}

test "processLine: bad checksum is rejected and M112 is emergency stop" {
    var due = PanelDue{ .enable_checksum = true };
    try std.testing.expectError(error.InvalidChecksum, due.processLine("N1 M23 f.gco*0"));
    due.enable_checksum = false;
    for ([_][]const u8{ "M112", "m112", "N12 m112 ; stop", "xxM112" }) |line| {
        due.emergency_stop = false;
        try due.processLine(line);
        try std.testing.expect(due.emergency_stop);
    }
}

test "fuzz processLine: arbitrary serial input preserves emergency detection" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const line = buf[0 .. smith.value(u8) % (buf.len + 1)];
            var due: PanelDue = .{};
            try due.processLine(line);
            try std.testing.expect(due.part_count <= due.parts.len);
            due.enable_checksum = true;
            due.processLine(line) catch |err| try std.testing.expectEqual(error.InvalidChecksum, err);
            var stop_buf: [buf.len + 4]u8 = undefined;
            const with_stop = try std.fmt.bufPrint(&stop_buf, "{s}m112", .{line});
            try due.processLine(with_stop);
            try std.testing.expect(due.emergency_stop);
            try std.testing.expectEqual(@as(usize, 0), due.part_count);
        }
    }.run, .{});
}

const testing = std.testing;
const Harness = struct {
    core: Core = .{},
    conns: @import("../server/connections.zig").Connections = undefined,
    bus: @import("../server/notify.zig").NotifyBus = undefined,
    klippy: Klippy.KlippyCtx = undefined,
    files: Files.FileCtx = undefined,
    due: PanelDue = .{},

    fn init(self: *Harness, a: Allocator, roots: []const Files.Root) !void {
        self.* = .{};
        self.conns = .init(a, &self.core);
        self.bus = .init(&self.core, &self.conns);
        self.klippy = try .init(a, &self.bus);
        self.klippy.setIo(testing.io);
        self.files = .{ .gpa = a, .roots = roots, .bus = null, .io = testing.io };
        self.due.bind(testing.io, a, &self.core, &self.klippy, &self.files);
    }
    fn deinit(self: *Harness) void {
        self.due.deinit();
        self.klippy.deinit();
        self.files.deinit();
        self.conns.deinit(testing.io);
    }
    fn response(self: *Harness, a: Allocator) !Value {
        var out: [1][]u8 = undefined;
        if (try self.due.output.get(testing.io, &out, 0) != 1) return error.MissingResponse;
        defer self.due.gpa.free(out[0]);
        try testing.expect(std.mem.endsWith(u8, out[0], "\r\n"));
        return std.json.parseFromSliceLeaky(Value, a, out[0], .{});
    }
    fn script(self: *Harness) ![]u8 {
        var out: [1]Work = undefined;
        if (try self.due.gcodes.get(testing.io, &out, 0) != 1) return error.MissingScript;
        return out[0].script;
    }
};

fn json(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

test "PanelDue configuration, command translation, confirmation and bounded queues" {
    var h: Harness = undefined;
    try h.init(testing.allocator, &.{});
    defer h.deinit();
    var cfg: ConfigParser = .init(testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[paneldue]\nserial: /dev/fixture\nbaud: 115200\nenable_checksum: false\nmacros: HOME G28, HEAT M109 S200\nconfirmed_macros: RESTART, SAFE G28\n", "paneldue.cfg");
    try h.due.configure(&cfg);
    try testing.expectEqual(@as(u32, 115200), h.due.baud);
    const translations = .{
        .{ "M0", "CANCEL_PRINT" },                                .{ "M24", "RESUME" },                                                              .{ "M25", "PAUSE" },
        .{ "M120", "SAVE_GCODE_STATE STATE=PANELDUE" },           .{ "M121", "RESTORE_GCODE_STATE STATE=PANELDUE" },                                 .{ "M999", "FIRMWARE_RESTART" },
        .{ "M23 0:/gcodes/my file.gcode", "M23 /my file.gcode" }, .{ "M32 /gcodes/my file.gcode", "SDCARD_PRINT_FILE FILENAME=\"/my file.gcode\"" }, .{ "M290 Z0.02", "SET_GCODE_OFFSET Z_ADJUST=0.02 MOVE=1" },
        .{ "M98 P\"/macros/HOME\"", "HOME G28" },                 .{ "G28 X Y", "G28 X Y" },
    };
    inline for (translations) |pair| {
        try h.due.receiveLine(pair[0]);
        const script = try h.script();
        defer testing.allocator.free(script);
        try testing.expectEqualStrings(pair[1], script);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try h.due.receiveLine("M98 P/macros/SAFE");
    const confirmation = try h.response(arena.allocator());
    try testing.expectEqual(@as(i64, 3), get(confirmation, "msgBox.mode").integer);
    try testing.expectEqualStrings("Confirmation Dialog", get(confirmation, "msgBox.title").string);
    try h.due.receiveLine("M292 P0");
    const script = try h.script();
    defer testing.allocator.free(script);
    try testing.expectEqualStrings("SAFE G28", script);
    try h.due.receiveLine("M292 P1");
    try testing.expectError(error.InvalidMacro, h.due.receiveLine("M98 Pmissing"));
    try testing.expectError(error.InvalidParams, h.due.receiveLine("M32"));
    try testing.expectError(error.InvalidParams, h.due.receiveLine("M290"));
    for (0..queue_capacity) |_| try h.due.receiveLine("G91");
    try testing.expectError(error.QueueFull, h.due.receiveLine("G90"));
}

test "PanelDue M408 merges partial status and sends errors and messages once" {
    var h: Harness = undefined;
    try h.init(testing.allocator, &.{});
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.due.receiveLine("M408 S1");
    const off = try h.response(a);
    try testing.expectEqualStrings("O", get(off, "status").string);
    try testing.expectEqualStrings("/macros", get(off, "dir").string);
    try h.due.applyConfig(a, try json(a, "{\"software_version\":\"v1\"}"), try json(a, "{\"printer\":{\"kinematics\":\"cartesian\"},\"extruder1\":{},\"heater_bed\":{},\"extruder\":{}}"));
    h.due.ready = true;
    h.due.statusUpdate(try json(a, "{\"motion_report\":{\"live_position\":[1.234,2,3.456,4.567]},\"gcode_move\":{\"speed_factor\":0.5,\"extrude_factor\":0.9,\"homing_origin\":[0,0,0.1234]},\"toolhead\":{\"homed_axes\":\"xz\",\"extruder\":\"extruder1\"},\"fan\":{\"speed\":0.3333},\"heater_bed\":{\"temperature\":50.55,\"target\":60},\"extruder\":{\"temperature\":200,\"target\":210},\"extruder1\":{\"temperature\":201,\"target\":215},\"display_status\":{\"message\":\"Ready\"},\"print_stats\":{\"state\":\"paused\"}}"));
    h.due.statusUpdate(try json(a, "{\"gcode_move\":{\"speed_factor\":0.75}}"));
    h.due.handleGcodeResponse("ok");
    try testing.expectEqual(@as(usize, 0), h.due.last_response.len);
    h.due.handleGcodeResponse("!! fixture error");
    try h.due.receiveLine("M408 S1 R4");
    const status = try h.response(a);
    try testing.expectEqualStrings("A", get(status, "status").string);
    try testing.expectEqualStrings("Repetier | Klipper v1", get(status, "firmwareName").string);
    try testing.expectEqualStrings("cartesian", get(status, "geometry").string);
    try testing.expectEqual(@as(i64, 2), get(status, "numTools").integer);
    try testing.expectEqual(@as(i64, 1), get(status, "tool").integer);
    try testing.expectEqual(@as(i64, 5), get(status, "seq").integer);
    try testing.expectEqualStrings("!! fixture error", get(status, "resp").string);
    try testing.expectEqual(@as(f64, 75), number(get(status, "sfactor"), 0));
    try testing.expectEqual(@as(f64, 1.23), number(get(status, "pos").array.items[0], 0));
    try testing.expectEqual(@as(f64, 0.123), number(get(status, "babystep"), 0));
    try testing.expectEqual(@as(i64, 0), get(status, "homed").array.items[1].integer);
    try testing.expectEqual(@as(i64, 1), get(status, "hstat").array.items[1].integer);
    try testing.expectEqual(@as(i64, 2), get(status, "hstat").array.items[2].integer);
    try testing.expectEqualStrings("Ready", get(status, "message").string);
    h.due.statusUpdate(try json(a, "{\"print_stats\":{\"state\":\"printing\",\"print_duration\":50},\"virtual_sdcard\":{\"progress\":0.25}}"));
    try h.due.receiveLine("M408 S0 R5");
    const resumed = try h.response(a);
    try testing.expectEqualStrings("R", get(resumed, "status").string);
    try testing.expectEqual(@as(i64, 150), get(resumed, "timesLeft").array.items[0].integer);
    try testing.expectEqual(Value.null, get(resumed, "resp"));
    try testing.expectEqual(Value.null, get(resumed, "message"));
    h.due.shutdown = true;
    try h.due.receiveLine("M408");
    try testing.expectEqualStrings("S", get(try h.response(a), "status").string);
    h.due.enable_checksum = true;
    try testing.expectError(error.InvalidChecksum, h.due.receiveLine("N3 G28*0"));
    var checked: [64]u8 = undefined;
    try h.due.receiveLine(checksumLine(&checked, "N4 M408 S0 R7"));
    try testing.expectEqualStrings("!! GCode Processing Error: N3 G28*0", get(try h.response(a), "resp").string);
}

test "PanelDue file responses use the checked gcodes root and real metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "part.gcode", .data = "; generated by PrusaSlicer 2.7\n; layer_height = 0.2\n; max_z_height = 12.34\n; estimated printing time (normal mode) = 1m 30s\n; filament used [mm] = 123.4\nG28\n" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(path);
    const roots = [_]Files.Root{.{ .name = "gcodes", .path = path, .full_access = true }};
    var h: Harness = undefined;
    try h.init(testing.allocator, &roots);
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try h.due.receiveLine("M20 S2 P0:/");
    const listing = try h.response(a);
    try testing.expectEqualStrings("/gcodes", get(listing, "dir").string);
    try testing.expectEqualStrings("*sub", get(listing, "files").array.items[0].string);
    try testing.expectEqualStrings("part.gcode", get(listing, "files").array.items[1].string);
    try h.due.receiveLine("M36 part.gcode");
    const md = try h.response(a);
    try testing.expectEqual(@as(i64, 0), get(md, "err").integer);
    try testing.expectEqual(@as(i64, 90), get(md, "printTime").integer);
    try testing.expectEqual(@as(f64, 0.2), number(get(md, "layerHeight"), 0));
    try testing.expect(std.mem.startsWith(u8, get(md, "lastModified").string, "T"));
    try h.due.receiveLine("M36 missing.gcode");
    try testing.expectEqual(@as(i64, 1), get(try h.response(a), "err").integer);
    try testing.expectError(error.InvalidParams, h.due.receiveLine("M30"));
    try testing.expectError(error.Forbidden, h.due.receiveLine("M30 ../outside.gcode"));
    try h.due.receiveLine("M30 part.gcode");
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "part.gcode", .{}));
    try h.due.receiveLine("M20 S2 P/macros");
    try testing.expectEqual(@as(usize, 2), get(try h.response(a), "files").array.items.len);
    try testing.expect(std.mem.startsWith(u8, try ctime(a, 0), "T"));
}

test "PanelDue allocation failures free queued scripts and responses" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            var h: Harness = undefined;
            try h.init(a, &.{});
            defer h.deinit();
            try h.due.receiveLine("G91");
            try h.due.receiveLine("M408");
            try h.due.receiveLine("M98 P/RESTART");
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try h.due.beep(try json(arena.allocator(), "{\"frequency\":440,\"duration\":0.25}"));
        }
    }.run, .{});
}

test "PanelDue PTY reads fragmented lines, returns CRLF JSON and joins silent workers" {
    const Pty = @import("../testutil/pty.zig").Pty;
    const io = testing.io;
    var pty = try Pty.init(io);
    defer pty.deinit();
    var slave = try Serial.open(io, pty.path(), 57600);
    defer slave.close();
    var h: Harness = undefined;
    try h.init(testing.allocator, &.{});
    defer h.deinit();
    h.due.serial_path = pty.path();
    try h.due.start();
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
    try pty.master.writeTimeout("M4", timeout);
    try pty.master.writeTimeout("08 S1\n", timeout);
    var response: [2048]u8 = undefined;
    var n: usize = 0;
    while (n < response.len and !std.mem.endsWith(u8, response[0..n], "\r\n")) n += try pty.master.readSomeTimeout(response[n..], timeout);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("O", get(try json(arena.allocator(), response[0..n]), "status").string);
    try h.core.run(io, PanelDue.beep, .{ &h.due, try json(arena.allocator(), "{\"frequency\":1000,\"duration\":0.02}") });
    n = try pty.master.readSomeTimeout(&response, timeout);
    const beep = try json(arena.allocator(), response[0..n]);
    try testing.expectEqual(@as(i64, 1000), get(beep, "beep_freq").integer);
    try testing.expectEqual(@as(i64, 20), get(beep, "beep_length").integer);
    h.core.lock(io);
    h.due.ready = true;
    h.core.unlock(io);
    var oversized: [max_line + 32]u8 = @splat('x');
    oversized[oversized.len - 1] = '\n';
    try pty.master.writeTimeout(&oversized, timeout);
    try pty.master.writeTimeout("M408 S0 R5\n", timeout);
    n = 0;
    while (n < response.len and !std.mem.endsWith(u8, response[0..n], "\r\n")) n += try pty.master.readSomeTimeout(response[n..], timeout);
    const error_response = try json(arena.allocator(), response[0..n]);
    try testing.expectEqualStrings("!! GCode Processing Error: line too long", get(error_response, "resp").string);
    const started = Io.Clock.Timestamp.now(io, .awake);
    h.due.deinit();
    try testing.expect(started.untilNow(io).raw.toMilliseconds() < 1000);
}

test "fuzz PanelDue commands, direct parameters, status snapshots and beep" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var h: Harness = undefined;
            try h.init(testing.allocator, &.{});
            defer h.deinit();
            var bytes: [128]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const raw = bytes[0..smith.valueRangeAtMostWithHash(u8, 0, bytes.len, 1)];
            var decoded: [bytes.len]u8 = undefined;
            try testing.expect(std.unicode.utf8ValidateSlice(validUtf8(raw, &decoded)));
            h.due.receiveLine(raw) catch {};
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var status: std.json.ObjectMap = .empty;
            var ps: std.json.ObjectMap = .empty;
            try ps.put(a, "filename", .{ .string = raw });
            try ps.put(a, "print_duration", .{ .float = smith.valueWithHash(f64, 2) });
            try status.put(a, "print_stats", .{ .object = ps });
            h.due.statusUpdate(.{ .object = status });
            h.due.ready = true;
            h.due.handleGcodeResponse(raw);
            const cmds = [_][]const u8{ "M408 S0 R1", "M408 S1", "M98 P/RESTART", "M292 P0", "M36", "M20 S2 P/macros", "M290 Z1", "M112" };
            for (cmds) |cmd| h.due.receiveLine(cmd) catch {};
            var params: std.json.ObjectMap = .empty;
            try params.put(a, "frequency", .{ .integer = smith.valueWithHash(i64, 3) });
            try params.put(a, "duration", .{ .float = smith.valueWithHash(f64, 4) });
            h.due.beep(.{ .object = params }) catch {};
            const seconds = smith.valueWithHash(f64, 5);
            _ = ctime(a, seconds) catch |err| switch (err) {
                error.InvalidTime => "",
                else => return err,
            };
            try testing.expect(h.due.part_count <= h.due.parts.len);
        }
    }.run, .{});
}

test "PanelDue ready worker discovers heaters and preserves ordered gcode without holding Core" {
    const io = testing.io;
    var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer server.deinit(io);
    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    const peer = try server.accept(io);
    defer peer.close(io);
    var h: Harness = undefined;
    try h.init(testing.allocator, &.{});
    defer h.deinit();
    h.klippy.stream = stream;
    h.klippy.state = .ready;
    h.klippy.connected.store(true, .release);
    h.due.serial_path = "paneldue-fixture";
    for (subscription_objects) |name| try h.klippy.addSubscriptionObject(name);
    try h.core.run(io, PanelDue.receiveLine, .{ &h.due, "G91" });
    try h.core.run(io, PanelDue.receiveLine, .{ &h.due, "G90" });
    for (2..queue_capacity) |_| try h.core.run(io, PanelDue.receiveLine, .{ &h.due, "G92 E0" });
    h.core.run(io, PanelDue.onState, .{ &h.due, Klippy.State.ready });
    h.due.gcode_worker = try io.concurrent(PanelDue.gcodeLoop, .{&h.due});
    var deadline: @import("../util/socket_deadline.zig").SocketDeadline = .{ .base_io = io, .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } } };
    var buffer: [4096]u8 = undefined;
    var reader = peer.reader(deadline.io(), &buffer);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replies = [_][]const u8{
        "{\"software_version\":\"vtest\"}",
        "{\"status\":{\"configfile\":{\"config\":{\"printer\":{\"kinematics\":\"corexy\"},\"extruder\":{},\"heater_bed\":{}}}}}",
        "{\"status\":{}}",
        "\"ok\"",
        "\"ok\"",
    };
    const methods = [_][]const u8{ "info", "objects/query", "objects/subscribe", "gcode/script", "gcode/script" };
    for (methods, replies, 0..) |method, reply, index| {
        const wire = try reader.interface.takeDelimiterInclusive(0x03);
        const request = try json(a, wire[0 .. wire.len - 1]);
        try testing.expectEqualStrings(method, get(request, "method").string);
        if (index == 2) {
            const objects = get(get(request, "params"), "objects");
            for (subscription_objects) |name| try testing.expect(objects.object.contains(name));
            try testing.expect(objects.object.contains("extruder"));
            try testing.expect(objects.object.contains("heater_bed"));
        }
        if (index >= 3) {
            try testing.expectEqualStrings(if (index == 3) "G91" else "G90", get(get(request, "params"), "script").string);
            try h.core.run(io, PanelDue.receiveLine, .{ &h.due, "M408 S1" });
            const status = try h.response(a);
            try testing.expectEqualStrings("I", get(status, "status").string);
            try testing.expectEqualStrings("corexy", get(status, "geometry").string);
            try testing.expectEqual(@as(i64, 1), get(status, "numTools").integer);
        }
        const id = try std.json.Stringify.valueAlloc(a, get(request, "id"), .{});
        try h.klippy.dispatchFrame(io, try std.fmt.allocPrint(a, "{{\"id\":{s},\"result\":{s}}}", .{ id, reply }));
    }
    const started = Io.Clock.Timestamp.now(io, .awake);
    h.due.deinit();
    try testing.expect(started.untilNow(io).raw.toMilliseconds() < 1000);
}

test "PanelDue config rejects missing serial and bad baud and permits an empty macro list" {
    var due: PanelDue = .{};
    var cfg: ConfigParser = .init(testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[paneldue]\n", "fixture");
    try testing.expectError(error.InvalidParams, due.configure(&cfg));
    try cfg.parseString("[paneldue]\nserial: fixture\nbaud: 123456\n", "fixture");
    try testing.expectError(error.UnsupportedBaud, due.configure(&cfg));
    var empty: ConfigParser = .init(testing.allocator);
    defer empty.deinit();
    try empty.parseString("[paneldue]\nserial: fixture\nmacros:\nconfirmed_macros:\n", "fixture");
    try due.configure(&empty);
    try testing.expectEqual(@as(usize, 0), due.macro_count);
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("G28 café", validUtf8("G28 caf\xc3\xa9\xff\xe2", &out));
    var text: Text(3) = .{};
    text.set("aaé");
    try testing.expectEqualStrings("aa", text.slice());
    try testing.expectEqual(@as(f64, 50.5), rounded(50.55, 1));
    try testing.expectEqual(@as(f64, 2.67), rounded(2.675, 2));
    try testing.expectEqual(@as(f64, 2), rounded(2.5, 0));
    try testing.expectEqual(@as(f64, 4), rounded(3.5, 0));
    try testing.expectEqual(std.math.floatMax(f64), rounded(std.math.floatMax(f64), 3));
}

test "PanelDue ctime uses local offsets and daylight saving with English date fields" {
    const Case = struct { zone: []const u8, timestamp: []const u8, text: []const u8 };
    for ([_]Case{
        .{ .zone = "UTC0", .timestamp = "0", .text = "Thu Jan  1 00:00:00 1970\n" },
        .{ .zone = "UTC0", .timestamp = "-1", .text = "Wed Dec 31 23:59:59 1969\n" },
        .{ .zone = "SGT-8", .timestamp = "0", .text = "Thu Jan  1 08:00:00 1970\n" },
        .{ .zone = "EST5EDT,M3.2.0/2,M11.1.0/2", .timestamp = "1705320000", .text = "Mon Jan 15 07:00:00 2024\n" },
        .{ .zone = "EST5EDT,M3.2.0/2,M11.1.0/2", .timestamp = "1721044800", .text = "Mon Jul 15 08:00:00 2024\n" },
    }) |case| {
        var environment = std.process.Environ.Map.init(testing.allocator);
        defer environment.deinit();
        try environment.put("TZ", case.zone);
        const result = try @import("../util/process.zig").run(testing.allocator, testing.io, .{
            .argv = &.{ @import("build_options").local_time_probe, case.timestamp, "ctime" },
            .environ_map = &environment,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(256),
            .timeout = .{ .deadline = .fromNow(testing.io, .{ .raw = .fromSeconds(3), .clock = .awake }) },
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try testing.expectEqualStrings(case.text, result.stdout);
    }
    var buffer: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), phobos_local_ctime(0, &buffer, buffer.len));
    try testing.expectError(error.InvalidTime, ctime(testing.allocator, std.math.nan(f64)));
}

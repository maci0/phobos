//! GPIO buttons with debounced edge events and bounded action templates.
const std = @import("std");
const gpio = @import("gpio_input.zig");
const templates = @import("sensor_template.zig");
const notify = @import("../server/notify.zig");
const Core = @import("../server/core.zig").Core;
const Config = @import("../config/confighelper.zig").ConfigParser;
const clock = @import("../util/clock.zig");
const sleep = @import("../util/sleep.zig");
const json = @import("../json/value.zig");
const Value = std.json.Value;
const max_user_data_bytes = 64 * 1024;

pub const Event = struct {
    elapsed_time: f64 = 0,
    received_time: f64 = 0,
    render_time: f64 = 0,
    pressed: bool = false,
};

pub const Button = struct {
    name: []const u8,
    pin: gpio.Pin,
    minimum_event_time: f64 = 0,
    debounce_period: f64 = 0.05,
    on_press: ?templates.Template = null,
    on_release: ?templates.Template = null,
    event: Event = .{},
    user_data: Value = .{ .object = .empty },
    candidate: bool = false,
    stable: bool = false,
    debounce_at: ?f64 = null,
    last_event_time: f64 = 0,
    input: ?gpio.Input = null,
    reader: ?std.Io.Future(void) = null,
    owner: *ButtonCtx,

    fn deinit(self: *Button, alloc: std.mem.Allocator) void {
        if (self.on_press) |*template| template.deinit();
        if (self.on_release) |*template| template.deinit();
        json.free(alloc, self.user_data);
        alloc.free(self.name);
    }
};

pub const ButtonCtx = struct {
    gpa: std.mem.Allocator,
    bus: ?*notify.NotifyBus,
    io: ?std.Io = null,
    core: ?*Core = null,
    gpio_root: []const u8 = "/dev",
    buttons: std.StringHashMap(*Button),
    stopped: std.Io.Event = .unset,
    worker: ?std.Io.Future(void) = null,
    method_ctx: ?*anyopaque = null,
    /// Called under Core. Blocking methods must release Core themselves.
    call_method: ?*const fn (*anyopaque, []const u8, Value, std.mem.Allocator) anyerror!Value = null,

    pub fn init(alloc: std.mem.Allocator, bus: ?*notify.NotifyBus) ButtonCtx {
        return .{ .gpa = alloc, .bus = bus, .buttons = std.StringHashMap(*Button).init(alloc) };
    }

    pub fn deinit(self: *ButtonCtx) void {
        self.stop();
        var it = self.buttons.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.buttons.deinit();
    }

    pub fn configure(self: *ButtonCtx, cfg: *const Config) !void {
        const sections = try cfg.sectionNames(self.gpa);
        defer self.gpa.free(sections);
        for (sections) |section| {
            if (!std.mem.startsWith(u8, section, "button ")) continue;
            const name = section["button ".len..];
            if (name.len == 0 or self.buttons.contains(name)) return error.InvalidButton;
            const press = cfg.get(section, "on_press");
            const release = cfg.get(section, "on_release");
            if (press == null and release == null) return error.MissingButtonTemplate;
            const minimum = cfg.getFloat(section, "minimum_event_time") catch |err| if (err == error.NoOption) @as(f64, 0) else return err;
            const debounce = cfg.getFloat(section, "debounce_period") catch |err| if (err == error.NoOption) @as(f64, 0.05) else return err;
            if (minimum < 0 or debounce < 0.01) return error.InvalidButton;
            const pin = try gpio.parsePin(cfg.get(section, "pin") orelse return error.InvalidPin);
            const button = try self.gpa.create(Button);
            errdefer self.gpa.destroy(button);
            button.* = .{ .name = try self.gpa.dupe(u8, name), .pin = pin, .minimum_event_time = minimum, .debounce_period = debounce, .owner = self };
            errdefer button.deinit(self.gpa);
            if (press) |source| button.on_press = try templates.Template.init(self.gpa, source);
            if (release) |source| button.on_release = try templates.Template.init(self.gpa, source);
            const key = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(key);
            try self.buttons.put(key, button);
        }
    }

    /// Explicit daemon startup; tests ingest fake edges and tick synchronously.
    pub fn start(self: *ButtonCtx, io: std.Io) !void {
        if (self.worker != null) return;
        self.io = io;
        self.stopped.reset();
        errdefer self.stop();
        var it = self.buttons.valueIterator();
        while (it.next()) |item| {
            const button = item.*;
            button.input = try gpio.Input.open(io, self.gpio_root, button.pin);
            self.initialize(button, try button.input.?.value(io), clock.monotonicSeconds(io));
            button.reader = try io.concurrent(readEdges, .{button});
        }
        if (self.buttons.count() != 0) self.worker = try io.concurrent(timerWorker, .{self});
    }

    pub fn stop(self: *ButtonCtx) void {
        const io = self.io orelse return;
        self.stopped.set(io);
        if (self.worker) |*worker| {
            worker.cancel(io);
            self.worker = null;
        }
        var it = self.buttons.valueIterator();
        while (it.next()) |item| {
            const button = item.*;
            if (button.reader) |*reader| {
                reader.cancel(io);
                button.reader = null;
            }
            if (button.input) |input| {
                input.close(io);
                button.input = null;
            }
        }
    }

    pub fn initialize(_: *ButtonCtx, button: *Button, pressed: bool, now: f64) void {
        button.stable = pressed;
        button.candidate = pressed;
        button.event.pressed = pressed;
        button.last_event_time = now;
        button.debounce_at = null;
    }

    /// Edge readers call under Core; template execution happens on the timer worker.
    pub fn edge(self: *ButtonCtx, name: []const u8, pressed: bool, now: f64) !void {
        const button = self.buttons.get(name) orelse return error.NotFound;
        button.candidate = pressed;
        if (button.debounce_at == null) button.debounce_at = now + button.debounce_period;
    }

    pub fn tick(self: *ButtonCtx, now: f64, alloc: std.mem.Allocator) !void {
        var it = self.buttons.valueIterator();
        while (it.next()) |item| {
            const button = item.*;
            if (button.debounce_at) |deadline| {
                if (now < deadline) continue;
                button.debounce_at = null;
                if (button.stable == button.candidate) continue;
                button.stable = button.candidate;
                const elapsed = @max(0, now - button.last_event_time);
                button.last_event_time = now;
                if (elapsed < button.minimum_event_time) continue;
                const template = if (button.stable) &(button.on_press orelse continue) else &(button.on_release orelse continue);
                button.event = .{ .pressed = button.stable, .elapsed_time = elapsed, .received_time = now, .render_time = if (self.io) |io| clock.monotonicSeconds(io) else now };
                var vars: std.json.ObjectMap = .empty;
                try vars.put(alloc, "event", try eventValue(alloc, button.event));
                var user_data = (try json.deepCopy(alloc, button.user_data)).object;
                try user_data.put(alloc, "__native", .{ .string = "user_data" });
                try vars.put(alloc, "user_data", .{ .object = user_data });
                var rendering = Render{ .ctx = self, .button = button };
                _ = template.renderText(alloc, vars, .{ .ctx = &rendering, .call = Render.call }) catch |err|
                    std.debug.print("phobos: warning: button '{s}' template failed: {}\n", .{ button.name, err });
            }
        }
    }
};

const Render = struct {
    ctx: *ButtonCtx,
    button: *Button,
    notified: bool = false,

    fn call(raw: *anyopaque, name: []const u8, args: []const Value, kwargs: std.json.ObjectMap, alloc: std.mem.Allocator) templates.RenderError!Value {
        const self: *Render = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, name, "call_method")) {
            if (args.len == 0 or args.len > 2 or args[0] != .string) return error.EvalError;
            const params: Value = if (args.len == 2) args[1] else .{ .object = kwargs };
            if (params != .object) return error.EvalError;
            const method = self.ctx.call_method orelse return error.EvalError;
            return method(self.ctx.method_ctx orelse return error.EvalError, args[0].string, params, alloc) catch error.EvalError;
        }
        if (std.mem.eql(u8, name, "user_data.__setitem__")) {
            if (args.len != 2 or args[0] != .string or std.mem.eql(u8, args[0].string, "__native")) return error.EvalError;
            var updated = (try json.deepCopy(alloc, self.button.user_data)).object;
            try updated.put(alloc, args[0].string, args[1]);
            var storage: [max_user_data_bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&storage);
            std.json.Stringify.value(Value{ .object = updated }, .{}, &writer) catch return error.OutOfMemory;
            const owned = try json.deepCopy(self.ctx.gpa, .{ .object = updated });
            json.free(self.ctx.gpa, self.button.user_data);
            self.button.user_data = owned;
            return .null;
        }
        if (std.mem.eql(u8, name, "send_notification")) {
            if (args.len > 1) return error.EvalError;
            if (self.notified) return .null;
            self.notified = true;
            const bus = self.ctx.bus orelse return .null;
            const io = self.ctx.io orelse return .null;
            var status: std.json.ObjectMap = .empty;
            try status.put(alloc, "name", .{ .string = self.button.name });
            try status.put(alloc, "type", .{ .string = "gpio" });
            try status.put(alloc, "event", try eventValue(alloc, self.button.event));
            try status.put(alloc, "aux", if (args.len == 1) args[0] else .null);
            var params: std.json.Array = .init(alloc);
            try params.append(.{ .object = status });
            bus.emitLocked(io, notify.names.button_event, .{ .array = params }) catch return error.EvalError;
            return .null;
        }
        return error.EvalError;
    }
};

fn eventValue(alloc: std.mem.Allocator, event: Event) error{OutOfMemory}!Value {
    var value: std.json.ObjectMap = .empty;
    try value.put(alloc, "elapsed_time", .{ .float = event.elapsed_time });
    try value.put(alloc, "received_time", .{ .float = event.received_time });
    try value.put(alloc, "render_time", .{ .float = event.render_time });
    try value.put(alloc, "pressed", .{ .bool = event.pressed });
    return .{ .object = value };
}

fn readEdges(button: *Button) void {
    const ctx = button.owner;
    const io = ctx.io orelse return;
    const input = button.input orelse return;
    while (!ctx.stopped.isSet()) {
        const pressed = input.read(io) catch |err| {
            if (err != error.Canceled) std.debug.print("phobos: warning: button '{s}' GPIO read failed: {}\n", .{ button.name, err });
            return;
        };
        if (ctx.core) |core| core.lock(io);
        defer if (ctx.core) |core| core.unlock(io);
        ctx.edge(button.name, pressed, clock.monotonicSeconds(io)) catch |err|
            std.debug.print("phobos: warning: button '{s}' edge failed: {}\n", .{ button.name, err });
    }
}

fn timerWorker(ctx: *ButtonCtx) void {
    const io = ctx.io orelse return;
    while (!sleep.untilStopped(io, .fromMilliseconds(10), &ctx.stopped)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        if (ctx.core) |core| core.lock(io);
        defer if (ctx.core) |core| core.unlock(io);
        ctx.tick(clock.monotonicSeconds(io), arena.allocator()) catch |err|
            std.debug.print("phobos: warning: button timer failed: {}\n", .{err});
    }
}

test "button templates dispatch methods, persist user data and debounce GPIO edges" {
    const Calls = struct {
        count: usize = 0,
        fn call(raw: *anyopaque, method: []const u8, params: Value, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("test.action", method);
            try std.testing.expectEqualStrings("psu", params.object.get("device").?.string);
            self.count += 1;
            return .null;
        }
    };
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[button test]\npin: !gpiochip0/gpio23\nminimum_event_time: 0.1\non_press:\n {% do user_data.__setitem__('count', user_data.count|default(0) + 1) %}\n {% do call_method('test.action', device='psu') %}\non_release:\n {% do user_data.__setitem__('released', event.pressed) %}\n", "test");
    var ctx = ButtonCtx.init(std.testing.allocator, null);
    defer ctx.deinit();
    try ctx.configure(&cfg);
    var calls: Calls = .{};
    ctx.method_ctx = &calls;
    ctx.call_method = Calls.call;
    const button = ctx.buttons.get("test").?;
    ctx.initialize(button, false, 1);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try ctx.edge("test", true, 1.2);
    try ctx.edge("test", false, 1.21);
    try ctx.tick(1.26, a);
    try std.testing.expectEqual(@as(usize, 0), calls.count);
    try ctx.edge("test", true, 1.3);
    try ctx.tick(1.34, a);
    try std.testing.expectEqual(@as(usize, 0), calls.count);
    try ctx.tick(1.36, a);
    try std.testing.expectEqual(@as(usize, 1), calls.count);
    try std.testing.expectEqual(@as(i64, 1), button.user_data.object.get("count").?.integer);
    try std.testing.expect(button.event.pressed);
    try ctx.edge("test", false, 1.5);
    try ctx.tick(1.56, a);
    try std.testing.expectEqual(false, button.user_data.object.get("released").?.bool);
    try ctx.edge("test", true, 1.7);
    try ctx.tick(1.76, a);
    try std.testing.expectEqual(@as(i64, 2), button.user_data.object.get("count").?.integer);
}

test "button config fails on missing templates, invalid pins and invalid timings" {
    for ([_][]const u8{
        "[button test]\npin: gpio2\n",
        "[button test]\npin: invalid\non_press: test\n",
        "[button test]\npin: gpio2\non_press: test\ndebounce_period: 0.001\n",
    }) |source| {
        var cfg = Config.init(std.testing.allocator);
        defer cfg.deinit();
        try cfg.parseString(source, "test");
        var ctx = ButtonCtx.init(std.testing.allocator, null);
        defer ctx.deinit();
        if (ctx.configure(&cfg)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "button configuration releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var cfg = Config.init(alloc);
            defer cfg.deinit();
            try cfg.parseString("[button test]\npin: gpio2\non_press: {% do send_notification() %}\non_release: {% do send_notification('released') %}\n", "test");
            var ctx = ButtonCtx.init(alloc, null);
            defer ctx.deinit();
            try ctx.configure(&cfg);
        }
    }.run, .{});
}

test "button reader consumes a fake GPIO edge and joins before closing its input" {
    const io = std.testing.io;
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[button test]\npin: gpio2\non_press: {% do send_notification() %}\n", "test");
    var ctx = ButtonCtx.init(std.testing.allocator, null);
    defer ctx.deinit();
    try ctx.configure(&cfg);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [16]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[8..12], 1, @import("builtin").cpu.arch.endian());
    try tmp.dir.writeFile(io, .{ .sub_path = "events", .data = &bytes });
    const button = ctx.buttons.get("test").?;
    ctx.io = io;
    button.input = .{ .file = try tmp.dir.openFile(io, "events", .{}) };
    var done: std.Io.Event = .unset;
    const Reader = struct {
        fn run(btn: *Button, completed: *std.Io.Event, aio: std.Io) void {
            defer completed.set(aio);
            readEdges(btn);
        }
    };
    button.reader = try io.concurrent(Reader.run, .{ button, &done, io });
    try done.waitTimeout(io, .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(2), .clock = .awake }) });
    ctx.stop();
    try std.testing.expect(button.candidate);
    try std.testing.expect(button.input == null and button.reader == null);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    ctx.gpio_root = root;
    try std.testing.expectError(error.FileNotFound, ctx.start(io));
}

test "button notification reaches a socket once with event fields and auxiliary data" {
    const io = std.testing.io;
    const Connections = @import("../server/connections.zig").Connections;
    const SocketDeadline = @import("../util/socket_deadline.zig").SocketDeadline;
    var core = Core.init();
    var connections = Connections.init(std.testing.allocator, &core);
    defer connections.deinit(io);
    var bus = notify.NotifyBus.init(&core, &connections);
    var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    const server = try listener.accept(io);
    defer server.close(io);
    var deadline: SocketDeadline = .{ .base_io = io, .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(2), .clock = .awake }) } };
    const Writer = struct {
        writer: std.Io.net.Stream.Writer,
        fn write(raw: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.writer.interface.writeAll(bytes);
            try self.writer.interface.writeByte('\n');
            try self.writer.interface.flush();
        }
    };
    var writer: Writer = .{ .writer = server.writer(deadline.io(), &.{}) };
    const connection = try connections.add(io, false);
    connections.attachWriter(io, connection, &writer, Writer.write);
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();
    try cfg.parseString("[button test]\npin: gpio2\non_press: {% do send_notification('first') %}{% do send_notification('second') %}\n", "test");
    var ctx = ButtonCtx.init(std.testing.allocator, &bus);
    defer ctx.deinit();
    try ctx.configure(&cfg);
    ctx.io = io;
    ctx.core = &core;
    ctx.initialize(ctx.buttons.get("test").?, false, 1);
    try ctx.edge("test", true, 2);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try core.run(io, ButtonCtx.tick, .{ &ctx, 2.1, arena.allocator() });
    var read_buffer: [2048]u8 = undefined;
    var reader = client.reader(deadline.io(), &read_buffer);
    const frame = try reader.interface.takeDelimiterExclusive('\n');
    const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), frame, .{});
    try std.testing.expectEqualStrings("notify_button_event", parsed.object.get("method").?.string);
    const status = parsed.object.get("params").?.array.items[0].object;
    try std.testing.expectEqualStrings("test", status.get("name").?.string);
    try std.testing.expectEqualStrings("first", status.get("aux").?.string);
    try std.testing.expect(status.get("event").?.object.get("pressed").?.bool);
    try std.testing.expectEqual(@as(u8, '\n'), try reader.interface.takeByte());
    try std.testing.expectEqual(@as(usize, 0), reader.interface.bufferedLen());
}

test "fuzz button edge timing and templates stay bounded" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var cfg = Config.init(std.testing.allocator);
            defer cfg.deinit();
            try cfg.parseString("[button test]\npin: gpio2\non_press: {% do user_data.__setitem__('pressed', true) %}\non_release: {% do send_notification() %}\n", "test");
            var ctx = ButtonCtx.init(std.testing.allocator, null);
            defer ctx.deinit();
            try ctx.configure(&cfg);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var now: f64 = 0;
            for (0..16) |index| {
                now += @as(f64, @floatFromInt(smith.valueRangeAtMostWithHash(u8, 0, 100, @intCast(index)))) / 100;
                try ctx.edge("test", index % 2 == 0, now);
                try ctx.tick(now + 0.1, arena.allocator());
            }
        }
    }.run, .{});
}

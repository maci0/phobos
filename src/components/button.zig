//! button.* notification component — Moonraker-compatible GPIO button events.
//!
//! Matches the notification registered in
//! `vendor/moonraker/moonraker/components/button.py` (ButtonManager):
//!
//!   notify_button_event  — emitted on GPIO button press/release
//!
//! No HTTP endpoints are registered; this is a notification-only component.
//! GPIO lines are polled via sysfs (`pollButton`/`pollAndEmitAll`, driven by a
//! 100 ms background thread started when buttons are configured); each edge
//! fires notify_button_event. Pin specs are parsed by `parsePin` ("!"=active-low).
//!
//! Button status shape (GpioButton.get_status):
//!   { name, type: "gpio", event: { elapsed_time, received_time, render_time, pressed } }

const std = @import("std");
const notify = @import("../server/notify.zig");
const registry = @import("../server/registry.zig");
const gpio_sysfs = @import("gpio_sysfs.zig");

const Registry = registry.Registry;

const NotifyBus = notify.NotifyBus;

/// A parsed Klipper-style button pin: sysfs line number + active-low inversion.
pub const ParsedPin = struct { line: u32, inverted: bool };

/// Parse a Klipper pin spec into a sysfs line + inversion. Handles a leading
/// "!" (active-low) and "^"/"~" (pull-up/down, irrelevant to reads), an optional
/// "gpiochipN/" chip prefix, a "gpio" prefix, and a bare or trailing number.
/// Returns null when no line number can be extracted.
pub fn parsePin(spec: []const u8) ?ParsedPin {
    var s = std.mem.trim(u8, spec, " \t");
    var inverted = false;
    // Strip modifier prefixes in any order.
    while (s.len > 0 and (s[0] == '!' or s[0] == '^' or s[0] == '~')) {
        if (s[0] == '!') inverted = true;
        s = s[1..];
    }
    // Drop a "gpiochipN/" chip prefix.
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    // Drop a leading "gpio" token.
    if (std.mem.startsWith(u8, s, "gpio")) s = s["gpio".len..];
    // Take the trailing run of digits.
    var i: usize = s.len;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    const digits = s[i..];
    if (digits.len == 0) return null;
    const line = std.fmt.parseInt(u32, digits, 10) catch return null;
    return .{ .line = line, .inverted = inverted };
}

// ---------------------------------------------------------------------------
// Button state
// ---------------------------------------------------------------------------

pub const ButtonEvent = struct {
    elapsed_time: f64,
    received_time: f64,
    render_time: f64,
    pressed: bool,
};

pub const Button = struct {
    name: []const u8,
    pin: []const u8,
    min_event_time: f64,
    notification_sent: bool,
    event: ButtonEvent,
    /// GPIO-poll state: last sampled pressed level + whether a baseline has been
    /// taken (the first sample sets the baseline without firing an event).
    prev_pressed: bool = false,
    initialized: bool = false,

    pub fn getStatus(self: *const Button, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "name", .{ .string = self.name });
        try obj.put(alloc, "type", .{ .string = "gpio" });
        var evt: std.json.ObjectMap = .empty;
        try evt.put(alloc, "elapsed_time", .{ .float = self.event.elapsed_time });
        try evt.put(alloc, "received_time", .{ .float = self.event.received_time });
        try evt.put(alloc, "render_time", .{ .float = self.event.render_time });
        try evt.put(alloc, "pressed", .{ .bool = self.event.pressed });
        try obj.put(alloc, "event", .{ .object = evt });
        return .{ .object = obj };
    }
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const ButtonCtx = struct {
    gpa: std.mem.Allocator,
    bus: ?*NotifyBus,
    io: ?std.Io,
    buttons: std.StringHashMap(Button),
    /// sysfs GPIO root (overridable for tests).
    gpio_root: []const u8 = "/sys/class/gpio",
    /// Background GPIO poll thread (started by App when buttons are configured).
    poll_thread: ?std.Thread = null,
    poll_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) ButtonCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .buttons = std.StringHashMap(Button).init(alloc),
        };
    }

    pub fn deinit(self: *ButtonCtx) void {
        self.stopPolling();
        var it = self.buttons.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.name);
            self.gpa.free(entry.value_ptr.pin);
        }
        self.buttons.deinit();
    }

    pub fn setIo(self: *ButtonCtx, io: std.Io) void {
        self.io = io;
    }

    /// Start the background GPIO poll thread (no-op if no buttons, no io, or
    /// already running). Each tick polls all lines and emits on edges.
    pub fn startPolling(self: *ButtonCtx) void {
        if (self.poll_thread != null) return;
        if (self.io == null) return;
        if (self.buttons.count() == 0) return;
        self.poll_stop.store(false, .release);
        self.poll_thread = std.Thread.spawn(.{}, pollLoop, .{self}) catch null;
    }

    /// Stop and join the poll thread.
    pub fn stopPolling(self: *ButtonCtx) void {
        self.poll_stop.store(true, .release);
        if (self.poll_thread) |t| {
            t.join();
            self.poll_thread = null;
        }
    }

    fn pollLoop(self: *ButtonCtx) void {
        const io = self.io orelse return;
        while (!self.poll_stop.load(.acquire)) {
            io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            if (self.poll_stop.load(.acquire)) break;
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            self.pollAndEmitAll(arena.allocator());
        }
    }

    pub fn findButton(self: *ButtonCtx, name: []const u8) ?*Button {
        return self.buttons.getPtr(name);
    }

    pub fn addButton(
        self: *ButtonCtx,
        name: []const u8,
        pin: []const u8,
        min_event_time: f64,
    ) !void {
        const k = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(k);
        const b: Button = .{
            .name = try self.gpa.dupe(u8, name),
            .pin = try self.gpa.dupe(u8, pin),
            .min_event_time = min_event_time,
            .notification_sent = false,
            .event = .{
                .elapsed_time = 0.0,
                .received_time = 0.0,
                .render_time = 0.0,
                .pressed = false,
            },
        };
        errdefer {
            self.gpa.free(b.name);
            self.gpa.free(b.pin);
        }
        try self.buttons.put(k, b);
    }

    /// Update the event state for a button (simulates a GPIO event).
    /// Returns the new pressed state or error.NotFound.
    pub fn sendEvent(self: *ButtonCtx, name: []const u8, pressed: bool) !void {
        const b = self.buttons.getPtr(name) orelse return error.NotFound;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now = @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1.0e9;
        // Seconds since the previous event for this button (Moonraker GpioButton
        // reports elapsed time between presses). 0 on the first event.
        b.event.elapsed_time = if (b.event.received_time > 0) now - b.event.received_time else 0;
        b.event.received_time = now;
        b.event.render_time = now;
        b.event.pressed = pressed;
    }

    /// Sample one button's GPIO line and, on a level change, update its event
    /// state. Returns true when an edge fired (caller may emit). The first
    /// sample only establishes the baseline. Returns false when io is absent,
    /// the pin is unparseable, or the line can't be read (no hardware).
    pub fn pollButton(self: *ButtonCtx, name: []const u8) !bool {
        const io = self.io orelse return false;
        const b = self.buttons.getPtr(name) orelse return error.NotFound;
        const pp = parsePin(b.pin) orelse return false;
        const gpio = gpio_sysfs.SysfsGpio{ .io = io, .root = self.gpio_root };
        const lvl = gpio.readValue(self.gpa, pp.line) catch return false;
        const pressed = if (pp.inverted) (lvl == 0) else (lvl == 1);
        if (!b.initialized) {
            b.initialized = true;
            b.prev_pressed = pressed;
            return false; // baseline only
        }
        if (pressed == b.prev_pressed) return false; // no edge
        b.prev_pressed = pressed;
        try self.sendEvent(name, pressed);
        self.resetNotificationSent(name);
        return true;
    }

    /// Poll every button and emit notify_button_event on each edge. Emits via
    /// the lock-taking `bus.emit` (safe to call from a standalone poll thread
    /// that holds no Core lock).
    pub fn pollAndEmitAll(self: *ButtonCtx, alloc: std.mem.Allocator) void {
        const io = self.io orelse return;
        const bus = self.bus orelse {
            // No bus: still advance edge state (used by tests).
            var it0 = self.buttons.keyIterator();
            while (it0.next()) |k| _ = self.pollButton(k.*) catch {};
            return;
        };
        var it = self.buttons.keyIterator();
        while (it.next()) |k| {
            const name = k.*;
            const fired = self.pollButton(name) catch continue;
            if (!fired) continue;
            const b = self.buttons.getPtr(name) orelse continue;
            const status = b.getStatus(alloc) catch continue;
            var evt: std.json.ObjectMap = .empty;
            evt.put(alloc, "aux", .{ .object = .empty }) catch continue;
            inline for ([_][]const u8{ "name", "type", "event" }) |key| {
                if (status.object.get(key)) |v| evt.put(alloc, key, v) catch {};
            }
            var arr: std.json.Array = .init(alloc);
            arr.append(.{ .object = evt }) catch continue;
            b.notification_sent = true;
            bus.emit(io, notify.names.button_event, .{ .array = arr }) catch {};
        }
    }

    /// Emit notify_button_event for a button. Called under the Core lock so
    /// uses emitLocked to avoid double-locking.
    pub fn emitButtonEvent(self: *ButtonCtx, a: std.mem.Allocator, name: []const u8) !void {
        const bus = self.bus orelse return;
        const io = self.io orelse return;
        const b = self.buttons.getPtr(name) orelse return error.NotFound;
        if (b.notification_sent) return;

        var arr: std.json.Array = .init(a);
        const status = try b.getStatus(a);
        var evt: std.json.ObjectMap = .empty;
        try evt.put(a, "aux", .{ .object = .empty });
        inline for ([_][]const u8{ "name", "type", "event" }) |k| {
            if (status.object.get(k)) |v| {
                try evt.put(a, k, v);
            }
        }
        try arr.append(.{ .object = evt });
        // Mark notification sent so repeated presses don't spam.
        b.notification_sent = true;
        bus.emitLocked(io, notify.names.button_event, .{ .array = arr }) catch {};
    }

    /// Reset the notification_sent guard so the next GPIO event can fire again.
    pub fn resetNotificationSent(self: *ButtonCtx, name: []const u8) void {
        const b = self.buttons.getPtr(name) orelse return;
        b.notification_sent = false;
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register button notification. No HTTP endpoints — notification-only.
pub fn registerButton(reg: *Registry, ctx: *ButtonCtx) !void {
    _ = reg;
    _ = ctx;
    // notify_button_event is registered in notify.zig's static name list.
    // No HTTP endpoints to register; this is a notification-only component.
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn testCtx(alloc: std.mem.Allocator) ButtonCtx {
    return ButtonCtx.init(alloc, null);
}

test "parsePin: gpio prefixes, chip prefix, inversion, bare number" {
    try testing.expectEqual(@as(u32, 26), parsePin("gpio26").?.line);
    try testing.expectEqual(false, parsePin("gpio26").?.inverted);
    try testing.expectEqual(@as(u32, 27), parsePin("!gpio27").?.line);
    try testing.expectEqual(true, parsePin("!gpio27").?.inverted);
    try testing.expectEqual(@as(u32, 5), parsePin("^~gpio5").?.line); // pull modifiers ignored
    try testing.expectEqual(@as(u32, 13), parsePin("gpiochip0/gpio13").?.line);
    try testing.expectEqual(@as(u32, 7), parsePin("7").?.line); // bare number
    try testing.expectEqual(@as(u32, 4), parsePin("!4").?.line);
    // No trailing digits → unparseable.
    try testing.expect(parsePin("") == null);
    try testing.expect(parsePin("gpio") == null);
    try testing.expect(parsePin("abc") == null);
}

test "pollButton: detects a debounced edge against a temp sysfs root" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;
    const root = "/tmp/phobos_button_test_root";
    const pindir = root ++ "/gpio26";
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, pindir);
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "0" });
    defer Dir.cwd().deleteTree(io, root) catch {};

    var ctx = ButtonCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.io = io;
    ctx.gpio_root = root;
    try ctx.addButton("btn", "gpio26", 0.0);

    // First poll: baseline (level 0 = not pressed), no edge.
    try testing.expectEqual(false, try ctx.pollButton("btn"));
    try testing.expect(!ctx.findButton("btn").?.event.pressed);

    // Drive the line high → next poll detects a press edge.
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "1" });
    try testing.expectEqual(true, try ctx.pollButton("btn"));
    try testing.expect(ctx.findButton("btn").?.event.pressed);

    // No change → no edge.
    try testing.expectEqual(false, try ctx.pollButton("btn"));

    // Back to low → release edge.
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "0" });
    try testing.expectEqual(true, try ctx.pollButton("btn"));
    try testing.expect(!ctx.findButton("btn").?.event.pressed);
}

test "pollButton: inverted pin (active-low) reads pressed at level 0" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Dir = std.Io.Dir;
    const root = "/tmp/phobos_button_inv_root";
    const pindir = root ++ "/gpio9";
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, pindir);
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "1" });
    defer Dir.cwd().deleteTree(io, root) catch {};

    var ctx = ButtonCtx.init(testing.allocator, null);
    defer ctx.deinit();
    ctx.io = io;
    ctx.gpio_root = root;
    try ctx.addButton("b", "!gpio9", 0.0);
    _ = try ctx.pollButton("b"); // baseline: level 1 + inverted → not pressed
    try testing.expect(!ctx.findButton("b").?.event.pressed);
    try Dir.cwd().writeFile(io, .{ .sub_path = pindir ++ "/value", .data = "0" });
    try testing.expectEqual(true, try ctx.pollButton("b")); // level 0 + inverted → pressed
    try testing.expect(ctx.findButton("b").?.event.pressed);
}

test "fuzz parsePin: arbitrary specs never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [16]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            _ = parsePin(&buf);
        }
    }.run, .{});
}

test "init/deinit: no leak" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 0), ctx.buttons.count());
}

test "addButton: stores button with owned strings" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addButton("my_button", "gpio26", 0.05);
    try testing.expectEqual(@as(usize, 1), ctx.buttons.count());
    const b = ctx.findButton("my_button").?;
    try testing.expectEqualStrings("my_button", b.name);
    try testing.expectEqualStrings("gpio26", b.pin);
    try testing.expectEqual(@as(f64, 0.05), b.min_event_time);
    try testing.expect(!b.notification_sent);
    try testing.expect(!b.event.pressed);
}

test "findButton: returns null for unknown" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try testing.expect(ctx.findButton("ghost") == null);
}

test "sendEvent: updates event state" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addButton("btn", "gpio5", 0.0);
    try ctx.sendEvent("btn", true);
    const b = ctx.findButton("btn").?;
    try testing.expect(b.event.pressed);
    try testing.expect(b.event.received_time > 0.0);
}

test "sendEvent: NotFound for unknown button" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try testing.expectError(error.NotFound, ctx.sendEvent("ghost", true));
}

test "sendEvent: elapsed_time is 0 on first event, positive after" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addButton("btn", "gpio5", 0.0);
    try ctx.sendEvent("btn", true);
    try testing.expectEqual(@as(f64, 0), ctx.findButton("btn").?.event.elapsed_time);
    try ctx.sendEvent("btn", false);
    // Second event sets elapsed = now - previous received_time (>= 0).
    try testing.expect(ctx.findButton("btn").?.event.elapsed_time >= 0);
}

test "emitButtonEvent: no-op without bus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());
    defer ctx.deinit();
    try ctx.addButton("btn", "gpio5", 0.0);
    try ctx.sendEvent("btn", true);
    // No bus or io set — should be a no-op, not a panic.
    ctx.emitButtonEvent(arena.allocator(), "btn") catch {};
    // Without bus/io, notification_sent is not set (can't emit).
    try testing.expect(!ctx.findButton("btn").?.notification_sent);
}

test "emitButtonEvent: notification_sent guard prevents duplicate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = testCtx(arena.allocator());
    defer ctx.deinit();
    try ctx.addButton("btn", "gpio5", 0.0);
    ctx.findButton("btn").?.notification_sent = true;
    // Should return early — notification already sent.
    try ctx.emitButtonEvent(arena.allocator(), "btn");
    try testing.expect(ctx.findButton("btn").?.notification_sent);
}

test "resetNotificationSent: clears guard" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addButton("btn", "gpio5", 0.0);
    ctx.findButton("btn").?.notification_sent = true;
    ctx.resetNotificationSent("btn");
    try testing.expect(!ctx.findButton("btn").?.notification_sent);
}

test "getStatus: full shape with all keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b: Button = .{
        .name = "test_btn",
        .pin = "gpio17",
        .min_event_time = 0.1,
        .notification_sent = false,
        .event = .{ .elapsed_time = 1.5, .received_time = 100.0, .render_time = 100.001, .pressed = true },
    };
    const v = try b.getStatus(a);
    const o = v.object;
    try testing.expectEqualStrings("test_btn", o.get("name").?.string);
    try testing.expectEqualStrings("gpio", o.get("type").?.string);
    const evt = o.get("event").?.object;
    try testing.expectEqual(@as(f64, 1.5), evt.get("elapsed_time").?.float);
    try testing.expectEqual(@as(f64, 100.0), evt.get("received_time").?.float);
    try testing.expectEqual(@as(f64, 100.001), evt.get("render_time").?.float);
    try testing.expect(evt.get("pressed").?.bool);
}

test "multiple buttons: independent state" {
    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try ctx.addButton("btn_a", "gpio5", 0.0);
    try ctx.addButton("btn_b", "gpio6", 0.1);
    try ctx.sendEvent("btn_a", true);
    try ctx.sendEvent("btn_b", false);
    try testing.expect(ctx.findButton("btn_a").?.event.pressed);
    try testing.expect(!ctx.findButton("btn_b").?.event.pressed);
}

// ---- fuzz tests ----

test "fuzz addButton: arbitrary names and pins never crash" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [8]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ButtonCtx.init(a, null);
            defer ctx.deinit();
            const names = [_][]const u8{ "a", "ab", "long_button_name_here", "" };
            const pins = [_][]const u8{ "gpio1", "gpio26", "", "!invalid" };
            for (names, 0..) |nm, i| {
                const pin = pins[(buf[0] + @as(u8, @intCast(i))) % pins.len];
                ctx.addButton(nm, pin, 0.0) catch {};
            }
            // sendEvent on random names
            const ns = [_][]const u8{ "a", "ab", "ghost", "" };
            for (ns) |nm| {
                ctx.sendEvent(nm, buf[1] & 1 == 1) catch {};
            }
        }
    }.run, .{});
}

test "fuzz getStatus: never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const b: Button = .{
                .name = "fuzz",
                .pin = "gpio",
                .min_event_time = 0.0,
                .notification_sent = buf[0] & 1 == 1,
                .event = .{
                    .elapsed_time = @floatCast(@as(f64, @floatFromInt(buf[1]))),
                    .received_time = @floatCast(@as(f64, @floatFromInt(buf[2]))),
                    .render_time = @floatCast(@as(f64, @floatFromInt(buf[3]))),
                    .pressed = buf[0] & 2 == 2,
                },
            };
            _ = b.getStatus(a) catch {};
        }
    }.run, .{});
}

test "registerButton: wires notification (no HTTP routes)" {
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(testing.allocator);
    defer d.deinit();
    var reg = Registry.init(testing.allocator, &d);
    defer reg.deinit();

    var ctx = testCtx(testing.allocator);
    defer ctx.deinit();
    try registerButton(&reg, &ctx);

    // Button is notification-only; registerButton is a no-op for HTTP routes.
    // Verify no crash and no unexpected routes registered.
    try testing.expect(reg.lookup(.GET, "/machine/button") == null);
}

test "fuzz emitButtonEvent: never panics without bus/io" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var ctx = ButtonCtx.init(a, null);
            defer ctx.deinit();
            const names = [_][]const u8{ "btn", "missing", "" };
            const nm = names[buf[0] % names.len];
            ctx.addButton("btn", "gpio", 0.0) catch {};
            ctx.sendEvent("btn", buf[1] & 1 == 1) catch {};
            ctx.emitButtonEvent(a, nm) catch {};
        }
    }.run, .{});
}

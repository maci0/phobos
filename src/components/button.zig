//! button.* notification component — Moonraker-compatible GPIO button events.
//!
//! Matches the notification registered in
//! `vendor/moonraker/moonraker/components/button.py` (ButtonManager):
//!
//!   notify_button_event  — emitted on GPIO button press/release
//!
//! No HTTP endpoints are registered; this is a notification-only component.
//! GPIO hardware monitoring is stubbed (no real GPIO pin reads). The state
//! machine and notification emission infrastructure are real and follow the
//! same pattern as power/wled: state tracked in memory, hardware stubbed.
//!
//! Button status shape (GpioButton.get_status):
//!   { name, type: "gpio", event: { elapsed_time, received_time, render_time, pressed } }

const std = @import("std");
const notify = @import("../server/notify.zig");
const registry = @import("../server/registry.zig");

const Registry = registry.Registry;

const NotifyBus = notify.NotifyBus;

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

    pub fn init(alloc: std.mem.Allocator, bus: ?*NotifyBus) ButtonCtx {
        return .{
            .gpa = alloc,
            .bus = bus,
            .io = null,
            .buttons = std.StringHashMap(Button).init(alloc),
        };
    }

    pub fn deinit(self: *ButtonCtx) void {
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
        b.event.received_time = now;
        b.event.render_time = now;
        b.event.pressed = pressed;
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

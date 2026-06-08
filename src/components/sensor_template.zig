//! Minimal Jinja-subset evaluator for Moonraker MQTT sensor
//! `state_response_template`s.
//!
//! Moonraker renders the template with a context of `payload` (the decoded MQTT
//! message string) and a `set_result(name, value)` callback that records a
//! measurement (sensor.py `_on_state_update`). Templates therefore look like:
//!
//!     {% set resp = payload|fromjson %}
//!     {% set _ = set_result("temperature", resp.temperature|float) %}
//!     {% set _ = set_result("humidity", resp["humidity"]|float) %}
//!
//! This is NOT a full Jinja engine — it implements exactly the subset those
//! templates use: `{% set NAME = EXPR %}` / `{{ EXPR }}` blocks, member/index
//! access, the `fromjson|float|int|round|abs|default|string` filters, and the
//! `set_result(name, value)` call. Everything is arena-scoped per render, so it
//! costs nothing between MQTT messages and fits phobos's memory budget.

const std = @import("std");
const Value = std.json.Value;

pub const RenderError = error{ ParseError, EvalError, OutOfMemory };

const Ctx = struct {
    arena: std.mem.Allocator,
    payload: []const u8,
    vars: std.StringHashMapUnmanaged(Value) = .empty,
    /// Measurements recorded by set_result(name, value): name → number.
    out: *std.json.ObjectMap,
};

/// Render `tmpl` against `payload`, recording each `set_result(name, value)`
/// into `out` (an ObjectMap of name → .integer/.float). `arena` owns all
/// intermediate allocations; the caller frees it.
pub fn render(arena: std.mem.Allocator, tmpl: []const u8, payload: []const u8, out: *std.json.ObjectMap) RenderError!void {
    var ctx = Ctx{ .arena = arena, .payload = payload, .out = out };
    var i: usize = 0;
    while (i < tmpl.len) {
        // Find the next block opener "{%" or "{{".
        const open = std.mem.indexOfScalarPos(u8, tmpl, i, '{') orelse break;
        if (open + 1 >= tmpl.len or (tmpl[open + 1] != '%' and tmpl[open + 1] != '{')) {
            i = open + 1;
            continue;
        }
        const is_stmt = tmpl[open + 1] == '%';
        const close_tok: []const u8 = if (is_stmt) "%}" else "}}";
        const close = std.mem.indexOfPos(u8, tmpl, open + 2, close_tok) orelse return error.ParseError;
        const inner = std.mem.trim(u8, tmpl[open + 2 .. close], " \t\r\n");
        try evalBlock(&ctx, inner);
        i = close + 2;
    }
}

/// A block is either `set NAME = EXPR` or a bare expression (e.g. a set_result
/// call). A leading `_ =` (Jinja's discard idiom) is tolerated.
fn evalBlock(ctx: *Ctx, inner: []const u8) RenderError!void {
    if (inner.len == 0) return;
    if (std.mem.startsWith(u8, inner, "set ") or std.mem.startsWith(u8, inner, "set\t")) {
        const rest = std.mem.trim(u8, inner[4..], " \t");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.ParseError;
        const name = std.mem.trim(u8, rest[0..eq], " \t");
        const expr_src = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        var p = Parser{ .src = expr_src, .ctx = ctx };
        const v = try p.parseExpr();
        try p.expectEnd();
        // `set _ = ...` discards the binding (used to invoke set_result).
        if (!std.mem.eql(u8, name, "_")) {
            const key = try ctx.arena.dupe(u8, name);
            try ctx.vars.put(ctx.arena, key, v);
        }
        return;
    }
    // Bare expression (its side effects, e.g. set_result, are what matter).
    var p = Parser{ .src = inner, .ctx = ctx };
    _ = try p.parseExpr();
    try p.expectEnd();
}

// ---------------------------------------------------------------------------
// Expression parser/evaluator (recursive descent)
//
//   expr    := pipe
//   pipe    := postfix ( '|' filter )*
//   postfix := primary ( '.' ident | '[' expr ']' | '(' args ')' )*
//   primary := number | string | ident | '(' expr ')'
// ---------------------------------------------------------------------------

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    ctx: *Ctx,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
    }
    fn peek(self: *Parser) ?u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn expectEnd(self: *Parser) RenderError!void {
        if (self.peek() != null) return error.ParseError;
    }

    fn parseExpr(self: *Parser) RenderError!Value {
        var v = try self.parsePostfix();
        while (self.peek()) |c| {
            if (c != '|') break;
            self.pos += 1; // consume '|'
            v = try self.applyFilter(v);
        }
        return v;
    }

    fn parsePostfix(self: *Parser) RenderError!Value {
        var v = try self.parsePrimary();
        while (self.peek()) |c| {
            switch (c) {
                '.' => {
                    self.pos += 1;
                    const name = try self.parseIdent();
                    v = try member(self.ctx, v, name);
                },
                '[' => {
                    self.pos += 1;
                    const idx = try self.parseExpr();
                    if (self.peek() != ']') return error.ParseError;
                    self.pos += 1;
                    v = try indexValue(self.ctx, v, idx);
                },
                else => break,
            }
        }
        return v;
    }

    fn parsePrimary(self: *Parser) RenderError!Value {
        const c = self.peek() orelse return error.ParseError;
        if (c == '(') {
            self.pos += 1;
            const v = try self.parseExpr();
            if (self.peek() != ')') return error.ParseError;
            self.pos += 1;
            return v;
        }
        if (c == '"' or c == '\'') return self.parseString();
        if (c == '-' or std.ascii.isDigit(c)) return self.parseNumber();
        // Identifier: payload, a variable, or a call (set_result/range-like).
        const name = try self.parseIdent();
        if (self.peek() == '(') return self.parseCall(name);
        if (std.mem.eql(u8, name, "payload")) return .{ .string = self.ctx.payload };
        if (std.mem.eql(u8, name, "none") or std.mem.eql(u8, name, "None")) return .null;
        if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "True")) return .{ .bool = true };
        if (std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "False")) return .{ .bool = false };
        return self.ctx.vars.get(name) orelse error.EvalError;
    }

    fn parseIdent(self: *Parser) RenderError![]const u8 {
        self.skipWs();
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_') self.pos += 1 else break;
        }
        if (self.pos == start) return error.ParseError;
        return self.src[start..self.pos];
    }

    fn parseString(self: *Parser) RenderError!Value {
        const quote = self.src[self.pos];
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != quote) self.pos += 1;
        if (self.pos >= self.src.len) return error.ParseError;
        const s = self.src[start..self.pos];
        self.pos += 1; // closing quote
        return .{ .string = s };
    }

    fn parseNumber(self: *Parser) RenderError!Value {
        self.skipWs();
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        var is_float = false;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isDigit(ch)) {
                self.pos += 1;
            } else if (ch == '.') {
                is_float = true;
                self.pos += 1;
            } else break;
        }
        const tok = self.src[start..self.pos];
        if (is_float) {
            return .{ .float = std.fmt.parseFloat(f64, tok) catch return error.ParseError };
        }
        return .{ .integer = std.fmt.parseInt(i64, tok, 10) catch return error.ParseError };
    }

    /// Parse a call: only `set_result(name, value)` is supported.
    fn parseCall(self: *Parser, name: []const u8) RenderError!Value {
        self.pos += 1; // consume '('
        var args: [4]Value = undefined;
        var n: usize = 0;
        if (self.peek() != ')') {
            while (true) {
                if (n >= args.len) return error.ParseError;
                args[n] = try self.parseExpr();
                n += 1;
                const sep = self.peek() orelse return error.ParseError;
                if (sep == ',') {
                    self.pos += 1;
                    continue;
                }
                if (sep == ')') break;
                return error.ParseError;
            }
        }
        self.pos += 1; // consume ')'
        if (std.mem.eql(u8, name, "set_result")) {
            if (n != 2) return error.EvalError;
            const key = switch (args[0]) {
                .string => |s| s,
                else => return error.EvalError,
            };
            try self.ctx.out.put(self.ctx.arena, try self.ctx.arena.dupe(u8, key), toNumber(args[1]));
            return .null;
        }
        return error.EvalError;
    }

    /// Apply a `|filter` (already consumed the '|') to `v`.
    fn applyFilter(self: *Parser, v: Value) RenderError!Value {
        const name = try self.parseIdent();
        // Optional filter argument list: default(x), round(n).
        var arg: ?Value = null;
        if (self.peek() == '(') {
            self.pos += 1;
            if (self.peek() != ')') arg = try self.parseExpr();
            if (self.peek() != ')') return error.ParseError;
            self.pos += 1;
        }
        if (std.mem.eql(u8, name, "fromjson")) {
            const s = switch (v) {
                .string => |str| str,
                else => return error.EvalError,
            };
            const parsed = std.json.parseFromSliceLeaky(Value, self.ctx.arena, s, .{}) catch return error.EvalError;
            return parsed;
        } else if (std.mem.eql(u8, name, "float")) {
            return .{ .float = toFloat(v) orelse if (arg) |a| toFloat(a) orelse 0 else return error.EvalError };
        } else if (std.mem.eql(u8, name, "int")) {
            return .{ .integer = toInt(v) orelse if (arg) |a| toInt(a) orelse 0 else return error.EvalError };
        } else if (std.mem.eql(u8, name, "abs")) {
            return absValue(v);
        } else if (std.mem.eql(u8, name, "round")) {
            const f = toFloat(v) orelse return error.EvalError;
            const ndigits: f64 = if (arg) |a| @floatFromInt(toInt(a) orelse 0) else 0;
            const scale = std.math.pow(f64, 10, ndigits);
            return .{ .float = @round(f * scale) / scale };
        } else if (std.mem.eql(u8, name, "default")) {
            return switch (v) {
                .null => arg orelse v,
                else => v,
            };
        } else if (std.mem.eql(u8, name, "string")) {
            return .{ .string = try toString(self.ctx.arena, v) };
        }
        return error.EvalError;
    }
};

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

fn member(ctx: *Ctx, v: Value, name: []const u8) RenderError!Value {
    _ = ctx;
    return switch (v) {
        .object => |o| o.get(name) orelse .null,
        else => error.EvalError,
    };
}

fn indexValue(ctx: *Ctx, v: Value, idx: Value) RenderError!Value {
    _ = ctx;
    switch (v) {
        .object => |o| {
            const key = switch (idx) {
                .string => |s| s,
                else => return error.EvalError,
            };
            return o.get(key) orelse .null;
        },
        .array => |a| {
            const i = toInt(idx) orelse return error.EvalError;
            if (i < 0 or i >= a.items.len) return error.EvalError;
            return a.items[@intCast(i)];
        },
        else => return error.EvalError,
    }
}

/// Coerce a value to a JSON number (int preferred), for set_result.
fn toNumber(v: Value) Value {
    return switch (v) {
        .integer, .float => v,
        .bool => |b| .{ .integer = if (b) 1 else 0 },
        else => if (toInt(v)) |i| .{ .integer = i } else if (toFloat(v)) |f| .{ .float = f } else .{ .integer = 0 },
    };
}

fn toFloat(v: Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null,
        .bool => |b| if (b) 1.0 else 0.0,
        else => null,
    };
}

fn toInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch blk: {
            const f = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch break :blk null;
            break :blk @intFromFloat(f);
        },
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}

fn absValue(v: Value) Value {
    return switch (v) {
        .integer => |i| .{ .integer = if (i < 0) -i else i },
        .float => |f| .{ .float = @abs(f) },
        else => v,
    };
}

fn toString(arena: std.mem.Allocator, v: Value) RenderError![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch error.OutOfMemory,
        .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}) catch error.OutOfMemory,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        else => error.EvalError,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn renderToMap(arena: std.mem.Allocator, tmpl: []const u8, payload: []const u8) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    try render(arena, tmpl, payload, &out);
    return out;
}

test "fromjson + member access + float, two measurements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl =
        \\{% set resp = payload|fromjson %}
        \\{% set _ = set_result("temperature", resp.temperature|float) %}
        \\{% set _ = set_result("humidity", resp["humidity"]|float) %}
    ;
    const out = try renderToMap(a, tmpl, "{\"temperature\": 21.5, \"humidity\": 47}");
    try testing.expectEqual(@as(f64, 21.5), out.get("temperature").?.float);
    try testing.expectEqual(@as(f64, 47.0), out.get("humidity").?.float);
}

test "bare {{ }} set_result, int filter, nested access" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl = "{% set d = payload|fromjson %}{{ set_result(\"p\", d.sensor.power|int) }}";
    const out = try renderToMap(a, tmpl, "{\"sensor\": {\"power\": \"1234\"}}");
    try testing.expectEqual(@as(i64, 1234), out.get("p").?.integer);
}

test "round + default filters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderToMap(a,
        "{% set d = payload|fromjson %}{% set _ = set_result(\"v\", d.x|round(2)) %}{% set _ = set_result(\"y\", d.missing|default(9)|float) %}",
        "{\"x\": 3.14159}");
    try testing.expectApproxEqAbs(@as(f64, 3.14), out.get("v").?.float, 1e-9);
    try testing.expectEqual(@as(f64, 9.0), out.get("y").?.float);
}

test "payload used directly as a scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderToMap(a, "{% set _ = set_result(\"raw\", payload|float) %}", "42.0");
    try testing.expectEqual(@as(f64, 42.0), out.get("raw").?.float);
}

test "malformed templates error, never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.json.ObjectMap = .empty;
    try testing.expectError(error.ParseError, render(a, "{% set x = %}", "{}", &out));
    try testing.expectError(error.ParseError, render(a, "{{ unclosed", "{}", &out));
    try testing.expectError(error.EvalError, render(a, "{{ set_result(\"a\") }}", "{}", &out)); // wrong arity
    try testing.expectError(error.EvalError, render(a, "{{ undefined_var }}", "{}", &out));
}

test "fuzz render: arbitrary templates + payloads never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tbuf: [128]u8 = undefined;
            var pbuf: [128]u8 = undefined;
            const tn = smith.valueRangeAtMostWithHash(u32, 0, 128, 0);
            const pn = smith.valueRangeAtMostWithHash(u32, 0, 128, 1);
            smith.bytesWithHash(tbuf[0..tn], 2);
            smith.bytesWithHash(pbuf[0..pn], 3);
            var out: std.json.ObjectMap = .empty;
            render(a, tbuf[0..tn], pbuf[0..pn], &out) catch {};
        }
    }.run, .{});
}

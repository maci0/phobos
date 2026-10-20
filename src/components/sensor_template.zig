//! A small Jinja2-subset template engine matching Moonraker's config Jinja
//! environment (`template.py`: `jinja2.Environment('{%', '%}', '{', '}')`):
//!
//!   * `{% ... %}`  statements   (set, if/elif/else/endif, for/else/endfor)
//!   * `{ ... }`    expressions   (rendered into the output text)
//!   * `{# ... #}`  comments
//!
//! `Template.init` parses the statement structure once (a malformed template
//! fails there, like Moonraker's `config.gettemplate`); `Template.render` is
//! the MQTT-sensor path: it provides `payload` + a `set_result(name, value)`
//! callable that records numeric measurements, and discards the text.
//! Expressions are parsed and evaluated together on each render.
//!
//! This is NOT full Jinja (no inheritance/macros/imports/sandbox); it implements
//! the language subset Moonraker realistically uses. Render state is
//! arena-scoped per render; a template keeps only its source and statement tree.

const std = @import("std");
const jv = @import("../json/value.zig");
const Value = std.json.Value;

pub const RenderError = error{ ParseError, EvalError, OutOfMemory };

/// Temporary render storage stays on the bounded handler stack.
const max_render_bytes = 64 * 1024;
/// Counts executed nodes, loop iterations and expression operands per render.
const max_render_steps = 10_000;

// ===========================================================================
// Public API
// ===========================================================================

/// A parsed template. Owns a copy of its source and its statement tree.
pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,

    pub fn init(gpa: std.mem.Allocator, src: []const u8) RenderError!Template {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const nodes = try parse(a, try a.dupe(u8, src));
        return .{ .arena = arena, .nodes = nodes };
    }

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }

    /// Execute with `payload` + `set_result`, recording measurements into
    /// `out` (name → .integer/.float). Only result keys enter `arena`; temporary
    /// evaluation uses at most `max_render_bytes` and `max_render_steps`.
    pub fn render(self: *const Template, arena: std.mem.Allocator, payload: []const u8, out: *std.json.ObjectMap) RenderError!void {
        var storage: [max_render_bytes]u8 = undefined;
        var bounded = std.heap.FixedBufferAllocator.init(&storage);
        const scratch = bounded.allocator();
        var results: std.json.ObjectMap = .empty;
        var ctx = Ctx{ .arena = scratch, .out = &results };
        try ctx.vars.put(scratch, "payload", .{ .string = payload });
        var sink = std.Io.Writer.Discarding.init(&.{});
        try exec(&ctx, self.nodes, &sink.writer);
        var it = results.iterator();
        while (it.next()) |entry| try out.put(arena, try arena.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }
};

// ===========================================================================
// AST
// ===========================================================================

const Node = union(enum) {
    text: []const u8,
    output: []const u8, // expression source
    set: struct { name: []const u8, expr: []const u8 },
    expr_stmt: []const u8, // bare expression (side effects, e.g. set_result)
    if_: struct { branches: []Branch, else_body: ?[]Node },
    for_: struct { vars: [2][]const u8, nvars: u8, seq: []const u8, body: []Node, else_body: ?[]Node },
};

const Branch = struct { cond: []const u8, body: []Node };

// ===========================================================================
// Tokenizer + parser → AST
// ===========================================================================

const Token = union(enum) {
    text: []const u8,
    output: []const u8, // inner of { ... }
    stmt: []const u8, // inner of {% ... %}
};

/// `depth` counts open if/for blocks; parsing rejects nesting past `Ctx.max_depth`.
const TokList = struct { items: []Token, pos: usize = 0, depth: u16 = 0 };

fn tokenize(arena: std.mem.Allocator, src: []const u8) RenderError![]Token {
    var list: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < src.len) {
        if (src[i] != '{') {
            i += 1;
            continue;
        }
        // Flush preceding literal text.
        if (i > text_start) try list.append(arena, .{ .text = src[text_start..i] });
        const c1: u8 = if (i + 1 < src.len) src[i + 1] else 0;
        if (c1 == '%') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "%}") orelse return error.ParseError;
            try list.append(arena, .{ .stmt = std.mem.trim(u8, src[i + 2 .. end], " \t\r\n") });
            i = end + 2;
        } else if (c1 == '#') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "#}") orelse return error.ParseError;
            i = end + 2; // comment: dropped
        } else {
            // Variable `{ ... }` (Moonraker single-brace), ends at first '}'.
            const end = std.mem.indexOfScalarPos(u8, src, i + 1, '}') orelse return error.ParseError;
            try list.append(arena, .{ .output = std.mem.trim(u8, src[i + 1 .. end], " \t\r\n") });
            i = end + 1;
        }
        text_start = i;
    }
    if (i > text_start) try list.append(arena, .{ .text = src[text_start..i] });
    return list.toOwnedSlice(arena);
}

fn parse(arena: std.mem.Allocator, src: []const u8) RenderError![]Node {
    const toks = try tokenize(arena, src);
    var tl = TokList{ .items = toks };
    return parseNodes(arena, &tl, &.{});
}

/// Parse nodes until a statement whose keyword is in `stop` (consumed by the
/// caller, left at tl.pos). `stop` keywords: endif/elif/else/endfor.
fn parseNodes(arena: std.mem.Allocator, tl: *TokList, stop: []const []const u8) RenderError![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    while (tl.pos < tl.items.len) {
        const t = tl.items[tl.pos];
        switch (t) {
            .text => |s| {
                tl.pos += 1;
                try nodes.append(arena, .{ .text = s });
            },
            .output => |s| {
                tl.pos += 1;
                try nodes.append(arena, .{ .output = s });
            },
            .stmt => |s| {
                const kw = firstWord(s);
                for (stop) |k| if (std.mem.eql(u8, kw, k)) return nodes.toOwnedSlice(arena);
                tl.pos += 1;
                if (std.mem.eql(u8, kw, "set")) {
                    try nodes.append(arena, try parseSet(s));
                } else if (std.mem.eql(u8, kw, "if") or std.mem.eql(u8, kw, "for")) {
                    tl.depth += 1;
                    defer tl.depth -= 1;
                    if (tl.depth > Ctx.max_depth) return error.ParseError;
                    try nodes.append(arena, try if (kw[0] == 'i') parseIf(arena, tl, s) else parseFor(arena, tl, s));
                } else {
                    try nodes.append(arena, .{ .expr_stmt = s });
                }
            },
        }
    }
    return nodes.toOwnedSlice(arena);
}

fn parseSet(s: []const u8) RenderError!Node {
    const rest = std.mem.trim(u8, s[3..], " \t");
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.ParseError;
    return .{ .set = .{
        .name = std.mem.trim(u8, rest[0..eq], " \t"),
        .expr = std.mem.trim(u8, rest[eq + 1 ..], " \t"),
    } };
}

fn parseIf(arena: std.mem.Allocator, tl: *TokList, first_stmt: []const u8) RenderError!Node {
    var branches: std.ArrayList(Branch) = .empty;
    var cond = std.mem.trim(u8, first_stmt[2..], " \t");
    const stops = [_][]const u8{ "elif", "else", "endif" };
    while (true) {
        const body = try parseNodes(arena, tl, &stops);
        try branches.append(arena, .{ .cond = cond, .body = body });
        const closer = currentStmt(tl) orelse return error.ParseError;
        const kw = firstWord(closer);
        tl.pos += 1;
        if (std.mem.eql(u8, kw, "elif")) {
            cond = std.mem.trim(u8, closer[4..], " \t");
            continue;
        }
        if (std.mem.eql(u8, kw, "else")) {
            const else_body = try parseNodes(arena, tl, &[_][]const u8{"endif"});
            _ = currentStmt(tl) orelse return error.ParseError;
            tl.pos += 1; // consume endif
            return .{ .if_ = .{ .branches = try branches.toOwnedSlice(arena), .else_body = else_body } };
        }
        // endif
        return .{ .if_ = .{ .branches = try branches.toOwnedSlice(arena), .else_body = null } };
    }
}

fn parseFor(arena: std.mem.Allocator, tl: *TokList, stmt: []const u8) RenderError!Node {
    // for VAR [, VAR2] in EXPR
    const rest = std.mem.trim(u8, stmt[3..], " \t");
    const in_idx = std.mem.indexOf(u8, rest, " in ") orelse return error.ParseError;
    const vars_src = std.mem.trim(u8, rest[0..in_idx], " \t");
    const seq = std.mem.trim(u8, rest[in_idx + 4 ..], " \t");
    var vnames: [2][]const u8 = .{ "", "" };
    var nv: u8 = 0;
    var vit = std.mem.splitScalar(u8, vars_src, ',');
    while (vit.next()) |v| {
        if (nv >= 2) return error.ParseError;
        vnames[nv] = std.mem.trim(u8, v, " \t");
        nv += 1;
    }
    const body = try parseNodes(arena, tl, &[_][]const u8{ "else", "endfor" });
    const closer = currentStmt(tl) orelse return error.ParseError;
    tl.pos += 1;
    var else_body: ?[]Node = null;
    if (std.mem.eql(u8, firstWord(closer), "else")) {
        else_body = try parseNodes(arena, tl, &[_][]const u8{"endfor"});
        _ = currentStmt(tl) orelse return error.ParseError;
        tl.pos += 1; // consume endfor
    }
    return .{ .for_ = .{ .vars = vnames, .nvars = nv, .seq = seq, .body = body, .else_body = else_body } };
}

fn currentStmt(tl: *TokList) ?[]const u8 {
    if (tl.pos >= tl.items.len) return null;
    return switch (tl.items[tl.pos]) {
        .stmt => |s| s,
        else => null,
    };
}

fn firstWord(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..end];
}

// ===========================================================================
// Execution
// ===========================================================================

const Ctx = struct {
    arena: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(Value) = .empty,
    out: ?*std.json.ObjectMap, // set_result target (sensor path); null otherwise
    depth: u16 = 0,
    steps_left: usize = max_render_steps,

    const max_depth: u16 = 64;

    fn step(self: *Ctx) RenderError!void {
        if (self.steps_left == 0) return error.EvalError;
        self.steps_left -= 1;
    }
};

fn exec(ctx: *Ctx, nodes: []const Node, w: *std.Io.Writer) RenderError!void {
    ctx.depth += 1;
    defer ctx.depth -= 1;
    if (ctx.depth > Ctx.max_depth) return error.EvalError;
    for (nodes) |node| {
        try ctx.step();
        switch (node) {
            .text => |s| w.writeAll(s) catch return error.OutOfMemory,
            .output => |src| {
                const v = try evalExprSrc(ctx, src);
                const s = try toString(ctx.arena, v);
                w.writeAll(s) catch return error.OutOfMemory;
            },
            .set => |st| {
                const v = try evalExprSrc(ctx, st.expr);
                if (!std.mem.eql(u8, st.name, "_")) {
                    try ctx.vars.put(ctx.arena, try ctx.arena.dupe(u8, st.name), v);
                }
            },
            .expr_stmt => |src| _ = try evalExprSrc(ctx, src),
            .if_ => |node_if| {
                var taken = false;
                for (node_if.branches) |br| {
                    if (truthy(try evalExprSrc(ctx, br.cond))) {
                        try exec(ctx, br.body, w);
                        taken = true;
                        break;
                    }
                }
                if (!taken) if (node_if.else_body) |eb| try exec(ctx, eb, w);
            },
            .for_ => |node_for| {
                const seq = try evalExprSrc(ctx, node_for.seq);
                const items: []const Value = switch (seq) {
                    .array => |a| a.items,
                    else => &.{},
                };
                if (items.len == 0) {
                    if (node_for.else_body) |eb| try exec(ctx, eb, w);
                } else {
                    for (items, 0..) |item, idx| {
                        try ctx.step();
                        try bindLoop(ctx, node_for, item, idx, items.len);
                        try exec(ctx, node_for.body, w);
                    }
                }
            },
        }
    }
}

fn bindLoop(ctx: *Ctx, nf: anytype, item: Value, idx: usize, total: usize) RenderError!void {
    if (nf.nvars == 2) {
        // `for k, v in obj` over an array of [k,v] pairs is unusual; support
        // index unpacking only when item is a 2-element array.
        switch (item) {
            .array => |a| if (a.items.len == 2) {
                try ctx.vars.put(ctx.arena, nf.vars[0], a.items[0]);
                try ctx.vars.put(ctx.arena, nf.vars[1], a.items[1]);
            } else return error.EvalError,
            else => return error.EvalError,
        }
    } else {
        try ctx.vars.put(ctx.arena, nf.vars[0], item);
    }
    // loop.index / loop.index0 / loop.first / loop.last / loop.length
    var loop: std.json.ObjectMap = .empty;
    try loop.put(ctx.arena, "index", .{ .integer = @intCast(idx + 1) });
    try loop.put(ctx.arena, "index0", .{ .integer = @intCast(idx) });
    try loop.put(ctx.arena, "first", .{ .bool = idx == 0 });
    try loop.put(ctx.arena, "last", .{ .bool = idx + 1 == total });
    try loop.put(ctx.arena, "length", .{ .integer = @intCast(total) });
    try ctx.vars.put(ctx.arena, "loop", .{ .object = loop });
}

fn evalExprSrc(ctx: *Ctx, src: []const u8) RenderError!Value {
    var p = Parser{ .src = src, .ctx = ctx };
    const v = try p.parseExpr();
    try p.expectEnd();
    return v;
}

// ===========================================================================
// Expression parser/evaluator (precedence climbing)
//
//   expr    := or
//   or      := and ('or' and)*
//   and     := not_ ('and' not_)*
//   not_    := 'not' not_ | cmp
//   cmp     := concat (('=='|'!='|'<'|'<='|'>'|'>='|'in'|'not' 'in') concat | 'is' test)?
//   concat  := add ('~' add)*
//   add     := mul (('+'|'-') mul)*
//   mul     := unary (('*'|'/'|'//'|'%') unary)*
//   unary   := '-' unary_nofilter filters | postfix
//   postfix := primary ('.' ident | '[' expr ']' | '|' filter)*
//   primary := number | string | '[' list ']' | ident | ident '(' args ')' | '(' expr ')'
//
// Jinja binds filters looser than unary minus (`-5|abs` is 5), and `and`/`or`
// return the deciding operand without evaluating the other one.
// ===========================================================================

/// Nesting bound for recursive expression rules (parentheses, lists, `not`,
/// unary minus).
const max_expr_depth = 64;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    ctx: *Ctx,
    rdepth: u16 = 0,
    /// Nonzero while parsing an operand that short-circuiting leaves
    /// unevaluated: syntax is still checked, operations yield `.null`, and
    /// `set_result` records nothing.
    skip: u16 = 0,

    fn skipWs(self: *Parser) void {
        self.pos = std.mem.findNonePos(u8, self.src, self.pos, " \t") orelse self.src.len;
    }
    fn peek(self: *Parser) ?u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn expectEnd(self: *Parser) RenderError!void {
        if (self.peek() != null) return error.ParseError;
    }
    /// Match a keyword/operator token at the cursor (word-bounded for alpha ops).
    fn match(self: *Parser, tok: []const u8) bool {
        self.skipWs();
        if (self.pos + tok.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + tok.len], tok)) return false;
        // Alphabetic operators (and/or/not/in/is) must be word-bounded.
        if (std.ascii.isAlphabetic(tok[0])) {
            const after = self.pos + tok.len;
            if (after < self.src.len and (std.ascii.isAlphanumeric(self.src[after]) or self.src[after] == '_')) return false;
        }
        self.pos += tok.len;
        return true;
    }

    /// Arithmetic unless skipping.
    fn binop(self: *Parser, op: u8, l: Value, r: Value) RenderError!Value {
        return if (self.skip > 0) .null else arith(op, l, r);
    }

    /// Parse an operand that short-circuiting leaves unevaluated.
    fn skipOperand(self: *Parser, comptime rule: fn (*Parser) RenderError!Value) RenderError!void {
        self.skip += 1;
        defer self.skip -= 1;
        _ = try rule(self);
    }

    fn parseExpr(self: *Parser) RenderError!Value {
        self.rdepth += 1;
        defer self.rdepth -= 1;
        if (self.rdepth > max_expr_depth) return error.ParseError;
        return self.parseOr();
    }

    fn parseOr(self: *Parser) RenderError!Value {
        var v = try self.parseAnd();
        while (self.match("or")) {
            if (truthy(v)) try self.skipOperand(parseAnd) else v = try self.parseAnd();
        }
        return v;
    }
    fn parseAnd(self: *Parser) RenderError!Value {
        var v = try self.parseNot();
        while (self.match("and")) {
            if (!truthy(v)) try self.skipOperand(parseNot) else v = try self.parseNot();
        }
        return v;
    }
    fn parseNot(self: *Parser) RenderError!Value {
        if (self.match("not")) {
            self.rdepth += 1;
            defer self.rdepth -= 1;
            if (self.rdepth > max_expr_depth) return error.ParseError;
            const r = try self.parseNot();
            return .{ .bool = !truthy(r) };
        }
        return self.parseCmp();
    }
    fn parseCmp(self: *Parser) RenderError!Value {
        const l = try self.parseConcat();
        // `is [not] test`
        if (self.match("is")) {
            const negate = self.match("not");
            const res = try self.parseTest(l);
            return .{ .bool = if (negate) !res else res };
        }
        if (self.match("not")) {
            if (!self.match("in")) return error.ParseError;
            const r = try self.parseConcat();
            return .{ .bool = self.skip == 0 and !try contains(r, l) };
        }
        const ops = [_][]const u8{ "==", "!=", "<=", ">=", "<", ">", "in" };
        inline for (ops) |op| {
            if (self.match(op)) {
                const r = try self.parseConcat();
                return .{ .bool = self.skip == 0 and try compare(op, l, r) };
            }
        }
        return l;
    }
    fn parseConcat(self: *Parser) RenderError!Value {
        var v = try self.parseAdd();
        while (self.match("~")) {
            const r = try self.parseAdd();
            if (self.skip > 0) continue;
            const a = try toString(self.ctx.arena, v);
            const b = try toString(self.ctx.arena, r);
            v = .{ .string = std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ a, b }) catch return error.OutOfMemory };
        }
        return v;
    }
    fn parseAdd(self: *Parser) RenderError!Value {
        var v = try self.parseMul();
        while (true) {
            if (self.match("+")) {
                v = try self.binop('+', v, try self.parseMul());
            } else if (self.match("-")) {
                v = try self.binop('-', v, try self.parseMul());
            } else break;
        }
        return v;
    }
    fn parseMul(self: *Parser) RenderError!Value {
        var v = try self.parseUnary(true);
        while (true) {
            if (self.match("//")) {
                v = try self.binop('F', v, try self.parseUnary(true)); // floor div
            } else if (self.match("*")) {
                v = try self.binop('*', v, try self.parseUnary(true));
            } else if (self.match("/")) {
                v = try self.binop('/', v, try self.parseUnary(true));
            } else if (self.match("%")) {
                v = try self.binop('%', v, try self.parseUnary(true));
            } else break;
        }
        return v;
    }
    fn parseUnary(self: *Parser, with_filter: bool) RenderError!Value {
        if (!self.match("-")) return self.parsePostfix(with_filter);
        self.rdepth += 1;
        defer self.rdepth -= 1;
        if (self.rdepth > max_expr_depth) return error.ParseError;
        const v = try self.binop('-', .{ .integer = 0 }, try self.parseUnary(false));
        return if (with_filter) self.postfixOps(v, true) else v;
    }

    fn parsePostfix(self: *Parser, with_filter: bool) RenderError!Value {
        return self.postfixOps(try self.parsePrimary(), with_filter);
    }

    fn postfixOps(self: *Parser, start: Value, with_filter: bool) RenderError!Value {
        var v = start;
        while (self.peek()) |c| {
            try self.ctx.step();
            switch (c) {
                '.' => {
                    self.pos += 1;
                    const name = try self.parseIdent();
                    v = if (self.skip > 0) .null else try member(v, name);
                },
                '[' => {
                    self.pos += 1;
                    const idx = try self.parseExpr();
                    if (self.peek() != ']') return error.ParseError;
                    self.pos += 1;
                    v = if (self.skip > 0) .null else try indexValue(v, idx);
                },
                '|' => {
                    if (!with_filter) break;
                    self.pos += 1;
                    v = try self.applyFilter(v);
                },
                else => break,
            }
        }
        return v;
    }

    fn parsePrimary(self: *Parser) RenderError!Value {
        try self.ctx.step();
        const c = self.peek() orelse return error.ParseError;
        if (c == '(') {
            self.pos += 1;
            const v = try self.parseExpr();
            if (self.peek() != ')') return error.ParseError;
            self.pos += 1;
            return v;
        }
        if (c == '[') return self.parseListLiteral();
        if (c == '"' or c == '\'') return self.parseString();
        if (std.ascii.isDigit(c)) return self.parseNumber();
        const name = try self.parseIdent();
        if (self.peek() == '(') return self.parseCall(name);
        if (std.mem.eql(u8, name, "none") or std.mem.eql(u8, name, "None")) return .null;
        if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "True")) return .{ .bool = true };
        if (std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "False")) return .{ .bool = false };
        // Jinja: an undefined name is the special "undefined" value — it renders
        // empty, `is defined` is false, and `|default(x)` rescues it. Only
        // *operations* on it (member/index/arithmetic) error.
        return self.ctx.vars.get(name) orelse .null;
    }

    fn parseListLiteral(self: *Parser) RenderError!Value {
        self.pos += 1; // '['
        var arr: std.json.Array = .init(self.ctx.arena);
        if (self.peek() != ']') {
            while (true) {
                try arr.append(try self.parseExpr());
                const sep = self.peek() orelse return error.ParseError;
                if (sep == ',') {
                    self.pos += 1;
                    continue;
                }
                if (sep == ']') break;
                return error.ParseError;
            }
        }
        self.pos += 1; // ']'
        return .{ .array = arr };
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
        self.pos = std.mem.findScalarPos(u8, self.src, self.pos, quote) orelse self.src.len;
        if (self.pos >= self.src.len) return error.ParseError;
        const s = self.src[start..self.pos];
        self.pos += 1;
        return .{ .string = s };
    }

    /// Unsigned literal; a leading `-` is unary minus.
    fn parseNumber(self: *Parser) RenderError!Value {
        const start = self.pos;
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
        if (is_float) return .{ .float = std.fmt.parseFloat(f64, tok) catch return error.ParseError };
        return .{ .integer = std.fmt.parseInt(i64, tok, 10) catch return error.ParseError };
    }

    fn parseCall(self: *Parser, name: []const u8) RenderError!Value {
        self.pos += 1; // '('
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
        self.pos += 1; // ')'
        if (self.skip > 0) return .null;
        if (std.mem.eql(u8, name, "set_result")) {
            const out = self.ctx.out orelse return error.EvalError;
            if (n != 2) return error.EvalError;
            const key = switch (args[0]) {
                .string => |s| s,
                else => return error.EvalError,
            };
            try out.put(self.ctx.arena, try self.ctx.arena.dupe(u8, key), toNumber(args[1]));
            return .null;
        }
        if (std.mem.eql(u8, name, "range")) return self.makeRange(args[0..n]);
        return error.EvalError;
    }

    fn makeRange(self: *Parser, args: []const Value) RenderError!Value {
        var lo: i64 = 0;
        var hi: i64 = 0;
        if (args.len == 1) {
            hi = toInt(args[0]) orelse return error.EvalError;
        } else if (args.len == 2) {
            lo = toInt(args[0]) orelse return error.EvalError;
            hi = toInt(args[1]) orelse return error.EvalError;
        } else return error.EvalError;
        // Bound the count in i128 so a hostile lo/hi (e.g. i64.min) can't
        // overflow the subtraction.
        if (@as(i128, hi) - @as(i128, lo) > 100_000) return error.EvalError;
        var arr: std.json.Array = .init(self.ctx.arena);
        var k = lo;
        while (k < hi) : (k += 1) try arr.append(.{ .integer = k });
        return .{ .array = arr };
    }

    fn parseTest(self: *Parser, v: Value) RenderError!bool {
        const name = try self.parseIdent();
        if (self.skip > 0) return false;
        if (std.mem.eql(u8, name, "defined")) return v != .null;
        if (std.mem.eql(u8, name, "undefined")) return v == .null;
        if (std.mem.eql(u8, name, "none")) return v == .null;
        if (std.mem.eql(u8, name, "string")) return v == .string;
        if (std.mem.eql(u8, name, "number")) return v == .integer or v == .float;
        if (std.mem.eql(u8, name, "boolean")) return v == .bool;
        if (std.mem.eql(u8, name, "mapping")) return v == .object;
        if (std.mem.eql(u8, name, "iterable")) return v == .array or v == .string;
        if (std.mem.eql(u8, name, "even")) return @rem(toInt(v) orelse return error.EvalError, 2) == 0;
        if (std.mem.eql(u8, name, "odd")) return @rem(toInt(v) orelse return error.EvalError, 2) != 0;
        return error.EvalError;
    }

    fn applyFilter(self: *Parser, v: Value) RenderError!Value {
        const name = try self.parseIdent();
        var arg: ?Value = null;
        var arg2: ?Value = null;
        if (self.peek() == '(') {
            self.pos += 1;
            if (self.peek() != ')') {
                arg = try self.parseExpr();
                if (self.peek() == ',') {
                    self.pos += 1;
                    arg2 = try self.parseExpr();
                }
            }
            if (self.peek() != ')') return error.ParseError;
            self.pos += 1;
        }
        if (self.skip > 0) return .null;
        return applyNamedFilter(self.ctx.arena, name, v, arg, arg2);
    }
};

fn applyNamedFilter(arena: std.mem.Allocator, name: []const u8, v: Value, arg: ?Value, arg2: ?Value) RenderError!Value {
    if (std.mem.eql(u8, name, "fromjson")) {
        const s = switch (v) {
            .string => |str| str,
            else => return error.EvalError,
        };
        return std.json.parseFromSliceLeaky(Value, arena, s, .{}) catch return error.EvalError;
    } else if (std.mem.eql(u8, name, "float")) {
        // A failed conversion yields the default (the argument as given, else
        // 0). Undefined (`.null` here) without a default is an error, as
        // Jinja's Undefined raises on float().
        if (toFloat(v)) |f| return .{ .float = f };
        return arg orelse if (v == .null) error.EvalError else .{ .float = 0 };
    } else if (std.mem.eql(u8, name, "int")) {
        if (toInt(v)) |i| return .{ .integer = i };
        return arg orelse if (v == .null) error.EvalError else .{ .integer = 0 };
    } else if (std.mem.eql(u8, name, "abs")) {
        return absValue(v);
    } else if (std.mem.eql(u8, name, "round")) {
        const f = toFloat(v) orelse return error.EvalError;
        const nd: f64 = if (arg) |a| @floatFromInt(toInt(a) orelse 0) else 0;
        const scale = std.math.pow(f64, 10, nd);
        return .{ .float = @round(f * scale) / scale };
    } else if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "d")) {
        return switch (v) {
            .null => arg orelse v,
            else => v,
        };
    } else if (std.mem.eql(u8, name, "string")) {
        return .{ .string = try toString(arena, v) };
    } else if (std.mem.eql(u8, name, "upper")) {
        return .{ .string = try std.ascii.allocUpperString(arena, try toString(arena, v)) };
    } else if (std.mem.eql(u8, name, "lower")) {
        return .{ .string = try std.ascii.allocLowerString(arena, try toString(arena, v)) };
    } else if (std.mem.eql(u8, name, "trim")) {
        return .{ .string = std.mem.trim(u8, try toString(arena, v), " \t\r\n") };
    } else if (std.mem.eql(u8, name, "capitalize")) {
        return .{ .string = try capitalize(arena, try toString(arena, v)) };
    } else if (std.mem.eql(u8, name, "title")) {
        return .{ .string = try titleCase(arena, try toString(arena, v)) };
    } else if (std.mem.eql(u8, name, "replace")) {
        const s = try toString(arena, v);
        const from = try toString(arena, arg orelse return error.EvalError);
        const to = try toString(arena, arg2 orelse return error.EvalError);
        if (from.len == 0) return .{ .string = s };
        const out = std.mem.replaceOwned(u8, arena, s, from, to) catch return error.OutOfMemory;
        return .{ .string = out };
    } else if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "count")) {
        return .{ .integer = switch (v) {
            .array => |a| @intCast(a.items.len),
            .object => |o| @intCast(o.count()),
            .string => |s| @intCast(s.len),
            else => return error.EvalError,
        } };
    } else if (std.mem.eql(u8, name, "first")) {
        return switch (v) {
            .array => |a| if (a.items.len > 0) a.items[0] else .null,
            .string => |s| if (s.len > 0) .{ .string = s[0..1] } else .null,
            else => error.EvalError,
        };
    } else if (std.mem.eql(u8, name, "last")) {
        return switch (v) {
            .array => |a| if (a.items.len > 0) a.items[a.items.len - 1] else .null,
            .string => |s| if (s.len > 0) .{ .string = s[s.len - 1 ..] } else .null,
            else => error.EvalError,
        };
    } else if (std.mem.eql(u8, name, "join")) {
        const sep = if (arg) |a| try toString(arena, a) else "";
        return .{ .string = try joinArray(arena, v, sep) };
    } else if (std.mem.eql(u8, name, "list")) {
        return v; // already iterable in our model
    }
    return error.EvalError;
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

fn arith(op: u8, l: Value, r: Value) RenderError!Value {
    // Integer arithmetic when both are integers (except true division).
    if (l == .integer and r == .integer and op != '/') {
        const a = l.integer;
        const b = r.integer;
        return switch (op) {
            '+' => .{ .integer = a +% b },
            '-' => .{ .integer = a -% b },
            '*' => .{ .integer = a *% b },
            // b==0 → error; a==minInt and b==-1 would overflow @divFloor/@mod.
            'F' => if (b == 0 or (a == std.math.minInt(i64) and b == -1)) error.EvalError else .{ .integer = @divFloor(a, b) },
            '%' => if (b == 0 or (a == std.math.minInt(i64) and b == -1)) error.EvalError else .{ .integer = @mod(a, b) },
            else => error.EvalError,
        };
    }
    const a = toFloat(l) orelse return error.EvalError;
    const b = toFloat(r) orelse return error.EvalError;
    return switch (op) {
        '+' => .{ .float = a + b },
        '-' => .{ .float = a - b },
        '*' => .{ .float = a * b },
        '/' => if (b == 0) error.EvalError else .{ .float = a / b },
        'F' => if (b == 0) error.EvalError else .{ .float = @floor(a / b) },
        '%' => if (b == 0) error.EvalError else .{ .float = @mod(a, b) },
        else => error.EvalError,
    };
}

fn compare(op: []const u8, l: Value, r: Value) RenderError!bool {
    if (std.mem.eql(u8, op, "in")) return try contains(r, l);
    // Numeric comparison when both coerce to numbers.
    if (toFloat(l)) |a| {
        if (toFloat(r)) |b| {
            if (std.mem.eql(u8, op, "==")) return a == b;
            if (std.mem.eql(u8, op, "!=")) return a != b;
            if (std.mem.eql(u8, op, "<")) return a < b;
            if (std.mem.eql(u8, op, "<=")) return a <= b;
            if (std.mem.eql(u8, op, ">")) return a > b;
            if (std.mem.eql(u8, op, ">=")) return a >= b;
        }
    }
    // String/structural equality.
    const eq = valueEql(l, r);
    if (std.mem.eql(u8, op, "==")) return eq;
    if (std.mem.eql(u8, op, "!=")) return !eq;
    return error.EvalError;
}

fn contains(haystack: Value, needle: Value) RenderError!bool {
    return switch (haystack) {
        .array => |a| {
            for (a.items) |it| if (valueEql(it, needle)) return true;
            return false;
        },
        .object => |o| switch (needle) {
            .string => |s| o.contains(s),
            else => false,
        },
        .string => |s| switch (needle) {
            .string => |n| std.mem.indexOf(u8, s, n) != null,
            else => false,
        },
        else => error.EvalError,
    };
}

fn valueEql(l: Value, r: Value) bool {
    return switch (l) {
        .string => |a| r == .string and std.mem.eql(u8, a, r.string),
        .bool => |a| r == .bool and a == r.bool,
        .null => r == .null,
        .integer => |a| r == .integer and a == r.integer,
        .float => |a| r == .float and a == r.float,
        else => false,
    };
}

fn truthy(v: Value) bool {
    return switch (v) {
        .bool => |b| b,
        .null => false,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
        .number_string => |s| s.len > 0,
    };
}

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

fn member(v: Value, name: []const u8) RenderError!Value {
    return switch (v) {
        .object => |o| o.get(name) orelse .null,
        else => error.EvalError,
    };
}

fn indexValue(v: Value, idx: Value) RenderError!Value {
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
            const ix = if (i < 0) i + @as(i64, @intCast(a.items.len)) else i;
            if (ix < 0 or ix >= a.items.len) return error.EvalError;
            return a.items[@intCast(ix)];
        },
        else => return error.EvalError,
    }
}

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
        .float => |f| jv.floatToInt(f),
        .number_string, .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch blk: {
            const f = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch break :blk null;
            break :blk jv.floatToInt(f);
        },
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}

fn absValue(v: Value) Value {
    return switch (v) {
        // -i64.min overflows; promote that one case to float.
        .integer => |i| if (i == std.math.minInt(i64)) .{ .float = -@as(f64, @floatFromInt(i)) } else .{ .integer = if (i < 0) -i else i },
        .float => |f| .{ .float = @abs(f) },
        else => v,
    };
}

fn toString(arena: std.mem.Allocator, v: Value) RenderError![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |i| std.fmt.allocPrint(arena, "{d}", .{i}) catch error.OutOfMemory,
        .float => |f| blk: {
            const s = std.fmt.allocPrint(arena, "{d}", .{f}) catch return error.OutOfMemory;
            // Python's str() marks an integral float with ".0" (21.0, not 21).
            if (std.mem.indexOfAny(u8, s, ".ein") != null) break :blk s;
            break :blk std.fmt.allocPrint(arena, "{s}.0", .{s}) catch error.OutOfMemory;
        },
        .bool => |b| if (b) "True" else "False",
        .null => "",
        else => error.EvalError,
    };
}

fn capitalize(arena: std.mem.Allocator, s: []const u8) RenderError![]u8 {
    const out = try std.ascii.allocLowerString(arena, s);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn titleCase(arena: std.mem.Allocator, s: []const u8) RenderError![]u8 {
    const out = arena.alloc(u8, s.len) catch return error.OutOfMemory;
    var at_start = true;
    for (s, 0..) |c, i| {
        out[i] = if (at_start) std.ascii.toUpper(c) else std.ascii.toLower(c);
        at_start = !std.ascii.isAlphanumeric(c);
    }
    return out;
}

fn joinArray(arena: std.mem.Allocator, v: Value, sep: []const u8) RenderError![]const u8 {
    const a = switch (v) {
        .array => |arr| arr.items,
        else => return error.EvalError,
    };
    var buf: std.ArrayList(u8) = .empty;
    for (a, 0..) |it, i| {
        if (i > 0) buf.appendSlice(arena, sep) catch return error.OutOfMemory;
        buf.appendSlice(arena, try toString(arena, it)) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(arena) catch error.OutOfMemory;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Template render bounds repeated string expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var template = try Template.init(testing.allocator, "{% set s = payload %}{% for i in range(20) %}{% set s = s ~ s %}{% endfor %}");
    defer template.deinit();
    var out: std.json.ObjectMap = .empty;
    try testing.expectError(error.OutOfMemory, template.render(arena.allocator(), "x", &out));
    try testing.expectEqual(@as(usize, 0), out.count());
}

test "Template execution shares its step budget across nested loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try parse(a, "{% for i in range(10) %}{% for j in range(10) %}{% endfor %}{% endfor %}");
    var ctx = Ctx{ .arena = a, .out = null, .steps_left = 32 };
    var sink = std.Io.Writer.Discarding.init(&.{});
    try testing.expectError(error.EvalError, exec(&ctx, nodes, &sink.writer));
    try testing.expectEqual(@as(usize, 0), ctx.steps_left);
}

test "Template render copies results out of temporary storage and releases failures" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var template = try Template.init(alloc, "{ set_result(payload, 12) }{ set_result(\"other\", 34) }");
            defer template.deinit();
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            var out: std.json.ObjectMap = .empty;
            var key = [_]u8{ 's', 'e', 'n', 's', 'o', 'r' };
            try template.render(arena.allocator(), &key, &out);
            @memset(&key, 'x');
            try testing.expectEqual(@as(i64, 12), out.get("sensor").?.integer);
            try testing.expectEqual(@as(i64, 34), out.get("other").?.integer);
        }
    }.run, .{});
}

test "fuzz Template render bounds expanding strings and owns successful results" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            const count = smith.valueRangeAtMostWithHash(u5, 0, 24, 0);
            var source: [160]u8 = undefined;
            const src = try std.fmt.bufPrint(&source, "{{% set s = payload %}}{{% for i in range({d}) %}}{{% set s = s ~ s %}}{{% endfor %}}{{ set_result(\"length\", s|length) }}", .{count});
            var template = try Template.init(testing.allocator, src);
            defer template.deinit();
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var out: std.json.ObjectMap = .empty;
            template.render(arena.allocator(), "x", &out) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                return testing.expectEqual(@as(usize, 0), out.count());
            };
            try testing.expectEqual(@as(i64, 1) << count, out.get("length").?.integer);
        }
    }.run, .{});
}

fn renderToMap(arena: std.mem.Allocator, tmpl: []const u8, payload: []const u8) !std.json.ObjectMap {
    const t = try Template.init(arena, tmpl);
    var out: std.json.ObjectMap = .empty;
    try t.render(arena, payload, &out);
    return out;
}

/// Render `tmpl` with caller variables and return the text (tests only: the
/// sensor path discards text).
fn renderTextForTest(arena: std.mem.Allocator, tmpl: []const u8, vars: []const struct { []const u8, Value }) RenderError![]const u8 {
    const nodes = try parse(arena, tmpl);
    var ctx = Ctx{ .arena = arena, .out = null };
    for (vars) |kv| try ctx.vars.put(arena, kv[0], kv[1]);
    var aw = std.Io.Writer.Allocating.init(arena);
    try exec(&ctx, nodes, &aw.writer);
    return aw.written();
}

test "sensor: fromjson + member + float, single-brace and statements" {
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

test "sensor: single-brace { set_result(...) } expression form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderToMap(a, "{% set d = payload|fromjson %}{ set_result(\"p\", d.sensor.power|int) }", "{\"sensor\":{\"power\":\"1234\"}}");
    try testing.expectEqual(@as(i64, 1234), out.get("p").?.integer);
}

test "Template: parsed once, rendered many times, owns its source" {
    var src_buf = "{% set d = payload|fromjson %}{ set_result(\"t\", d.t) }".*;
    var t = try Template.init(testing.allocator, &src_buf);
    defer t.deinit();
    @memset(&src_buf, ' '); // the template keeps its own copy
    for ([_][]const u8{ "{\"t\":1}", "{\"t\":2.5}" }, [_]f64{ 1, 2.5 }) |payload, want| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var out: std.json.ObjectMap = .empty;
        try t.render(arena.allocator(), payload, &out);
        try testing.expectEqual(want, toFloat(out.get("t").?).?);
    }
    try testing.expectError(error.ParseError, Template.init(testing.allocator, "{% if x %}no end"));
}

test "renderText: variable interpolation + arithmetic + concat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try renderTextForTest(a, "T={ a + b }C, name={ who|upper }", &.{
        .{ "a", .{ .integer = 20 } },
        .{ "b", .{ .integer = 5 } },
        .{ "who", .{ .string = "bed" } },
    });
    try testing.expectEqualStrings("T=25C, name=BED", s);
}

test "renderText: if/elif/else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl = "{% if t > 100 %}hot{% elif t > 50 %}warm{% else %}cold{% endif %}";
    try testing.expectEqualStrings("hot", try renderTextForTest(a, tmpl, &.{.{ "t", .{ .integer = 120 } }}));
    try testing.expectEqualStrings("warm", try renderTextForTest(a, tmpl, &.{.{ "t", .{ .integer = 60 } }}));
    try testing.expectEqualStrings("cold", try renderTextForTest(a, tmpl, &.{.{ "t", .{ .integer = 10 } }}));
}

test "renderText: for loop with loop.index, else branch, range()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try renderTextForTest(a, "{% for x in range(1, 4) %}{ loop.index }:{ x } {% endfor %}", &.{});
    try testing.expectEqualStrings("1:1 2:2 3:3 ", s);
    const empty = try renderTextForTest(a, "{% for x in items %}x{% else %}none{% endfor %}", &.{.{ "items", .{ .array = .init(a) } }});
    try testing.expectEqualStrings("none", empty);
}

test "renderText: comparison, logical, membership, is-tests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("yes", try renderTextForTest(a, "{% if a == 1 and b != 2 %}yes{% endif %}", &.{ .{ "a", .{ .integer = 1 } }, .{ "b", .{ .integer = 3 } } }));
    try testing.expectEqualStrings("in", try renderTextForTest(a, "{% if \"x\" in s %}in{% endif %}", &.{.{ "s", .{ .string = "axb" } }}));
    try testing.expectEqualStrings("def", try renderTextForTest(a, "{% if v is defined %}def{% endif %}", &.{.{ "v", .{ .integer = 0 } }}));
    try testing.expectEqualStrings("even", try renderTextForTest(a, "{% if n is even %}even{% endif %}", &.{.{ "n", .{ .integer = 4 } }}));
    try testing.expectEqualStrings("none", try renderTextForTest(a, "{% if m is not defined %}none{% endif %}", &.{}));
}

test "and/or return the deciding operand and short-circuit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("fallback", try renderTextForTest(a, "{ missing or \"fallback\" }", &.{}));
    try testing.expectEqualStrings("3", try renderTextForTest(a, "{ 3 or x.y }", &.{}));
    try testing.expectEqualStrings("0", try renderTextForTest(a, "{ 0 and x.y }", &.{}));
    try testing.expectEqualStrings("b", try renderTextForTest(a, "{ \"a\" and \"b\" }", &.{}));
    // The usual MQTT guard: the right side is not evaluated when x is undefined.
    try testing.expectEqualStrings("no", try renderTextForTest(a, "{% if x is defined and x.a > 1 %}yes{% else %}no{% endif %}", &.{}));
    // A skipped set_result records nothing.
    const out = try renderToMap(a, "{ true or set_result(\"skipped\", 1) }{ false and set_result(\"also\", 2) }", "");
    try testing.expectEqual(@as(usize, 0), out.count());
    // Syntax errors in a skipped operand still fail.
    try testing.expectError(error.ParseError, renderTextForTest(a, "{ true or (1 }", &.{}));
}

test "unary minus with spaces, filters after negation, and not in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("-5", try renderTextForTest(a, "{ - 5 }", &.{}));
    try testing.expectEqualStrings("5", try renderTextForTest(a, "{ -5|abs }", &.{}));
    try testing.expectEqualStrings("-2.5", try renderTextForTest(a, "{ -x }", &.{.{ "x", .{ .float = 2.5 } }}));
    try testing.expectEqualStrings("7", try renderTextForTest(a, "{ 2 - -5 }", &.{}));
    try testing.expectEqualStrings("True", try renderTextForTest(a, "{ 1 not in [2] }", &.{}));
    try testing.expectEqualStrings("False", try renderTextForTest(a, "{ 2 not in [2] }", &.{}));
    try testing.expectError(error.ParseError, renderTextForTest(a, "{ 1 not [2] }", &.{}));
}

test "float/int filters default on failed conversion; floats print like Python" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("0.0", try renderTextForTest(a, "{ \"abc\"|float }", &.{}));
    try testing.expectEqualStrings("0", try renderTextForTest(a, "{ \"abc\"|int }", &.{}));
    try testing.expectEqualStrings("x", try renderTextForTest(a, "{ \"abc\"|int(\"x\") }", &.{}));
    try testing.expectEqualStrings("1.5", try renderTextForTest(a, "{ missing|float(1.5) }", &.{}));
    try testing.expectError(error.EvalError, renderTextForTest(a, "{ missing|int }", &.{}));
    try testing.expectEqualStrings("21.0", try renderTextForTest(a, "{ 21.0 }", &.{}));
    try testing.expectEqualStrings("21.5", try renderTextForTest(a, "{ 21.5 }", &.{}));
    try testing.expectEqualStrings("-3.0", try renderTextForTest(a, "{ -3.0 }", &.{}));
}

test "filters: replace, length, join, round, default, capitalize, comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lst: std.json.Array = .init(a);
    try lst.append(.{ .string = "a" });
    try lst.append(.{ .string = "b" });
    try testing.expectEqualStrings("a-b", try renderTextForTest(a, "{ xs|join(\"-\") }", &.{.{ "xs", .{ .array = lst } }}));
    try testing.expectEqualStrings("2", try renderTextForTest(a, "{ xs|length }", &.{.{ "xs", .{ .array = lst } }}));
    try testing.expectEqualStrings("heLLo", try renderTextForTest(a, "{ s|replace(\"l\",\"L\") }", &.{.{ "s", .{ .string = "hello" } }}));
    try testing.expectEqualStrings("3.14", try renderTextForTest(a, "{ x|round(2) }", &.{.{ "x", .{ .float = 3.14159 } }}));
    try testing.expectEqualStrings("fallback", try renderTextForTest(a, "{ missing|default(\"fallback\") }", &.{}));
    try testing.expectEqualStrings("Hello", try renderTextForTest(a, "{ s|capitalize }", &.{.{ "s", .{ .string = "hello" } }}));
    try testing.expectEqualStrings("ab", try renderTextForTest(a, "a{# this is a comment #}b", &.{}));
}

test "malformed templates error, never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.ParseError, Template.init(a, "{% if x %}no end"));
    try testing.expectError(error.ParseError, Template.init(a, "{ unclosed"));
    try testing.expectError(error.ParseError, renderToMap(a, "{% for %}{% endfor %}", "{}"));
    // Operating on undefined errors (member access on the undefined value)...
    try testing.expectError(error.EvalError, renderToMap(a, "{ undefined_var.attr }", "{}"));
    // ...but a bare undefined name renders empty (Jinja undefined), not an error.
    try testing.expectEqualStrings("", try renderTextForTest(a, "{ undefined_var }", &.{}));
}

test "i64.min edge cases don't overflow (abs, range, // -1, % -1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const min = std.math.minInt(i64);
    // abs(i64.min) promotes to float instead of overflowing.
    const s = try renderTextForTest(a, "{ x|abs }", &.{.{ "x", .{ .integer = min } }});
    try testing.expect(s.len > 0);
    // range with i64.min lower bound is rejected by the bound check, not a crash.
    try testing.expectError(error.EvalError, renderToMap(a, "{ set_result(\"r\", range(-9223372036854775807 - 1, 1)|length) }", "{}"));
    // minInt // -1 and minInt % -1 error rather than overflow.
    try testing.expectError(error.EvalError, renderTextForTest(a, "{ x // -1 }", &.{.{ "x", .{ .integer = min } }}));
    try testing.expectError(error.EvalError, renderTextForTest(a, "{ x % -1 }", &.{.{ "x", .{ .integer = min } }}));
    // Negating i64.min wraps like the other integer operators.
    try testing.expectEqualStrings("-9223372036854775808", try renderTextForTest(a, "{ -x }", &.{.{ "x", .{ .integer = min } }}));
}

test "deeply nested expressions and blocks error instead of overflowing the stack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Nest = struct {
        fn build(alloc: std.mem.Allocator, open: []const u8, inner: []const u8, close: []const u8, n: usize) ![]const u8 {
            var buf: std.ArrayList(u8) = .empty;
            for (0..n) |_| try buf.appendSlice(alloc, open);
            try buf.appendSlice(alloc, inner);
            for (0..n) |_| try buf.appendSlice(alloc, close);
            return buf.items;
        }
    };
    const depth = 100_000;
    try testing.expectError(error.ParseError, renderToMap(a, try std.mem.concat(a, u8, &.{ "{ ", try Nest.build(a, "(", "1", ")", depth), " }" }), "{}"));
    try testing.expectError(error.ParseError, renderTextForTest(a, try std.mem.concat(a, u8, &.{ "{ ", try Nest.build(a, "not ", "1", "", depth), " }" }), &.{}));
    try testing.expectError(error.ParseError, renderTextForTest(a, try std.mem.concat(a, u8, &.{ "{ ", try Nest.build(a, "- ", "1", "", depth), " }" }), &.{}));
    try testing.expectError(error.ParseError, Template.init(a, try Nest.build(a, "{% if 1 %}", "x", "{% endif %}", depth)));
    try testing.expectError(error.ParseError, Template.init(a, try Nest.build(a, "{% for x in [1] %}", "x", "{% endfor %}", depth)));
    // Nesting within the bound still works.
    try testing.expectEqualStrings("x", try renderTextForTest(a, try Nest.build(a, "{% if 1 %}", "x", "{% endif %}", Ctx.max_depth - 1), &.{}));
}

test "fuzz render: arbitrary templates + payloads never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tbuf: [192]u8 = undefined;
            var pbuf: [128]u8 = undefined;
            const tn = smith.valueRangeAtMostWithHash(u32, 0, 192, 0);
            const pn = smith.valueRangeAtMostWithHash(u32, 0, 128, 1);
            smith.bytesWithHash(tbuf[0..tn], 2);
            smith.bytesWithHash(pbuf[0..pn], 3);
            var t = Template.init(testing.allocator, tbuf[0..tn]) catch return;
            defer t.deinit();
            var out: std.json.ObjectMap = .empty;
            t.render(a, pbuf[0..pn], &out) catch {};
            _ = renderTextForTest(a, tbuf[0..tn], &.{}) catch {};
        }
    }.run, .{});
}

test "fuzz expressions: operator soup never crashes" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const atoms = [_][]const u8{ "1", "-", " - ", "not ", " and ", " or ", " in ", " not in ", "x", ".y", "(", ")", "[", "]", ",", "|int", "|float", "\"s\"", "2.5", " is defined", "~", "//", "%" };
            var src: std.ArrayList(u8) = .empty;
            try src.appendSlice(a, "{ ");
            const n = smith.valueRangeAtMostWithHash(u8, 0, 24, 0);
            for (0..n) |i| try src.appendSlice(a, atoms[smith.valueRangeAtMostWithHash(u8, 0, atoms.len - 1, @intCast(i + 1))]);
            try src.appendSlice(a, " }");
            _ = renderTextForTest(a, src.items, &.{.{ "x", .{ .integer = 3 } }}) catch {};
        }
    }.run, .{});
}

//! A small Jinja2-subset template engine matching Moonraker's config Jinja
//! environment (`template.py`: `jinja2.Environment('{%', '%}', '{', '}')`):
//!
//!   * `{% ... %}`  statements   (set, if/elif/else/endif, for/else/endfor)
//!   * `{ ... }`    expressions   (rendered into the output text)
//!   * `{# ... #}`  comments
//!
//! Two entry points share one engine:
//!   * `render(arena, tmpl, payload, out)` — the MQTT-sensor path. Provides
//!     `payload` + a `set_result(name, value)` callable that records numeric
//!     measurements into `out`; the rendered text is discarded.
//!   * `renderText(arena, tmpl, vars, payload)` — general path (e.g. future
//!     notifier title/body templates): returns the rendered text, with caller
//!     supplied context variables.
//!
//! This is NOT full Jinja (no inheritance/macros/imports/sandbox); it implements
//! the language subset Moonraker realistically uses. Everything is arena-scoped
//! per render, so it costs nothing between renders and fits phobos's budget.

const std = @import("std");
const Value = std.json.Value;

pub const RenderError = error{ ParseError, EvalError, OutOfMemory };

// ===========================================================================
// Public API
// ===========================================================================

/// MQTT-sensor render: execute `tmpl` with `payload` + `set_result`, recording
/// measurements into `out` (name → .integer/.float). Output text is discarded.
pub fn render(arena: std.mem.Allocator, tmpl: []const u8, payload: []const u8, out: *std.json.ObjectMap) RenderError!void {
    const nodes = try parse(arena, tmpl);
    var ctx = Ctx{ .arena = arena, .out = out };
    try ctx.vars.put(arena, "payload", .{ .string = payload });
    var sink = std.Io.Writer.Discarding.init(&.{});
    try exec(&ctx, nodes, &sink.writer);
}

/// General render: execute `tmpl` with caller `vars` (+ optional `payload`) and
/// return the rendered text (arena-owned). `set_result` is unavailable here.
pub fn renderText(
    arena: std.mem.Allocator,
    tmpl: []const u8,
    vars: []const struct { []const u8, Value },
    payload: ?[]const u8,
) RenderError![]const u8 {
    const nodes = try parse(arena, tmpl);
    var ctx = Ctx{ .arena = arena, .out = null };
    if (payload) |p| try ctx.vars.put(arena, "payload", .{ .string = p });
    for (vars) |kv| try ctx.vars.put(arena, kv[0], kv[1]);
    var aw = std.Io.Writer.Allocating.init(arena);
    try exec(&ctx, nodes, &aw.writer);
    return aw.written();
}

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

const TokList = struct { items: []Token, pos: usize = 0 };

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
                } else if (std.mem.eql(u8, kw, "if")) {
                    try nodes.append(arena, try parseIf(arena, tl, s));
                } else if (std.mem.eql(u8, kw, "for")) {
                    try nodes.append(arena, try parseFor(arena, tl, s));
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

    const max_depth: u16 = 64;
};

fn exec(ctx: *Ctx, nodes: []const Node, w: *std.Io.Writer) RenderError!void {
    ctx.depth += 1;
    defer ctx.depth -= 1;
    if (ctx.depth > Ctx.max_depth) return error.EvalError;
    for (nodes) |node| {
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
//   cmp     := concat (('=='|'!='|'<'|'<='|'>'|'>='|'in') concat | 'is' test)?
//   concat  := add ('~' add)*
//   add     := mul (('+'|'-') mul)*
//   mul     := unary (('*'|'/'|'//'|'%') unary)*
//   unary   := '-' unary | postfix
//   postfix := primary ('.' ident | '[' expr ']' | '(' args ')' | '|' filter)*
//   primary := number | string | '[' list ']' | ident | '(' expr ')'
// ===========================================================================

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    ctx: *Ctx,
    rdepth: u16 = 0,

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

    fn parseExpr(self: *Parser) RenderError!Value {
        self.rdepth += 1;
        defer self.rdepth -= 1;
        if (self.rdepth > 64) return error.ParseError;
        return self.parseOr();
    }

    fn parseOr(self: *Parser) RenderError!Value {
        var v = try self.parseAnd();
        while (self.match("or")) {
            const r = try self.parseAnd();
            v = .{ .bool = truthy(v) or truthy(r) };
        }
        return v;
    }
    fn parseAnd(self: *Parser) RenderError!Value {
        var v = try self.parseNot();
        while (self.match("and")) {
            const r = try self.parseNot();
            v = .{ .bool = truthy(v) and truthy(r) };
        }
        return v;
    }
    fn parseNot(self: *Parser) RenderError!Value {
        if (self.match("not")) {
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
        const ops = [_][]const u8{ "==", "!=", "<=", ">=", "<", ">", "in" };
        inline for (ops) |op| {
            if (self.match(op)) {
                const r = try self.parseConcat();
                return .{ .bool = try compare(op, l, r) };
            }
        }
        return l;
    }
    fn parseConcat(self: *Parser) RenderError!Value {
        var v = try self.parseAdd();
        while (self.match("~")) {
            const r = try self.parseAdd();
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
                v = try arith('+', v, try self.parseMul());
            } else if (self.matchMinus()) {
                v = try arith('-', v, try self.parseMul());
            } else break;
        }
        return v;
    }
    /// Match a binary '-' (not a unary minus starting a new term — handled by
    /// only being called in the binary position).
    fn matchMinus(self: *Parser) bool {
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '-') {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn parseMul(self: *Parser) RenderError!Value {
        var v = try self.parseUnary();
        while (true) {
            if (self.match("//")) {
                v = try arith('F', v, try self.parseUnary()); // floor div
            } else if (self.match("*")) {
                v = try arith('*', v, try self.parseUnary());
            } else if (self.match("/")) {
                v = try arith('/', v, try self.parseUnary());
            } else if (self.match("%")) {
                v = try arith('%', v, try self.parseUnary());
            } else break;
        }
        return v;
    }
    fn parseUnary(self: *Parser) RenderError!Value {
        if (self.peek() == '-') {
            // Distinguish unary minus from a number literal "-5".
            const save = self.pos;
            self.pos += 1;
            self.skipWs();
            if (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) {
                self.pos = save;
                return self.parsePostfix();
            }
            const r = try self.parseUnary();
            return arith('-', .{ .integer = 0 }, r);
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) RenderError!Value {
        var v = try self.parsePrimary();
        while (self.peek()) |c| {
            switch (c) {
                '.' => {
                    self.pos += 1;
                    const name = try self.parseIdent();
                    v = try member(v, name);
                },
                '[' => {
                    self.pos += 1;
                    const idx = try self.parseExpr();
                    if (self.peek() != ']') return error.ParseError;
                    self.pos += 1;
                    v = try indexValue(v, idx);
                },
                '|' => {
                    self.pos += 1;
                    v = try self.applyFilter(v);
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
        if (c == '[') return self.parseListLiteral();
        if (c == '"' or c == '\'') return self.parseString();
        // `-` only reaches here as the start of a negative number literal
        // (parseUnary handles unary minus on non-literals); parseNumber consumes it.
        if (c == '-' or std.ascii.isDigit(c)) return self.parseNumber();
        const name = try self.parseIdent();
        if (self.peek() == '(') return self.parseCall(name);
        if (std.mem.eql(u8, name, "payload")) {
            return self.ctx.vars.get("payload") orelse error.EvalError;
        }
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
        while (self.pos < self.src.len and self.src[self.pos] != quote) self.pos += 1;
        if (self.pos >= self.src.len) return error.ParseError;
        const s = self.src[start..self.pos];
        self.pos += 1;
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
        return .{ .float = toFloat(v) orelse if (arg) |a| toFloat(a) orelse 0 else return error.EvalError };
    } else if (std.mem.eql(u8, name, "int")) {
        return .{ .integer = toInt(v) orelse if (arg) |a| toInt(a) orelse 0 else return error.EvalError };
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
        return .{ .string = try mapCase(arena, try toString(arena, v), true) };
    } else if (std.mem.eql(u8, name, "lower")) {
        return .{ .string = try mapCase(arena, try toString(arena, v), false) };
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
        .float => |f| std.fmt.allocPrint(arena, "{d}", .{f}) catch error.OutOfMemory,
        .bool => |b| if (b) "True" else "False",
        .null => "",
        else => error.EvalError,
    };
}

fn mapCase(arena: std.mem.Allocator, s: []const u8, upper: bool) RenderError![]u8 {
    const out = arena.alloc(u8, s.len) catch return error.OutOfMemory;
    for (s, 0..) |c, i| out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
    return out;
}

fn capitalize(arena: std.mem.Allocator, s: []const u8) RenderError![]u8 {
    const out = try mapCase(arena, s, false);
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

fn renderToMap(arena: std.mem.Allocator, tmpl: []const u8, payload: []const u8) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    try render(arena, tmpl, payload, &out);
    return out;
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

test "renderText: variable interpolation + arithmetic + concat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try renderText(a, "T={ a + b }C, name={ who|upper }", &.{
        .{ "a", .{ .integer = 20 } },
        .{ "b", .{ .integer = 5 } },
        .{ "who", .{ .string = "bed" } },
    }, null);
    try testing.expectEqualStrings("T=25C, name=BED", s);
}

test "renderText: if/elif/else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl = "{% if t > 100 %}hot{% elif t > 50 %}warm{% else %}cold{% endif %}";
    const hot = try renderText(a, tmpl, &.{.{ "t", .{ .integer = 120 } }}, null);
    try testing.expectEqualStrings("hot", hot);
    const warm = try renderText(a, tmpl, &.{.{ "t", .{ .integer = 60 } }}, null);
    try testing.expectEqualStrings("warm", warm);
    const cold = try renderText(a, tmpl, &.{.{ "t", .{ .integer = 10 } }}, null);
    try testing.expectEqualStrings("cold", cold);
}

test "renderText: for loop with loop.index, else branch, range()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try renderText(a, "{% for x in range(1, 4) %}{ loop.index }:{ x } {% endfor %}", &.{}, null);
    try testing.expectEqualStrings("1:1 2:2 3:3 ", s);
    const empty = try renderText(a, "{% for x in items %}x{% else %}none{% endfor %}", &.{.{ "items", .{ .array = .init(a) } }}, null);
    try testing.expectEqualStrings("none", empty);
}

test "renderText: comparison, logical, membership, is-tests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("yes", try renderText(a, "{% if a == 1 and b != 2 %}yes{% endif %}", &.{ .{ "a", .{ .integer = 1 } }, .{ "b", .{ .integer = 3 } } }, null));
    try testing.expectEqualStrings("in", try renderText(a, "{% if \"x\" in s %}in{% endif %}", &.{.{ "s", .{ .string = "axb" } }}, null));
    try testing.expectEqualStrings("def", try renderText(a, "{% if v is defined %}def{% endif %}", &.{.{ "v", .{ .integer = 0 } }}, null));
    try testing.expectEqualStrings("even", try renderText(a, "{% if n is even %}even{% endif %}", &.{.{ "n", .{ .integer = 4 } }}, null));
    try testing.expectEqualStrings("none", try renderText(a, "{% if m is not defined %}none{% endif %}", &.{}, null));
}

test "filters: replace, length, join, round, default, capitalize, comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lst: std.json.Array = .init(a);
    try lst.append(.{ .string = "a" });
    try lst.append(.{ .string = "b" });
    try testing.expectEqualStrings("a-b", try renderText(a, "{ xs|join(\"-\") }", &.{.{ "xs", .{ .array = lst } }}, null));
    try testing.expectEqualStrings("2", try renderText(a, "{ xs|length }", &.{.{ "xs", .{ .array = lst } }}, null));
    try testing.expectEqualStrings("heLLo", try renderText(a, "{ s|replace(\"l\",\"L\") }", &.{.{ "s", .{ .string = "hello" } }}, null));
    try testing.expectEqualStrings("3.14", try renderText(a, "{ x|round(2) }", &.{.{ "x", .{ .float = 3.14159 } }}, null));
    try testing.expectEqualStrings("fallback", try renderText(a, "{ missing|default(\"fallback\") }", &.{}, null));
    try testing.expectEqualStrings("Hello", try renderText(a, "{ s|capitalize }", &.{.{ "s", .{ .string = "hello" } }}, null));
    try testing.expectEqualStrings("ab", try renderText(a, "a{# this is a comment #}b", &.{}, null));
}

test "malformed templates error, never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.json.ObjectMap = .empty;
    try testing.expectError(error.ParseError, render(a, "{% if x %}no end", "{}", &out));
    try testing.expectError(error.ParseError, render(a, "{ unclosed", "{}", &out));
    try testing.expectError(error.ParseError, render(a, "{% for %}{% endfor %}", "{}", &out));
    // Operating on undefined errors (member access on the undefined value)...
    try testing.expectError(error.EvalError, render(a, "{ undefined_var.attr }", "{}", &out));
    // ...but a bare undefined name renders empty (Jinja undefined), not an error.
    try testing.expectEqualStrings("", try renderText(a, "{ undefined_var }", &.{}, null));
}

test "i64.min edge cases don't overflow (abs, range, // -1, % -1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const min = std.math.minInt(i64);
    // abs(i64.min) promotes to float instead of overflowing.
    const s = try renderText(a, "{ x|abs }", &.{.{ "x", .{ .integer = min } }}, null);
    try testing.expect(s.len > 0);
    // range with i64.min lower bound is rejected by the bound check, not a crash.
    var out: std.json.ObjectMap = .empty;
    try testing.expectError(error.EvalError, render(a, "{ set_result(\"r\", range(-9223372036854775808, 1)|length) }", "{}", &out));
    // minInt // -1 and minInt % -1 error rather than overflow.
    try testing.expectError(error.EvalError, renderText(a, "{ x // -1 }", &.{.{ "x", .{ .integer = min } }}, null));
    try testing.expectError(error.EvalError, renderText(a, "{ x % -1 }", &.{.{ "x", .{ .integer = min } }}, null));
}

test "deeply nested expression errors instead of overflowing the stack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{ ");
    try buf.appendNTimes(a, '(', 500);
    try buf.appendSlice(a, "1");
    try buf.appendNTimes(a, ')', 500);
    try buf.appendSlice(a, " }");
    var out: std.json.ObjectMap = .empty;
    try testing.expectError(error.ParseError, render(a, buf.items, "{}", &out));
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
            var out: std.json.ObjectMap = .empty;
            render(a, tbuf[0..tn], pbuf[0..pn], &out) catch {};
            _ = renderText(a, tbuf[0..tn], &.{}, pbuf[0..pn]) catch {};
        }
    }.run, .{});
}

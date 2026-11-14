//! Internal: Elroy, the template compiler. At build time it turns a
//! template into a Zig function that writes the same HTML the interpreter
//! (render/renderer.zig) renders, reading the view's data by field instead
//! of converting it and looking names up per request. The rules of the
//! template language live in elroy/runtime.zig, resolved by type when the
//! app compiles; this file emits the calls, and translates conditions the
//! way `evalBool` reads them, step by step, so even its corner cases match.
//!
//! A template that uses what Elroy does not compile yet (components,
//! layouts, slots, helper calls, `current_user`, a condition that calls a
//! function) gets no function: it keeps rendering with the interpreter.

const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");

const Node = ast.Node;
const trimWhitespace = parser_mod.trimWhitespace;

const Unsupported = error{Unsupported};
const Error = Unsupported || std.mem.Allocator.Error;

const Frame = struct {
    /// The template's name for the loop item.
    capture: []const u8,
    id: usize,
    capture_used: bool = false,
    loop_used: bool = false,
};

const Gen = struct {
    alc: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,
    next_id: usize = 0,
    data_used: bool = false,
    w_used: bool = false,

    /// The handle a path starts from and the rest of the path.
    const Root = struct { handle: []const u8, path: []const u8 };

    fn root(g: *Gen, expr: []const u8) Error!Root {
        if (!isPath(expr)) return error.Unsupported;
        const end = std.mem.indexOfAny(u8, expr, ".[") orelse expr.len;
        const name = expr[0..end];
        const rest = if (end < expr.len and expr[end] == '.') expr[end + 1 ..] else expr[end..];
        if (std.mem.eql(u8, name, "current_user") or std.mem.eql(u8, name, "slot") or std.mem.startsWith(u8, name, "slot_"))
            return error.Unsupported;
        var i = g.frames.items.len;
        while (i > 0) {
            i -= 1;
            const f = &g.frames.items[i];
            if (std.mem.eql(u8, name, f.capture)) {
                f.capture_used = true;
                return .{ .handle = try std.fmt.allocPrint(g.alc, "__c{d}", .{f.id}), .path = rest };
            }
            if (std.mem.eql(u8, name, "loop")) {
                f.loop_used = true;
                return .{ .handle = try std.fmt.allocPrint(g.alc, "&__l{d}", .{f.id}), .path = rest };
            }
        }
        g.data_used = true;
        return .{ .handle = "&data", .path = expr };
    }

    fn nodes(g: *Gen, out: *std.ArrayList(u8), list: []const Node) Error!void {
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            if (list[i] != .text) {
                try g.node(out, list[i]);
                continue;
            }
            // Text nodes in a row: one write.
            var text: std.ArrayList(u8) = .empty;
            while (i < list.len and list[i] == .text) : (i += 1) try text.appendSlice(g.alc, list[i].text);
            i -= 1;
            try g.node(out, .{ .text = text.items });
        }
    }

    fn node(g: *Gen, out: *std.ArrayList(u8), n: Node) Error!void {
        switch (n) {
            .text => |t| if (t.len > 0) {
                g.w_used = true;
                try out.print(g.alc, "try w.writeAll(\"{f}\");\n", .{std.zig.fmtString(t)});
            },
            .interpolation => |e| {
                g.w_used = true;
                const r = try g.root(trimWhitespace(e));
                try out.print(g.alc, "try E.interp(w, {s}, \"{f}\");\n", .{ r.handle, std.zig.fmtString(r.path) });
            },
            .interpolation_with_default => |iwd| {
                g.w_used = true;
                const r = try g.root(trimWhitespace(iwd.expr));
                try out.print(g.alc, "try E.interpDefault(w, {s}, \"{f}\", \"{f}\");\n", .{ r.handle, std.zig.fmtString(r.path), std.zig.fmtString(iwd.default) });
            },
            .if_node => |ifn| {
                const cond = try g.condition(ifn.condition);
                try out.print(g.alc, "if ({s}) {{\n", .{cond});
                try g.nodes(out, ifn.then_body);
                if (ifn.else_body) |eb| {
                    try out.appendSlice(g.alc, "} else {\n");
                    try g.nodes(out, eb);
                }
                try out.appendSlice(g.alc, "}\n");
            },
            .for_node => |f| {
                const r = try g.root(trimWhitespace(f.iterable));
                const id = g.next_id;
                g.next_id += 1;
                try g.frames.append(g.alc, .{ .capture = f.capture, .id = id });
                var body: std.ArrayList(u8) = .empty;
                try g.nodes(&body, f.body);
                const frame = g.frames.pop().?;
                try out.print(g.alc, "for (E.items({s}, \"{f}\")", .{ r.handle, std.zig.fmtString(r.path) });
                if (frame.loop_used) try out.appendSlice(g.alc, ", 0..");
                try out.appendSlice(g.alc, ") |");
                if (frame.capture_used) try out.print(g.alc, "*__p{d}", .{id}) else try out.appendSlice(g.alc, "_");
                if (frame.loop_used) try out.print(g.alc, ", __i{d}", .{id});
                try out.appendSlice(g.alc, "| {\n");
                if (frame.capture_used) try out.print(g.alc, "const __c{d} = E.item(__p{d});\n", .{ id, id });
                if (frame.loop_used) try out.print(g.alc, "const __l{d} = E.Loop{{ .index = __i{d} }};\n", .{ id, id });
                try out.appendSlice(g.alc, body.items);
                try out.appendSlice(g.alc, "}\n");
            },
            .component, .slot, .call => return error.Unsupported,
        }
    }

    /// `evalBool`, at build time: the same splits in the same order, each
    /// side compiled again; what is left is a name's truth.
    fn condition(g: *Gen, expr: []const u8) Error![]const u8 {
        const splits = [_]struct { sep: []const u8, op: []const u8 }{
            .{ .sep = " or ", .op = "or" },
            .{ .sep = " and ", .op = "and" },
        };
        for (splits) |s| {
            if (std.mem.indexOf(u8, expr, s.sep)) |idx| {
                const l = try g.condition(trimWhitespace(expr[0..idx]));
                const r = try g.condition(trimWhitespace(expr[idx + s.sep.len ..]));
                return std.fmt.allocPrint(g.alc, "({s} {s} {s})", .{ l, s.op, r });
            }
        }
        if (std.mem.indexOf(u8, expr, " != ")) |idx| {
            return std.fmt.allocPrint(g.alc, "!({s})", .{try g.compare(trimWhitespace(expr[0..idx]), trimWhitespace(expr[idx + 4 ..]))});
        }
        if (std.mem.indexOf(u8, expr, " == ")) |idx| {
            return g.compare(trimWhitespace(expr[0..idx]), trimWhitespace(expr[idx + 4 ..]));
        }
        const nums = [_]struct { sep: []const u8, cmp: []const u8 }{
            .{ .sep = " <= ", .cmp = "lte" },
            .{ .sep = " >= ", .cmp = "gte" },
            .{ .sep = " < ", .cmp = "lt" },
            .{ .sep = " > ", .cmp = "gt" },
        };
        for (nums) |s| {
            if (std.mem.indexOf(u8, expr, s.sep)) |idx| {
                const l = try g.operand(trimWhitespace(expr[0..idx]));
                const r = try g.operand(trimWhitespace(expr[idx + s.sep.len ..]));
                return std.fmt.allocPrint(g.alc, "E.numCmp({s}, {s}, .{s})", .{ l, r, s.cmp });
            }
        }
        const trimmed = trimWhitespace(expr);
        if (trimmed.len > 0 and trimmed[0] == '!') {
            return std.fmt.allocPrint(g.alc, "!({s})", .{try g.condition(trimmed[1..])});
        }
        try refuseCall(expr);
        // `resolveValue(ctx, expr)`: the expression as it is, spaces
        // included (a name with spaces around it is no name).
        if (!std.mem.eql(u8, expr, trimmed) or !isPath(expr)) return "false";
        const r = try g.root(expr);
        return std.fmt.allocPrint(g.alc, "E.truthy({s}, \"{f}\")", .{ r.handle, std.zig.fmtString(r.path) });
    }

    fn compare(g: *Gen, left: []const u8, right: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, right, "null")) {
            try refuseCall(left);
            if (!isPath(left)) return "true"; // no such name
            const r = try g.root(left);
            return std.fmt.allocPrint(g.alc, "E.isNull({s}, \"{f}\")", .{ r.handle, std.zig.fmtString(r.path) });
        }
        const l = try g.operand(left);
        const r = try g.operand(right);
        return std.fmt.allocPrint(g.alc, "E.eqText({s}, {s})", .{ l, r });
    }

    /// `operandText`: a quoted literal without its quotes; a number,
    /// `true` or `false` as written; else a name's text (`resolveLen`).
    fn operand(g: *Gen, op: []const u8) Error![]const u8 {
        if (op.len >= 2 and op[0] == '"' and op[op.len - 1] == '"')
            return std.fmt.allocPrint(g.alc, "E.lit(\"{f}\")", .{std.zig.fmtString(op[1 .. op.len - 1])});
        if (std.mem.eql(u8, op, "true") or std.mem.eql(u8, op, "false") or isNumber(op))
            return std.fmt.allocPrint(g.alc, "E.lit(\"{f}\")", .{std.zig.fmtString(op)});
        try refuseCall(op);
        if (std.mem.indexOf(u8, op, ".len")) |dot| {
            const prefix = op[0..dot];
            if (prefix.len == 0) return "E.lit(\"0\")";
            if (!isPath(prefix)) return "E.lit(\"0\")";
            const r = try g.root(prefix);
            return std.fmt.allocPrint(g.alc, "E.lenText({s}, \"{f}\")", .{ r.handle, std.zig.fmtString(r.path) });
        }
        if (!isPath(op)) return "E.lit(\"\")";
        const r = try g.root(op);
        return std.fmt.allocPrint(g.alc, "E.valueText({s}, \"{f}\")", .{ r.handle, std.zig.fmtString(r.path) });
    }
};

/// A condition that calls a function is an error at run time in the
/// interpreter; such a template stays there.
fn refuseCall(operand: []const u8) Unsupported!void {
    const quoted = operand.len >= 2 and operand[0] == '"' and operand[operand.len - 1] == '"';
    if (!quoted and std.mem.indexOfScalar(u8, operand, '(') != null) return error.Unsupported;
}

fn isNumber(text: []const u8) bool {
    const digits = if (text.len > 1 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    return digits.len > 0 and std.ascii.isDigit(digits[0]);
}

/// A name or a path: `title`, `book.author`, `books[0].title`, `items.len`.
fn isPath(expr: []const u8) bool {
    if (expr.len == 0 or std.ascii.isDigit(expr[0]) or expr[0] == '.' or expr[0] == '[') return false;
    for (expr) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']')) return false;
    return true;
}

/// Appends to `out` a function `pub fn @"<name>"(w, data) !void` that
/// renders template `src`, and returns true; returns false (and appends
/// nothing) when the template uses what Elroy does not compile yet.
pub fn generate(alc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, src: []const u8) std.mem.Allocator.Error!bool {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, src, " \t\r\n"), "-- doc")) return false;
    var arena = std.heap.ArenaAllocator.init(alc);
    defer arena.deinit();
    const a = arena.allocator();
    var p = parser_mod.Parser.init(a, src);
    p.log_failure = false;
    const parsed = p.parse() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (parsed.layout != null) return false;
    var g: Gen = .{ .alc = a };
    var body: std.ArrayList(u8) = .empty;
    g.nodes(&body, parsed.nodes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return false,
    };
    try out.print(alc, "pub fn {f}(w: *std.Io.Writer, data: anytype) !void {{\n", .{std.zig.fmtId(name)});
    if (!g.data_used) try out.appendSlice(alc, "_ = data;\n");
    if (!g.w_used) try out.appendSlice(alc, "_ = w;\n");
    try out.appendSlice(alc, body.items);
    try out.appendSlice(alc, "}\n");
    return true;
}

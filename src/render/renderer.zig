const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const ctx_mod = @import("context.zig");
const parser_mod = @import("parser.zig");

const Node = ast.Node;
const freeNode = ast.freeNode;
const Context = ctx_mod.Context;
const Value = ctx_mod.Value;
const dupeValue = ctx_mod.dupeValue;
const Parser = parser_mod.Parser;
const trimWhitespace = parser_mod.trimWhitespace;

/// Deepest allowed component nesting. Real layouts stay far below this; the
/// limit exists so a component that (directly or indirectly) includes itself
/// fails with `error.ComponentDepthExceeded` instead of overflowing the stack
/// and taking the whole process down (small coroutine stacks under zio hit
/// that fast).
pub const max_component_depth: usize = 32;

/// Per-render state threaded through renderNode.
pub const RenderState = struct {
    components: ?std.StringHashMapUnmanaged([]const u8),
    /// Component name -> parsed body, so a component used N times in one
    /// render (e.g. inside a `for`) is parsed once, not N times.
    parsed: std.StringHashMapUnmanaged([]Node) = .{},
    /// Components currently being rendered, outermost first (for the error log).
    stack: [max_component_depth][]const u8 = undefined,
    depth: usize = 0,

    pub fn init(components: ?std.StringHashMapUnmanaged([]const u8)) RenderState {
        return .{ .components = components };
    }

    pub fn deinit(self: *RenderState, alc: std.mem.Allocator) void {
        var it = self.parsed.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |n| freeNode(n, alc);
            alc.free(entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        self.parsed.deinit(alc);
    }

    /// Parsed body of component `name`, or null when it isn't registered.
    fn componentNodes(self: *RenderState, alc: std.mem.Allocator, name: []const u8) !?[]Node {
        if (self.parsed.get(name)) |nodes| return nodes;
        const comps = self.components orelse return null;
        const template_str = comps.get(name) orelse blk: {
            // PascalCase -> snake_case fallback ("UserCard" -> "user_card").
            var field_buf: [256]u8 = undefined;
            var field_len: usize = 0;
            for (name, 0..) |ch, i| {
                if (field_len + 2 > field_buf.len) break :blk null;
                if (ch >= 'A' and ch <= 'Z') {
                    if (i > 0) {
                        field_buf[field_len] = '_';
                        field_len += 1;
                    }
                    field_buf[field_len] = ch + 32;
                } else {
                    field_buf[field_len] = ch;
                }
                field_len += 1;
            }
            break :blk comps.get(field_buf[0..field_len]);
        } orelse return null;

        var comp_parser = Parser.init(alc, template_str);
        const parsed = try comp_parser.parse();
        errdefer {
            for (parsed.nodes) |n| freeNode(n, alc);
            alc.free(parsed.nodes);
        }
        const key = try alc.dupe(u8, name);
        errdefer alc.free(key);
        try self.parsed.put(alc, key, parsed.nodes);
        return parsed.nodes;
    }

    fn logDepthExceeded(self: *RenderState, next: []const u8) void {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (self.stack[0..self.depth]) |n| w.print("{s} > ", .{n}) catch break;
        w.print("{s}", .{next}) catch {};
        // warn under `zig test` only: the test runner fails any test that logs
        // at err level, and the tests trigger this on purpose.
        const log = if (builtin.is_test) std.log.warn else std.log.err;
        log(
            "[spider] template: component nesting deeper than {d} (a component probably includes itself): {s}",
            .{ max_component_depth, w.buffered() },
        );
    }
};

pub fn renderNode(node: Node, ctx: *Context, alc: std.mem.Allocator, result: *std.ArrayList(u8), state: *RenderState) anyerror!void {
    switch (node) {
        .text => |text| {
            try result.appendSlice(alc, text);
        },
        .interpolation => |expr| {
            if (std.mem.eql(u8, expr, "slot")) {
                if (ctx.get("slot")) |value| {
                    if (value == .string and value.string.len > 0) {
                        try result.appendSlice(alc, value.string);
                    }
                }
            } else {
                const value = resolveValue(ctx, expr);
                if (value) |v| {
                    const str = try valueToString(v, alc);
                    try result.appendSlice(alc, str);
                    alc.free(str);
                }
            }
        },
        .interpolation_with_default => |iwd| {
            const value = resolveValue(ctx, iwd.expr);
            if (value) |v| {
                const str = try valueToString(v, alc);
                defer alc.free(str);
                if (str.len > 0 and !std.mem.eql(u8, str, "false")) {
                    try result.appendSlice(alc, str);
                } else {
                    try result.appendSlice(alc, iwd.default);
                }
            } else {
                try result.appendSlice(alc, iwd.default);
            }
        },
        .if_node => |ifn| {
            const cond = evalBool(ctx, ifn.condition, alc);
            if (cond) {
                for (ifn.then_body) |n| try renderNode(n, ctx, alc, result, state);
            } else if (ifn.else_body) |eb| {
                for (eb) |n| try renderNode(n, ctx, alc, result, state);
            }
        },
        .for_node => |fnn| {
            if (resolveValue(ctx, fnn.iterable)) |value| {
                if (value == .list) {
                    for (value.list, 0..) |elem, idx| {
                        var loop_ctx = try ctx.clone(alc);
                        defer loop_ctx.deinit(alc);
                        switch (elem) {
                            .string => try loop_ctx.set(alc, fnn.capture, Value{ .string = try alc.dupe(u8, elem.string) }),
                            .object => {
                                var obj_copy = std.StringHashMapUnmanaged(Value){};
                                var iter = elem.object.iterator();
                                while (iter.next()) |entry| {
                                    try obj_copy.put(alc, try alc.dupe(u8, entry.key_ptr.*), try dupeValue(alc, entry.value_ptr.*));
                                }
                                try loop_ctx.set(alc, fnn.capture, Value{ .object = obj_copy });
                            },
                            else => {},
                        }
                        var loop_obj = std.StringHashMapUnmanaged(Value){};
                        try loop_obj.put(alc, try alc.dupe(u8, "index"), Value{ .string = try std.fmt.allocPrint(alc, "{d}", .{idx}) });
                        try loop_ctx.set(alc, "loop", Value{ .object = loop_obj });
                        for (fnn.body) |n| try renderNode(n, &loop_ctx, alc, result, state);
                    }
                }
            }
        },
        .component => |comp| {
            const comp_nodes = (try state.componentNodes(alc, comp.name)) orelse return;

            if (state.depth >= max_component_depth) {
                state.logDepthExceeded(comp.name);
                return error.ComponentDepthExceeded;
            }
            state.stack[state.depth] = comp.name;
            state.depth += 1;
            defer state.depth -= 1;

            var comp_ctx = try ctx.clone(alc);
            defer comp_ctx.deinit(alc);

            for (comp.props) |prop| {
                if (resolveValue(ctx, prop.value)) |val| {
                    try comp_ctx.set(alc, prop.name, try dupeValue(alc, val));
                } else {
                    try comp_ctx.set(alc, prop.name, Value{ .string = try alc.dupe(u8, prop.value) });
                }
            }

            if (comp.slot_content) |sc| {
                var slot_parser = Parser.init(alc, sc);
                const slot_result = try slot_parser.parse();
                defer {
                    for (slot_result.nodes) |n| freeNode(n, alc);
                    alc.free(slot_result.nodes);
                }
                var slot_buf = std.ArrayList(u8).empty;
                for (slot_result.nodes) |n| {
                    try renderNode(n, &comp_ctx, alc, &slot_buf, state);
                }
                try comp_ctx.set(alc, "slot", Value{ .string = try slot_buf.toOwnedSlice(alc) });
            }

            for (comp_nodes) |n| {
                try renderNode(n, &comp_ctx, alc, result, state);
            }
        },
        .slot => {},
        .call => |call| {
            // Same @import-condicional pattern already used for spider_config
            // (see core/app.zig): the app's build.zig can override the
            // "template_helpers" module with its own; if it doesn't, the
            // framework's own build.zig wires an empty default, so this
            // @import always resolves and unknown calls just render empty.
            const helpers = @import("template_helpers");
            inline for (@typeInfo(helpers).@"struct".decl_names) |decl_name| {
                if (std.mem.eql(u8, decl_name, call.name)) {
                    const value = @field(helpers, decl_name)(alc, call.args) catch null;
                    if (value) |v| {
                        defer alc.free(v);
                        try result.appendSlice(alc, v);
                    }
                }
            }
        },
    }
}

// Resolves a dotted/bracketed path against the context, walking through
// nested objects and lists at any depth (e.g. "g.packages[0].id", where
// "packages" is a list field on the loop-bound object "g", not a top-level
// context key). Each segment between dots may carry a single "[idx]" suffix.
fn resolveSegment(current: ?Value, seg: []const u8) ?Value {
    if (std.mem.indexOfScalar(u8, seg, '[')) |bracket_pos| {
        const field_name = seg[0..bracket_pos];
        const close = std.mem.indexOfScalar(u8, seg, ']') orelse return null;
        const index = std.fmt.parseInt(usize, seg[bracket_pos + 1 .. close], 10) catch return null;

        const list_val = if (field_name.len == 0)
            current orelse return null
        else blk: {
            const c = current orelse return null;
            if (c != .object) return null;
            break :blk c.object.get(field_name) orelse return null;
        };

        if (list_val != .list or index >= list_val.list.len) return null;
        return list_val.list[index];
    }

    const c = current orelse return null;
    if (c != .object) return null;
    return c.object.get(seg);
}

fn resolveValue(ctx: *const Context, expr: []const u8) ?Value {
    var it = std.mem.splitScalar(u8, expr, '.');
    const first_seg = it.next() orelse return null;

    var current: ?Value = if (std.mem.indexOfScalar(u8, first_seg, '[')) |bracket_pos| blk: {
        const list_name = first_seg[0..bracket_pos];
        break :blk resolveSegment(ctx.get(list_name), first_seg[bracket_pos..]) orelse return null;
    } else ctx.get(first_seg) orelse return null;

    while (it.next()) |seg| {
        current = resolveSegment(current, seg) orelse return null;
    }

    return current;
}

fn evalBool(ctx: *Context, expr: []const u8, alc: std.mem.Allocator) bool {
    // or binds looser than and — check first so each side may contain "and"
    if (std.mem.indexOf(u8, expr, " or ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalBool(ctx, left, alc) or evalBool(ctx, right, alc);
    }
    if (std.mem.indexOf(u8, expr, " and ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 5 ..]);
        return evalBool(ctx, left, alc) and evalBool(ctx, right, alc);
    }
    if (std.mem.indexOf(u8, expr, " != ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right_raw = trimWhitespace(expr[idx + 4 ..]);
        const right = if (right_raw.len >= 2 and right_raw[0] == '"' and right_raw[right_raw.len - 1] == '"')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;
        return !evalCompare(ctx, left, right, alc);
    }
    if (std.mem.indexOf(u8, expr, " == ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right_raw = trimWhitespace(expr[idx + 4 ..]);
        const right = if (right_raw.len >= 2 and right_raw[0] == '"' and right_raw[right_raw.len - 1] == '"')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;
        return evalCompare(ctx, left, right, alc);
    }
    if (std.mem.indexOf(u8, expr, " <= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .lte, alc);
    }
    if (std.mem.indexOf(u8, expr, " >= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .gte, alc);
    }
    if (std.mem.indexOf(u8, expr, " < ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .lt, alc);
    }
    if (std.mem.indexOf(u8, expr, " > ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .gt, alc);
    }

    // Unary "!" negation — checked after and/or/comparison so a genuine
    // binary condition (e.g. "role != \"council\"") is never misread as a
    // leading "!"; a real leading "!" only survives to here for something
    // like "!is_admin_tier". Recurses so "!a and b" still parses as
    // "(!a) and b" — the " and "/" or " splits above run first and hand
    // each side back into evalBool, where this check applies to "!a" on
    // its own. Note: this does NOT add general parenthesized grouping —
    // evalBool has no paren-stripping, so "!(a and b)" would still
    // misparse (the " and " split doesn't know to treat "(a"/"b)" as one
    // group). Only a plain "!identifier" or "!left op right" is supported.
    const trimmed = trimWhitespace(expr);
    if (trimmed.len > 0 and trimmed[0] == '!') {
        return !evalBool(ctx, trimmed[1..], alc);
    }

    if (resolveValue(ctx, expr)) |value| {
        if (value == .boolean) return value.boolean;
        if (value == .string) return value.string.len > 0 and !std.mem.eql(u8, value.string, "false");
    }
    return false;
}

fn evalCompare(ctx: *Context, left: []const u8, right: []const u8, alc: std.mem.Allocator) bool {
    const resolved = resolveLen(ctx, left, alc) catch return false;
    defer alc.free(resolved);
    return std.mem.eql(u8, resolved, right);
}

const Cmp = enum { lt, lte, gt, gte };

fn evalNumCompare(ctx: *Context, left: []const u8, right: []const u8, cmp: Cmp, alc: std.mem.Allocator) bool {
    const resolved = resolveLen(ctx, left, alc) catch return false;
    defer alc.free(resolved);
    const l = resolved;

    const lv = std.fmt.parseInt(i64, l, 10) catch return false;
    const rv = std.fmt.parseInt(i64, right, 10) catch return false;

    return switch (cmp) {
        .lt => lv < rv,
        .lte => lv <= rv,
        .gt => lv > rv,
        .gte => lv >= rv,
    };
}

fn resolveLen(ctx: *const Context, expr: []const u8, alc: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOf(u8, expr, ".len")) |dot_idx| {
        const var_name = expr[0..dot_idx];
        if (ctx.get(var_name)) |v| {
            if (v == .list) {
                return try std.fmt.allocPrint(alc, "{d}", .{v.list.len});
            }
            if (v == .string) {
                return try std.fmt.allocPrint(alc, "{d}", .{v.string.len});
            }
        }
        if (resolveValue(ctx, var_name)) |v| {
            if (v == .list) {
                return try std.fmt.allocPrint(alc, "{d}", .{v.list.len});
            }
            if (v == .string) {
                return try std.fmt.allocPrint(alc, "{d}", .{v.string.len});
            }
        }
        return try alc.dupe(u8, "0");
    }
    if (resolveValue(ctx, expr)) |v| {
        return try valueToString(v, alc);
    }
    return try alc.dupe(u8, "");
}

fn valueToString(value: Value, alc: std.mem.Allocator) ![]const u8 {
    switch (value) {
        .string => |s| return try alc.dupe(u8, s),
        .boolean => |b| return if (b) try alc.dupe(u8, "true") else try alc.dupe(u8, "false"),
        else => return try alc.dupe(u8, ""),
    }
}

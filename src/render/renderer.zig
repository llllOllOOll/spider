//! Internal: renders parsed template nodes to HTML: escaped interpolation,
//! `if` / `for`, components with props and slots, and `template_helpers`
//! calls. `Template.render` drives it.

const std = @import("std");
const assets = @import("assets.zig");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const ctx_mod = @import("context.zig");
const parser_mod = @import("parser.zig");
const embedded = @import("embedded.zig");
const parsed_cache = @import("parsed_cache.zig");
const props_decl = @import("props_decl.zig");

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

/// What a template does with a name it cannot find: a variable, a field,
/// a loop item, a prop, a component or a layout that does not exist. A name
/// that is declared with no value (a null optional) is not "not found".
pub const Strictness = enum {
    /// Render empty, say nothing (what templates always did).
    off,
    /// Render empty and log a warning, once per name and render, naming the
    /// view, the components it was inside, and the name.
    warn,
    /// Fail the render with `error.TemplateNameNotFound` (a 500), after
    /// the same log line.
    @"error",
};

/// Per-render state threaded through renderNode.
pub const RenderState = struct {
    components: ?std.StringHashMapUnmanaged([]const u8),
    /// Shared read-only components, looked up after `components`.
    base: ?*const embedded.Map = null,
    /// Component name -> parsed body, so a component used N times in one
    /// render (e.g. inside a `for`) is parsed once, not N times.
    parsed: std.StringHashMapUnmanaged([]Node) = .{},
    /// Components currently being rendered, outermost first (for the error log).
    stack: [max_component_depth][]const u8 = undefined,
    depth: usize = 0,
    /// What to do with a name that is not found (see Strictness).
    strict: Strictness = .off,
    /// The view being rendered, for the diagnostics.
    view_name: ?[]const u8 = null,
    /// Names already reported in this render (one line per name).
    warned: std.StringHashMapUnmanaged(void) = .{},
    /// Component name -> its `-- props:` declaration (null: none), read
    /// once per render when the parsed-template cache does not have it.
    decls: std.StringHashMapUnmanaged(?props_decl.Decl) = .{},

    pub fn init(components: ?std.StringHashMapUnmanaged([]const u8), base: ?*const embedded.Map) RenderState {
        return .{ .components = components, .base = base };
    }

    fn lookup(self: *const RenderState, name: []const u8) ?[]const u8 {
        if (self.components) |comps| {
            if (comps.get(name)) |src| return src;
        }
        if (self.base) |base| return base.get(name);
        return null;
    }

    pub fn deinit(self: *RenderState, alc: std.mem.Allocator) void {
        var it = self.parsed.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |n| freeNode(n, alc);
            alc.free(entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        self.parsed.deinit(alc);
        var wit = self.warned.keyIterator();
        while (wit.next()) |k| alc.free(k.*);
        self.warned.deinit(alc);
        var dit = self.decls.iterator();
        while (dit.next()) |e| {
            alc.free(e.key_ptr.*);
            if (e.value_ptr.*) |d| alc.free(d.props);
        }
        self.decls.deinit(alc);
    }

    /// A problem with a component's props (see props_decl.zig): logged once
    /// per render like `notFound`, and in `.error` mode the render fails
    /// with `error.TemplatePropInvalid`.
    fn propProblem(self: *RenderState, alc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        if (self.strict == .off) return;
        const msg = try std.fmt.allocPrint(alc, fmt, args);
        const gop = try self.warned.getOrPut(alc, msg);
        if (gop.found_existing) {
            alc.free(msg);
        } else {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (self.stack[0..self.depth]) |n| w.print(" in <{s}>", .{n}) catch break;
            const tail = "[spider] template \"{s}\"{s}: {s}; {s}";
            const targs = .{ self.view_name orelse "?", w.buffered(), msg, if (self.strict == .@"error") "the render fails" else "it renders anyway" };
            if (builtin.is_test or self.strict == .warn) std.log.warn(tail, targs) else std.log.err(tail, targs);
        }
        if (self.strict == .@"error") return error.TemplatePropInvalid;
    }

    /// The `-- props:` declaration of component `name` (source `src`), or null.
    fn componentDecl(self: *RenderState, alc: std.mem.Allocator, name: []const u8, src: []const u8) !?props_decl.Decl {
        if (props_decl.headerLine(src) == null) return null;
        if (parsed_cache.decl(src)) |d| return d;
        if (self.decls.get(name)) |d| return d;
        const d = props_decl.parse(alc, src) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // The parser already refused the template (a syntax error).
            error.InvalidPropsHeader => null,
        };
        try self.decls.put(alc, try alc.dupe(u8, name), d);
        return d;
    }

    /// A name the template reads that is not there: says so (once per name
    /// and render) and, in `.error` mode, fails the render.
    pub fn notFound(self: *RenderState, alc: std.mem.Allocator, comptime what: []const u8, name: []const u8) !void {
        if (self.strict == .off) return;
        const key = try std.fmt.allocPrint(alc, what ++ ":{s}", .{name});
        const gop = try self.warned.getOrPut(alc, key);
        if (gop.found_existing) {
            alc.free(key);
        } else {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (self.stack[0..self.depth]) |n| w.print(" in <{s}>", .{n}) catch break;
            const consequence = if (self.strict == .@"error") "the render fails" else "it renders empty";
            const fmt = "[spider] template \"{s}\"{s}: " ++ what ++ " `{s}` not found; {s}";
            const args = .{ self.view_name orelse "?", w.buffered(), name, consequence };
            // err only when the render fails (and never under `zig test`:
            // the test runner fails a test that logs at err).
            if (builtin.is_test or self.strict == .warn) std.log.warn(fmt, args) else std.log.err(fmt, args);
        }
        if (self.strict == .@"error") return error.TemplateNameNotFound;
    }

    /// The source of component `name`: as written, or its snake_case file.
    fn componentSource(self: *const RenderState, name: []const u8) ?[]const u8 {
        if (self.components == null and self.base == null) return null;
        return self.lookup(name) orelse blk: {
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
            break :blk self.lookup(field_buf[0..field_len]);
        };
    }

    /// Parsed body of component `name`, or null when it isn't registered.
    fn componentNodes(self: *RenderState, alc: std.mem.Allocator, name: []const u8) !?[]Node {
        if (self.parsed.get(name)) |nodes| return nodes;
        const template_str = self.componentSource(name) orelse return null;

        // An embedded source is parsed once for the whole process.
        if (parsed_cache.raw(template_str)) |nodes| return nodes;

        var comp_parser = Parser.init(alc, template_str);
        comp_parser.name = name;
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
            if (resolveValue(ctx, expr)) |v| {
                try appendValue(alc, result, v);
            } else if (lenOf(ctx, expr)) |n| {
                try result.print(alc, "{d}", .{n});
            } else if (undeclared(ctx, expr)) {
                try state.notFound(alc, "name", expr);
            }
        },
        .interpolation_with_default => |iwd| {
            const value = resolveValue(ctx, iwd.expr);
            if (value) |v| {
                const str = try valueToString(v, alc);
                defer alc.free(str);
                if (str.len > 0 and !std.mem.eql(u8, str, "false")) {
                    try appendValue(alc, result, v);
                } else {
                    try result.appendSlice(alc, iwd.default);
                }
            } else {
                try result.appendSlice(alc, iwd.default);
            }
        },
        .if_node => |ifn| {
            const cond = try evalBool(ctx, ifn.condition, alc, state);
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
                        // What the body sees: the page, plus this item
                        // and `loop`. Only those two are this iteration's.
                        var loop_ctx = ctx.child();
                        defer loop_ctx.deinit(alc);
                        switch (elem) {
                            .string => try loop_ctx.set(alc, fnn.capture, Value{ .string = try alc.dupe(u8, elem.string) }),
                            .html => try loop_ctx.set(alc, fnn.capture, Value{ .html = try alc.dupe(u8, elem.html) }),
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
            } else if (undeclared(ctx, fnn.iterable)) {
                try state.notFound(alc, "name", fnn.iterable);
            }
        },
        .component => |comp| {
            const comp_nodes = (try state.componentNodes(alc, comp.name)) orelse {
                try state.notFound(alc, "component", comp.name);
                return;
            };

            if (state.depth >= max_component_depth) {
                state.logDepthExceeded(comp.name);
                return error.ComponentDepthExceeded;
            }
            // The component sees what its caller sees, plus its props. The
            // props are read in the caller: a missing one is reported there.
            var comp_ctx = ctx.child();
            defer comp_ctx.deinit(alc);

            for (comp.props) |prop| {
                if (!prop.is_expr) {
                    // A literal prop is template source, like the markup around it.
                    try comp_ctx.set(alc, prop.name, Value{ .html = try alc.dupe(u8, prop.value) });
                } else if (resolveValue(ctx, prop.value)) |val| {
                    try comp_ctx.set(alc, prop.name, try dupeValue(alc, val));
                } else {
                    // Nothing by that name: empty, as `{ expr }` is.
                    if (undeclared(ctx, prop.value)) try state.notFound(alc, "name", prop.value);
                    try comp_ctx.set(alc, prop.name, Value{ .string = try alc.dupe(u8, "") });
                }
            }

            if (state.componentSource(comp.name)) |src| {
                if (try state.componentDecl(alc, comp.name, src)) |decl| {
                    try applyPropsDecl(state, alc, comp.name, comp.props, decl, ctx, &comp_ctx);
                }
            }

            state.stack[state.depth] = comp.name;
            state.depth += 1;
            defer state.depth -= 1;

            if (comp.slot_content) |sc| {
                const cached_slot = parsed_cache.raw(sc);
                const slot_nodes: []Node = cached_slot orelse blk: {
                    var slot_parser = Parser.init(alc, sc);
                    slot_parser.name = comp.name;
                    break :blk (try slot_parser.parse()).nodes;
                };
                defer if (cached_slot == null) {
                    for (slot_nodes) |n| freeNode(n, alc);
                    alc.free(slot_nodes);
                };
                var slot_buf = std.ArrayList(u8).empty;
                for (slot_nodes) |n| {
                    try renderNode(n, &comp_ctx, alc, &slot_buf, state);
                }
                try comp_ctx.set(alc, "slot", Value{ .html = try slot_buf.toOwnedSlice(alc) });
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
            var found = false;
            inline for (@typeInfo(helpers).@"struct".decl_names) |decl_name| {
                if (std.mem.eql(u8, decl_name, call.name)) {
                    found = true;
                    const value = @field(helpers, decl_name)(alc, call.args) catch null;
                    if (value) |v| {
                        defer alc.free(v);
                        try result.appendSlice(alc, v);
                    }
                }
            }
            // Built in, unless the app's helpers define it.
            if (!found and std.mem.eql(u8, call.name, "asset_url") and call.args.len == 1) {
                const v = try assets.url(alc, call.args[0]);
                defer alc.free(v);
                try result.appendSlice(alc, v);
            }
        },
    }
}

/// A component that declares its props (`-- props:`): checks the call
/// against the declaration and fills what the call leaves out. Reports, in
/// the caller: a prop the component does not declare, a literal of the
/// wrong type (`year="1969x"` for `year: int`), and a required prop that
/// is neither given nor in the caller's scope. A prop left out takes its
/// default; one with no default takes the caller's value of that name when
/// there is one (a component sees its caller's names), else it is declared
/// with no value. A `bool` literal becomes true/false.
fn applyPropsDecl(state: *RenderState, alc: std.mem.Allocator, comp_name: []const u8, given: []const ast.Prop, decl: props_decl.Decl, caller: *Context, comp_ctx: *Context) !void {
    for (given) |prop| {
        const declared = decl.get(prop.name) orelse {
            const names = try decl.names(alc);
            defer alc.free(names);
            try state.propProblem(alc, "<{s}> has no prop `{s}` (it declares: {s})", .{ comp_name, prop.name, names });
            continue;
        };
        if (prop.is_expr) continue; // an expression's type: checked at build time by c.viewChecked
        if (!declared.accepts(prop.value)) {
            try state.propProblem(alc, "prop `{s}` of <{s}> is {s}; \"{s}\" is not", .{ prop.name, comp_name, @tagName(declared.kind), prop.value });
        } else if (declared.kind == .bool) {
            try comp_ctx.set(alc, prop.name, Value{ .boolean = std.mem.eql(u8, prop.value, "true") });
        }
    }
    for (decl.props) |declared| {
        var passed = false;
        for (given) |prop| {
            if (std.mem.eql(u8, prop.name, declared.name)) passed = true;
        }
        if (passed) continue;
        if (!undeclared(caller, declared.name)) {
            // The caller has a value of that name: the component sees it
            // (as it would without the declaration). The default is for
            // when nobody gives one.
        } else if (declared.default) |def| {
            const v: Value = switch (declared.kind) {
                .bool => .{ .boolean = std.mem.eql(u8, def, "true") },
                else => .{ .html = try alc.dupe(u8, def) },
            };
            try comp_ctx.set(alc, declared.name, v);
        } else {
            if (declared.required) {
                try state.propProblem(alc, "<{s}> needs prop `{s}`, and the call does not give it", .{ comp_name, declared.name });
            }
            try comp_ctx.set(alc, declared.name, .none);
        }
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

/// `list.len` (or a string's): the count, when the name before `.len` is
/// a list or a string. A field named `len` is found by resolveValue first.
fn lenOf(ctx: *const Context, expr: []const u8) ?usize {
    if (!std.mem.endsWith(u8, expr, ".len")) return null;
    return switch (resolveValue(ctx, expr[0 .. expr.len - ".len".len]) orelse return null) {
        .list => |l| l.len,
        .string, .html => |t| t.len,
        else => null,
    };
}

/// True when `expr` names something that is not there: its first name is
/// in no scope, or a field after it is missing from an object that is
/// there. False when the path stops at a declared null (`.none`), at a
/// list index past the end (that is data, not a typo), at `.len` of a list
/// or a string, or at a name every template has (`slot`, `slot_<name>`,
/// `loop`).
fn undeclared(ctx: *const Context, expr: []const u8) bool {
    var it = std.mem.splitScalar(u8, expr, '.');
    const first_seg = it.next() orelse return false;
    const root = if (std.mem.indexOfScalar(u8, first_seg, '[')) |b| first_seg[0..b] else first_seg;
    if (std.mem.eql(u8, root, "slot") or std.mem.startsWith(u8, root, "slot_") or std.mem.eql(u8, root, "loop")) return false;
    var current: Value = ctx.get(root) orelse return true;
    if (std.mem.indexOfScalar(u8, first_seg, '[') != null) {
        current = resolveSegment(current, first_seg[root.len..]) orelse return false;
    }
    while (it.next()) |seg| {
        switch (current) {
            .none => return false,
            .list, .string, .html => return !std.mem.eql(u8, seg, "len"),
            .object => |obj| {
                const name = if (std.mem.indexOfScalar(u8, seg, '[')) |b| seg[0..b] else seg;
                if (!obj.contains(name)) return true;
                current = resolveSegment(current, seg) orelse return false;
            },
            .boolean => return true,
        }
    }
    return false;
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

const EvalError = error{ UnsupportedCondition, OutOfMemory, TemplateNameNotFound };

fn evalBool(ctx: *Context, expr: []const u8, alc: std.mem.Allocator, state: *RenderState) EvalError!bool {
    // or binds looser than and — check first so each side may contain "and"
    if (std.mem.indexOf(u8, expr, " or ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return try evalBool(ctx, left, alc, state) or try evalBool(ctx, right, alc, state);
    }
    if (std.mem.indexOf(u8, expr, " and ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 5 ..]);
        return try evalBool(ctx, left, alc, state) and try evalBool(ctx, right, alc, state);
    }
    if (std.mem.indexOf(u8, expr, " != ")) |idx| {
        return !try evalCompare(ctx, trimWhitespace(expr[0..idx]), trimWhitespace(expr[idx + 4 ..]), alc, state);
    }
    if (std.mem.indexOf(u8, expr, " == ")) |idx| {
        return evalCompare(ctx, trimWhitespace(expr[0..idx]), trimWhitespace(expr[idx + 4 ..]), alc, state);
    }
    if (std.mem.indexOf(u8, expr, " <= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .lte, alc, state);
    }
    if (std.mem.indexOf(u8, expr, " >= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .gte, alc, state);
    }
    if (std.mem.indexOf(u8, expr, " < ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .lt, alc, state);
    }
    if (std.mem.indexOf(u8, expr, " > ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .gt, alc, state);
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
        return !try evalBool(ctx, trimmed[1..], alc, state);
    }

    try refuseCall(expr);
    if (resolveValue(ctx, expr)) |value| {
        if (value == .boolean) return value.boolean;
        if (value == .string) return value.string.len > 0 and !std.mem.eql(u8, value.string, "false");
        if (value == .html) return value.html.len > 0 and !std.mem.eql(u8, value.html, "false");
        // An object that is there is true: `if (current_user) { ... }`.
        if (value == .object) return true;
    } else if (undeclared(ctx, trimmed)) {
        try state.notFound(alc, "name", trimmed);
    }
    return false;
}

fn isQuoted(text: []const u8) bool {
    return text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"';
}

/// A condition only reads names: `std.mem.eql(u8, m, "x")` or `len(x)`
/// used to be false without a word, so the page took the wrong branch.
fn refuseCall(operand: []const u8) EvalError!void {
    if (isQuoted(operand) or std.mem.indexOfScalar(u8, operand, '(') == null) return;
    const log = if (builtin.is_test) std.log.warn else std.log.err;
    log("[spider] template: a condition cannot call a function: {s} (compare with ==, or pass a bool)", .{operand});
    return error.UnsupportedCondition;
}

/// The text one side of a comparison stands for, allocated with `alc`: a
/// quoted literal without its quotes; a number, `true` or `false` as
/// written; anything else is a name, read from the context (`list.len`
/// included), and "" when there is no such name.
fn operandText(ctx: *const Context, operand: []const u8, alc: std.mem.Allocator, state: *RenderState) EvalError![]const u8 {
    if (isQuoted(operand)) return alc.dupe(u8, operand[1 .. operand.len - 1]);
    if (std.mem.eql(u8, operand, "true") or std.mem.eql(u8, operand, "false") or isNumber(operand))
        return alc.dupe(u8, operand);
    try refuseCall(operand);
    if (undeclared(ctx, operand)) try state.notFound(alc, "name", operand);
    return resolveLen(ctx, operand, alc);
}

fn isNumber(text: []const u8) bool {
    const digits = if (text.len > 1 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    return digits.len > 0 and std.ascii.isDigit(digits[0]);
}

fn evalCompare(ctx: *Context, left: []const u8, right: []const u8, alc: std.mem.Allocator, state: *RenderState) EvalError!bool {
    // `x == null`: no value, a null optional (declared, `.none`) or no such
    // name at all. It asks whether the name is there, so it is never a
    // diagnostic.
    if (std.mem.eql(u8, right, "null")) {
        try refuseCall(left);
        const v = resolveValue(ctx, left) orelse return true;
        return v == .none;
    }
    const l = try operandText(ctx, left, alc, state);
    defer alc.free(l);
    const r = try operandText(ctx, right, alc, state);
    defer alc.free(r);
    return std.mem.eql(u8, l, r);
}

const Cmp = enum { lt, lte, gt, gte };

fn evalNumCompare(ctx: *Context, left: []const u8, right: []const u8, cmp: Cmp, alc: std.mem.Allocator, state: *RenderState) EvalError!bool {
    const l = try operandText(ctx, left, alc, state);
    defer alc.free(l);
    const r = try operandText(ctx, right, alc, state);
    defer alc.free(r);

    const lv = std.fmt.parseInt(i64, l, 10) catch return false;
    const rv = std.fmt.parseInt(i64, r, 10) catch return false;

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
            if (v == .string or v == .html) {
                return try std.fmt.allocPrint(alc, "{d}", .{if (v == .string) v.string.len else v.html.len});
            }
        }
        return try alc.dupe(u8, "0");
    }
    if (resolveValue(ctx, expr)) |v| {
        return try valueToString(v, alc);
    }
    return try alc.dupe(u8, "");
}

/// Output of `{ expr }`: strings are HTML-escaped; `.html` (RawHtml, slots,
/// literal props) is trusted markup and goes out verbatim.
fn appendValue(alc: std.mem.Allocator, result: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .string => |s| try appendEscaped(alc, result, s),
        .html => |s| try result.appendSlice(alc, s),
        .boolean => |b| try result.appendSlice(alc, if (b) "true" else "false"),
        else => {},
    }
}

/// Escapes the five characters that matter in HTML text and in quoted
/// attribute values (single or double quotes).
pub fn appendEscaped(alc: std.mem.Allocator, result: *std.ArrayList(u8), s: []const u8) !void {
    return @import("escape.zig").append(alc, result, s);
}

fn valueToString(value: Value, alc: std.mem.Allocator) ![]const u8 {
    switch (value) {
        .string, .html => |s| return try alc.dupe(u8, s),
        .boolean => |b| return if (b) try alc.dupe(u8, "true") else try alc.dupe(u8, "false"),
        else => return try alc.dupe(u8, ""),
    }
}

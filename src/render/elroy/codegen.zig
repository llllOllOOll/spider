//! Internal: Elroy, the template compiler. At build time it turns a
//! template into a Zig function that writes the same HTML the interpreter
//! (render/renderer.zig, render/template.zig) renders, reading the view's
//! data by field instead of converting it and looking names up per
//! request. The rules of the template language live in elroy/runtime.zig,
//! resolved by type when the app compiles; this file emits the calls.
//!
//! Scopes follow the interpreter: a loop sees its item and `loop`; a
//! component sees its caller's names plus its props (it is expanded where
//! it is called); a layout sees the page's data plus the page's sections
//! (`slot`, `slot_<name>`), each rendered to a buffer first. Conditions are
//! translated the way `evalBool` reads them, step by step.
//!
//! A template that uses what Elroy does not compile (`current_user`, a
//! condition that calls a function, a component that includes itself, ...)
//! gets no function: it keeps the interpreter.

const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");
const props_decl = @import("../props_decl.zig");

const Node = ast.Node;
const trimWhitespace = parser_mod.trimWhitespace;

const Unsupported = error{Unsupported};
const Error = Unsupported || std.mem.Allocator.Error;

/// The app's templates by name (the embedded map's keys).
pub const Sources = std.StringHashMapUnmanaged([]const u8);

const Binding = struct {
    name: []const u8,
    kind: union(enum) {
        /// Ready: a Zig expression.
        expr: []const u8,
        /// `name="{ path }"`: the path in the caller's scope.
        prop_path: []const u8,
        /// Declared, left out by the call: the caller's value, else this.
        declared: []const u8,
    },
    /// Frames the caller sees (for `prop_path` and `declared`).
    caller_depth: usize = 0,
    ident: []const u8 = "",
    used: bool = false,
    /// What `ident` is set to, once used.
    def: []const u8 = "",
};

const Frame = struct {
    id: usize,
    /// A loop: the template's name for the item.
    capture: ?[]const u8 = null,
    capture_used: bool = false,
    loop_used: bool = false,
    /// A component or a layout: names it adds.
    bindings: std.ArrayList(Binding) = .empty,
    /// While a component's own slot content compiles, its `slot` binding is
    /// not there yet (the content sees the caller's `slot`).
    hide_slot: bool = false,
    /// The bottom frame of a component or layout function: every name not
    /// found above it is a field of the function's `scope` argument.
    fields: ?*std.ArrayList([]const u8) = null,
};

/// A component or layout compiled once as a function `__f<id>(w, alc,
/// scope)`, `scope` of type `__S<id>(types...)` with one field per name the
/// body reads from outside it. The type function makes the scope of two
/// calls with the same field types the same type, so Zig makes one copy of
/// the function for them (an anonymous struct literal would be a new type
/// at each call site).
const FnInfo = struct {
    id: usize,
    fields: []const []const u8,
};

/// What every template of an app shares: the component and layout
/// functions, generated once.
pub const Unit = struct {
    alc: std.mem.Allocator,
    sources: *const Sources,
    fns: std.StringHashMapUnmanaged(*FnInfo) = .{},
    failed: std.StringHashMapUnmanaged(void) = .{},
    compiling: std.StringHashMapUnmanaged(void) = .{},
    /// The functions' code, to put next to the templates' functions.
    code: std.ArrayList(u8) = .empty,
    next: usize = 0,
    /// A template's text (by address) -> the constant that holds it in the
    /// generated file (`const __t<n> = @embedFile(...)`), so the code writes
    /// slices of it instead of a second copy of the same markup.
    embeds: std.AutoHashMapUnmanaged(usize, []const u8) = .{},

    pub fn init(alc: std.mem.Allocator, sources: *const Sources) Unit {
        return .{ .alc = alc, .sources = sources };
    }

    /// Registers `text` (a template's whole source, as in `sources`) as
    /// held by the Zig expression `decl` (`@embedFile("...")` or a string
    /// literal).
    pub fn addSource(u: *Unit, text: []const u8, decl: []const u8) !void {
        const gop = try u.embeds.getOrPut(u.alc, @intFromPtr(text.ptr));
        if (gop.found_existing) return;
        gop.value_ptr.* = try std.fmt.allocPrint(u.alc, "__t{d}", .{u.embeds.count()});
        try u.code.print(u.alc, "const {s} = {s};\n", .{ gop.value_ptr.*, decl });
    }

    /// `text` as a slice of the constant holding `origin`, when it is in it.
    fn slice(u: *Unit, alc: std.mem.Allocator, origin: []const u8, text: []const u8) !?[]const u8 {
        const ident = u.embeds.get(@intFromPtr(origin.ptr)) orelse return null;
        const at = std.mem.indexOf(u8, origin, text) orelse return null;
        return try std.fmt.allocPrint(alc, "{s}[{d}..{d}]", .{ ident, at, at + text.len });
    }

    /// The function for `nodes` (memoized by `key`).
    fn function(u: *Unit, key: []const u8, list: []const Node, inline_components: *const Sources, origin: []const u8) Error!*FnInfo {
        if (u.fns.get(key)) |f| return f;
        if (u.failed.contains(key) or u.compiling.contains(key)) return error.Unsupported;
        try u.compiling.put(u.alc, key, {});
        defer _ = u.compiling.remove(key);

        var fields: std.ArrayList([]const u8) = .empty;
        var sub: Gen = .{ .alc = u.alc, .unit = u, .sources = u.sources, .inline_components = try inline_components.clone(u.alc), .origin = origin };
        const bottom = try u.alc.create(Frame);
        bottom.* = .{ .id = 0, .fields = &fields };
        try sub.frames.append(u.alc, bottom);
        var body: std.ArrayList(u8) = .empty;
        sub.nodes(&body, list) catch |err| {
            if (err == error.Unsupported) try u.failed.put(u.alc, key, {});
            return err;
        };

        const info = try u.alc.create(FnInfo);
        u.next += 1;
        info.* = .{ .id = u.next, .fields = fields.items };
        try u.code.print(u.alc, "fn __S{d}(", .{info.id});
        for (fields.items, 0..) |_, i| try u.code.print(u.alc, "{s}comptime T{d}: type", .{ if (i == 0) "" else ", ", i });
        try u.code.appendSlice(u.alc, ") type {\nreturn struct {");
        for (fields.items, 0..) |f, i| try u.code.print(u.alc, " {f}: T{d},", .{ std.zig.fmtId(f), i });
        try u.code.appendSlice(u.alc, " };\n}\n");
        try u.code.print(u.alc, "fn __f{d}(w: *std.Io.Writer, alc: std.mem.Allocator, scope: anytype) !void {{\n", .{info.id});
        if (fields.items.len == 0) try u.code.appendSlice(u.alc, "_ = scope;\n");
        if (!sub.alc_used) try u.code.appendSlice(u.alc, "_ = alc;\n");
        if (!sub.w_used) try u.code.appendSlice(u.alc, "_ = w;\n");
        try u.code.appendSlice(u.alc, body.items);
        try u.code.appendSlice(u.alc, "}\n");
        try u.fns.put(u.alc, key, info);
        return info;
    }
};

const Gen = struct {
    alc: std.mem.Allocator,
    unit: *Unit,
    sources: *const Sources,
    frames: std.ArrayList(*Frame) = .empty,
    /// The page's inline components.
    inline_components: Sources = .{},
    parsed: std.StringHashMapUnmanaged([]const Node) = .{},
    next_id: usize = 0,
    data_used: bool = false,
    alc_used: bool = false,
    /// The template being compiled (keys its inline components).
    page_name: []const u8 = "",
    /// The source the nodes being compiled come from (text is written as
    /// slices of it).
    origin: []const u8 = "",
    /// The writer the code being emitted writes to, and whether it did.
    w: []const u8 = "w",
    w_used: bool = false,

    fn newId(g: *Gen) usize {
        g.next_id += 1;
        return g.next_id;
    }

    // ── names ────────────────────────────────────────────────────────

    const Root = struct { handle: []const u8, path: []const u8 };

    fn root(g: *Gen, expr: []const u8) Error!Root {
        return g.rootIn(expr, g.frames.items.len);
    }

    /// Where `expr` starts, seen from the first `depth` frames.
    fn rootIn(g: *Gen, expr: []const u8, depth: usize) Error!Root {
        if (!isPath(expr)) return error.Unsupported;
        const end = std.mem.indexOfAny(u8, expr, ".[") orelse expr.len;
        const name = expr[0..end];
        const rest = if (end < expr.len and expr[end] == '.') expr[end + 1 ..] else expr[end..];
        if (std.mem.eql(u8, name, "current_user")) return error.Unsupported;
        var i = depth;
        while (i > 0) {
            i -= 1;
            const f = g.frames.items[i];
            if (f.capture) |cap| {
                if (std.mem.eql(u8, name, cap)) {
                    f.capture_used = true;
                    return .{ .handle = try std.fmt.allocPrint(g.alc, "__c{d}", .{f.id}), .path = rest };
                }
                if (std.mem.eql(u8, name, "loop")) {
                    f.loop_used = true;
                    return .{ .handle = try std.fmt.allocPrint(g.alc, "&__l{d}", .{f.id}), .path = rest };
                }
            }
            for (f.bindings.items) |*b| {
                if (!std.mem.eql(u8, b.name, name)) continue;
                if (f.hide_slot and std.mem.eql(u8, name, "slot")) continue;
                try g.use(b);
                return .{ .handle = b.ident, .path = rest };
            }
            if (f.fields) |fields| {
                const known = for (fields.items) |x| {
                    if (std.mem.eql(u8, x, name)) break true;
                } else false;
                if (!known) try fields.append(g.alc, name);
                return .{ .handle = try std.fmt.allocPrint(g.alc, "scope.{f}", .{std.zig.fmtId(name)}), .path = rest };
            }
        }
        g.data_used = true;
        return .{ .handle = "&data", .path = expr };
    }

    /// Defines a binding the first time a name reads it.
    fn use(g: *Gen, b: *Binding) Error!void {
        if (b.used) return;
        b.used = true;
        b.ident = try std.fmt.allocPrint(g.alc, "__b{d}", .{g.newId()});
        b.def = switch (b.kind) {
            .expr => |e| e,
            .prop_path => |p| blk: {
                if (std.mem.indexOfScalar(u8, p, '[') != null) return error.Unsupported;
                const r = try g.rootIn(p, b.caller_depth);
                break :blk try std.fmt.allocPrint(g.alc, "E.propExpr(E.lookup({s}, \"{f}\"))", .{ r.handle, std.zig.fmtString(r.path) });
            },
            .declared => |default| blk: {
                const r = try g.rootIn(b.name, b.caller_depth);
                break :blk try std.fmt.allocPrint(g.alc, "E.orDefault(E.lookup({s}, \"{f}\"), {s})", .{ r.handle, std.zig.fmtString(r.path), default });
            },
        };
    }

    // ── nodes ────────────────────────────────────────────────────────

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
                if (try g.unit.slice(g.alc, g.origin, t)) |ref|
                    try out.print(g.alc, "try {s}.writeAll({s});\n", .{ g.w, ref })
                else
                    try out.print(g.alc, "try {s}.writeAll(\"{f}\");\n", .{ g.w, std.zig.fmtString(t) });
            },
            .interpolation => |e| {
                const r = try g.root(trimWhitespace(e));
                g.w_used = true;
                try out.print(g.alc, "try E.interp({s}, {s}, \"{f}\");\n", .{ g.w, r.handle, std.zig.fmtString(r.path) });
            },
            .interpolation_with_default => |iwd| {
                const r = try g.root(trimWhitespace(iwd.expr));
                g.w_used = true;
                try out.print(g.alc, "try E.interpDefault({s}, {s}, \"{f}\", \"{f}\");\n", .{ g.w, r.handle, std.zig.fmtString(r.path), std.zig.fmtString(iwd.default) });
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
            .for_node => |f| try g.loop(out, f),
            .component => |c| try g.component(out, c),
            // The renderer writes nothing for it.
            .slot => {},
            .call => |c| {
                g.w_used = true;
                g.alc_used = true;
                var args: std.ArrayList(u8) = .empty;
                for (c.args, 0..) |a, i| try args.print(g.alc, "{s}\"{f}\"", .{ if (i == 0) "" else ", ", std.zig.fmtString(a) });
                try out.print(g.alc, "try E.call({s}, alc, \"{f}\", &[_][]const u8{{{s}}});\n", .{ g.w, std.zig.fmtString(c.name), args.items });
            },
        }
    }

    fn loop(g: *Gen, out: *std.ArrayList(u8), f: anytype) Error!void {
        const r = try g.root(trimWhitespace(f.iterable));
        const frame = try g.alc.create(Frame);
        frame.* = .{ .id = g.newId(), .capture = f.capture };
        try g.frames.append(g.alc, frame);
        var body: std.ArrayList(u8) = .empty;
        try g.nodes(&body, f.body);
        _ = g.frames.pop();
        const id = frame.id;
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
    }

    // ── components ───────────────────────────────────────────────────

    /// The component's source, as the renderer finds it: the name as
    /// written, else its snake_case form.
    fn findComponent(g: *Gen, name: []const u8) ?[]const u8 {
        if (g.inline_components.get(name)) |s| return s;
        if (g.sources.get(name)) |s| return s;
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        for (name, 0..) |ch, i| {
            if (n + 2 > buf.len) return null;
            if (ch >= 'A' and ch <= 'Z') {
                if (i > 0) {
                    buf[n] = '_';
                    n += 1;
                }
                buf[n] = ch + 32;
            } else buf[n] = ch;
            n += 1;
        }
        if (g.inline_components.get(buf[0..n])) |s| return s;
        return g.sources.get(buf[0..n]);
    }

    fn parse(g: *Gen, key: []const u8, src: []const u8) Error![]const Node {
        if (g.parsed.get(key)) |nodes_| return nodes_;
        var p = parser_mod.Parser.init(g.alc, src);
        p.log_failure = false;
        const parsed = p.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unsupported,
        };
        try g.parsed.put(g.alc, key, parsed.nodes);
        return parsed.nodes;
    }

    fn component(g: *Gen, out: *std.ArrayList(u8), c: anytype) Error!void {
        // Not found: the renderer writes nothing.
        const src = g.findComponent(c.name) orelse return;
        const body_nodes = try g.parse(c.name, src);
        const decl: ?props_decl.Decl = if (props_decl.headerLine(src) != null)
            (props_decl.parse(g.alc, src) catch return error.Unsupported)
        else
            null;
        // An inline component is the page's: its function is too.
        const is_inline = g.inline_components.get(c.name) != null;
        const key = try std.fmt.allocPrint(g.unit.alc, "c:{s}:{x}", .{ if (is_inline) g.page_name else "", std.hash.Wyhash.hash(0, src) });
        const info = try g.unit.function(key, body_nodes, &g.inline_components, if (is_inline) g.origin else src);

        const caller_depth = g.frames.items.len;
        const frame = try g.alc.create(Frame);
        frame.* = .{ .id = g.newId() };
        for (c.props) |prop| {
            var b: Binding = .{ .name = prop.name, .kind = undefined, .caller_depth = caller_depth };
            const declared_bool = if (decl) |d| (if (d.get(prop.name)) |dp| dp.kind == .bool and dp.accepts(prop.value) else false) else false;
            if (prop.is_expr) {
                b.kind = .{ .prop_path = trimWhitespace(prop.value) };
            } else if (declared_bool) {
                b.kind = .{ .expr = if (std.mem.eql(u8, prop.value, "true")) "true" else "false" };
            } else {
                b.kind = .{ .expr = try std.fmt.allocPrint(g.alc, "E.html(\"{f}\")", .{std.zig.fmtString(prop.value)}) };
            }
            try frame.bindings.append(g.alc, b);
        }
        if (decl) |d| for (d.props) |dp| {
            const given = for (c.props) |prop| {
                if (std.mem.eql(u8, prop.name, dp.name)) break true;
            } else false;
            if (given) continue;
            const default: []const u8 = if (dp.default) |def|
                (if (dp.kind == .bool)
                    (if (std.mem.eql(u8, def, "true")) "true" else "false")
                else
                    try std.fmt.allocPrint(g.alc, "E.html(\"{f}\")", .{std.zig.fmtString(def)}))
            else
                "E.none";
            try frame.bindings.append(g.alc, .{ .name = dp.name, .kind = .{ .declared = default }, .caller_depth = caller_depth });
        };
        const slot_index: ?usize = if (c.slot_content != null) blk: {
            try frame.bindings.append(g.alc, .{ .name = "slot", .kind = .{ .expr = try std.fmt.allocPrint(g.alc, "E.html(__s{d}.written())", .{frame.id}) } });
            break :blk frame.bindings.items.len - 1;
        } else null;

        try g.frames.append(g.alc, frame);
        // The names the function reads, as the call sees them.
        var args: std.ArrayList(u8) = .empty;
        for (info.fields, 0..) |f, i| {
            const r = try g.root(f);
            if (r.path.len == 0)
                try args.print(g.alc, "const __v{d}_{d} = {s};\n", .{ frame.id, i, r.handle })
            else
                try args.print(g.alc, "const __v{d}_{d} = E.bind(E.lookup({s}, \"{f}\"));\n", .{ frame.id, i, r.handle, std.zig.fmtString(r.path) });
        }
        // The slot content, rendered first (in the component's scope, with
        // the caller's `slot`), only when the component reads it.
        var slot_code: std.ArrayList(u8) = .empty;
        if (slot_index) |si| if (frame.bindings.items[si].used) {
            const slot_nodes = try g.parse(c.slot_content.?, c.slot_content.?);
            frame.hide_slot = true;
            try g.buffered(&slot_code, try std.fmt.allocPrint(g.alc, "__s{d}", .{frame.id}), slot_nodes);
            frame.hide_slot = false;
        };
        _ = g.frames.pop();

        try out.appendSlice(g.alc, "{\n");
        try out.appendSlice(g.alc, slot_code.items);
        for (frame.bindings.items) |b| if (b.used) try out.print(g.alc, "const {s} = {s};\n", .{ b.ident, b.def });
        try out.appendSlice(g.alc, args.items);
        try g.callFunction(out, info, frame.id);
        try out.appendSlice(g.alc, "}\n");
    }

    /// `try __f<id>(w, alc, __S<id>(@TypeOf(__v...), ...){ .name = __v..., ... });`
    fn callFunction(g: *Gen, out: *std.ArrayList(u8), info: *const FnInfo, vid: usize) Error!void {
        g.w_used = true;
        g.alc_used = true;
        try out.print(g.alc, "try __f{d}({s}, alc, __S{d}(", .{ info.id, g.w, info.id });
        for (info.fields, 0..) |_, i| try out.print(g.alc, "{s}@TypeOf(__v{d}_{d})", .{ if (i == 0) "" else ", ", vid, i });
        try out.appendSlice(g.alc, "){");
        for (info.fields, 0..) |f, i| try out.print(g.alc, " .{f} = __v{d}_{d},", .{ std.zig.fmtId(f), vid, i });
        try out.appendSlice(g.alc, " });\n");
    }

    /// Emits `list` rendered into a buffer `name` (std.Io.Writer.Allocating
    /// on the render's allocator).
    fn buffered(g: *Gen, out: *std.ArrayList(u8), name: []const u8, list: []const Node) Error!void {
        const saved_w = g.w;
        const saved_used = g.w_used;
        g.w = try std.fmt.allocPrint(g.alc, "{s}w", .{name});
        g.w_used = false;
        var code: std.ArrayList(u8) = .empty;
        try g.nodes(&code, list);
        g.alc_used = true;
        try out.print(g.alc, "var {s}: std.Io.Writer.Allocating = .init(alc);\n", .{name});
        if (g.w_used) {
            try out.print(g.alc, "const {s} = &{s}.writer;\n", .{ g.w, name });
            try out.appendSlice(g.alc, code.items);
        } else try out.print(g.alc, "_ = &{s};\n", .{name});
        g.w = saved_w;
        g.w_used = saved_used;
    }

    // ── layouts ──────────────────────────────────────────────────────

    /// `extends "layout"`: the page's sections, each to a buffer, then the
    /// layout with them as `slot` and `slot_<name>`.
    fn layout(g: *Gen, out: *std.ArrayList(u8), layout_src: []const u8, layout_name: []const u8, page: []const Node) Error!void {
        // Sections in order; a name given twice keeps the last one.
        var keys: std.ArrayList([]const u8) = .empty;
        var sections: std.ArrayList(std.ArrayList(Node)) = .empty;
        var cur_key: []const u8 = "slot";
        var cur: std.ArrayList(Node) = .empty;
        for (page) |n| {
            if (n == .interpolation and std.mem.startsWith(u8, n.interpolation, "slot_")) {
                try keepSection(g.alc, &keys, &sections, cur_key, cur);
                cur_key = n.interpolation;
                cur = .empty;
                continue;
            }
            try cur.append(g.alc, n);
        }
        try keepSection(g.alc, &keys, &sections, cur_key, cur);

        const frame = try g.alc.create(Frame);
        frame.* = .{ .id = g.newId() };
        for (keys.items, 0..) |k, i| {
            try frame.bindings.append(g.alc, .{ .name = k, .kind = .{ .expr = try std.fmt.allocPrint(g.alc, "E.html(__s{d}_{d}.written())", .{ frame.id, i }) } });
        }
        const layout_nodes = try g.parse(layout_name, layout_src);
        const key = try std.fmt.allocPrint(g.unit.alc, "l:{x}", .{std.hash.Wyhash.hash(0, layout_src)});
        const info = try g.unit.function(key, layout_nodes, &g.inline_components, layout_src);
        try g.frames.append(g.alc, frame);
        var args: std.ArrayList(u8) = .empty;
        for (info.fields, 0..) |f, i| {
            const r = try g.root(f);
            if (r.path.len == 0)
                try args.print(g.alc, "const __v{d}_{d} = {s};\n", .{ frame.id, i, r.handle })
            else
                try args.print(g.alc, "const __v{d}_{d} = E.bind(E.lookup({s}, \"{f}\"));\n", .{ frame.id, i, r.handle, std.zig.fmtString(r.path) });
        }
        _ = g.frames.pop();

        // The sections the layout reads, rendered in the page's scope.
        for (frame.bindings.items, 0..) |b, i| {
            if (!b.used) continue;
            try g.buffered(out, try std.fmt.allocPrint(g.alc, "__s{d}_{d}", .{ frame.id, i }), sections.items[i].items);
        }
        for (frame.bindings.items) |b| if (b.used) try out.print(g.alc, "const {s} = {s};\n", .{ b.ident, b.def });
        try out.appendSlice(g.alc, args.items);
        try g.callFunction(out, info, frame.id);
    }

    fn keepSection(alc: std.mem.Allocator, keys: *std.ArrayList([]const u8), sections: *std.ArrayList(std.ArrayList(Node)), key: []const u8, list: std.ArrayList(Node)) !void {
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                sections.items[i] = list;
                return;
            }
        }
        try keys.append(alc, key);
        try sections.append(alc, list);
    }

    // ── conditions ───────────────────────────────────────────────────

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
            if (prefix.len == 0 or !isPath(prefix)) return "E.lit(\"0\")";
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

/// Appends to `out` a function `pub fn @"<name>"(w, data, alc) !void`
/// that renders template `src` (the app's other templates, in `unit`, are
/// its components and layouts; their functions go to `unit.code`), and
/// returns true; returns false (and appends nothing) when the template
/// uses what Elroy does not compile.
pub fn generate(unit: *Unit, out: *std.ArrayList(u8), name: []const u8, src: []const u8) std.mem.Allocator.Error!bool {
    const alc = unit.alc;
    const sources = unit.sources;
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
    var g: Gen = .{ .alc = a, .unit = unit, .sources = sources, .page_name = name, .origin = src };

    // Inline components (what parsed_cache/collectInline do): a root-level
    // `<Name>...</Name>` with content, under a name nothing has, defines
    // one and is not rendered in place.
    var page: std.ArrayList(Node) = .empty;
    for (parsed.nodes) |n| {
        if (n == .component and !n.component.self_closing and n.component.slot_content != null) {
            const cname = n.component.name;
            if (!g.inline_components.contains(cname) and sources.get(cname) == null) {
                try g.inline_components.put(a, cname, n.component.slot_content.?);
                continue;
            }
        }
        try page.append(a, n);
    }

    var body: std.ArrayList(u8) = .empty;
    const result = if (parsed.layout) |layout_name|
        (if (g.inline_components.get(layout_name) orelse sources.get(layout_name)) |layout_src|
            g.layout(&body, layout_src, layout_name, page.items)
        else
            g.nodes(&body, page.items))
    else
        g.nodes(&body, page.items);
    result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return false,
    };
    try out.print(alc, "pub fn {f}(w: *std.Io.Writer, data: anytype, alc: std.mem.Allocator) !void {{\n", .{std.zig.fmtId(name)});
    if (!g.data_used) try out.appendSlice(alc, "_ = data;\n");
    if (!g.alc_used) try out.appendSlice(alc, "_ = alc;\n");
    if (!g.w_used) try out.appendSlice(alc, "_ = w;\n");
    try out.appendSlice(alc, body.items);
    try out.appendSlice(alc, "}\n");
    return true;
}

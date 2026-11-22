//! Internal (build tool): what each template reads from the data of a view,
//! for `Ctx.view`, which compares it with the data's type at compile
//! time.
//!
//! `generate-templates` parses every template and writes, next to the
//! embedded sources, one list per template of the paths it reads:
//! `title`, `book.title`, `books[].title` (a field of each item of the list
//! `books`, read through a `for (books) |b|` as `b.title`). What a component
//! reads from its caller's names counts as the caller's, minus the props the
//! call gives and the props the component declares; what it reads through a
//! prop given a data path (`book="{ b }"`) counts as that path; a layout
//! counts for the page that extends it. `analyzeFragment` does the same for
//! one component rendered alone (`c.viewFragment`). Names every template has (`slot`, `loop`,
//! `current_user`) and helper calls are left out.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const props_decl = @import("props_decl.zig");
const Node = ast.Node;

// internal: how a template reads a path.
pub const Kind = enum {
    /// Printed: `{ x }`, `{ x ?? "d" }`.
    text,
    /// Read in a condition or passed on as is: only needs to be there.
    cond,
    /// Looped over: `for (x) |item|`.
    iter,
    /// Passed as a prop the component declares as int / bool / string.
    prop_int,
    prop_bool,
    prop_string,
    /// A declared prop of no type, read from the caller because the call
    /// leaves it out: only needs to be there.
    prop_any,
    /// Not a data path: a component call that does not fit the component's
    /// `-- props:` line (a prop it does not declare, a literal of the wrong
    /// type). `path` holds the message; `c.view` fails with it.
    prop_problem,
};

// internal: one path a template reads.
pub const Use = struct {
    path: []const u8,
    /// 1-based line in the template the use was written in; for what a
    /// component reads, the line of the call (0: unknown, or a layout's).
    line: usize,
    kind: Kind,
    /// May be missing: `{ x ?? "d" }`, `x == null`.
    optional: bool,
    /// The components it was read through, outermost first: "Card>Badge".
    via: []const u8,
};

/// A template: the name `c.view` knows it by (the generated field name), its
/// source and its file.
pub const Source = struct {
    name: []const u8,
    text: []const u8,
    /// Where the template is, as error messages name it
    /// (`views/home.html`); "" when unknown.
    file: []const u8 = "",
};

// internal: works out what each template reads (generate-templates).
pub const Analyzer = struct {
    alc: std.mem.Allocator,
    by_name: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Source name -> what it reads from outside (memoized: each template,
    /// component or layout is summarized once).
    summaries: std.StringHashMapUnmanaged([]const Use) = .{},
    /// Names being summarized (a component that includes itself).
    in_progress: std.StringHashMapUnmanaged(void) = .{},

    // internal: an analyzer over every template of the app.
    pub fn init(alc: std.mem.Allocator, sources: []const Source) !Analyzer {
        var a: Analyzer = .{ .alc = alc };
        for (sources) |s| try a.by_name.put(alc, s.name, s.text);
        return a;
    }

    /// What a template (source `text`) reads from a view's data: its own
    /// names, and those its components and its layout read from it.
    pub fn analyze(a: *Analyzer, text: []const u8) ![]const Use {
        var out: Collect = .{ .alc = a.alc };
        for (try a.summarize("", text)) |u| try out.add(u);
        if (layoutOf(text)) |layout| {
            if (a.find(layout)) |found| {
                for (try a.summarize(found.name, found.text)) |u| {
                    if (isSlotName(rootOf(u.path))) continue;
                    try out.add(.{ .path = u.path, .line = 0, .kind = u.kind, .optional = u.optional, .via = try a.chain(layout, u.via) });
                }
            }
        }
        return out.list.toOwnedSlice(a.alc);
    }

    /// What the template `text` reads from outside itself, with lines in
    /// its own text. `name` memoizes it ("" = not memoized).
    fn summarize(a: *Analyzer, name: []const u8, text: []const u8) anyerror![]const Use {
        return a.summarizeWith(name, text, null);
    }

    /// `summarize` for a body that sees the inline components `inherited`
    /// (those of the file it is defined in), besides its own.
    fn summarizeWith(a: *Analyzer, name: []const u8, text: []const u8, inherited: ?*const Locals) anyerror![]const Use {
        if (name.len > 0) {
            if (a.summaries.get(name)) |s| return s;
            if (a.in_progress.contains(name)) return &.{};
            try a.in_progress.put(a.alc, name, {});
        }
        defer if (name.len > 0) {
            _ = a.in_progress.remove(name);
        };
        const locals = try a.alc.create(Locals);
        locals.* = .{};
        if (inherited) |inh| {
            var it = inh.iterator();
            while (it.next()) |e| try locals.put(a.alc, e.key_ptr.*, e.value_ptr.*);
        }
        var w: Walk = .{ .a = a, .text = text, .out = .{ .alc = a.alc }, .locals = locals };
        if (try parse(a.alc, text)) |nodes| {
            // What parsed_cache does: a root-level `<Name>...</Name>` with
            // content, under a name no file has, defines an inline component
            // (read where it is used, not here).
            var kept: std.ArrayList(Node) = .empty;
            for (nodes) |node| {
                if (node == .component and !node.component.self_closing and node.component.slot_content != null) {
                    const cname = node.component.name;
                    if (!locals.contains(cname) and a.find(cname) == null) {
                        try locals.put(a.alc, cname, node.component.slot_content.?);
                        continue;
                    }
                }
                try kept.append(a.alc, node);
            }
            var scope: Scope = .{};
            try w.nodes(kept.items, &scope);
        }
        const result = try w.out.list.toOwnedSlice(a.alc);
        if (name.len > 0) try a.summaries.put(a.alc, name, result);
        return result;
    }

    /// What `c.viewFragment(template, comp_name, data)` reads from `data`:
    /// the component rendered as if called `<comp_name />` from a page whose
    /// data is `data` (the template's inline components first, then the
    /// files). Null when there is no such component.
    pub fn analyzeFragment(a: *Analyzer, text: []const u8, comp_name: []const u8) !?[]const Use {
        const locals = try a.inlineComponents(text);
        if (!locals.contains(comp_name) and a.find(comp_name) == null) return null;
        var w: Walk = .{ .a = a, .text = "", .out = .{ .alc = a.alc }, .locals = locals };
        const scope: Scope = .{};
        try w.component(.{ .name = comp_name, .props = @as([]const ast.Prop, &.{}), .slot_content = @as(?[]const u8, null) }, &scope);
        return try w.out.list.toOwnedSlice(a.alc);
    }

    /// The inline components `text` defines (what `summarizeWith` sets
    /// aside): a root-level `<Name>...</Name>` with content, under a name
    /// no file has.
    pub fn inlineComponents(a: *Analyzer, text: []const u8) !*Locals {
        const locals = try a.alc.create(Locals);
        locals.* = .{};
        const nodes = (try parse(a.alc, text)) orelse return locals;
        for (nodes) |node| {
            if (node == .component and !node.component.self_closing and node.component.slot_content != null) {
                const cname = node.component.name;
                if (!locals.contains(cname) and a.find(cname) == null)
                    try locals.put(a.alc, cname, node.component.slot_content.?);
            }
        }
        return locals;
    }

    const Found = struct { name: []const u8, text: []const u8, local: bool = false };

    /// The component or layout called `name` (as written, or its snake_case
    /// form), or null.
    fn find(a: *Analyzer, name: []const u8) ?Found {
        if (a.by_name.getEntry(name)) |e| return .{ .name = e.key_ptr.*, .text = e.value_ptr.* };
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        for (name, 0..) |c, i| {
            if (n + 2 > buf.len) return null;
            if (std.ascii.isUpper(c)) {
                if (i > 0) {
                    buf[n] = '_';
                    n += 1;
                }
                buf[n] = std.ascii.toLower(c);
            } else buf[n] = c;
            n += 1;
        }
        if (a.by_name.getEntry(buf[0..n])) |e| return .{ .name = e.key_ptr.*, .text = e.value_ptr.* };
        return null;
    }

    fn chain(a: *Analyzer, outer: []const u8, inner: []const u8) ![]const u8 {
        return if (inner.len == 0) outer else std.fmt.allocPrint(a.alc, "{s}>{s}", .{ outer, inner });
    }
};

/// The kind a value given to a typed prop must have; null for an untyped one.
fn propKind(p: props_decl.Prop) ?Kind {
    return switch (p.kind) {
        .int => .prop_int,
        .bool => .prop_bool,
        .string => .prop_string,
        .any => null,
    };
}

/// A file's inline components: name -> body.
pub const Locals = std.StringHashMapUnmanaged([]const u8);

/// Uses without repeats.
const Collect = struct {
    alc: std.mem.Allocator,
    list: std.ArrayList(Use) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .{},

    fn add(c: *Collect, u: Use) !void {
        const key = try std.fmt.allocPrint(c.alc, "{s}|{s}|{}|{s}", .{ u.path, @tagName(u.kind), u.optional, u.via });
        if ((try c.seen.getOrPut(c.alc, key)).found_existing) return;
        try c.list.append(c.alc, u);
    }
};

fn rootOf(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfAny(u8, path, ".[") orelse path.len];
}

fn isSlotName(name: []const u8) bool {
    return std.mem.eql(u8, name, "slot") or std.mem.startsWith(u8, name, "slot_");
}

/// Loop items in sight: name -> the data path of the list's item.
const Scope = struct {
    bound: std.StringHashMapUnmanaged([]const u8) = .{},
    parent: ?*const Scope = null,

    fn get(s: *const Scope, name: []const u8) ?[]const u8 {
        var cur: ?*const Scope = s;
        while (cur) |c| : (cur = c.parent) {
            if (c.bound.get(name)) |v| return v;
        }
        return null;
    }
};

/// One template's own walk: its names, with loop items turned into the
/// list's path, and what its components read, through their summaries.
const Walk = struct {
    a: *Analyzer,
    text: []const u8,
    out: Collect,
    cursor: usize = 0,
    locals: *const Locals,

    fn nodes(w: *Walk, list: []const Node, scope: *const Scope) anyerror!void {
        for (list) |node| switch (node) {
            .interpolation => |e| _ = try w.expr(e, .text, false, scope),
            .interpolation_with_default => |iwd| _ = try w.expr(iwd.expr, .text, true, scope),
            .if_node => |n| {
                try w.condition(n.condition, scope);
                try w.nodes(n.then_body, scope);
                if (n.else_body) |eb| try w.nodes(eb, scope);
            },
            .for_node => |n| {
                var inner: Scope = .{ .parent = scope };
                if (try w.expr(n.iterable, .iter, false, scope)) |p| {
                    try inner.bound.put(w.a.alc, n.capture, try std.fmt.allocPrint(w.a.alc, "{s}[]", .{p}));
                } else {
                    // A list that is not the data's (a prop, a slot): its
                    // items are not either.
                    try inner.bound.put(w.a.alc, n.capture, "");
                }
                try w.nodes(n.body, &inner);
            },
            .component => |c| try w.component(c, scope),
            else => {},
        };
    }

    fn component(w: *Walk, c: anytype, scope: *const Scope) !void {
        // Where the call is written: what the component reads is reported
        // there (its own lines are in another file).
        const call_line = w.lineOf(try std.fmt.allocPrint(w.a.alc, "<{s}", .{c.name}));
        const found: ?Analyzer.Found = if (w.locals.get(c.name)) |body|
            .{ .name = c.name, .text = body, .local = true }
        else
            w.a.find(c.name);
        const decl: ?props_decl.Decl = if (found) |f| (props_decl.parse(w.a.alc, f.text) catch null) else null;
        if (decl) |d| for (c.props) |prop| {
            // What the renderer reports at run time (renderer.zig,
            // applyPropsDecl), here so that c.view fails the build.
            const message = if (d.get(prop.name)) |pd|
                (if (!prop.is_expr and !pd.accepts(prop.value))
                    try std.fmt.allocPrint(w.a.alc, "prop `{s}` of <{s}> is {s}; \"{s}\" is not", .{ prop.name, c.name, @tagName(pd.kind), prop.value })
                else
                    null)
            else
                try std.fmt.allocPrint(w.a.alc, "<{s}> has no prop `{s}` (it declares: {s})", .{ c.name, prop.name, try d.names(w.a.alc) });
            if (message) |m| try w.out.add(.{ .path = m, .line = w.lineOf(prop.name), .kind = .prop_problem, .optional = false, .via = "" });
        };
        // The data path each expression prop is given (`book="{ b }"` in a
        // `for (books) |b|`: `books[]`), so what the component reads
        // through the prop is checked against the caller's data.
        var given_paths: std.StringHashMapUnmanaged([]const u8) = .{};
        for (c.props) |prop| {
            if (!prop.is_expr) continue;
            const kind: Kind = if (decl) |d| (if (d.get(prop.name)) |pd| propKind(pd) orelse .cond else .cond) else .cond;
            if (try w.expr(prop.value, kind, false, scope)) |p| try given_paths.put(w.a.alc, prop.name, p);
        }
        if (c.slot_content) |sc| {
            if (try parse(w.a.alc, sc)) |slot_nodes| try w.nodes(slot_nodes, scope);
        }
        const f = found orelse {
            // At run time it renders nothing (renderer.zig): a typo in a
            // tag name, or a component file that is not there.
            const m = try std.fmt.allocPrint(w.a.alc, "<{s}> is not a component: no template file {s}.html (or {s}.html) and no <{s}>...</{s}> defined in this file", .{ c.name, c.name, try snakeCase(w.a.alc, c.name), c.name, c.name });
            try w.out.add(.{ .path = m, .line = call_line, .kind = .prop_problem, .optional = false, .via = "" });
            return;
        };
        const summary = if (f.local)
            // Memoized per definition: the same name may be defined inline
            // in other files.
            try w.a.summarizeWith(try std.fmt.allocPrint(w.a.alc, "inline:{x}", .{@intFromPtr(f.text.ptr)}), f.text, w.locals)
        else
            try w.a.summarize(f.name, f.text);
        for (summary) |u| {
            if (u.kind == .prop_problem) {
                // A call inside the component: its message, not a path.
                try w.out.add(.{ .path = u.path, .line = call_line, .kind = u.kind, .optional = false, .via = try w.a.chain(c.name, u.via) });
                continue;
            }
            const root = rootOf(u.path);
            if (isSlotName(root)) continue;
            const given = for (c.props) |prop| {
                if (std.mem.eql(u8, prop.name, root)) break true;
            } else false;
            if (given) {
                // Read through a prop given a data path: that path, read
                // the way the component reads it. A literal prop, or one
                // given something else, is not the data's.
                const base = given_paths.get(root) orelse continue;
                const through = try std.fmt.allocPrint(w.a.alc, "{s}{s}", .{ base, u.path[root.len..] });
                try w.out.add(.{ .path = through, .line = call_line, .kind = u.kind, .optional = u.optional, .via = try w.a.chain(c.name, u.via) });
                continue;
            }
            var kind = u.kind;
            var optional = u.optional;
            if (decl) |d| {
                if (d.get(root)) |pd| {
                    // A declared prop the call leaves out is the caller's
                    // name when the caller has it; without it, the default
                    // (or no value) is used, so it may be missing. A
                    // required one with no default may not.
                    if (!(pd.required and pd.default == null)) optional = true;
                    if (std.mem.eql(u8, u.path, root)) kind = propKind(pd) orelse .prop_any;
                } else {
                    // Not a prop: a component that declares its props does
                    // not see it (renderer.zig, pass_through). Read without
                    // a fallback, it always renders empty.
                    if (!u.optional) {
                        const m = try std.fmt.allocPrint(w.a.alc, "<{s}> reads `{s}`, which is not one of its props (it declares: {s})", .{ c.name, root, try d.names(w.a.alc) });
                        try w.out.add(.{ .path = m, .line = call_line, .kind = .prop_problem, .optional = false, .via = "" });
                    }
                    continue;
                }
            }
            const mapped = (try w.map(u.path, scope)) orelse continue;
            try w.out.add(.{ .path = mapped, .line = call_line, .kind = kind, .optional = optional, .via = try w.a.chain(c.name, u.via) });
        }
    }

    fn condition(w: *Walk, cond: []const u8, scope: *const Scope) !void {
        var rest = std.mem.trim(u8, cond, " ");
        const seps = [_][]const u8{ " or ", " and ", " != ", " == ", " <= ", " >= ", " < ", " > " };
        for (seps) |sep| {
            if (std.mem.indexOf(u8, rest, sep)) |i| {
                const left = rest[0..i];
                const right = rest[i + sep.len ..];
                const null_check = (std.mem.eql(u8, sep, " == ") or std.mem.eql(u8, sep, " != ")) and
                    std.mem.eql(u8, std.mem.trim(u8, right, " "), "null");
                if (null_check) {
                    _ = try w.expr(left, .cond, true, scope);
                    return;
                }
                try w.condition(left, scope);
                try w.condition(right, scope);
                return;
            }
        }
        while (rest.len > 0 and rest[0] == '!') rest = std.mem.trim(u8, rest[1..], " ");
        _ = try w.expr(rest, .cond, false, scope);
    }

    /// `path` with a loop item at its root replaced by the list's item path;
    /// null when it is not the data's (the item of a list that is not).
    fn map(w: *Walk, path: []const u8, scope: *const Scope) !?[]const u8 {
        const root = rootOf(path);
        const bound = scope.get(root) orelse return path;
        if (bound.len == 0) return null;
        return try std.fmt.allocPrint(w.a.alc, "{s}{s}", .{ bound, path[root.len..] });
    }

    /// Records the data path `e` reads, if any, and returns it.
    fn expr(w: *Walk, raw: []const u8, kind: Kind, optional: bool, scope: *const Scope) !?[]const u8 {
        const e = std.mem.trim(u8, raw, " \t\r\n");
        if (e.len == 0 or e[0] == '"' or std.ascii.isDigit(e[0]) or e[0] == '-') return null;
        if (std.mem.eql(u8, e, "true") or std.mem.eql(u8, e, "false") or std.mem.eql(u8, e, "null")) return null;
        for (e) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']')) return null;
        const root = rootOf(e);
        if (std.mem.eql(u8, root, "loop") or std.mem.eql(u8, root, "current_user")) return null;
        const path = (try w.map(e, scope)) orelse return null;
        try w.out.add(.{ .path = path, .line = w.lineOf(e), .kind = kind, .optional = optional, .via = "" });
        return path;
    }

    /// The line of `text` in the template, searched forward (uses come in
    /// order), then from the start; 0 when not found.
    fn lineOf(w: *Walk, needle: []const u8) usize {
        const at = std.mem.indexOfPos(u8, w.text, w.cursor, needle) orelse
            std.mem.indexOf(u8, w.text, needle) orelse return 0;
        w.cursor = at;
        return 1 + std.mem.count(u8, w.text[0..at], "\n");
    }
};

/// `BookCard` as `book_card`: the other file name a call finds.
fn snakeCase(alc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) try out.append(alc, '_');
            try out.append(alc, std.ascii.toLower(c));
        } else try out.append(alc, c);
    }
    return out.toOwnedSlice(alc);
}

fn parse(alc: std.mem.Allocator, text: []const u8) !?[]const Node {
    var p = parser_mod.Parser.init(alc, text);
    p.log_failure = false;
    const parsed = p.parse() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null, // a syntax error: reported elsewhere
    };
    return parsed.nodes;
}

fn layoutOf(text: []const u8) ?[]const u8 {
    const start = props_decl.bodyStart(text);
    const rest = std.mem.trimStart(u8, text[start..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, "extends \"")) return null;
    const name_start = "extends \"".len;
    const end = std.mem.indexOfScalarPos(u8, rest, name_start, '"') orelse return null;
    return rest[name_start..end];
}

/// Writes the manifest as Zig: one `pub const <name> = .{ .{ path, line,
/// .kind, optional, via }, ... };` per template, inside a struct the
/// generated file names `spider_manifest`.
pub fn writeZig(out: *std.ArrayList(u8), alc: std.mem.Allocator, name: []const u8, uses: []const Use) !void {
    if (uses.len == 0) return out.print(alc, "        pub const {f} = .{{}};\n", .{std.zig.fmtId(name)});
    try out.print(alc, "        pub const {f} = .{{\n", .{std.zig.fmtId(name)});
    for (uses) |u| {
        try out.print(alc, "            .{{ \"{f}\", {d}, .{s}, {}, \"{s}\" }},\n", .{ std.zig.fmtString(u.path), u.line, @tagName(u.kind), u.optional, u.via });
    }
    try out.appendSlice(alc, "        };\n");
}

const t = std.testing;

fn analyzeOne(arena: std.mem.Allocator, sources: []const Source, name: []const u8) ![]const Use {
    var a = try Analyzer.init(arena, sources);
    for (sources) |s| if (std.mem.eql(u8, s.name, name)) return a.analyze(s.text);
    return error.NotFound;
}

fn has(uses: []const Use, path: []const u8, kind: Kind) bool {
    for (uses) |u| if (std.mem.eql(u8, u.path, path) and u.kind == kind) return true;
    return false;
}

test "manifest: names, loops, conditions, defaults and null checks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const uses = try analyzeOne(arena.allocator(), &.{.{ .name = "page", .text =
        \\<h1>{ title }</h1>{ subtitle ?? "-" }
        \\for (books) |b| { <li>{ b.title } { loop.index }</li> }
        \\if (user.admin and count > 3) { x } if (note == null) { y }
    }}, "page");
    try t.expect(has(uses, "title", .text));
    try t.expect(has(uses, "subtitle", .text));
    try t.expect(has(uses, "books", .iter));
    try t.expect(has(uses, "books[].title", .text));
    try t.expect(has(uses, "user.admin", .cond));
    try t.expect(has(uses, "count", .cond));
    try t.expect(has(uses, "note", .cond));
    for (uses) |u| {
        if (std.mem.eql(u8, u.path, "subtitle") or std.mem.eql(u8, u.path, "note")) try t.expect(u.optional);
        try t.expect(!std.mem.startsWith(u8, u.path, "loop"));
    }
    for (uses) |u| if (std.mem.eql(u8, u.path, "title")) try t.expectEqual(@as(usize, 1), u.line);
}

test "manifest: components read the caller's names, minus props; layouts count; typed props" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "page", .text = "extends \"layout\"\nfor (books) |b| { <BookCard title=\"{ b.title }\" year=\"{ b.year }\" /> }" },
        .{ .name = "book_card", .text = "-- props: title!, year: int\n<b>{ title } { year } { shelf_name }</b>" },
        .{ .name = "layout", .text = "<title>{ page_title }</title>{ slot }" },
    };
    const uses = try analyzeOne(arena.allocator(), &sources, "page");
    try t.expect(has(uses, "books[].year", .prop_int));
    try t.expect(has(uses, "books[].title", .cond));
    try t.expect(has(uses, "page_title", .text)); // read by the layout
    try t.expect(!has(uses, "title", .text) and !has(uses, "year", .text)); // given by the call
    // The card declares its props: it does not see the caller's
    // `shelf_name`, so reading it is a problem, not a name of the data.
    try t.expect(!has(uses, "shelf_name", .text));
    try t.expect(has(uses, "<BookCard> reads `shelf_name`, which is not one of its props (it declares: title, year)", .prop_problem));
}

test "manifest: an inline component is read where it is used, not where it is defined" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const uses = try analyzeOne(arena.allocator(), &.{.{ .name = "page", .text =
        \\for (homes) |u| { <Card /> }
        \\<Badge label="x" />
        \\<Card>
        \\  <div data-id="{ u.id }">{ u.name } <Badge label="{ u.tag }" /></div>
        \\</Card>
        \\<Badge>
        \\  <i>{ label } { theme }</i>
        \\</Badge>
    }}, "page");
    try t.expect(has(uses, "homes", .iter));
    try t.expect(has(uses, "homes[].id", .text)); // `u` is the caller's loop item
    try t.expect(has(uses, "homes[].name", .text));
    try t.expect(has(uses, "theme", .text)); // Badge, inside Card, reads the page's
    for (uses) |u| {
        try t.expect(!std.mem.startsWith(u8, u.path, "u.") and !std.mem.eql(u8, u.path, "label"));
    }
}

test "manifest: a declared prop the call leaves out may come from the caller: optional, typed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "page", .text = "<Nav />" },
        .{ .name = "nav", .text = "-- props: show_tickets: bool = false, title!, label\nif (show_tickets) { x }{ title }{ label }" },
    };
    const uses = try analyzeOne(arena.allocator(), &sources, "page");
    for (uses) |u| {
        if (std.mem.eql(u8, u.path, "show_tickets")) try t.expect(u.optional and u.kind == .prop_bool);
        if (std.mem.eql(u8, u.path, "label")) try t.expect(u.optional);
        if (std.mem.eql(u8, u.path, "title")) try t.expect(!u.optional); // required, no default
    }
    try t.expect(has(uses, "show_tickets", .prop_bool) and has(uses, "title", .prop_any) and has(uses, "label", .prop_any));
}

test "manifest: a call that does not fit the component's props is a problem for c.view" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "page", .text = "<h1>Shelf</h1>\n<Hello nmae=\"{ name }\" />\n<Card year=\"1969x\" title=\"ok\" />\n<List />" },
        .{ .name = "Hello", .text = "-- props: name!\n<h1>Hello, { name }!</h1>" },
        .{ .name = "Card", .text = "-- props: title!, year: int\n<b>{ title } { year }</b>" },
        .{ .name = "List", .text = "<Card titel=\"x\" year=\"1\" />" },
        .{ .name = "Free", .text = "<i>{ anything }</i>" },
        .{ .name = "free_page", .text = "<Free whatever=\"x\" />" },
    };
    const uses = try analyzeOne(arena.allocator(), &sources, "page");
    var problems: usize = 0;
    for (uses) |u| if (u.kind == .prop_problem) {
        problems += 1;
        if (std.mem.indexOf(u8, u.path, "nmae") != null) {
            try t.expectEqualStrings("<Hello> has no prop `nmae` (it declares: name)", u.path);
            try t.expectEqual(@as(usize, 2), u.line);
        } else if (std.mem.indexOf(u8, u.path, "1969x") != null) {
            try t.expectEqualStrings("prop `year` of <Card> is int; \"1969x\" is not", u.path);
        } else {
            // Inside <List>: its call to <Card>, through the chain.
            try t.expectEqualStrings("<Card> has no prop `titel` (it declares: title, year)", u.path);
            try t.expectEqualStrings("List", u.via);
        }
    };
    try t.expectEqual(@as(usize, 3), problems);
    // A component without a `-- props:` line takes any prop.
    for (try analyzeOne(arena.allocator(), &sources, "free_page")) |u| try t.expect(u.kind != .prop_problem);
    // The generated line is valid Zig: the message is a string literal.
    var out: std.ArrayList(u8) = .empty;
    try writeZig(&out, arena.allocator(), "page", uses);
    try t.expect(std.mem.indexOf(u8, out.items, "\\\"1969x\\\" is not") != null);
}

test "manifest: what a component reads through a prop given a data path is that path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "page", .text = "for (books) |b| { <BookCard book=\"{ b }\" label=\"x\" /> }\n<Shelf items=\"{ shelf.books }\" />" },
        .{ .name = "book_card", .text = "-- props: book!, label\n<b>{ book.title } { book.year ?? 0 } { label.whatever }</b>" },
        .{ .name = "shelf", .text = "-- props: items!\nfor (items) |i| { <i>{ i.title }</i> }{ items.len }" },
    };
    const uses = try analyzeOne(arena.allocator(), &sources, "page");
    try t.expect(has(uses, "books[].title", .text));
    try t.expect(has(uses, "books[].year", .text));
    for (uses) |u| if (std.mem.eql(u8, u.path, "books[].year")) try t.expect(u.optional);
    try t.expect(has(uses, "shelf.books", .iter));
    try t.expect(has(uses, "shelf.books[].title", .text));
    try t.expect(has(uses, "shelf.books.len", .text));
    // A literal prop is not the data's.
    for (uses) |u| try t.expect(std.mem.indexOf(u8, u.path, "whatever") == null);
}

test "manifest: a fragment reads what a call `<Name />` would, from the view's data" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "posts_index", .text = "<h1>{ title }</h1><PostList />\n<PostList>\n  for (posts) |p| { <PostRow post=\"{ p }\" /> }\n</PostList>" },
        .{ .name = "PostRow", .text = "-- props: post!, compact: bool = false\n<li>{ post.title } if (compact) { c }</li>" },
    };
    var a = try Analyzer.init(arena.allocator(), &sources);
    const inline_uses = (try a.analyzeFragment(sources[0].text, "PostList")).?;
    try t.expect(has(inline_uses, "posts", .iter));
    try t.expect(has(inline_uses, "posts[].title", .text));
    try t.expect(!has(inline_uses, "title", .text)); // the page's, not the fragment's
    // A file component: its required props must be in the data; a prop
    // with a default may be missing.
    const file_uses = (try a.analyzeFragment("", "PostRow")).?;
    try t.expect(has(file_uses, "post.title", .text));
    try t.expect(has(file_uses, "compact", .prop_bool));
    for (file_uses) |u| {
        if (std.mem.eql(u8, u.path, "post.title")) try t.expect(!u.optional);
        if (std.mem.eql(u8, u.path, "compact")) try t.expect(u.optional);
    }
    try t.expect((try a.analyzeFragment(sources[0].text, "Nope")) == null);
    try t.expectEqual(@as(usize, 1), (try a.inlineComponents(sources[0].text)).count());
}

test "manifest: a call to a component that does not exist is a problem, at the call's line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const sources = [_]Source{
        .{ .name = "page", .text =
        \\<h1>{ title }</h1>
        \\<BookCrad title="{ title }" />
        \\<BookCard title="{ title }" />
        \\<Shelf />
        },
        .{ .name = "BookCard", .text = "-- props: title!\n<p>{ title }</p>" },
        // Found by its snake_case file, and defined inline: not problems.
        .{ .name = "shelf", .text = "<Row>\n  <i>row</i>\n</Row>\n<Row />\n{ shelf_name }" },
    };
    const uses = try analyzeOne(arena.allocator(), &sources, "page");
    var problems: usize = 0;
    for (uses) |u| if (u.kind == .prop_problem) {
        problems += 1;
        try t.expectEqualStrings("<BookCrad> is not a component: no template file BookCrad.html (or book_crad.html) and no <BookCrad>...</BookCrad> defined in this file", u.path);
        try t.expectEqual(@as(usize, 2), u.line);
    };
    try t.expectEqual(@as(usize, 1), problems);
    // What a component reads is reported at the line of the call.
    for (uses) |u| if (std.mem.eql(u8, u.path, "shelf_name")) try t.expectEqual(@as(usize, 4), u.line);
    try t.expect(has(uses, "shelf_name", .text));
}

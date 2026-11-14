//! Internal: what the code Elroy generates calls (see elroy/codegen.zig).
//! Elroy turns a template into a Zig function at build time; this file
//! gives that function the template engine's rules, resolved by type at
//! compile time instead of by name at run time: which field types a
//! template reads (`fieldValue` in render/context.zig), how a path like
//! `books[0].title` resolves (`resolveValue`, `lenOf` in render/renderer.zig),
//! what `{ x }`, `{ x ?? "d" }`, a condition and a loop do with each kind of
//! value. The output must be byte for byte what the interpreter renders.

const std = @import("std");
const RawHtml = @import("../context.zig").RawHtml;

/// A name the data does not have, known at compile time.
pub const Missing = struct {};

/// `loop` inside a `for` body.
pub const Loop = struct { index: usize };

// ── Types ────────────────────────────────────────────────────────────────

const Class = enum { string, html, boolean, number, object, list, opt, unsupported };

/// How a field of type `F` reaches a template (render/context.zig
/// `fieldValue`): `unsupported` means the field is not there at all.
fn fieldClass(comptime F: type) Class {
    if (F == RawHtml) return .html;
    if (F == ?RawHtml) return .opt;
    return switch (@typeInfo(F)) {
        .bool => .boolean,
        .int, .comptime_int, .float, .comptime_float => .number,
        .@"struct" => .object,
        .optional => |o| switch (@typeInfo(o.child)) {
            .bool, .int, .comptime_int, .float, .comptime_float => .opt,
            .pointer => |p| if (p.child == u8 and p.size == .slice) .opt else .unsupported,
            else => .unsupported,
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .string else if (isListItem(p.child)) .list else .unsupported,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) .string else if (isListItem(a.child)) .list else .unsupported,
                .@"struct" => .object,
                else => .unsupported,
            },
            else => .unsupported,
        },
        .array => |a| if (a.child != u8 and isListItem(a.child)) .list else .unsupported,
        else => .unsupported,
    };
}

/// An item of a list templates read: a struct (RawHtml included) or a string.
fn isListItem(comptime E: type) bool {
    return switch (@typeInfo(E)) {
        .@"struct" => true,
        .pointer => |p| p.child == u8 and p.size == .slice,
        else => false,
    };
}

/// The type a value of field type `F` is handled as: structs by pointer
/// (no copy), arrays and string literals as slices, comptime numbers as
/// runtime ones.
fn Norm(comptime F: type) type {
    if (F == RawHtml) return RawHtml;
    return switch (@typeInfo(F)) {
        .comptime_int => i128,
        .comptime_float => f64,
        .@"struct" => *const F,
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .array => |a| []const a.child,
                else => F,
            },
            else => F,
        },
        .array => |a| []const a.child,
        .optional => |o| ?Norm(o.child),
        else => F,
    };
}

/// The class of a handle (a normalized value).
fn handleClass(comptime H: type) Class {
    if (H == RawHtml) return .html;
    return switch (@typeInfo(H)) {
        .bool => .boolean,
        .int, .float => .number,
        .optional => .opt,
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .string else .list,
            .one => .object,
            else => .unsupported,
        },
        else => .unsupported,
    };
}

// ── Paths ────────────────────────────────────────────────────────────────

const Seg = struct { name: []const u8, index: ?usize };

fn segments(comptime path: []const u8) []const Seg {
    comptime {
        if (path.len == 0) return &.{};
        var out: []const Seg = &.{};
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |s| {
            if (std.mem.indexOfScalar(u8, s, '[')) |b| {
                const close = std.mem.indexOfScalar(u8, s, ']') orelse return out ++ [_]Seg{.{ .name = "\x00bad", .index = null }};
                const idx = std.fmt.parseInt(usize, s[b + 1 .. close], 10) catch return out ++ [_]Seg{.{ .name = "\x00bad", .index = null }};
                out = out ++ [_]Seg{.{ .name = s[0..b], .index = idx }};
            } else out = out ++ [_]Seg{.{ .name = s, .index = null }};
        }
        return out;
    }
}

/// The type `lookup` returns: Missing when the path cannot exist for these
/// types, else `?H` (null: an index past the end).
fn Result(comptime Root: type, comptime segs: []const Seg) type {
    if (Root == Missing) return Missing;
    var H: type = Root;
    for (segs) |s| {
        H = Step(H, s) orelse return Missing;
    }
    return ?H;
}

/// The handle type after one segment, or null when it cannot exist.
fn Step(comptime H: type, comptime s: Seg) ?type {
    var cur: type = H;
    if (s.name.len > 0) {
        if (handleClass(cur) != .object) return null;
        const S = @typeInfo(cur).pointer.child;
        if (@typeInfo(S) != .@"struct" or !@hasField(S, s.name)) return null;
        const F = @FieldType(S, s.name);
        if (fieldClass(F) == .unsupported) return null;
        cur = Norm(F);
    }
    if (s.index != null) {
        if (handleClass(cur) != .list) return null;
        cur = Item(@typeInfo(cur).pointer.child);
    }
    return cur;
}

/// The handle of a list item: a struct by pointer (RawHtml by value), a
/// string as it is.
fn Item(comptime E: type) type {
    if (E == RawHtml) return RawHtml;
    return if (@typeInfo(E) == .@"struct") *const E else E;
}

/// The value at `path` from `root` (a handle: `&data`, a loop item, ...).
pub fn lookup(root: anytype, comptime path: []const u8) Result(@TypeOf(root), segments(path)) {
    const R = Result(@TypeOf(root), segments(path));
    if (R == Missing) return .{};
    return walk(@TypeOf(root), root, comptime segments(path));
}

fn walk(comptime H: type, h: H, comptime segs: []const Seg) Result(H, segs) {
    if (segs.len == 0) return h;
    const s = segs[0];
    const Next = Step(H, s).?;
    const Mid = if (s.name.len > 0) Norm(@FieldType(@typeInfo(H).pointer.child, s.name)) else H;
    const mid: Mid = if (s.name.len > 0) field(H, h, s.name) else h;
    if (s.index) |i| {
        if (i >= mid.len) return null;
        const next: Next = itemHandle(@typeInfo(Mid).pointer.child, &mid[i]);
        return walk(Next, next, segs[1..]);
    }
    return walk(Next, mid, segs[1..]);
}

/// Field `name` of the struct `h` points to, as a handle. A comptime field
/// (a literal in an anonymous struct, `.{ .title = "x" }`) has no address
/// at run time: it is read from the type, a struct one through a constant.
fn field(comptime H: type, h: H, comptime name: []const u8) Norm(@FieldType(@typeInfo(H).pointer.child, name)) {
    const S = @typeInfo(H).pointer.child;
    const F = @FieldType(S, name);
    if (comptime isComptimeField(S, name)) {
        switch (@typeInfo(F)) {
            .comptime_int, .comptime_float => return @as(Norm(F), @field(@as(S, undefined), name)),
            else => {},
        }
        const Static = struct {
            const value: F = @field(@as(S, undefined), name);
        };
        return toHandle(F, &Static.value);
    }
    return toHandle(F, &@field(h.*, name));
}

fn isComptimeField(comptime S: type, comptime name: []const u8) bool {
    const info = @typeInfo(S).@"struct";
    for (info.field_names, info.field_attrs) |n, a| {
        if (std.mem.eql(u8, n, name)) return a.@"comptime";
    }
    return false;
}

fn toHandle(comptime F: type, v: *const F) Norm(F) {
    return switch (@typeInfo(F)) {
        .comptime_int, .comptime_float => v.*,
        .@"struct" => if (F == RawHtml) v.* else v,
        .array => v.*[0..],
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .array) v.*[0..] else v.*,
        .optional => |o| if (v.*) |*inner| toHandle(o.child, inner) else null,
        else => v.*,
    };
}

fn itemHandle(comptime E: type, p: *const E) Item(E) {
    if (E == RawHtml) return p.*;
    return if (@typeInfo(E) == .@"struct") p else p.*;
}

// ── What the generated code calls ────────────────────────────────────────

/// Text exactly as the template engine writes it: the five characters that
/// matter in HTML text and quoted attributes escaped.
pub fn escaped(w: *std.Io.Writer, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const entity: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// A value as `appendValue` writes it.
fn writeValue(w: *std.Io.Writer, v: anytype) !void {
    const H = @TypeOf(v);
    switch (comptime handleClass(H)) {
        .string => try escaped(w, v),
        .html => try w.writeAll(v.html),
        .boolean => try w.writeAll(if (v) "true" else "false"),
        .number => try w.print("{d}", .{v}),
        .opt => if (v) |inner| try writeValue(w, inner),
        else => {},
    }
}

/// `{ path }`: the value; when there is none (not a declared null), the
/// count of `x` for `x.len`.
pub fn interp(w: *std.Io.Writer, root: anytype, comptime path: []const u8) !void {
    const r = lookup(root, path);
    if (@TypeOf(r) != Missing) {
        if (r) |v| return writeValue(w, v);
    }
    if (comptime std.mem.endsWith(u8, path, ".len") or std.mem.eql(u8, path, "len")) {
        const prefix = comptime if (std.mem.eql(u8, path, "len")) "" else path[0 .. path.len - ".len".len];
        if (lenOfValue(lookup(root, prefix))) |n| try w.print("{d}", .{n});
    }
}

/// `{ path ?? "default" }`.
pub fn interpDefault(w: *std.Io.Writer, root: anytype, comptime path: []const u8, comptime default: []const u8) !void {
    const r = lookup(root, path);
    if (@TypeOf(r) != Missing) {
        if (r) |v| {
            var buf: [64]u8 = undefined;
            const s = textOf(&buf, v);
            if (s.len > 0 and !std.mem.eql(u8, s, "false")) return writeValue(w, v);
        }
    }
    try w.writeAll(default);
}

/// The text `valueToString` gives (number fields are text in the engine).
fn textOf(buf: *[64]u8, v: anytype) []const u8 {
    const H = @TypeOf(v);
    return switch (comptime handleClass(H)) {
        .string => v,
        .html => v.html,
        .boolean => if (v) "true" else "false",
        .number => std.fmt.bufPrint(buf, "{d}", .{v}) catch "",
        .opt => if (v) |inner| textOf(buf, inner) else "",
        else => "",
    };
}

/// The count `lenOf`/`resolveLen` give: a list's or a string's, else null.
fn lenOfValue(r: anytype) ?usize {
    if (@TypeOf(r) == Missing) return null;
    const v = r orelse return null;
    return lenOfHandle(v);
}

fn lenOfHandle(v: anytype) ?usize {
    const H = @TypeOf(v);
    return switch (comptime handleClass(H)) {
        .string, .list => v.len,
        .html => v.html.len,
        .opt => if (v) |inner| lenOfHandle(inner) else null,
        else => null,
    };
}

/// `if (path)`: the last step of `evalBool`.
pub fn truthy(root: anytype, comptime path: []const u8) bool {
    const r = lookup(root, path);
    if (@TypeOf(r) == Missing) return false;
    const v = r orelse return false;
    return truthyHandle(v);
}

fn truthyHandle(v: anytype) bool {
    const H = @TypeOf(v);
    return switch (comptime handleClass(H)) {
        .boolean => v,
        .string, .html, .number => blk: {
            var buf: [64]u8 = undefined;
            const s = textOf(&buf, v);
            break :blk s.len > 0 and !std.mem.eql(u8, s, "false");
        },
        .object => true,
        .opt => if (v) |inner| truthyHandle(inner) else false,
        else => false,
    };
}

/// `path == null`: no value, or a null optional.
pub fn isNull(root: anytype, comptime path: []const u8) bool {
    const r = lookup(root, path);
    if (@TypeOf(r) == Missing) return true;
    const v = r orelse return true;
    if (comptime handleClass(@TypeOf(v)) == .opt) return v == null;
    return false;
}

/// One side of a comparison: a literal, or the text a name stands for.
pub const Text = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    ext: ?[]const u8 = null,

    pub fn slice(t: *const Text) []const u8 {
        return t.ext orelse t.buf[0..t.len];
    }
};

pub fn lit(comptime s: []const u8) Text {
    return .{ .ext = s };
}

/// `resolveLen` for a name without `.len`: the value's text, "" when none.
pub fn valueText(root: anytype, comptime path: []const u8) Text {
    var t: Text = .{};
    const r = lookup(root, path);
    if (@TypeOf(r) != Missing) {
        if (r) |v| {
            const s = textOf(&t.buf, v);
            if (s.ptr == &t.buf) t.len = s.len else t.ext = s;
            return t;
        }
    }
    t.ext = "";
    return t;
}

/// `resolveLen` for `x.len` (and anything with `.len` in it): the count of
/// `x`, "0" when it is not a list or a string.
pub fn lenText(root: anytype, comptime prefix: []const u8) Text {
    var t: Text = .{};
    const n = lenOfValue(lookup(root, prefix)) orelse 0;
    const s = std.fmt.bufPrint(&t.buf, "{d}", .{n}) catch "0";
    t.len = s.len;
    return t;
}

pub fn eqText(a: Text, b: Text) bool {
    return std.mem.eql(u8, a.slice(), b.slice());
}

pub const Cmp = enum { lt, lte, gt, gte };

/// `<`, `<=`, `>`, `>=`: both sides as integers, false when one is not.
pub fn numCmp(a: Text, b: Text, comptime cmp: Cmp) bool {
    const l = std.fmt.parseInt(i64, a.slice(), 10) catch return false;
    const r = std.fmt.parseInt(i64, b.slice(), 10) catch return false;
    return switch (cmp) {
        .lt => l < r,
        .lte => l <= r,
        .gt => l > r,
        .gte => l >= r,
    };
}

/// The items `for (path)` goes over: a list's, else none.
pub fn items(root: anytype, comptime path: []const u8) ItemsOf(@TypeOf(lookup(root, path))) {
    const r = lookup(root, path);
    if (comptime ItemsOf(@TypeOf(r)) == []const Missing) return &.{};
    return r orelse &.{};
}

fn ItemsOf(comptime R: type) type {
    if (R == Missing) return []const Missing;
    const H = @typeInfo(R).optional.child;
    if (handleClass(H) != .list) return []const Missing;
    return H;
}

/// The handle a `for` capture stands for: a struct item by pointer, a
/// string or a RawHtml by value.
pub fn item(p: anytype) Item(@typeInfo(@TypeOf(p)).pointer.child) {
    return itemHandle(@typeInfo(@TypeOf(p)).pointer.child, p);
}

// ── Components ───────────────────────────────────────────────────────────

/// Markup that goes out verbatim: a literal prop, a slot, a default.
pub fn html(s: []const u8) RawHtml {
    return .{ .html = s };
}

/// A declared prop nobody gives and with no default: there, without a value.
pub const none: ?[]const u8 = null;

/// A prop written `name="{ path }"`: the value at the path in the caller's
/// scope, or "" when there is none (`resolveValue` failed).
pub fn propExpr(r: anytype) PropExpr(@TypeOf(r)) {
    if (@TypeOf(r) == Missing) return "";
    return r.?;
}

fn PropExpr(comptime R: type) type {
    return if (R == Missing) []const u8 else @typeInfo(R).optional.child;
}

/// A declared prop the call leaves out: the caller's value when it has
/// one, else `d` (the default, or `none`).
pub fn orDefault(r: anytype, d: anytype) OrDefault(@TypeOf(r), @TypeOf(d)) {
    if (@TypeOf(r) == Missing) return d;
    return r.?;
}

fn OrDefault(comptime R: type, comptime D: type) type {
    return if (R == Missing) D else @typeInfo(R).optional.child;
}

// ── Helper calls ─────────────────────────────────────────────────────────

const assets = @import("../assets.zig");

/// `{ name("a", "b") }`: the app's helper of that name (module
/// `template_helpers`), picked when the app compiles; else the built-in
/// `asset_url(path)`; else nothing. What it returns goes out as it is; an
/// error writes nothing, as in the interpreter.
pub fn call(w: *std.Io.Writer, alc: std.mem.Allocator, comptime name: []const u8, args: []const []const u8) !void {
    const helpers = @import("template_helpers");
    if (comptime hasDecl(helpers, name)) {
        const v = @field(helpers, name)(alc, args) catch return;
        return w.writeAll(v);
    }
    if (comptime std.mem.eql(u8, name, "asset_url")) {
        if (args.len != 1) return;
        return w.writeAll(try assets.url(alc, args[0]));
    }
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".decl_names) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

/// A name passed to a component or layout function: its handle, or
/// Missing (a bare name has no index, so a lookup is never null).
pub fn bind(r: anytype) Bind(@TypeOf(r)) {
    if (@TypeOf(r) == Missing) return .{};
    return r.?;
}

fn Bind(comptime R: type) type {
    return if (R == Missing) Missing else @typeInfo(R).optional.child;
}

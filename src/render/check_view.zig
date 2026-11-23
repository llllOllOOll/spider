//! Internal: compares, at compile time, what a template reads (its entry in
//! the generated `spider_manifest`, see render/manifest.zig) with the type
//! of the data a view passes. `Ctx.view` and `Ctx.viewFragment` call it; a mismatch is a
//! compile error naming the template's file and line (`views/home.html:7`),
//! the view, the component it was read through and the path.
//!
//! The types follow what `structToContext` reads (render/context.zig): a
//! field of another type renders nothing at run time, so it is an error
//! here too.

const std = @import("std");
const RawHtml = @import("context.zig").RawHtml;

const Class = enum { string, html, boolean, number, object, list, unsupported };

/// How a field of type `T` reaches a template.
fn classOf(comptime T: type) Class {
    if (T == RawHtml or T == ?RawHtml) return .html;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int, .float, .comptime_float => .number,
        .@"struct" => .object,
        .optional => |o| switch (@typeInfo(o.child)) {
            .bool => .boolean,
            .int, .comptime_int, .float, .comptime_float => .number,
            .pointer => |p| if (p.child == u8 and p.size == .slice) .string else .unsupported,
            else => .unsupported,
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .string else if (isItem(p.child)) .list else .unsupported,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) .string else if (isItem(a.child)) .list else .unsupported,
                .@"struct" => .object,
                else => .unsupported,
            },
            else => .unsupported,
        },
        .array => |a| if (a.child != u8 and isItem(a.child)) .list else .unsupported,
        else => .unsupported,
    };
}

/// A list item templates read: a struct, a RawHtml or a string.
fn isItem(comptime T: type) bool {
    if (T == RawHtml) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .pointer => |p| p.child == u8 and p.size == .slice,
        else => false,
    };
}

/// The struct an object field reads (through a pointer, too).
fn objectOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// The item type of a list field.
fn itemOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child,
            else => @typeInfo(p.child).array.child,
        },
        .array => |a| a.child,
        else => unreachable,
    };
}

fn fieldList(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (std.meta.fieldNames(T), 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ n;
    return if (out.len == 0) "no fields" else out;
}

/// Checks every use of `uses` (a tuple of `.{ path, line, .kind, optional,
/// via }`) against `Data`. One compile error listing all that do not fit,
/// so a view is fixed in one pass.
pub fn check(comptime Data: type, comptime view: []const u8, comptime uses: anytype) void {
    checkAs(Data, "view \"" ++ view ++ "\"", "", uses);
}

/// `check` with the messages starting with `file:line:` (`file` is the
/// template's, as `spider_files` names it; "" for none), then `label`
/// (`view "posts/index"`, `fragment <PostList> of "posts/index"`).
pub fn checkAs(comptime Data: type, comptime label: []const u8, comptime file: []const u8, comptime uses: anytype) void {
    if (problemsAs(Data, label, file, uses)) |msg| @compileError(msg);
}

/// Every use of `uses` that `Data` does not satisfy, one per line; null
/// when they all fit.
pub fn problems(comptime Data: type, comptime view: []const u8, comptime uses: anytype) ?[]const u8 {
    return problemsAs(Data, "view \"" ++ view ++ "\"", "", uses);
}

fn problemsAs(comptime Data: type, comptime label: []const u8, comptime file: []const u8, comptime uses: anytype) ?[]const u8 {
    // Grows with the uses: a view whose problems are many (hundreds, when
    // a whole app's components get `-- props:` at once) still gets its
    // message instead of a branch-quota error.
    @setEvalBranchQuota(100_000 + 2_000 * uses.len);
    if (@typeInfo(Data) != .@"struct") return (if (file.len > 0) file ++ ": " else "") ++ label ++ ": the data must be a struct, like .{ .title = t }; got " ++ @typeName(Data);
    var out: []const u8 = "";
    var n: usize = 0;
    var missing: []const []const u8 = &.{};
    // The messages so far with their line: a repeat can only be on the
    // same line, so the others are not compared.
    var said: []const struct { usize, []const u8 } = &.{};
    for (uses) |u| {
        if (checkUse(Data, label, file, u[0], u[1], u[2], u[3], u[4])) |msg| {
            // The same name read twice on a line (`if (x) { x }`): once.
            const repeat = for (said) |s| {
                if (s[0] == u[1] and std.mem.eql(u8, s[1], msg)) break true;
            } else false;
            if (repeat) continue;
            said = said ++ .{.{ u[1], msg }};
            // A field that is not there: once, where it is first read, not
            // again for each of its uses (`books`, `books.len`, `books[].id`).
            if (if (u[2] == .prop_problem) null else missingField(Data, u[0])) |key| {
                const seen = for (missing) |m| {
                    if (std.mem.eql(u8, m, key)) break true;
                } else false;
                if (seen) continue;
                missing = missing ++ .{key};
            }
            out = out ++ (if (n == 0) "" else "\n") ++ msg;
            n += 1;
        }
    }
    return if (n == 0) null else out;
}

/// The first use of `uses` that `Data` does not satisfy, as the message
/// `check` fails with; null when they all fit.
pub fn problem(comptime Data: type, comptime view: []const u8, comptime uses: anytype) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const label = "view \"" ++ view ++ "\"";
    if (@typeInfo(Data) != .@"struct") return label ++ ": the data must be a struct, like .{ .title = t }; got " ++ @typeName(Data);
    for (uses) |u| {
        if (checkUse(Data, label, "", u[0], u[1], u[2], u[3], u[4])) |msg| return msg;
    }
    return null;
}

/// The part of `path` up to the first field `Data` does not have
/// ("books" for `books[].id`), or null when every field is there.
fn missingField(comptime Data: type, comptime path: []const u8) ?[]const u8 {
    var T: type = Data;
    var it = std.mem.splitScalar(u8, path, '.');
    var end: usize = 0;
    while (it.next()) |seg_full| {
        const bracket = std.mem.indexOfScalar(u8, seg_full, '[');
        const name = if (bracket) |b| seg_full[0..b] else seg_full;
        end += (if (end == 0) 0 else 1) + name.len;
        if (classOf(T) != .object) return null;
        const S = objectOf(T);
        if (!@hasField(S, name)) return path[0..end];
        const F = @FieldType(S, name);
        if (classOf(F) == .unsupported) return null;
        T = if (bracket != null and classOf(F) == .list) itemOf(F) else F;
        if (bracket) |b| end += seg_full.len - b;
    }
    return null;
}

/// "Card>Badge" as "Card> > <Badge", so the message reads `<Card> > <Badge>`.
fn chainText(comptime via: []const u8) []const u8 {
    var out: []const u8 = "";
    for (via) |ch| out = out ++ (if (ch == '>') "> > <" else &[_]u8{ch});
    return out;
}

fn isProp(comptime kind: anytype) bool {
    return kind == .prop_int or kind == .prop_bool or kind == .prop_string or kind == .prop_any;
}

fn checkUse(comptime Data: type, comptime label: []const u8, comptime file: []const u8, comptime path: []const u8, comptime line: usize, comptime kind: anytype, comptime optional: bool, comptime via: []const u8) ?[]const u8 {
    const msg = useProblem(Data, path, kind, optional, via) orelse return null;
    // `views/home.html:7: view "home"`, or `view "home", line 7` when the
    // file is not known. Built only for a problem: it costs comptime
    // branches, and a big app has thousands of uses.
    return (if (file.len == 0) "" else if (line > 0) std.fmt.comptimePrint("{s}:{d}: ", .{ file, line }) else file ++ ": ") ++
        label ++
        (if (line > 0 and file.len == 0) std.fmt.comptimePrint(", line {d}", .{line}) else "") ++
        (if (via.len > 0) " (in <" ++ chainText(via) ++ ">)" else "") ++ ": " ++ msg;
}

/// What is wrong with one use, without where it is; null when it fits.
fn useProblem(comptime Data: type, comptime path: []const u8, comptime kind: anytype, comptime optional: bool, comptime via: []const u8) ?[]const u8 {
    const where = "";
    // A call that does not fit its component's `-- props:` line: `path` is
    // the message, whatever the data.
    if (kind == .prop_problem) return where ++ path;
    var T: type = Data;
    var it = std.mem.splitScalar(u8, path, '.');
    var walked: []const u8 = "";
    while (it.next()) |seg_full| {
        const bracket = std.mem.indexOfScalar(u8, seg_full, '[');
        const name = if (bracket) |b| seg_full[0..b] else seg_full;
        const is_last = it.peek() == null;
        const cls_here = classOf(T);
        if (std.mem.eql(u8, name, "len") and is_last and (cls_here == .list or cls_here == .string or cls_here == .html)) return null;
        if (cls_here != .object and walked.len > 0) {
            if (optional) return null;
            return where ++ "`" ++ path ++ "`: `" ++ walked ++ "` is " ++ @typeName(T) ++ ", which has no fields";
        }
        const S = objectOf(T);
        if (!@hasField(S, name)) {
            if (optional) return null;
            // A declared prop the call leaves out, which the caller's data
            // was to fill.
            if (walked.len == 0 and via.len > 0 and isProp(kind))
                return where ++ "the call does not give the prop `" ++ name ++ "`, and the data has no `" ++ name ++ "` to fill it (it has: " ++ fieldList(S) ++ ")";
            return where ++ "`" ++ path ++ "`: " ++ (if (walked.len == 0) "the data" else "`" ++ walked ++ "`") ++ " has no field `" ++ name ++ "` (it has: " ++ fieldList(S) ++ ")";
        }
        const F = @FieldType(S, name);
        walked = if (walked.len == 0) name else walked ++ "." ++ name;
        if (classOf(F) == .unsupported) {
            return where ++ "`" ++ walked ++ "` is " ++ @typeName(F) ++ ", a type templates do not read (it would render nothing): pass text, a number, a bool, a struct or a list of structs/strings";
        }
        T = F;
        if (bracket != null) {
            if (classOf(F) != .list) return where ++ "`" ++ walked ++ "` is looped over but is " ++ @typeName(F) ++ ", not a list";
            T = itemOf(F);
            walked = walked ++ "[]";
        }
    }
    const cls = classOf(T);
    return switch (kind) {
        .text => if (cls == .object or cls == .list) where ++ "`" ++ path ++ "` is printed but is " ++ @typeName(T) ++ " (it would render nothing): print one of its fields" else null,
        .iter => if (cls != .list) where ++ "`for (" ++ path ++ ")`: " ++ @typeName(T) ++ " is not a list" else null,
        .prop_int => if (cls != .number) where ++ "`" ++ path ++ "` goes to an int prop but is " ++ @typeName(T) else null,
        .prop_bool => if (cls != .boolean) where ++ "`" ++ path ++ "` goes to a bool prop but is " ++ @typeName(T) else null,
        .prop_string => if (cls != .string and cls != .html) where ++ "`" ++ path ++ "` goes to a string prop but is " ++ @typeName(T) else null,
        .cond, .prop_any => null,
        else => "unknown manifest kind",
    };
}

const Book = struct { title: []const u8, year: u32, finished: bool, note: ?[]const u8 = null };

test "check: a manifest that fits the data compiles" {
    const Data = struct { title: []const u8, books: []const Book, count: usize };
    comptime check(Data, "books/index", .{
        .{ "title", 1, .text, false, "" },
        .{ "books", 2, .iter, false, "" },
        .{ "books.len", 2, .text, false, "" },
        .{ "books[].title", 3, .text, false, "" },
        .{ "books[].year", 3, .prop_int, false, "BookCard" },
        .{ "books[].finished", 3, .prop_bool, false, "" },
        .{ "books[].note", 3, .text, false, "" },
        .{ "subtitle", 4, .text, true, "" }, // optional: may be missing
        .{ "count", 5, .cond, false, "" },
    });
}

fn expectProblem(comptime Data: type, comptime uses: anytype, comptime contains: []const u8) !void {
    const msg = comptime problem(Data, "books/index", uses) orelse return error.NoProblem;
    if (std.mem.indexOf(u8, msg, contains) == null) {
        std.debug.print("message: {s}\n", .{msg});
        return error.WrongMessage;
    }
}

test "check: each kind of mismatch, with the view, the line and the fix" {
    const Data = struct { title: []const u8, books: []const Book, kind: enum { a, b }, ids: []const u32, one: Book };
    try expectProblem(Data, .{.{ "titel", 3, .text, false, "" }}, "view \"books/index\", line 3: `titel`: the data has no field `titel` (it has: title, books, kind, ids, one)");
    try expectProblem(Data, .{.{ "books[].titel", 4, .text, false, "" }}, "`books[]` has no field `titel` (it has: title, year, finished, note)");
    try expectProblem(Data, .{.{ "shelf", 0, .text, false, "Card" }}, "view \"books/index\" (in <Card>): `shelf`");
    try expectProblem(Data, .{.{ "shelf", 0, .text, false, "List>Card" }}, "view \"books/index\" (in <List> > <Card>): `shelf`");
    try expectProblem(Data, .{.{ "kind", 2, .cond, false, "" }}, "a type templates do not read");
    try expectProblem(Data, .{.{ "ids", 2, .iter, false, "" }}, "a type templates do not read");
    try expectProblem(Data, .{.{ "title", 2, .iter, false, "" }}, "is not a list");
    try expectProblem(Data, .{.{ "one", 2, .text, false, "" }}, "is printed but is");
    try expectProblem(Data, .{.{ "books[].title", 2, .prop_int, false, "" }}, "goes to an int prop but is []const u8");
    try expectProblem(Data, .{.{ "books[].year", 2, .prop_bool, false, "" }}, "goes to a bool prop but is u32");
    try expectProblem(u32, .{}, "the data must be a struct");
    // A required prop the call leaves out and the data does not have.
    try expectProblem(Data, .{.{ "name", 0, .prop_any, false, "Hello" }}, "view \"books/index\" (in <Hello>): the call does not give the prop `name`, and the data has no `name` to fill it (it has: title, books, kind, ids, one)");
    try std.testing.expect(comptime problem(Data, "v", .{.{ "title", 0, .prop_any, false, "Hello" }}) == null);
    // A component call that does not fit its `-- props:` line, whatever the data.
    try expectProblem(Data, .{.{ "<Hello> has no prop `nmae` (it declares: name)", 7, .prop_problem, false, "" }}, "view \"books/index\", line 7: <Hello> has no prop `nmae` (it declares: name)");
    try expectProblem(Data, .{.{ "prop `year` of <Card> is int; \"1969.5\" is not", 0, .prop_problem, false, "List" }}, "(in <List>): prop `year` of <Card> is int");
    // All of them at once, one per line.
    const all = comptime problems(Data, "books/index", .{ .{ "titel", 3, .text, false, "" }, .{ "title", 4, .text, false, "" }, .{ "kind", 5, .cond, false, "" } }).?;
    try std.testing.expect(std.mem.indexOf(u8, all, "line 3: `titel`") != null and std.mem.indexOf(u8, all, "\nview \"books/index\", line 5: `kind`") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all, "\n"));
    // A missing field is named once, not for each of its uses.
    const once = comptime problems(Data, "books/index", .{ .{ "shelf", 2, .iter, false, "" }, .{ "shelf.len", 2, .text, false, "" }, .{ "shelf[].title", 3, .text, false, "" }, .{ "books[].titel", 4, .text, false, "" }, .{ "books[].titel", 5, .cond, false, "" } }).?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, once, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, once, "line 2: `shelf`") != null and std.mem.indexOf(u8, once, "line 4: `books[].titel`") != null);
    // With the template's file: `file:line:` first.
    const at = comptime problemsAs(Data, "view \"home\"", "views/home.html", .{ .{ "titel", 3, .text, false, "" }, .{ "shelf", 0, .text, false, "Card" } }).?;
    try std.testing.expect(std.mem.indexOf(u8, at, "views/home.html:3: view \"home\": `titel`") != null);
    try std.testing.expect(std.mem.indexOf(u8, at, "views/home.html: view \"home\" (in <Card>): `shelf`") != null);
    // Through an optional: not reported.
    try std.testing.expect(comptime problem(Data, "v", .{.{ "nope.deeper", 1, .text, true, "" }}) == null);
}

test "check: a view with hundreds of problems still gets its message" {
    // A whole app's components given `-- props:` at once can leave one
    // view with hundreds of problems; listing them must not run out of
    // comptime branches before the message is shown.
    const Data = struct { title: []const u8 };
    const Use = struct { []const u8, usize, @TypeOf(.text), bool, []const u8 };
    const uses = comptime blk: {
        @setEvalBranchQuota(400_000); // building the 400 uses; problemsAs raises its own
        var list: [400]Use = undefined;
        for (&list, 0..) |*u, i| u.* = .{ std.fmt.comptimePrint("missing_{d}", .{i}), i + 1, .text, false, "Card>Row" };
        break :blk list;
    };
    const msg = comptime problemsAs(Data, "view \"books/index\"", "views/books/index.html", uses) orelse return error.NoProblem;
    try std.testing.expect(std.mem.indexOf(u8, msg, "views/books/index.html:400: view \"books/index\" (in <Card> > <Row>): `missing_399`") != null);
}

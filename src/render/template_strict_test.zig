// Template.strict: what a render does with a name that is not there
// (a variable, a field, a prop, a component, a layout), as opposed to a name
// that is declared with no value (a null optional).

const std = @import("std");
const template_mod = @import("template.zig");
const Template = template_mod.Template;
const Strictness = template_mod.Strictness;

const t = std.testing;

const Comps = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    fn add(self: *Comps, name: []const u8, html: []const u8) !void {
        try self.map.put(t.allocator, try t.allocator.dupe(u8, name), try t.allocator.dupe(u8, html));
    }

    fn deinit(self: *Comps) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            t.allocator.free(e.key_ptr.*);
            t.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(t.allocator);
    }
};

fn renderStrict(comps: *Comps, strict: Strictness, src: []const u8, context: anytype) ![]const u8 {
    var tmpl = try Template.initNamed(t.allocator, src, "test/view");
    defer tmpl.deinit();
    tmpl.components = comps.map;
    tmpl.strict = strict;
    return tmpl.render(context, t.allocator);
}

/// Renders `src` in every mode: the same output in `.off` and `.warn`, and
/// in `.error` the same output too (nothing here is missing).
fn expectSame(comps: *Comps, src: []const u8, context: anytype, expected: []const u8) !void {
    inline for (.{ Strictness.off, Strictness.warn, Strictness.@"error" }) |mode| {
        const out = try renderStrict(comps, mode, src, context);
        defer t.allocator.free(out);
        try t.expectEqualStrings(expected, out);
    }
}

/// `src` names something that is not there: empty in `.off` and `.warn`
/// (`expected`), error.TemplateNameNotFound in `.error`.
fn expectMissing(comps: *Comps, src: []const u8, context: anytype, expected: []const u8) !void {
    inline for (.{ Strictness.off, Strictness.warn }) |mode| {
        const out = try renderStrict(comps, mode, src, context);
        defer t.allocator.free(out);
        try t.expectEqualStrings(expected, out);
    }
    try t.expectError(error.TemplateNameNotFound, renderStrict(comps, .@"error", src, context));
}

const Book = struct { title: []const u8, year: u32, subtitle: ?[]const u8 = null };

test "a variable or a field that is not there" {
    var comps: Comps = .{};
    defer comps.deinit();
    const book: Book = .{ .title = "Piranesi", .year = 2020 };
    try expectMissing(&comps, "[{ titel }]", .{ .title = "x" }, "[]");
    try expectMissing(&comps, "[{ book.titel }]", .{ .book = book }, "[]");
    try expectMissing(&comps, "if (published) {yes} else {no}", .{}, "no");
    try expectMissing(&comps, "if (status == \"open\") {open} else {closed}", .{}, "closed");
    try expectMissing(&comps, "for (books) |b| {<li>{ b.title }</li>}", .{}, "");
}

test "a null optional is declared: empty, false, ?? and == null, never an error" {
    var comps: Comps = .{};
    defer comps.deinit();
    const book: Book = .{ .title = "Piranesi", .year = 2020 };
    try expectSame(&comps, "[{ book.subtitle }]", .{ .book = book }, "[]");
    try expectSame(&comps, "[{ book.subtitle ?? \"-\" }]", .{ .book = book }, "[-]");
    try expectSame(&comps, "if (book.subtitle) {yes} else {no}", .{ .book = book }, "no");
    try expectSame(&comps, "if (book.subtitle == null) {none} else {some}", .{ .book = book }, "none");
    const note: ?[]const u8 = null;
    try expectSame(&comps, "[{ note }]", .{ .note = note }, "[]");
    try expectSame(&comps, "[{ note }]", .{ .note = @as(?[]const u8, "hi") }, "[hi]");
}

test "names every template has, ?? defaults, == null checks and data-dependent misses are not reported" {
    var comps: Comps = .{};
    defer comps.deinit();
    const books = [_]Book{ .{ .title = "A", .year = 1 }, .{ .title = "B", .year = 2 } };
    try expectSame(&comps, "{ books.len }", .{ .books = &books }, "2");
    try expectSame(&comps, "for (books) |b| { <i>{ loop.index }:{ b.title }</i> }", .{ .books = &books }, "<i>0:A</i><i>1:B</i>");
    try expectSame(&comps, "[{ books[5].title }]", .{ .books = &books }, "[]");
    try expectSame(&comps, "[{ title ?? \"Shelf\" }]", .{}, "[Shelf]");
    try expectSame(&comps, "if (nothing == null) {absent}", .{}, "absent");
    try comps.add("Box", "<div>{ slot }</div>");
    try expectSame(&comps, "<Box />", .{}, "<div></div>");
}

test "a component, a prop and a layout that are not there" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<b>{ title }</b>");
    try expectMissing(&comps, "a<MetricChart />b", .{}, "ab");
    // The prop the component reads is not passed, and not in the caller's scope.
    try expectMissing(&comps, "<Card />", .{}, "<b></b>");
    // A prop given as an expression that names nothing.
    try expectMissing(&comps, "<Card title=\"{ titel }\" />", .{}, "<b></b>");
    try expectMissing(&comps, "extends \"nowhere\"\n<p>page</p>", .{}, "<p>page</p>");
}

test "a component sees its caller's names: not reported" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<b>{ title }</b>");
    try expectSame(&comps, "<Card />", .{ .title = "from the page" }, "<b>from the page</b>");
    try expectSame(&comps, "<Card title=\"{ name }\" />", .{ .name = "prop" }, "<b>prop</b>");
}

// A component's `-- props:` declaration (render/props_decl.zig) at render
// time: defaults, required props, unknown props and literal types.

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

fn render(comps: *Comps, strict: Strictness, src: []const u8, context: anytype) ![]const u8 {
    var tmpl = try Template.initNamed(t.allocator, src, "test/page");
    defer tmpl.deinit();
    tmpl.components = comps.map;
    tmpl.strict = strict;
    return tmpl.render(context, t.allocator);
}

fn expectOk(comps: *Comps, src: []const u8, context: anytype, expected: []const u8) !void {
    inline for (.{ Strictness.off, Strictness.warn, Strictness.@"error" }) |mode| {
        const out = try render(comps, mode, src, context);
        defer t.allocator.free(out);
        try t.expectEqualStrings(expected, out);
    }
}

/// A problem with the props: the same output in `.off` and `.warn`,
/// error.TemplatePropInvalid in `.error`.
fn expectProblem(comps: *Comps, src: []const u8, context: anytype, expected: []const u8) !void {
    inline for (.{ Strictness.off, Strictness.warn }) |mode| {
        const out = try render(comps, mode, src, context);
        defer t.allocator.free(out);
        try t.expectEqualStrings(expected, out);
    }
    try t.expectError(error.TemplatePropInvalid, render(comps, .@"error", src, context));
}

const card =
    \\-- props: title!, year: int, finished: bool = false, size = "md"
    \\<b class="{ size }">{ title } ({ year ?? "?" })if (finished) { ✓ }</b>
;

test "props: the header is not rendered; defaults fill what the call leaves out" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", card);
    try expectOk(&comps, "<Card title=\"Piranesi\" />", .{}, "<b class=\"md\">Piranesi (?)</b>");
    try expectOk(&comps, "<Card title=\"A\" year=\"1969\" finished=\"true\" size=\"lg\" />", .{}, "<b class=\"lg\">A (1969)✓</b>");
    try expectOk(&comps, "<Card title=\"A\" finished=\"false\" />", .{}, "<b class=\"md\">A (?)</b>");
}

test "props: a required prop may come from the caller's scope" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", card);
    try expectOk(&comps, "<Card />", .{ .title = "from the page" }, "<b class=\"md\">from the page (?)</b>");
    try expectOk(&comps, "<Card title=\"{ name }\" />", .{ .name = "expr" }, "<b class=\"md\">expr (?)</b>");
}

test "props: a required prop nobody gives, an unknown prop, a literal of the wrong type" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", card);
    try expectProblem(&comps, "<Card />", .{}, "<b class=\"md\"> (?)</b>");
    try expectProblem(&comps, "<Card title=\"A\" colour=\"red\" />", .{}, "<b class=\"md\">A (?)</b>");
    try expectProblem(&comps, "<Card title=\"A\" year=\"1969x\" />", .{}, "<b class=\"md\">A (1969x)</b>");
    try expectProblem(&comps, "<Card title=\"A\" finished=\"yes\" />", .{}, "<b class=\"md\">A (?)✓</b>");
}

test "props: a default is for when nobody gives the value; the caller's scope does" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", card);
    try expectOk(&comps, "<Card />", .{ .title = "T", .size = "xl", .finished = true }, "<b class=\"xl\">T (?)✓</b>");
    try expectOk(&comps, "<Card size=\"sm\" />", .{ .title = "T", .size = "xl" }, "<b class=\"sm\">T (?)</b>");
}

test "props: an optional prop left out is declared, not a name that is not there" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Tag", "-- props: label, note\n<i>{ label }{ note }</i>");
    // `note` is used without being given: declared with no value, so no
    // "name not found" either.
    try expectOk(&comps, "<Tag label=\"x\" />", .{}, "<i>x</i>");
}

test "props: a component without the header works as before" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Plain", "<u>{ anything }</u>");
    const out = try render(&comps, .off, "<Plain anything=\"ok\" extra=\"fine\" />", .{});
    defer t.allocator.free(out);
    try t.expectEqualStrings("<u>ok</u>", out);
}

test "props: a header that does not parse is a syntax error of the component" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Bad", "-- props: year: float\n<u>x</u>");
    try t.expectError(error.InvalidPropsHeader, render(&comps, .off, "<Bad />", .{}));
}

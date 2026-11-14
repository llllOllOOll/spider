// render/parsed_cache.zig: embedded templates parsed once render exactly as
// templates parsed on every request, and a template that does not parse
// fails the build.

const std = @import("std");
const t = std.testing;
const parsed_cache = @import("parsed_cache.zig");
const embedded = @import("embedded.zig");
const Template = @import("template.zig").Template;

const Templates = struct {
    layout: []const u8 = "<html><nav>{ title ?? \"Shelf\" }</nav>{ slot }<footer>{ slot_footer }</footer></html>",
    books_index: []const u8 =
        \\extends "layout"
        \\<h1>{ title }</h1>
        \\for (books) |b| {
        \\  if (b.done) { <Card name="{ b.name }"><i>done: { b.name }</i></Card> } else { <Card name="{ b.name }" /> }
        \\}
        \\<Badge><b>{ title }</b></Badge>
        \\{ slot_footer }<small>shelf footer</small>
    ,
    // A page that defines a component inline, at the root.
    books_inline: []const u8 =
        \\<Local><em>{ name }</em></Local>
        \\<Local name="x" />-<Local name="y" />
    ,
    components_card: []const u8 = "<article>{ name }{ slot }</article>",
    components_badge: []const u8 = "<span class=\"badge\">{ slot }</span>",
    readme: []const u8 = "-- doc\n# not a template { unclosed",
};

const map: embedded.Map = embedded.buildMap(Templates);

const Book = struct { name: []const u8, done: bool };
const data = .{ .title = "Mine", .books = @as([]const Book, &.{ .{ .name = "A", .done = true }, .{ .name = "B", .done = false } }) };

fn renderFresh(name: []const u8) ![]const u8 {
    var tmpl = try Template.initNamed(t.allocator, map.get(name).?, name);
    defer tmpl.deinit();
    tmpl.base_components = &map;
    return tmpl.render(data, t.allocator);
}

fn renderCached(name: []const u8) ![]const u8 {
    const page = parsed_cache.page(map.get(name).?) orelse return error.NotCached;
    var tmpl = Template.fromCache(t.allocator, page, name);
    defer tmpl.deinit();
    tmpl.base_components = &map;
    return tmpl.render(data, t.allocator);
}

test "every embedded template renders the same parsed once as parsed per request" {
    parsed_cache.resetForTest();
    defer parsed_cache.resetForTest();
    const n = try parsed_cache.build(&map);
    try t.expect(n > 0);
    try t.expect(parsed_cache.isReady());

    for ([_][]const u8{ "books_index", "books_inline", "layout" }) |name| {
        const fresh = try renderFresh(name);
        defer t.allocator.free(fresh);
        // Twice: the shared nodes must come out of a render unchanged.
        for (0..2) |_| {
            const cached = try renderCached(name);
            defer t.allocator.free(cached);
            try t.expectEqualStrings(fresh, cached);
        }
    }
}

test "the cache holds the page form, components, inline components and slot content" {
    parsed_cache.resetForTest();
    defer parsed_cache.resetForTest();
    _ = try parsed_cache.build(&map);

    // The root-level inline definition is out of the page's nodes and in its map.
    const inline_page = parsed_cache.page(map.get("books_inline").?).?;
    try t.expect(inline_page.inline_components.contains("Local"));
    try t.expect(parsed_cache.raw(inline_page.inline_components.get("Local").?) != null);
    // A component, the layout, and Markdown left alone.
    try t.expect(parsed_cache.raw(map.get("components_card").?) != null);
    try t.expect(parsed_cache.raw(map.get("layout").?) != null);
    try t.expect(parsed_cache.page(map.get("readme").?) == null);
    // A source that is not embedded (same text, other memory) is not found.
    const copy = try t.allocator.dupe(u8, map.get("components_card").?);
    defer t.allocator.free(copy);
    try t.expect(parsed_cache.raw(copy) == null);
}

test "nothing is cached before build, and a template that does not parse fails it" {
    parsed_cache.resetForTest();
    defer parsed_cache.resetForTest();
    try t.expect(parsed_cache.raw(map.get("components_card").?) == null);

    const Broken = struct {
        ok: []const u8 = "<p>{ fine }</p>",
        broken: []const u8 = "<p>{ unclosed </p>",
    };
    const broken_map: embedded.Map = comptime embedded.buildMap(Broken);
    try t.expectError(error.UnclosedInterpolation, parsed_cache.build(&broken_map));
    try t.expect(!parsed_cache.isReady());
}

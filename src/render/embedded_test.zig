const std = @import("std");
const embedded = @import("embedded.zig");
const Template = @import("template.zig").Template;
const Ctx = @import("../core/context.zig").Ctx;

// Same shape as a generated src/embedded_templates.zig: components/Card.html
// becomes `Card` plus the legacy `components_Card`; a snake_case file under
// components/ keeps its prefix (reached through the `user_card` alias).
const Fixture = struct {
    layout: []const u8 = "<html><body>{ slot }</body></html>",
    home_index: []const u8 = "extends \"layout\"\n<Card title=\"{ title }\" /><UserCard />",
    Card: []const u8 = "<h2>{ title }</h2>",
    components_Card: []const u8 = "<h2>{ title }</h2>",
    components_user_card: []const u8 = "<p>user card</p>",
    Box: []const u8 = "<div class=\"box\">{ slot }</div>",
    docs_page: []const u8 = "-- doc\n# Hello",
    fragments_list: []const u8 = "<Items><ul>for (items) |i| {<li>{ i }</li>}</ul></Items><Items />",
    pages_boxed: []const u8 = "extends \"layout\"\n<Box><Card title=\"{ title }\" /></Box>",
    who_layout: []const u8 = "if (current_user) {<b>{ current_user.name }</b>} else {<i>guest</i>}{ slot }",
    who_page: []const u8 = "extends \"who_layout\"\n<Who />",
    Who: []const u8 = "<p>{ current_user.id }|{ current_user.email }</p>",
};

const fixture_map = embedded.buildMap(Fixture);

test "embedded map: every field by name, components_ also by alias" {
    try std.testing.expectEqualStrings("<h2>{ title }</h2>", fixture_map.get("Card").?);
    try std.testing.expectEqualStrings("<h2>{ title }</h2>", fixture_map.get("components_Card").?);
    try std.testing.expectEqualStrings("<h2>{ title }</h2>", fixture_map.get("Card").?);
    try std.testing.expectEqualStrings("<p>user card</p>", fixture_map.get("user_card").?);
    try std.testing.expect(fixture_map.get("home_index") != null);
    try std.testing.expect(fixture_map.get("index") == null);
}

test "embedded map: a later name wins, like the per-request map it replaces" {
    const FieldThenAlias = struct {
        card: []const u8 = "field",
        components_card: []const u8 = "alias",
    };
    const AliasThenField = struct {
        components_card: []const u8 = "alias",
        card: []const u8 = "field",
    };
    try std.testing.expectEqualStrings("alias", (comptime embedded.buildMap(FieldThenAlias)).get("card").?);
    try std.testing.expectEqualStrings("field", (comptime embedded.buildMap(AliasThenField)).get("card").?);
}

test "embedded map: empty struct (app without templates)" {
    const map = comptime embedded.buildMap(struct {});
    try std.testing.expect(map.get("layout") == null);
}

test "embedded name: '/' and '-' become '_', too long is not found" {
    var buf: [embedded.max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("home_index", embedded.normalizeName(&buf, "home/index").?);
    try std.testing.expectEqualStrings("water_readings_new_form", embedded.normalizeName(&buf, "water-readings/new-form").?);
    const long: [embedded.max_name_len + 1]u8 = @splat('a');
    try std.testing.expect(embedded.normalizeName(&buf, &long) == null);
}

test "template with base components: layout, component, snake_case fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var tmpl = try Template.init(alc, fixture_map.get("home_index").?);
    tmpl.base_components = &fixture_map;
    const out = try tmpl.render(.{ .title = "Hi" }, alc);
    try std.testing.expectEqualStrings("<html><body><h2>Hi</h2><p>user card</p></body></html>", out);
}

test "template with base components: a base component used with a slot is an invocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var tmpl = try Template.init(alc, "<Box><p>inside</p></Box>");
    tmpl.base_components = &fixture_map;
    const out = try tmpl.render(.{}, alc);
    try std.testing.expectEqualStrings("<div class=\"box\"><p>inside</p></div>", out);
}

test "template with base components: inline definitions still work and win" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var tmpl = try Template.init(alc, "<Local><i>local</i></Local><Local /><Card title=\"x\" />");
    tmpl.base_components = &fixture_map;
    const out = try tmpl.render(.{}, alc);
    try std.testing.expectEqualStrings("<i>local</i><h2>x</h2>", out);
}

test "template with base components: renderFragment finds a base component" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var tmpl = try Template.init(alc, "<p>page</p>");
    tmpl.base_components = &fixture_map;
    const out = try tmpl.renderFragment("Card", .{ .title = "frag" }, alc);
    try std.testing.expectEqualStrings("<h2>frag</h2>", out);
}

fn testCtx(alc: std.mem.Allocator) Ctx {
    return Ctx{ .request = undefined, .arena = alc, .params = .{}, .body = null };
}

test "Ctx.prepareEmbedded: template, -- doc, not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    var c = testCtx(alc);

    var page = (try c.prepareEmbedded(&fixture_map, "home/index", .{})).template;
    const out = try page.render(.{ .title = "T" }, alc);
    try std.testing.expectEqualStrings("<html><body><h2>T</h2><p>user card</p></body></html>", out);
    try std.testing.expectEqualStrings("home/index", c._last_template.?);

    const doc = (try c.prepareEmbedded(&fixture_map, "docs/page", .{})).done;
    try std.testing.expect(std.mem.indexOf(u8, doc.body.?, "Hello") != null);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", doc.content_type);

    try std.testing.expectError(error.TemplateNotFound, c.prepareEmbedded(&fixture_map, "nope/missing", .{}));
    try std.testing.expectEqualStrings("nope/missing", c._last_template.?);
}

test "Ctx.prepareEmbedded: inline component + fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    var c = testCtx(alc);

    var page = (try c.prepareEmbedded(&fixture_map, "fragments/list", .{})).template;
    const out = try page.renderFragment("Items", .{ .items = &[_][]const u8{ "a", "b" } }, alc);
    try std.testing.expectEqualStrings("<ul><li>a</li><li>b</li></ul>", out);
}

/// The per-request map Ctx.view() built before (every field, plus the alias
/// of each components_ field), to check the new path renders the same.
fn legacyComponents(alc: std.mem.Allocator) !std.StringHashMapUnmanaged([]const u8) {
    var components = std.StringHashMapUnmanaged([]const u8){};
    const inst: Fixture = .{};
    inline for (@typeInfo(Fixture).@"struct".field_names) |fname| {
        const content: []const u8 = @field(inst, fname);
        try components.put(alc, try alc.dupe(u8, fname), try alc.dupe(u8, content));
        if (comptime std.mem.startsWith(u8, fname, "components_")) {
            try components.put(alc, try alc.dupe(u8, fname["components_".len..]), try alc.dupe(u8, content));
        }
    }
    return components;
}

test "embedded view renders exactly what the per-request map rendered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    var c = testCtx(alc);
    const data = .{ .title = "Same", .items = &[_][]const u8{ "x", "y" } };

    inline for (.{ "home/index", "pages/boxed", "fragments/list", "layout" }) |name| {
        var old = try Template.init(alc, fixture_map.get(comptime blk: {
            var buf: [name.len]u8 = undefined;
            for (name, 0..) |ch, i| buf[i] = if (ch == '/') '_' else ch;
            const final = buf;
            break :blk &final;
        }).?);
        old.components = try legacyComponents(alc);
        const expected = try old.render(data, alc);

        var new = (try c.prepareEmbedded(&fixture_map, name, .{})).template;
        const got = try new.render(data, alc);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "embedded fragment renders exactly what the per-request map rendered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    var c = testCtx(alc);
    const data = .{ .title = "Frag", .items = &[_][]const u8{"z"} };

    inline for (.{ .{ "fragments/list", "Items" }, .{ "home/index", "Card" }, .{ "pages/boxed", "Box" } }) |pair| {
        var old = try Template.init(alc, fixture_map.get(comptime blk: {
            var buf: [pair[0].len]u8 = undefined;
            for (pair[0], 0..) |ch, i| buf[i] = if (ch == '/') '_' else ch;
            const final = buf;
            break :blk &final;
        }).?);
        old.components = try legacyComponents(alc);
        const expected = try old.renderFragment(pair[1], data, alc);

        var new = (try c.prepareEmbedded(&fixture_map, pair[0], .{})).template;
        const got = try new.renderFragment(pair[1], data, alc);
        try std.testing.expectEqualStrings(expected, got);
    }
}

test "Ctx views: current_user is the signed-in user, in the layout and in components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var anonymous = testCtx(alc);
    var page = (try anonymous.prepareEmbedded(&fixture_map, "who/page", .{})).template;
    try std.testing.expectEqualStrings("<i>guest</i><p>|</p>", try page.render(.{}, alc));

    var c = testCtx(alc);
    try c.setUser(.{ .id = "7", .email = "ana@example.com", .name = "Ana <Ribeiro>" });
    page = (try c.prepareEmbedded(&fixture_map, "who/page", .{})).template;
    try std.testing.expectEqualStrings("<b>Ana &lt;Ribeiro&gt;</b><p>7|ana@example.com</p>", try page.render(.{}, alc));

    // A fragment gets it too.
    page = (try c.prepareEmbedded(&fixture_map, "who/page", .{})).template;
    try std.testing.expectEqualStrings("<p>7|ana@example.com</p>", try page.renderFragment("Who", .{}, alc));
}

test "Ctx views: the handler's own current_user wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var c = testCtx(alc);
    try c.setUser(.{ .id = "7", .name = "Ana" });
    var page = (try c.prepareEmbedded(&fixture_map, "who/page", .{})).template;
    const out = try page.render(.{ .current_user = .{ .id = "1", .name = "Bia", .email = "" } }, alc);
    try std.testing.expectEqualStrings("<b>Bia</b><p>1|</p>", out);
}

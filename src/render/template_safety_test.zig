// HTML comments, component recursion limits and the per-render component
// parse cache.

const std = @import("std");
const Template = @import("template.zig").Template;
const renderer = @import("renderer.zig");

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

fn renderWith(comps: *Comps, src: []const u8, context: anytype) ![]const u8 {
    var tmpl = try Template.init(t.allocator, src);
    defer tmpl.deinit();
    tmpl.components = comps.map;
    return tmpl.render(context, t.allocator);
}

fn expectRender(comps: *Comps, src: []const u8, context: anytype, expected: []const u8) !void {
    const out = try renderWith(comps, src, context);
    defer t.allocator.free(out);
    try t.expectEqualStrings(expected, out);
}

// ── HTML comments ───────────────────────────────────────────────────────

test "comment: component that mentions its own tag in a comment renders once" {
    // The exact Orbitx incident (BottomNavGatekeeper.html documenting itself).
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Nav", "<!-- usage: <Nav /> --><nav>menu</nav>");
    try expectRender(&comps, "<Nav />", .{}, "<!-- usage: <Nav /> --><nav>menu</nav>");
}

test "comment: component tag inside a top-level comment is not included" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<div>card</div>");
    try expectRender(&comps, "a<!-- <Card /> -->b", .{}, "a<!-- <Card /> -->b");
}

test "comment: interpolation and control flow inside comments stay literal" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "<!-- { secret } if (x) { y } for (a) |b| { c } -->{ name }", .{ .name = "n", .secret = "S" }, "<!-- { secret } if (x) { y } for (a) |b| { c } -->n");
}

test "comment: inside if body, with a component tag and a stray brace" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<div>card</div>");
    try expectRender(&comps,
        \\if (show) {<!-- <Card /> { --><Card />}
    , .{ .show = true }, "<!-- <Card /> { --><div>card</div>");
}

test "comment: inside for body" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Item", "<li>{ label }</li>");
    const items = [_][]const u8{ "a", "b" };
    try expectRender(&comps,
        \\for (items) |i| {<!-- <Item /> --><Item label="{ i }" />}
    , .{ .items = &items }, "<!-- <Item /> --><li>a</li><!-- <Item /> --><li>b</li>");
}

test "comment: inside else body" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<div>card</div>");
    try expectRender(&comps,
        \\if (show) {x} else {<!-- } <Card /> -->y}
    , .{ .show = false }, "<!-- } <Card /> -->y");
}

test "comment: unterminated comment swallows the rest verbatim" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<div>card</div>");
    try expectRender(&comps, "a<!-- <Card /> { x }", .{}, "a<!-- <Card /> { x }");
}

test "comment: text around comments still interpolates" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "{ a }<!-- x -->{ b }<!---->{ a }", .{ .a = "1", .b = "2" }, "1<!-- x -->2<!---->1");
}

test "comment: a <script> after a comment is still raw" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "<!-- c --><script>let o = { a: 1 };</script>", .{}, "<!-- c --><script>let o = { a: 1 };</script>");
}

// ── recursion limit ─────────────────────────────────────────────────────

test "recursion: self-including component fails with an error instead of crashing" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Loop", "<div><Loop /></div>");
    try t.expectError(error.ComponentDepthExceeded, renderWith(&comps, "<Loop />", .{}));
}

test "recursion: mutual recursion A -> B -> A fails with an error" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Ping", "<Pong />");
    try comps.add("Pong", "<Ping />");
    try t.expectError(error.ComponentDepthExceeded, renderWith(&comps, "<Ping />", .{}));
}

test "recursion: self-include inside a slot fails with an error" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Box", "<div>{ slot }</div>");
    try comps.add("Evil", "<Box><Evil /></Box>");
    try t.expectError(error.ComponentDepthExceeded, renderWith(&comps, "<Evil />", .{}));
}

fn buildChain(comps: *Comps, depth: usize) !void {
    var name_buf: [16]u8 = undefined;
    var body_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "C{d}", .{i});
        const body = if (i + 1 < depth)
            try std.fmt.bufPrint(&body_buf, "<C{d} />", .{i + 1})
        else
            try std.fmt.bufPrint(&body_buf, "leaf", .{});
        try comps.add(name, body);
    }
}

test "recursion: nesting exactly at the limit renders" {
    var comps: Comps = .{};
    defer comps.deinit();
    try buildChain(&comps, renderer.max_component_depth);
    try expectRender(&comps, "<C0 />", .{}, "leaf");
}

test "recursion: nesting one past the limit fails" {
    var comps: Comps = .{};
    defer comps.deinit();
    try buildChain(&comps, renderer.max_component_depth + 1);
    try t.expectError(error.ComponentDepthExceeded, renderWith(&comps, "<C0 />", .{}));
}

test "recursion: the same component used many times side by side is not nesting" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Dot", ".");
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(t.allocator);
    for (0..renderer.max_component_depth * 3) |_| try src.appendSlice(t.allocator, "<Dot />");
    const out = try renderWith(&comps, src.items, .{});
    defer t.allocator.free(out);
    try t.expectEqual(renderer.max_component_depth * 3, out.len);
}

test "recursion: data-driven recursion that terminates still works" {
    // A component including itself behind a condition that becomes false.
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Once", "if (again) {<Once again=\"false\" />} else {done}");
    try expectRender(&comps, "<Once again=\"true\" />", .{}, "done");
}

// ── per-render parse cache ──────────────────────────────────────────────

test "cache: component reused across loop iterations gets fresh props each time" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Row", "<tr>{ label }:{ n ?? \"-\" }</tr>");
    const items = [_][]const u8{ "a", "b", "c" };
    try expectRender(&comps,
        \\for (items) |i| {<Row label="{ i }" />}
    , .{ .items = &items }, "<tr>a:-</tr><tr>b:-</tr><tr>c:-</tr>");
}

test "cache: same component with and without slot in one render" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Box", "[{ slot }]");
    try expectRender(&comps, "<Box>x</Box><Box /><Box>y</Box>", .{}, "[x][][y]");
}

test "cache: PascalCase -> snake_case lookup is cached under the tag name" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("user_card", "<b>{ name }</b>");
    try expectRender(&comps, "<UserCard name=\"a\" /><UserCard name=\"b\" />", .{}, "<b>a</b><b>b</b>");
}

test "unknown component renders empty and does not crash" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "a<Missing />b", .{}, "ab");
}

test "very long component name does not overflow the snake_case buffer" {
    var comps: Comps = .{};
    defer comps.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(t.allocator);
    try src.append(t.allocator, '<');
    for (0..200) |_| try src.appendSlice(t.allocator, "Ab");
    try src.appendSlice(t.allocator, " />");
    try expectRender(&comps, src.items, .{}, "");
}

test "renderFragment: self-including fragment fails with an error" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Frag", "<Frag />");
    var tmpl = try Template.init(t.allocator, "");
    defer tmpl.deinit();
    tmpl.components = comps.map;
    try t.expectError(error.ComponentDepthExceeded, tmpl.renderFragment("Frag", .{}, t.allocator));
}

// ── HTML escaping ───────────────────────────────────────────────────────
// `{ expr }` escapes by default; only values the app marks as RawHtml, and
// the template's own markup (slots, literal props), are emitted verbatim.

const RawHtml = @import("context.zig").RawHtml;

test "escape: interpolated text is HTML-escaped" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "<p>{ name }</p>", .{ .name = "<script>alert(1)</script> & 'x'" }, "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &#39;x&#39;</p>");
}

test "escape: a value cannot break out of a quoted attribute" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "<a href=\"{ url }\">x</a>", .{ .url = "\" onmouseover=\"alert(1)" }, "<a href=\"&quot; onmouseover=&quot;alert(1)\">x</a>");
}

test "escape: interpolation with a default escapes the value" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "{ name ?? \"-\" }", .{ .name = "<b>" }, "&lt;b&gt;");
}

test "escape: loop items and nested fields are escaped" {
    var comps: Comps = .{};
    defer comps.deinit();
    const Item = struct { title: []const u8 };
    const items = [_]Item{ .{ .title = "<i>a</i>" }, .{ .title = "b&c" } };
    try expectRender(&comps, "for (items) |it| {<li>{ it.title }</li>}", .{ .items = @as([]const Item, &items) }, "<li>&lt;i&gt;a&lt;/i&gt;</li><li>b&amp;c</li>");
}

test "escape: RawHtml is emitted verbatim, also optional and inside structs" {
    var comps: Comps = .{};
    defer comps.deinit();
    const Row = struct { body: RawHtml };
    try expectRender(&comps, "{ a }|{ b }|{ row.body }", .{
        .a = RawHtml{ .html = "<b>a</b>" },
        .b = @as(?RawHtml, .{ .html = "<i>b</i>" }),
        .row = Row{ .body = .{ .html = "<u>c</u>" } },
    }, "<b>a</b>|<i>b</i>|<u>c</u>");
}

test "escape: component slot content is not escaped twice" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Card", "<div class=\"card\">{ slot }</div>");
    try expectRender(&comps, "<Card><b>{ name }</b></Card>", .{ .name = "<x>" }, "<div class=\"card\"><b>&lt;x&gt;</b></div>");
}

test "escape: expression props are escaped once, literal props stay template markup" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Badge", "<span title=\"{ label }\">{ text }</span>");
    try expectRender(&comps, "<Badge label=\"A &amp; B\" text=\"{ name }\" />", .{ .name = "x < y & z" }, "<span title=\"A &amp; B\">x &lt; y &amp; z</span>");
}

test "escape: nested component props pass the raw value down, escaped only at output" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("Inner", "<i>{ v }</i>");
    try comps.add("Outer", "<Inner v=\"{ w }\" />");
    try expectRender(&comps, "<Outer w=\"{ name }\" />", .{ .name = "a&b" }, "<i>a&amp;b</i>");
}

test "escape: comparisons see the raw value, not the escaped one" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "if (name == \"a&b\") {yes} else {no}", .{ .name = "a&b" }, "yes");
}

test "escape: layout slots carry rendered HTML verbatim" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("layout", "<main>{ slot }</main><aside>{ slot_side }</aside>");
    try expectRender(&comps, "extends \"layout\"\n<p>{ a }</p>{ slot_side }<em>{ b }</em>", .{ .a = "<1>", .b = "<2>" }, "<main><p>&lt;1&gt;</p></main><aside><em>&lt;2&gt;</em></aside>");
}

// ── a render that fails half way ────────────────────────────────────────

test "layout: a page that fails after writing part of itself leaves nothing allocated" {
    var comps: Comps = .{};
    defer comps.deinit();
    try comps.add("layout", "<html><head>{ slot_header }</head><body>{ slot }</body></html>");
    try comps.add("Loop", "<div><Loop /></div>");
    // Some output in the default slot, a named slot, more output, and then
    // a component that never ends: the testing allocator reports whatever
    // the failed render kept.
    const page =
        \\extends "layout"
        \\<p>before</p>
        \\{ slot_header }
        \\<title>{ title }</title>
        \\<Loop />
    ;
    try t.expectError(error.ComponentDepthExceeded, renderWith(&comps, page, .{ .title = "T" }));
}

test "layout: a page that extends a layout nobody registered renders alone (and says so in the log)" {
    var comps: Comps = .{};
    defer comps.deinit();
    try expectRender(&comps, "extends \"nowhere\"\n<p>{ a }</p>", .{ .a = "1" }, "<p>1</p>");
}

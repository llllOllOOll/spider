const std = @import("std");
const Template = @import("template.zig").Template;

test "basic interpolation" {
    const alc = std.testing.allocator;
    const template_str = "Hello { name }!";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .name = "World" };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Hello World!", result);
}

test "coalescing ?? with missing value" {
    const alc = std.testing.allocator;
    const template_str = "Hello { name ?? \"Guest\" }!";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{}, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Hello Guest!", result);
}

test "coalescing ?? with present value" {
    const alc = std.testing.allocator;
    const template_str = "Hello { name ?? \"Guest\" }!";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .name = "Seven" }, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Hello Seven!", result);
}

test "coalescing ?? with empty string" {
    const alc = std.testing.allocator;
    const template_str = "{ title ?? \"Default Title\" }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .title = "" }, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Default Title", result);
}

test "coalescing ?? with nested field" {
    const alc = std.testing.allocator;
    const template_str = "{ user.name ?? \"Anonymous\" }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{}, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Anonymous", result);
}

test "if true" {
    const alc = std.testing.allocator;
    const template_str = "if (show) { <p>yes</p> }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .show = true };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("<p>yes</p>", result);
}

test "if false" {
    const alc = std.testing.allocator;
    const template_str = "if (show) { <p>yes</p> }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .show = false };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "if else false" {
    const alc = std.testing.allocator;
    const template_str = "if (x) { yes } else { no }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .x = false };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("no", result);
}

test "for loop" {
    const alc = std.testing.allocator;
    const Item = struct { name: []const u8 };
    const items = &[_]Item{ .{ .name = "A" }, .{ .name = "B" } };
    const template_str = "for (items) |i| { { i.name } }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .items = items };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "for loop with struct objects" {
    const alc = std.testing.allocator;
    const User = struct { name: []const u8, email: []const u8 };
    const users = &[_]User{
        .{ .name = "Alice", .email = "alice@test.com" },
        .{ .name = "Bob", .email = "bob@test.com" },
    };
    const template_str = "for (users) |user| { { user.name } - { user.email } }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const context = .{ .users = users };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("Alice - alice@test.comBob - bob@test.com", result);
}

test "if inside for body" {
    const alc = std.testing.allocator;
    const Item = struct { name: []const u8, flag: bool };
    const items = &[_]Item{
        .{ .name = "A", .flag = true },
        .{ .name = "B", .flag = false },
    };
    const template_str = "for (items) |i| { if (i.flag) { { i.name } } }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .items = items }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "B") == null);
}

test "component self-closing" {
    const alc = std.testing.allocator;
    const header_html = "<header>{ title }</header>";
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "Header"), try alc.dupe(u8, header_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    const template_str = "<Header title=\"{ page_title }\" />";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const context = .{ .page_title = "My Page" };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("<header>My Page</header>", result);
}

test "component with slot" {
    const alc = std.testing.allocator;
    const layout_html = "<div>{ slot }</div>";
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "Layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    const template_str = "<Layout><p>Content</p></Layout>";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const context = .{};
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("<div><p>Content</p></div>", result);
}

test "extends layout" {
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html = "extends \"layout\"\n<p>Page Content</p>";
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;
    const context = .{};
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("<html><body><p>Page Content</p></body></html>", result);
}

test "if inside for with boolean field" {
    const alc = std.testing.allocator;
    const User = struct { name: []const u8, active: bool };
    const users = &[_]User{
        .{ .name = "Alice", .active = true },
        .{ .name = "Bob", .active = false },
        .{ .name = "Charlie", .active = true },
    };
    const template_str =
        \\for (users) |user| {
        \\    if (user.active) {
        \\        <li class="active">{ user.name }</li>
        \\    } else {
        \\        <li class="inactive">{ user.name }</li>
        \\    }
        \\}
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .users = users }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"active\">Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"inactive\">Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"active\">Charlie") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"inactive\">Alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "class=\"active\">Bob") == null);
}

test "for loop with string slice - direct capture" {
    const alc = std.testing.allocator;
    const tags = &[_][]const u8{ "zig", "htmx", "spider" };
    const template_str =
        \\for (tags) |tag| {
        \\    <li>{ tag }</li>
        \\}
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .tags = tags }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>zig</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>htmx</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>spider</li>") != null);
}

test "named slots" {
    const alc = std.testing.allocator;
    const layout_str =
        \\<html>
        \\<head><title>{ title }</title></head>
        \\<body>
        \\<header>{ slot_header }</header>
        \\<nav>{ slot_sidebar }</nav>
        \\<main>{ slot }</main>
        \\</body>
        \\</html>
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_str));
    const view_str =
        \\extends "layout"
        \\{ slot_header }
        \\<h1>My Title</h1>
        \\{ slot_sidebar }
        \\<a href="/">Home</a>
        \\<p>Content here</p>
    ;
    var tmpl = try Template.init(alc, view_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const result = try tmpl.render(.{ .title = "Test" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<title>Test</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "My Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Home") != null);
}

test "component slot resolves parent context" {
    const alc = std.testing.allocator;
    const card_str = "<div class=\"card\"><h2>{ title }</h2><div class=\"body\">{ slot }</div></div>";
    var components = std.StringHashMapUnmanaged([]const u8){};
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    try components.put(alc, try alc.dupe(u8, "Card"), try alc.dupe(u8, card_str));
    const template_str =
        \\<Card title="Counter">
        \\<p>Count: { count }</p>
        \\</Card>
        \\<Card title="Users">
        \\<ul>
        \\for (users) |user| {
        \\<li>{ user.name }</li>
        \\}
        \\</ul>
        \\</Card>
    ;
    const User = struct { name: []const u8 };
    const users = &[_]User{ .{ .name = "Alice" }, .{ .name = "Bob" } };
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const result = try tmpl.render(.{ .count = 42, .users = users }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h2>Counter</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h2>Users</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Count: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>Alice</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>Bob</li>") != null);
}

test "quoted string literal in if body" {
    const alc = std.testing.allocator;
    const template_str =
        \\<span class="{ if (active) { "text-green-400" } else { "text-zinc-500" } }">label</span>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result_true = try tmpl.render(.{ .active = true }, alc);
    defer alc.free(result_true);
    try std.testing.expect(std.mem.indexOf(u8, result_true, "text-green-400") != null);
    const result_false = try tmpl.render(.{ .active = false }, alc);
    defer alc.free(result_false);
    try std.testing.expect(std.mem.indexOf(u8, result_false, "text-zinc-500") != null);
}

test "script tag content not processed as template" {
    const alc = std.testing.allocator;
    const template_str =
        \\<html><head>
        \\<script>
        \\function appState() { return { drawerOpen: false }; }
        \\</script>
        \\</head><body>{ greeting }</body></html>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .greeting = "Hello" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "drawerOpen: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "double braces passthrough - single expression" {
    const alc = std.testing.allocator;
    const template_str = "Hello { name }, mode: {{dark}}";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .name = "World" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello World") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{dark}") != null);
}

test "double braces passthrough - alpine x-data" {
    const alc = std.testing.allocator;
    const template_str = "<div x-data=\"{{open: false}}\">{ slot }</div>";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .slot = "content" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "{open: false}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "content") != null);
}

test "escaped braces survive extends layout slot re-parsing" {
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html =
        \\extends "layout"
        \\<div x-data="{{ message: 'waiting...' }}">
        \\  <p x-html="message"></p>
        \\</div>
        \\<script>
        \\ws.onmessage = (e) => {{ message = e.data }};
        \\</script>
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;
    const result = try tmpl.render(.{ .message = "Hello" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "{ message: 'waiting...' }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{ message = e.data }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<p x-html=\"message\">") != null);
}

test "else if - single chain with final else" {
    // if + one else if + else: the only supported chaining depth.
    const alc = std.testing.allocator;
    const template_str = "if (s == \"a\") { A } else if (s == \"b\") { B } else { C }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const ra = try tmpl.render(.{ .s = "a" }, alc);
    defer alc.free(ra);
    try std.testing.expectEqualStrings("A", ra);
    const rb = try tmpl.render(.{ .s = "b" }, alc);
    defer alc.free(rb);
    try std.testing.expectEqualStrings("B", rb);
    const rc = try tmpl.render(.{ .s = "z" }, alc);
    defer alc.free(rc);
    try std.testing.expectEqualStrings("C", rc);
}

test "else if - multiple branches in for loop (status translation)" {
    // Desired: each status value renders its clean translation with no leaked text.
    // Currently FAILS: parseIf handles exactly one else-if; branches beyond the
    // second are split into separate top-level nodes, causing "else " to leak into
    // the output and the else fallback to render for every iteration.
    const alc = std.testing.allocator;
    const Item = struct { status: []const u8 };
    const items = &[_]Item{
        .{ .status = "in_progress" },
        .{ .status = "open" },
        .{ .status = "resolved" },
        .{ .status = "other" },
    };
    const template_str =
        \\for (items) |t| {
        \\<span>if (t.status == "in_progress") { Em execução } else if (t.status == "open") { Aberto } else if (t.status == "resolved") { Resolvido } else { { t.status } }</span>
        \\}
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .items = items }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<span>Em execução</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<span>Aberto</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<span>Resolvido</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<span>other</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "else") == null);
}

test "coalescing ?? inside HTML attribute" {
    const alc = std.testing.allocator;
    const template_str =
        \\<a class="tab-{ active ?? "default" }">link</a>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .active = "home" }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("<a class=\"tab-home\">link</a>", r1);
    const r2 = try tmpl.render(.{}, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("<a class=\"tab-default\">link</a>", r2);
}

test "?? empty default in HTML attribute - no extra whitespace" {
    const alc = std.testing.allocator;
    // empty-string default, val is empty string
    {
        const tmpl_str =
            \\<a class="prefix-{ val ?? "" }">link</a>
        ;
        var tmpl = try Template.init(alc, tmpl_str);
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .val = "" }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("<a class=\"prefix-\">link</a>", r);
    }
    // empty-string default, val absent
    {
        const tmpl_str =
            \\<a class="prefix-{ val ?? "" }">link</a>
        ;
        var tmpl = try Template.init(alc, tmpl_str);
        defer tmpl.deinit();
        const r = try tmpl.render(.{}, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("<a class=\"prefix-\">link</a>", r);
    }
    // "default" as default, val is empty string — must use default, no space
    {
        const tmpl_str =
            \\<a class="prefix-{ val ?? "default" }">link</a>
        ;
        var tmpl = try Template.init(alc, tmpl_str);
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .val = "" }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("<a class=\"prefix-default\">link</a>", r);
    }
    // same cases inside a for-loop body (uses parseTextNodes path, not parseInterpolation)
    {
        const Item = struct { name: []const u8, cls: []const u8 };
        const items = &[_]Item{
            .{ .name = "x", .cls = "" },
            .{ .name = "y", .cls = "active" },
        };
        const tmpl_str =
            \\for (items) |item| { <a class="tab-{ item.cls ?? "" }">{ item.name }</a> }
        ;
        var tmpl = try Template.init(alc, tmpl_str);
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .items = items }, alc);
        defer alc.free(r);
        // empty cls must produce class="tab-", not "tab- " or "tab- y"
        try std.testing.expect(std.mem.indexOf(u8, r, "<a class=\"tab-\">x</a>") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "<a class=\"tab-active\">y</a>") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "tab- ") == null);
    }
}

test "style tag content not processed as template" {
    // CSS rules contain { } which must not be treated as interpolation.
    const alc = std.testing.allocator;
    const template_str =
        \\<html><body>
        \\<style>
        \\.dashboard { padding: 16px; }
        \\.metric-val { font-size: 28px; font-weight: 500; }
        \\</style>
        \\{ greeting }
        \\</body></html>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .greeting = "Hello" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, ".dashboard { padding: 16px; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".metric-val { font-size: 28px; font-weight: 500; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello") != null);
}

test "else if - multiple branches at top level (not in for loop)" {
    const alc = std.testing.allocator;
    const template_str =
        \\if (status == "open") { <p>Aberto</p> }
        \\else if (status == "in_progress") { <p>Em execução</p> }
        \\else if (status == "resolved") { <p>Resolvido</p> }
        \\else { <p>Outro</p> }
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();

    const r1 = try tmpl.render(.{ .status = "open" }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("<p>Aberto</p>", std.mem.trim(u8, r1, " \n\r\t"));

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("<p>Em execução</p>", std.mem.trim(u8, r2, " \n\r\t"));

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expectEqualStrings("<p>Resolvido</p>", std.mem.trim(u8, r3, " \n\r\t"));

    const r4 = try tmpl.render(.{ .status = "other" }, alc);
    defer alc.free(r4);
    try std.testing.expectEqualStrings("<p>Outro</p>", std.mem.trim(u8, r4, " \n\r\t"));
}

test "else if - multiple branches with extends layout (real app path)" {
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html =
        \\extends "layout"
        \\if (status == "open") { <p>Aberto</p> }
        \\else if (status == "in_progress") { <p>Em execução</p> }
        \\else if (status == "resolved") { <p>Resolvido</p> }
        \\else { <p>Outro</p> }
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;

    const r1 = try tmpl.render(.{ .status = "open" }, alc);
    defer alc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "<p>Aberto</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "else") == null);

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "<p>Em execução</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "else") == null);

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "<p>Resolvido</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "else") == null);

    const r4 = try tmpl.render(.{ .status = "other" }, alc);
    defer alc.free(r4);
    try std.testing.expect(std.mem.indexOf(u8, r4, "<p>Outro</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r4, "else") == null);
}

test "else if - tab-indented else if chains (real file format)" {
    // Real .html files often have tab indentation. The whitespace skip after
    // a then-body must consume \t so that "else if" is still recognised.
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    // Use \t before each else-if to simulate a tab-indented file
    const page_html = "extends \"layout\"\nif (status == \"open\") { <p>Aberto</p> }\n\telse if (status == \"in_progress\") { <p>Em execu\xc3\xa7\xc3\xa3o</p> }\n\telse if (status == \"resolved\") { <p>Resolvido</p> }\n\telse { <p>Outro</p> }";
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "Em execu") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "else") == null);

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "<p>Resolvido</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "else") == null);
}

test "else if - inline style: } else if on same line" {
    // Common formatting: closing } of then-block and else if on the same line.
    const alc = std.testing.allocator;
    const template_str =
        \\if (status == "open") {
        \\  <p>Aberto</p>
        \\} else if (status == "in_progress") {
        \\  <p>Em execução</p>
        \\} else if (status == "resolved") {
        \\  <p>Resolvido</p>
        \\} else {
        \\  <p>Outro</p>
        \\}
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();

    const r1 = try tmpl.render(.{ .status = "open" }, alc);
    defer alc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "<p>Aberto</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "else") == null);

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "Em execu") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "else") == null);

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "<p>Resolvido</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "else") == null);

    const r4_inline = try tmpl.render(.{ .status = "other" }, alc);
    defer alc.free(r4_inline);
    try std.testing.expect(std.mem.indexOf(u8, r4_inline, "<p>Outro</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r4_inline, "else") == null);
}

test "else if - inline style with HTML before the if block" {
    // Reproduces the real failure: HTML text before the if/else-if chain.
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html =
        \\extends "layout"
        \\<h1>título</h1>
        \\if (status == "open") {
        \\  <p>Aberto</p>
        \\} else if (status == "in_progress") {
        \\  <p>Em execução</p>
        \\} else if (status == "resolved") {
        \\  <p>Resolvido</p>
        \\} else {
        \\  <p>Outro</p>
        \\}
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "Em execu") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "else") == null);

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "<p>Resolvido</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "else") == null);
}

test "else if - inline style with extends layout and leading indent" {
    // Exact user format: 2-space indent on every line including the } lines,
    // combined with extends "layout". Tests both inline } else if and the extends path.
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html =
        \\extends "layout"
        \\  if (status == "open") {
        \\    <p>Aberto</p>
        \\  } else if (status == "in_progress") {
        \\    <p>Em execução</p>
        \\  } else if (status == "resolved") {
        \\    <p>Resolvido</p>
        \\  } else {
        \\    <p>Outro</p>
        \\  }
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;

    const r1 = try tmpl.render(.{ .status = "open" }, alc);
    defer alc.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "<p>Aberto</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "else") == null);

    const r2 = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "Em execu") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "else") == null);

    const r3 = try tmpl.render(.{ .status = "resolved" }, alc);
    defer alc.free(r3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "<p>Resolvido</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3, "else") == null);

    const r4 = try tmpl.render(.{ .status = "other" }, alc);
    defer alc.free(r4);
    try std.testing.expect(std.mem.indexOf(u8, r4, "<p>Outro</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r4, "else") == null);
}

test "else if - full user template with three sections" {
    // Exact copy of the user's failing template (three sections in one page).
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const page_html =
        \\extends "layout"
        \\
        \\<h1>else if múltiplo</h1>
        \\if (status == "open") {
        \\  <p>Aberto</p>
        \\} else if (status == "in_progress") {
        \\  <p>Em execução</p>
        \\} else if (status == "resolved") {
        \\  <p>Resolvido</p>
        \\} else {
        \\  <p>Outro</p>
        \\}
        \\
        \\<h1>depois</h1>
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, page_html);
    defer tmpl.deinit();
    tmpl.components = components;

    const r = try tmpl.render(.{ .status = "in_progress" }, alc);
    defer alc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "Em execu") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\nelse\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, ">else<") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "Outro") == null);
}

test "double braces with JS methods inside for body" {
    // Regression: {{ }} containing JS method bodies (nested { }) inside a for loop
    // was being split at the second { (which starts with "{ " matching interpolation).
    const alc = std.testing.allocator;
    const Item = struct { id: []const u8, active: bool };
    const items = &[_]Item{
        .{ .id = "a1", .active = true },
        .{ .id = "b2", .active = false },
    };
    const template_str =
        \\for (items) |item| {
        \\  if (item.active) {
        \\    <div x-data="{{ count: 0, inc() { this.count++; }, dec() { if (this.count > 0) { this.count--; } } }}">{ item.id }</div>
        \\  }
        \\}
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .items = items }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "{ count: 0, inc() { this.count++; }, dec() { if (this.count > 0) { this.count--; } } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, ">a1<") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "b2") == null);
}

// test "loop.index - 0-based index available inside for" {
//     const alc = std.testing.allocator;
//     const tmpl_str =
//         \\for (items) |item| { <div>{ loop.index }-{ item }</div> }
//     ;
//     var tmpl = try Template.init(alc, tmpl_str);
//     defer tmpl.deinit();
//     const r = try tmpl.render(.{ .items = [_][]const u8{ "Alpha", "Beta", "Gamma" } }, alc);
//     defer alc.free(r);
//     try std.testing.expect(std.mem.indexOf(u8, r, "<div>0-Alpha</div>") != null);
//     try std.testing.expect(std.mem.indexOf(u8, r, "<div>1-Beta</div>") != null);
//     try std.testing.expect(std.mem.indexOf(u8, r, "<div>2-Gamma</div>") != null);
// }

test "loop.index - 0-based index available inside for" {
    const alc = std.testing.allocator;
    const tmpl_str =
        \\for (items) |item| { <div>{ loop.index }-{ item }</div> }
    ;
    var tmpl = try Template.init(alc, tmpl_str);
    defer tmpl.deinit();

    const r = try tmpl.render(.{ .items = [_][]const u8{ "Alpha", "Beta", "Gamma" } }, alc);
    defer alc.free(r);

    try std.testing.expectEqualStrings(
        "<div>0-Alpha</div><div>1-Beta</div><div>2-Gamma</div>",
        r,
    );
}

test "loop.index - correct with struct objects" {
    const alc = std.testing.allocator;
    const tmpl_str =
        \\for (items) |item| { <li>{ loop.index }: { item.name }</li> }
    ;
    var tmpl = try Template.init(alc, tmpl_str);
    defer tmpl.deinit();
    const Item = struct { name: []const u8 };
    const r = try tmpl.render(.{ .items = [_]Item{ .{ .name = "Alice" }, .{ .name = "Bob" } } }, alc);
    defer alc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "<li>0: Alice</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<li>1: Bob</li>") != null);
}

test "loop.index - does not leak outside for" {
    const alc = std.testing.allocator;
    const tmpl_str =
        \\for (items) |item| { { item } }
        \\{ loop.index }
    ;
    var tmpl = try Template.init(alc, tmpl_str);
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .items = [_][]const u8{"x"} }, alc);
    defer alc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "0") == null);
}

test "logical and operator" {
    const alc = std.testing.allocator;
    // both true → renders
    {
        var tmpl = try Template.init(alc, "if (a and b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = true, .b = true }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
    // one false → does not render
    {
        var tmpl = try Template.init(alc, "if (a and b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = true, .b = false }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("", r);
    }
    // both false → does not render
    {
        var tmpl = try Template.init(alc, "if (a and b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = false, .b = false }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("", r);
    }
}

test "logical or operator" {
    const alc = std.testing.allocator;
    // both false → does not render
    {
        var tmpl = try Template.init(alc, "if (a or b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = false, .b = false }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("", r);
    }
    // one true → renders
    {
        var tmpl = try Template.init(alc, "if (a or b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = false, .b = true }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
    // both true → renders
    {
        var tmpl = try Template.init(alc, "if (a or b) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = true, .b = true }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
}

test "logical and with == comparisons" {
    const alc = std.testing.allocator;
    {
        var tmpl = try Template.init(alc,
            \\if (a == "x" and b == "y") { yes }
        );
        defer tmpl.deinit();
        const r1 = try tmpl.render(.{ .a = "x", .b = "y" }, alc);
        defer alc.free(r1);
        try std.testing.expectEqualStrings("yes", r1);
        const r2 = try tmpl.render(.{ .a = "x", .b = "z" }, alc);
        defer alc.free(r2);
        try std.testing.expectEqualStrings("", r2);
    }
}

test "logical or with == comparisons" {
    const alc = std.testing.allocator;
    {
        var tmpl = try Template.init(alc,
            \\if (a == "x" or b == "y") { yes }
        );
        defer tmpl.deinit();
        const r1 = try tmpl.render(.{ .a = "z", .b = "y" }, alc);
        defer alc.free(r1);
        try std.testing.expectEqualStrings("yes", r1);
        const r2 = try tmpl.render(.{ .a = "z", .b = "z" }, alc);
        defer alc.free(r2);
        try std.testing.expectEqualStrings("", r2);
    }
}

test "logical and with numeric comparisons" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "if (count > 0 and count < 10) { yes }");
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .count = 5 }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("yes", r1);
    const r2 = try tmpl.render(.{ .count = 0 }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("", r2);
    const r3 = try tmpl.render(.{ .count = 10 }, alc);
    defer alc.free(r3);
    try std.testing.expectEqualStrings("", r3);
}

test "and/or precedence: and binds tighter than or" {
    const alc = std.testing.allocator;
    // a or (b and c): b=false, c=false, a=true → true
    {
        var tmpl = try Template.init(alc, "if (a or b and c) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = true, .b = false, .c = false }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
    // a or (b and c): a=false, b=true, c=true → true
    {
        var tmpl = try Template.init(alc, "if (a or b and c) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = false, .b = true, .c = true }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
    // a or (b and c): a=false, b=true, c=false → false
    {
        var tmpl = try Template.init(alc, "if (a or b and c) { yes }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .a = false, .b = true, .c = false }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("", r);
    }
}

test "and/or no false positives with embedded substrings" {
    const alc = std.testing.allocator;
    // "standard" contains "and", "order" contains "or" — must not trigger operators
    {
        var tmpl = try Template.init(alc,
            \\if (status == "standard") { yes }
        );
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .status = "standard" }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
    {
        var tmpl = try Template.init(alc,
            \\if (status == "order") { yes }
        );
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .status = "order" }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("yes", r);
    }
}

test "unary not operator - true/false" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "if (!show) { yes }");
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .show = false }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("yes", r1);
    const r2 = try tmpl.render(.{ .show = true }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "unary not operator - double negation" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "if (!!show) { yes }");
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .show = true }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("yes", r1);
    const r2 = try tmpl.render(.{ .show = false }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "unary not operator - precedence with and" {
    const alc = std.testing.allocator;
    // !a and b: a=false negates to true, b=true → renders
    var tmpl = try Template.init(alc, "if (!a and b) { yes }");
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .a = false, .b = true }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("yes", r1);
    // a=true negates to false → does not render regardless of b
    const r2 = try tmpl.render(.{ .a = true, .b = true }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "unary not operator - precedence with or" {
    const alc = std.testing.allocator;
    // !a or b: a=true negates to false, b=false → does not render
    var tmpl = try Template.init(alc, "if (!a or b) { yes }");
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .a = true, .b = false }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("", r1);
    // a=false negates to true → renders regardless of b
    const r2 = try tmpl.render(.{ .a = false, .b = false }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("yes", r2);
}

test "unary not operator - does not break != operator" {
    const alc = std.testing.allocator;
    // "!=" contains "!" but never as the leading character of a trimmed
    // condition (there's always a left operand before it), so it must
    // keep working exactly as before this feature was added.
    var tmpl = try Template.init(alc,
        \\if (role != "council") { yes }
    );
    defer tmpl.deinit();
    const r1 = try tmpl.render(.{ .role = "admin" }, alc);
    defer alc.free(r1);
    try std.testing.expectEqualStrings("yes", r1);
    const r2 = try tmpl.render(.{ .role = "council" }, alc);
    defer alc.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "list index access [0] in interpolation" {
    const alc = std.testing.allocator;
    const Item = struct { name: []const u8, value: i64 };
    const items = &[_]Item{
        .{ .name = "first", .value = 42 },
        .{ .name = "second", .value = 99 },
    };
    {
        var tmpl = try Template.init(alc, "{ items[0].name }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .items = items }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("first", r);
    }
    {
        var tmpl = try Template.init(alc, "{ items[1].name }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .items = items }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("second", r);
    }
    {
        var tmpl = try Template.init(alc, "{ items[0].value }");
        defer tmpl.deinit();
        const r = try tmpl.render(.{ .items = items }, alc);
        defer alc.free(r);
        try std.testing.expectEqualStrings("42", r);
    }
}

test "call syntax and script-tag attributes work inside if blocks too" {
    // Regression: parseTextNodes (used for if/for bodies) is a separate
    // code path from Parser.parseInterpolation/parseText — both the call
    // dispatch and the script/style attribute-vs-body split need to work
    // there too, not just at the top level.
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc,
        \\if (show) {
        \\  <script src='{ url }'>const x = { ignored };</script>
        \\}
    );
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .show = true, .url = "/app.js" }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings(
        "\n  <script src='/app.js'>const x = { ignored };</script>\n",
        r,
    );
}

test "call syntax with no registered helper renders empty" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "before[{ asset_url(\"app.css\") }]after");
    defer tmpl.deinit();
    const r = try tmpl.render(.{}, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("before[]after", r);
}

test "script tag attributes are still interpolated" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "<script src='{ url }'></script>");
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .url = "/app.js" }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("<script src='/app.js'></script>", r);
}

test "script tag body is still raw (not template-processed)" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "<script>const x = { url };</script>");
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .url = "ignored" }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("<script>const x = { url };</script>", r);
}

test "style tag attributes are still interpolated, body stays raw" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc, "<style data-theme='{ theme }'>[x-cloak] { display: none; }</style>");
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .theme = "dark" }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("<style data-theme='dark'>[x-cloak] { display: none; }</style>", r);
}

test "call syntax does not regress plain variable interpolation" {
    const alc = std.testing.allocator;
    // Names/paths that could superficially resemble a call must still
    // resolve as plain variables when there's no "(" right after them.
    var tmpl = try Template.init(alc, "{ user.name }");
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .user = .{ .name = "Seven" } }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("Seven", r);
}

test "inline component - self-closing invocation" {
    // Define an inline component at root level, then invoke it via self-closing tag.
    const alc = std.testing.allocator;
    const template_str =
        \\<Header>
        \\<h1>{ title }</h1>
        \\</Header>
        \\<div class="page">
        \\<Header title="{ page_title }" />
        \\</div>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .page_title = "My Page" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>My Page</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<div class=\"page\">") != null);
    // The definition block itself should NOT render at the definition site.
    try std.testing.expect(std.mem.indexOf(u8, result, "Header") == null);
}

test "inline component - with slot" {
    // Define an inline component with a { slot }, invoke it with content.
    const alc = std.testing.allocator;
    const template_str =
        \\<Card>
        \\<div class="card"><h2>{ title }</h2><div class="body">{ slot }</div></div>
        \\</Card>
        \\<div>
        \\<Card title="Notice">
        \\<p>Hello</p>
        \\</Card>
        \\</div>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .title = "ignored" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h2>Notice</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<p>Hello</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<div class=\"card\">") != null);
}

test "inline component - resolves parent context" {
    // The inline component's body resolves variables from the caller's context.
    const alc = std.testing.allocator;
    const template_str =
        \\<List>
        \\<ul>
        \\for (items) |item| {
        \\<li>{ item.name }</li>
        \\}
        \\</ul>
        \\</List>
        \\<List />
    ;
    const Item = struct { name: []const u8 };
    const items = &[_]Item{ .{ .name = "Alice" }, .{ .name = "Bob" } };
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .items = items }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>Alice</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<li>Bob</li>") != null);
}

test "multiple inline components in same file" {
    // Two inline components defined and invoked in one template.
    const alc = std.testing.allocator;
    const template_str =
        \\<Header>
        \\<h1>{ title }</h1>
        \\</Header>
        \\<Footer>
        \\<p>{ copyright }</p>
        \\</Footer>
        \\<Header title="{ page_title }" />
        \\<Footer />
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.render(.{ .page_title = "Welcome", .copyright = "2024" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>Welcome</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<p>2024</p>") != null);
}

test "inline component does not shadow existing file component" {
    // File component "Title" exists. <Title>...</Title> at root level is an
    // invocation (not a definition) since the name is already registered.
    const alc = std.testing.allocator;
    const file_component = "<h1>FILE: { text }</h1><div>{ slot }</div>";
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "Title"), try alc.dupe(u8, file_component));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    const template_str =
        \\<div><Title>
        \\<p>slot content</p>
        \\</Title></div>
        \\<Title text="{ msg }" />
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const result = try tmpl.render(.{ .msg = "hello" }, alc);
    defer alc.free(result);
    // File component renders (inline does not shadow).
    try std.testing.expect(std.mem.indexOf(u8, result, "FILE: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "slot content") != null);
}

test "renderFragment renders inline component with for loop and context" {
    // renderFragment("DataList", data) should render the inline component's
    // template with the provided context, without layout or other nodes.
    const alc = std.testing.allocator;
    const template_str =
        \\<DataList>
        \\<ul>
        \\for (items) |item| {
        \\<li>{ item.name }</li>
        \\}
        \\</ul>
        \\</DataList>
        \\<p>other content</p>
    ;
    const Item = struct { name: []const u8 };
    const items = &[_]Item{ .{ .name = "Alice" }, .{ .name = "Bob" } };
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();

    const fragment = try tmpl.renderFragment("DataList", .{ .items = items }, alc);
    defer alc.free(fragment);

    // Fragment must contain the list items from the inline component
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<li>Alice</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<li>Bob</li>") != null);
    // Fragment must NOT contain "other content" (outside the component)
    try std.testing.expect(std.mem.indexOf(u8, fragment, "other content") == null);
}

test "renderFragment resolves context variables" {
    // renderFragment should resolve variables passed via context.
    const alc = std.testing.allocator;
    const template_str =
        \\<Greeting>
        \\<h1>{ message }, { name }!</h1>
        \\</Greeting>
        \\<p>unrelated</p>
    ;
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    const result = try tmpl.renderFragment("Greeting", .{ .message = "Hello", .name = "World" }, alc);
    defer alc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>Hello, World!</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "unrelated") == null);
}

test "renderFragment returns error on unknown component" {
    const alc = std.testing.allocator;
    const template_str = "<p>nothing here</p>";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    try std.testing.expectError(error.ComponentNotFound, tmpl.renderFragment("NonExistent", .{}, alc));
}

test "renderFragment does not include layout" {
    // renderFragment should NOT extend layout, even if the template has extends.
    const alc = std.testing.allocator;
    const layout_html = "<html><body>{ slot }</body></html>";
    const template_str =
        \\extends "layout"
        \\<MyComp>
        \\<p>fragment content</p>
        \\</MyComp>
        \\<p>page content</p>
    ;
    var components = std.StringHashMapUnmanaged([]const u8){};
    try components.put(alc, try alc.dupe(u8, "layout"), try alc.dupe(u8, layout_html));
    defer {
        var iter = components.iterator();
        while (iter.next()) |entry| {
            alc.free(entry.key_ptr.*);
            alc.free(entry.value_ptr.*);
        }
        components.deinit(alc);
    }
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();
    tmpl.components = components;
    const fragment = try tmpl.renderFragment("MyComp", .{}, alc);
    defer alc.free(fragment);
    // Must contain the fragment content
    try std.testing.expect(std.mem.indexOf(u8, fragment, "fragment content") != null);
    // Must NOT contain layout elements
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<html>") == null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "<body>") == null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "page content") == null);
}

test "raw <script> body after leading text inside a for body is not interpolated" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc,
        \\for (items) |i| {
        \\  <p>{ i }</p><script>let o = { a: 1 };</script>
        \\}
    );
    defer tmpl.deinit();
    const items = [_][]const u8{"x"};
    const r = try tmpl.render(.{ .items = &items }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("\n  <p>x</p><script>let o = { a: 1 };</script>\n", r);
}

test "raw <style> body after leading text inside an if body is not interpolated" {
    const alc = std.testing.allocator;
    var tmpl = try Template.init(alc,
        \\if (show) {
        \\  text <style>.a { color: red; }</style> { name }
        \\}
    );
    defer tmpl.deinit();
    const r = try tmpl.render(.{ .show = true, .name = "n" }, alc);
    defer alc.free(r);
    try std.testing.expectEqualStrings("\n  text <style>.a { color: red; }</style> n\n", r);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

pub const Node = @import("zmd/Node.zig");
pub const Ast = @import("zmd/Ast.zig");
pub const tokens = @import("zmd/tokens.zig");
pub const Formatters = @import("zmd/Formatters.zig");

pub const default_formatters = Formatters.default;

pub fn parse(
    allocator: Allocator,
    input: []const u8,
    formatters: Formatters,
) ![]const u8 {
    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var nodes: ArrayList(*Node) = .empty;
    defer nodes.deinit(alloc);

    const normalized = try normalizeInput(alloc, input);
    var ast: Ast = try .init(alloc, normalized);
    defer ast.deinit(alloc);
    const root = try ast.parse(alloc);
    try nodes.append(alloc, root);

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const fmt = if (formatters.root == Formatters.Default.root)
        Formatters{ .root = Formatters.Default.root_partial }
    else
        formatters;

    try nodes.items[0].toHtml(
        alloc,
        normalized,
        &aw.writer,
        0,
        fmt,
    );

    return allocator.dupe(u8, try aw.toOwnedSlice());
}

pub fn parseFull(
    allocator: Allocator,
    input: []const u8,
    formatters: Formatters,
) ![]const u8 {
    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var nodes: ArrayList(*Node) = .empty;
    defer nodes.deinit(alloc);

    const normalized = try normalizeInput(alloc, input);
    var ast: Ast = try .init(alloc, normalized);
    defer ast.deinit(alloc);
    const root = try ast.parse(alloc);
    try nodes.append(alloc, root);

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const fmt = if (formatters.root == Formatters.Default.root_partial)
        Formatters{ .root = Formatters.Default.root }
    else
        formatters;

    try nodes.items[0].toHtml(
        alloc,
        normalized,
        &aw.writer,
        0,
        fmt,
    );

    return allocator.dupe(u8, try aw.toOwnedSlice());
}

// Normalize text to unix-style linebreaks and ensure ending with a linebreak to simplify
// Windows compatibility.
fn normalizeInput(allocator: Allocator, input: []const u8) ![]const u8 {
    const output = try std.mem.replaceOwned(u8, allocator, input, "\r\n", "\n");
    if (std.mem.endsWith(u8, output, "\n")) return output;

    return std.mem.concat(allocator, u8, &[_][]const u8{ output, "\n" });
}

const testing = std.testing;

test "zmd renders h3" {
    const input = "### Hello";
    const html = try parse(testing.allocator, input, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<h3>Hello</h3>") != null);
}

test "zmd renders bold" {
    const input = "**bold**";
    const html = try parse(testing.allocator, input, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<b>bold</b>") != null);
}

test "zmd renders list" {
    const input = "- Lunas\n- Maylla";
    const html = try parse(testing.allocator, input, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<li>") != null);
}

test "zmd renders fenced code block" {
    const input = "```zig\nconst x = 1;\n```";
    const html = try parse(testing.allocator, input, .{});
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "<code") != null);
    try testing.expect(std.mem.indexOf(u8, html, "const x = 1;") != null);
}

test "partial: no html wrapper" {
    const input = "# Hello";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<html>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<body>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<main>") == null);
}

test "partial: inline code uses <code> tag" {
    const input = "use `spider.pg` here";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<code>spider.pg</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "font-family") == null);
}

test "partial: fenced code block structure" {
    const input = "```zig\nvar x = 1;\n```";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"code-block\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"code-block-bar\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "var x = 1;") != null);
}

test "full page: has html wrapper" {
    const input = "# Hello";
    const html = try parseFull(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<body>") != null);
}

test "preserves {% raw %} blocks untouched" {
    const input = "Some text\n{% raw %}{{ not_a_var }}{% endraw %}\nMore text";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ not_a_var }}") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{% raw %}") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{% endraw %}") != null);
}

test "preserves {% raw %} with template tags inside" {
    const input = "Example:\n{% raw %}\n{% if x %}yes{% endif %}\n{% endraw %}";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "{% if x %}yes{% endif %}") != null);
}

test "preserves {% raw %} with code block" {
    const input = "{% raw %}\n```html\n{% for item in items %}{{ item }}{% endfor %}\n```\n{% endraw %}";
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "{% for item in items %}") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ item }}") != null);
}

test "zmd handles raw block alone" {
    const input = "{% raw %}{{ title }}{% endraw %}";
    const result = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "{% raw %}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{% endraw %}") != null);
}

test "zmd handles raw block with surrounding text" {
    const input = "Some text\n{% raw %}{{ title }}{% endraw %}\nMore text";
    const result = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "{% raw %}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{% endraw %}") != null);
}

fn expectHtml(input: []const u8, expected: []const u8) !void {
    const html = try parse(std.testing.allocator, input, .{});
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, html, "\n"));
}

test "a link's address and text are escaped" {
    try expectHtml(
        "[<b>docs</b>](https://example.com/?a=1&b=2)",
        "<p><a href=\"https://example.com/?a=1&amp;b=2\">&lt;b&gt;docs&lt;/b&gt;</a></p>",
    );
    try expectHtml(
        "[x](https://a\" onmouseover=\"alert)",
        "<p><a href=\"https://a&quot; onmouseover=&quot;alert\">x</a></p>",
    );
}

test "a link keeps only addresses that are safe to follow" {
    try expectHtml("[a](/posts/1) [b](#top) [c](mailto:a@b.c) [d](http://x.y)", "<p><a href=\"/posts/1\">a</a> <a href=\"#top\">b</a> <a href=\"mailto:a@b.c\">c</a> <a href=\"http://x.y\">d</a></p>");
    try expectHtml("[e](docs/page.html)", "<p><a href=\"docs/page.html\">e</a></p>");
    try expectHtml("[click](javascript:alert)", "<p>click</p>");
    try expectHtml("[click](JavaScript:alert)", "<p>click</p>");
    try expectHtml("[click](data:text/html;base64,AAAA)", "<p>click</p>");
    try expectHtml("[click](//evil.example)", "<p><a href=\"//evil.example\">click</a></p>");
}

test "an image's address and title are escaped" {
    try expectHtml(
        "![a \"b\" <i>](https://example.com/i.png)",
        "<p><img src=\"https://example.com/i.png\" title=\"a &quot;b&quot; &lt;i&gt;\"></p>",
    );
    try expectHtml("![pic](javascript:alert)", "<p>pic</p>");
}

test "the language of a code block is escaped" {
    const html = try parse(std.testing.allocator, "```\"><script>alert(1)</script>\nx\n```", .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
}

test "a raw block keeps template tags but not HTML" {
    const html = try parse(std.testing.allocator, "{% raw %}{{ x }}<script>alert(1)</script>{% endraw %}", .{});
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ x }}") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "text escapes quotes too" {
    try expectHtml("say \"hi\" & <go>", "<p>say &quot;hi&quot; &amp; &lt;go&gt;</p>");
}

test "a line that starts with > is a blockquote" {
    try expectHtml("> Mind the **gap**.", "<blockquote>Mind the <b>gap</b>.</blockquote>");
    try expectHtml("a > b", "<p>a &gt; b</p>");
}

test "consecutive > lines are one blockquote" {
    try expectHtml("> one\n> two\n\nafter", "<blockquote>one\ntwo</blockquote>\n<p>after</p>");
}

//! The HTML of each Markdown element (`spider.zmd.Formatters`): one function
//! per kind of element, each with a default. Pass `.{}` to `zmd.parse` for
//! the defaults, or name the fields to replace.

const std = @import("std");
const Node = @import("Node.zig");
const Formatters = @This();
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
/// A formatter: gets one element and returns its HTML. `node.content` is the
/// inner HTML, already rendered and escaped; `node.href`, `node.title` and
/// `node.meta` are as the author typed them and must be escaped with
/// `escape` (and an address checked with `safeAddress`). The result must be
/// allocated with the given allocator: the caller frees it.
pub const Handler = fn (Allocator, Node) Allocator.Error![]const u8;

// internal: an empty `Default`; only `zmd.default_formatters` names it.
pub const default = Default{};

/// The whole document. The default returns the content as a fragment.
root: Handler = Default.root_partial,
/// A fenced code block; `node.meta` is its language, if any.
block: Handler = Default.block,
/// `[text](address)`: `node.title` is the text, `node.href` the address.
link: Handler = Default.link,
/// `![title](address)`: `node.title` and `node.href`.
image: Handler = Default.image,
h1: Handler = Default.h1,
h2: Handler = Default.h2,
h3: Handler = Default.h3,
h4: Handler = Default.h4,
h5: Handler = Default.h5,
h6: Handler = Default.h6,
/// A line starting with `> `.
blockquote: Handler = Default.blockquote,
/// `**text**`.
bold: Handler = Default.bold,
/// `_text_` or `*text*`.
italic: Handler = Default.italic,
unordered_list: Handler = Default.unordered_list,
ordered_list: Handler = Default.ordered_list,
list_item: Handler = Default.list_item,
/// Inline code between backticks.
code: Handler = Default.code,
/// A top-level paragraph.
paragraph: Handler = Default.paragraph,
/// Text between `{% raw %}` and `{% endraw %}`, kept as typed (escaped).
raw_block: Handler = Default.raw_block,
/// Every element without a field of its own (plain text, nested paragraphs).
default_handler: Handler = Default.default,

/// The default formatters, one per field of `Formatters`.
pub const Default = struct {
    /// A whole HTML document around the content; `zmd.parseFull` uses it.
    pub fn root(allocator: Allocator, node: Node) ![]const u8 {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <meta charset="utf8">
            \\</head>
            \\<body>
            \\<main>
            \\{s}</main>
            \\</body>
            \\</html>
            \\
        ;
        const content = try joinQuotes(allocator, node.content);
        defer allocator.free(content);
        return allocPrint(allocator, html, .{content});
    }

    /// The content alone; `zmd.parse` uses it.
    pub fn root_partial(allocator: Allocator, node: Node) ![]const u8 {
        return joinQuotes(allocator, node.content);
    }

    /// `<div class="code-block">` with `<pre><code>`, and a bar naming the language when the block has one.
    pub fn block(allocator: Allocator, node: Node) ![]const u8 {
        if (node.meta) |meta| {
            const lang = try escape(allocator, meta);
            defer allocator.free(lang);
            return allocPrint(allocator,
                \\<div class="code-block">
                \\  <div class="code-block-bar"><span class="code-block-lang">{s}</span></div>
                \\  <pre><code>{s}</code></pre>
                \\</div>
                \\
            , .{ lang, node.content });
        } else {
            return allocPrint(allocator,
                \\<div class="code-block">
                \\  <pre><code>{s}</code></pre>
                \\</div>
                \\
            , .{node.content});
        }
    }

    /// The address and the text are what the author typed: both are escaped,
    /// and an address that would run code (javascript:, data:) leaves only
    /// the text.
    pub fn link(allocator: Allocator, node: Node) ![]const u8 {
        const text = try escape(allocator, node.title.?);
        if (!safeAddress(node.href.?)) return text;
        defer allocator.free(text);
        const href = try escape(allocator, node.href.?);
        defer allocator.free(href);
        return allocPrint(allocator,
            \\<a href="{s}">{s}</a>
        , .{ href, text });
    }

    /// `<img src title>`, both escaped; an address that is not safe leaves only the title.
    pub fn image(allocator: Allocator, node: Node) ![]const u8 {
        const title = try escape(allocator, node.title.?);
        if (!safeAddress(node.href.?)) return title;
        defer allocator.free(title);
        const src = try escape(allocator, node.href.?);
        defer allocator.free(src);
        return allocPrint(allocator,
            \\<img src="{s}" title="{s}">
        , .{ src, title });
    }

    /// `<h1>`.
    pub fn h1(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h1>{s}</h1>
            \\
        , .{node.content});
    }

    /// `<h2>`.
    pub fn h2(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h2>{s}</h2>
            \\
        , .{node.content});
    }

    /// `<h3>`.
    pub fn h3(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h3>{s}</h3>
            \\
        , .{node.content});
    }

    /// `<h4>`.
    pub fn h4(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h4>{s}</h4>
            \\
        , .{node.content});
    }

    /// `<h5>`.
    pub fn h5(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h5>{s}</h5>
            \\
        , .{node.content});
    }

    /// `<h6>`.
    pub fn h6(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<h6>{s}</h6>
            \\
        , .{node.content});
    }

    /// `<blockquote>`.
    pub fn blockquote(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<blockquote>{s}</blockquote>
            \\
        , .{node.content});
    }

    /// `<b>`.
    pub fn bold(allocator: Allocator, node: Node) ![]const u8 {
        return wrap(allocator, node.content, "b");
    }

    /// `<i>`.
    pub fn italic(allocator: Allocator, node: Node) ![]const u8 {
        return wrap(allocator, node.content, "i");
    }

    /// `<ul>`.
    pub fn unordered_list(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<ul>
            \\{s}</ul>
            \\
        , .{node.content});
    }

    /// `<ol>`.
    pub fn ordered_list(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<ol>
            \\{s}</ol>
            \\
        , .{node.content});
    }

    /// `<li>`.
    pub fn list_item(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\  <li>{s}</li>
            \\
        , .{node.content});
    }

    /// `<code>`.
    pub fn code(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<code>{s}</code>
        , .{node.content});
    }

    /// `<p>`.
    pub fn paragraph(allocator: Allocator, node: Node) ![]const u8 {
        return allocPrint(allocator,
            \\<p>{s}</p>
            \\
        , .{node.content});
    }

    /// The content as it is.
    pub fn raw_block(allocator: Allocator, node: Node) ![]const u8 {
        return allocator.dupe(u8, node.content);
    }

    /// The content as it is.
    pub fn default(allocator: Allocator, node: Node) ![]const u8 {
        _ = allocator;
        return node.content;
    }
};

/// Each `> ` line is rendered as its own blockquote; lines that follow one
/// another become one. (Text never contains these tags: it is escaped.)
fn joinQuotes(allocator: Allocator, html: []const u8) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, allocator, html, "</blockquote>\n<blockquote>", "\n");
}

/// Escapes text for HTML, inside an element or a quoted attribute.
pub fn escape(allocator: Allocator, input: []const u8) Allocator.Error![]const u8 {
    var extra: usize = 0;
    for (input) |byte| extra += switch (byte) {
        '&' => 4,
        '<', '>' => 3,
        '"' => 5,
        '\'' => 4,
        else => 0,
    };
    const out = try allocator.alloc(u8, input.len + extra);
    var i: usize = 0;
    for (input) |byte| {
        const piece: []const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &.{byte},
        };
        @memcpy(out[i..][0..piece.len], piece);
        i += piece.len;
    }
    return out;
}

/// An address a reader may follow: http, https, mailto, or one with no
/// scheme at all (a path, a fragment). `javascript:` and `data:` are not.
pub fn safeAddress(address: []const u8) bool {
    const trimmed = std.mem.trim(u8, address, &std.ascii.whitespace);
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return true;
    // A colon after the path began is not a scheme: /a:b, ?q=a:b, #a:b.
    if (std.mem.indexOfAny(u8, trimmed[0..colon], "/?#") != null) return true;
    const scheme = trimmed[0..colon];
    for ([_][]const u8{ "http", "https", "mailto" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(scheme, allowed)) return true;
    }
    return false;
}

fn wrap(allocator: Allocator, content: []const u8, string: []const u8) ![]const u8 {
    return allocPrint(
        allocator,
        "<{[tag]s}>{[content]s}</{[tag]s}>",
        .{ .tag = string, .content = content },
    );
}

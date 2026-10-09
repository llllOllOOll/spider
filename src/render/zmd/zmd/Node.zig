//! One element of a parsed Markdown document (`spider.zmd.Node`): the value a
//! `Formatters` function receives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const tokens = @import("tokens.zig");
const Node = @This();
const Formatters = @import("Formatters.zig");
const Writer = std.Io.Writer;

/// The syntax element this node came from and its place in the input.
token: tokens.Token,
/// The inner HTML of the element when its formatter runs: the children
/// already rendered, text and code already escaped.
content: []const u8 = "",
/// The language named after the opening fence of a code block (`zig` for
/// a block opened with three backticks and `zig`). As typed: escape it.
meta: ?[]const u8 = null,
/// The address of a link or image. As typed: check it with
/// `Formatters.safeAddress` and escape it.
href: ?[]const u8 = null,
/// The text of a link or image. As typed: escape it.
title: ?[]const u8 = null,
/// The elements inside this one, in order.
children: ArrayList(*Node),
// internal: position of the token in the token list.
index: usize = 0,

// internal: recursively translates a node into HTML; `parse` calls it on the root.
pub fn toHtml(
    self: *Node,
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    level: usize,
    formatters: Formatters,
) !void {
    const token_type = self.token.element.type;
    const formatter: ?*const Formatters.Handler = switch (token_type) {
        .linebreak, .none, .eof => null,
        .paragraph => if (level == 1)
            &getHandlerComptime(formatters, "paragraph")
        else
            &getHandlerComptime(formatters, "text"),
        inline else => |element_type| &getHandlerComptime(formatters, @tagName(element_type)),
    };

    var allocating: Writer.Allocating = .init(allocator);
    defer allocating.deinit();

    switch (token_type) {
        .text => {
            if (self.children.items.len == 0) {
                const escaped = try escape(
                    allocator,
                    input[self.token.start..self.token.end],
                );
                defer allocator.free(escaped);
                try allocating.writer.writeAll(escaped);
            } else {
                try allocating.writer.writeAll(
                    input[self.token.start..self.token.end],
                );
            }
        },
        .code, .block => {
            const escaped = try escape(allocator, self.content);
            defer allocator.free(escaped);
            try allocating.writer.writeAll(escaped);
        },
        // Kept as typed for a template engine ({{ }}, {% %}), but it is
        // still text: HTML in it is escaped.
        .raw_block => {
            const escaped = try escape(allocator, self.content);
            defer allocator.free(escaped);
            try allocating.writer.writeAll(escaped);
        },
        else => {},
    }

    for (self.children.items) |node| {
        try node.toHtml(
            allocator,
            input,
            &allocating.writer,
            level + 1,
            formatters,
        );
    }

    self.content = if (self.token.element.trim)
        std.mem.trim(
            u8,
            try allocating.toOwnedSlice(),
            &std.ascii.whitespace,
        )
    else
        try allocating.toOwnedSlice();

    if (formatter) |handler_func| {
        const html_string = try handler_func(allocator, self.*);
        defer allocator.free(html_string);
        try writer.writeAll(html_string);
    }
}

// internal: the formatter of an element type, or `default_handler`.
pub fn getHandlerComptime(
    formatters: Formatters,
    comptime element_type: []const u8,
) Formatters.Handler {
    return if (@hasField(Formatters, element_type))
        @field(formatters, element_type)
    else
        formatters.default_handler;
}

fn escape(allocator: Allocator, input: []const u8) ![]const u8 {
    return Formatters.escape(allocator, input);
}

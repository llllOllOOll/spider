//! Internal: the template parser. Turns template source into the nodes of
//! ast.zig, with the layout named by `extends` and the components defined
//! inline.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const Node = ast.Node;
const Prop = ast.Prop;

fn isUpperCase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

pub fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < s.len and s[start] == ' ') start += 1;
    while (end > start and s[end - 1] == ' ') end -= 1;
    return s[start..end];
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// Recognizes `name("literal", "literal")` — an identifier immediately
// followed by '(', ending in ')' as the trimmed expression's last byte, with
// comma-separated string-literal arguments only. Returns null (not an error)
// for anything else — including malformed/partial call-like text — so the
// caller falls back to the existing variable-interpolation path unchanged.
fn tryParseCall(alc: std.mem.Allocator, expr: []const u8) !?Node {
    if (expr.len == 0 or !isIdentStart(expr[0])) return null;

    var i: usize = 1;
    while (i < expr.len and isIdentChar(expr[i])) : (i += 1) {}
    if (i >= expr.len or expr[i] != '(') return null;
    if (expr[expr.len - 1] != ')') return null;

    const name = expr[0..i];
    const args_text = trimWhitespace(expr[i + 1 .. expr.len - 1]);

    var args: std.ArrayList([]const u8) = .empty;
    var ok = true;

    if (args_text.len > 0) {
        var it = std.mem.splitScalar(u8, args_text, ',');
        while (it.next()) |raw_arg| {
            const arg = trimWhitespace(raw_arg);
            if (arg.len < 2 or arg[0] != '"' or arg[arg.len - 1] != '"') {
                ok = false;
                break;
            }
            try args.append(alc, try alc.dupe(u8, arg[1 .. arg.len - 1]));
        }
    }

    if (!ok) {
        for (args.items) |a| alc.free(a);
        args.deinit(alc);
        return null;
    }

    return Node{ .call = .{
        .name = try alc.dupe(u8, name),
        .args = try args.toOwnedSlice(alc),
    } };
}

/// Index just past the "-->" closing the HTML comment that starts at `start`
/// (which must point at "<!--"), or `str.len` when it is never closed —
/// browsers also treat an unterminated comment as running to the end.
pub fn commentEnd(str: []const u8, start: usize) usize {
    const body = start + "<!--".len;
    if (body > str.len) return str.len;
    const close = std.mem.indexOfPos(u8, str, body, "-->") orelse return str.len;
    return close + "-->".len;
}

/// Given `start` just past a block's opening '{', returns the index of the
/// matching '}' or null. HTML comments are skipped, so braces inside
/// `<!-- ... -->` don't unbalance if/for bodies.
fn findBlockEnd(str: []const u8, start: usize) ?usize {
    var i = start;
    var depth: usize = 1;
    while (i < str.len) {
        if (std.mem.startsWith(u8, str[i..], "<!--")) {
            i = commentEnd(str, i);
            continue;
        }
        switch (str[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn trimString(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n' or s[start] == '\r')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

pub const Parser = struct {
    alc: std.mem.Allocator,
    template: []const u8,
    pos: usize,
    // Set while scanning a <script>/<style> opening tag whose closing '>'
    // hasn't been reached yet, or while skipping its raw body verbatim.
    // Lives on the Parser (not a parseText-local) because parseText may
    // `break` mid-attribute-scan to hand off an interpolation found inside
    // the opening tag's attributes — a later parseText call must remember
    // it's still inside that tag to correctly skip the body afterward.
    raw_skip_close: ?[]const u8 = null,
    /// The template's name in the log line of a syntax error, when known.
    name: ?[]const u8 = null,
    /// Log a syntax error with its line and the fix (spider check reports
    /// it itself and turns this off).
    log_failure: bool = true,

    pub fn init(alc: std.mem.Allocator, template: []const u8) Parser {
        return Parser{ .alc = alc, .template = template, .pos = 0 };
    }

    pub const Parsed = struct { nodes: []Node, layout: ?[]const u8, inline_components: std.StringHashMapUnmanaged([]const u8) };

    /// Parses the whole template. On a syntax error, `failure()` says where
    /// and why, and the error is logged (unless `log_failure` is off).
    pub fn parse(p: *Parser) !Parsed {
        last_kind = null;
        return p.parseAll() catch |err| {
            if (p.log_failure) logFailure(p.template, p.name);
            return err;
        };
    }

    fn parseAll(p: *Parser) !Parsed {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(p.alc);

        var inline_components = std.StringHashMapUnmanaged([]const u8){};
        errdefer {
            var iter = inline_components.iterator();
            while (iter.next()) |entry| {
                p.alc.free(entry.key_ptr.*);
                p.alc.free(entry.value_ptr.*);
            }
            inline_components.deinit(p.alc);
        }

        var layout_name: ?[]const u8 = null;

        if (std.mem.startsWith(u8, p.template[p.pos..], "extends ")) {
            p.pos += 8;

            if (p.pos < p.template.len and p.template[p.pos] == '"') {
                p.pos += 1;
                const name_start = p.pos;
                while (p.pos < p.template.len and p.template[p.pos] != '"') p.pos += 1;
                if (p.pos < p.template.len) {
                    layout_name = try p.alc.dupe(u8, p.template[name_start..p.pos]);
                    p.pos += 1;
                }
            }

            while (p.pos < p.template.len and p.template[p.pos] != '\n') p.pos += 1;
            if (p.pos < p.template.len) p.pos += 1;
        }

        while (p.pos < p.template.len) {
            if (std.mem.startsWith(u8, p.template[p.pos..], "if (")) {
                const node = try p.parseIf();
                try nodes.append(p.alc, node);
            } else if (std.mem.startsWith(u8, p.template[p.pos..], "for (")) {
                const node = try p.parseFor();
                try nodes.append(p.alc, node);
            } else if (std.mem.startsWith(u8, p.template[p.pos..], "{ ")) {
                const node = try p.parseInterpolation();
                try nodes.append(p.alc, node);
            } else if (p.template[p.pos] == '<' and p.pos + 1 < p.template.len and isUpperCase(p.template[p.pos + 1])) {
                const node = try p.parseComponent();
                try nodes.append(p.alc, node);
            } else {
                const node = try p.parseText();
                try nodes.append(p.alc, node);
            }
        }

        return .{ .nodes = try nodes.toOwnedSlice(p.alc), .layout = layout_name, .inline_components = inline_components };
    }

    fn parseComponent(p: *Parser) !Node {
        return parseComponentNode(p.alc, p.template, &p.pos);
    }

    fn parseIf(p: *Parser) !Node {
        return parseIfNode(p.alc, p.template, &p.pos);
    }

    fn parseFor(p: *Parser) !Node {
        const at = p.template[p.pos..];
        p.pos += 5;

        const iter_start = p.pos;
        var paren_depth: usize = 0;
        while (p.pos < p.template.len) {
            if (p.template[p.pos] == '(') paren_depth += 1;
            if (p.template[p.pos] == ')' and paren_depth == 0) break;
            if (p.template[p.pos] == ')') paren_depth -= 1;
            p.pos += 1;
        }
        if (p.pos >= p.template.len) return fail(.unclosed_paren, at);
        const iterable = try p.alc.dupe(u8, p.template[iter_start..p.pos]);
        p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos >= p.template.len or p.template[p.pos] != '|') return fail(.expected_capture, at);
        p.pos += 1;
        const cap_start = p.pos;
        while (p.pos < p.template.len and p.template[p.pos] != '|') p.pos += 1;
        if (p.pos >= p.template.len) return fail(.unclosed_capture, at);
        const capture = try p.alc.dupe(u8, p.template[cap_start..p.pos]);
        p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos >= p.template.len or p.template[p.pos] != '{') return fail(.for_brace, at);
        p.pos += 1;

        const body_start = p.pos;
        p.pos = findBlockEnd(p.template, body_start) orelse return fail(.unclosed_block, at);

        const body_str = trimWhitespace(p.template[body_start..p.pos]);
        p.pos += 1;

        const body = try parseTextNodes(p.alc, body_str);

        return Node{ .for_node = .{ .iterable = iterable, .capture = capture, .body = body } };
    }

    fn parseInterpolation(p: *Parser) !Node {
        const at = p.template[p.pos..];
        p.pos += 2;

        const expr_start = p.pos;
        var depth: usize = 0;
        while (p.pos < p.template.len) {
            if (p.template[p.pos] == '{') {
                depth += 1;
                p.pos += 1;
            } else if (std.mem.startsWith(u8, p.template[p.pos..], " }")) {
                if (depth == 0) break;
                depth -= 1;
                p.pos += 2;
            } else {
                p.pos += 1;
            }
        }
        if (p.pos >= p.template.len) return fail(.unclosed_interpolation, at);
        const expr_raw = p.template[expr_start..p.pos];
        p.pos += 2;

        return exprNode(p.alc, expr_raw);
    }

    fn parseText(p: *Parser) !Node {
        const start = p.pos;
        while (p.pos < p.template.len) {
            // <script>/<style> bodies are raw — never template-processed,
            // since real JS/CSS commonly contains literal '{'/'}'. The
            // OPENING tag's own attributes are not part of that body, so
            // they still go through the normal scan below (this is what
            // lets something like <script src='{ asset_url(...) }'> work).
            if (p.raw_skip_close) |close_tag| {
                if (p.template[p.pos] == '>') {
                    p.pos += 1;
                    while (p.pos < p.template.len) {
                        if (std.mem.startsWith(u8, p.template[p.pos..], close_tag)) {
                            p.pos += close_tag.len;
                            break;
                        }
                        p.pos += 1;
                    }
                    p.raw_skip_close = null;
                    continue;
                }
            } else if (std.mem.startsWith(u8, p.template[p.pos..], "<!--")) {
                // Verbatim, never template-processed (see parseTextNodes).
                if (p.pos > start) break;
                p.pos = commentEnd(p.template, p.pos);
                return Node{ .text = try p.alc.dupe(u8, p.template[start..p.pos]) };
            } else if (std.mem.startsWith(u8, p.template[p.pos..], "<script")) {
                p.raw_skip_close = "</script>";
            } else if (std.mem.startsWith(u8, p.template[p.pos..], "<style")) {
                p.raw_skip_close = "</style>";
            }
            if (std.mem.startsWith(u8, p.template[p.pos..], "{{")) {
                if (p.pos > start) break;
                p.pos += 2;
                const raw_start = p.pos;
                while (p.pos < p.template.len) {
                    if (std.mem.startsWith(u8, p.template[p.pos..], "}}")) break;
                    p.pos += 1;
                }
                const raw = p.template[raw_start..p.pos];
                if (p.pos < p.template.len) p.pos += 2;
                const literal = try p.alc.alloc(u8, 1 + raw.len + 1);
                @memcpy(literal[0..1], "{");
                @memcpy(literal[1..][0..raw.len], raw);
                @memcpy(literal[1 + raw.len ..][0..1], "}");
                return Node{ .text = literal };
            }
            const remaining = p.template[p.pos..];
            if (std.mem.startsWith(u8, remaining, "if (")) break;
            if (std.mem.startsWith(u8, remaining, "for (")) break;
            if (std.mem.startsWith(u8, remaining, "{ ")) break;
            if (p.template[p.pos] == '<' and p.pos + 1 < p.template.len and isUpperCase(p.template[p.pos + 1])) break;
            p.pos += 1;
        }
        const text = try p.alc.dupe(u8, p.template[start..p.pos]);
        return Node{ .text = text };
    }
};

pub fn skipWhitespace(template: []const u8, pos: *usize) void {
    while (pos.* < template.len and (template[pos.*] == ' ' or template[pos.*] == '\n' or template[pos.*] == '\r' or template[pos.*] == '\t')) pos.* += 1;
}

pub fn parseComponentNode(alc: std.mem.Allocator, template: []const u8, pos: *usize) !Node {
    pos.* += 1;

    const name_start = pos.*;
    while (pos.* < template.len and template[pos.*] != ' ' and template[pos.*] != '/' and template[pos.*] != '>' and template[pos.*] != '\n') {
        pos.* += 1;
    }
    const name = try alc.dupe(u8, template[name_start..pos.*]);

    var props: std.ArrayList(Prop) = .empty;
    defer props.deinit(alc);

    skipWhitespace(template, pos);

    while (pos.* < template.len and template[pos.*] != '/' and template[pos.*] != '>') {
        const prop_name_start = pos.*;
        while (pos.* < template.len and template[pos.*] != '=' and template[pos.*] != ' ' and template[pos.*] != '/' and template[pos.*] != '>' and template[pos.*] != '\n' and template[pos.*] != '\r' and template[pos.*] != '\t') {
            pos.* += 1;
        }
        const prop_name = try alc.dupe(u8, template[prop_name_start..pos.*]);

        skipWhitespace(template, pos);

        if (pos.* < template.len and template[pos.*] == '=') {
            pos.* += 1;

            skipWhitespace(template, pos);

            if (pos.* < template.len and template[pos.*] == '"') {
                pos.* += 1;
                if (pos.* < template.len and template[pos.*] == '{') {
                    pos.* += 1;
                    const val_start = pos.*;
                    while (pos.* < template.len) {
                        if (std.mem.startsWith(u8, template[pos.*..], "}\"")) {
                            break;
                        }
                        pos.* += 1;
                    }
                    const prop_value_raw = template[val_start..pos.*];
                    const prop_value = trimString(prop_value_raw);
                    pos.* += 2;
                    try props.append(alc, Prop{ .name = prop_name, .value = try alc.dupe(u8, prop_value), .is_expr = true });
                } else {
                    const val_start = pos.*;
                    while (pos.* < template.len and template[pos.*] != '"') pos.* += 1;
                    const prop_value = template[val_start..pos.*];
                    pos.* += 1;
                    try props.append(alc, Prop{ .name = prop_name, .value = try alc.dupe(u8, prop_value) });
                }
            } else {
                alc.free(prop_name);
            }
        } else {
            alc.free(prop_name);
        }

        skipWhitespace(template, pos);
    }

    var self_closing = false;
    var slot_content: ?[]const u8 = null;

    if (pos.* < template.len and template[pos.*] == '/') {
        pos.* += 1;
        self_closing = true;
    }

    if (pos.* < template.len and template[pos.*] == '>') {
        pos.* += 1;
    }

    if (!self_closing) {
        const slot_start = pos.*;
        const close_tag = try std.fmt.allocPrint(alc, "</{s}>", .{name});
        defer alc.free(close_tag);

        if (std.mem.indexOf(u8, template[pos.*..], close_tag)) |idx| {
            const content = trimWhitespace(template[slot_start..(pos.* + idx)]);
            if (content.len > 0) {
                slot_content = try alc.dupe(u8, content);
            }
            pos.* += idx + close_tag.len;
        }
    }

    return Node{ .component = .{ .name = name, .props = try props.toOwnedSlice(alc), .self_closing = self_closing, .slot_content = slot_content } };
}

// Parses one complete if/else-if*/else? chain from str[pos.*..].
// On entry pos.* points at "if (". On return pos.* is past the chain.
// Handles arbitrary-depth else if chains via recursion.
const ParseError = error{ UnclosedParen, ExpectedBrace, UnclosedBrace, UnclosedInterpolation, UnclosedCapture, ExpectedCapture } || std.mem.Allocator.Error;

pub fn parseIfNode(alc: std.mem.Allocator, str: []const u8, pos: *usize) ParseError!Node {
    const at = str[pos.*..];
    pos.* += 4; // skip "if ("

    const cond_start = pos.*;
    var paren_depth: usize = 0;
    while (pos.* < str.len) {
        if (str[pos.*] == '(') paren_depth += 1;
        if (str[pos.*] == ')' and paren_depth == 0) break;
        if (str[pos.*] == ')') paren_depth -= 1;
        pos.* += 1;
    }
    if (pos.* >= str.len) return fail(.unclosed_paren, at);
    const condition = try alc.dupe(u8, str[cond_start..pos.*]);
    pos.* += 1; // skip ')'

    while (pos.* < str.len and str[pos.*] == ' ') pos.* += 1;
    if (pos.* >= str.len or str[pos.*] != '{') return fail(.if_brace, at);
    pos.* += 1; // skip '{'

    const then_start = pos.*;
    pos.* = findBlockEnd(str, then_start) orelse return fail(.unclosed_block, at);
    const then_body = try parseTextNodes(alc, trimWhitespace(str[then_start..pos.*]));
    pos.* += 1; // skip '}'

    var else_body: ?[]Node = null;
    while (pos.* < str.len and (str[pos.*] == ' ' or str[pos.*] == '\t' or str[pos.*] == '\n' or str[pos.*] == '\r')) pos.* += 1;

    if (pos.* + 9 <= str.len and std.mem.eql(u8, str[pos.* .. pos.* + 9], "else if (")) {
        pos.* += 5; // skip "else " to land on "if ("
        const nested = try parseIfNode(alc, str, pos);
        var nested_nodes = try alc.alloc(Node, 1);
        nested_nodes[0] = nested;
        else_body = nested_nodes;
    } else if (pos.* + 6 <= str.len and std.mem.eql(u8, str[pos.* .. pos.* + 6], "else {")) {
        const else_at = str[pos.*..];
        pos.* += 6; // skip "else {"
        const else_start = pos.*;
        pos.* = findBlockEnd(str, else_start) orelse return fail(.unclosed_block, else_at);
        const else_str = trimWhitespace(str[else_start..pos.*]);
        pos.* += 1; // skip '}'
        else_body = try parseTextNodes(alc, else_str);
    }

    return Node{ .if_node = .{ .condition = condition, .then_body = then_body, .else_body = else_body } };
}

/// The node for what a `{ ... }` holds, at the top of a template and in the
/// body of an `if` or a `for` alike (the body of a `for` once ignored the
/// `{ word if (cond) }` sugar, so a loop variable never set it).
fn exprNode(alc: std.mem.Allocator, expr_raw: []const u8) ParseError!Node {
    const trimmed_expr = trimWhitespace(expr_raw);
    // `{ disabled if (locked) }` / `{ "ui-btn-active" if (tab == "home") }`:
    // the word or string only when the condition holds — boolean
    // attributes and conditional classes (`disabled="{ x }"` would print
    // "false" and stay disabled). Sugar for `if (cond) { "text" }`.
    if (suffixIf(trimmed_expr)) |s| {
        const synthesized = try std.fmt.allocPrint(alc, "if ({s}) {{ \"{s}\" }}", .{ s.cond, s.text });
        defer alc.free(synthesized);
        var sub_pos: usize = 0;
        return parseIfNode(alc, synthesized, &sub_pos);
    }
    // If the expression is an if/else block, parse and return it directly.
    if (std.mem.startsWith(u8, trimmed_expr, "if (")) {
        // `{ if (cond) "x" }`: no braces around the body, a form Spider
        // never had (inside a for it once printed nothing, silently).
        if (closeParen(trimmed_expr, 4)) |close| {
            const rest = std.mem.trimStart(u8, trimmed_expr[close + 1 ..], " \t\r\n");
            if (rest.len == 0 or rest[0] != '{') return fail(.inline_if, trimmed_expr);
        }
        var sub_pos: usize = 0;
        return parseIfNode(alc, trimmed_expr, &sub_pos);
    }

    if (try tryParseCall(alc, trimmed_expr)) |call_node| {
        return call_node;
    }

    if (std.mem.indexOf(u8, expr_raw, " ?? ")) |idx| {
        const expr = trimWhitespace(expr_raw[0..idx]);
        const default_raw = trimWhitespace(expr_raw[idx + 4 ..]);
        const default_val = if (default_raw.len >= 2 and default_raw[0] == '"' and default_raw[default_raw.len - 1] == '"')
            default_raw[1 .. default_raw.len - 1]
        else
            default_raw;
        return Node{ .interpolation_with_default = .{
            .expr = try alc.dupe(u8, expr),
            .default = try alc.dupe(u8, default_val),
        } };
    }

    return Node{ .interpolation = try alc.dupe(u8, expr_raw) };
}

pub fn parseTextNodes(alc: std.mem.Allocator, str: []const u8) ![]Node {
    // FIX: If the entire content is a quoted string literal, emit it as plain text without quotes.
    const trimmed = trimWhitespace(str);
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        const inner = trimmed[1 .. trimmed.len - 1];
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(alc, Node{ .text = try alc.dupe(u8, inner) });
        return nodes.toOwnedSlice(alc);
    }

    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(alc);

    var pos: usize = 0;
    // Same rationale as Parser.raw_skip_close (see parseText): <script>/
    // <style> bodies are raw, but their opening tag's own attributes still
    // go through normal interpolation handling. This is a plain local var
    // (not a struct field) because parseTextNodes processes its whole
    // input in one call, unlike the top-level Parser loop.
    var raw_skip_close: ?[]const u8 = null;
    while (pos < str.len) {
        if (raw_skip_close) |close_tag| {
            if (str[pos] == '>') {
                const skip_start = pos;
                pos += 1;
                while (pos < str.len) {
                    if (std.mem.startsWith(u8, str[pos..], close_tag)) {
                        pos += close_tag.len;
                        break;
                    }
                    pos += 1;
                }
                try nodes.append(alc, Node{ .text = try alc.dupe(u8, str[skip_start..pos]) });
                raw_skip_close = null;
                continue;
            }
        }
        const remaining = str[pos..];
        // HTML comments are emitted verbatim and never template-processed:
        // a component tag mentioned in a comment must not become a real
        // include (a component documenting itself recursed forever).
        if (raw_skip_close == null and std.mem.startsWith(u8, remaining, "<!--")) {
            const end = commentEnd(str, pos);
            try nodes.append(alc, Node{ .text = try alc.dupe(u8, str[pos..end]) });
            pos = end;
            continue;
        }
        if (std.mem.startsWith(u8, remaining, "{{")) {
            pos += 2;
            const raw_start = pos;
            while (pos < str.len) {
                if (std.mem.startsWith(u8, str[pos..], "}}")) break;
                pos += 1;
            }
            const raw = str[raw_start..pos];
            if (pos < str.len) pos += 2;
            const literal = try alc.alloc(u8, 1 + raw.len + 1);
            @memcpy(literal[0..1], "{");
            @memcpy(literal[1..][0..raw.len], raw);
            @memcpy(literal[1 + raw.len ..][0..1], "}");
            try nodes.append(alc, Node{ .text = literal });
            continue;
        }
        if (std.mem.startsWith(u8, remaining, "{ ")) {
            pos += 2;
            const expr_start = pos;
            while (pos < str.len) {
                if (std.mem.startsWith(u8, str[pos..], " }")) break;
                pos += 1;
            }
            if (pos >= str.len) return fail(.unclosed_interpolation, remaining);
            const expr_raw = str[expr_start..pos];
            pos += 2;
            try nodes.append(alc, try exprNode(alc, expr_raw));
        } else if (std.mem.startsWith(u8, remaining, "{ slot }")) {
            try nodes.append(alc, Node{ .interpolation = try alc.dupe(u8, "slot") });
            pos += "{ slot }".len;
        } else if (std.mem.startsWith(u8, remaining, "if (")) {
            try nodes.append(alc, try parseIfNode(alc, str, &pos));
        } else if (std.mem.startsWith(u8, remaining, "for (")) {
            const at = remaining;
            pos += 5;
            const iter_start = pos;
            var paren_depth: usize = 0;
            while (pos < str.len) {
                if (str[pos] == '(') paren_depth += 1;
                if (str[pos] == ')' and paren_depth == 0) break;
                if (str[pos] == ')') paren_depth -= 1;
                pos += 1;
            }
            if (pos >= str.len) return fail(.unclosed_paren, at);
            const iterable = try alc.dupe(u8, str[iter_start..pos]);
            pos += 1;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos >= str.len or str[pos] != '|') return fail(.expected_capture, at);
            pos += 1;
            const cap_start = pos;
            while (pos < str.len and str[pos] != '|') pos += 1;
            if (pos >= str.len) return fail(.unclosed_capture, at);
            const capture = try alc.dupe(u8, str[cap_start..pos]);
            pos += 1;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos >= str.len or str[pos] != '{') return fail(.for_brace, at);
            pos += 1;
            const body_start = pos;
            pos = findBlockEnd(str, body_start) orelse return fail(.unclosed_block, at);
            const body_str = str[body_start..pos];
            pos += 1;
            const body = try parseTextNodes(alc, body_str);
            try nodes.append(alc, Node{ .for_node = .{ .iterable = iterable, .capture = capture, .body = body } });
        } else if (pos < str.len and str[pos] == '<' and pos + 1 < str.len and isUpperCase(str[pos + 1])) {
            const node = try parseComponentNode(alc, str, &pos);
            try nodes.append(alc, node);
        } else {
            const start = pos;
            if (raw_skip_close == null) {
                if (std.mem.startsWith(u8, remaining, "<script")) {
                    raw_skip_close = "</script>";
                } else if (std.mem.startsWith(u8, remaining, "<style")) {
                    raw_skip_close = "</style>";
                }
            }
            while (pos < str.len) {
                const r = str[pos..];
                if (raw_skip_close != null and str[pos] == '>') break;
                // Stop right before a <script>/<style> that isn't at the start
                // of this chunk, so the next chunk begins at the tag and the
                // raw-body detection above actually sees it. Without this, text
                // like "\n  <script>...{ x }...</script>" scanned straight past
                // the tag and the JS body got interpolated.
                if (pos > start and raw_skip_close == null and
                    (std.mem.startsWith(u8, r, "<script") or std.mem.startsWith(u8, r, "<style") or
                        std.mem.startsWith(u8, r, "<!--"))) break;
                if (std.mem.startsWith(u8, r, "{{")) break;
                if (std.mem.startsWith(u8, r, "{ ")) break;
                if (std.mem.startsWith(u8, r, "{ slot }")) break;
                if (std.mem.startsWith(u8, r, "if (")) break;
                if (std.mem.startsWith(u8, r, "for (")) break;
                if (pos < str.len and str[pos] == '<' and pos + 1 < str.len and isUpperCase(str[pos + 1])) break;
                pos += 1;
            }
            if (pos > start) {
                const text = try alc.dupe(u8, str[start..pos]);
                try nodes.append(alc, Node{ .text = text });
            }
        }
    }

    return nodes.toOwnedSlice(alc);
}

/// `NAME if (COND)` or `"TEXT" if (COND)` -> .{ text, cond }. NAME is an
/// attribute-like word (letters, digits, - _ : @ .); TEXT has no quotes.
fn suffixIf(expr: []const u8) ?struct { text: []const u8, cond: []const u8 } {
    const marker = " if (";
    const at = std.mem.indexOf(u8, expr, marker) orelse return null;
    if (expr.len == 0 or expr[expr.len - 1] != ')') return null;
    const head = expr[0..at];
    const cond = expr[at + marker.len .. expr.len - 1];
    if (cond.len == 0) return null;
    if (head.len >= 2 and head[0] == '"' and head[head.len - 1] == '"') {
        const text = head[1 .. head.len - 1];
        if (std.mem.indexOfScalar(u8, text, '"') != null) return null;
        return .{ .text = text, .cond = cond };
    }
    if (head.len == 0) return null;
    for (head) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':' or ch == '@' or ch == '.')) return null;
    }
    return .{ .text = head, .cond = cond };
}

// ── Syntax errors: where, what, and the form that works ─────────────────

/// What a syntax error was, for its message.
const Kind = enum {
    inline_if,
    if_brace,
    for_brace,
    unclosed_block,
    unclosed_interpolation,
    unclosed_paren,
    expected_capture,
    unclosed_capture,
};

// The last syntax error on this thread: what, and the text from where the
// construct starts (a slice of the source being parsed). Set just before
// the error is returned, read right after by failure(): parsing never
// yields, so nothing else runs on this thread in between.
threadlocal var last_kind: ?Kind = null;
threadlocal var last_at: []const u8 = "";

fn fail(kind: Kind, at: []const u8) ParseError {
    last_kind = kind;
    last_at = at;
    return switch (kind) {
        .inline_if, .if_brace, .for_brace => error.ExpectedBrace,
        .unclosed_block => error.UnclosedBrace,
        .unclosed_interpolation => error.UnclosedInterpolation,
        .unclosed_paren => error.UnclosedParen,
        .expected_capture => error.ExpectedCapture,
        .unclosed_capture => error.UnclosedCapture,
    };
}

/// The index of the `)` closing the `(` just before `from`, or null.
fn closeParen(str: []const u8, from: usize) ?usize {
    var depth: usize = 0;
    var i = from;
    while (i < str.len) : (i += 1) {
        switch (str[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// A syntax error explained: `line` in the source (1-based; 0 when the
/// failing text is not in it), the text that failed, what is wrong, and
/// the form that works.
pub const Failure = struct {
    line: usize,
    snippet: []const u8,
    message: []const u8,
    fix: []const u8,
};

/// Explains the syntax error of the last `Parser.parse` of `source` on
/// this thread, or null when that parse succeeded (or failed only for
/// memory). Strings are allocated with `alc` or point into `source`.
pub fn failure(alc: std.mem.Allocator, source: []const u8) !?Failure {
    const kind = last_kind orelse return null;
    const src_start = @intFromPtr(source.ptr);
    const at_start = @intFromPtr(last_at.ptr);
    // Text the parser built itself (the `{ x if (c) }` sugar) is not in
    // the source: no line and no snippet, but still what is wrong.
    const in_source = at_start >= src_start and at_start + last_at.len <= src_start + source.len;
    const offset = at_start -% src_start;
    const line = if (in_source) 1 + std.mem.count(u8, source[0..offset], "\n") else 0;
    const rest = if (in_source) restOfLine(source[offset..]) else "";
    return switch (kind) {
        .inline_if => .{
            .line = line,
            .snippet = if (in_source) try std.fmt.allocPrint(alc, "{{ {s} }}", .{last_at}) else "",
            .message = "an `if` inside { } needs its body in braces",
            .fix = if (in_source) try inlineIfFix(alc, last_at) else "{ \"text\" if (cond) }, or if (cond) { ... } else { ... }",
        },
        .if_brace => .{ .line = line, .snippet = rest, .message = "`if (...)` needs its body in braces right after the condition", .fix = "if (cond) { ... } else { ... }" },
        .for_brace => .{ .line = line, .snippet = rest, .message = "`for (...) |item|` needs its body in braces", .fix = "for (items) |item| { ... }" },
        .unclosed_block => .{ .line = line, .snippet = rest, .message = "the `{` of this block is never closed", .fix = "close the block with `}`" },
        .unclosed_interpolation => .{ .line = line, .snippet = rest, .message = "`{ ` is never closed with ` }`", .fix = "close it with ` }` (a space, then the brace); to print braces, write {{ ... }}" },
        .unclosed_paren => .{ .line = line, .snippet = rest, .message = "the `(` of this `if` or `for` is never closed", .fix = "close the condition with `)`" },
        .expected_capture => .{ .line = line, .snippet = rest, .message = "`for (...)` needs a name for each item", .fix = "for (items) |item| { ... }" },
        .unclosed_capture => .{ .line = line, .snippet = rest, .message = "the item name of this `for` is not closed with `|`", .fix = "for (items) |item| { ... }" },
    };
}

/// The text up to the end of its line, at most 120 bytes.
fn restOfLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trimEnd(u8, text[0..@min(end, 120)], " \t");
}

/// The form that works for `if (COND) BODY` written inside `{ }`:
/// `"x"` -> `{ "x" if (COND) }`; `"a" else "b"` -> the if/else block.
fn inlineIfFix(alc: std.mem.Allocator, expr: []const u8) ![]const u8 {
    const close = closeParen(expr, 4) orelse return "if (cond) { ... } else { ... }";
    const cond = expr[4..close];
    const body = std.mem.trim(u8, expr[close + 1 ..], " \t\r\n");
    if (quoted(body)) |text| {
        return std.fmt.allocPrint(alc, "{{ \"{s}\" if ({s}) }} (a class or an attribute), or if ({s}) {{ ... }}", .{ text, cond, cond });
    }
    if (std.mem.indexOf(u8, body, " else ")) |e| {
        if (quoted(std.mem.trim(u8, body[0..e], " "))) |a| {
            if (quoted(std.mem.trim(u8, body[e + " else ".len ..], " "))) |b| {
                return std.fmt.allocPrint(alc, "if ({s}) {{ {s} }} else {{ {s} }}", .{ cond, a, b });
            }
        }
    }
    return std.fmt.allocPrint(alc, "if ({s}) {{ ... }} else {{ ... }}", .{cond});
}

/// The text of a `"..."` literal with no quote inside, or null.
fn quoted(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return null;
    const inner = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '"') != null) return null;
    return inner;
}

/// Logs the last syntax error of `source`, with `name` when known:
/// `template "posts/index", line 5: { ... }: what is wrong` and the fix.
fn logFailure(source: []const u8, name: ?[]const u8) void {
    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const f = (failure(fba.allocator(), source) catch return) orelse return;
    // warn under `zig test`: the test runner fails any test that logs at err.
    const log = if (builtin.is_test) std.log.warn else std.log.err;
    var where_buf: [160]u8 = undefined;
    const where = if (name) |n|
        (if (f.line > 0) std.fmt.bufPrint(&where_buf, "template \"{s}\", line {d}", .{ n, f.line }) else std.fmt.bufPrint(&where_buf, "template \"{s}\"", .{n})) catch "template"
    else if (f.line > 0)
        std.fmt.bufPrint(&where_buf, "template, line {d}", .{f.line}) catch "template"
    else
        "template";
    log("{s}: {s}: {s}\n    fix: {s}", .{ where, f.snippet, f.message, f.fix });
}

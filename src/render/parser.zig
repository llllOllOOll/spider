const std = @import("std");
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

    pub fn init(alc: std.mem.Allocator, template: []const u8) Parser {
        return Parser{ .alc = alc, .template = template, .pos = 0 };
    }

    pub fn parse(p: *Parser) !struct { nodes: []Node, layout: ?[]const u8, inline_components: std.StringHashMapUnmanaged([]const u8) } {
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
        p.pos += 5;

        const iter_start = p.pos;
        var paren_depth: usize = 0;
        while (p.pos < p.template.len) {
            if (p.template[p.pos] == '(') paren_depth += 1;
            if (p.template[p.pos] == ')' and paren_depth == 0) break;
            if (p.template[p.pos] == ')') paren_depth -= 1;
            p.pos += 1;
        }
        if (p.pos >= p.template.len) return error.UnclosedParen;
        const iterable = try p.alc.dupe(u8, p.template[iter_start..p.pos]);
        p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos >= p.template.len or p.template[p.pos] != '|') return error.ExpectedCapture;
        p.pos += 1;
        const cap_start = p.pos;
        while (p.pos < p.template.len and p.template[p.pos] != '|') p.pos += 1;
        if (p.pos >= p.template.len) return error.UnclosedCapture;
        const capture = try p.alc.dupe(u8, p.template[cap_start..p.pos]);
        p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos >= p.template.len or p.template[p.pos] != '{') return error.ExpectedBrace;
        p.pos += 1;

        const body_start = p.pos;
        var brace_count: usize = 1;
        while (p.pos < p.template.len and brace_count > 0) {
            if (p.template[p.pos] == '{') brace_count += 1 else if (p.template[p.pos] == '}') brace_count -= 1;
            if (brace_count > 0) p.pos += 1;
        }
        if (p.pos >= p.template.len) return error.UnclosedBrace;

        const body_str = trimWhitespace(p.template[body_start..p.pos]);
        p.pos += 1;

        const body = try parseTextNodes(p.alc, body_str);

        return Node{ .for_node = .{ .iterable = iterable, .capture = capture, .body = body } };
    }

    fn parseInterpolation(p: *Parser) !Node {
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
        if (p.pos >= p.template.len) return error.UnclosedInterpolation;
        const expr_raw = p.template[expr_start..p.pos];
        p.pos += 2;

        // If the expression is an if/else block, parse and return it directly.
        const trimmed_expr = trimWhitespace(expr_raw);
        if (std.mem.startsWith(u8, trimmed_expr, "if (")) {
            var sub_pos: usize = 0;
            return parseIfNode(p.alc, trimmed_expr, &sub_pos);
        }

        if (try tryParseCall(p.alc, trimmed_expr)) |call_node| {
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
                .expr = try p.alc.dupe(u8, expr),
                .default = try p.alc.dupe(u8, default_val),
            } };
        }

        return Node{ .interpolation = try p.alc.dupe(u8, expr_raw) };
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
                    try props.append(alc, Prop{ .name = prop_name, .value = try alc.dupe(u8, prop_value) });
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
    pos.* += 4; // skip "if ("

    const cond_start = pos.*;
    var paren_depth: usize = 0;
    while (pos.* < str.len) {
        if (str[pos.*] == '(') paren_depth += 1;
        if (str[pos.*] == ')' and paren_depth == 0) break;
        if (str[pos.*] == ')') paren_depth -= 1;
        pos.* += 1;
    }
    if (pos.* >= str.len) return error.UnclosedParen;
    const condition = try alc.dupe(u8, str[cond_start..pos.*]);
    pos.* += 1; // skip ')'

    while (pos.* < str.len and str[pos.*] == ' ') pos.* += 1;
    if (pos.* >= str.len or str[pos.*] != '{') return error.ExpectedBrace;
    pos.* += 1; // skip '{'

    const then_start = pos.*;
    var brace_count: usize = 1;
    while (pos.* < str.len and brace_count > 0) {
        if (str[pos.*] == '{') brace_count += 1 else if (str[pos.*] == '}') brace_count -= 1;
        if (brace_count > 0) pos.* += 1;
    }
    if (pos.* >= str.len) return error.UnclosedBrace;
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
        pos.* += 6; // skip "else {"
        const else_start = pos.*;
        brace_count = 1;
        while (pos.* < str.len and brace_count > 0) {
            if (str[pos.*] == '{') brace_count += 1 else if (str[pos.*] == '}') brace_count -= 1;
            if (brace_count > 0) pos.* += 1;
        }
        if (pos.* >= str.len) return error.UnclosedBrace;
        const else_str = trimWhitespace(str[else_start..pos.*]);
        pos.* += 1; // skip '}'
        else_body = try parseTextNodes(alc, else_str);
    }

    return Node{ .if_node = .{ .condition = condition, .then_body = then_body, .else_body = else_body } };
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
    var brace_count: usize = undefined;
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
            if (pos >= str.len) return error.UnclosedInterpolation;
            const expr_raw = str[expr_start..pos];
            pos += 2;
            if (try tryParseCall(alc, trimWhitespace(expr_raw))) |call_node| {
                try nodes.append(alc, call_node);
                continue;
            }
            if (std.mem.indexOf(u8, expr_raw, " ?? ")) |idx| {
                const expr = trimWhitespace(expr_raw[0..idx]);
                const default_raw = trimWhitespace(expr_raw[idx + 4 ..]);
                const default_val = if (default_raw.len >= 2 and default_raw[0] == '"' and default_raw[default_raw.len - 1] == '"')
                    default_raw[1 .. default_raw.len - 1]
                else
                    default_raw;
                try nodes.append(alc, Node{ .interpolation_with_default = .{
                    .expr = try alc.dupe(u8, expr),
                    .default = try alc.dupe(u8, default_val),
                } });
            } else {
                try nodes.append(alc, Node{ .interpolation = try alc.dupe(u8, expr_raw) });
            }
        } else if (std.mem.startsWith(u8, remaining, "{ slot }")) {
            try nodes.append(alc, Node{ .interpolation = try alc.dupe(u8, "slot") });
            pos += "{ slot }".len;
        } else if (std.mem.startsWith(u8, remaining, "if (")) {
            try nodes.append(alc, try parseIfNode(alc, str, &pos));
        } else if (std.mem.startsWith(u8, remaining, "for (")) {
            pos += 5;
            const iter_start = pos;
            var paren_depth: usize = 0;
            while (pos < str.len) {
                if (str[pos] == '(') paren_depth += 1;
                if (str[pos] == ')' and paren_depth == 0) break;
                if (str[pos] == ')') paren_depth -= 1;
                pos += 1;
            }
            if (pos >= str.len) return error.UnclosedParen;
            const iterable = try alc.dupe(u8, str[iter_start..pos]);
            pos += 1;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos >= str.len or str[pos] != '|') return error.ExpectedCapture;
            pos += 1;
            const cap_start = pos;
            while (pos < str.len and str[pos] != '|') pos += 1;
            if (pos >= str.len) return error.UnclosedCapture;
            const capture = try alc.dupe(u8, str[cap_start..pos]);
            pos += 1;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos >= str.len or str[pos] != '{') return error.ExpectedBrace;
            pos += 1;
            const body_start = pos;
            brace_count = 1;
            while (pos < str.len and brace_count > 0) {
                if (str[pos] == '{') brace_count += 1 else if (str[pos] == '}') brace_count -= 1;
                if (brace_count > 0) pos += 1;
            }
            if (pos >= str.len) return error.UnclosedBrace;
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
                    (std.mem.startsWith(u8, r, "<script") or std.mem.startsWith(u8, r, "<style"))) break;
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

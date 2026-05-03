const std = @import("std");

const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    list: []const Value,
    object: std.StringHashMapUnmanaged(Value),
};

const Context = struct {
    values: std.StringHashMapUnmanaged(Value),

    pub fn init() Context {
        return .{ .values = .{} };
    }

    pub fn deinit(self: *Context, alc: std.mem.Allocator) void {
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            freeValue(alc, entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        self.values.deinit(alc);
    }

    pub fn set(self: *Context, alc: std.mem.Allocator, key: []const u8, value: Value) !void {
        try self.values.put(alc, try alc.dupe(u8, key), value);
    }

    pub fn get(self: *const Context, key: []const u8) ?Value {
        return self.values.get(key);
    }
};

fn structToContext(alc: std.mem.Allocator, data: anytype) !Context {
    var ctx = Context.init();
    errdefer ctx.deinit(alc);

    const T = @TypeOf(data);
    const info = @typeInfo(T);
    if (info != .@"struct") return ctx;

    inline for (info.@"struct".fields) |field| {
        const value = @field(data, field.name);
        const field_info = @typeInfo(@TypeOf(value));

        if (field_info == .pointer) {
            const ptr = field_info.pointer;
            if (ptr.child == u8 and ptr.size == .slice) {
                try ctx.set(alc, field.name, Value{ .string = try alc.dupe(u8, value) });
            } else if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    if (array_info.child == u8) {
                        const slice: []const u8 = value[0..];
                        try ctx.set(alc, field.name, Value{ .string = try alc.dupe(u8, slice) });
                    } else {
                        const slice = @as([]const array_info.child, value[0..]);
                        const elem_info = @typeInfo(array_info.child);
                        if (elem_info == .@"struct") {
                            try ctx.set(alc, field.name, Value{ .list = try structSliceToValueList(alc, slice) });
                        }
                    }
                } else if (child_info == .@"struct") {
                    try ctx.set(alc, field.name, Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try ctx.set(alc, field.name, Value{ .list = try structSliceToValueList(alc, value) });
                }
            }
        } else if (field_info == .bool) {
            try ctx.set(alc, field.name, Value{ .boolean = value });
        }
    }

    return ctx;
}

fn structSliceToValueList(alc: std.mem.Allocator, slice: anytype) ![]const Value {
    const list = try alc.alloc(Value, slice.len);
    errdefer {
        for (list[0..0]) |*v| freeValue(alc, v.*);
        alc.free(list);
    }
    for (slice, 0..) |elem, i| {
        list[i] = Value{ .object = try structToObject(alc, elem) };
    }
    return list;
}

fn structToObject(alc: std.mem.Allocator, data: anytype) !std.StringHashMapUnmanaged(Value) {
    var obj = std.StringHashMapUnmanaged(Value){};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            freeValue(alc, entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        obj.deinit(alc);
    }

    const info = @typeInfo(@TypeOf(data));
    if (info != .@"struct") return obj;

    inline for (info.@"struct".fields) |field| {
        const value = @field(data, field.name);
        const field_info = @typeInfo(@TypeOf(value));

        if (field_info == .pointer) {
            const ptr = field_info.pointer;
            if (ptr.child == u8 and ptr.size == .slice) {
                try obj.put(alc, try alc.dupe(u8, field.name), Value{ .string = try alc.dupe(u8, value) });
            } else if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    if (array_info.child == u8) {
                        const s: []const u8 = value[0..];
                        try obj.put(alc, try alc.dupe(u8, field.name), Value{ .string = try alc.dupe(u8, s) });
                    }
                } else if (child_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field.name), Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field.name), Value{ .list = try structSliceToValueList(alc, value) });
                }
            }
        } else if (field_info == .bool) {
            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .boolean = value });
        }
    }

    return obj;
}

fn isUpperCase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < s.len and s[start] == ' ') start += 1;
    while (end > start and s[end - 1] == ' ') end -= 1;
    return s[start..end];
}

const Prop = struct {
    name: []const u8,
    value: []const u8,
};

const Node = union(enum) {
    text: []const u8,
    interpolation: []const u8,
    if_node: struct {
        condition: []const u8,
        then_body: []Node,
        else_body: ?[]Node,
    },
    for_node: struct {
        iterable: []const u8,
        capture: []const u8,
        body: []Node,
    },
    component: struct {
        name: []const u8,
        props: []Prop,
        self_closing: bool,
        slot_content: ?[]const u8,
    },
    slot: void,
};

const Parser = struct {
    alc: std.mem.Allocator,
    template: []const u8,
    pos: usize,

    fn init(alc: std.mem.Allocator, template: []const u8) Parser {
        return Parser{ .alc = alc, .template = template, .pos = 0 };
    }

    fn parse(p: *Parser) !struct { nodes: []Node, layout: ?[]const u8 } {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(p.alc);

        var layout_name: ?[]const u8 = null;

        // Check for extends at the start
        if (p.pos + 8 <= p.template.len and std.mem.startsWith(u8, p.template[p.pos..], "extends ")) {
            p.pos += 8; // Skip "extends "

            if (p.pos < p.template.len and p.template[p.pos] == '"') {
                p.pos += 1; // Skip opening quote
                const name_start = p.pos;
                while (p.pos < p.template.len and p.template[p.pos] != '"') p.pos += 1;
                if (p.pos < p.template.len) {
                    layout_name = try p.alc.dupe(u8, p.template[name_start..p.pos]);
                    p.pos += 1; // Skip closing quote
                }
            }

            // Skip whitespace/newlines after extends
            while (p.pos < p.template.len and (p.template[p.pos] == ' ' or p.template[p.pos] == '\n' or p.template[p.pos] == '\r')) p.pos += 1;
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

        return .{ .nodes = try nodes.toOwnedSlice(p.alc), .layout = layout_name };
    }

    fn parseComponent(p: *Parser) !Node {
        p.pos += 1; // Skip '<'

        const name_start = p.pos;
        while (p.pos < p.template.len and p.template[p.pos] != ' ' and p.template[p.pos] != '/' and p.template[p.pos] != '>') {
            p.pos += 1;
        }
        const name = try p.alc.dupe(u8, p.template[name_start..p.pos]);

        var props: std.ArrayList(Prop) = .empty;
        defer props.deinit(p.alc);

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] != '/' and p.template[p.pos] != '>') {
            const prop_name_start = p.pos;
            while (p.pos < p.template.len and p.template[p.pos] != '=' and p.template[p.pos] != ' ' and p.template[p.pos] != '/' and p.template[p.pos] != '>') {
                p.pos += 1;
            }
            const prop_name = try p.alc.dupe(u8, p.template[prop_name_start..p.pos]);

            while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

            if (p.pos < p.template.len and p.template[p.pos] == '=') {
                p.pos += 1;

                while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

                if (p.pos + 2 <= p.template.len and std.mem.eql(u8, p.template[p.pos..(p.pos + 2)], "\"{")) {
                    p.pos += 2;
                    const val_start = p.pos;
                    while (p.pos < p.template.len) {
                        if (std.mem.startsWith(u8, p.template[p.pos..], "}\"")) {
                            break;
                        }
                        p.pos += 1;
                    }
                    const prop_value_raw = p.template[val_start..p.pos];
                    const prop_value = trimString(prop_value_raw);
                    p.pos += 2; // Skip '}"'

                    try props.append(p.alc, Prop{ .name = prop_name, .value = try p.alc.dupe(u8, prop_value) });
                } else {
                    p.alc.free(prop_name);
                }
            } else {
                p.alc.free(prop_name);
            }

            while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;
        }

        var self_closing = false;
        var slot_content: ?[]const u8 = null;

        if (p.pos < p.template.len and p.template[p.pos] == '/') {
            p.pos += 1;
            self_closing = true;
        }

        if (p.pos < p.template.len and p.template[p.pos] == '>') {
            p.pos += 1;
        }

        if (!self_closing) {
            const slot_start = p.pos;
            const close_tag = try std.fmt.allocPrint(p.alc, "</{s}>", .{name});
            defer p.alc.free(close_tag);

            if (std.mem.indexOf(u8, p.template[p.pos..], close_tag)) |idx| {
                const content = trimWhitespace(p.template[slot_start..(p.pos + idx)]);
                if (content.len > 0) {
                    slot_content = try p.alc.dupe(u8, content);
                }
                p.pos += idx + close_tag.len;
            }
        }

        return Node{ .component = .{ .name = name, .props = try props.toOwnedSlice(p.alc), .self_closing = self_closing, .slot_content = slot_content } };
    }

    fn parseIf(p: *Parser) !Node {
        p.pos += 4;

        const cond_start = p.pos;
        while (p.pos < p.template.len and p.template[p.pos] != ')') p.pos += 1;
        if (p.pos >= p.template.len) return error.UnclosedParen;
        const condition = try p.alc.dupe(u8, p.template[cond_start..p.pos]);
        p.pos += 1;

        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos >= p.template.len or p.template[p.pos] != '{') return error.ExpectedBrace;
        p.pos += 1;

        const then_start = p.pos;
        var brace_count: usize = 1;
        while (p.pos < p.template.len and brace_count > 0) {
            if (p.template[p.pos] == '{') brace_count += 1 else if (p.template[p.pos] == '}') brace_count -= 1;
            if (brace_count > 0) p.pos += 1;
        }
        if (p.pos >= p.template.len) return error.UnclosedBrace;

        const then_str = trimWhitespace(p.template[then_start..p.pos]);
        p.pos += 1;

        const then_body = try parseTextNodes(p.alc, then_str);

        var else_body: ?[]Node = null;
        while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;

        if (p.pos + 6 <= p.template.len and std.mem.eql(u8, p.template[p.pos..(p.pos + 6)], "else {")) {
            p.pos += 6;

            const else_start = p.pos;
            brace_count = 1;
            while (p.pos < p.template.len and brace_count > 0) {
                if (p.template[p.pos] == '{') brace_count += 1 else if (p.template[p.pos] == '}') brace_count -= 1;
                if (brace_count > 0) p.pos += 1;
            }
            if (p.pos >= p.template.len) return error.UnclosedBrace;

            const else_str = trimWhitespace(p.template[else_start..p.pos]);
            p.pos += 1;
            else_body = try parseTextNodes(p.alc, else_str);
        }

        return Node{ .if_node = .{ .condition = condition, .then_body = then_body, .else_body = else_body } };
    }

    fn parseFor(p: *Parser) !Node {
        p.pos += 5;

        const iter_start = p.pos;
        while (p.pos < p.template.len and p.template[p.pos] != ')') p.pos += 1;
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
        while (p.pos < p.template.len) {
            if (std.mem.startsWith(u8, p.template[p.pos..], " }")) break;
            p.pos += 1;
        }
        if (p.pos >= p.template.len) return error.UnclosedInterpolation;
        const expr = try p.alc.dupe(u8, p.template[expr_start..p.pos]);
        p.pos += 2;

        return Node{ .interpolation = expr };
    }

    fn parseText(p: *Parser) !Node {
        const start = p.pos;
        while (p.pos < p.template.len) {
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

fn parseTextNodes(alc: std.mem.Allocator, str: []const u8) ![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer nodes.deinit(alc);

    var pos: usize = 0;
    var brace_count: usize = undefined;
    while (pos < str.len) {
        const remaining = str[pos..];
        if (std.mem.startsWith(u8, remaining, "{ ")) {
            pos += 2;
            const expr_start = pos;
            while (pos < str.len) {
                if (std.mem.startsWith(u8, str[pos..], " }")) break;
                pos += 1;
            }
            const expr = try alc.dupe(u8, str[expr_start..pos]);
            pos += 2;
            try nodes.append(alc, Node{ .interpolation = expr });
        } else if (std.mem.startsWith(u8, remaining, "{ slot }")) {
            try nodes.append(alc, Node{ .slot = {} });
            pos += "{ slot }".len;
        } else if (std.mem.startsWith(u8, remaining, "if (")) {
            pos += 4;
            const cond_start = pos;
            while (pos < str.len and str[pos] != ')') pos += 1;
            if (pos >= str.len) return error.UnclosedParen;
            const condition = try alc.dupe(u8, str[cond_start..pos]);
            pos += 1;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos >= str.len or str[pos] != '{') return error.ExpectedBrace;
            pos += 1;
            const then_start = pos;
            brace_count = 1;
            while (pos < str.len and brace_count > 0) {
                if (str[pos] == '{') brace_count += 1 else if (str[pos] == '}') brace_count -= 1;
                if (brace_count > 0) pos += 1;
            }
            if (pos >= str.len) return error.UnclosedBrace;
            const then_str = str[then_start..pos];
            pos += 1;
            const then_body = try parseTextNodes(alc, then_str);
            var else_body: ?[]Node = null;
            while (pos < str.len and str[pos] == ' ') pos += 1;
            if (pos + 6 <= str.len and std.mem.eql(u8, str[pos..(pos + 6)], "else {")) {
                pos += 6;
                const else_start = pos;
                brace_count = 1;
                while (pos < str.len and brace_count > 0) {
                    if (str[pos] == '{') brace_count += 1 else if (str[pos] == '}') brace_count -= 1;
                    if (brace_count > 0) pos += 1;
                }
                if (pos >= str.len) return error.UnclosedBrace;
                const else_str = str[else_start..pos];
                pos += 1;
                else_body = try parseTextNodes(alc, else_str);
            }
            try nodes.append(alc, Node{ .if_node = .{ .condition = condition, .then_body = then_body, .else_body = else_body } });
        } else if (std.mem.startsWith(u8, remaining, "for (")) {
            pos += 5;
            const iter_start = pos;
            while (pos < str.len and str[pos] != ')') pos += 1;
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
        } else {
            const start = pos;
            while (pos < str.len) {
                const r = str[pos..];
                if (std.mem.startsWith(u8, r, "{ ")) break;
                if (std.mem.startsWith(u8, r, "{ slot }")) break;
                if (std.mem.startsWith(u8, r, "if (")) break;
                if (std.mem.startsWith(u8, r, "for (")) break;
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

fn isRootTemplate(template_str: []const u8) bool {
    return std.mem.indexOf(u8, template_str, "<html") != null;
}

pub const Template = struct {
    nodes: []Node,
    allocator: std.mem.Allocator,
    components: ?std.StringHashMapUnmanaged([]const u8) = null,
    layout: ?[]const u8 = null,
    is_root: bool = false,

    pub fn init(alc: std.mem.Allocator, template_str: []const u8) !Template {
        var parser = Parser.init(alc, template_str);
        const result = try parser.parse();

        const is_root = isRootTemplate(template_str);

        return Template{
            .nodes = result.nodes,
            .allocator = alc,
            .layout = result.layout,
            .is_root = is_root,
        };
    }

    pub fn deinit(self: *Template) void {
        for (self.nodes) |node| freeNode(node, self.allocator);
        self.allocator.free(self.nodes);
        if (self.layout) |l| self.allocator.free(l);
    }

    pub fn render(self: *Template, context: anytype, alc: std.mem.Allocator) ![]const u8 {
        var ctx = try structToContext(alc, context);
        defer ctx.deinit(alc);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(alc);

        for (self.nodes) |node| {
            try renderNode(node, &ctx, alc, &result, self.components);
        }

        const content = try result.toOwnedSlice(alc);
        defer alc.free(content);

        // If layout is specified, wrap content in layout
        if (self.layout) |layout_name| {
            if (self.components) |comps| {
                if (comps.get(layout_name)) |layout_template| {
                    // Create layout context with slot content
                    var layout_ctx = Context.init();
                    defer layout_ctx.deinit(alc);

                    // Set slot to the page content
                    try layout_ctx.set(alc, "slot", Value{ .string = try alc.dupe(u8, content) });

                    // Parse and render layout
                    var layout_parser = Parser.init(alc, layout_template);
                    const layout_result = try layout_parser.parse();
                    defer {
                        for (layout_result.nodes) |n| freeNode(n, alc);
                        alc.free(layout_result.nodes);
                    }

                    var layout_result_bytes: std.ArrayList(u8) = .empty;
                    defer layout_result_bytes.deinit(alc);

                    for (layout_result.nodes) |n| {
                        try renderNode(n, &layout_ctx, alc, &layout_result_bytes, self.components);
                    }

                    return layout_result_bytes.toOwnedSlice(alc);
                }
            }
        }

        return try alc.dupe(u8, content);
    }
};

fn freeNode(node: Node, alc: std.mem.Allocator) void {
    switch (node) {
        .text => |s| alc.free(s),
        .interpolation => |s| alc.free(s),
        .if_node => |ifn| {
            alc.free(ifn.condition);
            for (ifn.then_body) |n| freeNode(n, alc);
            alc.free(ifn.then_body);
            if (ifn.else_body) |eb| {
                for (eb) |n| freeNode(n, alc);
                alc.free(eb);
            }
        },
        .for_node => |fnn| {
            alc.free(fnn.iterable);
            alc.free(fnn.capture);
            for (fnn.body) |n| freeNode(n, alc);
            alc.free(fnn.body);
        },
        .component => |comp| {
            alc.free(comp.name);
            for (comp.props) |prop| {
                alc.free(prop.name);
                alc.free(prop.value);
            }
            alc.free(comp.props);
            if (comp.slot_content) |sc| alc.free(sc);
        },
        .slot => {},
    }
}

fn renderNode(node: Node, ctx: *Context, alc: std.mem.Allocator, result: *std.ArrayList(u8), components: ?std.StringHashMapUnmanaged([]const u8)) !void {
    switch (node) {
        .text => |text| {
            try result.appendSlice(alc, text);
        },
        .interpolation => |expr| {
            const value = resolveValue(ctx, expr);
            if (value) |v| {
                const str = try valueToString(v, alc);
                try result.appendSlice(alc, str);
                alc.free(str);
            }
        },
        .if_node => |ifn| {
            const cond = evalBool(ctx, ifn.condition);
            if (cond) {
                for (ifn.then_body) |n| try renderNode(n, ctx, alc, result, components);
            } else if (ifn.else_body) |eb| {
                for (eb) |n| try renderNode(n, ctx, alc, result, components);
            }
        },
        .for_node => |fnn| {
            if (ctx.get(fnn.iterable)) |value| {
                if (value == .list) {
                    for (value.list) |elem| {
                        var loop_ctx = Context.init();
                        defer loop_ctx.deinit(alc);
                        switch (elem) {
                            .string => try loop_ctx.set(alc, fnn.capture, Value{ .string = try alc.dupe(u8, elem.string) }),
                            .object => {
                                var obj_copy = std.StringHashMapUnmanaged(Value){};
                                var iter = elem.object.iterator();
                                while (iter.next()) |entry| {
                                    try obj_copy.put(alc, try alc.dupe(u8, entry.key_ptr.*), try dupeValue(alc, entry.value_ptr.*));
                                }
                                try loop_ctx.set(alc, fnn.capture, Value{ .object = obj_copy });
                            },
                            else => {},
                        }
                        for (fnn.body) |n| try renderNode(n, &loop_ctx, alc, result, components);
                    }
                }
            }
        },
        .component => |comp| {
            if (components) |comps| {
                if (comps.get(comp.name)) |comp_template_str| {
                    var comp_parser = Parser.init(alc, comp_template_str);
                    const comp_nodes = try comp_parser.parse();
                    defer {
                        for (comp_nodes.nodes) |n| freeNode(n, alc);
                        alc.free(comp_nodes.nodes);
                    }

                    var comp_ctx = Context.init();
                    defer comp_ctx.deinit(alc);

                    for (comp.props) |prop| {
                        if (ctx.get(prop.value)) |val| {
                            try comp_ctx.set(alc, prop.name, try dupeValue(alc, val));
                        } else {
                            try comp_ctx.set(alc, prop.name, Value{ .string = try alc.dupe(u8, prop.value) });
                        }
                    }

                    if (comp.slot_content) |sc| {
                        try comp_ctx.set(alc, "slot", Value{ .string = try alc.dupe(u8, sc) });
                    }

                    for (comp_nodes.nodes) |n| {
                        try renderNode(n, &comp_ctx, alc, result, components);
                    }
                }
            }
        },
        .slot => {
            if (ctx.get("slot")) |value| {
                if (value == .string) {
                    try result.appendSlice(alc, value.string);
                }
            }
        },
    }
}

fn freeValue(alc: std.mem.Allocator, value: Value) void {
    switch (value) {
        .string => |s| alc.free(s),
        .list => |list| {
            for (list) |v| freeValue(alc, v);
            alc.free(list);
        },
        .object => |*obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                freeValue(alc, entry.value_ptr.*);
                alc.free(entry.key_ptr.*);
            }
            @constCast(obj).deinit(alc);
        },
        else => {},
    }
}

fn resolveValue(ctx: *const Context, expr: []const u8) ?Value {
    if (std.mem.indexOfScalar(u8, expr, '.')) |dot_pos| {
        const first = expr[0..dot_pos];
        const rest = expr[dot_pos + 1 ..];
        if (ctx.get(first)) |outer| {
            if (outer == .object) {
                if (outer.object.get(rest)) |inner| {
                    return inner;
                }
            }
        }
        return null;
    }
    return ctx.get(expr);
}

fn dupeValue(alc: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| Value{ .string = try alc.dupe(u8, s) },
        .boolean => |b| Value{ .boolean = b },
        .list => |list| {
            const new_list = try alc.alloc(Value, list.len);
            for (list, 0..) |v, i| {
                new_list[i] = try dupeValue(alc, v);
            }
            return Value{ .list = new_list };
        },
        .object => |obj| {
            var new_obj = std.StringHashMapUnmanaged(Value){};
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try new_obj.put(alc, try alc.dupe(u8, entry.key_ptr.*), try dupeValue(alc, entry.value_ptr.*));
            }
            return Value{ .object = new_obj };
        },
    };
}

fn evalBool(ctx: *Context, expr: []const u8) bool {
    if (resolveValue(ctx, expr)) |value| {
        if (value == .boolean) return value.boolean;
    }
    return false;
}

fn valueToString(value: Value, alc: std.mem.Allocator) ![]const u8 {
    switch (value) {
        .string => |s| return try alc.dupe(u8, s),
        .boolean => |b| return if (b) try alc.dupe(u8, "true") else try alc.dupe(u8, "false"),
        else => return try alc.dupe(u8, ""),
    }
}

fn trimString(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n' or s[start] == '\r')) start += 1;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

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

    const Item = struct { name: []const u8 };
    const items = &[_]Item{ .{ .name = "A" }, .{ .name = "B" } };

    const template_str = "for (items) |i| { if (nonexistent) { X } else { { i.name } } }";
    var tmpl = try Template.init(alc, template_str);
    defer tmpl.deinit();

    const context = .{ .items = items };
    const result = try tmpl.render(context, alc);
    defer alc.free(result);
    try std.testing.expectEqualStrings("AB", result);
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

    const User = struct {
        name: []const u8,
        active: bool,
    };

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

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

    pub fn clone(self: *const Context, alc: std.mem.Allocator) !Context {
        var c = Context.init();
        errdefer c.deinit(alc);
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            try c.values.put(alc, try alc.dupe(u8, entry.key_ptr.*), try dupeValue(alc, entry.value_ptr.*));
        }
        return c;
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
                        } else if (elem_info == .pointer) {
                            const elem_ptr = elem_info.pointer;
                            if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                                try ctx.set(alc, field.name, Value{ .list = try stringSliceToValueList(alc, slice) });
                            }
                        }
                    }
                } else if (child_info == .@"struct") {
                    try ctx.set(alc, field.name, Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try ctx.set(alc, field.name, Value{ .list = try structSliceToValueList(alc, value) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try ctx.set(alc, field.name, Value{ .list = try stringSliceToValueList(alc, value) });
                    }
                }
            }
        } else if (field_info == .bool) {
            try ctx.set(alc, field.name, Value{ .boolean = value });
        } else if (field_info == .int or field_info == .comptime_int) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try ctx.set(alc, field.name, Value{ .string = str });
        } else if (field_info == .float or field_info == .comptime_float) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try ctx.set(alc, field.name, Value{ .string = str });
        } else if (field_info == .array) {
            const arr = field_info.array;
            if (arr.child != u8) {
                const slice = @as([]const arr.child, &value);
                const elem_info = @typeInfo(arr.child);
                if (elem_info == .@"struct") {
                    try ctx.set(alc, field.name, Value{ .list = try structSliceToValueList(alc, slice) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try ctx.set(alc, field.name, Value{ .list = try stringSliceToValueList(alc, slice) });
                    }
                }
            }
        } else if (field_info == .@"struct") {
            try ctx.set(alc, field.name, Value{ .object = try structToObject(alc, value) });
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

fn stringSliceToValueList(alc: std.mem.Allocator, slice: anytype) ![]const Value {
    const list = try alc.alloc(Value, slice.len);
    errdefer alc.free(list);
    for (slice, 0..) |elem, i| {
        list[i] = Value{ .string = try alc.dupe(u8, elem) };
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
                    } else {
                        const slice = @as([]const array_info.child, value[0..]);
                        const elem_info = @typeInfo(array_info.child);
                        if (elem_info == .@"struct") {
                            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .list = try structSliceToValueList(alc, slice) });
                        } else if (elem_info == .pointer) {
                            const elem_ptr = elem_info.pointer;
                            if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                                try obj.put(alc, try alc.dupe(u8, field.name), Value{ .list = try stringSliceToValueList(alc, slice) });
                            }
                        }
                    }
                } else if (child_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field.name), Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field.name), Value{ .list = try structSliceToValueList(alc, value) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try obj.put(alc, try alc.dupe(u8, field.name), Value{ .list = try stringSliceToValueList(alc, value) });
                    }
                }
            }
        } else if (field_info == .bool) {
            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .boolean = value });
        } else if (field_info == .int or field_info == .comptime_int) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .string = str });
        } else if (field_info == .float or field_info == .comptime_float) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .string = str });
        } else if (field_info == .@"struct") {
            try obj.put(alc, try alc.dupe(u8, field.name), Value{ .object = try structToObject(alc, value) });
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
    interpolation_with_default: struct {
        expr: []const u8,
        default: []const u8,
    },
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

        return .{ .nodes = try nodes.toOwnedSlice(p.alc), .layout = layout_name };
    }

    fn parseComponent(p: *Parser) !Node {
        return parseComponentNode(p.alc, p.template, &p.pos);
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

        while (p.pos < p.template.len and (p.template[p.pos] == ' ' or p.template[p.pos] == '\n' or p.template[p.pos] == '\r')) p.pos += 1;

        if (p.pos + 9 <= p.template.len and std.mem.eql(u8, p.template[p.pos..(p.pos + 9)], "else if (")) {
            p.pos += 9;
            const ei_cond_start = p.pos;
            while (p.pos < p.template.len and p.template[p.pos] != ')') p.pos += 1;
            if (p.pos >= p.template.len) return error.UnclosedParen;
            const ei_condition = try p.alc.dupe(u8, p.template[ei_cond_start..p.pos]);
            p.pos += 1;
            while (p.pos < p.template.len and p.template[p.pos] == ' ') p.pos += 1;
            if (p.pos >= p.template.len or p.template[p.pos] != '{') return error.ExpectedBrace;
            p.pos += 1;
            const ei_then_start = p.pos;
            brace_count = 1;
            while (p.pos < p.template.len and brace_count > 0) {
                if (p.template[p.pos] == '{') brace_count += 1 else if (p.template[p.pos] == '}') brace_count -= 1;
                if (brace_count > 0) p.pos += 1;
            }
            if (p.pos >= p.template.len) return error.UnclosedBrace;
            const ei_then_str = trimWhitespace(p.template[ei_then_start..p.pos]);
            p.pos += 1;
            const ei_then_body = try parseTextNodes(p.alc, ei_then_str);
            var ei_else_body: ?[]Node = null;
            while (p.pos < p.template.len and (p.template[p.pos] == ' ' or p.template[p.pos] == '\n' or p.template[p.pos] == '\r')) p.pos += 1;
            if (p.pos + 6 <= p.template.len and std.mem.eql(u8, p.template[p.pos..(p.pos + 6)], "else {")) {
                p.pos += 6;
                const ei_else_start = p.pos;
                brace_count = 1;
                while (p.pos < p.template.len and brace_count > 0) {
                    if (p.template[p.pos] == '{') brace_count += 1 else if (p.template[p.pos] == '}') brace_count -= 1;
                    if (brace_count > 0) p.pos += 1;
                }
                if (p.pos >= p.template.len) return error.UnclosedBrace;
                const ei_else_str = trimWhitespace(p.template[ei_else_start..p.pos]);
                p.pos += 1;
                ei_else_body = try parseTextNodes(p.alc, ei_else_str);
            }
            var nested_nodes = try p.alc.alloc(Node, 1);
            nested_nodes[0] = Node{ .if_node = .{ .condition = ei_condition, .then_body = ei_then_body, .else_body = ei_else_body } };
            else_body = nested_nodes;
        } else if (p.pos + 6 <= p.template.len and std.mem.eql(u8, p.template[p.pos..(p.pos + 6)], "else {")) {
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
        const expr_raw = p.template[expr_start..p.pos];
        p.pos += 2;

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
            // FIX: Skip <script>...</script> blocks — do not process template syntax inside them
            if (std.mem.startsWith(u8, p.template[p.pos..], "<script")) {
                while (p.pos < p.template.len and p.template[p.pos] != '>') p.pos += 1;
                if (p.pos < p.template.len) p.pos += 1;
                while (p.pos < p.template.len) {
                    if (std.mem.startsWith(u8, p.template[p.pos..], "</script>")) {
                        p.pos += 9;
                        break;
                    }
                    p.pos += 1;
                }
                continue;
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

fn skipWhitespace(template: []const u8, pos: *usize) void {
    while (pos.* < template.len and (template[pos.*] == ' ' or template[pos.*] == '\n' or template[pos.*] == '\r' or template[pos.*] == '\t')) pos.* += 1;
}

fn parseComponentNode(alc: std.mem.Allocator, template: []const u8, pos: *usize) !Node {
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

fn parseTextNodes(alc: std.mem.Allocator, str: []const u8) ![]Node {
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
    while (pos < str.len) {
        const remaining = str[pos..];
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
            while (pos < str.len and (str[pos] == ' ' or str[pos] == '\n' or str[pos] == '\r')) pos += 1;
            if (pos + 9 <= str.len and std.mem.eql(u8, str[pos..(pos + 9)], "else if (")) {
                pos += 9;
                const ei_cond_start = pos;
                while (pos < str.len and str[pos] != ')') pos += 1;
                if (pos >= str.len) return error.UnclosedParen;
                const ei_condition = try alc.dupe(u8, str[ei_cond_start..pos]);
                pos += 1;
                while (pos < str.len and str[pos] == ' ') pos += 1;
                if (pos >= str.len or str[pos] != '{') return error.ExpectedBrace;
                pos += 1;
                const ei_then_start = pos;
                brace_count = 1;
                while (pos < str.len and brace_count > 0) {
                    if (str[pos] == '{') brace_count += 1 else if (str[pos] == '}') brace_count -= 1;
                    if (brace_count > 0) pos += 1;
                }
                if (pos >= str.len) return error.UnclosedBrace;
                const ei_then_str = str[ei_then_start..pos];
                pos += 1;
                const ei_then_body = try parseTextNodes(alc, ei_then_str);
                var ei_else_body: ?[]Node = null;
                while (pos < str.len and (str[pos] == ' ' or str[pos] == '\n' or str[pos] == '\r')) pos += 1;
                if (pos + 9 <= str.len and std.mem.eql(u8, str[pos..(pos + 9)], "else if (")) {
                    const rest_nodes = try parseTextNodes(alc, str[pos..]);
                    pos = str.len;
                    ei_else_body = rest_nodes;
                } else if (pos + 6 <= str.len and std.mem.eql(u8, str[pos..(pos + 6)], "else {")) {
                    pos += 6;
                    const ei_else_start = pos;
                    brace_count = 1;
                    while (pos < str.len and brace_count > 0) {
                        if (str[pos] == '{') brace_count += 1 else if (str[pos] == '}') brace_count -= 1;
                        if (brace_count > 0) pos += 1;
                    }
                    if (pos >= str.len) return error.UnclosedBrace;
                    const ei_else_str = str[ei_else_start..pos];
                    pos += 1;
                    ei_else_body = try parseTextNodes(alc, ei_else_str);
                }
                var nested_nodes = try alc.alloc(Node, 1);
                nested_nodes[0] = Node{ .if_node = .{ .condition = ei_condition, .then_body = ei_then_body, .else_body = ei_else_body } };
                else_body = nested_nodes;
            } else if (pos + 6 <= str.len and std.mem.eql(u8, str[pos..(pos + 6)], "else {")) {
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
        } else if (pos < str.len and str[pos] == '<' and pos + 1 < str.len and isUpperCase(str[pos + 1])) {
            const node = try parseComponentNode(alc, str, &pos);
            try nodes.append(alc, node);
        } else {
            const start = pos;
            while (pos < str.len) {
                const r = str[pos..];
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

        if (self.layout) |layout_name| {
            if (self.components) |comps| {
                if (comps.get(layout_name)) |layout_template| {
                    var slot_bufs = std.StringHashMapUnmanaged(std.ArrayList(u8)){};
                    defer {
                        var iter = slot_bufs.iterator();
                        while (iter.next()) |entry| {
                            entry.value_ptr.*.deinit(alc);
                            alc.free(entry.key_ptr.*);
                        }
                        slot_bufs.deinit(alc);
                    }

                    var cur_buf = std.ArrayList(u8).empty;
                    var cur_key: []const u8 = "slot";

                    for (self.nodes) |node| {
                        if (node == .interpolation) {
                            const expr = node.interpolation;
                            if (std.mem.startsWith(u8, expr, "slot_")) {
                                const key = try alc.dupe(u8, cur_key);
                                try slot_bufs.put(alc, key, cur_buf);
                                cur_key = expr;
                                cur_buf = std.ArrayList(u8).empty;
                                continue;
                            }
                        }
                        try renderNode(node, &ctx, alc, &cur_buf, self.components);
                    }
                    {
                        const key = try alc.dupe(u8, cur_key);
                        try slot_bufs.put(alc, key, cur_buf);
                    }

                    var layout_ctx = try ctx.clone(alc);
                    defer layout_ctx.deinit(alc);

                    var iter = slot_bufs.iterator();
                    while (iter.next()) |entry| {
                        try layout_ctx.set(alc, entry.key_ptr.*, Value{ .string = try alc.dupe(u8, entry.value_ptr.*.items) });
                    }

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

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(alc);

        for (self.nodes) |node| {
            try renderNode(node, &ctx, alc, &result, self.components);
        }

        return result.toOwnedSlice(alc);
    }
};

fn freeNode(node: Node, alc: std.mem.Allocator) void {
    switch (node) {
        .text => |s| alc.free(s),
        .interpolation => |s| alc.free(s),
        .interpolation_with_default => |iwd| {
            alc.free(iwd.expr);
            alc.free(iwd.default);
        },
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
            if (std.mem.eql(u8, expr, "slot")) {
                if (ctx.get("slot")) |value| {
                    if (value == .string and value.string.len > 0) {
                        var slot_parser = Parser.init(alc, value.string);
                        const slot_result = try slot_parser.parse();
                        defer {
                            for (slot_result.nodes) |n| freeNode(n, alc);
                            alc.free(slot_result.nodes);
                        }
                        for (slot_result.nodes) |n| {
                            try renderNode(n, ctx, alc, result, components);
                        }
                    }
                }
            } else {
                const value = resolveValue(ctx, expr);
                if (value) |v| {
                    const str = try valueToString(v, alc);
                    try result.appendSlice(alc, str);
                    alc.free(str);
                }
            }
        },
        .interpolation_with_default => |iwd| {
            const value = resolveValue(ctx, iwd.expr);
            if (value) |v| {
                const str = try valueToString(v, alc);
                defer alc.free(str);
                if (str.len > 0 and !std.mem.eql(u8, str, "false")) {
                    try result.appendSlice(alc, str);
                } else {
                    try result.appendSlice(alc, iwd.default);
                }
            } else {
                try result.appendSlice(alc, iwd.default);
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
                const template_str = comps.get(comp.name) orelse brk: {
                    var field_buf: [256]u8 = undefined;
                    var field_len: usize = 0;
                    for (comp.name, 0..) |c, i| {
                        if (c >= 'A' and c <= 'Z') {
                            if (i > 0) {
                                field_buf[field_len] = '_';
                                field_len += 1;
                            }
                            field_buf[field_len] = c + 32;
                        } else {
                            field_buf[field_len] = c;
                        }
                        field_len += 1;
                    }
                    break :brk comps.get(field_buf[0..field_len]);
                };
                if (template_str) |comp_template_str| {
                    var comp_parser = Parser.init(alc, comp_template_str);
                    const comp_nodes = try comp_parser.parse();
                    defer {
                        for (comp_nodes.nodes) |n| freeNode(n, alc);
                        alc.free(comp_nodes.nodes);
                    }

                    var comp_ctx = try ctx.clone(alc);
                    defer comp_ctx.deinit(alc);

                    for (comp.props) |prop| {
                        if (resolveValue(ctx, prop.value)) |val| {
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
        .slot => {},
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
    if (std.mem.indexOf(u8, expr, " != ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right_raw = trimWhitespace(expr[idx + 4 ..]);
        const right = if (right_raw.len >= 2 and right_raw[0] == '"' and right_raw[right_raw.len - 1] == '"')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;
        return !evalCompare(ctx, left, right);
    }
    if (std.mem.indexOf(u8, expr, " == ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right_raw = trimWhitespace(expr[idx + 4 ..]);
        const right = if (right_raw.len >= 2 and right_raw[0] == '"' and right_raw[right_raw.len - 1] == '"')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;
        return evalCompare(ctx, left, right);
    }
    if (std.mem.indexOf(u8, expr, " <= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .lte);
    }
    if (std.mem.indexOf(u8, expr, " >= ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 4 ..]);
        return evalNumCompare(ctx, left, right, .gte);
    }
    if (std.mem.indexOf(u8, expr, " < ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .lt);
    }
    if (std.mem.indexOf(u8, expr, " > ")) |idx| {
        const left = trimWhitespace(expr[0..idx]);
        const right = trimWhitespace(expr[idx + 2 ..]);
        return evalNumCompare(ctx, left, right, .gt);
    }

    if (resolveValue(ctx, expr)) |value| {
        if (value == .boolean) return value.boolean;
        if (value == .string) return value.string.len > 0 and !std.mem.eql(u8, value.string, "false");
    }
    return false;
}

fn evalCompare(ctx: *Context, left: []const u8, right: []const u8) bool {
    const resolved = resolveLen(ctx, left) catch return false;
    defer std.heap.page_allocator.free(resolved);
    return std.mem.eql(u8, resolved, right);
}

const Cmp = enum { lt, lte, gt, gte };

fn evalNumCompare(ctx: *Context, left: []const u8, right: []const u8, cmp: Cmp) bool {
    const resolved = resolveLen(ctx, left) catch return false;
    defer std.heap.page_allocator.free(resolved);
    const l = resolved;

    const lv = std.fmt.parseInt(i64, l, 10) catch return false;
    const rv = std.fmt.parseInt(i64, right, 10) catch return false;

    return switch (cmp) {
        .lt => lv < rv,
        .lte => lv <= rv,
        .gt => lv > rv,
        .gte => lv >= rv,
    };
}

fn resolveLen(ctx: *const Context, expr: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, expr, ".len")) |dot_idx| {
        const var_name = expr[0..dot_idx];
        if (ctx.get(var_name)) |v| {
            if (v == .list) {
                return try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{v.list.len});
            }
        }
        return try std.heap.page_allocator.dupe(u8, "0");
    }
    if (resolveValue(ctx, expr)) |v| {
        return try valueToString(v, std.heap.page_allocator);
    }
    return try std.heap.page_allocator.dupe(u8, "");
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

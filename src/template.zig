const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    list: std.ArrayList(*Context),
    object: *Context,
};

pub const Context = struct {
    values: std.StringHashMapUnmanaged(Value),

    pub fn init() Context {
        return .{ .values = .{} };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| allocator.free(s),
                .list => |*list| list.deinit(allocator),
                .object => |obj| {
                    obj.deinit(allocator);
                    allocator.destroy(obj);
                },
            }
        }
        self.values.deinit(allocator);
    }

    pub fn clear(self: *Context, allocator: std.mem.Allocator) void {
        self.values.clearAndFree(allocator);
    }

    pub fn set(self: *Context, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.values.put(allocator, key, Value{ .string = try allocator.dupe(u8, value) });
    }

    pub fn setList(self: *Context, allocator: std.mem.Allocator, key: []const u8, items: std.ArrayList(*Context)) !void {
        try self.values.put(allocator, key, Value{ .list = items });
    }

    pub fn setObject(self: *Context, allocator: std.mem.Allocator, key: []const u8, obj: *Context) !void {
        try self.values.put(allocator, key, Value{ .object = obj });
    }

    pub fn get(self: *const Context, key: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, key, '.')) |dot_idx| {
            const first = std.mem.trim(u8, key[0..dot_idx], " ");
            const rest = std.mem.trim(u8, key[dot_idx + 1 ..], " ");
            if (self.values.get(first)) |v| {
                return switch (v) {
                    .object => |obj| obj.get(rest),
                    .list => |list| {
                        if (std.mem.indexOfScalar(u8, rest, '.')) |inner_dot| {
                            const idx_str = rest[0..inner_dot];
                            const field = rest[inner_dot + 1 ..];
                            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
                            if (idx < list.items.len) {
                                return list.items[idx].get(field);
                            }
                            return null;
                        }
                        return null;
                    },
                    else => null,
                };
            }
            return null;
        }
        if (self.values.get(key)) |v| {
            return switch (v) {
                .string => |s| s,
                .object => |obj| obj.get(key),
                .list => null,
            };
        }
        return null;
    }

    pub fn getValue(self: *const Context, key: []const u8) ?Value {
        if (std.mem.indexOfScalar(u8, key, '.')) |dot_idx| {
            const first = std.mem.trim(u8, key[0..dot_idx], " ");
            const rest = std.mem.trim(u8, key[dot_idx + 1 ..], " ");
            if (self.values.get(first)) |v| {
                return switch (v) {
                    .object => |obj| obj.getValue(rest),
                    .list => |list| {
                        if (std.mem.indexOfScalar(u8, rest, '.')) |inner_dot| {
                            const idx_str = rest[0..inner_dot];
                            const field = rest[inner_dot + 1 ..];
                            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
                            if (idx < list.items.len) {
                                return list.items[idx].getValue(field);
                            }
                            return null;
                        }
                        return null;
                    },
                    else => null,
                };
            }
            return null;
        }
        return self.values.get(key);
    }
};

fn parseTag(content: []const u8) ?struct { name: []const u8, args: []const u8 } {
    const trimmed = std.mem.trim(u8, content, " ");
    if (std.mem.startsWith(u8, trimmed, "for ")) {
        const args = trimmed[4..];
        if (std.mem.indexOf(u8, args, " in ") != null) {
            return .{
                .name = "for",
                .args = args,
            };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "endfor")) {
        return .{ .name = "endfor", .args = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "if ")) {
        const args = trimmed[3..];
        return .{ .name = "if", .args = args };
    }
    if (std.mem.startsWith(u8, trimmed, "else")) {
        return .{ .name = "else", .args = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "endif")) {
        return .{ .name = "endif", .args = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "include ")) {
        const args = trimmed[8..];
        return .{ .name = "include", .args = args };
    }
    return null;
}

fn isTruthy(context: *const Context, key: []const u8) bool {
    if (context.get(key)) |value| {
        return value.len > 0;
    }
    if (context.getValue(key)) |val| {
        switch (val) {
            .string => |s| return s.len > 0,
            .list => |l| return l.items.len > 0,
            .object => return true,
        }
    }
    return false;
}

fn findEndIf(template: []const u8, start: usize) ?usize {
    var i = start;
    var depth: usize = 1;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) {
                tag_end += 1;
            }
            if (tag_end < template.len) {
                const tag_content = template[tag_start..tag_end];
                if (parseTag(tag_content)) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "if")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, tag.name, "endif")) {
                        depth -= 1;
                        if (depth == 0) {
                            return tag_end + 2;
                        }
                    }
                }
                i = tag_end + 2;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn findElse(template: []const u8, start: usize, end: usize) ?usize {
    var i = start;
    var depth: usize = 1;
    while (i < end) {
        if (i + 1 < end and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < end and !(template[tag_end] == '%' and tag_end + 1 < end and template[tag_end + 1] == '}')) {
                tag_end += 1;
            }
            if (tag_end < end) {
                const tag_content = template[tag_start..tag_end];
                if (parseTag(tag_content)) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "if")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, tag.name, "endif")) {
                        depth -= 1;
                    } else if (std.mem.eql(u8, tag.name, "else") and depth == 1) {
                        return tag_end + 2;
                    }
                }
                i = tag_end + 2;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn findEndFor(template: []const u8, start: usize) ?usize {
    var i = start;
    var depth: usize = 1;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) {
                tag_end += 1;
            }
            if (tag_end < template.len) {
                const tag_content = template[tag_start..tag_end];
                if (parseTag(tag_content)) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "for")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, tag.name, "endfor")) {
                        depth -= 1;
                        if (depth == 0) {
                            return tag_end + 2;
                        }
                    }
                }
                i = tag_end + 2;
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return null;
}

fn parseForArgs(args: []const u8) ?struct { item_var: []const u8, list_var: []const u8 } {
    if (std.mem.indexOf(u8, args, " in ")) |in_idx| {
        const item_var = std.mem.trim(u8, args[0..in_idx], " ");
        const list_var = std.mem.trim(u8, args[in_idx + 4 ..], " ");
        if (item_var.len > 0 and list_var.len > 0) {
            return .{
                .item_var = item_var,
                .list_var = list_var,
            };
        }
    }
    return null;
}

pub const TemplateRegistry = struct {
    pub fn get(comptime name: [:0]const u8) []const u8 {
        return @embedFile(name);
    }
};

fn getTemplate(templates: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(templates);
    if (T == EmptyTemplates) return null;
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return @field(templates, field.name);
        }
    }
    return null;
}

fn renderTemplate(template: []const u8, context: *Context, allocator: std.mem.Allocator, templates: anytype) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, template.len);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) {
                tag_end += 1;
            }
            if (tag_end >= template.len) {
                try result.appendSlice(allocator, "{%");
                i += 2;
                continue;
            }
            const tag_content = std.mem.trim(u8, template[tag_start..tag_end], " ");
            if (parseTag(tag_content)) |tag| {
                if (std.mem.startsWith(u8, tag.name, "for")) {
                    if (parseForArgs(tag.args)) |for_args| {
                        var list_val = context.getValue(for_args.list_var);
                        if (list_val == null and for_args.list_var.len > 2 and for_args.list_var[0] == '[' and for_args.list_var[for_args.list_var.len - 1] == ']') {
                            const key = for_args.list_var[1 .. for_args.list_var.len - 1];
                            list_val = context.getValue(key);
                        }
                        if (list_val) |lv| {
                            if (lv == .list) {
                                const body_start = tag_end + 2;
                                if (findEndFor(template, body_start)) |end_for| {
                                    const body = template[body_start..end_for];
                                    for (lv.list.items) |item_ctx| {
                                        var loop_ctx = Context.init();
                                        try loop_ctx.values.put(allocator, for_args.item_var, Value{ .object = item_ctx });
                                        const rendered = try renderTemplate(body, &loop_ctx, allocator, templates);
                                        loop_ctx.clear(allocator);
                                        defer allocator.free(rendered);
                                        try result.appendSlice(allocator, rendered);
                                    }
                                    i = end_for;
                                    continue;
                                }
                            } else if (lv == .object) {
                                const body_start = tag_end + 2;
                                if (findEndFor(template, body_start)) |end_for| {
                                    const body = template[body_start..end_for];
                                    var loop_ctx = Context.init();
                                    try loop_ctx.values.put(allocator, for_args.item_var, Value{ .object = lv.object });
                                    const rendered = try renderTemplate(body, &loop_ctx, allocator, templates);
                                    loop_ctx.clear(allocator);
                                    defer allocator.free(rendered);
                                    try result.appendSlice(allocator, rendered);
                                    i = end_for;
                                    continue;
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, tag.name, "if")) {
                    const body_start = tag_end + 2;
                    if (findEndIf(template, body_start)) |end_if| {
                        const else_pos = findElse(template, body_start, end_if);
                        if (isTruthy(context, tag.args)) {
                            const if_body_end = else_pos orelse end_if;
                            const if_body = template[body_start..if_body_end];
                            const rendered = try renderTemplate(if_body, context, allocator, templates);
                            defer allocator.free(rendered);
                            try result.appendSlice(allocator, rendered);
                        } else if (else_pos) |else_start| {
                            const else_body = template[else_start..end_if];
                            const rendered = try renderTemplate(else_body, context, allocator, templates);
                            defer allocator.free(rendered);
                            try result.appendSlice(allocator, rendered);
                        }
                        i = end_if;
                        continue;
                    }
                } else if (std.mem.eql(u8, tag.name, "include")) {
                    const filename = std.mem.trim(u8, tag.args, "\" ");
                    if (getTemplate(templates, filename)) |included| {
                        const rendered = try renderTemplate(included, context, allocator, templates);
                        defer allocator.free(rendered);
                        try result.appendSlice(allocator, rendered);
                    }
                    i = tag_end + 2;
                    continue;
                }
            }
            i = tag_end + 2;
        } else if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const start = i + 2;
            var end = start;
            while (end < template.len and !(template[end] == '}' and end + 1 < template.len and template[end + 1] == '}')) {
                end += 1;
            }
            if (end >= template.len) {
                try result.appendSlice(allocator, "{{");
                i += 2;
                continue;
            }
            const var_name = std.mem.trim(u8, template[start..end], " ");
            if (context.get(var_name)) |value| {
                try result.appendSlice(allocator, value);
            }
            i = end + 2;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

const EmptyTemplates = struct {};

pub fn renderContext(template: []const u8, context: *Context, allocator: std.mem.Allocator) ![]u8 {
    return renderTemplate(template, context, allocator, EmptyTemplates{});
}

pub fn renderWithTemplates(comptime T: type, template: []const u8, context: *Context, allocator: std.mem.Allocator) ![]u8 {
    return renderTemplate(template, context, allocator, @as(T, undefined));
}

pub fn renderWith(template: []const u8, context: *Context, allocator: std.mem.Allocator, templates: anytype) ![]u8 {
    return renderTemplate(template, context, allocator, templates);
}

pub fn renderStr(template: []const u8, context: *Context) ![]u8 {
    return renderContext(template, context, std.heap.page_allocator);
}

fn fieldToString(value: anytype) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .float => {
            return std.fmt.allocPrint(std.heap.page_allocator, "{}", .{value}) catch @panic("alloc fail");
        },
        .bool => {
            return if (value) "true" else "false";
        },
        .pointer => {
            return value;
        },
        .optional => {
            if (value) |v| {
                return fieldToString(v);
            }
            return "";
        },
        else => {
            @compileError("Unsupported type: " ++ @typeName(T));
        },
    }
}

fn structToContext(comptime T: type, value: T, allocator: std.mem.Allocator) !*Context {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Expected struct, got " ++ @typeName(T));

    var ctx = try allocator.create(Context);
    ctx.* = Context.init();

    inline for (info.@"struct".fields) |field| {
        const field_value = @field(value, field.name);
        const str = fieldToString(field_value);
        try ctx.set(allocator, field.name, str);
    }

    return ctx;
}

fn sliceToContextList(comptime T: type, slice: []const T, allocator: std.mem.Allocator) !std.ArrayList(*Context) {
    var list = std.ArrayList(*Context).empty;
    for (slice) |item| {
        const ctx = try structToContext(T, item, allocator);
        try list.append(allocator, ctx);
    }
    return list;
}

pub fn render(template: []const u8, data: anytype, allocator: std.mem.Allocator) ![]u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);

    var context = try allocator.create(Context);
    context.* = Context.init();
    defer {
        context.deinit(allocator);
        allocator.destroy(context);
    }

    switch (info) {
        .@"struct" => {
            const type_name = @typeName(T);
            if (std.mem.indexOfScalar(u8, type_name, '.')) |dot| {
                if (std.mem.eql(u8, type_name[dot..], ".ArrayList")) {
                    const list = try sliceToContextList(info.@"struct".fields[0].type.@"struct".fields[0].type, data.items, allocator);
                    try context.setList(allocator, "items", list);
                } else {
                    inline for (info.@"struct".fields) |field| {
                        const field_value = @field(data, field.name);
                        const str = fieldToString(field_value);
                        try context.set(allocator, field.name, str);
                    }
                }
            } else {
                inline for (info.@"struct".fields) |field| {
                    const field_value = @field(data, field.name);
                    const str = fieldToString(field_value);
                    try context.set(allocator, field.name, str);
                }
            }
        },
        .array => |arr| {
            const list = try sliceToContextList(arr.child, &data, allocator);
            try context.setList(allocator, "items", list);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                const list = try sliceToContextList(ptr.child, data, allocator);
                try context.setList(allocator, "items", list);
            } else {
                @compileError("Unsupported pointer type for render: " ++ @typeName(T));
            }
        },
        else => @compileError("Unsupported type for render: " ++ @typeName(T)),
    }

    return renderTemplate(template, context, allocator, EmptyTemplates{});
}

test "basic variable substitution" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "name", "World");
    const result = try renderStr("Hello {{ name }}!", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello World!", result);
}

test "multiple variables" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "greeting", "Hello");
    try context.set(std.heap.page_allocator, "target", "Zig");
    const result = try renderStr("{{ greeting }}, {{ target }}!", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello, Zig!", result);
}

test "missing variable" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    const result = try renderStr("Hello {{ name }}!", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello !", result);
}

test "no variables" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    const result = try renderStr("Hello World!", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello World!", result);
}

test "for loop" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    var items = std.ArrayList(*Context).empty;
    for (0..3) |j| {
        var item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try item.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Item{}", .{j}));
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);

    const result = try renderStr("{% for item in items %}{{ item.name }}{% endfor %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Item0Item1Item2", result);
}

test "for loop with separator" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    var items = std.ArrayList(*Context).empty;
    for (0..3) |j| {
        var item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try item.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Item{}", .{j}));
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);

    const result = try renderStr("{% for item in items %}{{ item.name }},{% endfor %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Item0,Item1,Item2,", result);
}

test "for loop empty list" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    const items = std.ArrayList(*Context).empty;
    try context.setList(std.heap.page_allocator, "items", items);

    const result = try renderStr("{% for item in items %}{{ item.name }}{% endfor %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "", result);
}

test "nested for loop" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    var outer_item = try std.heap.page_allocator.create(Context);
    outer_item.* = Context.init();
    try outer_item.set(std.heap.page_allocator, "title", "Outer");

    var inner_items = std.ArrayList(*Context).empty;
    for (0..2) |j| {
        var inner = try std.heap.page_allocator.create(Context);
        inner.* = Context.init();
        try inner.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Inner{}", .{j}));
        try inner_items.append(std.heap.page_allocator, inner);
    }
    try outer_item.setList(std.heap.page_allocator, "children", inner_items);
    try context.setObject(std.heap.page_allocator, "outer", outer_item);

    const result = try renderStr("{% for outer in [outer] %}{{ outer.title }}: {% for child in outer.children %}{{ child.name }}{% endfor %}{% endfor %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Outer: Inner0Inner1", result);
}

test "if truthy" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "show", "yes");

    const result = try renderStr("{% if show %}visible{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "visible", result);
}

test "if falsy - missing variable" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    const result = try renderStr("{% if show %}visible{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "", result);
}

test "if falsy - empty string" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "show", "");

    const result = try renderStr("{% if show %}visible{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "", result);
}

test "if else truthy" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "show", "yes");

    const result = try renderStr("{% if show %}yes{% else %}no{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "yes", result);
}

test "if else falsy" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    const result = try renderStr("{% if show %}yes{% else %}no{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "no", result);
}

test "if with variable substitution" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "name", "World");

    const result = try renderStr("{% if name %}Hello {{ name }}{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello World", result);
}

test "nested if" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "a", "1");
    try context.set(std.heap.page_allocator, "b", "2");

    const result = try renderStr("{% if a %}{% if b %}{{ a }}-{{ b }}{% endif %}{% endif %}", &context);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "1-2", result);
}

const item_template = "<li>{{ name }}</li>";

const TestTemplates = struct {
    item: []const u8,
    item_tmpl: []const u8 = item_template,

    pub fn init() TestTemplates {
        return .{ .item = item_template };
    }
};

test "include template" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "name", "Test");

    const templates = TestTemplates{ .item = undefined, .item_tmpl = item_template };
    const result = try renderWith("{% include \"item_tmpl\" %}", &context, std.heap.page_allocator, templates);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "<li>Test</li>", result);
}

test "include with loop" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    var items = std.ArrayList(*Context).empty;
    for (0..3) |j| {
        var item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try item.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Item{}", .{j}));
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);

    const templates = TestTemplates{ .item = undefined, .item_tmpl = "<li>{{ i.name }}</li>" };
    const result = try renderWith("<ul>{% for i in items %}{% include \"item_tmpl\" %}{% endfor %}</ul>", &context, std.heap.page_allocator, templates);

    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "<ul><li>Item0</li><li>Item1</li><li>Item2</li></ul>", result);
}

const TestProduct = struct {
    name: []const u8,
    price: []const u8,
};

test "render with struct" {
    const product = TestProduct{ .name = "Widget", .price = "9.99" };
    const result = try render("Hello {{ name }}! Price: {{ price }}", product, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello Widget! Price: 9.99", result);
}

test "render with struct and for loop" {
    const products = [_]TestProduct{
        .{ .name = "Widget", .price = "9.99" },
        .{ .name = "Gadget", .price = "19.99" },
    };
    const result = try render("{% for p in items %}{{ p.name }}: {{ p.price }},{% endfor %}", products, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Widget: 9.99,Gadget: 19.99,", result);
}

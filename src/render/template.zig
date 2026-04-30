const std = @import("std");

fn isMdContent(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, "\n\r ");
    return std.mem.startsWith(u8, trimmed, "<!-- md -->");
}

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
            return .{ .name = "for", .args = args };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "endfor")) return .{ .name = "endfor", .args = "" };
    if (std.mem.startsWith(u8, trimmed, "if ")) return .{ .name = "if", .args = trimmed[3..] };
    if (std.mem.startsWith(u8, trimmed, "elif ")) return .{ .name = "elif", .args = trimmed[5..] };
    if (std.mem.startsWith(u8, trimmed, "else")) return .{ .name = "else", .args = "" };
    if (std.mem.startsWith(u8, trimmed, "endif")) return .{ .name = "endif", .args = "" };
    if (std.mem.startsWith(u8, trimmed, "include ")) return .{ .name = "include", .args = trimmed[8..] };
    if (std.mem.startsWith(u8, trimmed, "block ")) return .{ .name = "block", .args = trimmed[6..] };
    if (std.mem.startsWith(u8, trimmed, "template ")) return .{ .name = "template", .args = trimmed[9..] };
    if (std.mem.startsWith(u8, trimmed, "extends ")) return .{ .name = "extends", .args = trimmed[8..] };
    if (std.mem.eql(u8, trimmed, "end")) return .{ .name = "end", .args = "" };
    if (std.mem.eql(u8, trimmed, "raw")) return .{ .name = "raw", .args = "" };
    if (std.mem.eql(u8, trimmed, "endraw")) return .{ .name = "endraw", .args = "" };
    return null;
}

fn compareNumeric(a: []const u8, b: []const u8) i32 {
    const a_int = std.fmt.parseInt(i64, a, 10) catch null;
    const b_int = std.fmt.parseInt(i64, b, 10) catch null;
    if (a_int != null and b_int != null) {
        if (a_int.? < b_int.?) return -1;
        if (a_int.? > b_int.?) return 1;
        return 0;
    }
    // Fall back to lexicographic comparison
    const order = std.mem.order(u8, a, b);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn evalCondition(context: *const Context, expr: []const u8) bool {
    const trimmed_expr = std.mem.trim(u8, expr, " ");

    // Handle negation operator
    if (std.mem.startsWith(u8, trimmed_expr, "!")) {
        const inner_expr = std.mem.trim(u8, trimmed_expr[1..], " ");
        return !evalCondition(context, inner_expr);
    }

    // Handle equality and inequality operators
    if (std.mem.indexOf(u8, trimmed_expr, "==")) |eq_idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..eq_idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[eq_idx + 2 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return std.mem.eql(u8, left_value, right_value);
    }

    if (std.mem.indexOf(u8, trimmed_expr, "!=")) |neq_idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..neq_idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[neq_idx + 2 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return !std.mem.eql(u8, left_value, right_value);
    }

    // Handle comparison operators (>=, <=, >, <) — check longer operators first
    if (std.mem.indexOf(u8, trimmed_expr, ">=")) |idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[idx + 2 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return compareNumeric(left_value, right_value) >= 0;
    }
    if (std.mem.indexOf(u8, trimmed_expr, "<=")) |idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[idx + 2 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return compareNumeric(left_value, right_value) <= 0;
    }
    if (std.mem.indexOf(u8, trimmed_expr, ">")) |idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[idx + 1 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return compareNumeric(left_value, right_value) > 0;
    }
    if (std.mem.indexOf(u8, trimmed_expr, "<")) |idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[idx + 1 ..], " ");
        const left_value = getValueForComparison(context, left);
        const right_value = getValueForComparison(context, right);
        return compareNumeric(left_value, right_value) < 0;
    }

    // Handle logical operators (and/or)
    if (std.mem.indexOf(u8, trimmed_expr, " and ")) |and_idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..and_idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[and_idx + 5 ..], " ");
        return evalCondition(context, left) and evalCondition(context, right);
    }

    if (std.mem.indexOf(u8, trimmed_expr, " or ")) |or_idx| {
        const left = std.mem.trim(u8, trimmed_expr[0..or_idx], " ");
        const right = std.mem.trim(u8, trimmed_expr[or_idx + 4 ..], " ");
        return evalCondition(context, left) or evalCondition(context, right);
    }

    // Handle boolean strings specially
    if (context.get(trimmed_expr)) |value| {
        // Treat "false", "0", "no" as falsy
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no")) {
            return false;
        }
        // Treat "true", "1", "yes" as truthy
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes")) {
            return true;
        }
        // Default: non-empty string is truthy
        return value.len > 0;
    }

    if (context.getValue(trimmed_expr)) |val| {
        switch (val) {
            .string => |s| {
                // Handle boolean strings for string values too
                if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "no")) {
                    return false;
                }
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes")) {
                    return true;
                }
                return s.len > 0;
            },
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
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "if")) depth += 1 else if (std.mem.eql(u8, tag.name, "endif")) {
                        depth -= 1;
                        if (depth == 0) return tag_end + 2;
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
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
            while (tag_end < end and !(template[tag_end] == '%' and tag_end + 1 < end and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < end) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "if")) depth += 1 else if (std.mem.eql(u8, tag.name, "endif")) depth -= 1 else if (std.mem.eql(u8, tag.name, "else") and depth == 1) return tag_end + 2;
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }
    return null;
}

const IfBranch = struct {
    kind: enum { elif, @"else", endif },
    args: []const u8,
    body_start: usize,
    body_end: usize,
    next_pos: usize, // position right after the closing tag (endif → after {% endif %})
};

fn findNextIfBranch(template: []const u8, start: usize) ?IfBranch {
    var i = start;
    var depth: usize = 1;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end >= template.len) return null;
            if (parseTag(template[tag_start..tag_end])) |tag| {
                if (std.mem.startsWith(u8, tag.name, "if")) {
                    depth += 1;
                } else if (std.mem.eql(u8, tag.name, "endif")) {
                    depth -= 1;
                    if (depth == 0) {
                        return IfBranch{ .kind = .endif, .args = "", .body_start = i, .body_end = i, .next_pos = tag_end + 2 };
                    }
                } else if (depth == 1 and std.mem.eql(u8, tag.name, "elif")) {
                    return IfBranch{ .kind = .elif, .args = tag.args, .body_start = tag_end + 2, .body_end = i, .next_pos = tag_end + 2 };
                } else if (depth == 1 and std.mem.eql(u8, tag.name, "else")) {
                    return IfBranch{ .kind = .@"else", .args = "", .body_start = tag_end + 2, .body_end = i, .next_pos = tag_end + 2 };
                }
            }
            i = tag_end + 2;
        } else i += 1;
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
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.startsWith(u8, tag.name, "for")) depth += 1 else if (std.mem.eql(u8, tag.name, "endfor")) {
                        depth -= 1;
                        if (depth == 0) return tag_end + 2;
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }
    return null;
}

fn findEndBlock(template: []const u8, start: usize) ?usize {
    var i = start;
    var depth: usize = 1;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.eql(u8, tag.name, "block")) depth += 1 else if (std.mem.eql(u8, tag.name, "end")) {
                        depth -= 1;
                        if (depth == 0) return tag_end + 2;
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }
    return null;
}

fn findEndRaw(template: []const u8, start: usize) ?usize {
    var i = start;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.eql(u8, tag.name, "endraw")) {
                        return i;
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }
    return null;
}

fn parseForArgs(args: []const u8) ?struct { item_var: []const u8, list_var: []const u8 } {
    if (std.mem.indexOf(u8, args, " in ")) |in_idx| {
        const item_var = std.mem.trim(u8, args[0..in_idx], " ");
        const list_var = std.mem.trim(u8, args[in_idx + 4 ..], " ");
        if (item_var.len > 0 and list_var.len > 0) return .{ .item_var = item_var, .list_var = list_var };
    }
    return null;
}

fn extractBlocks(template: []const u8, allocator: std.mem.Allocator) !std.StringHashMapUnmanaged([]const u8) {
    var blocks = std.StringHashMapUnmanaged([]const u8){};
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                if (parseTag(template[tag_start..tag_end])) |tag| {
                    if (std.mem.eql(u8, tag.name, "block")) {
                        const block_name = std.mem.trim(u8, tag.args, "\" ");
                        const body_start = tag_end + 2;
                        if (findEndBlock(template, body_start)) |end_block| {
                            const body = template[body_start..end_block];
                            try blocks.put(allocator, try allocator.dupe(u8, block_name), body);
                            i = end_block;
                            continue;
                        }
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }
    return blocks;
}

fn copyContext(parent: *const Context, allocator: std.mem.Allocator) !*Context {
    const ctx = try allocator.create(Context);
    ctx.* = Context.init();
    var iter = parent.values.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |s| {
                try ctx.values.put(allocator, entry.key_ptr.*, Value{ .string = try allocator.dupe(u8, s) });
            },
            .list => |*list| {
                var new_list = std.ArrayList(*Context).empty;
                for (list.items) |item| {
                    const new_item = try allocator.create(Context);
                    new_item.* = Context.init();
                    var item_iter = item.values.iterator();
                    while (item_iter.next()) |item_entry| {
                        switch (item_entry.value_ptr.*) {
                            .string => |s| {
                                try new_item.values.put(allocator, item_entry.key_ptr.*, Value{ .string = try allocator.dupe(u8, s) });
                            },
                            else => {
                                try new_item.values.put(allocator, item_entry.key_ptr.*, item_entry.value_ptr.*);
                            },
                        }
                    }
                    try new_list.append(allocator, new_item);
                }
                try ctx.values.put(allocator, entry.key_ptr.*, Value{ .list = new_list });
            },
            .object => |obj| {
                const new_obj = try allocator.create(Context);
                new_obj.* = Context.init();
                var obj_iter = obj.values.iterator();
                while (obj_iter.next()) |obj_entry| {
                    switch (obj_entry.value_ptr.*) {
                        .string => |s| {
                            try new_obj.values.put(allocator, obj_entry.key_ptr.*, Value{ .string = try allocator.dupe(u8, s) });
                        },
                        else => {
                            try new_obj.values.put(allocator, obj_entry.key_ptr.*, obj_entry.value_ptr.*);
                        },
                    }
                }
                try ctx.values.put(allocator, entry.key_ptr.*, Value{ .object = new_obj });
            },
        }
    }
    return ctx;
}

pub const TemplateRegistry = struct {
    pub fn get(comptime name: [:0]const u8) []const u8 {
        return @embedFile(name);
    }
};

fn getTemplate(templates: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(templates);
    if (T == EmptyTemplates) return null;

    // Check if templates is a slice of TemplateEntry (web.zig format)
    if (comptime isTemplateEntrySlice(T)) {
        for (templates) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.content;
        }
        return null;
    }

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name)) return @field(templates, field.name);
    }
    return null;
}

fn isTemplateEntrySlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .slice) return false;
    const child_info = @typeInfo(ptr.child);
    if (child_info != .@"struct") return false;
    const fields = child_info.@"struct".fields;
    if (fields.len != 2) return false;
    if (!std.mem.eql(u8, fields[0].name, "name")) return false;
    if (!std.mem.eql(u8, fields[1].name, "content")) return false;
    return true;
}

pub fn getTemplateByName(comptime T: type, name: []const u8) ![]const u8 {
    const name_normalized = blk: {
        var normalized: [256]u8 = undefined;
        var j: usize = 0;
        for (name) |c| {
            if (c == '/') {
                normalized[j] = '_';
            } else {
                normalized[j] = c;
            }
            j += 1;
        }
        break :blk normalized[0..j];
    };

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, name_normalized)) {
            const instance: T = undefined;
            return @field(instance, field.name);
        }
    }

    return error.TemplateNotFound;
}

test "getTemplateByName finds template by name" {
    const Stub = struct { tmpl: []const u8 = "hello" };
    const tmpl = try getTemplateByName(Stub, "tmpl");
    try std.testing.expect(tmpl.len > 0);
}

test "getTemplateByName normalizes path to field name" {
    const Stub = struct { todo_index: []const u8 = "template content" };
    const tmpl = try getTemplateByName(Stub, "todo/index");
    try std.testing.expect(tmpl.len > 0);
}

test "parseTag recognizes extends" {
    if (parseTag("extends \"layout\"")) |tag| {
        try std.testing.expectEqualSlices(u8, "extends", tag.name);
    } else {
        try std.testing.expect(false);
    }
}

test "render with extends loads parent template" {
    // Test using render - this should trigger extends resolution
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    // Use renderWith which calls resolveExtends for us
    const child = "{% extends \"parent\" %}{% block \"content\" %}Hello{% end %}";
    const Templates = struct {
        parent: []const u8 = "LAYOUT{% template \"content\" %}END",
    };
    const templates: Templates = .{};
    const result = try renderWith(child, &context, std.heap.page_allocator, templates);
    defer std.heap.page_allocator.free(result);

    // Should have LAYOUT from parent and Hello from child block
    try std.testing.expect(std.mem.indexOf(u8, result, "LAYOUT") != null);
}

fn renderTemplate(template: []const u8, context: *Context, allocator: std.mem.Allocator, templates: anytype, blocks: ?*const std.StringHashMapUnmanaged([]const u8)) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, template.len);

    const md_mode = isMdContent(template);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end >= template.len) {
                try result.appendSlice(allocator, "{%");
                i += 2;
                continue;
            }
            const tag_content = std.mem.trim(u8, template[tag_start..tag_end], " ");
            if (parseTag(tag_content)) |tag| {
                const is_structural = std.mem.eql(u8, tag.name, "extends") or
                    std.mem.eql(u8, tag.name, "block") or
                    std.mem.eql(u8, tag.name, "end") or
                    std.mem.eql(u8, tag.name, "template") or
                    std.mem.eql(u8, tag.name, "raw") or
                    std.mem.eql(u8, tag.name, "endraw");
                if (md_mode and !is_structural) {
                    try result.appendSlice(allocator, template[i .. tag_end + 2]);
                    i = tag_end + 2;
                    continue;
                }
                if (std.mem.startsWith(u8, tag.name, "for")) {
                    if (parseForArgs(tag.args)) |for_args| {
                        var list_val = context.getValue(for_args.list_var);
                        if (list_val == null and for_args.list_var.len > 2 and for_args.list_var[0] == '[' and for_args.list_var[for_args.list_var.len - 1] == ']') {
                            list_val = context.getValue(for_args.list_var[1 .. for_args.list_var.len - 1]);
                        }
                        if (list_val) |lv| {
                            const body_start = tag_end + 2;
                            if (findEndFor(template, body_start)) |end_for| {
                                const body = template[body_start..end_for];
                                if (lv == .list) {
                                    for (lv.list.items) |item_ctx| {
                                        var loop_ctx = try copyContext(context, allocator);
                                        errdefer {
                                            loop_ctx.deinit(allocator);
                                            allocator.destroy(loop_ctx);
                                        }
                                        try loop_ctx.values.put(allocator, for_args.item_var, Value{ .object = item_ctx });
                                        {
                                            const rendered = try renderTemplate(body, loop_ctx, allocator, templates, null);
                                            loop_ctx.clear(allocator);
                                            defer allocator.free(rendered);
                                            try result.appendSlice(allocator, rendered);
                                        }
                                    }
                                } else if (lv == .object) {
                                    var loop_ctx = try copyContext(context, allocator);
                                    errdefer {
                                        loop_ctx.deinit(allocator);
                                        allocator.destroy(loop_ctx);
                                    }
                                    try loop_ctx.values.put(allocator, for_args.item_var, Value{ .object = lv.object });
                                    {
                                        const rendered = try renderTemplate(body, loop_ctx, allocator, templates, null);
                                        loop_ctx.clear(allocator);
                                        defer allocator.free(rendered);
                                        try result.appendSlice(allocator, rendered);
                                    }
                                }
                                i = end_for;
                                continue;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, tag.name, "if")) {
                    const body_start = tag_end + 2;
                    if (findEndIf(template, body_start)) |end_if| {
                        // Evaluate if condition
                        if (evalCondition(context, tag.args)) {
                            // if-body is from body_start to first elif/else/endif
                            if (findNextIfBranch(template, body_start)) |branch| {
                                const if_body = template[body_start..branch.body_end];
                                const rendered = try renderTemplate(if_body, context, allocator, templates, null);
                                defer allocator.free(rendered);
                                try result.appendSlice(allocator, rendered);
                            }
                        } else {
                            // Walk through elif/else branches
                            var pos = body_start;
                            var done = false;
                            while (!done) {
                                if (findNextIfBranch(template, pos)) |branch| {
                                    switch (branch.kind) {
                                        .elif => {
                                            if (evalCondition(context, branch.args)) {
                                                // Found true elif — find its end
                                                if (findNextIfBranch(template, branch.body_start)) |next| {
                                                    const elif_body = template[branch.body_start..next.body_end];
                                                    const rendered = try renderTemplate(elif_body, context, allocator, templates, null);
                                                    defer allocator.free(rendered);
                                                    try result.appendSlice(allocator, rendered);
                                                }
                                                done = true;
                                            } else {
                                                pos = branch.body_start;
                                            }
                                        },
                                        .@"else" => {
                                            // Render else body until endif
                                            // Find the endif to get the body range
                                            if (findNextIfBranch(template, branch.body_start)) |next| {
                                                const else_body = template[branch.body_start..next.body_end];
                                                const rendered = try renderTemplate(else_body, context, allocator, templates, null);
                                                defer allocator.free(rendered);
                                                try result.appendSlice(allocator, rendered);
                                            }
                                            done = true;
                                        },
                                        .endif => {
                                            done = true;
                                        },
                                    }
                                } else {
                                    done = true;
                                }
                            }
                        }
                        i = end_if;
                        continue;
                    }
                } else if (std.mem.eql(u8, tag.name, "include")) {
                    const filename = std.mem.trim(u8, tag.args, "\" ");
                    if (getTemplate(templates, filename)) |included| {
                        const rendered = try renderTemplate(included, context, allocator, templates, null);
                        defer allocator.free(rendered);
                        try result.appendSlice(allocator, rendered);
                    }
                    i = tag_end + 2;
                    continue;
                } else if (std.mem.eql(u8, tag.name, "template") and blocks != null) {
                    const block_name = std.mem.trim(u8, tag.args, "\" ");
                    if (blocks.?.get(block_name)) |block_content| {
                        const rendered = try renderTemplate(block_content, context, allocator, templates, blocks);
                        defer allocator.free(rendered);
                        try result.appendSlice(allocator, rendered);
                    }
                    i = tag_end + 2;
                    continue;
                } else if (std.mem.eql(u8, tag.name, "raw")) {
                    const body_start = tag_end + 2;
                    if (findEndRaw(template, body_start)) |end_raw| {
                        const raw_content = template[body_start..end_raw];
                        try result.appendSlice(allocator, raw_content);
                        i = end_raw + "{% endraw %}".len;
                        continue;
                    }
                }
            }
            i = tag_end + 2;
        } else if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            if (md_mode) {
                try result.append(allocator, template[i]);
                i += 1;
                continue;
            }
            const start = i + 2;
            var end = start;
            while (end < template.len and !(template[end] == '}' and end + 1 < template.len and template[end + 1] == '}')) end += 1;
            if (end >= template.len) {
                try result.appendSlice(allocator, "{{");
                i += 2;
                continue;
            }
            const var_name = std.mem.trim(u8, template[start..end], " ");
            // Handle .len on lists specially
            if (std.mem.endsWith(u8, var_name, ".len")) {
                const list_key = var_name[0 .. var_name.len - 4];
                if (context.getValue(list_key)) |val| {
                    if (val == .list) {
                        const len_str = try std.fmt.allocPrint(allocator, "{}", .{val.list.items.len});
                        defer allocator.free(len_str);
                        try result.appendSlice(allocator, len_str);
                    }
                }
            } else {
                const value = getValueWithFilter(context, var_name);
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

fn getValueWithFilter(context: *const Context, var_expr: []const u8) []const u8 {
    if (std.mem.indexOf(u8, var_expr, "|")) |pipe_idx| {
        const var_name = std.mem.trim(u8, var_expr[0..pipe_idx], " ");
        const filter_part = std.mem.trim(u8, var_expr[pipe_idx + 1 ..], " ");

        if (std.mem.startsWith(u8, filter_part, "default:")) {
            var fallback_part = std.mem.trim(u8, filter_part[8..], " ");
            // Handle quoted strings
            if (fallback_part.len >= 2 and fallback_part[0] == '"' and fallback_part[fallback_part.len - 1] == '"') {
                fallback_part = fallback_part[1 .. fallback_part.len - 1];
            }
            if (context.get(var_name)) |value| {
                if (value.len > 0) return value;
            }
            return fallback_part;
        }
    }

    // No filter or unknown filter - return original value or empty string
    return context.get(var_expr) orelse "";
}

fn getValueForComparison(context: *const Context, expr: []const u8) []const u8 {
    const trimmed_expr = std.mem.trim(u8, expr, " ");

    // Handle quoted strings
    if (trimmed_expr.len >= 2 and trimmed_expr[0] == '"' and trimmed_expr[trimmed_expr.len - 1] == '"') {
        return trimmed_expr[1 .. trimmed_expr.len - 1];
    }

    // Handle numeric literals
    _ = std.fmt.parseInt(i64, trimmed_expr, 10) catch {
        // Not a number — check for .len on lists
        if (std.mem.endsWith(u8, trimmed_expr, ".len")) {
            const list_key = trimmed_expr[0 .. trimmed_expr.len - 4];
            if (context.getValue(list_key)) |val| {
                if (val == .list) {
                    const n = val.list.items.len;
                    return std.fmt.allocPrint(std.heap.page_allocator, "{}", .{n}) catch "";
                }
            }
            return "0";
        }
        return context.get(trimmed_expr) orelse "";
    };
    return trimmed_expr;
}

const EmptyTemplates = struct {};

fn renderContext(template: []const u8, context: *Context, allocator: std.mem.Allocator) ![]u8 {
    return renderTemplate(template, context, allocator, EmptyTemplates{}, null);
}

fn renderWithTemplates(comptime T: type, template: []const u8, context: *Context, allocator: std.mem.Allocator) ![]u8 {
    return renderTemplate(template, context, allocator, @as(T, undefined), null);
}

fn renderWith(template: []const u8, context: *Context, allocator: std.mem.Allocator, templates: anytype) ![]u8 {
    const final_template = if (std.mem.indexOf(u8, template, "{% extends") != null)
        try resolveExtends(template, allocator, templates)
    else
        template;

    return renderTemplate(final_template, context, allocator, templates, null);
}

fn resolveExtends(template: []const u8, allocator: std.mem.Allocator, templates: anytype) ![]const u8 {
    var i: usize = 0;
    var parent_name: []const u8 = "";
    var child_blocks = std.StringHashMapUnmanaged([]const u8){};
    defer child_blocks.deinit(allocator);

    // Parse extends and blocks from child template
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '%') {
            const tag_start = i + 2;
            var tag_end = tag_start;
            while (tag_end < template.len and !(template[tag_end] == '%' and tag_end + 1 < template.len and template[tag_end + 1] == '}')) tag_end += 1;
            if (tag_end < template.len) {
                const tag_content = std.mem.trim(u8, template[tag_start..tag_end], " ");
                if (parseTag(tag_content)) |tag| {
                    if (std.mem.eql(u8, tag.name, "extends")) {
                        parent_name = std.mem.trim(u8, tag.args, "\" ");
                    } else if (std.mem.eql(u8, tag.name, "block")) {
                        const block_name = std.mem.trim(u8, tag.args, "\" ");
                        const body_start = tag_end + 2;
                        if (findEndBlock(template, body_start)) |end_block| {
                            const body = template[body_start..end_block];
                            try child_blocks.put(allocator, try allocator.dupe(u8, block_name), body);
                            i = end_block;
                            continue;
                        }
                    }
                }
                i = tag_end + 2;
            } else i += 1;
        } else i += 1;
    }

    // Load parent template
    if (parent_name.len == 0) return template;
    const parent_tmpl = getTemplate(templates, parent_name) orelse return template;

    // Extract parent blocks and merge with child blocks
    var parent_blocks = try extractBlocks(parent_tmpl, allocator);
    defer {
        var iter = parent_blocks.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        parent_blocks.deinit(allocator);
    }

    // Merge: child blocks override parent blocks
    var iter = child_blocks.iterator();
    while (iter.next()) |entry| {
        try parent_blocks.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }

    // Render parent with merged blocks
    var ctx = Context.init();
    return renderTemplate(parent_tmpl, &ctx, allocator, templates, &parent_blocks);
}

fn renderStr(template: []const u8, context: *Context) ![]u8 {
    return renderContext(template, context, std.heap.page_allocator);
}

fn fieldToString(allocator: std.mem.Allocator, value: anytype) []const u8 {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .int, .comptime_int => {
            return std.fmt.allocPrint(allocator, "{}", .{value}) catch "";
        },
        .float, .comptime_float => {
            return std.fmt.allocPrint(allocator, "{}", .{value}) catch "";
        },
        .bool => return if (value) "true" else "false",
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return value;
            return "";
        },
        .optional => {
            if (value) |v| return fieldToString(allocator, v);
            return "";
        },
        .array => |arr| {
            if (arr.child == u8) return &value;
            return "";
        },
        .@"struct", .@"enum", .@"union" => return "",
        else => return "",
    }
}

fn structToContext(comptime T: type, value: T, allocator: std.mem.Allocator) !*Context {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Expected struct, got " ++ @typeName(T));
    const ctx = try allocator.create(Context);
    ctx.* = Context.init();
    inline for (info.@"struct".fields) |field| {
        try setFieldValue(allocator, ctx, field.name, @field(value, field.name));
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

fn setFieldValue(allocator: std.mem.Allocator, context: *Context, name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |ptr| {
            // Slice of structs → named list
            if (ptr.size == .slice and ptr.child != u8) {
                if (comptime @typeInfo(ptr.child) == .@"struct") {
                    const list = try sliceToContextList(ptr.child, value, allocator);
                    try context.setList(allocator, name, list);
                    return;
                }
            }
            // []const u8 or []u8 — string slice
            if (ptr.size == .slice and ptr.child == u8) {
                try context.set(allocator, name, value);
                return;
            }
            if (ptr.size == .one) {
                const child_info = comptime @typeInfo(ptr.child);
                // *[N]T where T is struct → treat as slice of structs
                if (child_info == .array and comptime @typeInfo(child_info.array.child) == .@"struct") {
                    const elem_t = child_info.array.child;
                    const as_slice: []const elem_t = value;
                    const list = try sliceToContextList(elem_t, as_slice, allocator);
                    try context.setList(allocator, name, list);
                    return;
                }
                // *const [N:0]u8 — string literal
                if (child_info == .array and child_info.array.child == u8) {
                    try context.set(allocator, name, value);
                    return;
                }
            }
            try context.set(allocator, name, fieldToString(allocator, value));
        },
        .@"struct" => {
            const obj = try allocator.create(Context);
            obj.* = Context.init();
            inline for (info.@"struct".fields) |field| {
                try setFieldValue(allocator, obj, field.name, @field(value, field.name));
            }
            try context.setObject(allocator, name, obj);
        },
        .optional => {
            if (value) |v| try setFieldValue(allocator, context, name, v);
        },
        else => {
            try context.set(allocator, name, fieldToString(allocator, value));
        },
    }
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
            // Detect ArrayList by presence of 'items' slice field
            const is_array_list = comptime blk: {
                for (info.@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "items")) {
                        const fi = @typeInfo(f.type);
                        if (fi == .pointer and fi.pointer.size == .slice) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_array_list) {
                const child_type = @typeInfo(@TypeOf(data.items)).pointer.child;
                const list = try sliceToContextList(child_type, data.items, allocator);
                try context.setList(allocator, "items", list);
            } else {
                inline for (info.@"struct".fields) |field| {
                    try setFieldValue(allocator, context, field.name, @field(data, field.name));
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
        .optional => {
            if (data) |value| return render(template, value, allocator);
        },
        else => @compileError("Unsupported type for render: " ++ @typeName(T)),
    }

    return renderTemplate(template, context, allocator, EmptyTemplates{}, null);
}

pub fn renderBlock(template: []const u8, block_name: []const u8, data: anytype, allocator: std.mem.Allocator) ![]u8 {
    var blocks = try extractBlocks(template, allocator);
    defer {
        var iter = blocks.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        blocks.deinit(allocator);
    }

    const block_content = blocks.get(block_name) orelse return error.BlockNotFound;

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
            const is_array_list = comptime blk: {
                for (info.@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "items")) {
                        const fi = @typeInfo(f.type);
                        if (fi == .pointer and fi.pointer.size == .slice) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_array_list) {
                const child_type = @typeInfo(@TypeOf(data.items)).pointer.child;
                const list = try sliceToContextList(child_type, data.items, allocator);
                try context.setList(allocator, "items", list);
            } else {
                inline for (info.@"struct".fields) |field| {
                    try setFieldValue(allocator, context, field.name, @field(data, field.name));
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
                @compileError("Unsupported pointer type for renderBlock: " ++ @typeName(T));
            }
        },
        .optional => {
            if (data) |value| return renderBlock(template, block_name, value, allocator);
        },
        else => @compileError("Unsupported type for renderBlock: " ++ @typeName(T)),
    }

    return renderTemplate(block_content, context, allocator, EmptyTemplates{}, &blocks);
}

pub fn renderBlockWithTemplates(
    tmpl: []const u8,
    block_name: []const u8,
    data: anytype,
    allocator: std.mem.Allocator,
    templates: anytype,
) ![]u8 {
    var blocks = try extractBlocks(tmpl, allocator);
    defer {
        var iter = blocks.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        blocks.deinit(allocator);
    }

    const block_content = blocks.get(block_name) orelse return error.BlockNotFound;

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
            const is_array_list = comptime blk: {
                for (info.@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "items")) {
                        const fi = @typeInfo(f.type);
                        if (fi == .pointer and fi.pointer.size == .slice) break :blk true;
                    }
                }
                break :blk false;
            };
            if (is_array_list) {
                const child_type = @typeInfo(@TypeOf(data.items)).pointer.child;
                const list = try sliceToContextList(child_type, data.items, allocator);
                try context.setList(allocator, "items", list);
            } else {
                inline for (info.@"struct".fields) |field| {
                    try setFieldValue(allocator, context, field.name, @field(data, field.name));
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
                @compileError("Unsupported pointer type for renderBlockWithTemplates: " ++ @typeName(T));
            }
        },
        .optional => {
            if (data) |value| return renderBlockWithTemplates(tmpl, block_name, value, allocator, templates);
        },
        else => @compileError("Unsupported type for renderBlockWithTemplates: " ++ @typeName(T)),
    }

    return renderTemplate(block_content, context, allocator, templates, &blocks);
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

const TestDashboard = struct {
    total_str: []const u8,
    total_months: []const u8,
    summaries: []const TestProduct,
};

test "render with struct containing named slice field" {
    const rows = [_]TestProduct{
        .{ .name = "Julho/2025", .price = "R$ 4.644,25" },
        .{ .name = "Agosto/2025", .price = "R$ 5.482,31" },
    };
    const data = TestDashboard{
        .total_str = "R$ 50.504,97",
        .total_months = "8",
        .summaries = &rows,
    };
    const result = try render(
        "Total: {{ total_str }} ({{ total_months }} meses)\n{% for row in summaries %}{{ row.name }}: {{ row.price }}\n{% endfor %}",
        data,
        std.heap.page_allocator,
    );
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(
        u8,
        "Total: R$ 50.504,97 (8 meses)\nJulho/2025: R$ 4.644,25\nAgosto/2025: R$ 5.482,31\n",
        result,
    );
}

test "render with anonymous struct" {
    const result = try render("Hello {{ name }}!", .{ .name = "seven" }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Hello seven!", result);
}

test "block and template" {
    const tmpl =
        \\{% block "index" %}<!DOCTYPE html>
        \\<body>
        \\    <div id="count">
        \\        {% template "count" %}
        \\    </div>
        \\</body>
        \\</html>{% end %}
        \\
        \\{% block "count" %}Count {{ count }}{% end %}
    ;
    const result = try renderBlock(tmpl, "index", .{ .count = 42 }, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(
        u8,
        "<!DOCTYPE html>\n<body>\n    <div id=\"count\">\n        Count 42\n    </div>\n</body>\n</html>",
        result,
    );
}

// ===== NEW FEATURE TESTS =====

test "negation operator - truthy case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "is_expense", "false");
    const result = try renderStr("{% if !is_expense %}income{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "income", result);
}

test "negation operator - falsy case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "is_expense", "true");
    const result = try renderStr("{% if !is_expense %}income{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "negation operator - missing variable" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("{% if !empty %}has items{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "has items", result);
}

test "equality operator - true case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "locale", "pt_BR");
    const result = try renderStr("{% if locale == \"pt_BR\" %}R${% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "R$", result);
}

test "equality operator - false case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "locale", "en_US");
    const result = try renderStr("{% if locale == \"pt_BR\" %}R${% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "equality operator - empty string" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "status", "");
    const result = try renderStr("{% if status == \"\" %}empty{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "empty", result);
}

test "inequality operator - true case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "status", "inactive");
    const result = try renderStr("{% if status != \"active\" %}inactive{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "inactive", result);
}

test "inequality operator - false case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "status", "active");
    const result = try renderStr("{% if status != \"active\" %}inactive{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "and operator - both true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "active", "true");
    try context.set(std.heap.page_allocator, "verified", "yes");
    const result = try renderStr("{% if active and verified %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ok", result);
}

test "and operator - first false" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "active", "");
    try context.set(std.heap.page_allocator, "verified", "yes");
    const result = try renderStr("{% if active and verified %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "and operator - second false" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "active", "true");
    try context.set(std.heap.page_allocator, "verified", "");
    const result = try renderStr("{% if active and verified %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "or operator - first true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "error", "true");
    try context.set(std.heap.page_allocator, "warning", "");
    const result = try renderStr("{% if error or warning %}alert{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "alert", result);
}

test "or operator - second true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "error", "");
    try context.set(std.heap.page_allocator, "warning", "true");
    const result = try renderStr("{% if error or warning %}alert{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "alert", result);
}

test "or operator - both false" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "error", "");
    try context.set(std.heap.page_allocator, "warning", "");
    const result = try renderStr("{% if error or warning %}alert{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "default filter - variable exists" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "name", "John");
    const result = try renderStr("Hello {{ name | default:\"Anonymous\" }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Hello John", result);
}

test "default filter - missing variable" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("Hello {{ name | default:\"Anonymous\" }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Hello Anonymous", result);
}

test "default filter - empty string" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "amount", "");
    const result = try renderStr("Amount: {{ amount | default:\"0,00\" }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Amount: 0,00", result);
}

test "default filter - edge case with spaces" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("Value: {{ missing | default: \" fallback \" }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Value:  fallback ", result);
}

test "renderBlock with concatenated layout and view" {
    const layout =
        \\{% block "base" %}<!DOCTYPE html><html><body><main>{% template "content" %}</main></body></html>{% end %}
    ;
    const view =
        \\{% block "content" %}Hello World{% end %}
    ;

    const tmpl = try std.mem.concat(std.heap.page_allocator, u8, &.{ layout, view });
    defer std.heap.page_allocator.free(tmpl);

    const result = try renderBlock(tmpl, "base", .{}, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "<!DOCTYPE html><html><body><main>Hello World</main></body></html>", result);
}

test "raw block - variable syntax inside raw" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("{% raw %}{{ not_a_var }}{% endraw %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "{{ not_a_var }}", result);
}

test "raw block - template tags inside raw" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("{% raw %}{% if x %}{% endraw %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "{% if x %}", result);
}

test "raw block - mixed with normal content" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("Before {% raw %}{{ raw_var }}{% endraw %} After {{ name }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Before {{ raw_var }} After ", result);
}

test "raw block - multiple raw blocks" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const result = try renderStr("{% raw %}A{% endraw %} {{ x }} {% raw %}B{% endraw %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "A  B", result);
}

test "raw block - complex template syntax preserved" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const tmpl = "{% raw %}{% if condition %}\n  {{ variable }}\n{% endif %}\n{% for item in items %}{{ item }}{% endfor %}{% endraw %}";
    const result = try renderStr(tmpl, &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(
        u8,
        "{% if condition %}\n  {{ variable }}\n{% endif %}\n{% for item in items %}{{ item }}{% endfor %}",
        result,
    );
}

// ===== COMPARISON OPERATORS (>, <, >=, <=) =====

test "greater than - true case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "5");
    const result = try renderStr("{% if count > 3 %}big{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "big", result);
}

test "greater than - false case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "2");
    const result = try renderStr("{% if count > 3 %}big{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "greater than - equal case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "3");
    const result = try renderStr("{% if count > 3 %}big{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "less than - true case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "2");
    const result = try renderStr("{% if count < 10 %}small{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "small", result);
}

test "less than - false case" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "15");
    const result = try renderStr("{% if count < 10 %}small{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "greater than or equal - greater" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "5");
    const result = try renderStr("{% if count >= 3 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ok", result);
}

test "greater than or equal - equal" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "3");
    const result = try renderStr("{% if count >= 3 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ok", result);
}

test "greater than or equal - less" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "1");
    const result = try renderStr("{% if count >= 3 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "less than or equal - less" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "2");
    const result = try renderStr("{% if count <= 5 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ok", result);
}

test "less than or equal - equal" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "5");
    const result = try renderStr("{% if count <= 5 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "ok", result);
}

test "less than or equal - greater" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "count", "10");
    const result = try renderStr("{% if count <= 5 %}ok{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

// ===== .len PROPERTY ON LISTS =====

test "list .len - non-empty list" {
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
    const result = try renderStr("Count: {{ items.len }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Count: 3", result);
}

test "list .len - empty list" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const items = std.ArrayList(*Context).empty;
    try context.setList(std.heap.page_allocator, "items", items);
    const result = try renderStr("Count: {{ items.len }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Count: 0", result);
}

test "list .len with greater than - true" {
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
    const result = try renderStr("{% if items.len > 0 %}has items{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "has items", result);
}

test "list .len with greater than - false" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const items = std.ArrayList(*Context).empty;
    try context.setList(std.heap.page_allocator, "items", items);
    const result = try renderStr("{% if items.len > 0 %}has items{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "list .len with double digit - interpolation" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    var items = std.ArrayList(*Context).empty;
    for (0..11) |j| {
        var item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try item.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Item{}", .{j}));
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);
    const result = try renderStr("Count: {{ items.len }}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Count: 11", result);
}

test "list .len with double digit comparison" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    var items = std.ArrayList(*Context).empty;
    for (0..11) |j| {
        var item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try item.set(std.heap.page_allocator, "name", try std.fmt.allocPrint(std.heap.page_allocator, "Item{}", .{j}));
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);
    const result = try renderStr("{% if items.len > 10 %}has many items{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "has many items", result);
}

test "list .len with double digit - equals" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    var items = std.ArrayList(*Context).empty;
    for (0..11) |_| {
        const item = try std.heap.page_allocator.create(Context);
        item.* = Context.init();
        try items.append(std.heap.page_allocator, item);
    }
    try context.setList(std.heap.page_allocator, "items", items);
    const result = try renderStr("{% if items.len == 11 %}exactly 11{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "exactly 11", result);
}

// ===== ELIF TAG =====

test "elif - first condition true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "yes");
    try context.set(std.heap.page_allocator, "b", "no");
    const result = try renderStr("{% if a %}A{% elif b %}B{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "A", result);
}

test "elif - second condition true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "");
    try context.set(std.heap.page_allocator, "b", "yes");
    const result = try renderStr("{% if a %}A{% elif b %}B{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "B", result);
}

test "elif - all conditions false" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "");
    try context.set(std.heap.page_allocator, "b", "");
    const result = try renderStr("{% if a %}A{% elif b %}B{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "", result);
}

test "elif with else - first true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "yes");
    try context.set(std.heap.page_allocator, "b", "");
    const result = try renderStr("{% if a %}A{% elif b %}B{% else %}C{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "A", result);
}

test "elif with else - second true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "");
    try context.set(std.heap.page_allocator, "b", "yes");
    const result = try renderStr("{% if a %}A{% elif b %}B{% else %}C{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "B", result);
}

test "elif with else - none true" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "");
    try context.set(std.heap.page_allocator, "b", "");
    const result = try renderStr("{% if a %}A{% elif b %}B{% else %}C{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "C", result);
}

test "multiple elif" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "a", "");
    try context.set(std.heap.page_allocator, "b", "");
    try context.set(std.heap.page_allocator, "c", "yes");
    const result = try renderStr("{% if a %}A{% elif b %}B{% elif c %}C{% else %}D{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "C", result);
}

test "elif with comparison - statement scenario" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const txns = std.ArrayList(*Context).empty;
    var stmts = std.ArrayList(*Context).empty;
    var stmt = try std.heap.page_allocator.create(Context);
    stmt.* = Context.init();
    try stmt.set(std.heap.page_allocator, "period_label", "July 2025");
    try stmts.append(std.heap.page_allocator, stmt);
    try context.setList(std.heap.page_allocator, "statement_transactions", txns);
    try context.setList(std.heap.page_allocator, "statements", stmts);
    const tmpl = "{% if statement_transactions.len > 0 %}txns{% elif statements.len > 0 %}stmts{% else %}none{% endif %}";
    const result = try renderStr(tmpl, &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "stmts", result);
}

test "elif with comparison - all empty" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    const txns = std.ArrayList(*Context).empty;
    const stmts = std.ArrayList(*Context).empty;
    try context.setList(std.heap.page_allocator, "statement_transactions", txns);
    try context.setList(std.heap.page_allocator, "statements", stmts);
    const tmpl = "{% if statement_transactions.len > 0 %}txns{% elif statements.len > 0 %}stmts{% else %}none{% endif %}";
    const result = try renderStr(tmpl, &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "none", result);
}

test "for loop should preserve parent context variables" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "label_pay_button", "Pay Now");

    var groups = std.ArrayList(*Context).empty;
    var group = try std.heap.page_allocator.create(Context);
    group.* = Context.init();
    try group.set(std.heap.page_allocator, "period_label", "January/2025");
    try group.set(std.heap.page_allocator, "due_date", "2025-01-15");

    var transactions = std.ArrayList(*Context).empty;
    var tx = try std.heap.page_allocator.create(Context);
    tx.* = Context.init();
    try tx.set(std.heap.page_allocator, "title", "Purchase");
    try transactions.append(std.heap.page_allocator, tx);
    try group.setList(std.heap.page_allocator, "transactions", transactions);

    try groups.append(std.heap.page_allocator, group);
    try context.setList(std.heap.page_allocator, "statement_groups", groups);

    const tmpl = "{% for group in statement_groups %}{{ label_pay_button }}|{{ group.period_label }}{% for tx in group.transactions %}{{ label_pay_button }}|{{ tx.title }}{% endfor %}{% endfor %}";

    const result = try renderStr(tmpl, &context);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Pay Now|January/2025Pay Now|Purchase", result);
}

test "for loop should preserve parent context inside nested if" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);

    try context.set(std.heap.page_allocator, "label_pay_button", "Pay Now");

    var groups = std.ArrayList(*Context).empty;
    var group = try std.heap.page_allocator.create(Context);
    group.* = Context.init();
    try group.set(std.heap.page_allocator, "period_label", "January/2025");

    try groups.append(std.heap.page_allocator, group);
    try context.setList(std.heap.page_allocator, "statement_groups", groups);

    const tmpl = "{% for group in statement_groups %}{% if group.period_label %}{{ label_pay_button }}|{{ group.period_label }}{% endif %}{% endfor %}";

    const result = try renderStr(tmpl, &context);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Pay Now|January/2025", result);
}

test "raw block - {{ }} not processed" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "title", "SHOULD NOT APPEAR");
    const result = try renderStr("before {% raw %}{{ title }}{% endraw %} after", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "before {{ title }} after", result);
}

test "md mode: {{ }} not processed" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "title", "WRONG");
    const result = try renderStr("<!-- md -->\n<h1>{{ title }}</h1>", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "<!-- md -->\n<h1>{{ title }}</h1>", result);
}

test "md mode: {% if %} not processed" {
    var context = Context.init();
    defer context.deinit(std.heap.page_allocator);
    try context.set(std.heap.page_allocator, "show", "true");
    const result = try renderStr("<!-- md -->\n{% if show %}yes{% endif %}", &context);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "<!-- md -->\n{% if show %}yes{% endif %}", result);
}

test "md mode: {% block %} still processed" {
    const tmpl = "<!-- md -->\n{% block \"content\" %}Hello{% end %}";
    const result = try renderBlock(tmpl, "content", .{}, std.heap.page_allocator);
    defer std.heap.page_allocator.free(result);
    try std.testing.expectEqualSlices(u8, "Hello", result);
}

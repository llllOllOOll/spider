//! The data a template renders: `RawHtml` (the one name apps use) and the
//! internal `Value` / `Context` that structs passed to a view are converted to.

const std = @import("std");

/// Trusted HTML for a template: `{ expr }` escapes every string except a
/// RawHtml, which is emitted verbatim. Wrap only markup your code built
/// itself (or already escaped), never user input.
///
/// ```zig
/// return c.view("page", .{ .body = spider.RawHtml{ .html = rendered } }, .{});
/// ```
pub const RawHtml = struct { html: []const u8 };

// internal: one value of a template context; the renderer reads it.
pub const Value = union(enum) {
    string: []const u8,
    /// Markup emitted verbatim by `{ expr }`: RawHtml values, slots and
    /// literal component props (which are template source, not data).
    html: []const u8,
    boolean: bool,
    list: []const Value,
    object: std.StringHashMapUnmanaged(Value),
};

// internal: the names a template can read, built from the data of a view.
pub const Context = struct {
    values: std.StringHashMapUnmanaged(Value),

    // internal: an empty context.
    pub fn init() Context {
        return .{ .values = .{} };
    }

    // internal: frees the keys and the values.
    pub fn deinit(self: *Context, alc: std.mem.Allocator) void {
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            freeValue(alc, entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        self.values.deinit(alc);
    }

    // internal: copies `key`, takes ownership of `value`; replaces (and frees) a previous value.
    pub fn set(self: *Context, alc: std.mem.Allocator, key: []const u8, value: Value) !void {
        // `value` is this context's from here on, also when it cannot be
        // kept: the callers build it in the argument and have no name for it.
        errdefer freeValue(alc, value);
        const gop = try self.values.getOrPut(alc, key);
        if (gop.found_existing) {
            // Overwriting an existing key: free the old value, otherwise
            // it's orphaned (leaked) once its map slot is replaced below.
            freeValue(alc, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = alc.dupe(u8, key) catch |err| {
                // No entry without its key: deinit would free whatever
                // the slot happened to hold.
                self.values.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = value;
    }

    // internal: the value of `key`, not copied.
    pub fn get(self: *const Context, key: []const u8) ?Value {
        return self.values.get(key);
    }

    // internal: a deep copy.
    pub fn clone(self: *const Context, alc: std.mem.Allocator) !Context {
        var c = Context.init();
        errdefer c.deinit(alc);
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            try putOwned(alc, &c.values, entry.key_ptr.*, try dupeValue(alc, entry.value_ptr.*));
        }
        return c;
    }
};

// internal: Template.render converts its data with this.
pub fn structToContext(alc: std.mem.Allocator, data: anytype) !Context {
    var ctx = Context.init();
    errdefer ctx.deinit(alc);

    const T = @TypeOf(data);
    const info = @typeInfo(T);
    if (info != .@"struct") return ctx;

    inline for (info.@"struct".field_names) |field_name| {
        const value = @field(data, field_name);
        const field_info = @typeInfo(@TypeOf(value));

        if (@TypeOf(value) == RawHtml) {
            try ctx.set(alc, field_name, Value{ .html = try alc.dupe(u8, value.html) });
        } else if (@TypeOf(value) == ?RawHtml) {
            if (value) |v| try ctx.set(alc, field_name, Value{ .html = try alc.dupe(u8, v.html) });
        } else if (field_info == .pointer) {
            const ptr = field_info.pointer;
            if (ptr.child == u8 and ptr.size == .slice) {
                try ctx.set(alc, field_name, Value{ .string = try alc.dupe(u8, value) });
            } else if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    if (array_info.child == u8) {
                        const slice: []const u8 = value[0..];
                        try ctx.set(alc, field_name, Value{ .string = try alc.dupe(u8, slice) });
                    } else {
                        const slice = @as([]const array_info.child, value[0..]);
                        const elem_info = @typeInfo(array_info.child);
                        if (elem_info == .@"struct") {
                            try ctx.set(alc, field_name, Value{ .list = try structSliceToValueList(alc, slice) });
                        } else if (elem_info == .pointer) {
                            const elem_ptr = elem_info.pointer;
                            if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                                try ctx.set(alc, field_name, Value{ .list = try stringSliceToValueList(alc, slice) });
                            }
                        }
                    }
                } else if (child_info == .@"struct") {
                    try ctx.set(alc, field_name, Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try ctx.set(alc, field_name, Value{ .list = try structSliceToValueList(alc, value) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try ctx.set(alc, field_name, Value{ .list = try stringSliceToValueList(alc, value) });
                    }
                }
            }
        } else if (field_info == .optional) {
            if (value) |unwrapped| {
                const inner_info = @typeInfo(@TypeOf(unwrapped));
                if (inner_info == .pointer) {
                    const ptr = inner_info.pointer;
                    if (ptr.child == u8 and ptr.size == .slice) {
                        try ctx.set(alc, field_name, Value{ .string = try alc.dupe(u8, unwrapped) });
                    }
                } else if (inner_info == .bool) {
                    try ctx.set(alc, field_name, Value{ .boolean = unwrapped });
                } else if (inner_info == .int or inner_info == .comptime_int) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try ctx.set(alc, field_name, Value{ .string = str });
                } else if (inner_info == .float or inner_info == .comptime_float) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try ctx.set(alc, field_name, Value{ .string = str });
                }
            }
        } else if (field_info == .bool) {
            try ctx.set(alc, field_name, Value{ .boolean = value });
        } else if (field_info == .int or field_info == .comptime_int) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try ctx.set(alc, field_name, Value{ .string = str });
        } else if (field_info == .float or field_info == .comptime_float) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try ctx.set(alc, field_name, Value{ .string = str });
        } else if (field_info == .array) {
            const arr = field_info.array;
            if (arr.child != u8) {
                const slice = @as([]const arr.child, &value);
                const elem_info = @typeInfo(arr.child);
                if (elem_info == .@"struct") {
                    try ctx.set(alc, field_name, Value{ .list = try structSliceToValueList(alc, slice) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try ctx.set(alc, field_name, Value{ .list = try stringSliceToValueList(alc, slice) });
                    }
                }
            }
        } else if (field_info == .@"struct") {
            try ctx.set(alc, field_name, Value{ .object = try structToObject(alc, value) });
        }
    }

    return ctx;
}

fn structSliceToValueList(alc: std.mem.Allocator, slice: anytype) ![]const Value {
    const list = try alc.alloc(Value, slice.len);
    // The items made so far, when a later one fails.
    var done: usize = 0;
    errdefer {
        for (list[0..done]) |v| freeValue(alc, v);
        alc.free(list);
    }
    for (slice, 0..) |elem, i| {
        list[i] = if (@TypeOf(elem) == RawHtml)
            Value{ .html = try alc.dupe(u8, elem.html) }
        else
            Value{ .object = try structToObject(alc, elem) };
        done = i + 1;
    }
    return list;
}

fn stringSliceToValueList(alc: std.mem.Allocator, slice: anytype) ![]const Value {
    const list = try alc.alloc(Value, slice.len);
    var done: usize = 0;
    errdefer {
        for (list[0..done]) |v| freeValue(alc, v);
        alc.free(list);
    }
    for (slice, 0..) |elem, i| {
        list[i] = Value{ .string = try alc.dupe(u8, elem) };
        done = i + 1;
    }
    return list;
}

/// Puts `value` in `obj` under a copy of `name`. `value` is the map's from
/// here on: when it cannot be kept it is freed, key included.
fn putOwned(alc: std.mem.Allocator, obj: *std.StringHashMapUnmanaged(Value), name: []const u8, value: Value) !void {
    errdefer freeValue(alc, value);
    const key = try alc.dupe(u8, name);
    errdefer alc.free(key);
    try obj.put(alc, key, value);
}

// internal: converts a struct to the map of a `Value.object`.
pub fn structToObject(alc: std.mem.Allocator, data: anytype) !std.StringHashMapUnmanaged(Value) {
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

    inline for (info.@"struct".field_names) |field_name| {
        const value = @field(data, field_name);
        const field_info = @typeInfo(@TypeOf(value));

        if (@TypeOf(value) == RawHtml) {
            try putOwned(alc, &obj, field_name, Value{ .html = try alc.dupe(u8, value.html) });
        } else if (@TypeOf(value) == ?RawHtml) {
            if (value) |v| try putOwned(alc, &obj, field_name, Value{ .html = try alc.dupe(u8, v.html) });
        } else if (field_info == .pointer) {
            const ptr = field_info.pointer;
            if (ptr.child == u8 and ptr.size == .slice) {
                try putOwned(alc, &obj, field_name, Value{ .string = try alc.dupe(u8, value) });
            } else if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    if (array_info.child == u8) {
                        const s: []const u8 = value[0..];
                        try putOwned(alc, &obj, field_name, Value{ .string = try alc.dupe(u8, s) });
                    } else {
                        const slice = @as([]const array_info.child, value[0..]);
                        const elem_info = @typeInfo(array_info.child);
                        if (elem_info == .@"struct") {
                            try putOwned(alc, &obj, field_name, Value{ .list = try structSliceToValueList(alc, slice) });
                        } else if (elem_info == .pointer) {
                            const elem_ptr = elem_info.pointer;
                            if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                                try putOwned(alc, &obj, field_name, Value{ .list = try stringSliceToValueList(alc, slice) });
                            }
                        }
                    }
                } else if (child_info == .@"struct") {
                    try putOwned(alc, &obj, field_name, Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try putOwned(alc, &obj, field_name, Value{ .list = try structSliceToValueList(alc, value) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try putOwned(alc, &obj, field_name, Value{ .list = try stringSliceToValueList(alc, value) });
                    }
                }
            }
        } else if (field_info == .optional) {
            if (value) |unwrapped| {
                const inner_info = @typeInfo(@TypeOf(unwrapped));
                if (inner_info == .pointer) {
                    const ptr = inner_info.pointer;
                    if (ptr.child == u8 and ptr.size == .slice) {
                        try putOwned(alc, &obj, field_name, Value{ .string = try alc.dupe(u8, unwrapped) });
                    }
                } else if (inner_info == .bool) {
                    try putOwned(alc, &obj, field_name, Value{ .boolean = unwrapped });
                } else if (inner_info == .int or inner_info == .comptime_int) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try putOwned(alc, &obj, field_name, Value{ .string = str });
                } else if (inner_info == .float or inner_info == .comptime_float) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try putOwned(alc, &obj, field_name, Value{ .string = str });
                }
            }
        } else if (field_info == .bool) {
            try putOwned(alc, &obj, field_name, Value{ .boolean = value });
        } else if (field_info == .int or field_info == .comptime_int) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try putOwned(alc, &obj, field_name, Value{ .string = str });
        } else if (field_info == .float or field_info == .comptime_float) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try putOwned(alc, &obj, field_name, Value{ .string = str });
        } else if (field_info == .@"struct") {
            try putOwned(alc, &obj, field_name, Value{ .object = try structToObject(alc, value) });
        }
    }

    return obj;
}

// internal: frees a value built by this file.
pub fn freeValue(alc: std.mem.Allocator, value: Value) void {
    switch (value) {
        .string, .html => |s| alc.free(s),
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

// internal: a deep copy of a value.
pub fn dupeValue(alc: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| Value{ .string = try alc.dupe(u8, s) },
        .html => |s| Value{ .html = try alc.dupe(u8, s) },
        .boolean => |b| Value{ .boolean = b },
        .list => |list| {
            const new_list = try alc.alloc(Value, list.len);
            var done: usize = 0;
            errdefer {
                for (new_list[0..done]) |v| freeValue(alc, v);
                alc.free(new_list);
            }
            for (list, 0..) |v, i| {
                new_list[i] = try dupeValue(alc, v);
                done = i + 1;
            }
            return Value{ .list = new_list };
        },
        .object => |obj| {
            var new_obj = std.StringHashMapUnmanaged(Value){};
            errdefer freeValue(alc, Value{ .object = new_obj });
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try putOwned(alc, &new_obj, entry.key_ptr.*, try dupeValue(alc, entry.value_ptr.*));
            }
            return Value{ .object = new_obj };
        },
    };
}

const TestRow = struct { name: []const u8, tags: []const []const u8 };

fn contextOfRows(alc: std.mem.Allocator) !void {
    const rows = [_]TestRow{
        .{ .name = "one", .tags = &.{ "a", "b" } },
        .{ .name = "two", .tags = &.{"c"} },
        .{ .name = "three", .tags = &.{} },
    };
    var ctx = try structToContext(alc, .{ .rows = @as([]const TestRow, &rows), .names = @as([]const []const u8, &.{ "x", "y", "z" }) });
    defer ctx.deinit(alc);
    // And a deep copy of it, as a render with a layout makes.
    var copy = try ctx.clone(alc);
    copy.deinit(alc);
}

test "structToContext: a list that cannot be finished frees the items it had made" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, contextOfRows, .{});
}

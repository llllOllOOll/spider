const std = @import("std");

/// Trusted HTML for a template: `{ expr }` escapes every string except a
/// RawHtml, which is emitted verbatim. Wrap only markup your code built
/// itself (or already escaped), never user input.
///
///   return c.view("page", .{ .body = spider.RawHtml{ .html = rendered } }, .{});
pub const RawHtml = struct { html: []const u8 };

pub const Value = union(enum) {
    string: []const u8,
    /// Markup emitted verbatim by `{ expr }`: RawHtml values, slots and
    /// literal component props (which are template source, not data).
    html: []const u8,
    boolean: bool,
    list: []const Value,
    object: std.StringHashMapUnmanaged(Value),
};

pub const Context = struct {
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
        const gop = try self.values.getOrPut(alc, key);
        if (gop.found_existing) {
            // Overwriting an existing key: free the old value, otherwise
            // it's orphaned (leaked) once its map slot is replaced below.
            freeValue(alc, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try alc.dupe(u8, key);
        }
        gop.value_ptr.* = value;
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
    errdefer {
        for (list[0..0]) |*v| freeValue(alc, v.*);
        alc.free(list);
    }
    for (slice, 0..) |elem, i| {
        list[i] = if (@TypeOf(elem) == RawHtml)
            Value{ .html = try alc.dupe(u8, elem.html) }
        else
            Value{ .object = try structToObject(alc, elem) };
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
            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .html = try alc.dupe(u8, value.html) });
        } else if (@TypeOf(value) == ?RawHtml) {
            if (value) |v| try obj.put(alc, try alc.dupe(u8, field_name), Value{ .html = try alc.dupe(u8, v.html) });
        } else if (field_info == .pointer) {
            const ptr = field_info.pointer;
            if (ptr.child == u8 and ptr.size == .slice) {
                try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = try alc.dupe(u8, value) });
            } else if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    if (array_info.child == u8) {
                        const s: []const u8 = value[0..];
                        try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = try alc.dupe(u8, s) });
                    } else {
                        const slice = @as([]const array_info.child, value[0..]);
                        const elem_info = @typeInfo(array_info.child);
                        if (elem_info == .@"struct") {
                            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .list = try structSliceToValueList(alc, slice) });
                        } else if (elem_info == .pointer) {
                            const elem_ptr = elem_info.pointer;
                            if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                                try obj.put(alc, try alc.dupe(u8, field_name), Value{ .list = try stringSliceToValueList(alc, slice) });
                            }
                        }
                    }
                } else if (child_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field_name), Value{ .object = try structToObject(alc, value) });
                }
            } else if (ptr.size == .slice) {
                const elem_info = @typeInfo(ptr.child);
                if (elem_info == .@"struct") {
                    try obj.put(alc, try alc.dupe(u8, field_name), Value{ .list = try structSliceToValueList(alc, value) });
                } else if (elem_info == .pointer) {
                    const elem_ptr = elem_info.pointer;
                    if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                        try obj.put(alc, try alc.dupe(u8, field_name), Value{ .list = try stringSliceToValueList(alc, value) });
                    }
                }
            }
        } else if (field_info == .optional) {
            if (value) |unwrapped| {
                const inner_info = @typeInfo(@TypeOf(unwrapped));
                if (inner_info == .pointer) {
                    const ptr = inner_info.pointer;
                    if (ptr.child == u8 and ptr.size == .slice) {
                        try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = try alc.dupe(u8, unwrapped) });
                    }
                } else if (inner_info == .bool) {
                    try obj.put(alc, try alc.dupe(u8, field_name), Value{ .boolean = unwrapped });
                } else if (inner_info == .int or inner_info == .comptime_int) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = str });
                } else if (inner_info == .float or inner_info == .comptime_float) {
                    const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                    try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = str });
                }
            }
        } else if (field_info == .bool) {
            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .boolean = value });
        } else if (field_info == .int or field_info == .comptime_int) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = str });
        } else if (field_info == .float or field_info == .comptime_float) {
            const str = try std.fmt.allocPrint(alc, "{d}", .{value});
            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .string = str });
        } else if (field_info == .@"struct") {
            try obj.put(alc, try alc.dupe(u8, field_name), Value{ .object = try structToObject(alc, value) });
        }
    }

    return obj;
}

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

pub fn dupeValue(alc: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |s| Value{ .string = try alc.dupe(u8, s) },
        .html => |s| Value{ .html = try alc.dupe(u8, s) },
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

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
    /// The context this one was opened inside (a loop iteration inside a
    /// page, a component inside a loop): `get` looks there for a name this
    /// one does not have. Not owned.
    parent: ?*const Context = null,

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

    // internal: the value of `key`, not copied: this context's own, or
    // the one of the context it was opened inside.
    pub fn get(self: *const Context, key: []const u8) ?Value {
        var scope: ?*const Context = self;
        while (scope) |context| : (scope = context.parent) {
            if (context.values.get(key)) |value| return value;
        }
        return null;
    }

    // internal: a context for a loop iteration or a component: it sees
    // everything `self` has and holds only what is set on it. `self` must
    // outlive it. (Each iteration used to get a copy of the whole context,
    // which made a list inside a list cost its size squared.)
    pub fn child(self: *const Context) Context {
        return .{ .values = .{}, .parent = self };
    }

    // internal: a deep copy.
    pub fn clone(self: *const Context, alc: std.mem.Allocator) !Context {
        var c = Context.init();
        errdefer c.deinit(alc);
        // Everything in sight, the nearest value of a name winning: the
        // outer contexts first, then this one over them.
        var chain: [64]*const Context = undefined;
        var depth: usize = 0;
        var scope: ?*const Context = self;
        while (scope) |context| : (scope = context.parent) {
            if (depth == chain.len) return error.ContextTooDeep;
            chain[depth] = context;
            depth += 1;
        }
        while (depth > 0) {
            depth -= 1;
            var iter = chain[depth].values.iterator();
            while (iter.next()) |entry| {
                try c.set(alc, entry.key_ptr.*, try dupeValue(alc, entry.value_ptr.*));
            }
        }
        return c;
    }
};

// internal: Template.render converts its data with this.
pub fn structToContext(alc: std.mem.Allocator, data: anytype) !Context {
    var ctx = Context.init();
    errdefer ctx.deinit(alc);

    const T = @TypeOf(data);
    if (@typeInfo(T) != .@"struct") return ctx;

    // Not generic past this point: the loop and its error paths are compiled
    // once, and a struct adds only a small reader per field.
    for (Fields(T).list) |f| {
        if (try f.get(alc, &data)) |v| try ctx.set(alc, f.name, v);
    }
    return ctx;
}

/// A field of a struct the templates read: its name and how to get its value.
const FieldReader = struct {
    name: []const u8,
    get: *const fn (alc: std.mem.Allocator, data: *const anyopaque) std.mem.Allocator.Error!?Value,
};

/// The readers of `T`'s fields, built at compile time.
fn Fields(comptime T: type) type {
    return struct {
        const names = @typeInfo(T).@"struct".field_names;
        const list: [names.len]FieldReader = blk: {
            var arr: [names.len]FieldReader = undefined;
            for (names, 0..) |name, i| arr[i] = .{ .name = name, .get = reader(name) };
            break :blk arr;
        };

        fn reader(comptime name: []const u8) *const fn (std.mem.Allocator, *const anyopaque) std.mem.Allocator.Error!?Value {
            return struct {
                fn get(alc: std.mem.Allocator, data: *const anyopaque) std.mem.Allocator.Error!?Value {
                    // A struct with only comptime fields has no bytes to point at.
                    if (@sizeOf(T) == 0) return fieldValue(alc, @field(@as(T, undefined), name));
                    const ptr: *const T = @ptrCast(@alignCast(data));
                    return fieldValue(alc, @field(ptr, name));
                }
            }.get;
        }
    };
}

/// The template value of one field, or null for a null optional or a type
/// templates do not read. Generic on the field's type only.
fn fieldValue(alc: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!?Value {
    const field_info = @typeInfo(@TypeOf(value));

    if (@TypeOf(value) == RawHtml) {
        return Value{ .html = try alc.dupe(u8, value.html) };
    } else if (@TypeOf(value) == ?RawHtml) {
        if (value) |v| return Value{ .html = try alc.dupe(u8, v.html) };
    } else if (field_info == .pointer) {
        const ptr = field_info.pointer;
        if (ptr.child == u8 and ptr.size == .slice) {
            return Value{ .string = try alc.dupe(u8, value) };
        } else if (ptr.size == .one) {
            const child_info = @typeInfo(ptr.child);
            if (child_info == .array) {
                const array_info = child_info.array;
                if (array_info.child == u8) {
                    const s: []const u8 = value[0..];
                    return Value{ .string = try alc.dupe(u8, s) };
                } else {
                    const slice = @as([]const array_info.child, value[0..]);
                    const elem_info = @typeInfo(array_info.child);
                    if (elem_info == .@"struct") {
                        return Value{ .list = try structSliceToValueList(alc, slice) };
                    } else if (elem_info == .pointer) {
                        const elem_ptr = elem_info.pointer;
                        if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                            return Value{ .list = try stringSliceToValueList(alc, slice) };
                        }
                    }
                }
            } else if (child_info == .@"struct") {
                return Value{ .object = try structToObject(alc, value) };
            }
        } else if (ptr.size == .slice) {
            const elem_info = @typeInfo(ptr.child);
            if (elem_info == .@"struct") {
                return Value{ .list = try structSliceToValueList(alc, value) };
            } else if (elem_info == .pointer) {
                const elem_ptr = elem_info.pointer;
                if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                    return Value{ .list = try stringSliceToValueList(alc, value) };
                }
            }
        }
    } else if (field_info == .optional) {
        if (value) |unwrapped| {
            const inner_info = @typeInfo(@TypeOf(unwrapped));
            if (inner_info == .pointer) {
                const ptr = inner_info.pointer;
                if (ptr.child == u8 and ptr.size == .slice) {
                    return Value{ .string = try alc.dupe(u8, unwrapped) };
                }
            } else if (inner_info == .bool) {
                return Value{ .boolean = unwrapped };
            } else if (inner_info == .int or inner_info == .comptime_int) {
                const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                return Value{ .string = str };
            } else if (inner_info == .float or inner_info == .comptime_float) {
                const str = try std.fmt.allocPrint(alc, "{d}", .{unwrapped});
                return Value{ .string = str };
            }
        }
    } else if (field_info == .bool) {
        return Value{ .boolean = value };
    } else if (field_info == .int or field_info == .comptime_int) {
        const str = try std.fmt.allocPrint(alc, "{d}", .{value});
        return Value{ .string = str };
    } else if (field_info == .float or field_info == .comptime_float) {
        const str = try std.fmt.allocPrint(alc, "{d}", .{value});
        return Value{ .string = str };
    } else if (field_info == .array) {
        const arr = field_info.array;
        if (arr.child != u8) {
            const slice = @as([]const arr.child, &value);
            const elem_info = @typeInfo(arr.child);
            if (elem_info == .@"struct") {
                return Value{ .list = try structSliceToValueList(alc, slice) };
            } else if (elem_info == .pointer) {
                const elem_ptr = elem_info.pointer;
                if (elem_ptr.child == u8 and elem_ptr.size == .slice) {
                    return Value{ .list = try stringSliceToValueList(alc, slice) };
                }
            }
        }
    } else if (field_info == .@"struct") {
        return Value{ .object = try structToObject(alc, value) };
    }
    return null;
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
pub fn structToObject(alc: std.mem.Allocator, data: anytype) std.mem.Allocator.Error!std.StringHashMapUnmanaged(Value) {
    var obj = std.StringHashMapUnmanaged(Value){};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            freeValue(alc, entry.value_ptr.*);
            alc.free(entry.key_ptr.*);
        }
        obj.deinit(alc);
    }

    const T = @TypeOf(data);
    if (@typeInfo(T) != .@"struct") return obj;

    for (Fields(T).list) |f| {
        if (try f.get(alc, &data)) |v| try putOwned(alc, &obj, f.name, v);
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

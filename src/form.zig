const std = @import("std");

pub const FormValue = union(enum) {
    string: []const u8,
    array: std.ArrayListUnmanaged([]const u8),
};

pub const FormData = struct {
    fields: std.StringHashMap(FormValue),
    allocator: std.mem.Allocator,

    pub fn get(self: *const FormData, key: []const u8) ?[]const u8 {
        const entry = self.fields.get(key) orelse return null;
        return switch (entry) {
            .string => |v| v,
            .array => |arr| if (arr.items.len > 0) arr.items[0] else null,
        };
    }

    pub fn getArray(self: *const FormData, key: []const u8) ?[]const []const u8 {
        const entry = self.fields.get(key) orelse return null;
        return switch (entry) {
            .string => |v| &[_][]const u8{v},
            .array => |arr| arr.items,
        };
    }

    pub fn getNested(self: *const FormData, path: []const u8) ?[]const u8 {
        return self.get(path);
    }

    pub fn deinit(self: *FormData) void {
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .string => |v| self.allocator.free(v),
                .array => |*arr| {
                    for (arr.items) |item| {
                        self.allocator.free(item);
                    }
                    arr.deinit(self.allocator);
                },
            }
        }
        self.fields.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, body: ?[]const u8) !FormData {
    var fields = std.StringHashMap(FormValue).init(allocator);
    errdefer fields.deinit();

    const b = body orelse ""; // Empty body returns empty FormData
    if (b.len == 0) {
        return FormData{
            .fields = fields,
            .allocator = allocator,
        };
    }

    var iter = std.mem.splitScalar(u8, b, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;

        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |e| pair[0..e] else pair;
        const raw_value = if (eq) |e| pair[e + 1 ..] else "";

        const decoded_key = try urlDecode(allocator, key);
        const decoded_value = try urlDecode(allocator, raw_value);

        // Check if key ends with []
        if (std.mem.endsWith(u8, decoded_key, "[]")) {
            const base_key = try allocator.dupe(u8, decoded_key[0 .. decoded_key.len - 2]);
            allocator.free(decoded_key);
            try addToArray(allocator, &fields, base_key, decoded_value);
        } else {
            // Check if this key already exists
            if (fields.getPtr(decoded_key)) |existing| {
                switch (existing.*) {
                    .string => |old_val| {
                        // Promote to array
                        var arr = std.ArrayListUnmanaged([]const u8){};
                        try arr.append(allocator, old_val);
                        try arr.append(allocator, decoded_value);
                        existing.* = .{ .array = arr };
                        allocator.free(decoded_key);
                    },
                    .array => |*arr| {
                        try arr.append(allocator, decoded_value);
                        allocator.free(decoded_key);
                    },
                }
            } else {
                try fields.put(decoded_key, .{ .string = decoded_value });
            }
        }
    }

    return FormData{
        .fields = fields,
        .allocator = allocator,
    };
}

fn addToArray(allocator: std.mem.Allocator, fields: *std.StringHashMap(FormValue), key: []const u8, value: []const u8) !void {
    if (fields.getPtr(key)) |existing| {
        allocator.free(key);
        switch (existing.*) {
            .string => {
                var arr = std.ArrayListUnmanaged([]const u8){};
                try arr.append(allocator, existing.*.string);
                try arr.append(allocator, value);
                existing.* = .{ .array = arr };
            },
            .array => |*arr| {
                try arr.append(allocator, value);
            },
        }
    } else {
        var arr = std.ArrayListUnmanaged([]const u8){};
        try arr.append(allocator, value);
        try fields.put(key, .{ .array = arr });
    }
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null and std.mem.indexOfScalar(u8, input, '+') == null) {
        return allocator.dupe(u8, input);
    }

    var decode_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const valid = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch {
                decode_len += 3;
                i += 2;
                continue;
            };
            _ = valid;
            decode_len += 1;
            i += 2;
        } else {
            decode_len += 1;
        }
    }

    var result = try allocator.alloc(u8, decode_len);
    errdefer allocator.free(result);

    var out_len: usize = 0;
    i = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch {
                result[out_len] = '%';
                out_len += 1;
                continue;
            };
            result[out_len] = hex;
            out_len += 1;
            i += 2;
        } else if (input[i] == '+') {
            result[out_len] = ' ';
            out_len += 1;
        } else {
            result[out_len] = input[i];
            out_len += 1;
        }
    }

    return result;
}

test "FormData - simple field get" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "name=John&email=john@example.com");
    defer form.deinit();

    try std.testing.expectEqualStrings("John", form.get("name").?);
    try std.testing.expectEqualStrings("john@example.com", form.get("email").?);
}

test "FormData - missing field returns null" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "name=John");
    defer form.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), form.get("nonexistent"));
    try std.testing.expectEqual(@as(?[]const u8, null), form.get("email"));
}

test "FormData - array notation" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "tags[]=js&tags[]=zig&tags[]=rust");
    defer form.deinit();

    const entry = form.fields.get("tags");
    try std.testing.expect(entry != null);
    try std.testing.expect(std.mem.eql(u8, @tagName(entry.?), "array"));

    const arr = &entry.?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqualStrings("js", arr.items[0]);
    try std.testing.expectEqualStrings("zig", arr.items[1]);
    try std.testing.expectEqualStrings("rust", arr.items[2]);
}

test "FormData - dot notation nested" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "user.name=John&user.email=john@example.com");
    defer form.deinit();

    try std.testing.expectEqualStrings("John", form.get("user.name").?);
    try std.testing.expectEqualStrings("john@example.com", form.get("user.email").?);
}

test "FormData - nested array" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "user.roles[]=admin&user.roles[]=editor&user.roles[]=viewer");
    defer form.deinit();

    const entry = form.fields.get("user.roles");
    try std.testing.expect(entry != null);
    try std.testing.expect(std.mem.eql(u8, @tagName(entry.?), "array"));

    const arr = &entry.?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqualStrings("admin", arr.items[0]);
    try std.testing.expectEqualStrings("editor", arr.items[1]);
    try std.testing.expectEqualStrings("viewer", arr.items[2]);
}

test "FormData - multiple values same key promotes to array" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "items=a&items=b&items=c");
    defer form.deinit();

    const entry = form.fields.get("items");
    try std.testing.expect(entry != null);
    try std.testing.expect(std.mem.eql(u8, @tagName(entry.?), "array"));

    const arr = &entry.?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqualStrings("a", arr.items[0]);
    try std.testing.expectEqualStrings("b", arr.items[1]);
    try std.testing.expectEqualStrings("c", arr.items[2]);
}

test "FormData - URL encoded values" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "name=hello%20world&path=foo%2Fbar");
    defer form.deinit();

    try std.testing.expectEqualStrings("hello world", form.get("name").?);
    try std.testing.expectEqualStrings("foo/bar", form.get("path").?);
}

test "FormData - plus decoded as space" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "message=hello+world&greeting=hi+there");
    defer form.deinit();

    try std.testing.expectEqualStrings("hello world", form.get("message").?);
    try std.testing.expectEqualStrings("hi there", form.get("greeting").?);
}

test "FormData - empty body returns empty FormData" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, null);
    defer form.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), form.get("anything"));
    try std.testing.expectEqual(@as(usize, 0), form.fields.count());
}

test "FormData - empty string body returns empty FormData" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "");
    defer form.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), form.get("anything"));
    try std.testing.expectEqual(@as(usize, 0), form.fields.count());
}

test "FormData - deinit cleans up without leaks" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "name=John&tags[]=a&tags[]=b&user.name=Jane");
    form.deinit();
}

test "FormData - getArray returns all values from array" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "tags[]=first&tags[]=second");
    defer form.deinit();

    const result = form.getArray("tags");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.len);
    try std.testing.expectEqualStrings("first", result.?[0]);
    try std.testing.expectEqualStrings("second", result.?[1]);
}

test "FormData - mixed array and single values" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "single=value&array[]=a&array[]=b&another=item");
    defer form.deinit();

    try std.testing.expectEqualStrings("value", form.get("single").?);
    try std.testing.expectEqualStrings("item", form.get("another").?);

    const entry = form.fields.get("array");
    try std.testing.expect(std.mem.eql(u8, @tagName(entry.?), "array"));
    try std.testing.expectEqual(@as(usize, 2), entry.?.array.items.len);
}

test "FormData - percent encoding edge cases" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "hex=%41%42%43&invalid=%2G&trailing=%41");
    defer form.deinit();

    try std.testing.expectEqualStrings("ABC", form.get("hex").?);
    try std.testing.expectEqualStrings("%2G", form.get("invalid").?);
    try std.testing.expectEqualStrings("A", form.get("trailing").?);
}

test "FormData - get returns first item for arrays" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "items[]=x&items[]=y&items[]=z");
    defer form.deinit();

    try std.testing.expectEqualStrings("x", form.get("items").?);
}

test "FormData - getNested retrieves dot notation key" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "user.email=john@example.com&user.name=John");
    defer form.deinit();

    try std.testing.expectEqualStrings("john@example.com", form.getNested("user.email").?);
    try std.testing.expectEqualStrings("John", form.getNested("user.name").?);
}

test "FormData - getNested returns null for missing key" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "user.email=john@example.com");
    defer form.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), form.getNested("missing.key"));
    try std.testing.expectEqual(@as(?[]const u8, null), form.getNested("user.nonexistent"));
}

test "FormData - dot notation stored as literal key" {
    const alloc = std.testing.allocator;
    var form = try parse(alloc, "user.email=john@example.com");
    defer form.deinit();

    // Key is stored as literal "user.email"
    try std.testing.expect(form.fields.contains("user.email"));
    try std.testing.expect(!form.fields.contains("user"));
    try std.testing.expectEqualStrings("john@example.com", form.get("user.email").?);
}

//! Internal: fills a struct from a submitted form, urlencoded or multipart
//! (`FormParser`). It is what `c.parseForm(T)` and `spider.Form(T)` run.

const std = @import("std");
const form = @import("form.zig");
const multipart = @import("multipart.zig");

/// True when the form gave nothing for this field: it is not there, or it is
/// a number field left blank. An empty text is a value; a checkbox that is
/// not sent is "unchecked", which is a value too.
fn notGiven(comptime InnerType: type, raw_value: ?[]const u8) bool {
    if (InnerType == bool) return false;
    const value = raw_value orelse return true;
    if (InnerType == []const u8) return false;
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn setField(result: anytype, comptime name: []const u8, allocator: std.mem.Allocator, raw_value: ?[]const u8, comptime InnerType: type, comptime is_optional: bool) !void {
    if (InnerType == []const u8) {
        if (is_optional) {
            if (raw_value) |v| {
                @field(result, name) = try allocator.dupe(u8, v);
            } else {
                @field(result, name) = null;
            }
        } else {
            @field(result, name) = try allocator.dupe(u8, raw_value orelse "");
        }
    } else if (InnerType == f64 or InnerType == f32 or InnerType == i32 or InnerType == i64 or InnerType == u32) {
        // A number field left blank is sent as "": the same as not sent.
        const text = std.mem.trim(u8, raw_value orelse "", " \t\r\n");
        if (text.len == 0) {
            @field(result, name) = if (is_optional) null else 0;
        } else {
            // Text that is not a number ("12,50", "abc", too big for the
            // field) is the client's mistake, said so: it used to be saved
            // as 0.
            @field(result, name) = switch (@typeInfo(InnerType)) {
                .float => std.fmt.parseFloat(InnerType, text) catch return error.InvalidNumber,
                else => std.fmt.parseInt(InnerType, text, 10) catch return error.InvalidNumber,
            };
        }
    } else if (InnerType == bool) {
        if (raw_value) |val| {
            @field(result, name) = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
        } else if (is_optional) {
            @field(result, name) = null;
        } else {
            @field(result, name) = false;
        }
    } else if (InnerType == multipart.UploadedFile) {
        // For multipart binding, the value is looked up from parseForm's auto-detect
        // This is a placeholder for when parseForm auto-detects multipart
        if (is_optional) {
            @field(result, name) = null;
        } else {
            @field(result, name) = multipart.UploadedFile{
                .filename = "",
                .content_type = "",
                .data = "",
                .size = 0,
            };
        }
    } else {
        @compileError("Unsupported field type: " ++ @typeName(InnerType));
    }
}

pub const FormParser = struct {
    allocator: std.mem.Allocator,
    data: form.FormData,

    pub fn init(allocator: std.mem.Allocator, body: ?[]const u8) !FormParser {
        return .{
            .allocator = allocator,
            .data = try form.parse(allocator, body),
        };
    }

    pub fn deinit(self: *FormParser) void {
        self.data.deinit();
    }

    pub fn fromMultipartData(data: *const multipart.MultipartData, allocator: std.mem.Allocator, comptime T: type) !T {
        var result: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, info.field_attrs) |fname, ftype, attrs| {
            const name = fname;
            const T2 = ftype;
            const is_optional = @typeInfo(T2) == .optional;
            const InnerType = if (is_optional) @typeInfo(T2).optional.child else T2;
            const default = comptime attrs.defaultValue(T2);

            if (InnerType == multipart.UploadedFile) {
                const files = data.getFile(name);
                if (files) |f| {
                    if (f.len > 0) {
                        @field(result, name) = f[0];
                    } else if (is_optional) {
                        @field(result, name) = null;
                    } else {
                        return error.MissingField;
                    }
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    return error.MissingField;
                }
            } else {
                const raw_value = data.getValue(name);
                if (default != null and notGiven(InnerType, raw_value)) {
                    @field(result, name) = default.?;
                } else {
                    try setField(&result, name, allocator, raw_value, InnerType, is_optional);
                }
            }
        }
        return result;
    }

    pub fn parse(self: *FormParser, comptime T: type) !T {
        var result: T = undefined;
        try self.parseInto(&result);
        return result;
    }

    pub fn parseInto(self: *FormParser, result: anytype) !void {
        const T = @TypeOf(result.*);
        if (@typeInfo(T) != .@"struct") {
            @compileError("parseInto requires a struct type");
        }
        const info2 = @typeInfo(T).@"struct";
        inline for (info2.field_names, info2.field_types, info2.field_attrs) |fname, ftype, attrs| {
            const name = fname;
            const raw_value = self.data.get(name);
            const T2 = ftype;
            const is_optional = @typeInfo(T2) == .optional;
            const InnerType = if (is_optional) @typeInfo(T2).optional.child else T2;
            // What the form does not give takes the struct's default.
            const default = comptime attrs.defaultValue(T2);
            if (default != null and notGiven(InnerType, raw_value)) {
                @field(result, name) = default.?;
            } else {
                try setField(result, name, self.allocator, raw_value, InnerType, is_optional);
            }
        }
    }
};

const t = std.testing;

fn fromForm(arena: std.mem.Allocator, comptime T: type, body: []const u8) !T {
    var parser = try FormParser.init(arena, body);
    defer parser.deinit();
    return parser.parse(T);
}

test "form: a field the form does not send takes the struct's default" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const Input = struct {
        title: []const u8 = "",
        role: []const u8 = "user",
        per_page: u32 = 20,
        ratio: f64 = 1.5,
        note: ?[]const u8 = null,
        plain: []const u8,
        count: i32,
    };
    const input = try fromForm(arena.allocator(), Input, "title=Hello");
    try t.expectEqualStrings("Hello", input.title);
    try t.expectEqualStrings("user", input.role);
    try t.expectEqual(@as(u32, 20), input.per_page);
    try t.expectEqual(@as(f64, 1.5), input.ratio);
    try t.expect(input.note == null);
    // No default: the empty value, as before.
    try t.expectEqualStrings("", input.plain);
    try t.expectEqual(@as(i32, 0), input.count);

    // What the form sends wins, an empty text included.
    const sent = try fromForm(arena.allocator(), Input, "role=&per_page=5&ratio=2");
    try t.expectEqualStrings("", sent.role);
    try t.expectEqual(@as(u32, 5), sent.per_page);
    try t.expectEqual(@as(f64, 2), sent.ratio);
}

test "form: a number left blank is like one not sent; one that is not a number is an error" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const Input = struct { quantity: i32 = 1, price: f64 = 0, maybe: ?i64 = null };

    const blank = try fromForm(arena.allocator(), Input, "quantity=&price=+&maybe=");
    try t.expectEqual(@as(i32, 1), blank.quantity);
    try t.expectEqual(@as(f64, 0), blank.price);
    try t.expect(blank.maybe == null);

    const good = try fromForm(arena.allocator(), Input, "quantity=+7+&price=12.50&maybe=-3");
    try t.expectEqual(@as(i32, 7), good.quantity);
    try t.expectEqual(@as(f64, 12.5), good.price);
    try t.expectEqual(@as(i64, -3), good.maybe.?);

    // It used to become 0 without a word: "12,50" saved as nothing.
    try t.expectError(error.InvalidNumber, fromForm(arena.allocator(), Input, "price=12,50"));
    try t.expectError(error.InvalidNumber, fromForm(arena.allocator(), Input, "quantity=abc"));
    try t.expectError(error.InvalidNumber, fromForm(arena.allocator(), Input, "quantity=99999999999"));
    try t.expectError(error.InvalidNumber, fromForm(arena.allocator(), Input, "maybe=1.5"));
}

test "form: a checkbox that is not sent is false, whatever the default" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const Input = struct { active: bool = true, urgent: bool = false };
    // A browser sends nothing for an unchecked box: absence is the answer.
    const unchecked = try fromForm(arena.allocator(), Input, "other=1");
    try t.expect(!unchecked.active);
    try t.expect(!unchecked.urgent);
    const checked = try fromForm(arena.allocator(), Input, "active=on&urgent=true");
    try t.expect(checked.active);
    try t.expect(checked.urgent);
}

const std = @import("std");
const form = @import("form.zig");

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
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const name = field.name;
            const raw_value = self.data.get(name);
            const T2 = field.type;
            const is_optional = @typeInfo(T2) == .optional;
            const InnerType = if (is_optional) @typeInfo(T2).optional.child else T2;

            if (InnerType == []const u8) {
                if (is_optional) {
                    if (raw_value) |v| {
                        @field(result, name) = try self.allocator.dupe(u8, v);
                    } else {
                        @field(result, name) = null;
                    }
                } else {
                    @field(result, name) = try self.allocator.dupe(u8, raw_value orelse "");
                }
            } else if (InnerType == f64) {
                if (raw_value) |val| {
                    @field(result, name) = std.fmt.parseFloat(f64, val) catch 0.0;
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = 0.0;
                }
            } else if (InnerType == f32) {
                if (raw_value) |val| {
                    @field(result, name) = std.fmt.parseFloat(f32, val) catch 0.0;
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = 0.0;
                }
            } else if (InnerType == i32) {
                if (raw_value) |val| {
                    @field(result, name) = std.fmt.parseInt(i32, val, 10) catch 0;
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = 0;
                }
            } else if (InnerType == i64) {
                if (raw_value) |val| {
                    @field(result, name) = std.fmt.parseInt(i64, val, 10) catch 0;
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = 0;
                }
            } else if (InnerType == u32) {
                if (raw_value) |val| {
                    @field(result, name) = std.fmt.parseInt(u32, val, 10) catch 0;
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = 0;
                }
            } else if (InnerType == bool) {
                if (raw_value) |val| {
                    @field(result, name) = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
                } else if (is_optional) {
                    @field(result, name) = null;
                } else {
                    @field(result, name) = false;
                }
            } else {
                @compileError("Unsupported field type: " ++ @typeName(InnerType));
            }
        }
    }
};

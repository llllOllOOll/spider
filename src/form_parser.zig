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
        try self.parseInto(&result, T);
        return result;
    }

    pub fn parseInto(self: *FormParser, result: anytype, comptime T: type) !void {
        inline for (@typeInfo(T).Struct.fields) |field| {
            const name = field.name;
            const T2 = field.type;
            const is_optional = @typeInfo(T2) == .Optional;
            const InnerType = if (is_optional) @typeInfo(T2).Optional.child else T2;

            if (InnerType == []const u8) {
                if (is_optional) {
                    @field(result, name) = self.data.get(name);
                } else {
                    @field(result, name) = self.data.get(name) orelse "";
                }
            } else if (InnerType == f64) {
                const val = self.data.get(name) orelse (if (is_optional) null else "0");
                @field(result, name) = if (val) |v| (std.fmt.parseFloat(f64, v) catch if (is_optional) null else 0.0) else if (is_optional) null else 0.0;
            } else if (InnerType == f32) {
                const val = self.data.get(name) orelse (if (is_optional) null else "0");
                @field(result, name) = if (val) |v| (std.fmt.parseFloat(f32, v) catch if (is_optional) null else 0.0) else if (is_optional) null else 0.0;
            } else if (InnerType == i32) {
                const val = self.data.get(name) orelse (if (is_optional) null else "0");
                @field(result, name) = if (val) |v| (std.fmt.parseInt(i32, v, 10) catch if (is_optional) null else 0) else if (is_optional) null else 0;
            } else if (InnerType == i64) {
                const val = self.data.get(name) orelse (if (is_optional) null else "0");
                @field(result, name) = if (val) |v| (std.fmt.parseInt(i64, v, 10) catch if (is_optional) null else 0) else if (is_optional) null else 0;
            } else if (InnerType == u32) {
                const val = self.data.get(name) orelse (if (is_optional) null else "0");
                @field(result, name) = if (val) |v| (std.fmt.parseInt(u32, v, 10) catch if (is_optional) null else 0) else if (is_optional) null else 0;
            } else if (InnerType == bool) {
                const val = self.data.get(name);
                @field(result, name) = if (val) |v| (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")) else if (is_optional) null else false;
            } else {
                @compileError("Unsupported field type: " ++ @typeName(InnerType));
            }
        }
    }
};

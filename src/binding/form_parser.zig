//! Internal: fills a struct from a submitted form, urlencoded or multipart
//! (`FormParser`). It is what `c.parseForm(T)` and `spider.Form(T)` run.

const std = @import("std");
const form = @import("form.zig");
const multipart = @import("multipart.zig");

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
        inline for (info.field_names, info.field_types) |fname, ftype| {
            const name = fname;
            const T2 = ftype;
            const is_optional = @typeInfo(T2) == .optional;
            const InnerType = if (is_optional) @typeInfo(T2).optional.child else T2;

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
                try setField(&result, name, allocator, raw_value, InnerType, is_optional);
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
        inline for (info2.field_names, info2.field_types) |fname, ftype| {
            const name = fname;
            const raw_value = self.data.get(name);
            const T2 = ftype;
            const is_optional = @typeInfo(T2) == .optional;
            const InnerType = if (is_optional) @typeInfo(T2).optional.child else T2;
            try setField(result, name, self.allocator, raw_value, InnerType, is_optional);
        }
    }
};

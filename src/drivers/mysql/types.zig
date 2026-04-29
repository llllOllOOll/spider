// MySQL type mapping to Zig types
// Based on Bun's MySQLTypes.zig

const std = @import("std");
const protocol = @import("./protocol.zig");

// MySQL value representation
pub const Value = union(enum) {
    null,
    int8: i8,
    int16: i16,
    int24: i24,
    int32: i32,
    int64: i64,
    uint8: u8,
    uint16: u16,
    uint24: u24,
    uint32: u32,
    uint64: u64,
    float32: f32,
    float64: f64,
    string: []const u8,
    blob: []const u8,
    bool: bool,
    date: Date,
    time: Time,
    datetime: DateTime,
    timestamp: Timestamp,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string, .blob => |slice| {
                if (slice.len > 0) {
                    allocator.free(slice);
                }
            },
            else => {},
        }
    }

    pub fn toZig(self: Value, comptime T: type, allocator: std.mem.Allocator) !T {
        const type_info = @typeInfo(T);

        if (type_info == .optional) {
            const Child = type_info.optional.child;
            if (self == .null) return null;
            return try self.toZig(Child, allocator);
        }

        return switch (self) {
            .null => switch (T) {
                []const u8 => "",
                bool => false,
                i8, i16, i32, i64, u8, u16, u32, u64 => 0,
                f32, f64 => 0.0,
                else => @compileError("Cannot convert null to " ++ @typeName(T)),
            },
            .int8 => |v| switch (T) {
                i8 => v,
                i16, i32, i64 => @as(T, v),
                u8, u16, u32, u64 => if (v >= 0) @as(T, @intCast(v)) else error.NegativeToUnsigned,
                else => @compileError("Cannot convert int8 to " ++ @typeName(T)),
            },
            .int32 => |v| switch (T) {
                i32 => v,
                i8, i16 => if (v >= std.math.minInt(T) and v <= std.math.maxInt(T)) @as(T, @intCast(v)) else error.ValueOutOfRange,
                i64 => @as(i64, v),
                u8, u16, u32, u64 => if (v >= 0) @as(T, @intCast(v)) else error.NegativeToUnsigned,
                else => @compileError("Cannot convert int32 to " ++ @typeName(T)),
            },
            .int64 => |v| switch (T) {
                i64 => v,
                i8, i16, i32 => if (v >= std.math.minInt(T) and v <= std.math.maxInt(T)) @as(T, @intCast(v)) else error.ValueOutOfRange,
                u8, u16, u32, u64 => if (v >= 0) @as(T, @intCast(v)) else error.NegativeToUnsigned,
                else => @compileError("Cannot convert int64 to " ++ @typeName(T)),
            },
            .uint32 => |v| switch (T) {
                u32 => v,
                u8, u16 => if (v <= std.math.maxInt(T)) @as(T, @intCast(v)) else error.ValueOutOfRange,
                u64 => @as(u64, v),
                i8, i16, i32, i64 => if (v <= std.math.maxInt(T)) @as(T, @intCast(v)) else error.ValueOutOfRange,
                else => @compileError("Cannot convert uint32 to " ++ @typeName(T)),
            },
            .string => |v| switch (T) {
                []const u8 => try allocator.dupe(u8, v),
                bool => std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "TRUE"),
                i8, i16, i32, i64 => try std.fmt.parseInt(T, v, 10),
                u8, u16, u32, u64 => try std.fmt.parseInt(T, v, 10),
                f32, f64 => try std.fmt.parseFloat(T, v),
                else => @compileError("Cannot convert string to " ++ @typeName(T)),
            },
            .bool => |v| switch (T) {
                bool => v,
                i8, i16, i32, i64 => if (v) 1 else 0,
                u8, u16, u32, u64 => if (v) 1 else 0,
                []const u8 => if (v) "true" else "false",
                else => @compileError("Cannot convert bool to " ++ @typeName(T)),
            },
            else => @compileError("Conversion from " ++ @tagName(self) ++ " to " ++ @typeName(T) ++ " not implemented"),
        };
    }
};

// Date/time types
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32 = 0,
};

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32 = 0,
};

pub const Timestamp = struct {
    unix_timestamp: i64,
};

// Field metadata
pub const Field = struct {
    name: []const u8,
    field_type: protocol.FieldType,
    flags: protocol.ColumnFlags,
    is_nullable: bool,

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

// Result set metadata
pub const ResultSetMetadata = struct {
    fields: []Field,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResultSetMetadata) void {
        for (self.fields) |*field| {
            field.deinit(self.allocator);
        }
        self.allocator.free(self.fields);
    }
};

// Utility functions for type conversion
pub fn mysqlTypeToZigType(field_type: protocol.FieldType, flags: protocol.ColumnFlags) type {
    return switch (field_type) {
        .TINY => if (flags.UNSIGNED) u8 else i8,
        .SHORT => if (flags.UNSIGNED) u16 else i16,
        .LONG => if (flags.UNSIGNED) u32 else i32,
        .LONGLONG => if (flags.UNSIGNED) u64 else i64,
        .INT24 => if (flags.UNSIGNED) u24 else i24,
        .FLOAT => f32,
        .DOUBLE => f64,
        .DECIMAL, .NEWDECIMAL => f64, // Approximate with double
        .VARCHAR, .VAR_STRING, .STRING => []const u8,
        .BLOB, .TINY_BLOB, .MEDIUM_BLOB, .LONG_BLOB => []const u8,
        .DATE => Date,
        .TIME => Time,
        .DATETIME => DateTime,
        .TIMESTAMP => Timestamp,
        .YEAR => u16,
        .BIT => u64,
        .JSON => []const u8,
        .ENUM, .SET => []const u8,
        .GEOMETRY => []const u8,
        else => @compileError("Unsupported MySQL type: " ++ @tagName(field_type)),
    };
}

pub fn isNullable(field_type: protocol.FieldType, flags: protocol.ColumnFlags) bool {
    _ = field_type;
    return !flags.NOT_NULL;
}

// Text encoding/decoding
pub fn encodeText(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .int, .comptime_int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .float, .comptime_float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .bool => if (value) "1" else "0",
        .pointer => |p| if (p.size == .slice) value else @compileError("Unsupported pointer type"),
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

pub fn decodeText(comptime T: type, text: []const u8, allocator: std.mem.Allocator) !T {
    return switch (T) {
        []const u8 => try allocator.dupe(u8, text),
        bool => std.mem.eql(u8, text, "1") or std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "TRUE"),
        i8, i16, i32, i64 => try std.fmt.parseInt(T, text, 10),
        u8, u16, u32, u64 => try std.fmt.parseInt(T, text, 10),
        f32, f64 => try std.fmt.parseFloat(T, text),
        else => @compileError("Cannot decode text to " ++ @typeName(T)),
    };
}

pub fn mapRowToStruct(
    comptime T: type,
    row: []?[]const u8,
    field_names: [][]const u8,
    allocator: std.mem.Allocator,
) !T {
    var result: T = undefined;
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("T must be a struct");

    inline for (info.@"struct".fields) |field| {
        var found = false;
        for (field_names, 0..) |name, col_idx| {
            if (std.mem.eql(u8, name, field.name)) {
                const col_data = row[col_idx] orelse {
                    @field(result, field.name) = switch (@typeInfo(field.type)) {
                        .optional => null,
                        .pointer => @as(field.type, ""),
                        .int => @as(field.type, 0),
                        .bool => false,
                        else => undefined,
                    };
                    found = true;
                    break;
                };
                @field(result, field.name) = try parseField(field.type, col_data, allocator);
                found = true;
                break;
            }
        }
        if (!found) {
            @field(result, field.name) = switch (@typeInfo(field.type)) {
                .optional => null,
                .pointer => @as(field.type, ""),
                .int => @as(field.type, 0),
                .bool => false,
                else => undefined,
            };
        }
    }
    return result;
}

fn parseField(comptime T: type, data: []const u8, allocator: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, data, 10) catch 0,
        .float => std.fmt.parseFloat(T, data) catch 0.0,
        .bool => std.mem.eql(u8, data, "1"),
        .pointer => |ptr| if (ptr.child == u8)
            try allocator.dupe(u8, data)
        else
            error.UnsupportedType,
        .optional => |opt| if (data.len == 0)
            null
        else
            try parseField(opt.child, data, allocator),
        else => error.UnsupportedType,
    };
}

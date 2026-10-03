const std = @import("std");
const proto = @import("_proto.zig");

const Error = @This();

code: []const u8,
message: []const u8,
severity: []const u8,

column: ?[]const u8 = null,
constraint: ?[]const u8 = null,
data_type_name: ?[]const u8 = null,
detail: ?[]const u8 = null,
file: ?[]const u8 = null,
hint: ?[]const u8 = null,
internal_position: ?[]const u8 = null,
internal_query: ?[]const u8 = null,
line: ?[]const u8 = null,
position: ?[]const u8 = null,
routine: ?[]const u8 = null,
schema: ?[]const u8 = null,
severity2: ?[]const u8 = null,
table: ?[]const u8 = null,
where: ?[]const u8 = null,

pub fn isUnique(self: Error) bool {
    return std.mem.eql(u8, self.code, "23505");
}

pub fn parse(data: []const u8) Error {
    var err = Error{
        .code = "",
        .message = "",
        .severity = "",
    };

    var pos: usize = 0;
    while (pos < data.len) {
        const value_end = std.mem.indexOfScalarPos(u8, data, pos + 1, 0) orelse {
            // TODO: should not happen
            break;
        };

        const value = data[pos + 1 .. value_end];
        switch (data[pos]) {
            'S' => err.severity = value,
            'V' => err.severity2 = value,
            'C' => err.code = value,
            'M' => err.message = value,
            'D' => err.detail = value,
            'H' => err.hint = value,
            'P' => err.position = value,
            'p' => err.internal_position = value,
            'q' => err.internal_query = value,
            'W' => err.where = value,
            's' => err.schema = value,
            't' => err.table = value,
            'c' => err.column = value,
            'd' => err.data_type_name = value,
            'n' => err.constraint = value,
            'F' => err.file = value,
            'L' => err.line = value,
            'R' => err.routine = value,
            // a field we don't know: skip it, as the protocol asks
            else => {},
        }
        pos = value_end + 1;
    }

    return err;
}

const t = proto.testing;
test "Error: parse" {
    var buf = try proto.Buffer.init(t.allocator, 128);
    defer buf.deinit();

    {
        // only required
        try buf.writeByte('C');
        try buf.write("10391A");
        try buf.writeByte(0);

        try buf.writeByte('M');
        try buf.write("The Message");
        try buf.writeByte(0);

        try buf.writeByte('S');
        try buf.write("FATAL");
        try buf.writeByte(0);

        const err = Error.parse(buf.string());
        try t.expectString("10391A", err.code);
        try t.expectString("The Message", err.message);
        try t.expectString("FATAL", err.severity);
    }

    {
        // all fields
        const fields = [_]u8{ 'S', 'V', 'C', 'M', 'D', 'H', 'P', 'p', 'q', 'W', 's', 't', 'c', 'd', 'n', 'F', 'L', 'R' };
        for (fields) |field| {
            try buf.writeByte(field);
            try buf.writeByte(field);
            try buf.write("-value");
            try buf.writeByte(0);
        }

        const err = Error.parse(buf.string());
        try t.expectString("C-value", err.code);
        try t.expectString("M-value", err.message);
        try t.expectString("S-value", err.severity);
        try t.expectString("V-value", err.severity2.?);
        try t.expectString("D-value", err.detail.?);
        try t.expectString("H-value", err.hint.?);
        try t.expectString("P-value", err.position.?);
        try t.expectString("p-value", err.internal_position.?);
        try t.expectString("q-value", err.internal_query.?);
        try t.expectString("W-value", err.where.?);
        try t.expectString("s-value", err.schema.?);
        try t.expectString("t-value", err.table.?);
        try t.expectString("c-value", err.column.?);
        try t.expectString("d-value", err.data_type_name.?);
        try t.expectString("n-value", err.constraint.?);
        try t.expectString("F-value", err.file.?);
        try t.expectString("L-value", err.line.?);
        try t.expectString("R-value", err.routine.?);
    }
}

test "Error: parse ignores unknown fields" {
    // "Since more field types might be added in future, frontends should
    // silently ignore fields of unrecognized type." (protocol docs)
    const err = Error.parse("SERROR\x00C42501\x00Xa field from the future\x00Mthe message\x00\x01also unknown\x00Rroutine\x00\x00");
    try t.expectString("ERROR", err.severity);
    try t.expectString("42501", err.code);
    try t.expectString("the message", err.message);
    try t.expectString("routine", err.routine.?);
}

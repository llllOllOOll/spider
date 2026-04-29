// MySQL Protocol implementation
// Based on Bun's MySQL protocol implementation

const std = @import("std");

// Command packet types - from Bun's CommandType.zig
pub const CommandType = enum(u8) {
    COM_QUIT = 0x01,
    COM_INIT_DB = 0x02,
    COM_QUERY = 0x03,
    COM_FIELD_LIST = 0x04,
    COM_CREATE_DB = 0x05,
    COM_DROP_DB = 0x06,
    COM_REFRESH = 0x07,
    COM_SHUTDOWN = 0x08,
    COM_STATISTICS = 0x09,
    COM_PROCESS_INFO = 0x0a,
    COM_CONNECT = 0x0b,
    COM_PROCESS_KILL = 0x0c,
    COM_DEBUG = 0x0d,
    COM_PING = 0x0e,
    COM_TIME = 0x0f,
    COM_DELAYED_INSERT = 0x10,
    COM_CHANGE_USER = 0x11,
    COM_BINLOG_DUMP = 0x12,
    COM_TABLE_DUMP = 0x13,
    COM_CONNECT_OUT = 0x14,
    COM_REGISTER_SLAVE = 0x15,
    COM_STMT_PREPARE = 0x16,
    COM_STMT_EXECUTE = 0x17,
    COM_STMT_SEND_LONG_DATA = 0x18,
    COM_STMT_CLOSE = 0x19,
    COM_STMT_RESET = 0x1a,
    COM_SET_OPTION = 0x1b,
    COM_STMT_FETCH = 0x1c,
    COM_DAEMON = 0x1d,
    COM_BINLOG_DUMP_GTID = 0x1e,
    COM_RESET_CONNECTION = 0x1f,
};

// MySQL field types
pub const FieldType = enum(u8) {
    DECIMAL = 0x00,
    TINY = 0x01,
    SHORT = 0x02,
    LONG = 0x03,
    FLOAT = 0x04,
    DOUBLE = 0x05,
    NULL = 0x06,
    TIMESTAMP = 0x07,
    LONGLONG = 0x08,
    INT24 = 0x09,
    DATE = 0x0a,
    TIME = 0x0b,
    DATETIME = 0x0c,
    YEAR = 0x0d,
    NEWDATE = 0x0e,
    VARCHAR = 0x0f,
    BIT = 0x10,
    TIMESTAMP2 = 0x11,
    DATETIME2 = 0x12,
    TIME2 = 0x13,
    JSON = 0xf5,
    NEWDECIMAL = 0xf6,
    ENUM = 0xf7,
    SET = 0xf8,
    TINY_BLOB = 0xf9,
    MEDIUM_BLOB = 0xfa,
    LONG_BLOB = 0xfb,
    BLOB = 0xfc,
    VAR_STRING = 0xfd,
    STRING = 0xfe,
    GEOMETRY = 0xff,
};

// MySQL column flags
pub const ColumnFlags = packed struct(u16) {
    NOT_NULL: bool = false,
    PRI_KEY: bool = false,
    UNIQUE_KEY: bool = false,
    MULTIPLE_KEY: bool = false,
    BLOB: bool = false,
    UNSIGNED: bool = false,
    ZEROFILL: bool = false,
    BINARY: bool = false,
    ENUM: bool = false,
    AUTO_INCREMENT: bool = false,
    TIMESTAMP: bool = false,
    SET: bool = false,
    NO_DEFAULT_VALUE: bool = false,
    ON_UPDATE_NOW: bool = false,
    _padding: u2 = 0,
};

// Packet header
pub const PacketHeader = packed struct {
    payload_length: u24,
    sequence_id: u8,
};

// Handshake packet
pub const HandshakeV10 = struct {
    protocol_version: u8,
    server_version: []const u8,
    connection_id: u32,
    auth_plugin_data_part_1: [8]u8,
    filler: u8,
    capability_flags_1: u16,
    character_set: u8,
    status_flags: u16,
    capability_flags_2: u16,
    auth_plugin_data_len: u8,
    reserved: [10]u8,
    auth_plugin_data_part_2: []const u8,
    auth_plugin_name: []const u8,
};

// Handshake response
pub const HandshakeResponse41 = struct {
    capability_flags: u32,
    max_packet_size: u32,
    character_set: u8,
    reserved: [23]u8,
    username: []const u8,
    auth_response: []const u8,
    database: []const u8,
    auth_plugin_name: []const u8,
};

// Result set header
pub const ResultSetHeader = struct {
    field_count: usize,
    extra: ?[]const u8,
};

// Column definition
pub const ColumnDefinition = struct {
    catalog: []const u8,
    schema: []const u8,
    table: []const u8,
    org_table: []const u8,
    name: []const u8,
    org_name: []const u8,
    next_length: u8,
    character_set: u16,
    column_length: u32,
    field_type: FieldType,
    flags: ColumnFlags,
    decimals: u8,
};

// Error packet
pub const ErrorPacket = struct {
    error_code: u16,
    sql_state: [5]u8,
    error_message: []const u8,
};

// OK packet
pub const OkPacket = struct {
    affected_rows: u64,
    last_insert_id: u64,
    status_flags: u16,
    warnings: u16,
    info: ?[]const u8,
};

// EOF packet
pub const EofPacket = struct {
    warnings: u16,
    status_flags: u16,
};

// Utility functions for protocol handling
pub fn readLengthEncodedInteger(reader: *std.Io.Reader) !u64 {
    const first_byte = try reader.takeByte();

    return switch (first_byte) {
        0xfb => 0, // NULL
        0xfc => @as(u64, try reader.takeInt(u16, .little)),
        0xfd => @as(u64, try reader.takeInt(u24, .little)),
        0xfe => try reader.takeInt(u64, .little),
        else => @as(u64, first_byte),
    };
}

pub fn writeLengthEncodedInteger(writer: anytype, value: u64) !void {
    if (value < 251) {
        try writer.writeByte(@as(u8, @intCast(value)));
    } else if (value < 65536) {
        try writer.writeByte(0xfc);
        try writer.writeInt(u16, @as(u16, @intCast(value)), .little);
    } else if (value < 16777216) {
        try writer.writeByte(0xfd);
        try writer.writeInt(u24, @as(u24, @intCast(value)), .little);
    } else {
        try writer.writeByte(0xfe);
        try writer.writeInt(u64, value, .little);
    }
}

pub fn readLengthEncodedString(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]const u8 {
    const length = try readLengthEncodedInteger(reader);
    if (length == 0) return "";

    const result = try reader.readAlloc(allocator, @as(usize, @intCast(length)));
    return result;
}

pub fn writeLengthEncodedString(writer: anytype, str: []const u8) !void {
    try writeLengthEncodedInteger(writer, str.len);
    try writer.writeAll(str);
}

// Packet reading/writing utilities — use *std.Io.Reader / *std.Io.Writer (Zig 0.16 async I/O)
pub fn readPacket(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    const header = try reader.takeArray(4);
    const payload_length = std.mem.readInt(u24, header[0..3], .little);
    return reader.readAlloc(allocator, payload_length);
}

pub fn writePacket(writer: *std.Io.Writer, payload: []const u8, sequence_id: u8) !void {
    var header_buf: [4]u8 = undefined;
    std.mem.writeInt(u24, header_buf[0..3], @as(u24, @intCast(payload.len)), .little);
    header_buf[3] = sequence_id;

    try writer.writeAll(&header_buf);
    try writer.writeAll(payload);
    try writer.flush();
}

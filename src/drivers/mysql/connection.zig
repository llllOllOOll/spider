const std = @import("std");
const protocol = @import("./protocol.zig");

pub const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    sequence_id: u8 = 0,
    capabilities: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Connection {
        std.log.info("MySQL: Connecting to {s}:{}", .{ config.host, config.port });
        const address = try std.Io.net.IpAddress.parse(config.host, config.port);
        const stream = try address.connect(io, .{ .mode = .stream });
        var conn = Connection{ .stream = stream, .io = io, .allocator = allocator };
        try conn.handshake(config);
        return conn;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
    }

    fn handshake(self: *Connection, config: Config) !void {
        var read_buf: [65536]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(self.stream, self.io, &read_buf);
        var sw = std.Io.net.Stream.Writer.init(self.stream, self.io, &write_buf);
        const reader = &sr.interface;
        const writer = &sw.interface;

        const payload = try protocol.readPacket(reader, self.allocator);
        defer self.allocator.free(payload);

        var hr = std.Io.Reader.fixed(payload);

        const protocol_version = try hr.takeByte();
        if (protocol_version != 10) return error.UnsupportedProtocol;

        // server_version — null-terminated
        const server_version: []const u8 = try hr.takeSentinel(0);
        std.log.info("MySQL: {s}", .{server_version});

        // connection_id
        _ = try hr.takeInt(u32, .little);

        // auth_plugin_data_part_1 — 8 bytes
        var auth_part1: [8]u8 = undefined;
        try hr.readSliceAll(&auth_part1);

        // filler
        _ = try hr.takeByte();

        // capabilities
        const cap1 = try hr.takeInt(u16, .little);
        _ = try hr.takeByte(); // character_set
        _ = try hr.takeInt(u16, .little); // status_flags
        const cap2 = try hr.takeInt(u16, .little);
        self.capabilities = (@as(u32, cap2) << 16) | cap1;

        // auth_plugin_data_len
        const auth_data_len = try hr.takeByte();

        // reserved — 10 bytes
        var reserved_buf: [10]u8 = undefined;
        try hr.readSliceAll(&reserved_buf);

        // auth_plugin_data_part_2 — max(13, auth_data_len - 8)
        const part2_len = @max(13, @as(usize, auth_data_len) -| 8);
        const auth_part2 = try self.allocator.alloc(u8, part2_len);
        defer self.allocator.free(auth_part2);
        try hr.readSliceAll(auth_part2);

        // auth_plugin_name — null-terminated (optional)
        const auth_plugin_name: []const u8 = hr.takeSentinel(0) catch "";
        _ = auth_plugin_name;

        // auth_data = part1[0..8] ++ part2[0..12]
        var auth_data: [20]u8 = undefined;
        @memcpy(auth_data[0..8], &auth_part1);
        @memcpy(auth_data[8..20], auth_part2[0..@min(12, auth_part2.len)]);

        // Client capabilities
        const CLIENT_LONG_PASSWORD: u32 = 1 << 0;
        const CLIENT_CONNECT_WITH_DB: u32 = 1 << 3;
        const CLIENT_PROTOCOL_41: u32 = 1 << 9;
        const CLIENT_SECURE_CONNECTION: u32 = 1 << 15;
        const CLIENT_PLUGIN_AUTH: u32 = 1 << 19;
        const client_caps: u32 = CLIENT_LONG_PASSWORD | CLIENT_CONNECT_WITH_DB |
            CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH;

        // Build HandshakeResponse41
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.allocator);

        var tmp4: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp4, client_caps, .little);
        try resp.appendSlice(self.allocator, &tmp4);

        std.mem.writeInt(u32, &tmp4, 0xFFFFFF, .little);
        try resp.appendSlice(self.allocator, &tmp4);

        try resp.append(self.allocator, 33); // utf8_general_ci

        const zeros23 = [_]u8{0} ** 23;
        try resp.appendSlice(self.allocator, &zeros23);

        // username (null-terminated)
        try resp.appendSlice(self.allocator, config.user);
        try resp.append(self.allocator, 0);

        // auth_response
        if (config.password.len > 0) {
            var auth_resp: [20]u8 = undefined;
            mysqlNativePassword(config.password, &auth_data, &auth_resp);
            try resp.append(self.allocator, 20);
            try resp.appendSlice(self.allocator, &auth_resp);
        } else {
            try resp.append(self.allocator, 0);
        }

        // database (null-terminated)
        try resp.appendSlice(self.allocator, config.database);
        try resp.append(self.allocator, 0);

        // auth_plugin_name
        try resp.appendSlice(self.allocator, "mysql_native_password");
        try resp.append(self.allocator, 0);

        self.sequence_id = 1;
        try protocol.writePacket(writer, resp.items, self.sequence_id);
        self.sequence_id +%= 1;

        // Read auth response
        const resp_payload = try protocol.readPacket(reader, self.allocator);
        defer self.allocator.free(resp_payload);

        switch (resp_payload[0]) {
            0x00 => std.log.info("MySQL: auth OK", .{}),
            0xff => {
                const err_code = std.mem.readInt(u16, resp_payload[1..3], .little);
                std.log.err("MySQL auth error: {d}", .{err_code});
                return error.AuthenticationFailed;
            },
            else => return error.UnexpectedResponse,
        }
    }

    fn mysqlNativePassword(
        password: []const u8,
        auth_data: *const [20]u8,
        out: *[20]u8,
    ) void {
        var sha1_pass: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(password, &sha1_pass, .{});

        var sha1_sha1: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(&sha1_pass, &sha1_sha1, .{});

        var h = std.crypto.hash.Sha1.init(.{});
        h.update(auth_data);
        h.update(&sha1_sha1);
        var combined: [20]u8 = undefined;
        h.final(&combined);

        for (out, 0..) |*b, i| b.* = sha1_pass[i] ^ combined[i];
    }

    pub fn query(self: *Connection, sql: []const u8) !void {
        self.sequence_id = 0;

        var read_buf: [65536]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(self.stream, self.io, &read_buf);
        var sw = std.Io.net.Stream.Writer.init(self.stream, self.io, &write_buf);
        const reader = &sr.interface;
        const writer = &sw.interface;

        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(self.allocator);
        try cmd.append(self.allocator, @intFromEnum(protocol.CommandType.COM_QUERY));
        try cmd.appendSlice(self.allocator, sql);
        try protocol.writePacket(writer, cmd.items, self.sequence_id);
        self.sequence_id +%= 1;

        const resp = try protocol.readPacket(reader, self.allocator);
        defer self.allocator.free(resp);

        switch (resp[0]) {
            0x00 => std.log.info("MySQL: exec OK", .{}),
            0xff => {
                const err_code = std.mem.readInt(u16, resp[1..3], .little);
                const msg = if (resp.len > 8) resp[8..] else "";
                std.log.err("MySQL exec error {}: {s}", .{ err_code, msg });
                return error.QueryFailed;
            },
            else => {},
        }
    }

    pub const RowSet = struct {
        field_names: [][]const u8,
        rows: [][]?[]const u8,
    };

    pub fn queryRows(
        self: *Connection,
        allocator: std.mem.Allocator,
        sql: []const u8,
    ) !RowSet {
        self.sequence_id = 0;

        var read_buf: [65536]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(self.stream, self.io, &read_buf);
        var sw = std.Io.net.Stream.Writer.init(self.stream, self.io, &write_buf);
        const reader = &sr.interface;
        const writer = &sw.interface;

        // Send COM_QUERY
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(allocator);
        try cmd.append(allocator, @intFromEnum(protocol.CommandType.COM_QUERY));
        try cmd.appendSlice(allocator, sql);
        try protocol.writePacket(writer, cmd.items, self.sequence_id);
        self.sequence_id +%= 1;

        // Read result set header
        const hdr = try protocol.readPacket(reader, allocator);
        defer allocator.free(hdr);

        if (hdr[0] == 0x00) return .{ .field_names = &.{}, .rows = &.{} };
        if (hdr[0] == 0xff) return error.QueryFailed;

        var hdr_r = std.Io.Reader.fixed(hdr);
        const field_count: usize = @intCast(try protocol.readLengthEncodedInteger(&hdr_r));

        // Read ColumnDefinition packets — extract names
        var field_names: std.ArrayList([]const u8) = .empty;
        for (0..field_count) |_| {
            const col = try protocol.readPacket(reader, allocator);
            defer allocator.free(col);

            var cr = std.Io.Reader.fixed(col);
            // Skip catalog, schema, table, org_table without allocating
            for (0..4) |_| {
                const len: usize = @intCast(try protocol.readLengthEncodedInteger(&cr));
                _ = try cr.take(len);
            }
            // name — allocate and keep
            const name = try protocol.readLengthEncodedString(&cr, allocator);
            try field_names.append(allocator, name);
        }

        // EOF after column definitions
        const eof1 = try protocol.readPacket(reader, allocator);
        allocator.free(eof1);

        // Read DataRows until EOF
        var rows: std.ArrayList([]?[]const u8) = .empty;

        while (true) {
            const row_pkt = try protocol.readPacket(reader, allocator);

            // EOF packet (0xfe, len < 9)
            if (row_pkt[0] == 0xfe and row_pkt.len < 9) {
                allocator.free(row_pkt);
                break;
            }
            if (row_pkt[0] == 0xff) {
                allocator.free(row_pkt);
                return error.QueryFailed;
            }

            var rr = std.Io.Reader.fixed(row_pkt);
            const cols = try allocator.alloc(?[]const u8, field_count);

            for (cols) |*col| {
                const first = try rr.takeByte();
                if (first == 0xfb) {
                    col.* = null;
                } else {
                    const col_len: usize = switch (first) {
                        0xfc => @intCast(try rr.takeInt(u16, .little)),
                        0xfd => @intCast(try rr.takeInt(u24, .little)),
                        0xfe => @intCast(try rr.takeInt(u64, .little)),
                        else => @intCast(first),
                    };
                    const col_data = try allocator.alloc(u8, col_len);
                    try rr.readSliceAll(col_data);
                    col.* = col_data;
                }
            }

            try rows.append(allocator, cols);
            allocator.free(row_pkt);
        }

        return .{
            .field_names = try field_names.toOwnedSlice(allocator),
            .rows = try rows.toOwnedSlice(allocator),
        };
    }
};

pub const Config = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password: []const u8 = "",
};

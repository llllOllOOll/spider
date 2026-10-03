const std = @import("std");

const Allocator = std.mem.Allocator;
const Conn = @import("conn.zig").Conn;

pub const allocator = std.testing.allocator;
pub const io = std.testing.io;

pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
    _ = arena.reset(.free_all);
}

// std.testing.expectEqual won't coerce expected to actual, which is a problem
// when expected is frequently a comptime.
// https://github.com/ziglang/zig/issues/4437
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}
pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    expectEqual(true, expected - delta <= actual) catch |err| {
        return err;
    };
    expectEqual(true, expected + delta >= actual) catch |err| {
        return err;
    };
}
pub const expectError = std.testing.expectError;
pub const expectSlice = std.testing.expectEqualSlices;
pub const expectString = std.testing.expectEqualStrings;
pub fn expectStringSlice(expected: []const []const u8, actual: [][]const u8) !void {
    try expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try expectString(e, a);
    }
}

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&seed));
    return std.Random.DefaultPrng.init(seed);
}

pub fn setup() !void {
    var c = try connect(.{});
    defer c.deinit();
    _ = c.exec(
        \\ drop user if exists pgz_user_nopass;
        \\ drop user if exists pgz_user_clear;
        \\ drop user if exists pgz_user_scram_sha256;
        \\ drop user if exists pgz_user_ssl;
        \\ create user pgz_user_nopass;
        \\ create user pgz_user_clear with password 'pgz_user_clear_pw';
        \\ create user pgz_user_scram_sha256 with password 'pgz_user_scram_sha256_pw';
        \\ create user pgz_user_ssl with password 'pgz_user_ssl_pw';
    , .{}) catch |err| try fail(c, err);

    _ = c.exec(
        \\ drop table if exists simple_table;
        \\ create table simple_table (value text);
    , .{}) catch |err| try fail(c, err);

    _ = c.exec(
        \\ drop type if exists custom_enum cascade;
        \\ create type custom_enum as enum ('val1', 'val2');
    , .{}) catch |err| try fail(c, err);

    _ = c.exec(
        \\ drop table if exists all_types;
        \\ create table all_types (
        \\   id integer primary key,
        \\   col_int2 smallint,
        \\   col_int4 integer,
        \\   col_int8 bigint,
        \\   col_float4 float4,
        \\   col_float8 float8,
        \\   col_bool bool,
        \\   col_text text,
        \\   col_bytea bytea,
        \\   col_int2_arr smallint[],
        \\   col_int4_arr integer[],
        \\   col_int8_arr bigint[],
        \\   col_float4_arr float4[],
        \\   col_float8_arr float[],
        \\   col_bool_arr bool[],
        \\   col_text_arr text[],
        \\   col_bytea_arr bytea[],
        \\   col_enum custom_enum,
        \\   col_enum_arr custom_enum[],
        \\   col_uuid uuid,
        \\   col_uuid_arr uuid[],
        \\   col_numeric numeric,
        \\   col_numeric_arr numeric[],
        \\   col_timestamp timestamp,
        \\   col_timestamp_arr timestamp[],
        \\   col_json json,
        \\   col_json_arr json[],
        \\   col_jsonb jsonb,
        \\   col_jsonb_arr jsonb[],
        \\   col_char char,
        \\   col_char_arr char[],
        \\   col_charn char(3),
        \\   col_charn_arr char(2)[],
        \\   col_timestamptz timestamptz,
        \\   col_timestamptz_arr timestamptz[],
        \\   col_cidr cidr,
        \\   col_cidr_arr cidr[],
        \\   col_inet inet,
        \\   col_inet_arr inet[],
        \\   col_macaddr macaddr,
        \\   col_macaddr_arr macaddr[],
        \\   col_macaddr8 macaddr8,
        \\   col_macaddr8_arr macaddr8[]
        \\ );
    , .{}) catch |err| try fail(c, err);
}

// Dummy net.Stream, lets us setup data to be read and capture data that is written.
pub const Stream = struct {
    closed: bool,
    _read_index: usize,
    socket: c_int = 0,
    _to_read: std.ArrayList(u8),
    _received: std.ArrayList(u8),

    pub fn init() *Stream {
        const s = allocator.create(Stream) catch unreachable;
        s.* = .{
            .closed = false,
            ._read_index = 0,
            ._to_read = .empty,
            ._received = .empty,
        };
        return s;
    }

    pub fn deinit(self: *Stream) void {
        self._to_read.deinit(allocator);
        self._received.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn reset(self: *Stream) void {
        self._read_index = 0;
        self._to_read.clearRetainingCapacity();
        self._received.clearRetainingCapacity();
    }

    pub fn received(self: *Stream) []const u8 {
        return self._received.items;
    }

    pub fn add(self: *Stream, value: []const u8) void {
        self._to_read.appendSlice(allocator, value) catch unreachable;
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        std.debug.assert(!self.closed);

        const read_index = self._read_index;
        const items = self._to_read.items;

        if (read_index == items.len) {
            return 0;
        }
        if (buf.len == 0) {
            return 0;
        }

        // let's fragment this message
        const left_to_read = items.len - read_index;
        const max_can_read = if (buf.len < left_to_read) buf.len else left_to_read;

        const to_read = max_can_read;
        var data = items[read_index..(read_index + to_read)];
        if (data.len > buf.len) {
            // we have more data than we have space in buf (our target)
            // we'll give it when it can take
            data = data[0..buf.len];
        }
        self._read_index = read_index + data.len;

        @memcpy(buf[0..data.len], data);
        return data.len;
    }

    // store messages that are written to the stream
    pub fn writeAll(self: *Stream, data: []const u8) !void {
        self._received.appendSlice(allocator, data) catch unreachable;
    }

    pub fn close(self: *Stream) void {
        self.closed = true;
    }
};

pub fn getTestPort() u16 {
    return 5433;
}

pub fn connect(opts: anytype) !Conn {
    const T = @TypeOf(opts);

    var c = try Conn.open(io, allocator, .{
        .tls = if (@hasField(T, "tls")) opts.tls else .off,
        .host = if (@hasField(T, "host")) opts.host else "127.0.0.1",
        .port = if (@hasField(T, "port")) opts.port else getTestPort(),
        .read_buffer = if (@hasField(T, "read_buffer")) opts.read_buffer else 2000,
    });

    c.auth(authOpts(opts)) catch |err| {
        if (c.err) |pg| {
            @panic(pg.message);
        }
        @panic(@errorName(err));
    };
    return c;
}

pub fn authOpts(opts: anytype) Conn.AuthOpts {
    const T = @TypeOf(opts);
    return .{
        .database = if (@hasField(T, "database")) opts.database else "postgres",
        .username = if (@hasField(T, "username")) opts.username else "postgres",
        .password = if (@hasField(T, "password")) opts.password else "postgres",
    };
}

pub fn fail(_: Conn, err: anyerror) !void {
    return err;
}

pub fn scalar(c: *Conn, sql: []const u8) i32 {
    var result = c.query(sql, .{}) catch unreachable;
    defer result.deinit();

    const row = (result.nextUnsafe() catch unreachable).?;
    const value = row.get(i32, 0);
    result.drain() catch unreachable;
    return value;
}

// A scripted Postgres for tests that need to control exactly which bytes
// arrive in which packet — something a real server won't promise.
//
// It accepts one connection. For each stage it waits for the client to write
// something, then sends the stage's chunks one at a time with a pause in
// between, so each chunk reaches the client in its own read.
pub const FakeServer = struct {
    port: u16,
    stages: []const Stage,
    server: std.Io.net.Server,
    thread: std.Thread,

    pub const Stage = []const []const u8;

    const pause_ms = 40;
    var next_port = std.atomic.Value(u16).init(54710);

    pub fn start(stages: []const Stage) !*FakeServer {
        const port = next_port.fetchAdd(1, .seq_cst);
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

        const self = try allocator.create(FakeServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .port = port,
            .stages = stages,
            .server = try address.listen(io, .{ .reuse_address = true }),
            .thread = undefined,
        };
        errdefer self.server.deinit(io);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    // Call after the client connection is closed.
    pub fn stop(self: *FakeServer) void {
        self.thread.join();
        self.server.deinit(io);
        allocator.destroy(self);
    }

    pub fn connect(self: *const FakeServer) !Conn {
        return Conn.open(io, allocator, .{ .tls = .off, .host = "127.0.0.1", .port = self.port });
    }

    fn run(self: *FakeServer) void {
        const stream = self.server.accept(io) catch return;
        defer stream.close(io);

        var buf: [4096]u8 = undefined;
        for (self.stages) |chunks| {
            if ((readSome(stream, &buf) catch 0) == 0) return;
            for (chunks, 0..) |chunk, i| {
                if (i > 0) std.Io.sleep(io, .fromMilliseconds(pause_ms), .awake) catch {};
                writeAll(stream, chunk) catch return;
            }
        }
        // stay around until the client hangs up
        while ((readSome(stream, &buf) catch 0) != 0) {}
    }

    fn readSome(stream: std.Io.net.Stream, buf: []u8) !usize {
        var vecs: [1][]u8 = .{buf};
        var reader = stream.reader(io, &.{});
        return reader.interface.readVec(&vecs);
    }

    fn writeAll(stream: std.Io.net.Stream, data: []const u8) !void {
        var wbuf: [1024]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }
};

// One backend message: type byte, length (which counts itself), payload.
pub fn message(comptime typ: u8, comptime payload: []const u8) []const u8 {
    comptime {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(payload.len + 4), .big);
        const all = [_]u8{typ} ++ len ++ payload[0..payload.len].*;
        return &all;
    }
}

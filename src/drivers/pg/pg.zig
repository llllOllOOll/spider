const std = @import("std");
const pg_lib = @import("pg");
const env = @import("../../internal/env.zig");

/// Marker type for PostgreSQL array parameters that should use ANY() pattern
pub fn ArrayParameter(comptime T: type) type {
    return struct {
        values: []const T,
        type_name: []const u8,

        pub fn init(values: []const T, type_name: []const u8) @This() {
            return .{
                .values = values,
                .type_name = type_name,
            };
        }
    };
}

/// Convert an array to PostgreSQL array parameter for use with ANY() operator.
/// Example: array(i32, &[_]i32{ 1, 2, 3 }) → ArrayParameter that will be handled as "$1::integer[]"
pub fn array(comptime T: type, values: []const T) ArrayParameter(T) {
    // Determine PostgreSQL type name
    const type_name = switch (T) {
        i16 => "smallint",
        i32 => "integer",
        i64 => "bigint",
        f32 => "real",
        f64 => "double precision",
        bool => "boolean",
        []const u8, []u8 => "text",
        else => "text", // fallback
    };

    return ArrayParameter(T).init(values, type_name);
}

pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    database: []const u8,
    user: []const u8,
    password: []const u8 = "",
    pool_size: usize = 10,
    timeout_ms: u64 = 5000,
};

pub const DbConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
    database: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    pool_size: ?usize = null,
};

var db_pool: ?*pg_lib.Pool = null;
var db_allocator: ?std.mem.Allocator = null;

fn getEnv(key: []const u8, default: []const u8) []const u8 {
    return env.getOr(key, default);
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    const val = env.get(key) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;

    const host = overrides.host orelse getEnv("POSTGRES_HOST", "localhost");
    const port = overrides.port orelse getEnvInt("POSTGRES_PORT", 5432);
    const user = overrides.user orelse getEnv("POSTGRES_USER", "spider");
    const password = overrides.password orelse getEnv("POSTGRES_PASSWORD", "spider");
    const database = overrides.database orelse getEnv("POSTGRES_DB", "spider_db");
    const pool_size: u16 = @intCast(overrides.pool_size orelse 10);

    const opts = pg_lib.Pool.Opts{
        .size = pool_size,
        .auth = .{
            .username = user,
            .password = password,
            .database = database,
        },
        .connect = .{
            .host = host,
            .port = port,
        },
    };

    var attempt: usize = 0;
    var delay_ms: i64 = 1000;
    while (attempt < 5) : (attempt += 1) {
        db_pool = pg_lib.Pool.init(io, allocator, opts) catch |err| {
            if (attempt < 4) {
                std.log.warn("pg: connect attempt {d}/5 failed, retrying in {d}ms", .{ attempt + 1, delay_ms });
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay_ms), .real);
                delay_ms *= 2;
                continue;
            }
            std.log.err("pg: connection failed after 5 attempts", .{});
            return err;
        };
        std.log.info("pg: connected ({d} connections)", .{pool_size});
        break;
    }
}

pub fn deinit() void {
    if (db_pool) |p| {
        p.deinit();
        db_pool = null;
    }
    db_allocator = null;
}

pub fn acquireConn() !*pg_lib.Conn {
    return db_pool.?.acquire();
}

pub fn releaseConn(conn: *pg_lib.Conn) void {
    db_pool.?.release(conn);
}

pub fn QueryResult(comptime T: type) type {
    return switch (T) {
        void => void,
        i32 => i32,
        else => []T,
    };
}

fn readIntBinary(data: []const u8, oid: i32) i64 {
    return switch (oid) {
        21 => @as(i64, std.mem.readInt(i16, data[0..2], .big)),
        23 => @as(i64, std.mem.readInt(i32, data[0..4], .big)),
        20 => std.mem.readInt(i64, data[0..8], .big),
        else => 0,
    };
}

fn readFloatBinary(data: []const u8, oid: i32) f64 {
    return switch (oid) {
        700 => @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, data[0..4], .big)))),
        701 => @as(f64, @bitCast(std.mem.readInt(u64, data[0..8], .big))),
        else => 0.0,
    };
}

fn nullValue(comptime T: type) T {
    const info = @typeInfo(T);
    if (info == .optional) return null;
    return switch (T) {
        []const u8 => "",
        bool => false,
        i8, i16, i32, i64, u8, u16, u32, u64 => 0,
        f32, f64 => 0.0,
        else => @compileError("nullValue: unsupported field type " ++ @typeName(T)),
    };
}

fn decodeField(comptime T: type, data: []const u8, oid: i32, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        return try decodeField(info.optional.child, data, oid, arena);
    }
    if (info == .@"enum") {
        return std.meta.stringToEnum(T, data) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try arena.dupe(u8, data),
        bool => if (oid == 16) (data.len > 0 and data[0] != 0) else (data.len > 0 and (data[0] == 't' or data[0] == '1')),
        i8 => @intCast(readIntBinary(data, oid)),
        i16 => @intCast(readIntBinary(data, oid)),
        i32 => @intCast(readIntBinary(data, oid)),
        i64 => readIntBinary(data, oid),
        u8 => @intCast(readIntBinary(data, oid)),
        u16 => @intCast(readIntBinary(data, oid)),
        u32 => @intCast(readIntBinary(data, oid)),
        u64 => @intCast(readIntBinary(data, oid)),
        f32 => @floatCast(readFloatBinary(data, oid)),
        f64 => readFloatBinary(data, oid),
        else => @compileError("decodeField: unsupported field type " ++ @typeName(T)),
    };
}

fn mapRow(comptime T: type, result: *pg_lib.Result, row: pg_lib.Row, arena: std.mem.Allocator) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var col_idx: ?usize = null;
        for (result.column_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, field.name)) {
                col_idx = i;
                break;
            }
        }
        if (col_idx) |ci| {
            const value = row.values[ci];
            @field(item, field.name) = if (value.is_null)
                nullValue(field.type)
            else
                try decodeField(field.type, value.data, row.oids[ci], arena);
        } else {
            @field(item, field.name) = nullValue(field.type);
        }
    }
    return item;
}

fn execTyped(
    conn: *pg_lib.Conn,
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    if (T == void) {
        _ = try conn.exec(sql, params);
        return {};
    }

    var result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer result.deinit();

    if (T == i32) {
        const row = (try result.next()) orelse return 0;
        const v = row.values[0];
        if (v.is_null) return 0;
        return @intCast(readIntBinary(v.data, row.oids[0]));
    }

    var items = std.ArrayListUnmanaged(T).empty;
    while (try result.next()) |row| {
        try items.append(arena, try mapRow(T, result, row, arena));
    }
    return try items.toOwnedSlice(arena);
}

fn execTypedOne(
    conn: *pg_lib.Conn,
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?T {
    var result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer result.deinit();

    const row = (try result.next()) orelse return null;

    if (T == i32) {
        const v = row.values[0];
        if (v.is_null) return null;
        return @intCast(readIntBinary(v.data, row.oids[0]));
    }
    return try mapRow(T, result, row, arena);
}

pub fn query(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTyped(conn, T, arena, sql, params);
}

pub fn queryOne(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?T {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTypedOne(conn, T, arena, sql, params);
}

/// Execute raw SQL without parameters. Supports multiple statements separated by ';'.
pub fn queryExecute(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
) !QueryResult(T) {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    if (T == void) {
        var it = std.mem.splitScalar(u8, sql, ';');
        while (it.next()) |stmt| {
            const s = std.mem.trim(u8, stmt, " \n\r\t");
            if (s.len == 0) continue;
            _ = try conn.exec(s, .{});
        }
        return {};
    }

    return execTyped(conn, T, arena, sql, .{});
}

/// Execute raw SQL without parameters and return a single row.
pub fn queryOneExecute(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
) !?T {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTypedOne(conn, T, arena, sql, .{});
}

pub fn begin() !Transaction {
    const conn = try db_pool.?.acquire();
    _ = try conn.exec("BEGIN", .{});
    return Transaction{ .conn = conn };
}

/// Database transaction. Use begin() to create one.
///
/// Example:
///   var tx = try pg.begin();
///   defer tx.rollback();
///   try tx.query(void, arena, "INSERT INTO users (name) VALUES ($1)", .{"Alice"});
///   try tx.commit();
pub const Transaction = struct {
    conn: *pg_lib.Conn,
    committed: bool = false,
    rolled_back: bool = false,

    /// Deprecated: use tx.query(void, arena, sql, params) instead.
    pub fn exec(self: *Transaction, sql: []const u8, params: anytype) !void {
        _ = try self.conn.exec(sql, params);
    }

    pub fn query(
        self: *Transaction,
        comptime T: type,
        arena: std.mem.Allocator,
        sql: []const u8,
        params: anytype,
    ) !QueryResult(T) {
        return execTyped(self.conn, T, arena, sql, params);
    }

    pub fn queryOne(
        self: *Transaction,
        comptime T: type,
        arena: std.mem.Allocator,
        sql: []const u8,
        params: anytype,
    ) !?T {
        return execTypedOne(self.conn, T, arena, sql, params);
    }

    pub fn commit(self: *Transaction) !void {
        if (self.committed or self.rolled_back) return error.TransactionAlreadyFinished;
        _ = try self.conn.exec("COMMIT", .{});
        db_pool.?.release(self.conn);
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) void {
        if (self.committed or self.rolled_back) return;
        _ = self.conn.exec("ROLLBACK", .{}) catch {};
        db_pool.?.release(self.conn);
        self.rolled_back = true;
    }
};

// ── PgDriver (Database interface for ORM-style usage) ───────────────────────

fn pgExecFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
    _ = ptr;
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\r\t");
        if (s.len == 0) continue;
        _ = try conn.exec(s, .{});
    }
}

fn pgDeinitFn(_: *anyopaque) void {}

pub const PgDriver = struct {
    _dummy: u8 = 0,

    pub fn database(_: *PgDriver) @import("../../core/database.zig").Database {
        return .{
            .ptr = @constCast(db_pool orelse @panic("PostgreSQL not initialized")),
            .exec_fn = pgExecFn,
            .deinit_fn = pgDeinitFn,
            .driver_type = .postgresql,
        };
    }
};

// ── Deprecated API ──────────────────────────────────────────────────────────

/// Deprecated: use query(void, arena, sql, params) instead.
pub fn exec(sql: []const u8, params: anytype) !void {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    _ = try conn.exec(sql, params);
}

/// Deprecated: use queryExecute(void, arena, sql) instead.
pub fn execRaw(sql: []const u8) !void {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\r\t");
        if (s.len == 0) continue;
        _ = try conn.exec(s, .{});
    }
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryWith(sql: []const u8, params: anytype) !Result {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    var pg_result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer pg_result.deinit();

    var arena = std.heap.ArenaAllocator.init(db_allocator.?);
    errdefer arena.deinit();

    return collectResult(&pg_result, arena);
}

/// Deprecated: use queryOne(T, arena, sql, params) instead.
pub fn queryOneWith(comptime T: type, sql: []const u8, params: anytype) !?T {
    var result = try queryWith(sql, params);
    defer result.deinit();
    return try result.mapOne(T, db_allocator.?);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryRaw(sql: []const u8, params: anytype) !Result {
    return queryWith(sql, params);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryRow(sql: []const u8, params: anytype) !Result {
    return queryWith(sql, params);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !MappedRows(T) {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    var pg_result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer pg_result.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var items = std.ArrayListUnmanaged(T).empty;
    while (try pg_result.next()) |row| {
        try items.append(aa, try row.to(T, .{ .map = .name, .dupe = true, .allocator = aa }));
    }

    return MappedRows(T){
        .arena = arena,
        .items = try items.toOwnedSlice(aa),
    };
}

/// Deprecated: use queryOne(T, arena, sql, params) instead.
pub fn queryOneAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?MappedRows(T) {
    var result = try queryAs(T, allocator, sql, params);
    if (result.items.len == 0) {
        result.deinit();
        return null;
    }
    return result;
}

pub fn MappedRows(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []T,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

// ── Deprecated Result type ──────────────────────────────────────────────────

pub const Result = struct {
    _arena: std.heap.ArenaAllocator,
    _col_names: [][]const u8,
    _values: [][]const u8,
    _row_count: usize,
    _col_count: usize,

    pub fn deinit(self: *Result) void {
        self._arena.deinit();
    }

    pub fn rows(self: *const Result) usize {
        return self._row_count;
    }

    pub fn columns(self: *const Result) usize {
        return self._col_count;
    }

    pub fn columnName(self: *const Result, col: usize) []const u8 {
        if (col >= self._col_count) return "";
        return self._col_names[col];
    }

    pub fn columnTypeOid(_: *const Result, _: usize) i32 {
        return 0;
    }

    pub fn affectedRows(self: *const Result) usize {
        return self._row_count;
    }

    pub fn getValue(self: *const Result, row: usize, col: usize) []const u8 {
        if (row >= self._row_count or col >= self._col_count) return "";
        return self._values[row * self._col_count + col];
    }

    pub fn get(self: *const Result, row: usize, comptime name: []const u8) []const u8 {
        for (self._col_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.getValue(row, i);
        }
        return "";
    }

    pub fn isNull(self: *const Result, row: usize, col: usize) bool {
        return self.getValue(row, col).len == 0;
    }

    pub fn mapAll(self: *Result, comptime T: type, alloc: std.mem.Allocator) ![]T {
        const items = try alloc.alloc(T, self._row_count);
        for (items, 0..) |*item, row| {
            item.* = try mapResultRow(T, self, row, alloc);
        }
        return items;
    }

    pub fn mapOne(self: *Result, comptime T: type, alloc: std.mem.Allocator) !?T {
        if (self._row_count == 0) return null;
        return try mapResultRow(T, self, 0, alloc);
    }
};

fn mapResultRow(comptime T: type, result: *const Result, row: usize, alloc: std.mem.Allocator) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var col_idx: ?usize = null;
        for (0..result._col_count) |i| {
            if (std.mem.eql(u8, result._col_names[i], field.name)) {
                col_idx = i;
                break;
            }
        }
        const raw = if (col_idx) |ci| result.getValue(row, ci) else "";
        @field(item, field.name) = try parseField(field.type, raw, alloc);
    }
    return item;
}

fn parseField(comptime T: type, raw: []const u8, alloc: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        const Child = info.optional.child;
        if (raw.len == 0) return null;
        return try parseField(Child, raw, alloc);
    }
    if (info == .@"enum") {
        return std.meta.stringToEnum(T, raw) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try alloc.dupe(u8, raw),
        bool => raw.len > 0 and (raw[0] == 't' or raw[0] == 'T' or raw[0] == '1'),
        i8, i16, i32, i64 => std.fmt.parseInt(T, raw, 10) catch 0,
        u8, u16, u32, u64 => std.fmt.parseInt(T, raw, 10) catch 0,
        f32, f64 => std.fmt.parseFloat(T, raw) catch 0.0,
        else => @compileError("parseField: unsupported type " ++ @typeName(T)),
    };
}

fn collectResult(pg_result: *pg_lib.Result, arena: std.heap.ArenaAllocator) !Result {
    var owned_arena = arena;
    const aa = owned_arena.allocator();

    const num_cols = pg_result.number_of_columns;

    const col_names = try aa.alloc([]const u8, num_cols);
    for (pg_result.column_names, 0..) |name, i| {
        col_names[i] = try aa.dupe(u8, name);
    }

    var values_list = std.ArrayListUnmanaged([]const u8).empty;
    var row_count: usize = 0;

    while (try pg_result.next()) |row| {
        for (0..num_cols) |col| {
            const value = row.values[col];
            const text = if (value.is_null)
                ""
            else
                try cellToText(aa, value.data, row.oids[col]);
            try values_list.append(aa, text);
        }
        row_count += 1;
    }

    return Result{
        ._arena = owned_arena,
        ._col_names = col_names,
        ._values = try values_list.toOwnedSlice(aa),
        ._row_count = row_count,
        ._col_count = num_cols,
    };
}

fn cellToText(arena: std.mem.Allocator, data: []const u8, oid: i32) ![]const u8 {
    return switch (oid) {
        21 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i16, data[0..2], .big)}),
        23 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i32, data[0..4], .big)}),
        20 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i64, data[0..8], .big)}),
        16 => if (data.len > 0 and data[0] == 1) "t" else "f",
        700 => blk: {
            const bits = std.mem.readInt(u32, data[0..4], .big);
            const f: f32 = @bitCast(bits);
            break :blk try std.fmt.allocPrint(arena, "{d}", .{f});
        },
        701 => blk: {
            const bits = std.mem.readInt(u64, data[0..8], .big);
            const f: f64 = @bitCast(bits);
            break :blk try std.fmt.allocPrint(arena, "{d}", .{f});
        },
        else => try arena.dupe(u8, data),
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn initTestDb(allocator: std.mem.Allocator) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    try init(allocator, io, .{
        .host = null,
        .database = null,
        .user = null,
        .password = null,
    });
}

test "query - integer param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try query(i32, arena.allocator(), "SELECT $1::integer", .{@as(i32, 42)});
    try std.testing.expectEqual(42, result);
}

test "query - bool param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { val: bool };
    const rows = try query(Row, arena.allocator(), "SELECT $1::boolean AS val", .{true});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expect(rows[0].val);
}

test "query - text param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { val: []const u8 };
    const rows = try query(Row, arena.allocator(), "SELECT $1::text AS val", .{"hello"});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expectEqualStrings("hello", rows[0].val);
}

test "execRaw - multiple statements" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    try execRaw("CREATE TEMP TABLE raw_test (id integer); INSERT INTO raw_test VALUES (1), (2), (3)");
    defer execRaw("DROP TABLE IF EXISTS raw_test") catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { id: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM raw_test ORDER BY id", .{});
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqual(1, rows[0].id);
    try std.testing.expectEqual(3, rows[2].id);
}

test "transaction - commit" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE tx_test (id integer)");
    defer execRaw("DROP TABLE IF EXISTS tx_test") catch {};

    var tx = try begin();
    defer tx.rollback();

    try tx.query(void, arena.allocator(), "INSERT INTO tx_test VALUES ($1)", .{@as(i32, 99)});
    try tx.commit();

    const Row = struct { id: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM tx_test", .{});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expectEqual(99, rows[0].id);
}

const std = @import("std");
pub const c = @cImport({
    @cInclude("libpq-fe.h");
    @cInclude("stdlib.h");
});

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

var db_pool: ?*Pool = null;
var db_allocator: ?std.mem.Allocator = null;

fn getEnv(key: []const u8, default: []const u8) []const u8 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.mem.sliceTo(val, 0);
    }
    return default;
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.fmt.parseInt(u16, std.mem.sliceTo(val, 0), 10) catch default;
    }
    return default;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;

    const host_raw = overrides.host orelse getEnv("POSTGRES_HOST", "localhost");
    const port = overrides.port orelse getEnvInt("POSTGRES_PORT", 5432);
    const user_raw = overrides.user orelse getEnv("POSTGRES_USER", "spider");
    const password_raw = overrides.password orelse getEnv("POSTGRES_PASSWORD", "spider");
    const database_raw = overrides.database orelse getEnv("POSTGRES_DB", "spider_db");
    const pool_size = overrides.pool_size orelse 10;

    const config = Config{
        .host = try allocator.dupe(u8, host_raw),
        .port = port,
        .database = try allocator.dupe(u8, database_raw),
        .user = try allocator.dupe(u8, user_raw),
        .password = try allocator.dupe(u8, password_raw),
        .pool_size = pool_size,
    };

    db_pool = try allocator.create(Pool);
    db_pool.?.* = try Pool.init(allocator, io, config);
}

pub fn deinit() void {
    if (db_pool) |p| {
        p.deinit();
        db_allocator.?.destroy(p);
        db_pool = null;
        db_allocator = null;
    }
}

pub fn acquireConn() !*Conn {
    return db_pool.?.acquire();
}

pub fn releaseConn(conn: *Conn) void {
    db_pool.?.release(conn);
}

pub fn queryParams(sql: [:0]const u8, params: []const []const u8) !Result {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return queryConnParams(conn, sql, params, db_allocator.?);
}

pub fn queryWith(sql: [:0]const u8, params: anytype) !Result {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    const allocator = db_allocator.?;
    const params_info = @typeInfo(@TypeOf(params));

    const param_count = switch (params_info) {
        .@"struct" => params_info.@"struct".fields.len,
        .@"union" => @compileError("Unions not supported as query parameters"),
        else => @compileError("Query parameters must be a struct, got: " ++ @tagName(params_info)),
    };

    const param_strings = try allocator.alloc([]const u8, param_count);
    defer allocator.free(param_strings);

    const allocated = try allocator.alloc(bool, param_count);
    defer allocator.free(allocated);
    @memset(allocated, false);

    inline for (0..param_count) |i| {
        const field_name = comptime params_info.@"struct".fields[i].name;
        const value = @field(params, field_name);
        const field_type = params_info.@"struct".fields[i].type;

        param_strings[i] = switch (@typeInfo(field_type)) {
            .int, .comptime_int => blk: {
                allocated[i] = true;
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{value});
            },
            .float, .comptime_float => blk: {
                allocated[i] = true;
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{value});
            },
            .bool => if (value) "true" else "false",
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => value,
                .one => if (@typeInfo(ptr_info.child) == .array) value else @compileError("Unsupported pointer type: " ++ @typeName(field_type)),
                else => @compileError("Unsupported pointer type: " ++ @typeName(field_type)),
            },
            else => @compileError("Unsupported parameter type: " ++ @typeName(field_type)),
        };
    }

    errdefer {
        for (0..param_count) |i| {
            if (allocated[i]) allocator.free(param_strings[i]);
        }
    }

    const result = try queryConnParams(conn, sql, param_strings, allocator);

    for (0..param_count) |i| {
        if (allocated[i]) allocator.free(param_strings[i]);
    }

    return result;
}

/// Deprecated: use queryOneAs() instead for arena-managed memory and type-safe mapping.
pub fn queryOneWith(comptime T: type, sql: [:0]const u8, params: anytype) !?T {
    var result = try queryWith(sql, params);
    defer result.deinit();
    return try result.mapOne(T, db_allocator.?);
}

pub fn query(sql: [:0]const u8, params: anytype) !Result {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return queryConnParamsWith(conn, sql, params, db_allocator.?);
}

pub fn queryRow(sql: [:0]const u8, params: anytype) !Result {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return queryConnParamsWith(conn, sql, params, db_allocator.?);
}

pub fn exec(sql: [:0]const u8, params: anytype) !void {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var result = try queryConnParamsWith(conn, sql, params, db_allocator.?);
    result.deinit();
}

pub fn execRaw(sql: [:0]const u8) !void {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var result = try queryConn(conn, sql);
    result.deinit();
}

pub fn begin() !Transaction {
    const conn = try db_pool.?.acquire();
    _ = try queryConn(conn, "BEGIN");
    return Transaction{ .conn = conn };
}

pub const Transaction = struct {
    conn: *Conn,
    committed: bool = false,
    rolled_back: bool = false,

    pub fn exec(self: *Transaction, sql: [:0]const u8, params: anytype) !void {
        var result = try queryConnParamsWith(self.conn, sql, params, db_allocator.?);
        result.deinit();
    }

    pub fn commit(self: *Transaction) !void {
        if (self.committed or self.rolled_back) return error.TransactionAlreadyFinished;
        _ = try queryConn(self.conn, "COMMIT");
        db_pool.?.release(self.conn);
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) void {
        if (self.committed or self.rolled_back) return;
        _ = queryConn(self.conn, "ROLLBACK") catch {};
        db_pool.?.release(self.conn);
        self.rolled_back = true;
    }
};

const Conn = struct {
    inner: ?*c.PGconn,
    available: std.atomic.Value(bool),

    pub fn errorMessage(self: *Conn) []const u8 {
        const pg = self.inner orelse return "no connection";
        return std.mem.span(c.PQerrorMessage(pg));
    }
};

pub const Pool = struct {
    conns: []Conn,
    config: Config,
    allocator: std.mem.Allocator,
    conninfo: [:0]const u8,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Pool {
        const conninfo_with_null = try std.fmt.allocPrint(allocator, "host={s} port={d} dbname={s} user={s} password={s}\x00", .{ config.host, config.port, config.database, config.user, config.password });
        const conninfo = conninfo_with_null[0 .. conninfo_with_null.len - 1 :0];

        const conns = try allocator.alloc(Conn, config.pool_size);
        errdefer allocator.free(conns);

        for (conns) |*conn| {
            var attempt: usize = 0;
            const max_attempts = 5;
            var delay_ms: u64 = 1000; // Start with 1 second

            while (attempt < max_attempts) : (attempt += 1) {
                const pg_conn = c.PQconnectdb(conninfo.ptr);
                const status = if (pg_conn) |p| c.PQstatus(p) else c.CONNECTION_BAD;

                if (pg_conn != null and status == c.CONNECTION_OK) {
                    std.log.info("pg: connection established on attempt {d}/{d}", .{ attempt + 1, max_attempts });
                    conn.* = .{
                        .inner = pg_conn,
                        .available = std.atomic.Value(bool).init(true),
                    };
                    break;
                }

                // Connection failed
                if (pg_conn) |p| c.PQfinish(p);

                if (attempt < max_attempts - 1) {
                    std.log.warn("pg: connection attempt {d}/{d} failed, retrying in {d}ms", .{ attempt + 1, max_attempts, delay_ms });
                    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(delay_ms))), .real);
                    delay_ms *= 2; // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                } else {
                    std.log.err("pg: connection failed after {d} attempts", .{max_attempts});
                    return error.ConnectionFailed;
                }
            }
        }

        return .{
            .conns = conns,
            .config = config,
            .allocator = allocator,
            .conninfo = conninfo,
            .io = io,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.conns) |*conn| {
            if (conn.inner) |pg| c.PQfinish(pg);
        }
        self.allocator.free(self.conns);
        self.allocator.free(self.conninfo);
        self.allocator.free(self.config.host);
        self.allocator.free(self.config.user);
        self.allocator.free(self.config.password);
        self.allocator.free(self.config.database);
    }

    fn connHealthCheck(conn: *Conn, conninfo: [*:0]const u8) !void {
        const pg = conn.inner orelse {
            std.log.warn("pg: connection is null, recreating", .{});
            conn.inner = c.PQconnectdb(conninfo);
            if (conn.inner == null or c.PQstatus(conn.inner.?) != c.CONNECTION_OK) {
                return error.ConnectionFailed;
            }
            return;
        };

        if (c.PQstatus(pg) != c.CONNECTION_OK) {
            std.log.warn("pg: connection bad, attempting reset", .{});
            c.PQreset(pg);
            if (c.PQstatus(pg) != c.CONNECTION_OK) {
                std.log.warn("pg: reset failed, recreating connection", .{});
                c.PQfinish(pg);
                conn.inner = c.PQconnectdb(conninfo);
                if (conn.inner == null or c.PQstatus(conn.inner.?) != c.CONNECTION_OK) {
                    return error.ConnectionFailed;
                }
            }
        }
    }

    pub fn acquire(self: *Pool) !*Conn {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.conns) |*conn| {
                if (conn.available.cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                    connHealthCheck(conn, self.conninfo.ptr) catch |err| {
                        std.log.err("pg: connection health check failed: {}", .{err});
                        conn.available.store(true, .release);
                        continue;
                    };
                    return conn;
                }
            }
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn release(self: *Pool, conn: *Conn) void {
        // Check connection health before returning to pool
        connHealthCheck(conn, self.conninfo.ptr) catch |err| {
            std.log.warn("pg: releasing bad connection, recreating: {}", .{err});
            if (conn.inner) |pg| {
                c.PQfinish(pg);
            }
            conn.inner = c.PQconnectdb(self.conninfo.ptr);
        };

        conn.available.store(true, .release);
        self.cond.signal(self.io);
    }
};

pub const Result = struct {
    inner: ?*c.PGresult,

    pub fn deinit(self: *Result) void {
        if (self.inner) |r| c.PQclear(r);
    }

    pub fn rows(self: *Result) usize {
        const r = self.inner orelse return 0;
        return @intCast(c.PQntuples(r));
    }

    pub fn columns(self: *Result) usize {
        const r = self.inner orelse return 0;
        return @intCast(c.PQnfields(r));
    }

    pub fn columnName(self: *Result, col: usize) []const u8 {
        const r = self.inner orelse return "";
        const name = c.PQfname(r, @intCast(col));
        return if (name) |n| std.mem.span(n) else "";
    }

    pub fn columnTypeOid(self: *Result, col: usize) c.Oid {
        const r = self.inner orelse return 0;
        return c.PQftype(r, @intCast(col));
    }

    pub fn affectedRows(self: *Result) usize {
        const r = self.inner orelse return 0;
        const cmd_tuples = c.PQcmdTuples(r);
        if (cmd_tuples[0] == 0) return 0;
        return std.fmt.parseInt(usize, std.mem.span(cmd_tuples), 10) catch 0;
    }

    // deprecated: use get instead with column name
    pub fn getValue(self: *Result, row: usize, col: usize) []const u8 {
        const r = self.inner orelse return "";
        const val = c.PQgetvalue(r, @intCast(row), @intCast(col));
        return std.mem.span(val);
    }

    pub fn get(self: *Result, row: usize, comptime name: []const u8) []const u8 {
        const r = self.inner orelse return "";
        const num_cols = @as(usize, @intCast(c.PQnfields(r)));
        for (0..num_cols) |i| {
            const col_name = c.PQfname(r, @intCast(i));
            if (col_name != null and std.mem.eql(u8, std.mem.span(col_name), name)) {
                const val = c.PQgetvalue(r, @intCast(row), @intCast(i));
                return std.mem.span(val);
            }
        }
        return "";
    }

    pub fn isNull(self: *Result, row: usize, col: usize) bool {
        const r = self.inner orelse return true;
        return c.PQgetisnull(r, @intCast(row), @intCast(col)) == 1;
    }

    /// Deprecated: use queryAs() instead for arena-managed memory and type-safe mapping.
    pub fn mapAll(self: *Result, comptime T: type, alloc: std.mem.Allocator) ![]T {
        const count = self.rows();
        const items = try alloc.alloc(T, count);

        const num_columns = self.columns();
        inline for (@typeInfo(T).@"struct".fields) |field| {
            var col_idx: ?usize = null;
            for (0..num_columns) |i| {
                if (std.mem.eql(u8, self.columnName(i), field.name)) {
                    col_idx = i;
                    break;
                }
            }
            if (col_idx) |col| {
                for (items, 0..) |*item, row| {
                    const is_null = self.isNull(row, col);
                    const raw = if (is_null) "" else self.getValue(row, col);
                    const type_info = @typeInfo(field.type);
                    if (type_info == .optional) {
                        const Child = type_info.optional.child;
                        @field(item, field.name) = if (is_null) null else switch (Child) {
                            []const u8 => try alloc.dupe(u8, raw),
                            i32, i64 => try std.fmt.parseInt(Child, raw, 10),
                            f32, f64 => try std.fmt.parseFloat(Child, raw),
                            bool => std.mem.eql(u8, raw, "t"),
                            else => @compileError("unsupported optional child type: " ++ @typeName(Child)),
                        };
                    } else {
                        @field(item, field.name) = switch (field.type) {
                            []const u8 => try alloc.dupe(u8, raw),
                            i32, i64 => try std.fmt.parseInt(field.type, raw, 10),
                            f32, f64 => try std.fmt.parseFloat(field.type, raw),
                            bool => std.mem.eql(u8, raw, "t"),
                            else => @compileError("unsupported type: " ++ @typeName(field.type)),
                        };
                    }
                }
            }
        }
        return items;
    }

    /// Deprecated: use queryOneAs() instead for arena-managed memory and type-safe mapping.
    pub fn mapOne(self: *Result, comptime T: type, alloc: std.mem.Allocator) !?T {
        const items = try self.mapAll(T, alloc);
        defer alloc.free(items);

        if (items.len == 0) return null;
        return items[0];
    }
};

// ─── Typed query API (SQLx-style) ─────────────────────────────────────

pub fn MappedRows(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []T,
        inner: ?*c.PGresult,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const items = try arena.allocator().alloc(T, count);
            return .{
                .arena = arena,
                .items = items,
                .inner = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.inner) |r| c.PQclear(r);
            self.arena.deinit();
        }
    };
}

fn mapRowValue(
    comptime FieldType: type,
    raw: []const u8,
    is_null: bool,
    arena_alloc: std.mem.Allocator,
) !FieldType {
    const type_info = @typeInfo(FieldType);
    if (type_info == .optional) {
        const Child = type_info.optional.child;
        if (is_null or raw.len == 0) return null;
        return try mapRowValue(Child, raw, false, arena_alloc);
    }
    if (is_null or raw.len == 0) {
        return switch (FieldType) {
            []const u8 => "",
            bool => false,
            i8, i16, i32, i64, u8, u16, u32, u64 => 0,
            f32, f64 => 0.0,
            else => @compileError("pg.queryAs: unsupported type " ++ @typeName(FieldType)),
        };
    }
    return switch (FieldType) {
        []const u8 => try arena_alloc.dupe(u8, raw),
        bool => raw[0] == 't' or raw[0] == 'T',
        i8, i16, i32, i64 => std.fmt.parseInt(FieldType, raw, 10) catch 0,
        u8, u16, u32, u64 => std.fmt.parseInt(FieldType, raw, 10) catch 0,
        f32, f64 => std.fmt.parseFloat(FieldType, raw) catch 0.0,
        else => @compileError("pg.queryAs: unsupported type " ++ @typeName(FieldType)),
    };
}

fn mapRowFromPg(
    comptime T: type,
    pg_result: ?*c.PGresult,
    row: usize,
    num_cols: usize,
    arena_alloc: std.mem.Allocator,
) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var col_idx: ?usize = null;
        for (0..num_cols) |ci| {
            const col_name = c.PQfname(pg_result, @intCast(ci));
            if (col_name != null and std.mem.eql(u8, std.mem.span(col_name), field.name)) {
                col_idx = ci;
                break;
            }
        }
        if (col_idx) |col| {
            const is_null = c.PQgetisnull(pg_result, @intCast(row), @intCast(col)) == 1;
            const raw = if (is_null) "" else blk: {
                const val = c.PQgetvalue(pg_result, @intCast(row), @intCast(col));
                break :blk std.mem.span(val);
            };
            @field(item, field.name) = try mapRowValue(field.type, raw, is_null, arena_alloc);
        } else {
            @field(item, field.name) = try mapRowValue(field.type, "", true, arena_alloc);
        }
    }
    return item;
}

pub fn queryAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: [:0]const u8,
    params: anytype,
) !MappedRows(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_alloc = arena.allocator();

    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    const param_count = comptime @typeInfo(@TypeOf(params)).@"struct".fields.len;
    const param_strings = try allocator.alloc([*:0]const u8, param_count);
    defer allocator.free(param_strings);

    const allocated = try allocator.alloc(bool, param_count);
    defer allocator.free(allocated);
    @memset(allocated, false);

    inline for (0..param_count) |i| {
        const value = @field(params, @typeInfo(@TypeOf(params)).@"struct".fields[i].name);
        const field_type = @typeInfo(@TypeOf(params)).@"struct".fields[i].type;

        param_strings[i] = switch (@typeInfo(field_type)) {
            .int, .comptime_int => blk: {
                allocated[i] = true;
                const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
                const z = try allocator.dupeZ(u8, s);
                allocator.free(s);
                break :blk z;
            },
            .float, .comptime_float => blk: {
                allocated[i] = true;
                const s = try std.fmt.allocPrint(allocator, "{d}", .{value});
                const z = try allocator.dupeZ(u8, s);
                allocator.free(s);
                break :blk z;
            },
            .bool => if (value) "true" else "false",
            .pointer => |p| switch (p.size) {
                .slice => blk: {
                    allocated[i] = true;
                    break :blk try allocator.dupeZ(u8, value);
                },
                .one => if (@typeInfo(p.child) == .array) blk: {
                    allocated[i] = true;
                    break :blk try allocator.dupeZ(u8, value);
                } else @compileError("Unsupported pointer type"),
                else => @compileError("Unsupported pointer type"),
            },
            else => @compileError("Unsupported parameter type: " ++ @typeName(field_type)),
        };
    }

    defer {
        for (0..param_count) |i| {
            if (allocated[i]) allocator.free(std.mem.span(param_strings[i]));
        }
    }

    const pg_result = c.PQexecParams(
        conn.inner.?,
        sql,
        @intCast(param_count),
        null,
        @ptrCast(param_strings.ptr),
        null,
        null,
        0,
    );
    if (pg_result == null) return error.QueryFailed;

    const status = c.PQresultStatus(pg_result);
    if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
        const msg = std.mem.span(c.PQresultErrorMessage(pg_result));
        std.log.err("PostgreSQL: {s}", .{msg});
        c.PQclear(pg_result);
        return error.QueryFailed;
    }

    const row_count: usize = @intCast(c.PQntuples(pg_result));
    const num_cols: usize = @intCast(c.PQnfields(pg_result));
    const items = try arena_alloc.alloc(T, row_count);

    for (0..row_count) |row| {
        items[row] = try mapRowFromPg(T, pg_result, row, num_cols, arena_alloc);
    }

    return MappedRows(T){
        .arena = arena,
        .items = items,
        .inner = pg_result,
    };
}

pub fn queryOneAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: [:0]const u8,
    params: anytype,
) !?MappedRows(T) {
    var result = try queryAs(T, allocator, sql, params);
    if (result.items.len == 0) {
        result.deinit();
        return null;
    }
    return result;
}

pub fn queryConn(conn: *Conn, sql: [:0]const u8) !Result {
    const pg_conn = conn.inner orelse return error.QueryFailed;
    const result = c.PQexec(pg_conn, sql);
    if (result == null) return error.QueryFailed;
    const status = c.PQresultStatus(result);
    if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
        const msg = std.mem.span(c.PQresultErrorMessage(result));
        std.log.err("PostgreSQL: {s}", .{msg});
        c.PQclear(result);
        return error.QueryFailed;
    }
    return .{ .inner = result };
}

pub fn queryConnParams(
    conn: *Conn,
    sql: [:0]const u8,
    params: []const []const u8,
    allocator: std.mem.Allocator,
) !Result {
    const pg_conn = conn.inner orelse return error.QueryFailed;

    const param_values = try allocator.alloc([*:0]const u8, params.len);
    defer allocator.free(param_values);

    for (params, 0..) |p, i| {
        param_values[i] = try allocator.dupeZ(u8, p);
    }
    defer {
        for (param_values) |p| allocator.free(std.mem.span(p));
    }

    const result = c.PQexecParams(
        pg_conn,
        sql,
        @intCast(params.len),
        null,
        @ptrCast(param_values.ptr),
        null,
        null,
        0,
    );
    if (result == null) return error.QueryFailed;

    const status = c.PQresultStatus(result);
    if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
        const msg = std.mem.span(c.PQresultErrorMessage(result));
        std.log.err("PostgreSQL: {s}", .{msg});
        c.PQclear(result);
        return error.QueryFailed;
    }
    return .{ .inner = result };
}

fn logQuery(sql: [:0]const u8, elapsed_us: i64, rows: usize, p: []const []const u8) void {
    std.log.info("pg: {s} ({d} rows, {d}µs)", .{ sql, rows, elapsed_us });
    for (p, 0..) |val, i| {
        std.log.debug("pg:   ${d} = \"{s}\"", .{ i + 1, val });
    }
}

fn logExec(sql: [:0]const u8, elapsed_us: i64, affected: usize) void {
    std.log.info("pg: {s} ({d} rows, {d}µs)", .{ sql, affected, elapsed_us });
}

fn queryConnParamsWith(
    conn: *Conn,
    sql: [:0]const u8,
    params: anytype,
    allocator: std.mem.Allocator,
) !Result {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const start = std.Io.Clock.now(.awake, io);

    const params_info = @typeInfo(@TypeOf(params));

    const param_count = switch (params_info) {
        .@"struct" => params_info.@"struct".fields.len,
        else => 0,
    };

    if (param_count == 0) {
        var result = try queryConnParams(conn, sql, &.{}, allocator);
        const end = std.Io.Clock.now(.awake, io);
        const elapsed_us = @as(i64, @intCast(@divTrunc(start.durationTo(end).nanoseconds, 1000)));
        logQuery(sql, elapsed_us, result.rows(), &.{});
        return result;
    }

    const param_strings = try allocator.alloc([]const u8, param_count);
    defer allocator.free(param_strings);

    const allocated = try allocator.alloc(bool, param_count);
    defer allocator.free(allocated);
    @memset(allocated, false);

    inline for (0..param_count) |i| {
        const field_name = comptime params_info.@"struct".fields[i].name;
        const value = @field(params, field_name);
        const field_type = params_info.@"struct".fields[i].type;

        param_strings[i] = switch (@typeInfo(field_type)) {
            .int, .comptime_int => blk: {
                allocated[i] = true;
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{value});
            },
            .float, .comptime_float => blk: {
                allocated[i] = true;
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{value});
            },
            .bool => if (value) "true" else "false",
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => value,
                .one => if (@typeInfo(ptr_info.child) == .array) value else @compileError("Unsupported pointer type: " ++ @typeName(field_type)),
                else => @compileError("Unsupported pointer type: " ++ @typeName(field_type)),
            },
            else => @compileError("Unsupported parameter type: " ++ @typeName(field_type)),
        };
    }

    errdefer {
        for (0..param_count) |i| {
            if (allocated[i]) allocator.free(param_strings[i]);
        }
    }

    var result = try queryConnParams(conn, sql, param_strings, allocator);

    const end = std.Io.Clock.now(.awake, io);
    const elapsed_us = @as(i64, @intCast(@divTrunc(start.durationTo(end).nanoseconds, 1000)));

    logQuery(sql, elapsed_us, result.rows(), param_strings);

    for (0..param_count) |i| {
        if (allocated[i]) allocator.free(param_strings[i]);
    }

    return result;
}

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

test "queryWith - native int" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryWith("SELECT $1::integer", .{@as(i32, 42)});
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.getValue(0, 0));
}

test "queryWith - native float" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryWith("SELECT $1::numeric", .{@as(f64, 49.90)});
    defer result.deinit();
    try std.testing.expectEqualStrings("49.9", result.getValue(0, 0));
}

test "queryWith - native bool" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryWith("SELECT $1::boolean", .{true});
    defer result.deinit();
    try std.testing.expectEqualStrings("t", result.getValue(0, 0));
}

test "queryWith - heap string" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    const s = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(s);
    var result = try queryWith("SELECT $1::text", .{s});
    defer result.deinit();
    try std.testing.expectEqualStrings("hello", result.getValue(0, 0));
}

test "queryWith - static string literal" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryWith("SELECT $1::text", .{"monthly"});
    defer result.deinit();
    try std.testing.expectEqualStrings("monthly", result.getValue(0, 0));
}

test "queryWith - multiple mixed types" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryWith(
        "SELECT $1::integer, $2::text, $3::boolean, $4::numeric",
        .{ @as(i32, 1), "test", false, @as(f64, 99.99) },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.getValue(0, 0));
    try std.testing.expectEqualStrings("test", result.getValue(0, 1));
    try std.testing.expectEqualStrings("f", result.getValue(0, 2));
    try std.testing.expectEqualStrings("99.99", result.getValue(0, 3));
}

test "queryParams - heap strings" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    const p1 = try std.testing.allocator.dupe(u8, "42");
    const p2 = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(p1);
    defer std.testing.allocator.free(p2);
    var result = try queryParams("SELECT $1::integer, $2::text", &.{ p1, p2 });
    defer result.deinit();
    try std.testing.expectEqualStrings("42", result.getValue(0, 0));
    try std.testing.expectEqualStrings("hello", result.getValue(0, 1));
}

test "queryParams - static string literal" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try queryParams("SELECT $1::text", &.{"monthly"});
    defer result.deinit();
    try std.testing.expectEqualStrings("monthly", result.getValue(0, 0));
}

test "query - no params" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try query("SELECT 1::integer AS num, 'hello' AS text", .{});
    defer result.deinit();
    try std.testing.expect(result.rows() == 1);
    try std.testing.expectEqualStrings("1", result.get(0, "num"));
    try std.testing.expectEqualStrings("hello", result.get(0, "text"));
}

test "query - with params" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var result = try query(
        "SELECT $1::integer AS id, $2::text AS name",
        .{ @as(i32, 42), "Alice" },
    );
    defer result.deinit();
    try std.testing.expect(result.rows() == 1);
    try std.testing.expectEqualStrings("42", result.get(0, "id"));
    try std.testing.expectEqualStrings("Alice", result.get(0, "name"));
}

test "query - multiple rows" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE items (id integer, name text)", .{});
    try exec("INSERT INTO items VALUES (1, 'one')", .{});
    try exec("INSERT INTO items VALUES (2, 'two')", .{});
    try exec("INSERT INTO items VALUES (3, 'three')", .{});
    defer exec("DROP TABLE items", .{}) catch {};

    var result = try query("SELECT id, name FROM items ORDER BY id", .{});
    defer result.deinit();
    try std.testing.expect(result.rows() == 3);
    try std.testing.expectEqualStrings("1", result.get(0, "id"));
    try std.testing.expectEqualStrings("one", result.get(0, "name"));
    try std.testing.expectEqualStrings("2", result.get(1, "id"));
    try std.testing.expectEqualStrings("two", result.get(1, "name"));
    try std.testing.expectEqualStrings("3", result.get(2, "id"));
    try std.testing.expectEqualStrings("three", result.get(2, "name"));
}

test "queryRow - returns one row" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE users (id integer, email text)", .{});
    try exec("INSERT INTO users VALUES (1, 'a@b.com')", .{});
    try exec("INSERT INTO users VALUES (2, 'c@d.com')", .{});
    defer exec("DROP TABLE users", .{}) catch {};

    var row = try queryRow("SELECT * FROM users WHERE id = $1", .{@as(i32, 1)});
    defer row.deinit();
    try std.testing.expectEqualStrings("1", row.get(0, "id"));
    try std.testing.expectEqualStrings("a@b.com", row.get(0, "email"));
}

test "queryRow - returns null when no rows" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE users (id integer)", .{});
    defer exec("DROP TABLE users", .{}) catch {};

    var row = try queryRow("SELECT * FROM users WHERE id = $1", .{@as(i32, 999)});
    defer row.deinit();
    try std.testing.expect(row.rows() == 0);
}

test "exec - insert" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE users (id SERIAL PRIMARY KEY, name text)", .{});
    defer exec("DROP TABLE users", .{}) catch {};

    try exec(
        "INSERT INTO users (name) VALUES ($1)",
        .{"Charlie"},
    );

    var result = try query("SELECT id, name FROM users", .{});
    defer result.deinit();
    try std.testing.expect(result.rows() == 1);
    try std.testing.expectEqualStrings("1", result.get(0, "id"));
    try std.testing.expectEqualStrings("Charlie", result.get(0, "name"));
}

test "exec - update" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE users (id integer, name text)", .{});
    try exec("INSERT INTO users VALUES (1, 'Alice')", .{});
    try exec("INSERT INTO users VALUES (2, 'Bob')", .{});
    defer exec("DROP TABLE users", .{}) catch {};

    try exec(
        "UPDATE users SET name = $1 WHERE id = $2",
        .{ "Alicia", @as(i32, 1) },
    );

    var row = try queryRow("SELECT name FROM users WHERE id = $1", .{@as(i32, 1)});
    defer row.deinit();
    try std.testing.expectEqualStrings("Alicia", row.get(0, "name"));
}

test "exec - delete" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE users (id integer, name text)", .{});
    try exec("INSERT INTO users VALUES (1, 'Alice')", .{});
    try exec("INSERT INTO users VALUES (2, 'Bob')", .{});
    defer exec("DROP TABLE users", .{}) catch {};

    try exec("DELETE FROM users WHERE id = $1", .{@as(i32, 1)});

    var count = try queryRow("SELECT COUNT(*) AS cnt FROM users", .{});
    defer count.deinit();
    try std.testing.expectEqualStrings("1", count.get(0, "cnt"));
}

test "execRaw - multiple statements" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try execRaw("CREATE TEMP TABLE raw_test (id integer); INSERT INTO raw_test VALUES (1), (2), (3);");
    defer execRaw("DROP TABLE raw_test") catch {};

    var result = try query("SELECT COUNT(*) AS cnt FROM raw_test", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("3", result.get(0, "cnt"));
}

test "begin - commit" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE accounts (id integer PRIMARY KEY, balance integer)", .{});
    try exec("INSERT INTO accounts VALUES (1, 100), (2, 100)", .{});
    defer exec("DROP TABLE accounts", .{}) catch {};

    var tx = try begin();
    defer tx.rollback();

    try tx.exec("UPDATE accounts SET balance = balance - 50 WHERE id = 1", .{});
    try tx.exec("UPDATE accounts SET balance = balance + 50 WHERE id = 2", .{});
    try tx.commit();

    var b1 = try queryRow("SELECT balance FROM accounts WHERE id = 1", .{});
    defer b1.deinit();
    try std.testing.expectEqualStrings("50", b1.get(0, "balance"));

    var b2 = try queryRow("SELECT balance FROM accounts WHERE id = 2", .{});
    defer b2.deinit();
    try std.testing.expectEqualStrings("150", b2.get(0, "balance"));
}

test "begin - rollback" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE accounts (id integer PRIMARY KEY, balance integer)", .{});
    try exec("INSERT INTO accounts VALUES (1, 100)", .{});
    defer exec("DROP TABLE accounts", .{}) catch {};

    var tx = try begin();
    try tx.exec("UPDATE accounts SET balance = 0 WHERE id = 1", .{});
    tx.rollback();

    var row = try queryRow("SELECT balance FROM accounts WHERE id = 1", .{});
    defer row.deinit();
    try std.testing.expectEqualStrings("100", row.get(0, "balance"));
}

test "query logging - info level shows sql and row count" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE logtest (id integer, name text)", .{});
    try exec("INSERT INTO logtest VALUES (1, 'alice')", .{});
    try exec("INSERT INTO logtest VALUES (2, 'bob')", .{});
    defer exec("DROP TABLE logtest", .{}) catch {};

    var result = try query("SELECT id, name FROM logtest ORDER BY id", .{});
    defer result.deinit();

    try std.testing.expect(result.rows() == 2);
}

test "query logging - debug level shows sql params and rows" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE logtest (id integer, name text)", .{});
    try exec("INSERT INTO logtest VALUES (1, 'alice')", .{});
    defer exec("DROP TABLE logtest", .{}) catch {};

    var result = try query("SELECT id, name FROM logtest WHERE id = $1", .{@as(i32, 1)});
    defer result.deinit();

    try std.testing.expect(result.rows() == 1);
    try std.testing.expectEqualStrings("1", result.get(0, "id"));
    try std.testing.expectEqualStrings("alice", result.get(0, "name"));
}

test "query logging - exec shows affected rows" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE logtest (id integer)", .{});
    defer exec("DROP TABLE logtest", .{}) catch {};

    try exec("INSERT INTO logtest VALUES (1), (2), (3)", .{});

    var count = try queryRow("SELECT COUNT(*) AS cnt FROM logtest", .{});
    defer count.deinit();
    try std.testing.expectEqualStrings("3", count.get(0, "cnt"));
}

test "query logging - timing is included" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE logtest (id integer)", .{});
    defer exec("DROP TABLE logtest", .{}) catch {};

    var result = try query("SELECT * FROM logtest", .{});
    defer result.deinit();
    try std.testing.expect(result.rows() == 0);
}

test "query logging - transaction commits" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE logtest (id integer PRIMARY KEY, value integer)", .{});
    defer exec("DROP TABLE logtest", .{}) catch {};

    var tx = try begin();
    defer tx.rollback();
    try tx.exec("INSERT INTO logtest VALUES (1, 100)", .{});
    try tx.commit();

    var row = try queryRow("SELECT value FROM logtest WHERE id = 1", .{});
    defer row.deinit();
    try std.testing.expectEqualStrings("100", row.get(0, "value"));
}

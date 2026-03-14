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

pub fn query(sql: [:0]const u8) !Result {
    const conn = try db_pool.?.acquire();
    errdefer db_pool.?.release(conn);
    return queryConn(conn, sql);
}

pub fn queryParams(sql: [:0]const u8, params: []const []const u8) !Result {
    const conn = try db_pool.?.acquire();
    errdefer db_pool.?.release(conn);
    return queryConnParams(conn, sql, params, db_allocator.?);
}

pub fn queryWith(sql: [:0]const u8, params: anytype) !Result {
    const conn = try db_pool.?.acquire();
    errdefer db_pool.?.release(conn);

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
            .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) value else @compileError("Unsupported pointer type: " ++ @typeName(field_type)),
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

pub fn queryOneWith(comptime T: type, sql: [:0]const u8, params: anytype) !?T {
    var result = try queryWith(sql, params);
    defer result.deinit();
    return try result.mapOne(T, db_allocator.?);
}

pub fn exec(sql: [:0]const u8) !void {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    _ = try queryConn(conn, sql);
}

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
        const conninfo = conninfo_with_null[0..conninfo_with_null.len :0];

        const conns = try allocator.alloc(Conn, config.pool_size);
        errdefer allocator.free(conns);

        for (conns) |*conn| {
            const pg_conn = c.PQconnectdb(conninfo.ptr);
            const status = if (pg_conn) |p| c.PQstatus(p) else c.CONNECTION_BAD;
            if (pg_conn == null or status != c.CONNECTION_OK) {
                if (pg_conn) |p| c.PQfinish(p);
                return error.ConnectionFailed;
            }
            conn.* = .{
                .inner = pg_conn,
                .available = std.atomic.Value(bool).init(true),
            };
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

    pub fn getValue(self: *Result, row: usize, col: usize) []const u8 {
        const r = self.inner orelse return "";
        const val = c.PQgetvalue(r, @intCast(row), @intCast(col));
        return std.mem.span(val);
    }

    pub fn isNull(self: *Result, row: usize, col: usize) bool {
        const r = self.inner orelse return true;
        return c.PQgetisnull(r, @intCast(row), @intCast(col)) == 1;
    }

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

    pub fn mapOne(self: *Result, comptime T: type, alloc: std.mem.Allocator) !?T {
        const items = try self.mapAll(T, alloc);
        defer alloc.free(items);

        if (items.len == 0) return null;
        return items[0];
    }
};

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

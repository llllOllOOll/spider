const std = @import("std");
pub const c = @cImport({
    @cInclude("libpq-fe.h");
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
    conninfo: []u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pool {
        const conninfo = try std.fmt.allocPrint(allocator, "host={s} port={d} dbname={s} user={s} password={s}\x00", .{ config.host, config.port, config.database, config.user, config.password });

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

    pub fn acquire(self: *Pool) !*Conn {
        while (true) {
            for (self.conns) |*conn| {
                if (conn.available.cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                    if (conn.inner) |pg| {
                        if (c.PQstatus(pg) != c.CONNECTION_OK) {
                            c.PQreset(pg);
                        }
                    }
                    return conn;
                }
            }
            // spin
        }
    }

    pub fn release(self: *Pool, conn: *Conn) void {
        _ = self;
        conn.available.store(true, .release);
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
};

pub fn query(conn: *Conn, sql: [:0]const u8) !Result {
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

pub fn queryParams(
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

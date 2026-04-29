const std = @import("std");
const connection = @import("./connection.zig");
const types = @import("./types.zig");
const env = @import("../../internal/env.zig");

pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8,
    user: []const u8,
    password: []const u8 = "",
    pool_size: usize = 10,
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
var db_io: ?std.Io = null;
var db_allocator: ?std.mem.Allocator = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;
    db_io = io;

    const host = overrides.host orelse env.getOr("MYSQL_HOST", "localhost");
    const port = overrides.port orelse env.getInt(u16, "MYSQL_PORT", 3306);
    const user = overrides.user orelse env.getOr("MYSQL_USER", "root");
    const password = overrides.password orelse env.getOr("MYSQL_PASSWORD", "");
    const database = overrides.database orelse env.getOr("MYSQL_DB", "");
    const pool_size = overrides.pool_size orelse 10;

    const config = Config{
        .host = try allocator.dupe(u8, host),
        .port = port,
        .database = try allocator.dupe(u8, database),
        .user = try allocator.dupe(u8, user),
        .password = try allocator.dupe(u8, password),
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
        db_io = null;
        db_allocator = null;
    }
}

pub fn query(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) ![]T {
    _ = params;

    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    const result = try conn.queryRows(arena, sql);

    var items: std.ArrayList(T) = .empty;
    for (result.rows) |row| {
        const item = try types.mapRowToStruct(T, row, result.field_names, arena);
        try items.append(arena, item);
    }
    return items.toOwnedSlice(arena);
}

const Conn = connection.Connection;

pub const Pool = struct {
    conns: std.ArrayList(*Conn),
    config: Config,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Pool {
        var conns: std.ArrayList(*Conn) = .empty;

        for (0..config.pool_size) |_| {
            const conn = try allocator.create(Conn);
            conn.* = try Conn.init(allocator, io, .{
                .host = config.host,
                .port = config.port,
                .database = config.database,
                .user = config.user,
                .password = config.password,
            });
            try conns.append(allocator, conn);
        }

        return .{
            .conns = conns,
            .config = config,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.conns.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.conns.deinit(self.allocator);
    }

    pub fn acquire(self: *Pool) !*Conn {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var attempts: usize = 0;
        while (self.conns.items.len == 0) {
            if (attempts >= 100) return error.PoolTimeout;
            try self.cond.wait(self.io, &self.mutex);
            attempts += 1;
        }
        return self.conns.pop() orelse error.NoConnectionsAvailable;
    }

    pub fn release(self: *Pool, conn: *Conn) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.conns.append(self.allocator, conn) catch {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        };
        self.cond.signal(self.io);
    }
};

pub const MySqlDriver = struct {
    pool: *Pool,

    pub fn database(self: *MySqlDriver) Database {
        return .{
            .ptr = self,
            .exec_fn = execFn,
            .deinit_fn = deinitFn,
            .driver_type = .mysql,
        };
    }

    fn execFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
        const self: *MySqlDriver = @ptrCast(@alignCast(ptr));
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);
        try conn.query(sql);
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *MySqlDriver = @ptrCast(@alignCast(ptr));
        self.pool.deinit();
    }
};

const Database = @import("../../core/database.zig").Database;

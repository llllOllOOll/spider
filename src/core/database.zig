const std = @import("std");

pub const Database = struct {
    ptr: *anyopaque,
    exec_fn: *const fn (ptr: *anyopaque, sql: []const u8) anyerror!void,
    deinit_fn: *const fn (ptr: *anyopaque) void,
    driver_type: DriverType,

    pub fn exec(self: Database, sql: []const u8) !void {
        return self.exec_fn(self.ptr, sql);
    }

    pub fn deinit(self: Database) void {
        self.deinit_fn(self.ptr);
    }
};

pub const DriverType = enum { postgresql, sqlite, mysql };

pub const DatabaseCtx = struct {
    _db: *const Database,
    _arena: std.mem.Allocator,
    _driver_type: DriverType,

    pub fn exec(self: DatabaseCtx, sql: []const u8) !void {
        return self._db.exec(sql);
    }

    pub fn query(self: DatabaseCtx, comptime T: type, sql: []const u8, params: anytype) ![]T {
        return switch (self._driver_type) {
            .postgresql => {
                const pg = @import("../drivers/pg/pg.zig");

                // Convert to null-terminated string for libpq
                var sql_buf: [4096]u8 = undefined;
                if (sql.len >= sql_buf.len) return error.SqlTooLong;
                @memcpy(sql_buf[0..sql.len], sql);
                sql_buf[sql.len] = 0;
                const sql_z: [:0]const u8 = sql_buf[0..sql.len :0];

                return pg.query(T, self._arena, sql_z, params);
            },
            .sqlite => {
                const sqlite = @import("../drivers/sqlite/sqlite.zig");
                return sqlite.query(T, self._arena, sql, params);
            },
            .mysql => {
                const mysql = @import("../drivers/mysql/mysql.zig");
                return mysql.query(T, self._arena, sql, params);
            },
        };
    }
};

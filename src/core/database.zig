const std = @import("std");

pub const Database = struct {
    ptr: *anyopaque,
    exec_fn: *const fn (ptr: *anyopaque, sql: []const u8) anyerror!void,
    deinit_fn: *const fn (ptr: *anyopaque) void,

    pub fn exec(self: Database, sql: []const u8) !void {
        return self.exec_fn(self.ptr, sql);
    }

    pub fn deinit(self: Database) void {
        self.deinit_fn(self.ptr);
    }
};

pub const DatabaseCtx = struct {
    _db: *const Database,
    _arena: std.mem.Allocator,

    pub fn exec(self: DatabaseCtx, sql: []const u8) !void {
        return self._db.exec(sql);
    }

    // TODO: multi-driver query dispatch
    // Currently assumes PgDriver - when SQLite support is added,
    // we'll need driver_type enum and proper dispatch
    pub fn query(self: DatabaseCtx, comptime T: type, sql: []const u8, params: anytype) ![]T {
        const pg = @import("../drivers/pg/pg.zig");

        // Convert to null-terminated string for libpq
        var sql_buf: [4096]u8 = undefined;
        if (sql.len >= sql_buf.len) return error.SqlTooLong;
        @memcpy(sql_buf[0..sql.len], sql);
        sql_buf[sql.len] = 0;
        const sql_z: [:0]const u8 = sql_buf[0..sql.len :0];

        return pg.query(T, self._arena, sql_z, params);
    }
};

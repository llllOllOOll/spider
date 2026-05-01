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

pub const DriverType = enum { postgresql, mysql };

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
                return pg.query(T, self._arena, sql, params);
            },
            .mysql => {
                const mysql = @import("../drivers/mysql/mysql.zig");
                return mysql.query(T, self._arena, sql, params);
            },
        };
    }
};

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

    pub fn query(self: DatabaseCtx, comptime T: type, sql: []const u8) !T {
        _ = self;
        _ = sql;
        @compileError("query() with comptime T cannot go through vtable; call the driver directly");
    }
};

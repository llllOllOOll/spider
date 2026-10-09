//! Internal: the old generic database handle (`Database`, a pointer plus an
//! exec function) and the `DatabaseCtx` that `c.db()` returns. Apps use
//! `spider.pg` or `spider.sqlite` directly.
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
};

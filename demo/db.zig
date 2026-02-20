const std = @import("std");
pub const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const User = struct {
    id: i32,
    name: []const u8,
};

pub const Db = struct {
    conn: ?*c.PGconn,

    pub fn connect(conninfo: [:0]const u8) !Db {
        const conn = c.PQconnectdb(conninfo);
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            c.PQfinish(conn);
            return error.ConnectionFailed;
        }
        return .{ .conn = conn };
    }

    pub fn disconnect(self: *Db) void {
        c.PQfinish(self.conn);
    }

    pub fn queryUsers(self: *Db, allocator: std.mem.Allocator) ![]User {
        const result = c.PQexec(self.conn, "SELECT id, name FROM users LIMIT 10");
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            return error.QueryFailed;
        }

        const nrows: usize = @intCast(c.PQntuples(result));
        const users = try allocator.alloc(User, nrows);

        for (0..nrows) |i| {
            const id_str = c.PQgetvalue(result, @intCast(i), 0);
            const name_str = c.PQgetvalue(result, @intCast(i), 1);
            users[i] = .{
                .id = try std.fmt.parseInt(i32, std.mem.span(id_str), 10),
                .name = try allocator.dupe(u8, std.mem.span(name_str)),
            };
        }
        return users;
    }
};

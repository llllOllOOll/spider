const std = @import("std");
const spider_pg = @import("spider_pg");

pub const User = struct {
    id: u64,
    email: []const u8,
    name: []const u8,

    pub fn deinit(self: User, alloc: std.mem.Allocator) void {
        alloc.free(self.email);
        alloc.free(self.name);
    }
};

pub const CreateUserInput = struct {
    email: []const u8,
    name: []const u8,
};

pub const UpdateUserInput = struct {
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const UserRepository = struct {
    allocator: std.mem.Allocator,
    pool: *spider_pg.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *spider_pg.Pool) UserRepository {
        return .{ .allocator = allocator, .pool = pool };
    }

    // ─── Create ───────────────────────────────────────────

    pub fn create(self: UserRepository, input: CreateUserInput) !User {
        const sql = "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.queryParams(conn, sql, &.{ input.email, input.name }, self.allocator);
        defer result.deinit();

        return User{
            .id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10),
            .email = try self.allocator.dupe(u8, input.email),
            .name = try self.allocator.dupe(u8, input.name),
        };
    }

    // ─── Read ─────────────────────────────────────────────

    pub fn findById(self: UserRepository, id: u64) !?User {
        const sql = "SELECT id, email, name FROM users WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return null;

        return User{
            .id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10),
            .email = try self.allocator.dupe(u8, result.getValue(0, 1)),
            .name = try self.allocator.dupe(u8, result.getValue(0, 2)),
        };
    }

    pub fn findByEmail(self: UserRepository, email: []const u8) !?User {
        const sql = "SELECT id, email, name FROM users WHERE email = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.queryParams(conn, sql, &.{email}, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return null;

        return User{
            .id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10),
            .email = try self.allocator.dupe(u8, result.getValue(0, 1)),
            .name = try self.allocator.dupe(u8, result.getValue(0, 2)),
        };
    }

    pub fn findAll(self: UserRepository) ![]User {
        const sql = "SELECT id, email, name FROM users ORDER BY id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.query(conn, sql);
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]User{};

        var users = try self.allocator.alloc(User, count);
        errdefer self.allocator.free(users);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            users[i] = .{
                .id = try std.fmt.parseInt(u64, result.getValue(i, 0), 10),
                .email = try self.allocator.dupe(u8, result.getValue(i, 1)),
                .name = try self.allocator.dupe(u8, result.getValue(i, 2)),
            };
        }

        return users;
    }

    pub fn exists(self: UserRepository, email: []const u8) !bool {
        const sql = "SELECT 1 FROM users WHERE email = $1 LIMIT 1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.queryParams(conn, sql, &.{email}, self.allocator);
        defer result.deinit();

        return result.rows() > 0;
    }

    // ─── Update ───────────────────────────────────────────

    pub fn update(self: UserRepository, id: u64, input: UpdateUserInput) !?User {
        const current = try self.findById(id) orelse return null;
        defer {
            self.allocator.free(current.email);
            self.allocator.free(current.name);
        }

        const new_email = if (input.email) |e| try self.allocator.dupe(u8, e) else try self.allocator.dupe(u8, current.email);
        errdefer self.allocator.free(new_email);

        const new_name = if (input.name) |n| try self.allocator.dupe(u8, n) else try self.allocator.dupe(u8, current.name);
        errdefer self.allocator.free(new_name);

        const sql = "UPDATE users SET email = $1, name = $2 WHERE id = $3";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{ new_email, new_name, id_str }, self.allocator);
        defer result.deinit();

        return User{
            .id = id,
            .email = new_email,
            .name = new_name,
        };
    }

    // ─── Delete ───────────────────────────────────────────

    pub fn delete(self: UserRepository, id: u64) !bool {
        const sql = "DELETE FROM users WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        return true;
    }

    pub fn destroy(self: UserRepository, user: User) void {
        user.deinit(self.allocator);
    }

    pub fn destroyAll(self: UserRepository, users: []User) void {
        for (users) |user| {
            user.deinit(self.allocator);
        }
        self.allocator.free(users);
    }
};

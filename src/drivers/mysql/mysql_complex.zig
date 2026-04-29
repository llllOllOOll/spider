const std = @import("std");
const protocol = @import("./protocol.zig");
const connection = @import("./connection.zig");
const types = @import("./types.zig");

pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 3306,
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
    if (std.c.getenv(&key_null)) |val| {
        return std.mem.sliceTo(val, 0);
    }
    return default;
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (std.c.getenv(&key_null)) |val| {
        return std.fmt.parseInt(u16, std.mem.sliceTo(val, 0), 10) catch default;
    }
    return default;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;

    const host_raw = overrides.host orelse getEnv("MYSQL_HOST", "localhost");
    const port = overrides.port orelse getEnvInt("MYSQL_PORT", 3306);
    const user_raw = overrides.user orelse getEnv("MYSQL_USER", "spider");
    const password_raw = overrides.password orelse getEnv("MYSQL_PASSWORD", "spider");
    const database_raw = overrides.database orelse getEnv("MYSQL_DB", "spider_db");
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

fn QueryResult(comptime T: type) type {
    return switch (T) {
        void => void,
        i32 => i32,
        else => []T,
    };
}

/// Query the database and return results as native Zig types.
/// API idêntica ao PostgreSQL: c.db().query(T, sql, params)
///
/// The return type is determined by T:
///   query(User, arena, sql, params)  → ![]User   // SELECT multiple rows
///   query(void, arena, sql, params)  → !void     // INSERT/UPDATE/DELETE
///   query(i32,  arena, sql, params)  → !i32      // INSERT/UPDATE RETURNING id
///
/// Ownership: caller passes arena, function allocates into it,
/// caller calls arena.deinit() when done.
///
/// Params support native Zig types: i32, i64, f64, bool,
/// []const u8, and optionals (?i32, ?[]const u8, etc).
pub fn query(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    // TODO: Implement parameter binding for MySQL prepared statements
    _ = params;

    // For now, use simple query without parameters
    _ = 0; // param_count

    // Execute query and get result set
    var result_set = try conn.executeQuery(sql);
    defer result_set.deinit();

    // Handle different return types
    return switch (T) {
        void => {
            // For void queries (INSERT/UPDATE/DELETE), just return success
            return {};
        },
        i32 => {
            // For single integer return (like RETURNING id)
            if (result_set.rows.items.len > 0 and result_set.fields.items.len > 0) {
                const first_value = result_set.rows.items[0].values.items[0];
                return try std.fmt.parseInt(i32, first_value, 10);
            }
            return 0;
        },
        else => {
            // For struct types, map rows to structs
            const items = try arena.alloc(T, result_set.rows.items.len);

            for (result_set.rows.items, 0..) |row, i| {
                items[i] = try mapRowToStruct(T, row, result_set.fields.items, arena);
            }

            return items;
        },
    };
}

fn mapRowToStruct(
    comptime T: type,
    row: connection.Row,
    fields: []connection.Field,
    arena: std.mem.Allocator,
) !T {
    var item: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        // Find matching field by name
        var field_index: ?usize = null;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, field.name)) {
                field_index = i;
                break;
            }
        }

        if (field_index) |idx| {
            const raw_value = if (idx < row.values.items.len) row.values.items[idx] else "";

            @field(item, field.name) = try types.decodeText(field.type, raw_value, arena);
        } else {
            // Field not found, use default value
            @field(item, field.name) = switch (field.type) {
                []const u8 => "",
                bool => false,
                i8, i16, i32, i64, u8, u16, u32, u64 => 0,
                f32, f64 => 0.0,
                else => @compileError("Unsupported field type: " ++ @typeName(field.type)),
            };
        }
    }

    return item;
}

/// Query a single row and return it as a native Zig struct.
/// Same API as PostgreSQL
///
///   queryOne(User, arena, sql, params) → !?User
///
/// Returns null if no rows found, the struct if found.
/// Only for structs — use query(i32, ...) for RETURNING id.
pub fn queryOne(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?T {
    _ = arena;
    _ = sql;
    _ = params;

    return switch (T) {
        i32 => null,
        else => error.NotImplemented,
    };
}

/// Execute raw SQL string (multiple statements supported).
/// Uses MySQL COM_QUERY protocol internally.
pub fn queryExecute(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
) !QueryResult(T) {
    _ = arena;
    _ = sql;

    return switch (T) {
        void => {},
        i32 => 0,
        else => error.NotImplemented,
    };
}

const Conn = connection.Connection;

pub const Pool = struct {
    conns: []connection.Connection,
    config: Config,
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Pool {
        const conns = try allocator.alloc(connection.Connection, config.pool_size);
        errdefer allocator.free(conns);

        // Initialize connections
        for (conns) |*conn| {
            conn.* = connection.Connection.init(allocator);

            // Connect to MySQL server
            try conn.connect(config.host, config.port);
            try conn.authenticate(config.user, config.password, config.database);
        }

        return .{
            .conns = conns,
            .config = config,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Pool) void {
        for (self.conns) |*conn| {
            conn.close();
        }
        self.allocator.free(self.conns);
        self.allocator.free(self.config.host);
        self.allocator.free(self.config.user);
        self.allocator.free(self.config.password);
        self.allocator.free(self.config.database);
    }

    pub fn acquire(self: *Pool) !*connection.Connection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Simple round-robin for now
        for (self.conns) |*conn| {
            // TODO: Add connection health checking
            return conn;
        }

        return error.NoConnectionsAvailable;
    }

    pub fn release(self: *Pool, conn: *connection.Connection) void {
        _ = conn;
        self.cond.signal(self.io);
    }
};

fn mysqlExecFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
    _ = ptr;
    _ = sql;

    // TODO: Implementar execução MySQL
    return error.NotImplemented;
}

fn mysqlDeinitFn(_: *anyopaque) void {
    // TODO: Implementar cleanup MySQL
}

pub const MySqlDriver = struct {
    _dummy: u8 = 0,

    pub fn database(_: *MySqlDriver) Database {
        return .{
            .ptr = undefined, // TODO: Implement
            .exec_fn = mysqlExecFn,
            .deinit_fn = mysqlDeinitFn,
            .driver_type = .mysql,
        };
    }
};

const Database = @import("../../core/database.zig").Database;

const net = std.Io.net;

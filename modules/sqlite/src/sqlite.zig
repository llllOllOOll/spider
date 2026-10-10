//! SQLite for an app (`spider.sqlite`, opt-in with `-Dsqlite=true`): one
//! database per process, opened by `init`, then `query`, `queryOne`,
//! `queryExecute` and `begin` from anywhere. Rows come back as structs whose
//! fields are matched to columns by name.
const std = @import("std");
const zqlite = @import("zqlite");

// ── Global state ──────────────────────────────────────────
var db_pool: ?*zqlite.Pool = null;
var db_conn: ?zqlite.Conn = null;
var db_path: ?[]u8 = null;
var db_allocator: ?std.mem.Allocator = null;
var db_io: ?std.Io = null;

// ── Config ────────────────────────────────────────────────
/// The options of `init`. `.{}` opens the file named by `SQLITE_PATH` with
/// a pool of five connections.
pub const DbConfig = struct {
    /// The database file, or ":memory:". null (the default): the
    /// `SQLITE_PATH` variable, or "db.sqlite" when it is not set.
    path: ?[]const u8 = null, // null → read SQLITE_PATH from env, fallback "db.sqlite"
    /// Connections in the pool. Default 5. With 1 there is no pool: every
    /// call uses the same connection, which is what an in-memory database
    /// needs (each connection to ":memory:" is a database of its own).
    size: usize = 5,
};

// ── Init / Deinit ─────────────────────────────────────────
/// Opens the database, creating the file when it does not exist. Call it
/// once at startup, before any query, and `deinit()` at exit. `allocator`
/// must outlive the database. Fails with the SQLite error when the file
/// can't be opened.
///
/// ```zig
/// try spider.sqlite.init(allocator, io, .{});
/// defer spider.sqlite.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;
    const env = @import("spider").env;
    const path = overrides.path orelse env.getOr("SQLITE_PATH", "db.sqlite");
    const path_buf = try allocator.alloc(u8, path.len + 1);
    db_path = path_buf;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf.ptr);
    if (overrides.size == 1) {
        const c = try zqlite.open(path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        try runMigrations(c, null);
        db_conn = c;
    } else {
        db_io = io;
        db_pool = try zqlite.Pool.init(allocator, .{
            .size = overrides.size,
            .path = path_z,
            .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
            .on_first_connection = runMigrations,
            .on_first_connection_context = null,
        });
    }
}

/// Closes every connection. No query may run after it.
pub fn deinit() void {
    if (db_conn) |c| c.close();
    db_conn = null;
    if (db_pool) |p| p.deinit();
    db_pool = null;
    if (db_path) |p| {
        if (db_allocator) |a| a.free(p);
        db_path = null;
    }
}

// ── Conn helpers ────────────────────────────────────────────
fn acquireConn() !zqlite.Conn {
    if (db_conn) |c| return c;
    return db_pool.?.acquire(db_io.?);
}

fn releaseConn(conn: zqlite.Conn) void {
    if (db_conn != null) return;
    db_pool.?.release(db_io.?, conn);
}

// ── QueryResult ───────────────────────────────────────────
fn QueryResult(comptime T: type) type {
    if (T == void) return void;
    if (T == i64) return i64;
    return []T;
}

// ── nullValue ─────────────────────────────────────────────
fn nullValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .optional => null,
        .int => 0,
        .float => 0.0,
        .bool => false,
        .pointer => &[_]u8{},
        else => undefined,
    };
}

// ── decodeField ───────────────────────────────────────────
fn decodeField(comptime T: type, row: zqlite.Row, col: usize, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        if (row.columnType(col) == .null) return null;
        return try decodeField(info.optional.child, row, col, arena);
    }
    if (info == .@"enum") {
        const text = row.text(col);
        return std.meta.stringToEnum(T, text) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try arena.dupe(u8, row.text(col)),
        bool => row.boolean(col),
        i8, i16, i32, i64 => @intCast(row.int(col)),
        u8, u16, u32, u64 => @intCast(row.int(col)),
        f32, f64 => @floatCast(row.float(col)),
        else => @compileError("decodeField: unsupported type " ++ @typeName(T)),
    };
}

// ── mapRow ────────────────────────────────────────────────
fn mapRow(comptime T: type, row: zqlite.Row, arena: std.mem.Allocator) !T {
    var item: T = undefined;
    const info = @typeInfo(T).@"struct";
    const col_count: usize = @intCast(row.columnCount());
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        var col_idx: ?usize = null;
        for (0..col_count) |i| {
            if (std.mem.eql(u8, row.columnName(i), field_name)) {
                col_idx = i;
                break;
            }
        }
        if (col_idx) |ci| {
            @field(item, field_name) = try decodeField(field_type, row, ci, arena);
        } else {
            @field(item, field_name) = nullValue(field_type);
        }
    }
    return item;
}

// ── query ─────────────────────────────────────────────────
/// Runs one statement with `?` parameters and gives back what `T` asks for:
/// - a struct: every row as a `[]T` allocated in `arena`. A field takes the
///   column of the same name; a field with no such column gets null, 0,
///   false or "". Fields may be `[]const u8` (copied into `arena`), `bool`,
///   integers, floats, enums (stored as their name; error.InvalidEnumValue
///   for another text) and optionals of those (null for a NULL column).
/// - `i64`: the first column of the first row, 0 when there is no row.
/// - `void`: nothing; for INSERT, UPDATE and DELETE.
///
/// Fails with the SQLite error of the statement (a constraint, a missing
/// table, a syntax error).
///
/// ```zig
/// const posts = try spider.sqlite.query(Post, c.arena, "SELECT id, title FROM posts WHERE author = ?", .{author});
/// try spider.sqlite.query(void, c.arena, "DELETE FROM posts WHERE id = ?1", .{id});
/// ```
pub fn query(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
    const conn = try acquireConn();
    defer releaseConn(conn);

    if (T == void) {
        try conn.exec(sql, params);
        return;
    }

    var rows = try conn.rows(sql, params);
    defer rows.deinit();

    if (T == i64) {
        if (rows.next()) |row| return row.int(0);
        // No row: nothing matched, or the statement failed while running.
        if (rows.err) |err| return err;
        return 0;
    }

    var items = std.ArrayListUnmanaged(T).empty;
    while (rows.next()) |row| {
        try items.append(arena, try mapRow(T, row, arena));
    }
    if (rows.err) |err| return err;
    return try items.toOwnedSlice(arena);
}

// ── queryOne ──────────────────────────────────────────────
/// The first row of a statement as a struct `T`, or null when it returns
/// no row. Fields are mapped as in `query`; strings are allocated in `arena`.
///
/// ```zig
/// const post = try spider.sqlite.queryOne(Post, c.arena, "SELECT id, title FROM posts WHERE id = ?", .{id}) orelse return error.NotFound;
/// ```
pub fn queryOne(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
    const conn = try acquireConn();
    defer releaseConn(conn);

    const row = try conn.row(sql, params) orelse return null;
    defer row.deinit();
    return try mapRow(T, row, arena);
}

// ── queryExecute ────────────────────────────────────────────
/// Runs a script: one or more statements separated by `;`, without
/// parameters (DDL, migrations). Triggers and `;` inside strings or comments
/// are fine. Pass `void` as `T`: no rows are returned (a struct `T` gives an
/// empty slice). The allocator argument is not used.
///
/// ```zig
/// try spider.sqlite.queryExecute(void, arena, "CREATE TABLE IF NOT EXISTS posts (id INTEGER PRIMARY KEY, title TEXT)");
/// ```
pub fn queryExecute(comptime T: type, _: std.mem.Allocator, sql: []const u8) !QueryResult(T) {
    const conn = try acquireConn();
    defer releaseConn(conn);

    // The whole script goes to sqlite3_exec, which runs each statement in
    // turn. (Splitting on ';' here cut triggers, whose body has its own
    // semicolons, and any ';' inside a string or a comment.)
    // The copy does not come from `arena`: exec() below has none to give.
    const gpa = std.heap.smp_allocator;
    const sql_z = try gpa.dupeSentinel(u8, sql, 0);
    defer gpa.free(sql_z);
    try conn.execNoArgs(sql_z);
    return if (T == void) {} else &[_]T{};
}

// ── exec (for Database bridge) ───────────────────────────────
/// Runs a script without parameters: `queryExecute(void, ...)` without the
/// allocator argument.
pub fn exec(sql: []const u8) !void {
    try queryExecute(void, undefined, sql);
}

// ── Transaction ──────────────────────────────────────────────
/// A transaction on one connection, made by `begin()`. End it with
/// `commit()` or `rollback()`; a call after the first does nothing.
///
/// ```zig
/// var tx = try spider.sqlite.begin();
/// defer tx.rollback();
/// try tx.query(void, c.arena, "INSERT INTO posts (title) VALUES (?1)", .{title});
/// try tx.commit();
/// ```
pub const Transaction = struct {
    /// The connection the transaction runs on.
    conn: zqlite.Conn,
    /// The transaction was committed or rolled back: its connection went
    /// back to the pool and must not be given back again.
    finished: bool = false,

    /// The same as the module's `query`, inside this transaction.
    pub fn query(self: Transaction, comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
        if (T == void) {
            try self.conn.exec(sql, params);
            return;
        }
        var rows = try self.conn.rows(sql, params);
        defer rows.deinit();
        if (T == i64) {
            if (rows.next()) |row| return row.int(0);
            // No row: nothing matched, or the statement failed while running.
            if (rows.err) |err| return err;
            return 0;
        }
        var items = std.ArrayListUnmanaged(T).empty;
        while (rows.next()) |row| {
            try items.append(arena, try mapRow(T, row, arena));
        }
        if (rows.err) |err| return err;
        return try items.toOwnedSlice(arena);
    }

    /// Commits and gives the connection back. When the commit fails the
    /// connection is still held: call `rollback()`.
    pub fn commit(self: *Transaction) !void {
        if (self.finished) return;
        try self.conn.commit();
        self.finished = true;
        releaseConn(self.conn);
    }

    /// Undoes everything since `begin()` and gives the connection back.
    /// After a `commit()` or another `rollback()` it does nothing, so
    /// `defer tx.rollback()` right after `begin()` is safe.
    pub fn rollback(self: *Transaction) void {
        if (self.finished) return;
        self.finished = true;
        self.conn.rollback();
        releaseConn(self.conn);
    }
};

/// Starts a transaction on a connection that stays reserved until
/// `commit()` or `rollback()`. Statements run through the module's `query`
/// meanwhile are not part of it when the pool has more than one connection.
///
/// ```zig
/// var tx = try spider.sqlite.begin();
/// try tx.query(void, arena, "INSERT INTO posts (title) VALUES (?)", .{title});
/// try tx.commit();
/// ```
pub fn begin() !Transaction {
    const conn = try acquireConn();
    try conn.transaction();
    return Transaction{ .conn = conn };
}

// ── Migrations placeholder ────────────────────────────────
fn runMigrations(_: zqlite.Conn, _: ?*anyopaque) !void {}

// ── SqliteDriver (Database interface) ────────────────────────

fn sqliteExecFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
    _ = ptr;
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\r\t");
        if (s.len == 0) continue;
        try exec(s);
    }
}

fn sqliteDeinitFn(_: *anyopaque) void {}

// internal: adapter to the old generic `spider.Database` handle; apps call
// the functions above.
pub const SqliteDriver = struct {
    _dummy: u8 = 0,

    // internal: see SqliteDriver.
    pub fn database(_: *SqliteDriver) @import("spider").Database {
        return .{
            .ptr = @constCast(db_pool orelse @panic("SQLite not initialized")),
            .exec_fn = sqliteExecFn,
            .deinit_fn = sqliteDeinitFn,
        };
    }
};

// ── Tests ─────────────────────────────────────────────────────

fn initTestDb(allocator: std.mem.Allocator) !void {
    try init(allocator, undefined, .{ .path = ":memory:", .size = 1 });
}

test "query - integer param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const conn = try acquireConn();
    defer releaseConn(conn);
    try conn.execNoArgs("CREATE TEMP TABLE int_test (val INTEGER)");
    try conn.execNoArgs("INSERT INTO int_test VALUES (42)");

    const Row = struct { val: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT val FROM int_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 42), rows[0].val);
}

test "query - bool param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const conn = try acquireConn();
    defer releaseConn(conn);
    try conn.execNoArgs("CREATE TEMP TABLE bool_test (val INTEGER)");
    try conn.exec("INSERT INTO bool_test VALUES (?)", .{@as(i64, 1)});

    const Row = struct { val: bool };
    const rows = try query(Row, arena.allocator(), "SELECT val FROM bool_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].val);
}

test "query - text param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const conn = try acquireConn();
    defer releaseConn(conn);
    try conn.execNoArgs("CREATE TEMP TABLE text_test (val TEXT)");
    try conn.exec("INSERT INTO text_test VALUES (?)", .{"hello"});

    const Row = struct { val: []const u8 };
    const rows = try query(Row, arena.allocator(), "SELECT val FROM text_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("hello", rows[0].val);
}

test "queryExecute - a script with a trigger (semicolons inside BEGIN..END, in strings and comments)" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(),
        \\CREATE TEMP TABLE trig_test (id INTEGER PRIMARY KEY, name TEXT, touched INTEGER DEFAULT 0);
        \\-- a comment; with a semicolon
        \\CREATE TEMP TRIGGER trig_test_touch
        \\AFTER UPDATE OF name ON trig_test
        \\FOR EACH ROW
        \\BEGIN
        \\    UPDATE trig_test SET touched = touched + 1 WHERE id = NEW.id;
        \\END;
        \\INSERT INTO trig_test (name) VALUES ('a; b');
        \\UPDATE trig_test SET name = 'c' WHERE id = 1;
    );

    const Row = struct { name: []const u8, touched: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT name, touched FROM trig_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("c", rows[0].name);
    try std.testing.expectEqual(@as(i64, 1), rows[0].touched);
}

test "exec - runs a script without an arena" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    try exec("CREATE TEMP TABLE exec_test (x INTEGER); INSERT INTO exec_test VALUES (1);");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Row = struct { x: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT x FROM exec_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
}

test "queryExecute - DDL statement" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE ddl_test (x INTEGER)");
    try queryExecute(void, arena.allocator(), "INSERT INTO ddl_test VALUES (10), (20), (30)");

    const Row = struct { x: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT x FROM ddl_test ORDER BY x", .{});
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(i64, 10), rows[0].x);
    try std.testing.expectEqual(@as(i64, 30), rows[2].x);
}

test "transaction - commit" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE tx_test (id INTEGER)");

    {
        var tx = try begin();
        try tx.query(void, arena.allocator(), "INSERT INTO tx_test VALUES (?)", .{@as(i64, 99)});
        try tx.commit();
    }

    const Row = struct { id: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM tx_test", .{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 99), rows[0].id);
}

test "transaction - a rollback after the commit does nothing (defer tx.rollback())" {
    // A pool this time: giving a connection back twice is what breaks.
    try init(std.testing.allocator, std.testing.io, .{ .path = ":memory:", .size = 2 });
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        var tx = try begin();
        defer tx.rollback(); // the pattern taught for spider.pg
        try tx.query(void, arena.allocator(), "CREATE TABLE tx_twice (id INTEGER)", .{});
        try tx.commit();
    }

    // Both connections are still there, and they are two.
    var first = try begin();
    var second = try begin();
    try std.testing.expect(first.conn.conn != second.conn.conn);
    second.rollback();
    second.rollback(); // twice is harmless too
    first.rollback();

    var again = try begin();
    try again.commit();
}

test "query(i64) - a statement that fails while running is an error, not 0" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Prepares fine, fails when it runs: SQLite refuses abs() of the
    // smallest integer.
    const sql = "SELECT abs(-9223372036854775808)";
    try std.testing.expect(std.meta.isError(query(i64, arena.allocator(), sql, .{})));

    var tx = try begin();
    defer tx.rollback();
    try std.testing.expect(std.meta.isError(tx.query(i64, arena.allocator(), sql, .{})));

    // No row at all is still 0.
    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE empty_t (n INTEGER)");
    try std.testing.expectEqual(@as(i64, 0), try tx.query(i64, arena.allocator(), "SELECT n FROM empty_t", .{}));
}

test "queryOne - single row return" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE one_test (id INTEGER, label TEXT)");
    try queryExecute(void, arena.allocator(), "INSERT INTO one_test VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')");

    const Row = struct { id: i64, label: []const u8 };
    const row = try queryOne(Row, arena.allocator(), "SELECT id, label FROM one_test WHERE id = ?", .{@as(i64, 2)});
    try std.testing.expect(row != null);
    if (row) |r| {
        try std.testing.expectEqual(@as(i64, 2), r.id);
        try std.testing.expectEqualStrings("beta", r.label);
    }

    const missing = try queryOne(Row, arena.allocator(), "SELECT id, label FROM one_test WHERE id = ?", .{@as(i64, 99)});
    try std.testing.expect(missing == null);
}

test "transaction - rollback" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE rb_test (id INTEGER)");

    {
        var tx = try begin();
        try tx.query(void, arena.allocator(), "INSERT INTO rb_test VALUES (?)", .{@as(i64, 42)});
        tx.rollback();
    }

    const Row = struct { id: i64 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM rb_test", .{});
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "mapRow - i64 and optional fields" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE opt_test (bigval INTEGER, maybe TEXT)");
    try queryExecute(void, arena.allocator(), "INSERT INTO opt_test VALUES (9000000000000, 'hello'), (42, NULL)");

    const Row = struct {
        bigval: i64,
        maybe: ?[]const u8,
    };

    const rows = try query(Row, arena.allocator(), "SELECT bigval, maybe FROM opt_test ORDER BY bigval", .{});
    try std.testing.expectEqual(@as(usize, 2), rows.len);

    try std.testing.expectEqual(@as(i64, 42), rows[0].bigval);
    try std.testing.expect(rows[0].maybe == null);

    try std.testing.expectEqual(@as(i64, 9000000000000), rows[1].bigval);
    try std.testing.expectEqualStrings("hello", rows[1].maybe.?);
}

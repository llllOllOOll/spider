const std = @import("std");
const pg_lib = @import("pg");
const env = @import("spider").env;

/// Marker type for PostgreSQL array parameters that should use ANY() pattern
pub fn ArrayParameter(comptime T: type) type {
    return struct {
        values: []const T,
        type_name: []const u8,

        pub fn init(values: []const T, type_name: []const u8) @This() {
            return .{
                .values = values,
                .type_name = type_name,
            };
        }
    };
}

/// Convert an array to PostgreSQL array parameter for use with ANY() operator.
/// Example: array(i32, &[_]i32{ 1, 2, 3 }) → ArrayParameter that will be handled as "$1::integer[]"
pub fn array(comptime T: type, values: []const T) ArrayParameter(T) {
    // Determine PostgreSQL type name
    const type_name = switch (T) {
        i16 => "smallint",
        i32 => "integer",
        i64 => "bigint",
        f32 => "real",
        f64 => "double precision",
        bool => "boolean",
        []const u8, []u8 => "text",
        else => "text", // fallback
    };

    return ArrayParameter(T).init(values, type_name);
}

pub const Config = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
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

var db_pool: ?*pg_lib.Pool = null;
var db_allocator: ?std.mem.Allocator = null;

fn getEnv(key: []const u8, default: []const u8) []const u8 {
    return env.getOr(key, default);
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    const val = env.get(key) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;
    env.autoLoad(allocator);

    const host = overrides.host orelse getEnv("PG_HOST", "localhost");
    const port = overrides.port orelse getEnvInt("PG_PORT", 5432);
    const user = overrides.user orelse getEnv("PG_USER", "spider");
    const password = overrides.password orelse getEnv("PG_PASSWORD", "spider");
    const database = overrides.database orelse getEnv("PG_DB", "spider_db");
    const pool_size: u16 = @intCast(overrides.pool_size orelse 10);

    const opts = pg_lib.Pool.Opts{
        .size = pool_size,
        .auth = .{
            .username = user,
            .password = password,
            .database = database,
        },
        .connect = .{
            .host = host,
            .port = port,
        },
    };

    var pg_err_msg: ?[]const u8 = null;
    defer if (pg_err_msg) |msg| allocator.free(msg);

    var attempt: usize = 0;
    var delay_ms: i64 = 1000;
    while (attempt < 5) : (attempt += 1) {
        db_pool = pg_lib.Pool.init(io, allocator, opts, &pg_err_msg) catch |err| {
            if (err == error.PG) {
                if (pg_err_msg) |msg| {
                    std.log.err("pg: {s}", .{msg});
                }
                return err;
            }
            if (attempt < 4) {
                std.log.warn("pg: connect attempt {d}/5 failed, retrying in {d}ms", .{ attempt + 1, delay_ms });
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay_ms), .real);
                delay_ms *= 2;
                continue;
            }
            std.log.err("pg: connection failed after 5 attempts", .{});
            return err;
        };
        std.log.info("pg: connected ({d} connections)", .{pool_size});
        break;
    }
}

pub fn deinit() void {
    if (db_pool) |p| {
        p.deinit();
        db_pool = null;
    }
    db_allocator = null;
}

pub fn acquireConn() !*pg_lib.Conn {
    return db_pool.?.acquire();
}

pub fn releaseConn(conn: *pg_lib.Conn) void {
    db_pool.?.release(conn);
}

pub fn QueryResult(comptime T: type) type {
    return switch (T) {
        void => void,
        i32 => i32,
        else => []T,
    };
}

fn readIntBinary(data: []const u8, oid: i32) i64 {
    return switch (oid) {
        21 => @as(i64, std.mem.readInt(i16, data[0..2], .big)),
        23 => @as(i64, std.mem.readInt(i32, data[0..4], .big)),
        20 => std.mem.readInt(i64, data[0..8], .big),
        else => 0,
    };
}

fn readFloatBinary(data: []const u8, oid: i32) f64 {
    return switch (oid) {
        700 => @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, data[0..4], .big)))),
        701 => @as(f64, @bitCast(std.mem.readInt(u64, data[0..8], .big))),
        else => 0.0,
    };
}

fn nullValue(comptime T: type) T {
    const info = @typeInfo(T);
    if (info == .optional) return null;
    return switch (T) {
        []const u8 => "",
        bool => false,
        i8, i16, i32, i64, u8, u16, u32, u64 => 0,
        f32, f64 => 0.0,
        else => @compileError("nullValue: unsupported field type " ++ @typeName(T)),
    };
}

fn decodeField(comptime T: type, data: []const u8, oid: i32, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        return try decodeField(info.optional.child, data, oid, arena);
    }
    if (info == .@"enum") {
        return std.meta.stringToEnum(T, data) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try arena.dupe(u8, data),
        bool => if (oid == 16) (data.len > 0 and data[0] != 0) else (data.len > 0 and (data[0] == 't' or data[0] == '1')),
        i8 => @intCast(readIntBinary(data, oid)),
        i16 => @intCast(readIntBinary(data, oid)),
        i32 => @intCast(readIntBinary(data, oid)),
        i64 => readIntBinary(data, oid),
        u8 => @intCast(readIntBinary(data, oid)),
        u16 => @intCast(readIntBinary(data, oid)),
        u32 => @intCast(readIntBinary(data, oid)),
        u64 => @intCast(readIntBinary(data, oid)),
        f32 => @floatCast(readFloatBinary(data, oid)),
        f64 => readFloatBinary(data, oid),
        else => @compileError("decodeField: unsupported field type " ++ @typeName(T)),
    };
}

fn mapRow(comptime T: type, result: *pg_lib.Result, row: pg_lib.Row, arena: std.mem.Allocator) !T {
    var item: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        var col_idx: ?usize = null;
        for (result.column_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, field_name)) {
                col_idx = i;
                break;
            }
        }
        if (col_idx) |ci| {
            const value = row.values[ci];
            @field(item, field_name) = if (value.is_null)
                nullValue(field_type)
            else
                try decodeField(field_type, value.data, row.oids[ci], arena);
        } else {
            @field(item, field_name) = nullValue(field_type);
        }
    }
    return item;
}

fn logPgErr(conn: *pg_lib.Conn) void {
    if (conn.err) |e| {
        std.log.err("[pg] {s} (code={s})", .{ e.message, e.code });
        if (e.detail) |d| std.log.err("[pg] detail: {s}", .{d});
        if (e.constraint) |c| std.log.err("[pg] constraint: {s}", .{c});
    }
}

fn execTyped(
    conn: *pg_lib.Conn,
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    if (T == void) {
        _ = conn.exec(sql, params) catch |err| {
            if (err == error.PG) logPgErr(conn);
            return err;
        };
        return {};
    }

    var result = conn.queryOpts(sql, params, .{ .column_names = true }) catch |err| {
        if (err == error.PG) logPgErr(conn);
        return err;
    };
    defer result.deinit();

    if (T == i32) {
        const row = (try result.next()) orelse return 0;
        const v = row.values[0];
        if (v.is_null) return 0;
        return @intCast(readIntBinary(v.data, row.oids[0]));
    }

    var items = std.ArrayListUnmanaged(T).empty;
    while (try result.next()) |row| {
        try items.append(arena, try mapRow(T, result, row, arena));
    }
    return try items.toOwnedSlice(arena);
}

fn execTypedOne(
    conn: *pg_lib.Conn,
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?T {
    var result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer result.deinit();

    const row = (try result.next()) orelse return null;

    const out: ?T = if (T == i32) blk: {
        const v = row.values[0];
        if (v.is_null) break :blk null;
        break :blk @intCast(readIntBinary(v.data, row.oids[0]));
    } else try mapRow(T, result, row, arena);

    // Drain remaining CommandComplete + ReadyForQuery messages so conn._state
    // is restored to .idle/.transaction before the connection is reused.
    // Without this, transactions fail with ConnectionBusy on the next operation.
    while (try result.next()) |_| {}

    return out;
}

pub fn query(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTyped(conn, T, arena, sql, params);
}

pub fn queryOne(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?T {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTypedOne(conn, T, arena, sql, params);
}

/// Execute raw SQL without parameters. Supports multiple statements separated by ';'.
pub fn queryExecute(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
) !QueryResult(T) {
    if (T == void) try guardMulti(sql) else try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    if (T == void) {
        var it = std.mem.splitScalar(u8, sql, ';');
        while (it.next()) |stmt| {
            const s = std.mem.trim(u8, stmt, " \n\r\t");
            if (s.len == 0) continue;
            _ = try conn.exec(s, .{});
        }
        return {};
    }

    return execTyped(conn, T, arena, sql, .{});
}

/// Execute raw SQL without parameters and return a single row.
pub fn queryOneExecute(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
) !?T {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    return execTypedOne(conn, T, arena, sql, .{});
}

pub fn begin() !Transaction {
    const conn = try db_pool.?.acquire();
    _ = conn.exec("BEGIN", .{}) catch |err| {
        if (err == error.PG) logPgErr(conn);
        db_pool.?.release(conn);
        return err;
    };
    return Transaction{ .conn = conn };
}

/// Runs `body(&tx, context)` inside one transaction on one pinned connection:
/// commits when it returns normally, rolls back when it returns an error (the
/// error is passed through).
///
///   const id = try pg.transaction(i64, input, struct {
///       fn run(tx: *pg.Transaction, in: Input) !i64 { ... }
///   }.run);
pub fn transaction(
    comptime R: type,
    context: anytype,
    comptime body: fn (*Transaction, @TypeOf(context)) anyerror!R,
) !R {
    var tx = try begin();
    errdefer tx.rollback();
    const result = try body(&tx, context);
    try tx.commit();
    return result;
}

// ── Transaction-control guard ───────────────────────────────────────────────

pub const TxControl = enum {
    none,
    /// BEGIN / START TRANSACTION
    open,
    /// COMMIT / END / ROLLBACK / ABORT
    close,
    /// SAVEPOINT / RELEASE / ROLLBACK TO — only meaningful inside a transaction
    inside,
};

fn skipSqlNoise(sql: []const u8) []const u8 {
    var rest = sql;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        if (std.mem.startsWith(u8, rest, "--")) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
            rest = rest[nl + 1 ..];
        } else if (std.mem.startsWith(u8, rest, "/*")) {
            const end = std.mem.indexOf(u8, rest, "*/") orelse return "";
            rest = rest[end + 2 ..];
        } else return rest;
    }
}

fn nextWord(sql: []const u8) struct { word: []const u8, rest: []const u8 } {
    const s = skipSqlNoise(sql);
    var i: usize = 0;
    while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
    return .{ .word = s[0..i], .rest = s[i..] };
}

/// Classifies the leading keyword(s) of one SQL statement.
pub fn txControl(sql: []const u8) TxControl {
    const first = nextWord(sql);
    const w = first.word;
    const second = nextWord(first.rest).word;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "BEGIN")) return .open;
    if (eq(w, "START")) return if (eq(second, "TRANSACTION")) .open else .none;
    if (eq(w, "COMMIT") or eq(w, "ROLLBACK")) {
        if (eq(second, "PREPARED")) return .none; // two-phase commit, valid outside a tx
        if (eq(second, "TO")) return .inside;
        return .close;
    }
    if (eq(w, "END") or eq(w, "ABORT")) return .close;
    if (eq(w, "SAVEPOINT") or eq(w, "RELEASE")) return .inside;
    return .none;
}

fn refuseTxControl(sql: []const u8) error{UseBeginForTransactions} {
    std.log.err(
        "[pg] refused \"{s}\": every pg.* call runs on its own pooled connection, so transaction " ++
            "control there can't wrap other statements. Use pg.begin() / pg.transaction() instead.",
        .{std.mem.trim(u8, sql, " \t\r\n;")},
    );
    return error.UseBeginForTransactions;
}

/// Single-statement entry points never accept transaction control.
fn guardSingle(sql: []const u8) error{UseBeginForTransactions}!void {
    if (txControl(sql) != .none) return refuseTxControl(sql);
}

/// Multi-statement entry points run everything on one connection, so a
/// BEGIN ... COMMIT/ROLLBACK pair inside the same call is a real transaction.
/// Unbalanced control would hand an in-transaction connection back to the pool.
fn guardMulti(sql: []const u8) error{UseBeginForTransactions}!void {
    var open = false;
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        switch (txControl(stmt)) {
            .none => {},
            .open => {
                if (open) return refuseTxControl(sql);
                open = true;
            },
            .close => {
                if (!open) return refuseTxControl(sql);
                open = false;
            },
            .inside => if (!open) return refuseTxControl(sql),
        }
    }
    if (open) return refuseTxControl(sql);
}

/// Database transaction on ONE pinned connection. Use begin() (or
/// transaction()) to create one.
///
/// Example:
///   var tx = try pg.begin();
///   defer tx.rollback();
///   try tx.query(void, arena, "INSERT INTO users (name) VALUES ($1)", .{"Alice"});
///   try tx.commit();
///
/// After any statement fails, Postgres aborts the transaction: further
/// statements (and commit) return error.TransactionAborted until rollback().
pub const Transaction = struct {
    conn: *pg_lib.Conn,
    committed: bool = false,
    rolled_back: bool = false,

    fn check(self: *Transaction) !void {
        if (self.committed or self.rolled_back) return error.TransactionAlreadyFinished;
        if (self.conn._state == .fail) return error.TransactionAborted;
    }

    /// Deprecated: use tx.query(void, arena, sql, params) instead.
    pub fn exec(self: *Transaction, sql: []const u8, params: anytype) !void {
        try self.check();
        _ = self.conn.exec(sql, params) catch |err| {
            if (err == error.PG) logPgErr(self.conn);
            return err;
        };
    }

    pub fn query(
        self: *Transaction,
        comptime T: type,
        arena: std.mem.Allocator,
        sql: []const u8,
        params: anytype,
    ) !QueryResult(T) {
        try self.check();
        return execTyped(self.conn, T, arena, sql, params);
    }

    pub fn queryOne(
        self: *Transaction,
        comptime T: type,
        arena: std.mem.Allocator,
        sql: []const u8,
        params: anytype,
    ) !?T {
        try self.check();
        return execTypedOne(self.conn, T, arena, sql, params);
    }

    /// On failure the transaction stays open; the usual `defer tx.rollback()`
    /// then cleans it up and returns the connection.
    pub fn commit(self: *Transaction) !void {
        try self.check();
        _ = self.conn.exec("COMMIT", .{}) catch |err| {
            if (err == error.PG) logPgErr(self.conn);
            return err;
        };
        db_pool.?.release(self.conn);
        self.committed = true;
    }

    /// Safe to call at any point (also from `defer`), including after a
    /// failed statement: it uses the driver's rollback, which works on an
    /// aborted transaction, so the connection goes back to the pool clean
    /// instead of being torn down and reopened.
    pub fn rollback(self: *Transaction) void {
        if (self.committed or self.rolled_back) return;
        self.conn.rollback() catch {};
        db_pool.?.release(self.conn);
        self.rolled_back = true;
    }
};

// ── PgDriver (Database interface for ORM-style usage) ───────────────────────

fn pgExecFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
    try guardMulti(sql);
    _ = ptr;
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\r\t");
        if (s.len == 0) continue;
        _ = try conn.exec(s, .{});
    }
}

fn pgDeinitFn(_: *anyopaque) void {}

pub const PgDriver = struct {
    _dummy: u8 = 0,

    pub fn database(_: *PgDriver) @import("spider").Database {
        return .{
            .ptr = @constCast(db_pool orelse @panic("PostgreSQL not initialized")),
            .exec_fn = pgExecFn,
            .deinit_fn = pgDeinitFn,
        };
    }
};

// ── Deprecated API ──────────────────────────────────────────────────────────

/// Deprecated: use query(void, arena, sql, params) instead.
pub fn exec(sql: []const u8, params: anytype) !void {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    _ = try conn.exec(sql, params);
}

/// Deprecated: use queryExecute(void, arena, sql) instead.
pub fn execRaw(sql: []const u8) !void {
    try guardMulti(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var it = std.mem.splitScalar(u8, sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\r\t");
        if (s.len == 0) continue;
        _ = try conn.exec(s, .{});
    }
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryWith(sql: []const u8, params: anytype) !Result {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    var pg_result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer pg_result.deinit();

    var arena = std.heap.ArenaAllocator.init(db_allocator.?);
    errdefer arena.deinit();

    return collectResult(pg_result, arena);
}

/// Deprecated: use queryOne(T, arena, sql, params) instead.
pub fn queryOneWith(comptime T: type, sql: []const u8, params: anytype) !?T {
    var result = try queryWith(sql, params);
    defer result.deinit();
    return try result.mapOne(T, db_allocator.?);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryRaw(sql: []const u8, params: anytype) !Result {
    return queryWith(sql, params);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryRow(sql: []const u8, params: anytype) !Result {
    return queryWith(sql, params);
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !MappedRows(T) {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    var pg_result = try conn.queryOpts(sql, params, .{ .column_names = true });
    defer pg_result.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var items = std.ArrayListUnmanaged(T).empty;
    while (try pg_result.next()) |row| {
        try items.append(aa, try row.to(T, .{ .map = .name, .dupe = true, .allocator = aa }));
    }

    return MappedRows(T){
        .arena = arena,
        .items = try items.toOwnedSlice(aa),
    };
}

/// Deprecated: use queryOne(T, arena, sql, params) instead.
pub fn queryOneAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !?MappedRows(T) {
    var result = try queryAs(T, allocator, sql, params);
    if (result.items.len == 0) {
        result.deinit();
        return null;
    }
    return result;
}

pub fn MappedRows(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []T,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }
    };
}

// ── Deprecated Result type ──────────────────────────────────────────────────

pub const Result = struct {
    _arena: std.heap.ArenaAllocator,
    _col_names: [][]const u8,
    _values: [][]const u8,
    _row_count: usize,
    _col_count: usize,

    pub fn deinit(self: *Result) void {
        self._arena.deinit();
    }

    pub fn rows(self: *const Result) usize {
        return self._row_count;
    }

    pub fn columns(self: *const Result) usize {
        return self._col_count;
    }

    pub fn columnName(self: *const Result, col: usize) []const u8 {
        if (col >= self._col_count) return "";
        return self._col_names[col];
    }

    pub fn columnTypeOid(_: *const Result, _: usize) i32 {
        return 0;
    }

    pub fn affectedRows(self: *const Result) usize {
        return self._row_count;
    }

    pub fn getValue(self: *const Result, row: usize, col: usize) []const u8 {
        if (row >= self._row_count or col >= self._col_count) return "";
        return self._values[row * self._col_count + col];
    }

    pub fn get(self: *const Result, row: usize, comptime name: []const u8) []const u8 {
        for (self._col_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.getValue(row, i);
        }
        return "";
    }

    pub fn isNull(self: *const Result, row: usize, col: usize) bool {
        return self.getValue(row, col).len == 0;
    }

    pub fn mapAll(self: *Result, comptime T: type, alloc: std.mem.Allocator) ![]T {
        const items = try alloc.alloc(T, self._row_count);
        for (items, 0..) |*item, row| {
            item.* = try mapResultRow(T, self, row, alloc);
        }
        return items;
    }

    pub fn mapOne(self: *Result, comptime T: type, alloc: std.mem.Allocator) !?T {
        if (self._row_count == 0) return null;
        return try mapResultRow(T, self, 0, alloc);
    }
};

fn mapResultRow(comptime T: type, result: *const Result, row: usize, alloc: std.mem.Allocator) !T {
    var item: T = undefined;
    const info2 = @typeInfo(T).@"struct";
    inline for (info2.field_names, info2.field_types) |field_name, field_type| {
        var col_idx: ?usize = null;
        for (0..result._col_count) |i| {
            if (std.mem.eql(u8, result._col_names[i], field_name)) {
                col_idx = i;
                break;
            }
        }
        const raw = if (col_idx) |ci| result.getValue(row, ci) else "";
        @field(item, field_name) = try parseField(field_type, raw, alloc);
    }
    return item;
}

fn parseField(comptime T: type, raw: []const u8, alloc: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        const Child = info.optional.child;
        if (raw.len == 0) return null;
        return try parseField(Child, raw, alloc);
    }
    if (info == .@"enum") {
        return std.meta.stringToEnum(T, raw) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try alloc.dupe(u8, raw),
        bool => raw.len > 0 and (raw[0] == 't' or raw[0] == 'T' or raw[0] == '1'),
        i8, i16, i32, i64 => std.fmt.parseInt(T, raw, 10) catch 0,
        u8, u16, u32, u64 => std.fmt.parseInt(T, raw, 10) catch 0,
        f32, f64 => std.fmt.parseFloat(T, raw) catch 0.0,
        else => @compileError("parseField: unsupported type " ++ @typeName(T)),
    };
}

fn collectResult(pg_result: *pg_lib.Result, arena: std.heap.ArenaAllocator) !Result {
    var owned_arena = arena;
    const aa = owned_arena.allocator();

    const num_cols = pg_result.number_of_columns;

    const col_names = try aa.alloc([]const u8, num_cols);
    for (pg_result.column_names, 0..) |name, i| {
        col_names[i] = try aa.dupe(u8, name);
    }

    var values_list = std.ArrayListUnmanaged([]const u8).empty;
    var row_count: usize = 0;

    while (try pg_result.next()) |row| {
        for (0..num_cols) |col| {
            const value = row.values[col];
            const text = if (value.is_null)
                ""
            else
                try cellToText(aa, value.data, row.oids[col]);
            try values_list.append(aa, text);
        }
        row_count += 1;
    }

    return Result{
        ._arena = owned_arena,
        ._col_names = col_names,
        ._values = try values_list.toOwnedSlice(aa),
        ._row_count = row_count,
        ._col_count = num_cols,
    };
}

fn cellToText(arena: std.mem.Allocator, data: []const u8, oid: i32) ![]const u8 {
    return switch (oid) {
        21 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i16, data[0..2], .big)}),
        23 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i32, data[0..4], .big)}),
        20 => try std.fmt.allocPrint(arena, "{d}", .{std.mem.readInt(i64, data[0..8], .big)}),
        16 => if (data.len > 0 and data[0] == 1) "t" else "f",
        700 => blk: {
            const bits = std.mem.readInt(u32, data[0..4], .big);
            const f: f32 = @bitCast(bits);
            break :blk try std.fmt.allocPrint(arena, "{d}", .{f});
        },
        701 => blk: {
            const bits = std.mem.readInt(u64, data[0..8], .big);
            const f: f64 = @bitCast(bits);
            break :blk try std.fmt.allocPrint(arena, "{d}", .{f});
        },
        else => try arena.dupe(u8, data),
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

var test_threaded: ?std.Io.Threaded = null;

fn initTestDb(allocator: std.mem.Allocator) !void {
    if (test_threaded == null) {
        test_threaded = std.Io.Threaded.init(allocator, .{});
    }
    const io = test_threaded.?.io();
    try init(allocator, io, .{
        .host = null,
        .database = null,
        .user = null,
        .password = null,
    });
}

test "query - integer param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try query(i32, arena.allocator(), "SELECT $1::integer", .{@as(i32, 42)});
    try std.testing.expectEqual(42, result);
}

test "query - bool param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { val: bool };
    const rows = try query(Row, arena.allocator(), "SELECT $1::boolean AS val", .{true});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expect(rows[0].val);
}

test "query - text param" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { val: []const u8 };
    const rows = try query(Row, arena.allocator(), "SELECT $1::text AS val", .{"hello"});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expectEqualStrings("hello", rows[0].val);
}

test "execRaw - multiple statements" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    try execRaw("CREATE TEMP TABLE raw_test (id integer); INSERT INTO raw_test VALUES (1), (2), (3)");
    defer execRaw("DROP TABLE IF EXISTS raw_test") catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Row = struct { id: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM raw_test ORDER BY id", .{});
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqual(1, rows[0].id);
    try std.testing.expectEqual(3, rows[2].id);
}

test "transaction - commit" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE tx_test (id integer)");
    defer execRaw("DROP TABLE IF EXISTS tx_test") catch {};

    var tx = try begin();
    defer tx.rollback();

    try tx.query(void, arena.allocator(), "INSERT INTO tx_test VALUES ($1)", .{@as(i32, 99)});
    try tx.commit();

    const Row = struct { id: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM tx_test", .{});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expectEqual(99, rows[0].id);
}

test "queryOne - single row return" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE one_test (id integer, label text)");
    defer execRaw("DROP TABLE IF EXISTS one_test") catch {};

    try execRaw("INSERT INTO one_test VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma')");

    const Row = struct { id: i32, label: []const u8 };
    const row = try queryOne(Row, arena.allocator(), "SELECT id, label FROM one_test WHERE id = $1", .{@as(i32, 2)});
    try std.testing.expect(row != null);
    if (row) |r| {
        try std.testing.expectEqual(2, r.id);
        try std.testing.expectEqualStrings("beta", r.label);
    }

    const missing = try queryOne(Row, arena.allocator(), "SELECT id, label FROM one_test WHERE id = $1", .{@as(i32, 99)});
    try std.testing.expect(missing == null);
}

test "queryExecute - DDL statement" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try queryExecute(void, arena.allocator(), "CREATE TEMP TABLE ddl_test (x integer)");
    defer execRaw("DROP TABLE IF EXISTS ddl_test") catch {};

    try queryExecute(void, arena.allocator(), "INSERT INTO ddl_test VALUES (10), (20), (30)");

    const Row = struct { x: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT x FROM ddl_test ORDER BY x", .{});
    try std.testing.expectEqual(3, rows.len);
    try std.testing.expectEqual(10, rows[0].x);
    try std.testing.expectEqual(30, rows[2].x);
}

test "transaction - rollback" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE rb_test (id integer)");
    defer execRaw("DROP TABLE IF EXISTS rb_test") catch {};

    {
        var tx = try begin();
        try tx.query(void, arena.allocator(), "INSERT INTO rb_test VALUES ($1)", .{@as(i32, 42)});
        tx.rollback();
    }

    const Row = struct { id: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT id FROM rb_test", .{});
    try std.testing.expectEqual(0, rows.len);
}

test "Database bridge - exec via vtable" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var driver = PgDriver{};
    const db = driver.database();

    try db.exec("CREATE TEMP TABLE bridge_test (val integer)");
    defer execRaw("DROP TABLE IF EXISTS bridge_test") catch {};

    try db.exec("INSERT INTO bridge_test VALUES (100)");

    const Row = struct { val: i32 };
    const rows = try query(Row, arena.allocator(), "SELECT val FROM bridge_test", .{});
    try std.testing.expectEqual(1, rows.len);
    try std.testing.expectEqual(100, rows[0].val);
}

test "mapRow - i64 and optional fields" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE opt_test (bigval bigint, maybe text)");
    defer execRaw("DROP TABLE IF EXISTS opt_test") catch {};

    try execRaw("INSERT INTO opt_test VALUES (9000000000000, 'hello'), (42, NULL)");

    const Row = struct {
        bigval: i64,
        maybe: ?[]const u8,
    };

    const rows = try query(Row, arena.allocator(), "SELECT bigval, maybe FROM opt_test ORDER BY bigval", .{});
    try std.testing.expectEqual(2, rows.len);

    try std.testing.expectEqual(@as(i64, 42), rows[0].bigval);
    try std.testing.expect(rows[0].maybe == null);

    try std.testing.expectEqual(@as(i64, 9000000000000), rows[1].bigval);
    try std.testing.expectEqualStrings("hello", rows[1].maybe.?);
}

test "Config - defaults" {
    const cfg = Config{
        .host = "localhost",
        .port = 5432,
        .database = "mydb",
        .user = "myuser",
    };
    try std.testing.expectEqualStrings("localhost", cfg.host);
    try std.testing.expectEqual(@as(u16, 5432), cfg.port);
    try std.testing.expectEqualStrings("mydb", cfg.database);
    try std.testing.expectEqualStrings("myuser", cfg.user);
    try std.testing.expectEqual(@as(usize, 10), cfg.pool_size);
    try std.testing.expectEqual(@as(u64, 5000), cfg.timeout_ms);

    const dbcfg = DbConfig{};
    try std.testing.expect(dbcfg.host == null);
    try std.testing.expect(dbcfg.port == null);
    try std.testing.expect(dbcfg.database == null);
    try std.testing.expect(dbcfg.user == null);
    try std.testing.expect(dbcfg.password == null);
    try std.testing.expect(dbcfg.pool_size == null);
}

test "init and deinit lifecycle" {
    // init with explicit config, then deinit
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    try init(arena.allocator(), io, .{
        .host = null,
        .database = null,
        .user = null,
        .password = null,
    });
    defer deinit();

    // verify pool is active by running a query
    const result = try query(i32, arena.allocator(), "SELECT $1::integer", .{@as(i32, 77)});
    try std.testing.expectEqual(77, result);
}

test "array parameter - ANY() query" {
    try initTestDb(std.testing.allocator);
    defer deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("CREATE TEMP TABLE any_test (id integer, name text)");
    defer execRaw("DROP TABLE IF EXISTS any_test") catch {};

    try execRaw("INSERT INTO any_test VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four'), (5, 'five')");

    const ids = &[_]i32{ 2, 4 };
    const Row = struct { id: i32, name: []const u8 };
    const rows = try query(Row, arena.allocator(),
        "SELECT id, name FROM any_test WHERE id = ANY($1) ORDER BY id",
        .{ids.*},
    );
    try std.testing.expectEqual(2, rows.len);
    try std.testing.expectEqual(2, rows[0].id);
    try std.testing.expectEqualStrings("two", rows[0].name);
    try std.testing.expectEqual(4, rows[1].id);
    try std.testing.expectEqualStrings("four", rows[1].name);
}

// ── Transactions: pinned connection, no pool-level BEGIN/COMMIT ─────────────

fn countRows(arena: std.mem.Allocator, table: []const u8) !usize {
    const sql = try std.fmt.allocPrint(arena, "SELECT count(*)::integer FROM {s}", .{table});
    return @intCast(try query(i32, arena, sql, .{}));
}

test "fake transaction: pool-level BEGIN/ROLLBACK can't wrap later statements" {
    // The Orbitx pattern: pg.exec("BEGIN") ... pg.exec("ROLLBACK"). Each call
    // takes its own pooled connection, so the INSERT between them autocommits
    // and survives the ROLLBACK. Pool-level transaction control must be refused.
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("DROP TABLE IF EXISTS spider_fake_tx; CREATE TABLE spider_fake_tx (id integer)");
    defer execRaw("DROP TABLE IF EXISTS spider_fake_tx") catch {};

    if (exec("BEGIN", .{})) |_| {
        try exec("INSERT INTO spider_fake_tx VALUES (1)", .{});
        exec("ROLLBACK", .{}) catch {};
        const n = try countRows(arena.allocator(), "spider_fake_tx");
        std.debug.print("\n  pg.exec(\"BEGIN\") accepted; row count after ROLLBACK = {d} (expected 0 in a real transaction)\n", .{n});
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.UseBeginForTransactions, err);
    }
}

test "fake transaction: every pool-level entry point refuses transaction control" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stmts = [_][]const u8{ "BEGIN", "begin", "  BEGIN;", "START TRANSACTION", "BEGIN ISOLATION LEVEL SERIALIZABLE", "COMMIT", "END", "ROLLBACK", "abort", "SAVEPOINT s1", "RELEASE SAVEPOINT s1", "-- note\nBEGIN", "/* c */ COMMIT" };
    for (stmts) |sql| {
        try std.testing.expectError(error.UseBeginForTransactions, exec(sql, .{}));
        try std.testing.expectError(error.UseBeginForTransactions, query(void, a, sql, .{}));
        try std.testing.expectError(error.UseBeginForTransactions, queryOne(i32, a, sql, .{}));
        try std.testing.expectError(error.UseBeginForTransactions, queryOneExecute(i32, a, sql));
        try std.testing.expectError(error.UseBeginForTransactions, queryWith(sql, .{}));
    }
}

test "fake transaction: multi-statement calls must be balanced on their one connection" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("DROP TABLE IF EXISTS spider_multi_tx; CREATE TABLE spider_multi_tx (id integer)");
    defer execRaw("DROP TABLE IF EXISTS spider_multi_tx") catch {};

    // Balanced: runs on one connection, genuinely transactional.
    try queryExecute(void, arena.allocator(), "BEGIN; INSERT INTO spider_multi_tx VALUES (1); INSERT INTO spider_multi_tx VALUES (2); COMMIT");
    try std.testing.expectEqual(@as(usize, 2), try countRows(arena.allocator(), "spider_multi_tx"));
    try execRaw("BEGIN; INSERT INTO spider_multi_tx VALUES (3); ROLLBACK");
    try std.testing.expectEqual(@as(usize, 2), try countRows(arena.allocator(), "spider_multi_tx"));

    // Unbalanced: would hand an in-transaction connection back to the pool.
    try std.testing.expectError(error.UseBeginForTransactions, execRaw("BEGIN; INSERT INTO spider_multi_tx VALUES (4)"));
    try std.testing.expectError(error.UseBeginForTransactions, queryExecute(void, arena.allocator(), "INSERT INTO spider_multi_tx VALUES (5); COMMIT"));
    try std.testing.expectEqual(@as(usize, 2), try countRows(arena.allocator(), "spider_multi_tx"));
}

test "begin(): statements share one pinned connection and are invisible until commit" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try execRaw("DROP TABLE IF EXISTS spider_pin_tx; CREATE TABLE spider_pin_tx (id integer)");
    defer execRaw("DROP TABLE IF EXISTS spider_pin_tx") catch {};

    var tx = try begin();
    defer tx.rollback();
    const pid_1 = try tx.queryOne(i32, a, "SELECT pg_backend_pid()", .{});
    try tx.query(void, a, "INSERT INTO spider_pin_tx VALUES (1)", .{});
    const pid_2 = try tx.queryOne(i32, a, "SELECT pg_backend_pid()", .{});
    try std.testing.expectEqual(pid_1.?, pid_2.?);

    // Another pooled connection must not see the uncommitted row.
    try std.testing.expectEqual(@as(usize, 0), try countRows(a, "spider_pin_tx"));
    // The transaction itself does.
    try std.testing.expectEqual(@as(i32, 1), (try tx.queryOne(i32, a, "SELECT count(*)::integer FROM spider_pin_tx", .{})).?);

    try tx.commit();
    try std.testing.expectEqual(@as(usize, 1), try countRows(a, "spider_pin_tx"));
}

test "begin(): commit twice is an error, rollback after commit is a no-op" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var tx = try begin();
    try tx.commit();
    try std.testing.expectError(error.TransactionAlreadyFinished, tx.commit());
    tx.rollback();
}

test "begin(): failed statement aborts the tx; rollback returns the SAME connection clean" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pid_in_tx: i32 = 0;
    {
        var tx = try begin();
        defer tx.rollback();
        pid_in_tx = (try tx.queryOne(i32, a, "SELECT pg_backend_pid()", .{})).?;
        try std.testing.expectError(error.PG, tx.query(void, a, "SELECT 1/0", .{}));
        // Postgres refuses everything until the transaction ends; say so clearly.
        try std.testing.expectError(error.TransactionAborted, tx.query(void, a, "SELECT 1", .{}));
        try std.testing.expectError(error.TransactionAborted, tx.queryOne(i32, a, "SELECT 1", .{}));
        try std.testing.expectError(error.TransactionAborted, tx.commit());
    }
    // The pool is LIFO: the next acquire gets the connection just released.
    // Same backend pid == it was rolled back and reused, not torn down and
    // reconnected (what happened when rollback sent ROLLBACK via exec()).
    const pid_after = try query(i32, a, "SELECT pg_backend_pid()", .{});
    try std.testing.expectEqual(pid_in_tx, pid_after);
    for (0..20) |_| try std.testing.expectEqual(@as(i32, 7), try query(i32, a, "SELECT 7", .{}));
}

const TxInput = struct { a: i32, b: i32 };

fn insertPair(tx: *Transaction, in: TxInput) !i32 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tx.query(void, arena.allocator(), "INSERT INTO spider_helper_tx VALUES ($1)", .{in.a});
    try tx.query(void, arena.allocator(), "INSERT INTO spider_helper_tx VALUES ($1)", .{in.b});
    return in.a + in.b;
}

fn insertThenFail(tx: *Transaction, in: TxInput) !i32 {
    _ = try insertPair(tx, in);
    return error.BusinessRuleViolated;
}

test "transaction(): commits on success and returns the body's value" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("DROP TABLE IF EXISTS spider_helper_tx; CREATE TABLE spider_helper_tx (id integer)");
    defer execRaw("DROP TABLE IF EXISTS spider_helper_tx") catch {};

    const sum = try transaction(i32, TxInput{ .a = 1, .b = 2 }, insertPair);
    try std.testing.expectEqual(@as(i32, 3), sum);
    try std.testing.expectEqual(@as(usize, 2), try countRows(arena.allocator(), "spider_helper_tx"));
}

test "transaction(): rolls back everything when the body returns an error" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try execRaw("DROP TABLE IF EXISTS spider_helper_tx; CREATE TABLE spider_helper_tx (id integer)");
    defer execRaw("DROP TABLE IF EXISTS spider_helper_tx") catch {};

    try std.testing.expectError(error.BusinessRuleViolated, transaction(i32, TxInput{ .a = 1, .b = 2 }, insertThenFail));
    try std.testing.expectEqual(@as(usize, 0), try countRows(arena.allocator(), "spider_helper_tx"));
}

test "txControl: classifier" {
    try std.testing.expectEqual(TxControl.open, txControl("BEGIN"));
    try std.testing.expectEqual(TxControl.open, txControl("\n\t begin work"));
    try std.testing.expectEqual(TxControl.open, txControl("START TRANSACTION READ ONLY"));
    try std.testing.expectEqual(TxControl.close, txControl("commit"));
    try std.testing.expectEqual(TxControl.close, txControl("END"));
    try std.testing.expectEqual(TxControl.close, txControl("ROLLBACK"));
    try std.testing.expectEqual(TxControl.close, txControl("abort;"));
    try std.testing.expectEqual(TxControl.inside, txControl("SAVEPOINT a"));
    try std.testing.expectEqual(TxControl.inside, txControl("ROLLBACK TO SAVEPOINT a"));
    try std.testing.expectEqual(TxControl.inside, txControl("release a"));
    try std.testing.expectEqual(TxControl.open, txControl("-- c\n/* d */ BEGIN"));
    // Not transaction control:
    try std.testing.expectEqual(TxControl.none, txControl("COMMIT PREPARED 'x'"));
    try std.testing.expectEqual(TxControl.none, txControl("ROLLBACK PREPARED 'x'"));
    try std.testing.expectEqual(TxControl.none, txControl("SELECT 'BEGIN'"));
    try std.testing.expectEqual(TxControl.none, txControl("DO $$ BEGIN PERFORM 1; END $$"));
    try std.testing.expectEqual(TxControl.none, txControl("BEGINNING"));
    try std.testing.expectEqual(TxControl.none, txControl("INSERT INTO t VALUES ('commit')"));
    try std.testing.expectEqual(TxControl.none, txControl("start"));
    try std.testing.expectEqual(TxControl.none, txControl(""));
    try std.testing.expectEqual(TxControl.none, txControl("/* unterminated"));
}

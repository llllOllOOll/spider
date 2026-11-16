//! Microsoft SQL Server for an app (`spider.mssql`, opt-in with
//! `-Dmssql=true`): a pool of connections opened by `init`, then `query`,
//! `queryOne`, `queryExecute` and `begin` from anywhere. The same calls as
//! `spider.pg`; rows come back as structs whose fields are matched to columns
//! by name. The driver underneath speaks TDS 7.4 natively (SQL Server 2012
//! and later, Azure SQL), with TLS from Zig's standard library.
//!
//! Parameters are written `@p1`, `@p2`... (not `$1`: in T-SQL `$5` is a money
//! literal) and travel apart from the SQL text, through `sp_executesql`.

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("mssql");
const Conn = driver.Conn;
const Value = driver.Value;

const env = @import("spider").env;

// ── Config ──────────────────────────────────────────────────────────────────

/// The options of `init`. A field left null comes from the environment
/// (the `.env` files included), then from a built-in default.
pub const DbConfig = struct {
    /// Server address. null: `MSSQL_HOST`, or "localhost".
    host: ?[]const u8 = null,
    /// Server port. null: `MSSQL_PORT`, or 1433.
    port: ?u16 = null,
    /// Database name. null: `MSSQL_DB`, or "master".
    database: ?[]const u8 = null,
    /// SQL login. null: `MSSQL_USER`, or "sa".
    user: ?[]const u8 = null,
    /// null: `MSSQL_PASSWORD`, or "".
    password: ?[]const u8 = null,
    /// Connections kept open. null: `MSSQL_POOL_SIZE`, or 10.
    pool_size: ?usize = null,
    /// TLS for the whole session. null: `MSSQL_ENCRYPT`, or true. false is
    /// refused by a server that forces encryption.
    encrypt: ?bool = null,
    /// Accept the server's certificate without checking it, as a SQL Server
    /// with its own self-signed certificate needs (the default install, the
    /// Docker image). null: `MSSQL_TRUST_SERVER_CERTIFICATE`, or false: the
    /// certificate must chain to a root the system trusts and name the host.
    trust_server_certificate: ?bool = null,
    /// The name the server's certificate must carry, when it is not `host`
    /// (connecting by IP address). null: `MSSQL_CERTIFICATE_HOST`, or `host`.
    certificate_host: ?[]const u8 = null,
    /// What typed mapping does with a column missing from the result or a
    /// NULL in a non-optional field: the same rule as `spider.pg`.
    mapping: MappingMode = .fail,
};

/// The values of `DbConfig.mapping`. `.fail` returns error.ColumnMissing /
/// error.UnexpectedNull (fields with a declared default use it either way);
/// `.warn` logs it once per field and keeps the zero value (0, "", false).
pub const MappingMode = enum { fail, warn };

var db_pool: ?*driver.Pool = null;
var mapping_mode: MappingMode = .fail;

/// Opens the connection pool. Call it once at startup, before any query,
/// and `deinit()` at exit. `allocator` and `io` must outlive the pool.
///
/// A server that can't be reached is tried five times in all, waiting 1, 2,
/// 4 and 8 seconds (a SQL Server container takes a while to start). A
/// refusal from the server itself (wrong password, unknown database, a
/// certificate that is not accepted) is returned at once: error.LoginFailed,
/// with the server's message in the log.
///
/// ```zig
/// try spider.mssql.init(allocator, io, .{});
/// defer spider.mssql.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    mapping_mode = overrides.mapping;
    const host = overrides.host orelse env.getOr("MSSQL_HOST", "localhost");
    const port = overrides.port orelse env.getInt(u16, "MSSQL_PORT", 1433);
    const size = overrides.pool_size orelse env.getInt(usize, "MSSQL_POOL_SIZE", 10);
    const opts: driver.Options = .{
        .host = host,
        .port = port,
        .user = overrides.user orelse env.getOr("MSSQL_USER", "sa"),
        .password = overrides.password orelse env.getOr("MSSQL_PASSWORD", ""),
        .database = overrides.database orelse env.getOr("MSSQL_DB", "master"),
        .encrypt = if (overrides.encrypt orelse env.getBool("MSSQL_ENCRYPT", true)) .on else .off,
        .trust_server_certificate = overrides.trust_server_certificate orelse
            env.getBool("MSSQL_TRUST_SERVER_CERTIFICATE", false),
        .certificate_host = overrides.certificate_host orelse env.get("MSSQL_CERTIFICATE_HOST"),
        .app_name = "spider",
        .xact_abort = true,
    };

    var delay_ms: i64 = 1000;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        db_pool = driver.Pool.init(allocator, io, opts, size) catch |err| {
            if (attempt == 5 or !unreachableServer(err)) {
                std.log.err("mssql: cannot connect to {s}:{d}: {t}", .{ host, port, err });
                return err;
            }
            std.log.warn("mssql: connect attempt {d}/5 failed ({t}), retrying in {d}ms", .{ attempt, err, delay_ms });
            try std.Io.sleep(io, .fromMilliseconds(delay_ms), .real);
            delay_ms *= 2;
            continue;
        };
        std.log.info("mssql: connected to {s}:{d} ({d} connections)", .{ host, port, size });
        return;
    }
}

/// The server did not answer at all (as opposed to answering no).
fn unreachableServer(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.EndOfStream,
        error.ReadFailed,
        error.WriteFailed,
        error.UnknownHostName,
        error.NameServerFailure,
        => true,
        else => false,
    };
}

// internal: whether init() opened the pool.
pub fn isInitialized() bool {
    return db_pool != null;
}

/// Closes the pool. No query may run after it.
pub fn deinit() void {
    if (db_pool) |p| p.deinit();
    db_pool = null;
}

fn pool() !*driver.Pool {
    return db_pool orelse error.MssqlNotInitialized;
}

/// What `query(T, ...)` returns: nothing for `void`, one value for `i32`
/// and `i64`, a slice `[]T` for a struct.
pub fn QueryResult(comptime T: type) type {
    return switch (T) {
        void => void,
        i32, i64 => T,
        else => []T,
    };
}

// ── Errors ──────────────────────────────────────────────────────────────────

/// SQL Server failures, by error number, with the names `spider.pg` gives
/// the same failures. `error.MSSQL` remains for numbers not listed here.
/// Use `lastError()` in the catch for the number and the message.
pub const DbError = error{
    UniqueViolation, // 2627, 2601
    ForeignKeyViolation, // 547 (FOREIGN KEY / REFERENCE constraint)
    NotNullViolation, // 515
    CheckViolation, // 547 (CHECK constraint)
    InvalidTextRepresentation, // 245, 8114, 8169: "abc" into an int, a uniqueidentifier...
    StringDataRightTruncation, // 2628, 8152
    NumericValueOutOfRange, // 220, 232, 8115
    InvalidDatetimeFormat, // 241
    DatetimeFieldOverflow, // 242, 517
    DivisionByZero, // 8134
    DeadlockDetected, // 1205
    LockNotAvailable, // 1222
    QueryCanceled, // 3617
    UndefinedTable, // 208
    UndefinedColumn, // 207
    UndefinedFunction, // 195, 2812, 4121
    SqlSyntaxError, // 102, 105, 156, 170
    InsufficientPrivilege, // 229, 230, 262, 300
    RaisedException, // 50000 and above: RAISERROR / THROW with a message of the app's
    MSSQL,
};

/// Typed-mapping failures: what a row can fail to give a struct.
/// error.ColumnMissing: no column with the field's name. error.UnexpectedNull:
/// a NULL where the field is neither optional nor has a default.
/// error.TypeMismatch: the column's type cannot become the field's type (a
/// date into an integer, 1.5 into an integer). error.IntegerOverflow: the
/// number does not fit the field. An unknown enum label is
/// error.InvalidEnumValue, which is not part of this set.
pub const MappingError = error{ ColumnMissing, UnexpectedNull, TypeMismatch, IntegerOverflow };

/// The `DbError` for a SQL Server error number and its message (547 is both
/// foreign key and check constraint; the message says which).
pub fn errorForNumber(number: i32, message: []const u8) DbError {
    return switch (number) {
        2627, 2601 => error.UniqueViolation,
        547 => if (std.mem.indexOf(u8, message, "CHECK constraint") != null)
            error.CheckViolation
        else
            error.ForeignKeyViolation,
        515 => error.NotNullViolation,
        245, 8114, 8169 => error.InvalidTextRepresentation,
        2628, 8152 => error.StringDataRightTruncation,
        220, 232, 8115 => error.NumericValueOutOfRange,
        241 => error.InvalidDatetimeFormat,
        242, 517 => error.DatetimeFieldOverflow,
        8134 => error.DivisionByZero,
        1205 => error.DeadlockDetected,
        1222 => error.LockNotAvailable,
        3617 => error.QueryCanceled,
        208 => error.UndefinedTable,
        207 => error.UndefinedColumn,
        195, 2812, 4121 => error.UndefinedFunction,
        102, 105, 156, 170 => error.SqlSyntaxError,
        229, 230, 262, 300 => error.InsufficientPrivilege,
        else => if (number >= 50000) error.RaisedException else error.MSSQL,
    };
}

/// True when `err` is one of the errors of `DbError`: a failure reported by
/// SQL Server itself, as opposed to a mapping error or a lost connection.
pub fn isDbError(err: anyerror) bool {
    inline for (@typeInfo(DbError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

/// Details of the last SQL Server error raised on this thread, as
/// `lastError` returns them. The strings live in a per-thread buffer of
/// 2048 bytes (longer texts are cut) that the next error on the thread
/// overwrites: copy what must be kept.
pub const ErrorInfo = struct {
    /// The error number as text, e.g. "2627" (the field `spider.pg` calls
    /// the SQLSTATE).
    code: []const u8,
    /// The error number, e.g. 2627 for a duplicate key.
    number: i32,
    /// Severity: 11 to 16 are the caller's mistakes (a constraint, a
    /// conversion, a syntax error), 17 and above the server's trouble.
    class: u8,
    state: u8,
    /// Can contain row values (the duplicate key, for one): not for end users.
    message: []const u8,
    /// The stored procedure or trigger that raised it, if any.
    procedure: ?[]const u8,
    line: u32,
};

const ErrorStore = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,
    code_buf: [12]u8 = undefined,
    info: ErrorInfo = undefined,
    set: bool = false,

    fn keep(self: *ErrorStore, v: []const u8) []const u8 {
        const n = @min(v.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], v[0..n]);
        defer self.len += n;
        return self.buf[self.len..][0..n];
    }
};

threadlocal var last_error: ErrorStore = .{};

/// Details (number, message, procedure, line) of the SQL Server error that
/// the mssql.* call which just failed returned. Read it in the `catch`,
/// before any other query: it is per-thread and the next failing call on
/// this thread replaces it. `message` can contain row values (a duplicate
/// email, for one) — don't show it to end users.
///
/// null while no SQL Server error happened on this thread. It is only set by
/// a `DbError`, and a call that succeeds does not clear it.
pub fn lastError() ?ErrorInfo {
    return if (last_error.set) last_error.info else null;
}

fn recordError(m: driver.ServerMessage) void {
    last_error = .{};
    const code = std.fmt.bufPrint(&last_error.code_buf, "{d}", .{m.number}) catch "";
    last_error.info = .{
        .code = code,
        .number = m.number,
        .class = m.class,
        .state = m.state,
        .message = last_error.keep(m.message),
        .procedure = if (m.procedure.len > 0) last_error.keep(m.procedure) else null,
        .line = m.line,
    };
    last_error.set = true;
}

/// Every SQL Server failure goes through here: records lastError(), logs ONE
/// line (warn for the caller's mistakes, class 16 and below; err above) and
/// returns the typed error. Other errors (connection, mapping, OOM...) pass
/// through.
// internal: turns a driver error into the typed one, logging the server's message.
pub fn fail(conn: *Conn, err: anyerror) anyerror {
    if (err != error.ServerError) return err;
    const m = conn.last_error orelse return error.MSSQL;
    recordError(m);
    const typed = errorForNumber(m.number, m.message);
    if (m.class <= 16 or builtin.is_test)
        std.log.warn("mssql: {s} ({d}): {s}", .{ @errorName(typed), m.number, m.message })
    else
        std.log.err("mssql: {s} ({d}, class {d}): {s}", .{ @errorName(typed), m.number, m.class, m.message });
    return typed;
}

// ── Decoding a value into a field ───────────────────────────────────────────

/// A column value as text: strings as they are, numbers in decimal, bit as
/// "true"/"false", dates and times in ISO 8601 ("2026-09-26",
/// "2026-09-26T18:40:33.183", "2026-09-26T18:40:33-03:00"), a
/// uniqueidentifier as SQL Server prints it, binary as its bytes.
fn textOf(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "",
        .string, .bytes => |s| arena.dupe(u8, s),
        .boolean => |b| if (b) "true" else "false",
        .date => |d| std.fmt.allocPrint(arena, "{f}", .{Value{ .date = d }}),
        .time => |t| std.fmt.allocPrint(arena, "{f}", .{Value{ .time = t }}),
        .datetime => |dt| std.fmt.allocPrint(arena, "{f}T{f}", .{ Value{ .date = dt.date }, Value{ .time = dt.time } }),
        .datetimeoffset => |dt| blk: {
            const off: u16 = @abs(dt.offset_minutes);
            break :blk std.fmt.allocPrint(arena, "{f}T{f}{c}{d:0>2}:{d:0>2}", .{
                Value{ .date = dt.date },
                Value{ .time = dt.time },
                @as(u8, if (dt.offset_minutes < 0) '-' else '+'),
                off / 60,
                off % 60,
            });
        },
        .int, .float, .decimal, .guid => std.fmt.allocPrint(arena, "{f}", .{v}),
    };
}

fn intFrom(comptime I: type, v: Value) !I {
    const wide: i128 = switch (v) {
        .int => |i| i,
        // SUM()/AVG() and decimal columns: integral values only.
        .decimal => |d| blk: {
            const pow = std.math.powi(i128, 10, d.scale) catch return error.TypeMismatch;
            if (@rem(d.value, pow) != 0) return error.TypeMismatch;
            break :blk @divTrunc(d.value, pow);
        },
        // A number written as text (a CAST to varchar, a JSON value...).
        .string => |s| std.fmt.parseInt(i128, std.mem.trim(u8, s, " "), 10) catch return error.TypeMismatch,
        else => return error.TypeMismatch,
    };
    return std.math.cast(I, wide) orelse error.IntegerOverflow;
}

fn floatFrom(comptime F: type, v: Value) !F {
    return switch (v) {
        .float => |f| @floatCast(f),
        .int => |i| @floatFromInt(i),
        .decimal => |d| @floatCast(d.toFloat()),
        .string => |s| @floatCast(std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return error.TypeMismatch),
        else => error.TypeMismatch,
    };
}

fn decodeField(comptime T: type, v: Value, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) return try decodeField(info.optional.child, v, arena);
    if (info == .@"enum") {
        if (v != .string) return error.TypeMismatch;
        return std.meta.stringToEnum(T, v.string) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try textOf(arena, v),
        bool => switch (v) {
            .boolean => |b| b,
            .int => |i| i != 0,
            else => error.TypeMismatch,
        },
        i8, i16, i32, i64, u8, u16, u32, u64 => try intFrom(T, v),
        f32, f64 => try floatFrom(T, v),
        else => @compileError("spider.mssql: unsupported field type " ++ @typeName(T)),
    };
}

fn zeroValue(comptime T: type) T {
    const info = @typeInfo(T);
    if (info == .optional) return null;
    if (info == .@"enum") return @fromBackingInt(@intCast(0));
    return switch (T) {
        []const u8 => "",
        bool => false,
        i8, i16, i32, i64, u8, u16, u32, u64 => 0,
        f32, f64 => 0.0,
        else => @compileError("spider.mssql: unsupported field type " ++ @typeName(T)),
    };
}

// ── Mapping a row to a struct ───────────────────────────────────────────────

fn sqlHead(sql: []const u8) []const u8 {
    const t = std.mem.trim(u8, sql, " \t\r\n");
    return t[0..@min(t.len, 80)];
}

/// One flag per struct field, for `.warn`: a field's issue is logged once
/// per process, not on every call.
fn WarnedOnce(comptime T: type, comptime field: []const u8) type {
    return struct {
        comptime {
            _ = T;
            _ = field;
        }
        var flag = std.atomic.Value(bool).init(false);
    };
}

noinline fn reportMappingIssue(err: MappingError, type_name: []const u8, field: []const u8, sql: []const u8, warned: *std.atomic.Value(bool)) MappingError!void {
    switch (mapping_mode) {
        .fail => {
            const format = "[mssql] {s} mapping {s}.{s} for \"{s}\": make the field optional, give it a default, or select the column";
            const args = .{ @errorName(err), type_name, field, sqlHead(sql) };
            if (builtin.is_test) std.log.warn(format, args) else std.log.err(format, args);
            return err;
        },
        .warn => if (!warned.swap(true, .monotonic)) {
            std.log.warn("[mssql] {s} mapping {s}.{s} for \"{s}\" (DbConfig.mapping = .warn: using the zero value; logged once)", .{ @errorName(err), type_name, field, sqlHead(sql) });
        },
    }
}

/// The column of each field of `T`: the one with the field's name, or else
/// the one whose name differs only in letter case (SQL Server compares
/// names without case, so `Nome` and `nome` are the same column).
fn ColumnIndexes(comptime T: type) type {
    return [@typeInfo(T).@"struct".field_names.len]?usize;
}

fn columnIndexes(comptime T: type, columns: []const driver.Column) ColumnIndexes(T) {
    var out: ColumnIndexes(T) = undefined;
    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, f| {
        out[f] = null;
        for (columns, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) {
            out[f] = i;
            break;
        };
        if (out[f] == null) for (columns, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c.name, name)) {
            out[f] = i;
            break;
        };
    }
    return out;
}

fn mapRow(comptime T: type, idx: *const ColumnIndexes(T), row: []const Value, arena: std.mem.Allocator, sql: []const u8) !T {
    var item: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldT, attrs, f| {
        @field(item, name) = try mapField(
            FieldT,
            comptime attrs.defaultValue(FieldT),
            if (idx[f]) |i| row[i] else null,
            arena,
            sql,
            @typeName(T),
            name,
            &WarnedOnce(T, name).flag,
        );
    }
    return item;
}

/// The value of one field: its column decoded, or null / the default / the
/// mapping rule when the column is missing (`cell` null) or NULL.
fn mapField(
    comptime FieldT: type,
    comptime default: ?FieldT,
    cell: ?Value,
    arena: std.mem.Allocator,
    sql: []const u8,
    type_name: []const u8,
    field: []const u8,
    warned: *std.atomic.Value(bool),
) !FieldT {
    const is_optional = @typeInfo(FieldT) == .optional;
    const v = cell orelse {
        if (is_optional) return null;
        if (default) |d| return d;
        try reportMappingIssue(error.ColumnMissing, type_name, field, sql, warned);
        return zeroValue(FieldT);
    };
    if (v == .null) {
        if (is_optional) return null;
        if (default) |d| return d;
        try reportMappingIssue(error.UnexpectedNull, type_name, field, sql, warned);
        return zeroValue(FieldT);
    }
    return decodeField(FieldT, v, arena) catch |err| {
        const e: anyerror = err;
        if (e != error.TypeMismatch and e != error.IntegerOverflow and e != error.InvalidEnumValue) return err;
        std.log.warn("[mssql] {s} decoding {s}.{s} (a {t} value) for \"{s}\"", .{ @errorName(err), type_name, field, v, sqlHead(sql) });
        if (mapping_mode == .warn) return zeroValue(FieldT);
        return err;
    };
}

// ── Running statements ──────────────────────────────────────────────────────

fn execTyped(conn: *Conn, comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
    if (T == void) {
        _ = conn.execArgs(sql, params) catch |err| return fail(conn, err);
        return;
    }
    var rows = conn.queryArgs(sql, params) catch |err| return fail(conn, err);
    defer rows.deinit();

    if (T == i32 or T == i64) {
        const row = (rows.next() catch |err| return fail(conn, err)) orelse return 0;
        const v: T = if (row.len == 0 or row[0] == .null) 0 else try decodeField(T, row[0], arena);
        // The rest of the reply: an error in a later statement still counts.
        while (rows.nextResult() catch |err| return fail(conn, err)) {}
        return v;
    }

    const idx = columnIndexes(T, rows.columns);
    var items: std.ArrayList(T) = .empty;
    // Errors can also arrive mid-stream (a division by zero on row N).
    while (rows.next() catch |err| return fail(conn, err)) |row| {
        try items.append(arena, try mapRow(T, &idx, row, arena, sql));
    }
    while (rows.nextResult() catch |err| return fail(conn, err)) {}
    return try items.toOwnedSlice(arena);
}

fn execTypedOne(conn: *Conn, comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
    var rows = conn.queryArgs(sql, params) catch |err| return fail(conn, err);
    defer rows.deinit();
    const row = (rows.next() catch |err| return fail(conn, err)) orelse {
        while (rows.nextResult() catch |err| return fail(conn, err)) {}
        return null;
    };
    const out: ?T = if (T == i32 or T == i64)
        (if (row.len == 0 or row[0] == .null) null else try decodeField(T, row[0], arena))
    else blk: {
        const idx = columnIndexes(T, rows.columns);
        break :blk try mapRow(T, &idx, row, arena, sql);
    };
    while (rows.nextResult() catch |err| return fail(conn, err)) {}
    return out;
}

/// Runs a statement with `@p1`, `@p2`... parameters on a connection of the
/// pool and gives back what `T` asks for:
/// - a struct: every row of the first result set as a `[]T` allocated in
///   `arena`. A field takes the column of the same name (or, failing that,
///   the one whose name differs only in case). Fields may be `[]const u8`,
///   `bool`, integers (`i8` to `i64`, `u8` to `u64`), `f32`, `f64`, enums
///   (a column holding the label) and optionals of those. A `[]const u8`
///   field accepts any column: numbers and decimal in decimal, bit as
///   "true"/"false", date, time, datetime and datetime2 in ISO 8601
///   ("2026-09-26T18:40:33.183"), datetimeoffset with its offset
///   ("2026-09-26T18:40:33-03:00"), a uniqueidentifier as SQL Server prints
///   it, binary as its bytes.
/// - `i32` or `i64`: the first column of the first row; 0 when there is no
///   row or the value is NULL.
/// - `void`: nothing; for INSERT, UPDATE and DELETE.
///
/// Parameters come from a tuple: integers, floats, bools, strings, enums
/// (sent as their name), null and optionals. Strings go as nvarchar(max),
/// which SQL Server converts where a date or a decimal is expected.
///
/// Fails with:
/// - a `DbError` when SQL Server refuses the statement (`lastError()` has
///   the details), e.g. error.UniqueViolation;
/// - a `MappingError` when a row does not fit `T`: error.ColumnMissing and
///   error.UnexpectedNull (a field that is neither optional nor has a
///   default; see `DbConfig.mapping`), error.TypeMismatch,
///   error.IntegerOverflow; error.InvalidEnumValue for an unknown enum label;
/// - error.UseBeginForTransactions for BEGIN TRANSACTION, COMMIT, ROLLBACK
///   or SAVE TRANSACTION: each call may run on a different connection. Use
///   `begin()`.
///
/// ```zig
/// const posts = try spider.mssql.query(Post, c.arena, "SELECT id, title FROM posts WHERE author_id = @p1", .{author_id});
/// const total = try spider.mssql.query(i64, c.arena, "SELECT COUNT(*) FROM posts", .{});
/// try spider.mssql.query(void, c.arena, "DELETE FROM posts WHERE id = @p1", .{id});
/// ```
pub fn query(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
    try guard(sql);
    const p = try pool();
    const conn = try p.acquire();
    defer p.release(conn);
    return execTyped(conn, T, arena, sql, params);
}

/// The first row of a statement, or null when it returns no row. `T` is a
/// struct, mapped as in `query`, or `i32`/`i64` for the first column (null
/// when that value is NULL). Further rows are discarded. Fails as `query`.
///
/// ```zig
/// const post = try spider.mssql.queryOne(Post, c.arena, "SELECT id, title FROM posts WHERE id = @p1", .{id}) orelse return error.NotFound;
/// ```
pub fn queryOne(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
    try guard(sql);
    const p = try pool();
    const conn = try p.acquire();
    defer p.release(conn);
    return execTypedOne(conn, T, arena, sql, params);
}

/// Runs a script without parameters (DDL, migrations, seed data).
///
/// With `void` as `T` the script is cut into batches at the lines that hold
/// only `GO`, as sqlcmd and SSMS do (CREATE PROCEDURE, VIEW, TRIGGER and
/// FUNCTION must each be alone in a batch), and the batches run in order on
/// one connection, stopping at the first that fails. Within a batch an
/// error ends the batch. A transaction the script opened itself and left
/// open by the failure is rolled back. With another `T` it is `query` for
/// one statement without parameters.
///
/// ```zig
/// try spider.mssql.queryExecute(void, arena,
///     \\IF OBJECT_ID('dbo.posts') IS NULL
///     \\CREATE TABLE dbo.posts (id int IDENTITY PRIMARY KEY, title nvarchar(200) NOT NULL)
/// );
/// ```
pub fn queryExecute(comptime T: type, arena: std.mem.Allocator, sql: []const u8) !QueryResult(T) {
    if (T != void) try guard(sql);
    const p = try pool();
    const conn = try p.acquire();
    defer p.release(conn);
    if (T == void) return runScript(conn, sql);
    return execTyped(conn, T, arena, sql, .{});
}

/// The first row of one statement without parameters:
/// `queryOne(T, arena, sql, .{})`.
pub fn queryOneExecute(comptime T: type, arena: std.mem.Allocator, sql: []const u8) !?T {
    return queryOne(T, arena, sql, .{});
}

fn runScript(conn: *Conn, sql: []const u8) !void {
    var it: Batches = .{ .sql = sql };
    while (it.next()) |batch| {
        _ = conn.exec(batch) catch |err| {
            const failure = fail(conn, err);
            if (!conn.broken and conn.inTransaction()) _ = conn.exec("IF @@TRANCOUNT > 0 ROLLBACK") catch {};
            return failure;
        };
    }
}

/// The batches of a script, cut at the lines that hold only `GO` (any
/// letter case, spaces around). A `GO` inside a string or a /* comment */
/// does not cut. Empty batches are skipped.
// internal: pub for the tests.
pub const Batches = struct {
    sql: []const u8,
    pos: usize = 0,

    pub fn next(self: *Batches) ?[]const u8 {
        while (self.pos < self.sql.len) {
            const start = self.pos;
            const end = self.findGo(start);
            const batch = std.mem.trim(u8, self.sql[start..end.batch_end], " \t\r\n");
            self.pos = end.resume_at;
            if (batch.len > 0) return batch;
        }
        return null;
    }

    const Cut = struct { batch_end: usize, resume_at: usize };

    fn findGo(self: *Batches, from: usize) Cut {
        const s = self.sql;
        var i = from;
        var in_string = false;
        var comment_depth: usize = 0;
        var line_start = true;
        while (i < s.len) {
            if (line_start and !in_string and comment_depth == 0) {
                const eol = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, s[i..eol], " \t\r"), "GO"))
                    return .{ .batch_end = i, .resume_at = @min(eol + 1, s.len) };
            }
            line_start = false;
            const c = s[i];
            if (in_string) {
                if (c == '\'') in_string = false; // '' re-enters at once
            } else if (comment_depth > 0) {
                if (c == '*' and i + 1 < s.len and s[i + 1] == '/') {
                    comment_depth -= 1;
                    i += 1;
                } else if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                    comment_depth += 1;
                    i += 1;
                }
            } else if (c == '\'') {
                in_string = true;
            } else if (c == '/' and i + 1 < s.len and s[i + 1] == '*') {
                comment_depth += 1;
                i += 1;
            } else if (c == '-' and i + 1 < s.len and s[i + 1] == '-') {
                i = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
                continue;
            }
            if (c == '\n') line_start = true;
            i += 1;
        }
        return .{ .batch_end = s.len, .resume_at = s.len };
    }
};

// ── Transactions ────────────────────────────────────────────────────────────

/// A transaction on one connection, made by `begin()`. End it with
/// `commit()` or `rollback()`; a call after the first does nothing.
///
/// The session runs with XACT_ABORT ON: a failing statement rolls the whole
/// transaction back at once (as in Postgres, nothing after it can commit).
///
/// ```zig
/// var tx = try spider.mssql.begin();
/// defer tx.rollback();
/// try tx.query(void, c.arena, "INSERT INTO posts (title) VALUES (@p1)", .{title});
/// try tx.commit();
/// ```
pub const Transaction = struct {
    /// The connection the transaction runs on.
    conn: *Conn,
    /// The transaction was committed or rolled back and its connection went
    /// back to the pool.
    finished: bool = false,

    /// The same as the module's `query`, inside this transaction.
    pub fn query(self: *Transaction, comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
        try guard(sql);
        return execTyped(self.conn, T, arena, sql, params);
    }

    /// The same as the module's `queryOne`, inside this transaction.
    pub fn queryOne(self: *Transaction, comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
        try guard(sql);
        return execTypedOne(self.conn, T, arena, sql, params);
    }

    /// `query(void, ...)` without the allocator argument.
    pub fn exec(self: *Transaction, sql: []const u8, params: anytype) !void {
        try self.query(void, undefined, sql, params);
    }

    /// Commits and gives the connection back. When the commit fails, the
    /// error is returned and `rollback()` still gives the connection back.
    pub fn commit(self: *Transaction) !void {
        if (self.finished) return;
        _ = self.conn.exec("COMMIT TRANSACTION") catch |err| return fail(self.conn, err);
        self.finished = true;
        (pool() catch unreachable).release(self.conn);
    }

    /// Undoes everything since `begin()` and gives the connection back.
    /// After a `commit()` or another `rollback()` it does nothing, so
    /// `defer tx.rollback()` right after `begin()` is safe.
    pub fn rollback(self: *Transaction) void {
        if (self.finished) return;
        self.finished = true;
        if (!self.conn.broken) _ = self.conn.exec("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION") catch {};
        (pool() catch unreachable).release(self.conn);
    }
};

/// Starts a transaction: takes a connection from the pool, sends BEGIN
/// TRANSACTION and keeps the connection for the `Transaction` until
/// `commit()` or `rollback()`. Always `defer tx.rollback()`.
///
/// ```zig
/// var tx = try spider.mssql.begin();
/// defer tx.rollback();
/// try tx.query(void, c.arena, "UPDATE accounts SET balance = balance - @p1 WHERE id = @p2", .{ amount, from });
/// try tx.query(void, c.arena, "UPDATE accounts SET balance = balance + @p1 WHERE id = @p2", .{ amount, to });
/// try tx.commit();
/// ```
pub fn begin() !Transaction {
    const p = try pool();
    const conn = try p.acquire();
    _ = conn.exec("BEGIN TRANSACTION") catch |err| {
        const typed = fail(conn, err);
        p.release(conn);
        return typed;
    };
    return .{ .conn = conn };
}

/// Runs `body(&tx, context)` inside one transaction on one connection:
/// commits when it returns normally, rolls back when it returns an error
/// (the error is passed through). Returns what `body` returned.
///
/// ```zig
/// const id = try spider.mssql.transaction(i64, input, struct {
///     fn run(tx: *spider.mssql.Transaction, in: NewPost) !i64 {
///         return tx.query(i64, in.arena, "INSERT INTO posts (title) OUTPUT INSERTED.id VALUES (@p1)", .{in.title});
///     }
/// }.run);
/// ```
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

/// What the first statement of `sql` does to the transaction.
// internal: pub for the tests.
pub const TxControl = enum { none, open, close };

/// Skips spaces, `-- line` and `/* block */` comments at the start of `sql`.
fn skipNoise(sql: []const u8) []const u8 {
    var s = sql;
    while (true) {
        s = std.mem.trimStart(u8, s, " \t\r\n;");
        if (std.mem.startsWith(u8, s, "--")) {
            s = s[(std.mem.indexOfScalar(u8, s, '\n') orelse s.len)..];
        } else if (std.mem.startsWith(u8, s, "/*")) {
            s = s[(if (std.mem.indexOf(u8, s, "*/")) |e| e + 2 else s.len)..];
        } else return s;
    }
}

fn word(sql: []const u8) struct { word: []const u8, rest: []const u8 } {
    const s = skipNoise(sql);
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphabetic(s[n]) or s[n] == '_')) n += 1;
    return .{ .word = s[0..n], .rest = s[n..] };
}

// internal: pub for the tests.
pub fn txControl(sql: []const u8) TxControl {
    const first = word(sql);
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(first.word, "COMMIT") or eq(first.word, "ROLLBACK")) return .close;
    if (eq(first.word, "BEGIN") or eq(first.word, "SAVE")) {
        const second = word(first.rest).word;
        if (eq(second, "TRAN") or eq(second, "TRANSACTION") or eq(second, "DISTRIBUTED")) return .open;
    }
    return .none;
}

fn guard(sql: []const u8) error{UseBeginForTransactions}!void {
    if (txControl(sql) != .none) {
        std.log.warn("mssql: \"{s}\" controls a transaction; use spider.mssql.begin()", .{sqlHead(sql)});
        return error.UseBeginForTransactions;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────
// Unit tests first (no server); then the ones that need a SQL Server: the
// MSSQL_* variables say where (`zig build test-mssql`, see AGENTS.md).

const testing = std.testing;

test "Batches cuts at GO lines only" {
    var it: Batches = .{ .sql =
        \\CREATE TABLE t (a int)
        \\go
        \\  GO
        \\INSERT t VALUES (1) -- GO here is a comment
        \\/* a block
        \\GO
        \\*/ SELECT 'x
        \\GO
        \\'
        \\GO
    };
    try testing.expectEqualStrings("CREATE TABLE t (a int)", it.next().?);
    const second = it.next().?;
    try testing.expect(std.mem.startsWith(u8, second, "INSERT t VALUES (1)"));
    try testing.expect(std.mem.endsWith(u8, second, "'x\nGO\n'"));
    try testing.expectEqual(null, it.next());
}

test "txControl" {
    try testing.expectEqual(TxControl.open, txControl("BEGIN TRANSACTION"));
    try testing.expectEqual(TxControl.open, txControl("  /* x */ begin tran t1"));
    try testing.expectEqual(TxControl.close, txControl("-- done\nCOMMIT"));
    try testing.expectEqual(TxControl.close, txControl("rollback transaction"));
    try testing.expectEqual(TxControl.open, txControl("SAVE TRANSACTION sp1"));
    try testing.expectEqual(TxControl.none, txControl("BEGIN TRY SELECT 1 END TRY BEGIN CATCH END CATCH"));
    try testing.expectEqual(TxControl.none, txControl("SELECT 1"));
}

test "errorForNumber" {
    try testing.expectEqual(error.UniqueViolation, errorForNumber(2627, ""));
    try testing.expectEqual(error.CheckViolation, errorForNumber(547, "The INSERT statement conflicted with the CHECK constraint \"ck\"."));
    try testing.expectEqual(error.ForeignKeyViolation, errorForNumber(547, "The DELETE statement conflicted with the REFERENCE constraint \"fk\"."));
    try testing.expectEqual(error.RaisedException, errorForNumber(50000, "boom"));
    try testing.expectEqual(error.MSSQL, errorForNumber(9999, ""));
    try testing.expect(isDbError(error.UniqueViolation));
    try testing.expect(!isDbError(error.ColumnMissing));
}

test "textOf writes ISO 8601" {
    const a = testing.allocator;
    const dt: Value = .{ .datetime = .{ .date = .{ .year = 2026, .month = 9, .day = 6 }, .time = .{ .hour = 8, .minute = 5, .second = 3, .nanos = 183_000_000 } } };
    const s = try textOf(a, dt);
    defer a.free(s);
    try testing.expectEqualStrings("2026-09-06T08:05:03.183", s);
    const off: Value = .{ .datetimeoffset = .{ .date = .{ .year = 2026, .month = 1, .day = 2 }, .time = .{ .hour = 10, .minute = 0, .second = 0, .nanos = 0 }, .offset_minutes = -180 } };
    const s2 = try textOf(a, off);
    defer a.free(s2);
    try testing.expectEqualStrings("2026-01-02T10:00:00-03:00", s2);
}

test "intFrom takes integral decimals only" {
    try testing.expectEqual(@as(i32, 12), try intFrom(i32, .{ .decimal = .{ .value = 1200, .scale = 2 } }));
    try testing.expectError(error.TypeMismatch, intFrom(i32, .{ .decimal = .{ .value = 1250, .scale = 2 } }));
    try testing.expectError(error.IntegerOverflow, intFrom(u8, .{ .int = 300 }));
}

var test_threaded: ?std.Io.Threaded = null;

fn initTestDb() !void {
    const a = std.heap.smp_allocator;
    if (test_threaded == null) test_threaded = std.Io.Threaded.init(a, .{});
    try init(a, test_threaded.?.io(), .{ .pool_size = 2 });
}

test "server: scalar, struct and parameters" {
    try initTestDb();
    defer deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(i64, 42), try query(i64, a, "SELECT @p1 + 0", .{@as(i64, 42)}));
    try testing.expectEqual(@as(i32, 0), try query(i32, a, "SELECT CAST(NULL AS int)", .{}));

    const Row = struct {
        id: i32,
        name: []const u8,
        price: f64,
        active: bool,
        at: []const u8,
        note: ?[]const u8,
        kind: enum { book, pen },
        missing: i32 = 7,
    };
    const rows = try query(Row, a,
        \\SELECT 1 AS Id, @p1 AS name, CAST(10.50 AS decimal(10,2)) AS price, CAST(1 AS bit) AS active,
        \\       CAST('2026-09-06T08:05:03.183' AS datetime2(3)) AS at, CAST(NULL AS nvarchar(10)) AS note, @p2 AS kind
    , .{ "café ✓", "pen" });
    try testing.expectEqual(1, rows.len);
    try testing.expectEqual(1, rows[0].id);
    try testing.expectEqualStrings("café ✓", rows[0].name);
    try testing.expectEqual(10.5, rows[0].price);
    try testing.expect(rows[0].active);
    try testing.expectEqualStrings("2026-09-06T08:05:03.183", rows[0].at);
    try testing.expectEqual(null, rows[0].note);
    try testing.expectEqual(.pen, rows[0].kind);
    try testing.expectEqual(7, rows[0].missing);

    try testing.expectEqual(null, try queryOne(Row, a, "SELECT 1 AS id WHERE 1 = 0", .{}));
    try testing.expectError(error.ColumnMissing, query(struct { nope: i32 }, a, "SELECT 1 AS id", .{}));
    try testing.expectError(error.UnexpectedNull, query(struct { id: i32 }, a, "SELECT CAST(NULL AS int) AS id", .{}));
}

test "server: script, typed errors, transactions" {
    try initTestDb();
    defer deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try queryExecute(void, a,
        \\IF OBJECT_ID('tempdb..##spider_mssql_test') IS NOT NULL DROP TABLE ##spider_mssql_test
        \\GO
        \\CREATE TABLE ##spider_mssql_test (id int PRIMARY KEY, name nvarchar(5) NOT NULL CHECK (name <> 'bad'))
        \\GO
        \\INSERT ##spider_mssql_test VALUES (1, N'one')
    );
    defer queryExecute(void, a, "DROP TABLE ##spider_mssql_test") catch {};

    try testing.expectError(error.UniqueViolation, query(void, a, "INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 1, "dup" }));
    try testing.expectEqual(2627, lastError().?.number);
    try testing.expectError(error.NotNullViolation, query(void, a, "INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 2, null }));
    try testing.expectError(error.CheckViolation, query(void, a, "INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 2, "bad" }));
    try testing.expectError(error.StringDataRightTruncation, query(void, a, "INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 2, "too long" }));
    try testing.expectError(error.DivisionByZero, query(i32, a, "SELECT 1/0", .{}));
    try testing.expectError(error.UndefinedTable, query(void, a, "SELECT * FROM no_such_table", .{}));
    try testing.expectError(error.RaisedException, query(void, a, "THROW 50001, 'custom', 1", .{}));
    try testing.expectError(error.UseBeginForTransactions, query(void, a, "BEGIN TRAN", .{}));

    // Rolled back: the row is not there.
    {
        var tx = try begin();
        defer tx.rollback();
        try tx.exec("INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 2, "two" });
        try testing.expectEqual(@as(i64, 2), try tx.query(i64, a, "SELECT COUNT(*) FROM ##spider_mssql_test", .{}));
    }
    try testing.expectEqual(@as(i64, 1), try query(i64, a, "SELECT COUNT(*) FROM ##spider_mssql_test", .{}));

    // A failure inside rolls everything back (XACT_ABORT ON).
    {
        var tx = try begin();
        defer tx.rollback();
        try tx.exec("INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 3, "three" });
        try testing.expectError(error.UniqueViolation, tx.exec("INSERT ##spider_mssql_test VALUES (@p1, @p2)", .{ 1, "dup" }));
    }
    try testing.expectEqual(@as(i64, 1), try query(i64, a, "SELECT COUNT(*) FROM ##spider_mssql_test", .{}));

    // Committed.
    const id = try transaction(i64, a, struct {
        fn run(tx: *Transaction, ar: std.mem.Allocator) !i64 {
            return tx.query(i64, ar, "INSERT ##spider_mssql_test OUTPUT INSERTED.id VALUES (@p1, @p2)", .{ 4, "four" });
        }
    }.run);
    try testing.expectEqual(4, id);
    try testing.expectEqual(@as(i64, 2), try query(i64, a, "SELECT COUNT(*) FROM ##spider_mssql_test", .{}));

    // A script that fails mid-way leaves no transaction open on the pool.
    try testing.expectError(error.UniqueViolation, queryExecute(void, a,
        \\BEGIN TRANSACTION
        \\INSERT ##spider_mssql_test VALUES (5, N'five')
        \\INSERT ##spider_mssql_test VALUES (1, N'dup')
        \\COMMIT
    ));
    try testing.expectEqual(@as(i64, 2), try query(i64, a, "SELECT COUNT(*) FROM ##spider_mssql_test", .{}));
}

test "server: the pool serves many threads" {
    try initTestDb();
    defer deinit();
    const io = test_threaded.?.io();

    const worker = struct {
        fn run() !void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            for (0..50) |i| {
                const n = try query(i64, arena.allocator(), "SELECT @p1 * 2", .{@as(i64, @intCast(i))});
                try testing.expectEqual(@as(i64, @intCast(i * 2)), n);
            }
        }
    }.run;
    var f1 = try io.concurrent(worker, .{});
    var f2 = try io.concurrent(worker, .{});
    var f3 = try io.concurrent(worker, .{});
    try f1.await(io);
    try f2.await(io);
    try f3.await(io);
}

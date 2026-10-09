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
    /// What typed mapping does with a column missing from the result or a
    /// NULL in a non-optional field (fields with a declared default use it
    /// either way). `.fail` returns error.ColumnMissing / error.UnexpectedNull;
    /// `.warn` logs it and keeps the old zero value — a migration aid for
    /// code written against the old silent behavior.
    mapping: MappingMode = .fail,
};

pub const MappingMode = enum { fail, warn };

var db_pool: ?*pg_lib.Pool = null;
var mapping_mode: MappingMode = .fail;
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
    mapping_mode = overrides.mapping;
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
        i32, i64 => T,
        else => []T,
    };
}

// ── Errors ──────────────────────────────────────────────────────────────────

/// Postgres failures, by SQLSTATE class. `error.PG` remains for codes not
/// listed here. Use `lastError()` in the catch for message/detail/constraint.
pub const DbError = error{
    UniqueViolation, // 23505
    ForeignKeyViolation, // 23503
    NotNullViolation, // 23502
    CheckViolation, // 23514
    ExclusionViolation, // 23P01
    IntegrityConstraintViolation, // other 23xxx
    InvalidTextRepresentation, // 22P02 (e.g. "abc"::uuid)
    StringDataRightTruncation, // 22001
    NumericValueOutOfRange, // 22003
    InvalidDatetimeFormat, // 22007
    DatetimeFieldOverflow, // 22008
    DivisionByZero, // 22012
    DataException, // other 22xxx
    SerializationFailure, // 40001
    DeadlockDetected, // 40P01
    LockNotAvailable, // 55P03
    QueryCanceled, // 57014
    UndefinedTable, // 42P01
    UndefinedColumn, // 42703
    UndefinedFunction, // 42883
    SqlSyntaxError, // 42601
    InsufficientPrivilege, // 42501
    RaisedException, // P0001 (RAISE EXCEPTION in plpgsql / triggers)
    PG,
};

/// Typed-mapping failures (see DbConfig.mapping).
pub const MappingError = error{ ColumnMissing, UnexpectedNull, TypeMismatch, IntegerOverflow };

pub fn errorForCode(code: []const u8) DbError {
    const eq = std.mem.eql;
    if (eq(u8, code, "23505")) return error.UniqueViolation;
    if (eq(u8, code, "23503")) return error.ForeignKeyViolation;
    if (eq(u8, code, "23502")) return error.NotNullViolation;
    if (eq(u8, code, "23514")) return error.CheckViolation;
    if (eq(u8, code, "23P01")) return error.ExclusionViolation;
    if (eq(u8, code, "22P02")) return error.InvalidTextRepresentation;
    if (eq(u8, code, "22001")) return error.StringDataRightTruncation;
    if (eq(u8, code, "22003")) return error.NumericValueOutOfRange;
    if (eq(u8, code, "22007")) return error.InvalidDatetimeFormat;
    if (eq(u8, code, "22008")) return error.DatetimeFieldOverflow;
    if (eq(u8, code, "22012")) return error.DivisionByZero;
    if (eq(u8, code, "40001")) return error.SerializationFailure;
    if (eq(u8, code, "40P01")) return error.DeadlockDetected;
    if (eq(u8, code, "55P03")) return error.LockNotAvailable;
    if (eq(u8, code, "57014")) return error.QueryCanceled;
    if (eq(u8, code, "42P01")) return error.UndefinedTable;
    if (eq(u8, code, "42703")) return error.UndefinedColumn;
    if (eq(u8, code, "42883")) return error.UndefinedFunction;
    if (eq(u8, code, "42601")) return error.SqlSyntaxError;
    if (eq(u8, code, "42501")) return error.InsufficientPrivilege;
    if (eq(u8, code, "P0001")) return error.RaisedException;
    if (std.mem.startsWith(u8, code, "23")) return error.IntegrityConstraintViolation;
    if (std.mem.startsWith(u8, code, "22")) return error.DataException;
    return error.PG;
}

/// True for any error this module returns for a Postgres-side failure.
pub fn isDbError(err: anyerror) bool {
    inline for (@typeInfo(DbError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

/// Details of the last Postgres error raised on this thread.
pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    detail: ?[]const u8,
    constraint: ?[]const u8,
    table: ?[]const u8,
    column: ?[]const u8,
};

const ErrorStore = struct {
    buf: [2048]u8 = undefined,
    len: usize = 0,
    info: ErrorInfo = undefined,
    set: bool = false,

    fn keep(self: *ErrorStore, v: []const u8) []const u8 {
        const n = @min(v.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], v[0..n]);
        defer self.len += n;
        return self.buf[self.len..][0..n];
    }
    fn keepOpt(self: *ErrorStore, v: ?[]const u8) ?[]const u8 {
        return if (v) |x| self.keep(x) else null;
    }
};

threadlocal var last_error: ErrorStore = .{};

/// Details (SQLSTATE, message, detail, constraint, table, column) of the
/// Postgres error that the pg.* call which just failed returned. Read it in
/// the `catch`, before any other I/O: it is per-thread and the next failing
/// call on this thread replaces it. `detail` can contain row values (e.g. an
/// email in a unique violation) — don't show it to end users.
pub fn lastError() ?ErrorInfo {
    return if (last_error.set) last_error.info else null;
}

fn recordError(e: anytype) void {
    last_error = .{};
    last_error.info = .{
        .code = last_error.keep(e.code),
        .message = last_error.keep(e.message),
        .detail = last_error.keepOpt(e.detail),
        .constraint = last_error.keepOpt(e.constraint),
        .table = last_error.keepOpt(e.table),
        .column = last_error.keepOpt(e.column),
    };
    last_error.set = true;
}

/// Every Postgres failure goes through here: records lastError(), logs ONE
/// line (warn for data/constraint classes 22/23 — usually bad input — err
/// otherwise; `detail` only at debug since it can carry personal data) and
/// returns the typed error. Non-PG errors (connection, OOM...) pass through.
fn fail(conn: *pg_lib.Conn, err: anyerror) anyerror {
    if (err != error.PG) return err;
    const e = conn.err orelse return err;
    recordError(e);
    const typed = errorForCode(e.code);
    const client_class = std.mem.startsWith(u8, e.code, "22") or std.mem.startsWith(u8, e.code, "23");
    if (client_class) {
        std.log.warn("[pg] {s} {s}: {s}{s}{s}", .{ e.code, @errorName(typed), e.message, if (e.constraint != null) " constraint=" else "", e.constraint orelse "" });
    } else {
        std.log.err("[pg] {s} {s}: {s}{s}{s}", .{ e.code, @errorName(typed), e.message, if (e.constraint != null) " constraint=" else "", e.constraint orelse "" });
    }
    if (e.detail) |d| std.log.debug("[pg] detail: {s}", .{d});
    return typed;
}

// ── Decoding (every result column arrives in binary format) ─────────────────

const oid_bool = 16;
const oid_bytea = 17;
const oid_int8 = 20;
const oid_int2 = 21;
const oid_int4 = 23;
const oid_oid = 26;
const oid_float4 = 700;
const oid_float8 = 701;
const oid_date = 1082;
const oid_time = 1083;
const oid_timestamp = 1114;
const oid_timestamptz = 1184;
const oid_numeric = 1700;
const oid_uuid = 2950;
const oid_jsonb = 3802;
const pg_epoch_us: i64 = 946_684_800_000_000; // 2000-01-01 in unix microseconds

fn readInt(data: []const u8, oid: i32) ?i64 {
    return switch (oid) {
        oid_int2 => if (data.len >= 2) @as(i64, std.mem.readInt(i16, data[0..2], .big)) else null,
        oid_int4 => if (data.len >= 4) @as(i64, std.mem.readInt(i32, data[0..4], .big)) else null,
        oid_int8 => if (data.len >= 8) std.mem.readInt(i64, data[0..8], .big) else null,
        oid_oid => if (data.len >= 4) @as(i64, std.mem.readInt(u32, data[0..4], .big)) else null,
        else => null,
    };
}

fn formatTimestamp(arena: std.mem.Allocator, us_since_2000: i64, utc_suffix: bool) ![]const u8 {
    if (us_since_2000 == std.math.maxInt(i64)) return "infinity";
    if (us_since_2000 == std.math.minInt(i64)) return "-infinity";
    const unix_us: i128 = @as(i128, us_since_2000) + pg_epoch_us;
    const secs: i128 = @divFloor(unix_us, std.time.us_per_s);
    const frac_ms: u64 = @intCast(@divFloor(@mod(unix_us, std.time.us_per_s), 1000));
    if (secs < 0) return error.TypeMismatch; // pre-1970: not needed by callers so far
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), frac_ms, if (utc_suffix) "Z" else "",
    });
}

fn formatDate(arena: std.mem.Allocator, days_since_2000: i32) ![]const u8 {
    const days: i64 = @as(i64, days_since_2000) + 10957; // 1970-01-01 -> 2000-01-01
    if (days < 0) return error.TypeMismatch;
    const yd = (std.time.epoch.EpochDay{ .day = @intCast(days) }).calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

fn numericText(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    if (data.len < 8) return error.TypeMismatch;
    const n = pg_lib.types.Numeric.decodeKnown(data);
    const buf = try arena.alloc(u8, n.estimatedStringLen());
    return n.toString(buf);
}

/// Human-readable text for a binary column value.
fn textOf(arena: std.mem.Allocator, data: []const u8, oid: i32) ![]const u8 {
    return switch (oid) {
        oid_bool => if (data.len > 0 and data[0] != 0) "true" else "false",
        oid_int2, oid_int4, oid_int8, oid_oid => std.fmt.allocPrint(arena, "{d}", .{readInt(data, oid) orelse return error.TypeMismatch}),
        oid_float4, oid_float8 => std.fmt.allocPrint(arena, "{d}", .{readFloat(data, oid) orelse return error.TypeMismatch}),
        oid_numeric => numericText(arena, data),
        oid_uuid => blk: {
            if (data.len != 16) return error.TypeMismatch;
            const txt = try pg_lib.types.UUID.toString(data);
            break :blk arena.dupe(u8, &txt);
        },
        oid_timestamp => formatTimestamp(arena, std.mem.readInt(i64, data[0..8], .big), false),
        oid_timestamptz => formatTimestamp(arena, std.mem.readInt(i64, data[0..8], .big), true),
        oid_date => formatDate(arena, std.mem.readInt(i32, data[0..4], .big)),
        oid_time => blk: {
            const us = std.mem.readInt(i64, data[0..8], .big);
            const s_total = @divFloor(us, std.time.us_per_s);
            const secs: u64 = @intCast(@max(0, s_total));
            break :blk std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs / 60) % 60, secs % 60 });
        },
        // jsonb binary = 1 version byte + the JSON text.
        oid_jsonb => arena.dupe(u8, if (data.len > 0) data[1..] else data),
        // text, varchar, bpchar, name, json, enums, bytea (raw bytes)...: the
        // binary form IS the value.
        else => arena.dupe(u8, data),
    };
}

fn readFloat(data: []const u8, oid: i32) ?f64 {
    return switch (oid) {
        oid_float4 => if (data.len >= 4) @as(f64, @as(f32, @bitCast(std.mem.readInt(u32, data[0..4], .big)))) else null,
        oid_float8 => if (data.len >= 8) @as(f64, @bitCast(std.mem.readInt(u64, data[0..8], .big))) else null,
        else => null,
    };
}

/// "7", "+7", "-7.000" -> integer; any non-zero fraction is a TypeMismatch.
fn integralText(text: []const u8) !i128 {
    const t = std.mem.trim(u8, text, " ");
    const dot = std.mem.indexOfScalar(u8, t, '.');
    const int_part = if (dot) |d| t[0..d] else t;
    if (dot) |d| for (t[d + 1 ..]) |ch| if (ch != '0') return error.TypeMismatch;
    const digits = if (int_part.len > 0 and int_part[0] == '+') int_part[1..] else int_part;
    return std.fmt.parseInt(i128, digits, 10) catch error.TypeMismatch;
}

fn intFrom(comptime I: type, data: []const u8, oid: i32, arena: std.mem.Allocator) !I {
    const wide: i128 = if (readInt(data, oid)) |v| v else switch (oid) {
        // SUM()/AVG()/numeric columns: integral values only.
        oid_numeric => try integralText(try numericText(arena, data)),
        oid_bool, oid_float4, oid_float8, oid_uuid, oid_timestamp, oid_timestamptz, oid_date, oid_time, oid_jsonb, oid_bytea => return error.TypeMismatch,
        // text-like (e.g. a ::text cast of a number)
        else => std.fmt.parseInt(i128, std.mem.trim(u8, data, " "), 10) catch return error.TypeMismatch,
    };
    return std.math.cast(I, wide) orelse error.IntegerOverflow;
}

fn floatFrom(comptime F: type, data: []const u8, oid: i32, arena: std.mem.Allocator) !F {
    if (readFloat(data, oid)) |v| return @floatCast(v);
    if (readInt(data, oid)) |v| return @floatFromInt(v);
    return switch (oid) {
        oid_numeric => blk: {
            if (data.len < 8) return error.TypeMismatch;
            break :blk @floatCast(pg_lib.types.Numeric.decodeKnown(data).toFloat());
        },
        oid_bool, oid_uuid, oid_timestamp, oid_timestamptz, oid_date, oid_time, oid_jsonb, oid_bytea => error.TypeMismatch,
        else => @floatCast(std.fmt.parseFloat(f64, std.mem.trim(u8, try arena.dupe(u8, data), " ")) catch return error.TypeMismatch),
    };
}

fn decodeField(comptime T: type, data: []const u8, oid: i32, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        return try decodeField(info.optional.child, data, oid, arena);
    }
    if (info == .@"enum") {
        // enum columns arrive as their label; also accept a text cast
        return std.meta.stringToEnum(T, data) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8 => try textOf(arena, data, oid),
        bool => switch (oid) {
            oid_bool => data.len > 0 and data[0] != 0,
            oid_int2, oid_int4, oid_int8 => (readInt(data, oid) orelse return error.TypeMismatch) != 0,
            else => if (std.mem.eql(u8, data, "t") or std.mem.eql(u8, data, "true") or std.mem.eql(u8, data, "1"))
                true
            else if (std.mem.eql(u8, data, "f") or std.mem.eql(u8, data, "false") or std.mem.eql(u8, data, "0"))
                false
            else
                error.TypeMismatch,
        },
        i8, i16, i32, i64, u8, u16, u32, u64 => try intFrom(T, data, oid, arena),
        f32, f64 => try floatFrom(T, data, oid, arena),
        else => @compileError("decodeField: unsupported field type " ++ @typeName(T)),
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
        else => @compileError("zeroValue: unsupported field type " ++ @typeName(T)),
    };
}

fn sqlHead(sql: []const u8) []const u8 {
    const t = std.mem.trim(u8, sql, " \t\r\n");
    return t[0..@min(t.len, 80)];
}

/// Missing column / NULL into a non-optional field with no default.
fn mappingIssue(comptime T: type, comptime field: []const u8, comptime FieldT: type, err: MappingError, sql: []const u8) MappingError!FieldT {
    switch (mapping_mode) {
        .fail => {
            std.log.err("[pg] {s} mapping {s}.{s} for \"{s}\"", .{ @errorName(err), @typeName(T), field, sqlHead(sql) });
            return err;
        },
        .warn => {
            // Once per struct field per process: a query in a timer or a hot
            // page would otherwise repeat the same line on every call.
            const Once = struct {
                var warned = std.atomic.Value(bool).init(false);
            };
            if (!Once.warned.swap(true, .monotonic)) {
                std.log.warn("[pg] {s} mapping {s}.{s} for \"{s}\" (DbConfig.mapping = .warn: using the zero value; logged once)", .{ @errorName(err), @typeName(T), field, sqlHead(sql) });
            }
            return zeroValue(FieldT);
        },
    }
}

fn mapRow(comptime T: type, result: *pg_lib.Result, row: pg_lib.Row, arena: std.mem.Allocator, sql: []const u8) !T {
    var item: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, attrs| {
        var col_idx: ?usize = null;
        for (result.column_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, field_name)) {
                col_idx = i;
                break;
            }
        }
        const default = comptime attrs.defaultValue(field_type);
        if (col_idx) |ci| {
            const value = row.values[ci];
            @field(item, field_name) = if (value.is_null)
                (if (@typeInfo(field_type) == .optional)
                    null
                else if (default) |d|
                    d
                else
                    try mappingIssue(T, field_name, field_type, error.UnexpectedNull, sql))
            else
                decodeField(field_type, value.data, row.oids[ci], arena) catch |err| blk: {
                    const e: anyerror = err;
                    if (e != error.TypeMismatch and e != error.IntegerOverflow and e != error.InvalidEnumValue) return err;
                    std.log.err("[pg] {s} decoding {s}.{s} (column oid {d}) for \"{s}\"", .{ @errorName(err), @typeName(T), field_name, row.oids[ci], sqlHead(sql) });
                    if (mapping_mode == .warn) break :blk zeroValue(field_type);
                    return err;
                };
        } else {
            @field(item, field_name) = if (@typeInfo(field_type) == .optional)
                null
            else if (default) |d|
                d
            else
                try mappingIssue(T, field_name, field_type, error.ColumnMissing, sql);
        }
    }
    return item;
}

/// Scalar results (query(i32/i64, ...)): first column of the first row.
fn scalar(comptime T: type, row: pg_lib.Row, arena: std.mem.Allocator) !?T {
    const v = row.values[0];
    if (v.is_null) return null;
    return try decodeField(T, v.data, row.oids[0], arena);
}

fn execTyped(
    conn: *pg_lib.Conn,
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) !QueryResult(T) {
    if (T == void) {
        _ = conn.exec(sql, params) catch |err| return fail(conn, err);
        return {};
    }

    var result = conn.queryOpts(sql, params, .{ .column_names = true }) catch |err| return fail(conn, err);
    defer result.deinit();

    if (T == i32 or T == i64) {
        const row = (result.next() catch |err| return fail(conn, err)) orelse return 0;
        const v = (try scalar(T, row, arena)) orelse 0;
        while (result.next() catch |err| return fail(conn, err)) |_| {}
        return v;
    }

    var items = std.ArrayListUnmanaged(T).empty;
    // Errors can also arrive mid-stream (e.g. division by zero on row N).
    while (result.next() catch |err| return fail(conn, err)) |row| {
        try items.append(arena, try mapRow(T, result, row, arena, sql));
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
    var result = conn.queryOpts(sql, params, .{ .column_names = true }) catch |err| return fail(conn, err);
    defer result.deinit();

    const row = (result.next() catch |err| return fail(conn, err)) orelse return null;

    const out: ?T = if (T == i32 or T == i64)
        try scalar(T, row, arena)
    else
        try mapRow(T, result, row, arena, sql);

    // Drain remaining CommandComplete + ReadyForQuery messages so conn._state
    // is restored to .idle/.transaction before the connection is reused.
    // Without this, transactions fail with ConnectionBusy on the next operation.
    while (result.next() catch |err| return fail(conn, err)) |_| {}

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
        var it: Statements = .{ .sql = sql };
        while (it.next()) |stmt| {
            _ = conn.exec(stmt, .{}) catch |err| return fail(conn, err);
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
        const typed = fail(conn, err);
        db_pool.?.release(conn);
        return typed;
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

/// The statements of a script, one at a time, trimmed, empty ones skipped.
/// A `;` only ends a statement outside strings ('..'), quoted names (".."),
/// dollar-quoted bodies ($$..$$, $tag$..$tag$) and comments (-- and /* */):
/// a function body such as `$$ BEGIN ...; END; $$` stays in one piece.
const Statements = struct {
    sql: []const u8,
    pos: usize = 0,

    fn next(self: *Statements) ?[]const u8 {
        while (self.pos < self.sql.len) {
            const start = self.pos;
            const end = self.endOfStatement();
            self.pos = @min(end + 1, self.sql.len);
            const stmt = std.mem.trim(u8, self.sql[start..end], " \n\r\t");
            if (stmt.len > 0) return stmt;
        }
        return null;
    }

    /// The index of the `;` that ends the statement at `pos`, or sql.len.
    fn endOfStatement(self: *Statements) usize {
        const sql = self.sql;
        var i = self.pos;
        while (i < sql.len) {
            const ch = sql[i];
            if (ch == ';') return i;
            if (ch == '\'' or ch == '"') {
                i = skipQuoted(sql, i, ch);
            } else if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
                i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
            } else if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
                i = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |close| close + 2 else sql.len;
            } else if (ch == '$') {
                i = skipDollarQuoted(sql, i);
            } else {
                i += 1;
            }
        }
        return sql.len;
    }

    /// Past the closing quote of the string or name opened at `open`. A
    /// doubled quote inside it is the quote character itself.
    fn skipQuoted(sql: []const u8, open: usize, quote: u8) usize {
        var i = open + 1;
        while (i < sql.len) : (i += 1) {
            if (sql[i] != quote) continue;
            if (i + 1 < sql.len and sql[i + 1] == quote) {
                i += 1;
                continue;
            }
            return i + 1;
        }
        return sql.len;
    }

    /// Past the closing tag of the `$tag$` body opened at `open`; one past
    /// the `$` when it does not open one (`$1`, a `$` inside a name).
    fn skipDollarQuoted(sql: []const u8, open: usize) usize {
        var tag_end = open + 1;
        while (tag_end < sql.len and (std.ascii.isAlphanumeric(sql[tag_end]) or sql[tag_end] == '_')) tag_end += 1;
        if (tag_end >= sql.len or sql[tag_end] != '$') return open + 1;
        // `$1$`-like tags do not exist: a tag does not start with a digit.
        if (tag_end > open + 1 and std.ascii.isDigit(sql[open + 1])) return open + 1;
        const tag = sql[open .. tag_end + 1];
        const close = std.mem.indexOfPos(u8, sql, tag_end + 1, tag) orelse return sql.len;
        return close + tag.len;
    }
};

test "Statements: a function body, strings and comments keep their semicolons" {
    const script =
        \\CREATE TABLE notes (id int, name text DEFAULT 'a; b');
        \\-- a comment; with a semicolon
        \\CREATE OR REPLACE FUNCTION set_updated_at()
        \\RETURNS TRIGGER AS $$
        \\BEGIN
        \\    NEW.updated_at = NOW();
        \\    RETURN NEW;
        \\END;
        \\$$ LANGUAGE plpgsql;
        \\/* block; comment */ CREATE TRIGGER t BEFORE UPDATE ON notes
        \\FOR EACH ROW EXECUTE FUNCTION set_updated_at();
        \\DO $body$ BEGIN PERFORM 1; END $body$;
        \\INSERT INTO notes VALUES ($1, 'it''s; fine') ;
        \\;
    ;
    var it: Statements = .{ .sql = script };
    try std.testing.expect(std.mem.startsWith(u8, it.next().?, "CREATE TABLE notes"));
    const function = it.next().?;
    try std.testing.expect(std.mem.indexOf(u8, function, "-- a comment; with a semicolon") != null);
    try std.testing.expect(std.mem.endsWith(u8, function, "$$ LANGUAGE plpgsql"));
    try std.testing.expect(std.mem.endsWith(u8, it.next().?, "EXECUTE FUNCTION set_updated_at()"));
    try std.testing.expectEqualStrings("DO $body$ BEGIN PERFORM 1; END $body$", it.next().?);
    try std.testing.expectEqualStrings("INSERT INTO notes VALUES ($1, 'it''s; fine')", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "guardMulti: BEGIN and END inside a function body are not transaction control" {
    try guardMulti(
        \\CREATE OR REPLACE FUNCTION f() RETURNS TRIGGER AS $$
        \\BEGIN
        \\    RETURN NEW;
        \\END;
        \\$$ LANGUAGE plpgsql;
        \\CREATE TABLE t (id int);
    );
    try guardMulti("BEGIN; INSERT INTO t VALUES (1); COMMIT");
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
    var it: Statements = .{ .sql = sql };
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
        _ = self.conn.exec(sql, params) catch |err| return fail(self.conn, err);
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
        _ = self.conn.exec("COMMIT", .{}) catch |err| return fail(self.conn, err);
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
    var it: Statements = .{ .sql = sql };
    while (it.next()) |stmt| {
        _ = conn.exec(stmt, .{}) catch |err| return fail(conn, err);
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
    _ = conn.exec(sql, params) catch |err| return fail(conn, err);
}

/// Deprecated: use queryExecute(void, arena, sql) instead.
pub fn execRaw(sql: []const u8) !void {
    try guardMulti(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);
    var it: Statements = .{ .sql = sql };
    while (it.next()) |stmt| {
        _ = conn.exec(stmt, .{}) catch |err| return fail(conn, err);
    }
}

/// Deprecated: use query(T, arena, sql, params) instead.
pub fn queryWith(sql: []const u8, params: anytype) !Result {
    try guardSingle(sql);
    const conn = try db_pool.?.acquire();
    defer db_pool.?.release(conn);

    var pg_result = conn.queryOpts(sql, params, .{ .column_names = true }) catch |err| return fail(conn, err);
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

    var pg_result = conn.queryOpts(sql, params, .{ .column_names = true }) catch |err| return fail(conn, err);
    defer pg_result.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var items = std.ArrayListUnmanaged(T).empty;
    while (pg_result.next() catch |err| return fail(conn, err)) |row| {
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
    const rows = try query(
        Row,
        arena.allocator(),
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
        try std.testing.expectError(error.DivisionByZero, tx.query(void, a, "SELECT 1/0", .{}));
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

// ── Typed errors ────────────────────────────────────────────────────────────

fn setupErrTables(a: std.mem.Allocator) !void {
    _ = a;
    try execRaw("DROP TABLE IF EXISTS spider_err_child; DROP TABLE IF EXISTS spider_err_parent");
    try execRaw("CREATE TABLE spider_err_parent (id integer PRIMARY KEY, email text UNIQUE, qty integer NOT NULL DEFAULT 0 CHECK (qty >= 0), code varchar(3))");
    try execRaw("CREATE TABLE spider_err_child (id integer PRIMARY KEY, parent_id integer NOT NULL REFERENCES spider_err_parent(id))");
    try query(void, std.testing.allocator, "INSERT INTO spider_err_parent (id, email) VALUES (1, 'ana@example.com')", .{});
}

fn dropErrTables() void {
    execRaw("DROP TABLE IF EXISTS spider_err_child; DROP TABLE IF EXISTS spider_err_parent") catch {};
}

test "typed errors: SQLSTATE classes map to specific errors, lastError has the details" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try setupErrTables(a);
    defer dropErrTables();

    // 23505
    try std.testing.expectError(error.UniqueViolation, query(void, a, "INSERT INTO spider_err_parent (id, email) VALUES (2, 'ana@example.com')", .{}));
    const info = lastError().?;
    try std.testing.expectEqualStrings("23505", info.code);
    try std.testing.expectEqualStrings("spider_err_parent_email_key", info.constraint.?);
    try std.testing.expectEqualStrings("spider_err_parent", info.table.?);
    try std.testing.expect(std.mem.indexOf(u8, info.detail.?, "ana@example.com") != null);

    // 23503, 23502, 23514
    try std.testing.expectError(error.ForeignKeyViolation, query(void, a, "INSERT INTO spider_err_child VALUES (1, 999)", .{}));
    try std.testing.expectEqualStrings("spider_err_child_parent_id_fkey", lastError().?.constraint.?);
    try std.testing.expectError(error.NotNullViolation, query(void, a, "INSERT INTO spider_err_child (id) VALUES (2)", .{}));
    try std.testing.expectEqualStrings("parent_id", lastError().?.column.?);
    try std.testing.expectError(error.CheckViolation, query(void, a, "INSERT INTO spider_err_parent (id, qty) VALUES (3, -1)", .{}));

    // 22P02 via a parameter, 22001, 22012 (mid-stream), 42601, 42P01
    const Row = struct { id: []const u8 };
    try std.testing.expectError(error.InvalidTextRepresentation, query(Row, a, "SELECT 'not-a-uuid'::uuid::text AS id", .{}));
    // A uuid *parameter* is validated by the driver before it's sent.
    try std.testing.expectError(error.InvalidUUID, query(Row, a, "SELECT $1::uuid::text AS id", .{"not-a-uuid"}));
    try std.testing.expectError(error.StringDataRightTruncation, query(void, a, "INSERT INTO spider_err_parent (id, code) VALUES (4, 'toolong')", .{}));
    try std.testing.expectError(error.DivisionByZero, query(struct { v: i32 }, a, "SELECT 10 / (2 - g) AS v FROM generate_series(1, 3) g", .{}));
    try std.testing.expectError(error.SqlSyntaxError, query(void, a, "SELEC 1", .{}));
    try std.testing.expectError(error.UndefinedTable, query(void, a, "SELECT * FROM spider_no_such_table", .{}));
    try std.testing.expect(isDbError(error.UniqueViolation));
    try std.testing.expect(!isDbError(error.OutOfMemory));

    // The pool is healthy after all of the above.
    try std.testing.expectEqual(@as(i32, 1), try query(i32, a, "SELECT 1", .{}));
}

test "typed errors: RAISE EXCEPTION from a trigger, and inside a transaction" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try setupErrTables(a);
    defer dropErrTables();

    try std.testing.expectError(error.RaisedException, query(void, a,
        \\DO $$ BEGIN RAISE EXCEPTION 'blocked by rule' USING ERRCODE = 'P0001'; END $$
    , .{}));
    try std.testing.expectEqualStrings("blocked by rule", lastError().?.message);

    var tx = try begin();
    defer tx.rollback();
    try std.testing.expectError(error.UniqueViolation, tx.query(void, a, "INSERT INTO spider_err_parent (id, email) VALUES (9, 'ana@example.com')", .{}));
    try std.testing.expectError(error.TransactionAborted, tx.query(void, a, "SELECT 1", .{}));
}

test "errorForCode: classes" {
    try std.testing.expectEqual(DbError.UniqueViolation, errorForCode("23505"));
    try std.testing.expectEqual(DbError.IntegrityConstraintViolation, errorForCode("23000"));
    try std.testing.expectEqual(DbError.DataException, errorForCode("22023"));
    try std.testing.expectEqual(DbError.SerializationFailure, errorForCode("40001"));
    try std.testing.expectEqual(DbError.PG, errorForCode("XX000"));
}

// ── Decoding ────────────────────────────────────────────────────────────────

test "decode: uuid, timestamps, date, time, numeric, jsonb, bool as readable text" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Row = struct {
        id: []const u8,
        ts: []const u8,
        tstz: []const u8,
        d: []const u8,
        t: []const u8,
        n: []const u8,
        neg: []const u8,
        j: []const u8,
        b: []const u8,
        i: []const u8,
    };
    const rows = try query(Row, arena.allocator(),
        \\SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS id,
        \\       '2026-09-26 18:40:33.183'::timestamp AS ts,
        \\       '2026-09-26 15:40:33.183-03'::timestamptz AS tstz,
        \\       '2026-09-26'::date AS d,
        \\       '07:05:09'::time AS t,
        \\       123.4500::numeric AS n,
        \\       -0.05::numeric AS neg,
        \\       '{"a": [1, 2]}'::jsonb AS j,
        \\       true AS b,
        \\       42::bigint AS i
    , .{});
    const r = rows[0];
    try std.testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", r.id);
    try std.testing.expectEqualStrings("2026-09-26T18:40:33.183", r.ts);
    try std.testing.expectEqualStrings("2026-09-26T18:40:33.183Z", r.tstz);
    try std.testing.expectEqualStrings("2026-09-26", r.d);
    try std.testing.expectEqualStrings("07:05:09", r.t);
    try std.testing.expectEqualStrings("123.4500", r.n);
    try std.testing.expectEqualStrings("-0.05", r.neg);
    try std.testing.expectEqualStrings("{\"a\": [1, 2]}", r.j);
    try std.testing.expectEqualStrings("true", r.b);
    try std.testing.expectEqualStrings("42", r.i);
}

test "decode: numbers from numeric/sum/text, overflow is an error not a panic" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { total: i64, avg: f64, small: i16, txt: i32 };
    const rows = try query(Row, a, "SELECT sum(x)::numeric AS total, avg(x) AS avg, 7::int2 AS small, '12'::text AS txt FROM (VALUES (1), (2), (4)) v(x)", .{});
    try std.testing.expectEqual(@as(i64, 7), rows[0].total);
    try std.testing.expect(@abs(rows[0].avg - 7.0 / 3.0) < 1e-9);
    try std.testing.expectEqual(@as(i16, 7), rows[0].small);
    try std.testing.expectEqual(@as(i32, 12), rows[0].txt);

    try std.testing.expectEqual(@as(i64, 5_000_000_000), try query(i64, a, "SELECT 5000000000::bigint", .{}));
    try std.testing.expectError(error.IntegerOverflow, query(struct { v: i32 }, a, "SELECT 5000000000::bigint AS v", .{}));
    try std.testing.expectError(error.TypeMismatch, query(struct { v: i32 }, a, "SELECT 1.5::numeric AS v", .{}));
    try std.testing.expectError(error.TypeMismatch, query(struct { v: i64 }, a, "SELECT now() AS v", .{}));
}

// ── Missing columns / NULLs ─────────────────────────────────────────────────

test "mapping: missing column and NULL into non-optional fail by default" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.ColumnMissing, query(struct { id: i32, carrier: []const u8 }, a, "SELECT 1 AS id", .{}));
    try std.testing.expectError(error.UnexpectedNull, query(struct { name: []const u8 }, a, "SELECT NULL::text AS name", .{}));
    try std.testing.expectError(error.UnexpectedNull, queryOne(struct { n: i32 }, a, "SELECT NULL::int AS n", .{}));
}

test "mapping: optional -> null, declared default -> default" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Row = struct { id: i32, note: ?[]const u8, label: []const u8 = "n/a", count: i32 = -1, missing_opt: ?i32 };
    const rows = try query(Row, arena.allocator(), "SELECT 1 AS id, NULL::text AS note, NULL::text AS label", .{});
    try std.testing.expectEqual(@as(i32, 1), rows[0].id);
    try std.testing.expect(rows[0].note == null);
    try std.testing.expectEqualStrings("n/a", rows[0].label);
    try std.testing.expectEqual(@as(i32, -1), rows[0].count);
    try std.testing.expect(rows[0].missing_opt == null);
}

test "mapping: .warn mode keeps the old zero values (migration aid)" {
    try initTestDb(std.testing.allocator);
    defer deinit();
    mapping_mode = .warn;
    defer mapping_mode = .fail;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try query(struct { id: i32, carrier: []const u8, n: i32 }, arena.allocator(), "SELECT 1 AS id, NULL::int AS n", .{});
    try std.testing.expectEqualStrings("", rows[0].carrier);
    try std.testing.expectEqual(@as(i32, 0), rows[0].n);
}

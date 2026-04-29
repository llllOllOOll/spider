const std = @import("std");
const c = @import("c_sqlite");

pub const Config = struct {
    filename: []const u8 = ":memory:", // padrão: banco em memória
    flags: i32 = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
};

var db_connection: ?*c.sqlite3 = null;
var db_allocator: ?std.mem.Allocator = null;

pub fn init(allocator: std.mem.Allocator, config: Config) !void {
    db_allocator = allocator;

    var db_ptr: ?*c.sqlite3 = null;
    const result = c.sqlite3_open_v2(config.filename.ptr, &db_ptr, config.flags, null);

    if (result != c.SQLITE_OK) {
        const err_msg_ptr = if (db_ptr) |db| c.sqlite3_errmsg(db) else null;
        const err_msg = if (err_msg_ptr) |msg| std.mem.span(msg) else "unknown error";
        std.log.err("sqlite: failed to open database: {s}", .{err_msg});
        return error.ConnectionFailed;
    }

    db_connection = db_ptr;
    std.log.info("sqlite: database opened: {s}", .{config.filename});
}

pub fn deinit() void {
    if (db_connection) |db| {
        _ = c.sqlite3_close(db);
        db_connection = null;
    }
    db_allocator = null;
}

fn sqliteExecFn(ptr: *anyopaque, sql: []const u8) anyerror!void {
    _ = ptr;

    var err_msg: [*c]u8 = null;
    const result = c.sqlite3_exec(db_connection.?, sql.ptr, null, null, &err_msg);

    if (result != c.SQLITE_OK) {
        const msg = if (err_msg != null) std.mem.span(err_msg) else "unknown error";
        std.log.err("sqlite: exec failed: {s}", .{msg});
        if (err_msg != null) c.sqlite3_free(err_msg);
        return error.QueryFailed;
    }
}

fn sqliteDeinitFn(_: *anyopaque) void {
    // A conexão é gerenciada globalmente, não precisa fazer nada aqui
}

pub const SqliteDriver = struct {
    _dummy: u8 = 0,

    pub fn database(_: *SqliteDriver) Database {
        return .{
            .ptr = @constCast(db_connection orelse @panic("SQLite not initialized")),
            .exec_fn = sqliteExecFn,
            .deinit_fn = sqliteDeinitFn,
            .driver_type = .sqlite,
        };
    }
};

const Database = @import("../../core/database.zig").Database;

pub fn query(
    comptime T: type,
    arena: std.mem.Allocator,
    sql: []const u8,
    params: anytype,
) ![]T {
    const db = db_connection orelse return error.DatabaseNotInitialized;

    // Preparar statement
    var stmt: ?*c.sqlite3_stmt = null;
    const prepare_result = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);

    if (prepare_result != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db);
        std.log.err("sqlite: failed to prepare statement: {s}", .{std.mem.span(err_msg)});
        return error.QueryFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters (se houver)
    const param_count = comptime @typeInfo(@TypeOf(params)).@"struct".fields.len;
    if (param_count > 0) {
        inline for (0..param_count) |i| {
            const value = @field(params, @typeInfo(@TypeOf(params)).@"struct".fields[i].name);
            const bind_result = bindParam(stmt.?, @intCast(i + 1), value);
            if (bind_result != c.SQLITE_OK) {
                std.log.err("sqlite: failed to bind parameter {d}", .{i + 1});
                return error.QueryFailed;
            }
        }
    }

    // Executar query e coletar resultados
    var row_count: usize = 0;

    // Primeiro contar as linhas
    while (true) {
        const step_result = c.sqlite3_step(stmt.?);
        if (step_result == c.SQLITE_ROW) {
            row_count += 1;
        } else if (step_result == c.SQLITE_DONE) {
            break;
        } else {
            std.log.err("sqlite: query execution failed", .{});
            return error.QueryFailed;
        }
    }

    // Reset statement para ler novamente
    _ = c.sqlite3_reset(stmt.?);

    // Alocar array para resultados
    const items = try arena.alloc(T, row_count);

    // Mapear linhas
    for (0..row_count) |i| {
        const step_result = c.sqlite3_step(stmt.?);
        if (step_result != c.SQLITE_ROW) {
            std.log.err("sqlite: unexpected step result", .{});
            return error.QueryFailed;
        }
        items[i] = try mapRow(T, stmt.?, arena);
    }

    return items;
}

fn bindParam(stmt: *c.sqlite3_stmt, index: i32, value: anytype) c_int {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .int, .comptime_int => c.sqlite3_bind_int(stmt, index, @as(c_int, @intCast(value))),
        .bool => c.sqlite3_bind_int(stmt, index, if (value) 1 else 0),
        .pointer => |p| if (p.size == .slice)
            c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null)
        else
            @compileError("Unsupported pointer type: " ++ @typeName(T)),
        else => return c.SQLITE_ERROR,
    };
}

fn mapRow(comptime T: type, stmt: *c.sqlite3_stmt, arena: std.mem.Allocator) !T {
    var item: T = undefined;
    const num_cols = c.sqlite3_column_count(stmt);

    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (i >= num_cols) break;

        const col_type = c.sqlite3_column_type(stmt, @intCast(i));
        const is_null = col_type == c.SQLITE_NULL;

        if (!is_null) {
            switch (field.type) {
                i32 => @field(item, field.name) = c.sqlite3_column_int(stmt, @intCast(i)),
                bool => @field(item, field.name) = c.sqlite3_column_int(stmt, @intCast(i)) != 0,
                []const u8 => {
                    const text_ptr = c.sqlite3_column_text(stmt, @intCast(i));
                    const text_len = @as(usize, @intCast(c.sqlite3_column_bytes(stmt, @intCast(i))));
                    const text_slice = text_ptr[0..text_len];
                    @field(item, field.name) = try arena.dupe(u8, text_slice);
                },
                else => @compileError("Unsupported field type: " ++ @typeName(field.type)),
            }
        } else {
            // Para campos que podem ser nulos, precisaríamos de Optionals
            // Por enquanto, vamos usar valores padrão
            switch (field.type) {
                i32 => @field(item, field.name) = 0,
                bool => @field(item, field.name) = false,
                []const u8 => @field(item, field.name) = "",
                else => @compileError("Unsupported field type: " ++ @typeName(field.type)),
            }
        }
    }

    return item;
}

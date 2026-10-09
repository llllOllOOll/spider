const std = @import("std");
const fs_utils = @import("fs_utils.zig");
const pg = @import("pg");
const zqlite = @import("zqlite");

fn getEnvValue(content: []const u8, key: []const u8, default: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], key)) return trimmed[eq + 1 ..];
    }
    return default;
}

fn extractUpSection(sql: []const u8) []const u8 {
    const up_marker = "-- migrate:up\n";
    const down_marker = "-- migrate:down";
    const start = std.mem.indexOf(u8, sql, up_marker) orelse return sql;
    const content_start = start + up_marker.len;
    const end = std.mem.indexOf(u8, sql[content_start..], down_marker) orelse return sql[content_start..];
    return sql[content_start .. content_start + end];
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const PendingMigration = struct {
    version: []const u8,
    up_sql: []const u8,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    // A fresh clone has no .env (it is not kept in git): the committed
    // .env.example names the same development database.
    const env_opt: ?[]u8 = root_dir.readFileAlloc(io, ".env", allocator, .limited(64 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) {
            std.debug.print("error: could not read .env file\n", .{});
            return err;
        }
        const example = root_dir.readFileAlloc(io, ".env.example", allocator, .limited(64 * 1024)) catch break :blk null;
        std.debug.print("note: no .env here; using the settings of .env.example (cp .env.example .env to keep your own)\n", .{});
        break :blk example;
    };
    defer if (env_opt) |e| allocator.free(e);
    const env_content: []const u8 = env_opt orelse "";

    var migrations_dir = root_dir.openDir(io, "src/core/db/migrations", .{ .iterate = true }) catch {
        std.debug.print("error: src/core/db/migrations not found\n", .{});
        return error.MigrationsDirNotFound;
    };
    defer migrations_dir.close(io);

    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    var iter = migrations_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, files.items, {}, lessThanStr);

    if (files.items.len == 0) {
        std.debug.print("No migration files found.\n", .{});
        return;
    }

    var pending = std.ArrayListUnmanaged(PendingMigration).empty;
    defer {
        for (pending.items) |p| {
            allocator.free(p.version);
            allocator.free(p.up_sql);
        }
        pending.deinit(allocator);
    }

    for (files.items) |filename| {
        const version = try allocator.dupe(u8, filename[0 .. filename.len - 4]);
        errdefer allocator.free(version);
        const sql_content = try migrations_dir.readFileAlloc(io, filename, allocator, .limited(1024 * 1024));
        const up_sql = try allocator.dupe(u8, extractUpSection(sql_content));
        allocator.free(sql_content);
        try pending.append(allocator, .{ .version = version, .up_sql = up_sql });
    }

    const sqlite_path: []const u8 = blk: {
        const from_env = getEnvValue(env_content, "SQLITE_PATH", "");
        if (from_env.len > 0) break :blk from_env;
        if (root_dir.openFile(io, "db.sqlite", .{})) |f| {
            f.close(io);
            break :blk "db.sqlite";
        } else |_| {}
        break :blk "";
    };

    if (sqlite_path.len > 0) {
        std.debug.print("Running migrations on SQLite: {s}...\n", .{sqlite_path});
        try runSqlite(allocator, sqlite_path, pending.items);
    } else if (env_opt != null) {
        try runPg(io, allocator, env_content, pending.items);
    } else {
        std.debug.print(
            \\error: no database configured
            \\
            \\  SQLite:     add SQLITE_PATH=db.sqlite to .env  (or just run: touch db.sqlite)
            \\  PostgreSQL: add PG_HOST, PG_PORT, PG_USER, PG_PASSWORD, PG_DB to .env
            \\
        , .{});
        return error.NoDatabaseConfigured;
    }
}

fn runSqlite(allocator: std.mem.Allocator, path: []const u8, pending: []const PendingMigration) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var conn = try zqlite.open(path_z.ptr, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite);
    defer conn.close();

    conn.execNoArgs(
        "CREATE TABLE IF NOT EXISTS schema_migrations (" ++
            "version TEXT NOT NULL PRIMARY KEY, " ++
            "ran_at TEXT NOT NULL DEFAULT (datetime('now')))",
    ) catch |err| {
        std.debug.print("error: could not create schema_migrations: {}\n", .{err});
        return err;
    };

    var applied: usize = 0;

    for (pending) |m| {
        const row_opt = try conn.row(
            "SELECT 1 FROM schema_migrations WHERE version = ?1",
            .{m.version},
        );
        if (row_opt) |row| {
            row.deinit();
            continue;
        }

        std.debug.print("  running  {s}\n", .{m.version});

        const up = std.mem.trim(u8, m.up_sql, " \n\r\t");
        if (up.len > 0) {
            const s_z = try allocator.dupeSentinel(u8, up, 0);
            defer allocator.free(s_z);
            conn.execNoArgs(s_z.ptr) catch |err| {
                std.debug.print("error in migration {s}: {}\n", .{ m.version, err });
                return err;
            };
        }

        try conn.exec(
            "INSERT INTO schema_migrations (version) VALUES (?1)",
            .{m.version},
        );

        applied += 1;
        std.debug.print("  applied  {s}\n", .{m.version});
    }

    printResult(applied);
}

fn runPg(io: std.Io, allocator: std.mem.Allocator, env_content: []const u8, pending: []const PendingMigration) !void {
    const host = getEnvValue(env_content, "PG_HOST", "localhost");
    const port_str = getEnvValue(env_content, "PG_PORT", "5432");
    const port = std.fmt.parseInt(u16, port_str, 10) catch 5432;
    const user = getEnvValue(env_content, "PG_USER", "spider");
    const password = getEnvValue(env_content, "PG_PASSWORD", "spider");
    const db_name = getEnvValue(env_content, "PG_DB", "spiderdb");

    std.debug.print("Running migrations on {s}:{d}/{s}...\n", .{ host, port, db_name });

    var conn = pg.Conn.openAndAuth(io, allocator, .{
        .host = host,
        .port = port,
    }, .{
        .username = user,
        .password = password,
        .database = db_name,
    }) catch |err| {
        std.debug.print("error: could not connect to PostgreSQL ({s}:{d}): {s}\n", .{ host, port, @errorName(err) });
        return err;
    };
    defer conn.deinit();

    _ = try conn.exec(
        "CREATE TABLE IF NOT EXISTS schema_migrations (" ++
            "version VARCHAR(255) NOT NULL PRIMARY KEY, " ++
            "ran_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
        .{},
    );

    var applied: usize = 0;

    for (pending) |m| {
        var check = try conn.query(
            "SELECT 1 FROM schema_migrations WHERE version = $1",
            .{m.version},
        );
        var already = false;
        while (try check.next()) |_| already = true;
        check.deinit();
        if (already) continue;

        std.debug.print("  running  {s}\n", .{m.version});

        const up = std.mem.trim(u8, m.up_sql, " \n\r\t");
        if (up.len > 0) {
            _ = conn.exec(up, .{}) catch |err| {
                if (err == error.PG) {
                    if (conn.err) |pg_err| {
                        std.debug.print("error in migration {s}: {s} (SQLSTATE={s})\n", .{ m.version, pg_err.message, pg_err.code });
                        if (pg_err.detail) |d| std.debug.print("  detail: {s}\n", .{d});
                        if (pg_err.hint) |h| std.debug.print("  hint: {s}\n", .{h});
                    }
                } else {
                    std.debug.print("error in migration {s}: {}\n", .{ m.version, err });
                }
                return err;
            };
        }

        _ = try conn.exec(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            .{m.version},
        );

        applied += 1;
        std.debug.print("  applied  {s}\n", .{m.version});
    }

    printResult(applied);
}

fn printResult(applied: usize) void {
    if (applied == 0) {
        std.debug.print("Nothing to migrate.\n", .{});
    } else {
        std.debug.print("\n{d} migration(s) applied.\n", .{applied});
    }
}

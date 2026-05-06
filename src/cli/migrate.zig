const std = @import("std");
const fs_utils = @import("fs_utils.zig");
const pg = @import("pg");

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

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    const env_content = root_dir.readFileAlloc(io, ".env", allocator, .limited(64 * 1024)) catch |err| {
        std.debug.print("error: could not read .env file\n", .{});
        return err;
    };
    defer allocator.free(env_content);

    const host = getEnvValue(env_content, "PG_HOST", "localhost");
    const port_str = getEnvValue(env_content, "PG_PORT", "5432");
    const port = std.fmt.parseInt(u16, port_str, 10) catch 5432;
    const user = getEnvValue(env_content, "PG_USER", "spider");
    const password = getEnvValue(env_content, "PG_PASSWORD", "spider");
    const db_name = getEnvValue(env_content, "PG_DB", "spiderdb");

    std.debug.print("Running migrations on {s}:{d}/{s}...\n", .{ host, port, db_name });

    // List migration SQL files
    var migrations_dir = root_dir.openDir(io, "src/core/db/migrations", .{ .iterate = true }) catch {
        std.debug.print("error: src/core/db/migrations not found\n", .{});
        return error.MigrationsDirNotFound;
    };
    defer migrations_dir.close(io);

    var files = std.ArrayListUnmanaged([]const u8).empty;
    var iter = migrations_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.name));
    }
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    std.mem.sort([]const u8, files.items, {}, lessThanStr);

    if (files.items.len == 0) {
        std.debug.print("No migration files found.\n", .{});
        return;
    }

    // Connect to PostgreSQL
    var conn = pg.Conn.openAndAuth(io, allocator, .{
        .host = host,
        .port = port,
    }, .{
        .username = user,
        .password = password,
        .database = db_name,
    }) catch |err| {
        std.debug.print("error: could not connect to PostgreSQL ({s}:{d}): {}\n", .{ host, port, err });
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

    for (files.items) |filename| {
        const version = filename[0 .. filename.len - 4]; // strip .sql
        const version_z = try allocator.dupeZ(u8, version);
        defer allocator.free(version_z);

        var check = try conn.query(
            "SELECT 1 FROM schema_migrations WHERE version = $1",
            .{version_z},
        );
        var already = false;
        while (try check.next()) |_| already = true;
        check.deinit();
        if (already) continue;

        std.debug.print("  running  {s}\n", .{version});

        const sql_content = try migrations_dir.readFileAlloc(io, filename, allocator, .limited(1024 * 1024));
        defer allocator.free(sql_content);

        const up_sql = extractUpSection(sql_content);
        if (std.mem.trim(u8, up_sql, " \n\r\t").len == 0) continue;

        var stmts = std.mem.splitScalar(u8, up_sql, ';');
        while (stmts.next()) |stmt| {
            const s = std.mem.trim(u8, stmt, " \n\r\t");
            if (s.len == 0) continue;
            _ = conn.exec(s, .{}) catch |err| {
                std.debug.print("error in migration {s}: {}\n", .{ version, err });
                return err;
            };
        }

        _ = try conn.exec(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            .{version_z},
        );

        applied += 1;
        std.debug.print("  applied  {s}\n", .{version});
    }

    if (applied == 0) {
        std.debug.print("Nothing to migrate.\n", .{});
    } else {
        std.debug.print("\n{d} migration(s) applied.\n", .{applied});
    }
}

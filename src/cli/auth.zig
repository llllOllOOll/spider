const std = @import("std");
const template_engine = @import("template_engine.zig");
const fs_utils = @import("fs_utils.zig");
const mod_updater = @import("mod_updater.zig");
const migration_updater = @import("migration_updater.zig");
const auth_updater = @import("auth_updater.zig");

const mod_tmpl = @embedFile("templates/auth/mod.zig.template");
const routes_tmpl = @embedFile("templates/auth/routes.zig.template");
const routes_test_tmpl = @embedFile("templates/auth/routes_test.zig.template");
const controller_sqlite_tmpl = @embedFile("templates/auth/controller.zig.sqlite.template");
const controller_pg_tmpl = @embedFile("templates/auth/controller.zig.pg.template");
const migration_sql_sqlite_tmpl = @embedFile("templates/auth/migration.sql.sqlite.template");
const migration_sql_pg_tmpl = @embedFile("templates/auth/migration.sql.pg.template");
const migrations_zig_sqlite_tmpl = @embedFile("templates/migrations.zig.sqlite.template");
const migrations_zig_pg_tmpl = @embedFile("templates/migrations.zig.pg.template");

// Keycloak: connection settings from .env (KeycloakConfig.fromEnv), plus
// what differs from the defaults. No skip list: routes that need no login
// say so themselves (`.public`, see features/auth/routes.zig).
const keycloak_config =
    \\    var keycloak_config = spider.keycloak.KeycloakConfig.fromEnv();
    \\    keycloak_config.after_callback_path = "/auth/session";
    \\
;

const keycloak_config_api =
    \\    var keycloak_config = spider.keycloak.KeycloakConfig.fromEnv();
    \\    keycloak_config.api_mode = true;
    \\
;

/// Why `provider` can't be generated, or null when it can. Only Keycloak:
/// spider.google has the OAuth calls (authUrl, fetchProfile) but no session
/// provider (middleware, login/callback handlers), so the code generated for
/// "google" never compiled.
pub fn unsupportedProvider(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "local")) return null;
    if (std.mem.eql(u8, provider, "keycloak")) return null;
    if (std.mem.eql(u8, provider, "google"))
        return "Google sign-in isn't generated: Spider has no Google session provider.\n" ++
            "Use Keycloak (--provider=keycloak) and add Google as an identity provider\n" ++
            "of the realm; users then pick it on the Keycloak login page.";
    return "unsupported provider; leave --provider out for the app's own users, or use --provider=keycloak";
}

test "unsupportedProvider: keycloak only; google says why" {
    try std.testing.expect(unsupportedProvider("keycloak") == null);
    try std.testing.expect(std.mem.indexOf(u8, unsupportedProvider("google").?, "identity provider") != null);
    try std.testing.expect(unsupportedProvider("github") != null);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, provider: []const u8, api: bool) !void {
    if (unsupportedProvider(provider)) |why| {
        std.debug.print("error: --provider={s}: {s}\n", .{ provider, why });
        std.process.exit(2);
    }
    if (std.mem.eql(u8, provider, "local")) return @import("auth_local.zig").run(io, allocator, api);

    const root_dir = try fs_utils.findProjectRoot(io);

    const Provider = try std.fmt.allocPrint(allocator, "{c}{s}", .{ std.ascii.toUpper(provider[0]), provider[1..] });
    defer allocator.free(Provider);

    const vars = [_][2][]const u8{
        .{ "{{provider}}", provider },
        .{ "{{Provider}}", Provider },
    };

    std.debug.print("Generating auth feature with provider '{s}'...\n", .{provider});

    // Detect db module — follows same pattern as feature.zig
    const db_module = detectDbModule(io, allocator, root_dir) catch |err| blk: {
        std.debug.print("warning: could not detect database module, defaulting to sqlite: {}\n", .{err});
        break :blk try allocator.dupe(u8, "sqlite");
    };
    defer allocator.free(db_module);

    // Select templates based on db module

    if (!api) {
        const controller_tmpl = if (std.mem.eql(u8, db_module, "pg")) controller_pg_tmpl else controller_sqlite_tmpl;
        const migration_sql_tmpl = if (std.mem.eql(u8, db_module, "pg")) migration_sql_pg_tmpl else migration_sql_sqlite_tmpl;
        const migrations_zig_tmpl = if (std.mem.eql(u8, db_module, "pg")) migrations_zig_pg_tmpl else migrations_zig_sqlite_tmpl;

        // Create features/auth/ directory
        var features_dir = root_dir.openDir(io, "src/features", .{}) catch |err| {
            std.debug.print("error: 'src/features' directory not found. Are you in a Spider project?\n", .{});
            return err;
        };
        defer features_dir.close(io);

        features_dir.createDir(io, "auth", .default_dir) catch |err| {
            if (err == error.PathAlreadyExists) {
                std.debug.print("error: auth feature already exists\n", .{});
                return error.FeatureExists;
            }
            return err;
        };

        var auth_dir = try features_dir.openDir(io, "auth", .{});
        defer auth_dir.close(io);

        // Write mod.zig
        const mod_content = try template_engine.renderTemplateWithVars(allocator, mod_tmpl, &vars);
        defer allocator.free(mod_content);
        try fs_utils.writeFile(io, auth_dir, "mod.zig", mod_content);
        std.debug.print("  create  src/features/auth/mod.zig\n", .{});

        // Write controller.zig — db-variant template
        const controller_content = try template_engine.renderTemplateWithVars(allocator, controller_tmpl, &vars);
        defer allocator.free(controller_content);
        try fs_utils.writeFile(io, auth_dir, "controller.zig", controller_content);
        std.debug.print("  create  src/features/auth/controller.zig\n", .{});

        // Routes: login/callback from the provider, session/logout from the controller
        const routes_content = try template_engine.renderTemplateWithVars(allocator, routes_tmpl, &vars);
        defer allocator.free(routes_content);
        try fs_utils.writeFile(io, auth_dir, "routes.zig", routes_content);
        std.debug.print("  create  src/features/auth/routes.zig\n", .{});
        const routes_test_content = try template_engine.renderTemplateWithVars(allocator, routes_test_tmpl, &vars);
        defer allocator.free(routes_test_content);
        try fs_utils.writeFile(io, auth_dir, "routes_test.zig", routes_test_content);
        std.debug.print("  create  src/features/auth/routes_test.zig\n", .{});

        // No login.html — auth provider (keycloak/google) handles login page

        // Update features/mod.zig
        try mod_updater.updateFeaturesMod(io, allocator, features_dir, "auth");
        std.debug.print("  update  src/features/mod.zig\n", .{});

        // Generate migration
        const timestamp = migration_updater.generateTimestamp(io);
        const migration_name = try std.fmt.allocPrint(allocator, "{d}_create_users.sql", .{timestamp});
        defer allocator.free(migration_name);

        const migration_content = try template_engine.renderTemplateWithVars(allocator, migration_sql_tmpl, &vars);
        defer allocator.free(migration_content);

        const migration_path = try std.fmt.allocPrint(allocator, "src/core/db/migrations/{s}", .{migration_name});
        defer allocator.free(migration_path);
        try fs_utils.writeFile(io, root_dir, migration_path, migration_content);
        std.debug.print("  create  {s}\n", .{migration_path});

        // Update src/core/db/migrations.zig
        try migration_updater.updateMigrationsZig(io, allocator, root_dir, timestamp, "users", migrations_zig_tmpl);
        std.debug.print("  update  src/core/db/migrations.zig\n", .{});

        // Ensure src/core/db/mod.zig exists and exports migrations
        {
            const db_mod_content = root_dir.readFileAlloc(io, "src/core/db/mod.zig", allocator, .limited(256)) catch "";
            defer if (db_mod_content.len > 0) allocator.free(db_mod_content);
            if (db_mod_content.len == 0 or std.mem.indexOf(u8, db_mod_content, "pub const migrations") == null) {
                try fs_utils.writeFile(io, root_dir, "src/core/db/mod.zig", "pub const migrations = @import(\"migrations.zig\");\n");
                std.debug.print("  create  src/core/db/mod.zig\n", .{});
            }
        }

        // Ensure src/core/mod.zig has pub const db = ...
        {
            const core_mod_content = try root_dir.readFileAlloc(io, "src/core/mod.zig", allocator, .limited(4096));
            defer allocator.free(core_mod_content);
            if (std.mem.indexOf(u8, core_mod_content, "pub const db") == null) {
                const updated = try std.mem.concat(allocator, u8, &.{ core_mod_content, "pub const db = @import(\"db/mod.zig\");\n" });
                defer allocator.free(updated);
                try fs_utils.writeFile(io, root_dir, "src/core/mod.zig", updated);
                std.debug.print("  update  src/core/mod.zig\n", .{});
            }
        }
    }

    // Select provider config
    const provider_config = if (api) keycloak_config_api else keycloak_config;

    // Update main.zig
    try auth_updater.updateMainZig(io, allocator, root_dir, provider, provider_config, api);
    std.debug.print("  update  src/main.zig\n", .{});

    // Keycloak settings: in .env.example (the committed reference) and in
    // .env, which `spider new` creates — otherwise the app reads empty
    // KEYCLOAK_* values. A project without .env keeps not having one.
    if (std.mem.eql(u8, provider, "keycloak")) {
        inline for (.{ ".env.example", ".env" }) |path| {
            const is_example = comptime std.mem.eql(u8, path, ".env.example");
            const existing: ?[]u8 = root_dir.readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch null;
            defer if (existing) |e| allocator.free(e);
            if (existing != null or is_example) {
                if (try withKeycloakVars(allocator, existing orelse "")) |updated| {
                    defer allocator.free(updated);
                    try fs_utils.writeFile(io, root_dir, path, updated);
                    std.debug.print("  update  {s}\n", .{path});
                }
            }
        }
    }

    std.debug.print("\nDone! Auth feature with {s} provider generated.\n", .{provider});
    std.debug.print("Features generated before auth have their defaults() commented out: with auth,\n", .{});
    std.debug.print("their routes need declared access. `spider check` lists them.\n", .{});
}

/// `env` with the Keycloak variables appended, or null when it already has
/// them.
pub fn withKeycloakVars(allocator: std.mem.Allocator, env: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, env, "KEYCLOAK_") != null) return null;
    const vars =
        "\n# Keycloak\n" ++
        "KEYCLOAK_BASE_URL=http://localhost:8080\n" ++
        "KEYCLOAK_REALM=myrealm\n" ++
        "KEYCLOAK_CLIENT_ID=spider-app\n" ++
        "KEYCLOAK_CLIENT_SECRET=your-client-secret\n" ++
        "KEYCLOAK_REDIRECT_URI=http://localhost:3000/auth/callback\n" ++
        "KEYCLOAK_REDIRECT_URI_LOGOUT=http://localhost:3000\n";
    const jwt = if (std.mem.indexOf(u8, env, "JWT_SECRET") == null) "JWT_SECRET=change-me-in-production\n" else "";
    return try std.mem.concat(allocator, u8, &.{ env, vars, jwt });
}

test "withKeycloakVars: appends once, keeps an existing JWT_SECRET" {
    const a = std.testing.allocator;
    const once = (try withKeycloakVars(a, "JWT_SECRET=abc\n")).?;
    defer a.free(once);
    try std.testing.expect(std.mem.startsWith(u8, once, "JWT_SECRET=abc\n\n# Keycloak\nKEYCLOAK_BASE_URL="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, once, "JWT_SECRET="));
    try std.testing.expect((try withKeycloakVars(a, once)) == null);
    const fresh = (try withKeycloakVars(a, "")).?;
    defer a.free(fresh);
    try std.testing.expect(std.mem.endsWith(u8, fresh, "JWT_SECRET=change-me-in-production\n"));
}

fn detectDbModule(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir) ![]const u8 {
    const main_content = root_dir.readFileAlloc(io, "src/main.zig", allocator, .limited(32 * 1024)) catch {
        return allocator.dupe(u8, "sqlite");
    };
    defer allocator.free(main_content);

    if (std.mem.indexOf(u8, main_content, "spider.pg") != null) {
        return allocator.dupe(u8, "pg");
    }
    return allocator.dupe(u8, "sqlite");
}

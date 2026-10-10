//! `spider g auth` with the app's own users: a users table, sign in, sign
//! up and sign out, with nothing outside the app. Passwords are hashed with
//! spider.password and a login is a spider.session cookie (a bearer token
//! with --api).
const std = @import("std");
const template_engine = @import("template_engine.zig");
const fs_utils = @import("fs_utils.zig");
const mod_updater = @import("mod_updater.zig");
const migration_updater = @import("migration_updater.zig");

const mod_tmpl = @embedFile("templates/auth_local/mod.zig.template");
const model_tmpl = @embedFile("templates/auth_local/model.zig.template");
const repository_tmpl = @embedFile("templates/auth_local/repository.zig.template");
const controller_tmpl = @embedFile("templates/auth_local/controller.zig.template");
const controller_api_tmpl = @embedFile("templates/auth_local/controller.zig.api.template");
const routes_tmpl = @embedFile("templates/auth_local/routes.zig.template");
const routes_api_tmpl = @embedFile("templates/auth_local/routes.zig.api.template");
const routes_test_tmpl = @embedFile("templates/auth_local/routes_test.zig.template");
const routes_test_api_tmpl = @embedFile("templates/auth_local/routes_test.zig.api.template");
const login_tmpl = @embedFile("templates/auth_local/login.html.template");
const register_tmpl = @embedFile("templates/auth_local/register.html.template");
const account_tmpl = @embedFile("templates/auth_local/account.html.template");
const migration_sqlite_tmpl = @embedFile("templates/auth_local/migration.sql.sqlite.template");
const migration_pg_tmpl = @embedFile("templates/auth_local/migration.sql.pg.template");
const app_tests_tmpl = @embedFile("templates/auth_local/app_tests.zig.template");
const app_tests_api_tmpl = @embedFile("templates/auth_local/app_tests.zig.api.template");
const migrations_zig_sqlite_tmpl = @embedFile("templates/migrations.zig.sqlite.template");
const migrations_zig_pg_tmpl = @embedFile("templates/migrations.zig.pg.template");

const Db = enum { sqlite, pg };

pub fn run(io: std.Io, allocator: std.mem.Allocator, api: bool) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    const main_src = root_dir.readFileAlloc(io, "src/main.zig", allocator, .limited(64 * 1024)) catch {
        std.debug.print("error: src/main.zig not found. Are you in a Spider project?\n", .{});
        return error.NotAProjectRoot;
    };
    defer allocator.free(main_src);

    const db = databaseOf(main_src) orelse {
        std.debug.print(
            \\error: this project has no database, and a login needs one for its users.
            \\
            \\  Create the project with a database (`spider new <name>` or `--pg`), or
            \\  use an outside provider: spider g auth --provider=keycloak
            \\
        , .{});
        std.process.exit(1);
    };

    std.debug.print("Generating login with the app's own users...\n", .{});

    var features_dir = root_dir.openDir(io, "src/features", .{}) catch |err| {
        std.debug.print("error: 'src/features' directory not found. Are you in a Spider project?\n", .{});
        return err;
    };
    defer features_dir.close(io);
    features_dir.createDir(io, "auth", .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: src/features/auth already exists: this project has a login\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    var auth_dir = try features_dir.openDir(io, "auth", .{});
    defer auth_dir.close(io);

    const repository = try forDatabase(allocator, repository_tmpl, db);
    defer allocator.free(repository);

    const Files = struct { path: []const u8, content: []const u8 };
    const common = [_]Files{
        .{ .path = "mod.zig", .content = mod_tmpl },
        .{ .path = "model.zig", .content = model_tmpl },
        .{ .path = "repository.zig", .content = repository },
        .{ .path = "controller.zig", .content = if (api) controller_api_tmpl else controller_tmpl },
        .{ .path = "routes.zig", .content = if (api) routes_api_tmpl else routes_tmpl },
        .{ .path = "routes_test.zig", .content = if (api) routes_test_api_tmpl else routes_test_tmpl },
    };
    const views = [_]Files{
        .{ .path = "views/login.html", .content = login_tmpl },
        .{ .path = "views/register.html", .content = register_tmpl },
        .{ .path = "views/account.html", .content = account_tmpl },
    };
    for (common) |f| {
        try fs_utils.writeFile(io, auth_dir, f.path, f.content);
        std.debug.print("  create  src/features/auth/{s}\n", .{f.path});
    }
    if (!api) for (views) |f| {
        try fs_utils.writeFile(io, auth_dir, f.path, f.content);
        std.debug.print("  create  src/features/auth/{s}\n", .{f.path});
    };

    try mod_updater.updateFeaturesMod(io, allocator, features_dir, "auth");
    std.debug.print("  update  src/features/mod.zig\n", .{});

    // The users table.
    const timestamp = migration_updater.generateTimestamp(io, root_dir);
    const migration_path = try std.fmt.allocPrint(allocator, "src/core/db/migrations/{d}_create_users.sql", .{timestamp});
    defer allocator.free(migration_path);
    try fs_utils.writeFile(io, root_dir, migration_path, if (db == .pg) migration_pg_tmpl else migration_sqlite_tmpl);
    std.debug.print("  create  {s}\n", .{migration_path});
    try migration_updater.updateMigrationsZig(io, allocator, root_dir, timestamp, "users", if (db == .pg) migrations_zig_pg_tmpl else migrations_zig_sqlite_tmpl);
    std.debug.print("  update  src/core/db/migrations.zig\n", .{});

    // The middleware, and where a visitor without a session is sent.
    const new_main = try withSession(allocator, main_src, api);
    defer allocator.free(new_main);
    if (std.mem.eql(u8, new_main, main_src)) {
        std.debug.print(
            \\  warning: src/main.zig was not changed (no `.mountFeatures(features)` line found).
            \\           Add `.use(spider.session.middleware())` before the routes yourself.
            \\
        , .{});
    } else {
        try fs_utils.writeFile(io, root_dir, "src/main.zig", new_main);
        std.debug.print("  update  src/main.zig (session middleware)\n", .{});
    }

    // Tests, next to the ones the project already has. They sign up and
    // sign in, so they need the test server to have a database.
    if (root_dir.readFileAlloc(io, "src/app_test.zig", allocator, .limited(256 * 1024))) |existing| {
        defer allocator.free(existing);
        if (std.mem.indexOf(u8, existing, "spider g auth") != null) {
            // Already there.
        } else if (!startsDatabase(existing)) {
            std.debug.print(
                \\  note: no tests of the login were added: the test server in src/app_test.zig
                \\        starts no database (see the comment in its run()).
                \\
            , .{});
        } else {
            const with_tests = try std.mem.concat(allocator, u8, &.{ existing, if (api) app_tests_api_tmpl else app_tests_tmpl });
            defer allocator.free(with_tests);
            try fs_utils.writeFile(io, root_dir, "src/app_test.zig", with_tests);
            std.debug.print("  update  src/app_test.zig (tests of the login)\n", .{});
        }
    } else |_| {
        std.debug.print("  note: no src/app_test.zig in this project, so no tests of the login were added\n", .{});
    }

    std.debug.print(
        \\
        \\Done. {s}
        \\
        \\  Every route that is not `.public` now needs a login. Features made before
        \\  this have their access undeclared: `spider check` lists them.
        \\  Logins are signed with JWT_SECRET (.env). The app applies the new
        \\  migration when it starts.
        \\
    , .{if (api)
        "POST /auth/register and /auth/login answer a token; send it as `Authorization: Bearer <token>`."
    else
        "Open /auth/register to create the first account."});
}

/// Whether the test server of src/app_test.zig connects to a database (a
/// line of code, not of comment, that calls `.init(gpa, io`).
pub fn startsDatabase(app_test_src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, app_test_src, '\n');
    while (lines.next()) |line| {
        const code = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, code, "//")) continue;
        if (std.mem.indexOf(u8, code, ".init(gpa, io") != null and std.mem.indexOf(u8, code, "Threaded") == null) return true;
    }
    return false;
}

test "startsDatabase: a db.init in code counts, one in a comment does not" {
    try t.expect(startsDatabase("    var threaded: std.Io.Threaded = .init(gpa, .{});\n    try db.init(gpa, io, .{ .path = path });\n"));
    try t.expect(!startsDatabase("    var threaded: std.Io.Threaded = .init(gpa, .{});\n    //     try spider.pg.init(gpa, io, .{ .database = \"blog_test\" });\n"));
}

/// Which database the project uses, from its main.zig; null for none.
pub fn databaseOf(main_src: []const u8) ?Db {
    var lines = std.mem.splitScalar(u8, main_src, '\n');
    while (lines.next()) |line| {
        const code = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, code, "//")) continue;
        if (std.mem.indexOf(u8, code, "= spider.pg;") != null) return .pg;
        if (std.mem.indexOf(u8, code, "= spider.sqlite;") != null) return .sqlite;
    }
    return null;
}

/// The repository template for one database: the module name, and the
/// placeholders as that database writes them ($1 or ?1).
pub fn forDatabase(allocator: std.mem.Allocator, tmpl: []const u8, db: Db) ![]u8 {
    const named = try std.mem.replaceOwned(u8, allocator, tmpl, "{{db_module}}", @tagName(db));
    if (db == .pg) return named;
    defer allocator.free(named);
    return std.mem.replaceOwned(u8, allocator, named, "$", "?");
}

/// main.zig with the session middleware before the routes and, in an app
/// with pages, a visitor without a session sent to the sign-in page.
pub fn withSession(allocator: std.mem.Allocator, main_src: []const u8, api: bool) ![]u8 {
    if (std.mem.indexOf(u8, main_src, "spider.session.middleware()") != null) return allocator.dupe(u8, main_src);

    const marker = ".mountFeatures(features)";
    const pos = std.mem.indexOf(u8, main_src, marker) orelse return allocator.dupe(u8, main_src);
    const line_start = if (std.mem.lastIndexOfScalar(u8, main_src[0..pos], '\n')) |nl| nl + 1 else 0;
    const indent = main_src[line_start..pos];
    const use_line = try std.fmt.allocPrint(allocator,
        \\{s}// Reads the login cookie (or a bearer token) and tells the routes
        \\{s}// who is there; a route that is not `.public` needs a login.
        \\{s}.use(spider.session.middleware())
        \\
    , .{ indent, indent, indent });
    defer allocator.free(use_line);
    const with_use = try std.mem.concat(allocator, u8, &.{ main_src[0..line_start], use_line, main_src[line_start..] });
    if (api) return with_use;
    defer allocator.free(with_use);

    const handler = "spider.errorHandler(.{";
    const at = std.mem.indexOf(u8, with_use, handler) orelse return allocator.dupe(u8, with_use);
    const after = at + handler.len;
    const rest = std.mem.trimStart(u8, with_use[after..], " ");
    const empty = std.mem.startsWith(u8, rest, "}");
    return std.mem.concat(allocator, u8, &.{
        with_use[0..after],
        " .unauthorized_redirect = \"/auth/login\"",
        if (empty) " " else ", ",
        rest,
    });
}

const t = std.testing;

test "databaseOf: the database main.zig uses, comments aside" {
    try t.expectEqual(Db.sqlite, databaseOf("const db = spider.sqlite;\n").?);
    try t.expectEqual(Db.pg, databaseOf("const db = spider.pg;\n").?);
    try t.expect(databaseOf("// const db = spider.pg;\n") == null);
    try t.expect(databaseOf("const std = @import(\"std\");\n") == null);
}

test "forDatabase: placeholders as each database writes them" {
    const sqlite = try forDatabase(t.allocator, "const db = spider.{{db_module}};\n\"WHERE email = $1 AND id = $2\"", .sqlite);
    defer t.allocator.free(sqlite);
    try t.expectEqualStrings("const db = spider.sqlite;\n\"WHERE email = ?1 AND id = ?2\"", sqlite);

    const pg = try forDatabase(t.allocator, "const db = spider.{{db_module}};\n\"WHERE email = $1\"", .pg);
    defer t.allocator.free(pg);
    try t.expectEqualStrings("const db = spider.pg;\n\"WHERE email = $1\"", pg);
}

test "withSession: the middleware goes before the routes, and pages redirect to the sign-in" {
    const src =
        \\    server
        \\        .use(spider.logger)
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{ .template_not_found_is_404 = true }))
        \\        .listen(.{}) catch |err| return err;
        \\
    ;
    const out = try withSession(t.allocator, src, false);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\    server
        \\        .use(spider.logger)
        \\        // Reads the login cookie (or a bearer token) and tells the routes
        \\        // who is there; a route that is not `.public` needs a login.
        \\        .use(spider.session.middleware())
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{ .unauthorized_redirect = "/auth/login", .template_not_found_is_404 = true }))
        \\        .listen(.{}) catch |err| return err;
        \\
    , out);

    // Running it again changes nothing.
    const again = try withSession(t.allocator, out, false);
    defer t.allocator.free(again);
    try t.expectEqualStrings(out, again);
}

test "withSession: an API gets the middleware only; an empty handler config gets the redirect" {
    const api_src =
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{ .always_json = true }))
        \\
    ;
    const api = try withSession(t.allocator, api_src, true);
    defer t.allocator.free(api);
    try t.expect(std.mem.indexOf(u8, api, ".use(spider.session.middleware())") != null);
    try t.expect(std.mem.indexOf(u8, api, "unauthorized_redirect") == null);

    const bare = try withSession(t.allocator, "    .mountFeatures(features)\n    .onError(spider.errorHandler(.{}))\n", false);
    defer t.allocator.free(bare);
    try t.expect(std.mem.indexOf(u8, bare, "spider.errorHandler(.{ .unauthorized_redirect = \"/auth/login\" })") != null);

    const no_routes = try withSession(t.allocator, "pub fn main() void {}\n", false);
    defer t.allocator.free(no_routes);
    try t.expectEqualStrings("pub fn main() void {}\n", no_routes);
}

test "the generated tests match the generated routes" {
    try t.expect(std.mem.indexOf(u8, app_tests_tmpl, "\"/auth/account\"") != null);
    try t.expect(std.mem.indexOf(u8, routes_tmpl, ".get(\"/account\"") != null);
    try t.expect(std.mem.indexOf(u8, app_tests_api_tmpl, "\"/auth/me\"") != null);
    try t.expect(std.mem.indexOf(u8, routes_api_tmpl, ".get(\"/me\"") != null);
}

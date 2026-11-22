const std = @import("std");
const template_engine = @import("template_engine.zig");
const fs_utils = @import("fs_utils.zig");
const mod_updater = @import("mod_updater.zig");
const migration_updater = @import("migration_updater.zig");
const routes_updater = @import("routes_updater.zig");

// Embedded templates
const mod_tmpl = @embedFile("templates/feature/mod.zig.template");
const mod_api_tmpl = @embedFile("templates/feature/mod.zig.api.template");
const model_tmpl = @embedFile("templates/feature/model.zig.template");
const repository_sqlite_tmpl = @embedFile("templates/feature/repository.zig.template");
const repository_pg_tmpl = @embedFile("templates/feature/repository.zig.pg.template");
const controller_tmpl = @embedFile("templates/feature/controller.zig.template");
const controller_api_sqlite_tmpl = @embedFile("templates/feature/controller.zig.api.sqlite.template");
const controller_api_pg_tmpl = @embedFile("templates/feature/controller.zig.api.pg.template");
const routes_tmpl = @embedFile("templates/feature/routes.zig.template");
const routes_api_tmpl = @embedFile("templates/feature/routes.zig.api.template");
const routes_test_tmpl = @embedFile("templates/feature/routes_test.zig.template");
const index_html_tmpl = @embedFile("templates/feature/index.html.template");
const list_html_tmpl = @embedFile("templates/feature/_list.html.template");
const card_html_tmpl = @embedFile("templates/feature/_card.html.template");
const form_html_tmpl = @embedFile("templates/feature/_form.html.template");
const edit_form_html_tmpl = @embedFile("templates/feature/_edit_form.html.template");
const page_html_tmpl = @embedFile("templates/feature/page.html.template");
const migration_sql_sqlite_tmpl = @embedFile("templates/feature/migration.sql.sqlite.template");
const migration_sql_pg_tmpl = @embedFile("templates/feature/migration.sql.pg.template");
const migrations_zig_sqlite_tmpl = @embedFile("templates/migrations.zig.sqlite.template");
const migrations_zig_pg_tmpl = @embedFile("templates/migrations.zig.pg.template");

pub fn run(io: std.Io, allocator: std.mem.Allocator, feature: []const u8, api: bool) !void {
    // validate feature name
    if (std.mem.startsWith(u8, feature, "-")) {
        std.debug.print("error: invalid feature name '{s}'\n", .{feature});
        std.debug.print("Feature names cannot start with '-'.\n", .{});
        std.debug.print("Usage: spider generate feature <name>\n", .{});
        return error.InvalidFeatureName;
    }

    const root_dir = try fs_utils.findProjectRoot(io);

    // The feature keeps its records in a table: a project made with
    // --no-db has nowhere to put them.
    if (root_dir.readFileAlloc(io, "src/main.zig", allocator, .limited(64 * 1024))) |main_src| {
        defer allocator.free(main_src);
        if (@import("auth_local.zig").databaseOf(main_src) == null) {
            std.debug.print(
                \\error: this project has no database, and a feature keeps its records in a table.
                \\
                \\  Create the project with a database (`spider new <name>` or `--pg`).
                \\
            , .{});
            std.process.exit(1);
        }
    } else |_| {}

    std.debug.print("Generating feature '{s}'...\n", .{feature});

    const Feature = try template_engine.capitalize(allocator, feature);
    defer allocator.free(Feature);

    var plural_buf: [256]u8 = undefined;
    const plural = template_engine.pluralize(feature, &plural_buf);

    const mod_tmpl_selected = if (api) mod_api_tmpl else mod_tmpl;
    const mod_content = try template_engine.renderTemplate(allocator, mod_tmpl_selected, feature, plural);
    defer allocator.free(mod_content);

    const model_content = try template_engine.renderTemplate(allocator, model_tmpl, feature, plural);
    defer allocator.free(model_content);

    const db_module = detectDbModule(io, allocator, root_dir) catch |err| blk: {
        std.debug.print("warning: could not detect database module, defaulting to sqlite: {}\n", .{err});
        break :blk try allocator.dupe(u8, "sqlite");
    };
    defer allocator.free(db_module);

    const repo_feature = try template_engine.capitalize(allocator, feature);
    defer allocator.free(repo_feature);

    const repository_tmpl = if (std.mem.eql(u8, db_module, "pg")) repository_pg_tmpl else repository_sqlite_tmpl;
    const repository_content = try template_engine.renderTemplateWithVars(allocator, repository_tmpl, &.{
        .{ "{{feature}}", feature },
        .{ "{{Feature}}", repo_feature },
        .{ "{{plural}}", plural },
        .{ "{{db_module}}", db_module },
    });
    defer allocator.free(repository_content);

    const controller_tmpl_selected = if (api)
        if (std.mem.eql(u8, db_module, "pg")) controller_api_pg_tmpl else controller_api_sqlite_tmpl
    else
        controller_tmpl;
    const controller_content = try template_engine.renderTemplate(allocator, controller_tmpl_selected, feature, plural);
    defer allocator.free(controller_content);

    const auth = authOfProject(io, allocator, root_dir);
    const routes_content = try renderRoutes(allocator, if (api) routes_api_tmpl else routes_tmpl, feature, plural, auth);
    defer allocator.free(routes_content);
    const routes_test_content = try renderRoutesTest(allocator, api, feature, plural, auth);
    defer allocator.free(routes_test_content);

    const index_html_content = try template_engine.renderTemplate(allocator, index_html_tmpl, feature, plural);
    defer allocator.free(index_html_content);

    const list_html_content = try template_engine.renderTemplate(allocator, list_html_tmpl, feature, plural);
    defer allocator.free(list_html_content);

    const card_html_content = try template_engine.renderTemplate(allocator, card_html_tmpl, feature, plural);
    defer allocator.free(card_html_content);

    // What the views say to htmx is written for the version the project loads.
    const form_html_rendered = try template_engine.renderTemplate(allocator, form_html_tmpl, feature, plural);
    defer allocator.free(form_html_rendered);
    const form_html_content = try @import("htmx.zig").view(allocator, form_html_rendered, @import("htmx.zig").ofProject(io, allocator, root_dir));
    defer allocator.free(form_html_content);

    const edit_form_html_content = try template_engine.renderTemplate(allocator, edit_form_html_tmpl, feature, plural);
    defer allocator.free(edit_form_html_content);

    const page_html_content = try template_engine.renderTemplate(allocator, page_html_tmpl, feature, plural);
    defer allocator.free(page_html_content);

    const timestamp = migration_updater.generateTimestamp(io, root_dir);
    const migration_name = try std.fmt.allocPrint(allocator, "{d}_create_{s}.sql", .{ timestamp, plural });
    defer allocator.free(migration_name);

    const migration_sql_tmpl = if (std.mem.eql(u8, db_module, "pg")) migration_sql_pg_tmpl else migration_sql_sqlite_tmpl;
    const migration_content = try template_engine.renderTemplate(allocator, migration_sql_tmpl, feature, plural);
    defer allocator.free(migration_content);

    var features_dir = root_dir.openDir(io, "src/features", .{}) catch |err| {
        std.debug.print("error: 'src/features' directory not found. Are you in a Spider project?\n", .{});
        return err;
    };
    defer features_dir.close(io);

    features_dir.createDir(io, feature, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: feature '{s}' already exists\n", .{feature});
            return error.FeatureExists;
        }
        return err;
    };

    var feature_dir = try features_dir.openDir(io, feature, .{});
    defer feature_dir.close(io);

    if (!api) {
        try feature_dir.createDir(io, "views", .default_dir);
    }

    try fs_utils.writeFile(io, feature_dir, "mod.zig", mod_content);
    std.debug.print("  create  src/features/{s}/mod.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "model.zig", model_content);
    std.debug.print("  create  src/features/{s}/model.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "repository.zig", repository_content);
    std.debug.print("  create  src/features/{s}/repository.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "controller.zig", controller_content);
    std.debug.print("  create  src/features/{s}/controller.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "routes.zig", routes_content);
    std.debug.print("  create  src/features/{s}/routes.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "routes_test.zig", routes_test_content);
    std.debug.print("  create  src/features/{s}/routes_test.zig\n", .{feature});

    if (!api) {
        try fs_utils.writeFile(io, feature_dir, "views/index.html", index_html_content);
        std.debug.print("  create  src/features/{s}/views/index.html\n", .{feature});

        const list_filename = try std.fmt.allocPrint(allocator, "views/{s}List.html", .{Feature});
        defer allocator.free(list_filename);
        try fs_utils.writeFile(io, feature_dir, list_filename, list_html_content);
        std.debug.print("  create  src/features/{s}/{s}\n", .{ feature, list_filename });

        const card_filename = try std.fmt.allocPrint(allocator, "views/{s}Card.html", .{Feature});
        defer allocator.free(card_filename);
        try fs_utils.writeFile(io, feature_dir, card_filename, card_html_content);
        std.debug.print("  create  src/features/{s}/{s}\n", .{ feature, card_filename });

        const form_filename = try std.fmt.allocPrint(allocator, "views/{s}Form.html", .{Feature});
        defer allocator.free(form_filename);
        try fs_utils.writeFile(io, feature_dir, form_filename, form_html_content);
        std.debug.print("  create  src/features/{s}/{s}\n", .{ feature, form_filename });

        const edit_form_filename = try std.fmt.allocPrint(allocator, "views/{s}EditForm.html", .{Feature});
        defer allocator.free(edit_form_filename);
        try fs_utils.writeFile(io, feature_dir, edit_form_filename, edit_form_html_content);
        std.debug.print("  create  src/features/{s}/{s}\n", .{ feature, edit_form_filename });

        try fs_utils.writeFile(io, feature_dir, "views/page.html", page_html_content);
        std.debug.print("  create  src/features/{s}/views/page.html\n", .{feature});
    }

    const migration_path = try std.fmt.allocPrint(allocator, "src/core/db/migrations/{s}", .{migration_name});
    defer allocator.free(migration_path);
    try fs_utils.writeFile(io, root_dir, migration_path, migration_content);
    std.debug.print("  create  {s}\n", .{migration_path});

    const migrations_zig_tmpl = if (std.mem.eql(u8, db_module, "pg")) migrations_zig_pg_tmpl else migrations_zig_sqlite_tmpl;
    try migration_updater.registerMigration(io, allocator, root_dir, timestamp, plural, migrations_zig_tmpl);

    try mod_updater.updateFeaturesMod(io, allocator, features_dir, feature);
    std.debug.print("  update  src/features/mod.zig\n", .{});

    switch (try routes_updater.wireFeature(io, allocator, root_dir, feature)) {
        .automatic => std.debug.print("  (routes mounted by mountFeatures in src/main.zig)\n", .{}),
        .inserted => std.debug.print("  update  src/main.zig (.mountFeature(features.{s}))\n", .{feature}),
        .manual, .no_main => std.debug.print("warning: add `.mountFeature(features.{s})` to the server in src/main.zig\n", .{feature}),
    }

    std.debug.print("\nDone! Next:\n", .{});
    std.debug.print(migrate_hint, .{plural});
    std.debug.print("  spider routes    check what got registered, and who may call it\n", .{});
    std.debug.print("  access: src/features/{s}/routes.zig (defaults() and each route's config)\n", .{feature});
}

/// What the app's routes are behind, read from src/main.zig: what decides
/// the access a generated feature declares.
pub const Auth = enum {
    /// No auth middleware: every route is open, defaults() stays commented.
    none,
    /// A provider (Keycloak, JWKS, a marked middleware): users carry roles,
    /// so the feature gets a role of its own.
    roles,
    /// `spider g auth` (spider.session): one `role` column per user, so the
    /// feature is for any logged-in user.
    session,
};

fn authOfProject(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir) Auth {
    const main_content = root_dir.readFileAlloc(io, "src/main.zig", allocator, .limited(64 * 1024)) catch return .none;
    defer allocator.free(main_content);
    return authOf(main_content);
}

/// The auth `main_src` (a src/main.zig) sets up: the middlewares the
/// `route-access` convention looks for.
pub fn authOf(main_src: []const u8) Auth {
    if (std.mem.indexOf(u8, main_src, "spider.session.middleware()") != null) return .session;
    if (std.mem.indexOf(u8, main_src, "_auth.middleware()") != null or
        std.mem.indexOf(u8, main_src, "markAuthMiddleware") != null) return .roles;
    return .none;
}

const defaults_commented =
    "        // Who may use these routes. Once the app has auth (spider g auth),\n" ++
    "        // enable this and set the role; until then every route is open:\n" ++
    "        // .defaults(.{ .roles = &.{\"{{plural}}_admin\"} })\n";

/// The defaults() lines of a feature's routes.zig for `auth`.
fn defaultsLines(auth: Auth) []const u8 {
    return switch (auth) {
        .none => defaults_commented,
        .roles => "        // Who may use these routes: adjust the role (or use .org_roles).\n" ++
            "        .defaults(.{ .roles = &.{\"{{plural}}_admin\"} })\n",
        .session => "        // Who may use these routes: any logged-in user. For a role, use\n" ++
            "        // .roles = &.{\"admin\"} (the role column of the users table).\n" ++
            "        .defaults(.{ .authenticated = true })\n",
    };
}

/// The access column of routes_test.zig for routes declared with `auth`.
fn accessLabel(allocator: std.mem.Allocator, auth: Auth, plural: []const u8) ![]u8 {
    return switch (auth) {
        .none => allocator.dupe(u8, "-"),
        .roles => std.fmt.allocPrint(allocator, "roles:{s}_admin", .{plural}),
        .session => allocator.dupe(u8, "authenticated"),
    };
}

/// routes.zig with its defaults() line: active when the app has auth,
/// commented out otherwise (a role nobody can hold would answer 403 to
/// every request until auth exists).
pub fn renderRoutes(allocator: std.mem.Allocator, tmpl: []const u8, feature: []const u8, plural: []const u8, auth: Auth) ![]u8 {
    const with_defaults = try std.mem.replaceOwned(u8, allocator, tmpl, "{{defaults}}", defaultsLines(auth));
    defer allocator.free(with_defaults);
    return template_engine.renderTemplate(allocator, with_defaults, feature, plural);
}

/// For `spider g auth`: each feature whose routes.zig still has the
/// commented defaults() it was generated with gets the access `auth` gives
/// (what `spider g feature` writes in an app with that auth), and its
/// routes_test.zig the matching access column. Without it, every such
/// route would fail the `route-access` convention. A feature edited by
/// hand is left alone and named.
pub fn closeFeatures(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir, auth: Auth) !void {
    var features = root_dir.openDir(io, "src/features", .{ .iterate = true }) catch return;
    defer features.close(io);
    var it = features.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, "auth")) continue;
        var dir = features.openDir(io, entry.name, .{}) catch continue;
        defer dir.close(io);
        const routes = dir.readFileAlloc(io, "routes.zig", allocator, .limited(256 * 1024)) catch continue;
        defer allocator.free(routes);
        const closed = (try closeRoutes(allocator, routes, auth)) orelse {
            if (!declaresAnyAccess(routes))
                std.debug.print("  note: src/features/{s}/routes.zig declares no access: add a defaults(...) (spider check)\n", .{entry.name});
            continue;
        };
        defer allocator.free(closed.routes);
        defer allocator.free(closed.label);
        try fs_utils.writeFile(io, dir, "routes.zig", closed.routes);
        std.debug.print("  update  src/features/{s}/routes.zig (defaults: {s})\n", .{ entry.name, closed.label });
        const tests = dir.readFileAlloc(io, "routes_test.zig", allocator, .limited(256 * 1024)) catch continue;
        defer allocator.free(tests);
        const row_end = "\", \"-\" },\n";
        if (std.mem.indexOf(u8, tests, row_end) == null) continue;
        const new_end = try std.fmt.allocPrint(allocator, "\", \"{s}\" }},\n", .{closed.label});
        defer allocator.free(new_end);
        const new_tests = try std.mem.replaceOwned(u8, allocator, tests, row_end, new_end);
        defer allocator.free(new_tests);
        try fs_utils.writeFile(io, dir, "routes_test.zig", new_tests);
        std.debug.print("  update  src/features/{s}/routes_test.zig\n", .{entry.name});
    }
}

/// Whether `routes` names any access key: a feature that does not cannot
/// pass the `route-access` convention once the app has auth.
fn declaresAnyAccess(routes: []const u8) bool {
    for ([_][]const u8{ ".defaults(", ".public", ".authenticated", ".roles", ".org_roles", ".policy" }) |key| {
        if (std.mem.indexOf(u8, routes, key) != null) return true;
    }
    return false;
}

const Closed = struct { routes: []u8, label: []u8 };

/// `routes` with its generated, commented defaults() made active for
/// `auth`; null when it has no such lines (edited, or already active).
fn closeRoutes(allocator: std.mem.Allocator, routes: []const u8, auth: Auth) !?Closed {
    const head_end = std.mem.indexOf(u8, defaults_commented, "        // .defaults(").?;
    const head = defaults_commented[0..head_end];
    const start = std.mem.indexOf(u8, routes, head) orelse return null;
    const line = routes[start + head.len ..];
    const prefix = "        // .defaults(.{ .roles = &.{\"";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const plural_end = std.mem.indexOfPos(u8, line, prefix.len, "_admin\"} })\n") orelse return null;
    const plural = line[prefix.len..plural_end];
    const end = start + head.len + plural_end + "_admin\"} })\n".len;
    const active = try std.mem.replaceOwned(u8, allocator, defaultsLines(auth), "{{plural}}", plural);
    defer allocator.free(active);
    const out = try std.mem.concat(allocator, u8, &.{ routes[0..start], active, routes[end..] });
    errdefer allocator.free(out);
    return .{ .routes = out, .label = try accessLabel(allocator, auth, plural) };
}

/// The routes the templates register (method, path after the prefix), in
/// the order routes.zig lists them.
const html_routes = [_][2][]const u8{
    .{ "GET", "" },         .{ "GET", "/new" },         .{ "GET", "/:id/edit" },
    .{ "POST", "/create" }, .{ "POST", "/:id/update" }, .{ "POST", "/:id/delete" },
};
const api_routes = [_][2][]const u8{
    .{ "GET", "" }, .{ "GET", "/:id" }, .{ "POST", "" }, .{ "PATCH", "/:id" }, .{ "DELETE", "/:id" },
};

/// routes_test.zig: the access table matching routes.zig as generated
/// (what defaults() gives for the app's auth, "-" without).
pub fn renderRoutesTest(allocator: std.mem.Allocator, api: bool, feature: []const u8, plural: []const u8, auth: Auth) ![]u8 {
    const access = try accessLabel(allocator, auth, plural);
    defer allocator.free(access);
    var rows: std.ArrayListUnmanaged(u8) = .empty;
    defer rows.deinit(allocator);
    for (if (api) api_routes[0..] else html_routes[0..]) |r| {
        const line = try std.fmt.allocPrint(allocator, "        .{{ \"{s}\", \"/{s}{s}\", \"{s}\" }},\n", .{ r[0], plural, r[1], access });
        defer allocator.free(line);
        try rows.appendSlice(allocator, line);
    }
    const with_rows = try std.mem.replaceOwned(u8, allocator, routes_test_tmpl, "{{rows}}", rows.items);
    defer allocator.free(with_rows);
    return template_engine.renderTemplate(allocator, with_rows, feature, plural);
}

/// The next step about the new migration: main() applies the pending
/// migrations as the app starts (PostgreSQL and SQLite alike), so a restart
/// creates the table; `spider dev` restarts on save.
const migrate_hint = "  restart the app  it creates the {s} table as it starts (spider dev restarts on save; spider migrate only migrates)\n";

test "migrate_hint: a restart applies the migration" {
    try std.testing.expect(std.mem.indexOf(u8, migrate_hint, "restart the app") != null);
    try std.testing.expect(std.mem.indexOf(u8, migrate_hint, "answers 500") == null);
}

test "renderRoutesTest: one row per generated route, access matching defaults()" {
    const a = std.testing.allocator;
    const open = try renderRoutesTest(a, false, "post", "posts", .none);
    defer a.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, "        .{ \"POST\", \"/posts/:id/delete\", \"-\" },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "test \"post routes: method, path and access\"") != null);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, open, "        .{ \""));
    const closed = try renderRoutesTest(a, true, "post", "posts", .roles);
    defer a.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "        .{ \"PATCH\", \"/posts/:id\", \"roles:posts_admin\" },\n") != null);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, closed, "        .{ \""));
    try std.testing.expect(std.mem.indexOf(u8, closed, "{{") == null);
}

test "renderRoutes: defaults() active only when the app has auth" {
    const a = std.testing.allocator;
    const open = try renderRoutes(a, routes_tmpl, "post", "posts", .none);
    defer a.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, "        // .defaults(.{ .roles = &.{\"posts_admin\"} })\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "Group.init(\"/posts\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "{{") == null);

    const closed = try renderRoutes(a, routes_api_tmpl, "post", "posts", .roles);
    defer a.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\n        .defaults(.{ .roles = &.{\"posts_admin\"} })\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, ".patch(\"/:id\", controller.update, .{})") != null);
}

test "authOf: a provider middleware, a session, none" {
    try std.testing.expectEqual(Auth.roles, authOf("        .use(keycloak_auth.middleware())\n"));
    try std.testing.expectEqual(Auth.session, authOf("        .use(spider.session.middleware())\n"));
    try std.testing.expectEqual(Auth.none, authOf("        .use(spider.logger)\n"));
}

test "renderRoutes with a session: any logged-in user, and the test table says so" {
    const a = std.testing.allocator;
    const routes = try renderRoutes(a, routes_tmpl, "post", "posts", .session);
    defer a.free(routes);
    try std.testing.expect(std.mem.indexOf(u8, routes, "\n        .defaults(.{ .authenticated = true })\n") != null);
    const tests = try renderRoutesTest(a, false, "post", "posts", .session);
    defer a.free(tests);
    try std.testing.expect(std.mem.indexOf(u8, tests, "        .{ \"GET\", \"/posts\", \"authenticated\" },\n") != null);
}

test "closeRoutes: the generated commented defaults() becomes the auth's, an edited one is left" {
    const a = std.testing.allocator;
    const open = try renderRoutes(a, routes_tmpl, "post", "posts", .none);
    defer a.free(open);
    inline for (.{ Auth.session, Auth.roles }) |auth| {
        const closed = (try closeRoutes(a, open, auth)).?;
        defer a.free(closed.routes);
        defer a.free(closed.label);
        const expected = try renderRoutes(a, routes_tmpl, "post", "posts", auth);
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, closed.routes);
    }
    const edited = try std.mem.replaceOwned(u8, a, open, "// .defaults(", "// .defaults (");
    defer a.free(edited);
    try std.testing.expect((try closeRoutes(a, edited, .session)) == null);
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

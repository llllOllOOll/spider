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

    const routes_content = try renderRoutes(allocator, if (api) routes_api_tmpl else routes_tmpl, feature, plural, hasAuth(io, allocator, root_dir));
    defer allocator.free(routes_content);

    const index_html_content = try template_engine.renderTemplate(allocator, index_html_tmpl, feature, plural);
    defer allocator.free(index_html_content);

    const list_html_content = try template_engine.renderTemplate(allocator, list_html_tmpl, feature, plural);
    defer allocator.free(list_html_content);

    const card_html_content = try template_engine.renderTemplate(allocator, card_html_tmpl, feature, plural);
    defer allocator.free(card_html_content);

    const form_html_content = try template_engine.renderTemplate(allocator, form_html_tmpl, feature, plural);
    defer allocator.free(form_html_content);

    const edit_form_html_content = try template_engine.renderTemplate(allocator, edit_form_html_tmpl, feature, plural);
    defer allocator.free(edit_form_html_content);

    const page_html_content = try template_engine.renderTemplate(allocator, page_html_tmpl, feature, plural);
    defer allocator.free(page_html_content);

    const timestamp = migration_updater.generateTimestamp(io);
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
    try migration_updater.updateMigrationsZig(io, allocator, root_dir, timestamp, plural, migrations_zig_tmpl);
    std.debug.print("  update  src/core/db/migrations.zig\n", .{});

    // ensure src/core/db/mod.zig exists and exports migrations
    const db_mod_content = root_dir.readFileAlloc(io, "src/core/db/mod.zig", allocator, .limited(256)) catch "";
    if (db_mod_content.len == 0 or std.mem.indexOf(u8, db_mod_content, "pub const migrations") == null) {
        if (db_mod_content.len > 0) allocator.free(db_mod_content);
        try fs_utils.writeFile(io, root_dir, "src/core/db/mod.zig", "pub const migrations = @import(\"migrations.zig\");\n");
        std.debug.print("  create  src/core/db/mod.zig\n", .{});
    } else if (db_mod_content.len > 0) {
        allocator.free(db_mod_content);
    }

    // ensure src/core/mod.zig has pub const db = ...
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

    try mod_updater.updateFeaturesMod(io, allocator, features_dir, feature);
    std.debug.print("  update  src/features/mod.zig\n", .{});

    switch (try routes_updater.wireFeature(io, allocator, root_dir, feature)) {
        .automatic => std.debug.print("  (routes mounted by mountFeatures in src/main.zig)\n", .{}),
        .inserted => std.debug.print("  update  src/main.zig (.mountFeature(features.{s}))\n", .{feature}),
        .manual, .no_main => std.debug.print("warning: add `.mountFeature(features.{s})` to the server in src/main.zig\n", .{feature}),
    }

    std.debug.print("\nDone! Next:\n", .{});
    std.debug.print("  spider migrate   create the {s} table (until then /{s} answers 500)\n", .{ plural, plural });
    std.debug.print("  spider routes    check what got registered, and who may call it\n", .{});
    std.debug.print("  access: src/features/{s}/routes.zig (defaults() and each route's config)\n", .{feature});
}

/// The app already authenticates requests (spider g auth added a provider
/// middleware): generated routes then get an active defaults() role.
fn hasAuth(io: std.Io, allocator: std.mem.Allocator, root_dir: std.Io.Dir) bool {
    const main_content = root_dir.readFileAlloc(io, "src/main.zig", allocator, .limited(64 * 1024)) catch return false;
    defer allocator.free(main_content);
    return mainHasAuth(main_content);
}

fn mainHasAuth(main_src: []const u8) bool {
    return std.mem.indexOf(u8, main_src, "_auth.middleware()") != null;
}

/// routes.zig with its defaults() line: active when the app has auth,
/// commented out otherwise (a role nobody can hold would answer 403 to
/// every request until auth exists).
pub fn renderRoutes(allocator: std.mem.Allocator, tmpl: []const u8, feature: []const u8, plural: []const u8, with_auth: bool) ![]u8 {
    const defaults_active =
        "        // Who may use these routes: adjust the role (or use .org_roles).\n" ++
        "        .defaults(.{ .roles = &.{\"{{plural}}_admin\"} })\n";
    const defaults_commented =
        "        // Who may use these routes. Once the app has auth (spider g auth),\n" ++
        "        // enable this and set the role; until then every route is open:\n" ++
        "        // .defaults(.{ .roles = &.{\"{{plural}}_admin\"} })\n";
    const with_defaults = try std.mem.replaceOwned(u8, allocator, tmpl, "{{defaults}}", if (with_auth) defaults_active else defaults_commented);
    defer allocator.free(with_defaults);
    return template_engine.renderTemplate(allocator, with_defaults, feature, plural);
}

test "renderRoutes: defaults() active only when the app has auth" {
    const a = std.testing.allocator;
    const open = try renderRoutes(a, routes_tmpl, "post", "posts", false);
    defer a.free(open);
    try std.testing.expect(std.mem.indexOf(u8, open, "        // .defaults(.{ .roles = &.{\"posts_admin\"} })\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "Group.init(\"/posts\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "{{") == null);

    const closed = try renderRoutes(a, routes_api_tmpl, "post", "posts", true);
    defer a.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\n        .defaults(.{ .roles = &.{\"posts_admin\"} })\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, ".patch(\"/:id\", controller.update, .{})") != null);
}

test "mainHasAuth: a provider middleware in main.zig" {
    try std.testing.expect(mainHasAuth("        .use(keycloak_auth.middleware())\n"));
    try std.testing.expect(!mainHasAuth("        .use(spider.logger)\n"));
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

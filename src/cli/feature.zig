const std = @import("std");
const template_engine = @import("template_engine.zig");
const fs_utils = @import("fs_utils.zig");
const mod_updater = @import("mod_updater.zig");
const migration_updater = @import("migration_updater.zig");
const routes_updater = @import("routes_updater.zig");

// Embedded templates
const mod_tmpl = @embedFile("templates/feature/mod.zig.template");
const model_tmpl = @embedFile("templates/feature/model.zig.template");
const repository_tmpl = @embedFile("templates/feature/repository.zig.template");
const presenter_tmpl = @embedFile("templates/feature/presenter.zig.template");
const controller_tmpl = @embedFile("templates/feature/controller.zig.template");
const index_html_tmpl = @embedFile("templates/feature/index.html.template");
const migration_sql_tmpl = @embedFile("templates/feature/migration.sql.template");
const migrations_zig_tmpl = @embedFile("templates/migrations.zig.template");

pub fn run(io: std.Io, allocator: std.mem.Allocator, feature: []const u8) !void {
    const root_dir = try fs_utils.findProjectRoot(io);

    std.debug.print("Generating feature '{s}'...\n", .{feature});

    const Feature = try template_engine.capitalize(allocator, feature);
    defer allocator.free(Feature);

    var plural_buf: [256]u8 = undefined;
    const plural = template_engine.pluralize(feature, &plural_buf);

    const mod_content = try template_engine.renderTemplate(allocator, mod_tmpl, feature, plural);
    defer allocator.free(mod_content);

    const model_content = try template_engine.renderTemplate(allocator, model_tmpl, feature, plural);
    defer allocator.free(model_content);

    const repository_content = try template_engine.renderTemplate(allocator, repository_tmpl, feature, plural);
    defer allocator.free(repository_content);

    const presenter_content = try template_engine.renderTemplate(allocator, presenter_tmpl, feature, plural);
    defer allocator.free(presenter_content);

    const controller_content = try template_engine.renderTemplate(allocator, controller_tmpl, feature, plural);
    defer allocator.free(controller_content);

    const index_html_content = try template_engine.renderTemplate(allocator, index_html_tmpl, feature, plural);
    defer allocator.free(index_html_content);

    const timestamp = migration_updater.generateTimestamp(io);
    const migration_name = try std.fmt.allocPrint(allocator, "{d}_create_{s}.sql", .{ timestamp, plural });
    defer allocator.free(migration_name);

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

    try feature_dir.createDir(io, "views", .default_dir);

    try fs_utils.writeFile(io, feature_dir, "mod.zig", mod_content);
    std.debug.print("  create  src/features/{s}/mod.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "model.zig", model_content);
    std.debug.print("  create  src/features/{s}/model.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "repository.zig", repository_content);
    std.debug.print("  create  src/features/{s}/repository.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "presenter.zig", presenter_content);
    std.debug.print("  create  src/features/{s}/presenter.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "controller.zig", controller_content);
    std.debug.print("  create  src/features/{s}/controller.zig\n", .{feature});

    try fs_utils.writeFile(io, feature_dir, "views/index.html", index_html_content);
    std.debug.print("  create  src/features/{s}/views/index.html\n", .{feature});

    const migration_path = try std.fmt.allocPrint(allocator, "src/core/db/migrations/{s}", .{migration_name});
    defer allocator.free(migration_path);
    try fs_utils.writeFile(io, root_dir, migration_path, migration_content);
    std.debug.print("  create  {s}\n", .{migration_path});

    try migration_updater.updateMigrationsZig(io, allocator, root_dir, timestamp, plural, migrations_zig_tmpl);
    std.debug.print("  update  src/core/db/migrations.zig\n", .{});

    try mod_updater.updateFeaturesMod(io, allocator, features_dir, feature);
    std.debug.print("  update  src/features/mod.zig\n", .{});

    try routes_updater.updateMainZig(io, allocator, root_dir, feature, plural);
    std.debug.print("  update  src/main.zig\n", .{});

    std.debug.print("\nDone!\n", .{});
}

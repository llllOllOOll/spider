const std = @import("std");

// Embedded templates
const mod_tmpl = @embedFile("templates/feature/mod.zig.template");
const model_tmpl = @embedFile("templates/feature/model.zig.template");
const repository_tmpl = @embedFile("templates/feature/repository.zig.template");
const presenter_tmpl = @embedFile("templates/feature/presenter.zig.template");
const controller_tmpl = @embedFile("templates/feature/controller.zig.template");
const index_html_tmpl = @embedFile("templates/feature/index.html.template");
const migration_sql_tmpl = @embedFile("templates/feature/migration.sql.template");

fn capitalize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return allocator.dupe(u8, name);
    const result = try allocator.alloc(u8, name.len);
    result[0] = std.ascii.toUpper(name[0]);
    for (name[1..], 1..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

fn pluralize(name: []const u8, buf: []u8) []const u8 {
    if (std.mem.endsWith(u8, name, "s")) {
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 's';
    return buf[0 .. name.len + 1];
}

fn renderTemplate(allocator: std.mem.Allocator, tmpl: []const u8, feature: []const u8, plural: []const u8) ![]u8 {
    const Feature = try capitalize(allocator, feature);
    defer allocator.free(Feature);

    const step1 = try std.mem.replaceOwned(u8, allocator, tmpl, "{{feature}}", feature);
    defer allocator.free(step1);

    const step2 = try std.mem.replaceOwned(u8, allocator, step1, "{{Feature}}", Feature);
    defer allocator.free(step2);

    return try std.mem.replaceOwned(u8, allocator, step2, "{{plural}}", plural);
}

fn findProjectRoot(io: std.Io) !std.Io.Dir {
    var depth: u32 = 0;
    var current = std.Io.Dir.cwd();

    while (depth < 20) : (depth += 1) {
        if (current.openFile(io, "build.zig.zon", .{})) |file| {
            file.close(io);
            return current;
        } else |_| {}

        const parent = current.openDir(io, "..", .{}) catch break;
        current = parent;
    }

    return error.NotAProjectRoot;
}

fn updateFeaturesMod(io: std.Io, allocator: std.mem.Allocator, features_dir: std.Io.Dir, feature: []const u8) !void {
    const mod_path = "mod.zig";

    // Read existing content, default to empty string if file doesn't exist
    const existing = features_dir.readFileAlloc(io, mod_path, allocator, .limited(64 * 1024)) catch "";
    defer if (existing.len > 0 and existing.ptr != "".ptr) allocator.free(existing);

    // New line to add
    const new_line = try std.fmt.allocPrint(allocator, "pub const {s} = @import(\"{s}/mod.zig\");\n", .{ feature, feature });
    defer allocator.free(new_line);

    // Combine existing content with new line
    const new_content = try std.mem.concat(allocator, u8, &.{ existing, new_line });
    defer allocator.free(new_content);

    // Write back to file
    try writeFile(io, features_dir, mod_path, new_content);
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(io, parent) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn generateTimestamp(io: std.Io) u64 {
    const now = std.Io.Clock.now(.real, io);
    return @intCast(@divFloor(now.nanoseconds, 1_000_000_000));
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, feature: []const u8) !void {
    const root_dir = try findProjectRoot(io);

    std.debug.print("Generating feature '{s}'...\n", .{feature});

    const Feature = try capitalize(allocator, feature);
    defer allocator.free(Feature);

    var plural_buf: [256]u8 = undefined;
    const plural = pluralize(feature, &plural_buf);

    const mod_content = try renderTemplate(allocator, mod_tmpl, feature, plural);
    defer allocator.free(mod_content);

    const model_content = try renderTemplate(allocator, model_tmpl, feature, plural);
    defer allocator.free(model_content);

    const repository_content = try renderTemplate(allocator, repository_tmpl, feature, plural);
    defer allocator.free(repository_content);

    const presenter_content = try renderTemplate(allocator, presenter_tmpl, feature, plural);
    defer allocator.free(presenter_content);

    const controller_content = try renderTemplate(allocator, controller_tmpl, feature, plural);
    defer allocator.free(controller_content);

    const index_html_content = try renderTemplate(allocator, index_html_tmpl, feature, plural);
    defer allocator.free(index_html_content);

    const timestamp = generateTimestamp(io);
    const migration_name = try std.fmt.allocPrint(allocator, "{d}_create_{s}.sql", .{ timestamp, plural });
    defer allocator.free(migration_name);

    const migration_content = try renderTemplate(allocator, migration_sql_tmpl, feature, plural);
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

    try writeFile(io, feature_dir, "mod.zig", mod_content);
    std.debug.print("  create  src/features/{s}/mod.zig\n", .{feature});

    try writeFile(io, feature_dir, "model.zig", model_content);
    std.debug.print("  create  src/features/{s}/model.zig\n", .{feature});

    try writeFile(io, feature_dir, "repository.zig", repository_content);
    std.debug.print("  create  src/features/{s}/repository.zig\n", .{feature});

    try writeFile(io, feature_dir, "presenter.zig", presenter_content);
    std.debug.print("  create  src/features/{s}/presenter.zig\n", .{feature});

    try writeFile(io, feature_dir, "controller.zig", controller_content);
    std.debug.print("  create  src/features/{s}/controller.zig\n", .{feature});

    try writeFile(io, feature_dir, "views/index.html", index_html_content);
    std.debug.print("  create  src/features/{s}/views/index.html\n", .{feature});

    const migration_path = try std.fmt.allocPrint(allocator, "src/core/db/migrations/{s}", .{migration_name});
    defer allocator.free(migration_path);
    try writeFile(io, root_dir, migration_path, migration_content);
    std.debug.print("  create  {s}\n", .{migration_path});

    try updateFeaturesMod(io, allocator, features_dir, feature);
    std.debug.print("  update  src/features/mod.zig\n", .{});

    std.debug.print("\nDone! Add these routes to src/main.zig:\n", .{});
    std.debug.print("  .get(\"/{s}\", {s}.controller.index)\n", .{ plural, feature });
    std.debug.print("  .post(\"/{s}/create\", {s}.controller.create)\n", .{ plural, feature });
    std.debug.print("  .post(\"/{s}/:id/update\", {s}.controller.update)\n", .{ plural, feature });
    std.debug.print("  .post(\"/{s}/:id/delete\", {s}.controller.delete)\n", .{ plural, feature });
}

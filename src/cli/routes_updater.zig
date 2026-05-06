const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub fn updateMainZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    feature: []const u8,
    plural: []const u8,
) !void {
    const main_path = "src/main.zig";

    const existing = root_dir.readFileAlloc(io, main_path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("warning: src/main.zig not found, skipping routes update\n", .{});
        return;
    };
    defer allocator.free(existing);

    // 1. Adicionar import após "const home = features.home;"
    const import_line = try std.fmt.allocPrint(allocator,
        "const {s} = features.{s};\n",
        .{ feature, feature },
    );
    defer allocator.free(import_line);

    const import_marker = "const home = features.home;\n";
    const after_imports = std.mem.indexOf(u8, existing, import_marker) orelse {
        std.debug.print("warning: could not find import marker in main.zig\n", .{});
        return;
    };
    const insert_pos = after_imports + import_marker.len;

    const with_import = try std.mem.concat(allocator, u8, &.{
        existing[0..insert_pos],
        import_line,
        existing[insert_pos..],
    });
    defer allocator.free(with_import);

    // 2. Adicionar rotas antes de .listen(
    const routes = try std.fmt.allocPrint(allocator,
        "        .get(\"/{s}\", {s}.controller.index)\n" ++
        "        .post(\"/{s}/create\", {s}.controller.create)\n" ++
        "        .post(\"/{s}/:id/update\", {s}.controller.update)\n" ++
        "        .post(\"/{s}/:id/delete\", {s}.controller.delete)\n",
        .{ plural, feature, plural, feature, plural, feature, plural, feature },
    );
    defer allocator.free(routes);

    const listen_marker = "        .listen(";
    const listen_pos = std.mem.indexOf(u8, with_import, listen_marker) orelse {
        std.debug.print("warning: could not find .listen( in main.zig\n", .{});
        return;
    };

    const final_content = try std.mem.concat(allocator, u8, &.{
        with_import[0..listen_pos],
        routes,
        with_import[listen_pos..],
    });
    defer allocator.free(final_content);

    try fs_utils.writeFile(io, root_dir, main_path, final_content);
}

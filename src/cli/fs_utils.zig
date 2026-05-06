const std = @import("std");

pub fn findProjectRoot(io: std.Io) !std.Io.Dir {
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

pub fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
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

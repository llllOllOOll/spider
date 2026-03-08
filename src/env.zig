const std = @import("std");

pub const c = @cImport({
    @cInclude("stdlib.h");
});

pub fn loadEnv(allocator: std.mem.Allocator, path: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_index| {
            const key = std.mem.trim(u8, trimmed[0..eq_index], " \t\r");
            const value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r");

            if (key.len > 0) {
                const key_z = try allocator.dupeZ(u8, key);
                defer allocator.free(key_z);

                const value_z = try allocator.dupeZ(u8, value);
                defer allocator.free(value_z);

                _ = c.setenv(key_z.ptr, value_z.ptr, 1);
            }
        }
    }
}

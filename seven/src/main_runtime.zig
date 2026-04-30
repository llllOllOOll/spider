const std = @import("std");
const lib = @import("lib.zig");

// ZERO declaração de spider_templates
// Spider detecta automaticamente → modo runtime/disco

pub fn main() void {
    std.debug.print("\n=== Spider POC — Runtime Mode ===\n\n", .{});

    std.debug.print("--- GET / (normal request) ---\n", .{});
    lib.view("home/index", .{ .name = "Spider" }, false);

    std.debug.print("\n--- GET / (HX-Request: true) ---\n", .{});
    lib.view("home/index", .{ .name = "Spider" }, true);

    std.debug.print("\n--- GET /layout ---\n", .{});
    lib.view("layout", .{}, false);

    std.debug.print("\n--- GET /games (não existe) ---\n", .{});
    lib.view("games/index", .{}, false);

    std.debug.print("\n=== fim ===\n", .{});
}

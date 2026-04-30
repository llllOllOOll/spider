const std = @import("std");
const lib = @import("lib.zig");

// ZERO configuração de templates

pub fn main() void {
    std.debug.print("\n=== ALT 2: zero config ===\n\n", .{});
    lib.view("layout", .{}, false);
    std.debug.print("\n=== fim ===\n", .{});
}

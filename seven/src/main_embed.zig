const std = @import("std");
const lib = @import("lib.zig");
const tmpl = @import("templates.zig");

// modo embed — uma linha — dev declara isso no main.zig
pub const spider_templates = tmpl.EmbeddedTemplates;

// handlers simulados — igual ao SpiderStack real
fn homeHandler() void {
    lib.view("home/index", .{ .name = "Spider" }, false);
}

fn homeHandlerHTMX() void {
    lib.view("home/index", .{ .name = "Spider" }, true);
}

fn layoutHandler() void {
    lib.view("layout", .{}, false);
}

fn notFoundHandler() void {
    lib.view("games/index", .{}, false); // não existe — deve retornar NOT FOUND
}

pub fn main() void {
    std.debug.print("\n=== Spider POC — caso real SpiderStack ===\n\n", .{});

    std.debug.print("--- GET / (normal request) ---\n", .{});
    homeHandler();

    std.debug.print("\n--- GET / (HX-Request: true) ---\n", .{});
    homeHandlerHTMX();

    std.debug.print("\n--- GET /layout (sem extends) ---\n", .{});
    layoutHandler();

    std.debug.print("\n--- GET /games (template não existe) ---\n", .{});
    notFoundHandler();

    std.debug.print("\n=== fim ===\n", .{});
}

const std = @import("std");
const lib = @import("lib.zig");
const tmpl = @import("templates.zig");

pub const spider_templates = tmpl.EmbeddedTemplates;

pub fn main() void {
    std.debug.print("\n=== COMPARAÇÃO: embed vs runtime ===\n\n", .{});

    const cases = [_]struct {
        name: []const u8,
        is_htmx: bool,
    }{
        .{ .name = "home/index", .is_htmx = false },
        .{ .name = "home/index", .is_htmx = true },
        .{ .name = "layout", .is_htmx = false },
        .{ .name = "games/index", .is_htmx = false },
    };

    for (cases) |case| {
        std.debug.print("=== '{s}' htmx={} ===\n", .{ case.name, case.is_htmx });

        std.debug.print("[EMBED]   ", .{});
        const embed_result = lib.viewCapture(case.name, case.is_htmx, .embed);

        std.debug.print("[RUNTIME] ", .{});
        const runtime_result = lib.viewCapture(case.name, case.is_htmx, .runtime);

        if (embed_result != null and runtime_result != null) {
            if (std.mem.eql(u8, embed_result.?, runtime_result.?)) {
                std.debug.print("✅ IDENTICAL\n\n", .{});
            } else {
                std.debug.print("❌ DIFFERENT\n\n", .{});
            }
        } else if (embed_result == null and runtime_result == null) {
            std.debug.print("✅ BOTH NOT FOUND\n\n", .{});
        } else {
            std.debug.print("❌ ONE FOUND, ONE NOT\n\n", .{});
        }
    }
}

const std = @import("std");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Use default Io (Threaded)
    // Try explicit IoUring - but this has issues
    // For now use the working default
    try server.start(gpa.allocator(), init.io);
}

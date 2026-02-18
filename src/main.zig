const std = @import("std");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // init.gpa = GeneralPurposeAllocator (threadsafe, leak checking in debug)
    // init.io  = platform default Io (io_uring on Linux)
    try server.start(init.gpa, init.io);
}

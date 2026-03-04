const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //
    // const allocator = gpa.allocator();
    // defer _ = gpa.deinit();

    var client = std.http.Client{ .io = io, .allocator = allocator };
    defer client.deinit();

    var body = std.ArrayList(usize).empty; // .initCapacity(allocator, usize);
    // defer body.deinit();

    const uri = try std.Uri.parse("https://api.quotable.io/random");
    const result = try client.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .response_storage = .{ .dynamic = &body },
    });

    if (result.status == .ok) {
        std.debug.print("Resposta: {s}\n", .{body.items});
    }
}

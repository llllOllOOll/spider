const std = @import("std");

/// Context represents the HTTP request context
/// Provides helpers for reading requests and writing responses
pub const Ctx = struct {
    // HTTP request
    request: std.http.Server.Request,
    arena: std.mem.Allocator,

    /// Send a JSON response
    pub fn json(self: *Ctx, value: anytype) !void {
        // Simple JSON serialization
        var buffer: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();

        const json_string = try std.json.Stringify.valueAlloc(allocator, value, .{});

        // Send response
        try self.request.respond(json_string, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }

    /// Send a plain text response
    pub fn text(self: *Ctx, content: []const u8) !void {
        try self.request.respond(content, .{
            .status = .ok,
        });
    }

    /// Get the request path
    pub fn getPath(self: *Ctx) []const u8 {
        return self.request.head.target;
    }

    /// Get the request method
    pub fn getMethod(self: *Ctx) []const u8 {
        return @tagName(self.request.head.method);
    }
};

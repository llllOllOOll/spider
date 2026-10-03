const std = @import("std");
const http = std.http;

const Headers = @import("headers.zig").Headers;

pub const Response = struct {
    status: http.Status,
    headers: Headers,
    arena: *std.heap.ArenaAllocator,
    body_text: []const u8,
    http_client: *http.Client,
    /// True when `http_client` was created just for this one request (the
    /// standalone get/post/etc path) — this Response then owns its lifetime.
    /// False when `http_client` belongs to a persistent `pacman.Client`
    /// (reused across many requests): in that case `Client.deinit()` closes
    /// it, not this Response — destroying it here would leave every
    /// subsequent request through that Client using a freed http.Client.
    owns_http_client: bool,

    pub fn deinit(self: *Response) void {
        if (self.owns_http_client) {
            self.http_client.deinit();
            self.arena.allocator().destroy(self.http_client);
        }
        self.arena.deinit();
        self.arena.child_allocator.destroy(self.arena);
    }

    pub fn text(self: *Response) []const u8 {
        return self.body_text;
    }

    pub fn json(self: *Response, comptime T: type) !std.json.Parsed(T) {
        const allocator = self.arena.allocator();
        return try std.json.parseFromSlice(T, allocator, self.body_text, .{
            .ignore_unknown_fields = true,
        });
    }
};

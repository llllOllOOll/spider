const std = @import("std");
const http = std.http;

pub const Headers = struct {
    items: []http.Header,

    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
};

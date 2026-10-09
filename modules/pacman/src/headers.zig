//! The headers of a response.

const std = @import("std");
const http = std.http;

/// The headers a server answered with. Names and values live in the
/// response: they are gone after `Response.deinit()`.
pub const Headers = struct {
    /// Every header, in the order received. A header with an empty value is
    /// left out.
    items: []http.Header,

    /// The value of the first header called `name` (case does not matter), or
    /// null.
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
};

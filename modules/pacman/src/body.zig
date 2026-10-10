//! The body of a request, as `FetchOptions.body` takes it.

const std = @import("std");

/// What a request sends. Each kind sets a `Content-Type` unless
/// `FetchOptions.headers` (or, for a `Client`, its own headers) already has
/// one. Only POST, PUT and PATCH take a body (see `FetchOptions.body`).
pub const Body = union(enum) {
    /// Bytes sent as they are. `Content-Type: application/octet-stream`.
    raw: []const u8,
    /// JSON text, already serialized (it is not checked). `Content-Type:
    /// application/json`.
    json: []const u8,
    /// Name/value pairs, sent URL-encoded (a space goes as `%20`, not `+`).
    /// `Content-Type: application/x-www-form-urlencoded`.
    form: []const [2][]const u8,
};

/// `.{ .json = serialized }`: a body from JSON text that is already serialized.
pub fn jsonBody(serialized: []const u8) Body {
    return .{ .json = serialized };
}

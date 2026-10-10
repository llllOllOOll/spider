//! Typed request extractors: an alternative to the classic `fn(*Ctx) !Response`
//! handler signature. A handler may instead take `Path(T, "name")`, `Form(T)`
//! and `Loaded(T)` parameters (in any order, mixed with `*Ctx`);
//! `buildAutoWrapper` in `core/handler.zig` fills them in before calling it.

const std = @import("std");

/// A handler parameter filled from a `:name` segment of the route, already
/// converted: an integer type or `[]const u8`.
///
/// ```zig
/// fn show(c: *spider.Ctx, id: spider.Path(i64, "id")) !spider.Response {
///     return c.json(.{ .id = id.value }, .{});
/// }
/// ```
///
/// A value that is not a `T` (`/posts/abc` for an integer, or a number
/// that does not fit in `T`) never reaches the handler: the request fails
/// with `error.InvalidPathParam`, a 400. A route without a `:name` segment
/// of that name fails with `error.MissingPathParam`. Integers are read in
/// base 10; a `[]const u8` is the segment as it came in the URL, not
/// percent-decoded.
pub fn Path(comptime T: type, comptime name: []const u8) type {
    switch (@typeInfo(T)) {
        .int => {},
        else => if (T != []const u8) @compileError(
            "spider.Path: unsupported type `" ++ @typeName(T) ++
                "` — only integer types and []const u8 are supported",
        ),
    }

    return struct {
        // internal: how the server tells the extractors apart.
        pub const spider_kind = .path;
        // internal: the type the extractor carries.
        pub const Inner = T;
        // internal: the route segment this one reads.
        pub const param_name = name;
        value: T,
    };
}

/// A handler parameter filled from the submitted form, as `Ctx.parseForm`
/// would:
///
/// ```zig
/// const Input = struct { title: []const u8 = "", body: []const u8 = "" };
///
/// fn create(c: *spider.Ctx, form: spider.Form(Input)) !spider.Response {
///     return c.json(.{ .title = form.value.title }, .{});
/// }
/// ```
///
/// An error of `parseForm` (`error.BodyEmpty` for a request without a
/// body) is the request's error, and the handler is not called.
pub fn Form(comptime T: type) type {
    return struct {
        // internal: how the server tells the extractors apart.
        pub const spider_kind = .form;
        // internal: the type the extractor carries.
        pub const Inner = T;
        value: T,
    };
}

/// The resource the route's `spider.resourcePolicy(name, T, ...)` loaded and
/// allowed: `fn edit(post: spider.Loaded(Post), c: *spider.Ctx)`, then
/// `post.value`, a `*T` that lives in the request arena. A route without
/// such a policy fails with error.ResourceNotLoaded (a 500: the route is
/// wired wrong).
pub fn Loaded(comptime T: type) type {
    return struct {
        // internal: how the server tells the extractors apart.
        pub const spider_kind = .loaded;
        // internal: the type the extractor carries.
        pub const Inner = T;
        value: *T,
    };
}

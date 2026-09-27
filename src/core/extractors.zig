//! Typed request extractors — alternative to the classic `fn(*Ctx) !Response`
//! handler signature. A handler may instead take `Path(T, "name")` and/or
//! `Form(T)` parameters (in any order, mixed with `*Ctx`), and `app.zig`'s
//! `buildAutoWrapper` fills them in before calling the handler. See
//! `buildAutoWrapper` in `core/app.zig` for the dispatch side of this.

const std = @import("std");

pub fn Path(comptime T: type, comptime name: []const u8) type {
    switch (@typeInfo(T)) {
        .int => {},
        else => if (T != []const u8) @compileError(
            "spider.Path: unsupported type `" ++ @typeName(T) ++
                "` — only integer types and []const u8 are supported",
        ),
    }

    return struct {
        pub const spider_kind = .path;
        pub const Inner = T;
        pub const param_name = name;
        value: T,
    };
}

pub fn Form(comptime T: type) type {
    return struct {
        pub const spider_kind = .form;
        pub const Inner = T;
        value: T,
    };
}

/// The resource the route's `spider.resourcePolicy(name, T, ...)` loaded and
/// allowed: `fn edit(post: spider.Loaded(Post), c: *spider.Ctx)`, then
/// `post.value`. A route without such a policy fails with
/// error.ResourceNotLoaded (a 500: the route is wired wrong).
pub fn Loaded(comptime T: type) type {
    return struct {
        pub const spider_kind = .loaded;
        pub const Inner = T;
        value: *T,
    };
}

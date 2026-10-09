//! Which middlewares authenticate requests, so the server can tell whether
//! an app has auth (the route listing reports it; `spider routes --check`
//! only flags routes with no declared access when there is auth).
//!
//! Spider's providers mark their middleware when it's created (jwks /
//! keycloak, clerk, HS256 `auth`). An app with its own session middleware
//! marks it with `spider.markAuthMiddleware(mw)`.
//!
//! Filled while the app is set up (single thread, before listen()); read
//! afterwards.
//!
//! Middlewares are told apart by address. In release builds the compiler
//! may give two functions with identical bodies the same address; marking
//! one of them then marks both. Real auth middlewares differ from the
//! others, so this only shows with trivial pass-through functions.

const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;

var marked: [16]MiddlewareFn = undefined;
var count: usize = 0;

/// Tells Spider that `mw` is a middleware that authenticates requests
/// (`spider.markAuthMiddleware`). An app with its own session or token
/// middleware marks it before `listen()`; Spider's providers mark theirs.
/// With auth present, the route listing and `spider routes --check` flag the
/// routes that declare no access. Marking twice is harmless. Panics past 16
/// marked middlewares.
pub fn mark(mw: MiddlewareFn) void {
    if (isMarked(mw)) return;
    if (count == marked.len) @panic("spider.markAuthMiddleware: more than 16 auth middlewares");
    marked[count] = mw;
    count += 1;
}

// internal: the server asks it for each `use`/`useAt` middleware.
pub fn isMarked(mw: MiddlewareFn) bool {
    for (marked[0..count]) |m| if (m == mw) return true;
    return false;
}

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;

// Each with a body no other function has: identical functions (a plain
// `return next(c)` exists in other tests too) can be merged into one address
// in release builds (see the note at the top).
fn testMw(c: *Ctx, next: NextFn) anyerror!Response {
    c.setErrorDetail("auth_marker test: marked");
    return next(c);
}
fn otherMw(c: *Ctx, next: NextFn) anyerror!Response {
    c.setErrorDetail("auth_marker test: other");
    return next(c);
}

test "mark / isMarked: only the marked middleware, marking twice is harmless" {
    try std.testing.expect(!isMarked(testMw));
    mark(testMw);
    mark(testMw);
    try std.testing.expect(isMarked(testMw));
    try std.testing.expect(!isMarked(otherMw));
}

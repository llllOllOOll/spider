//! `spider.dbgRequest`: a middleware that prints each incoming request to
//! stderr. A teaching and debugging aid, not for production.

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;

/// Prints the incoming HTTP request shaped like the Web standard `Request`
/// interface (method, url, headers, body) -- a teaching aid for introducing
/// the Fetch API request/response model. Pairs with `dbgResponse`, which
/// prints the matching `Response` side after the handler runs.
pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    const head = c.request.head;

    std.debug.print(
        \\
        \\+- Request ---------------------------------------
        \\| method:  {s}
        \\| url:     {s}
        \\| version: {s}
        \\| headers:
        \\
    , .{ @tagName(head.method), head.target, @tagName(head.version) });

    // `c.request.iterateHeaders()` can only run once, while the underlying
    // reader is still in its `.received_head` state -- app.zig's dispatch
    // loop already consumes it once (into `c._headers`) before running any
    // middleware, and consumes it again to read the body for requests that
    // have one. Calling it here directly would hit that reader's internal
    // assert. `c._headers` is the safe, already-parsed copy.
    var it = c._headers.iterator();
    while (it.next()) |entry| {
        std.debug.print("|   {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    std.debug.print("| body:    {?s}\n+---------------------------------------------------\n", .{c.getBody()});

    return next(c);
}

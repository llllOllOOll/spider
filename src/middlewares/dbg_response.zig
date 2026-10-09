//! `spider.dbgResponse`: a middleware that prints each outgoing response to
//! stderr. A teaching and debugging aid, not for production.

const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;

/// Prints the outgoing HTTP response shaped like the Web standard `Response`
/// interface (status, statusText, ok, headers, body) -- pairs with
/// `dbgRequest` for teaching the Fetch API request/response model.
pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    const resp = try next(c);

    const status_int: u16 = @intFromEnum(resp.status);
    const status_text = resp.status.phrase() orelse "";
    const ok = status_int >= 200 and status_int < 300;

    std.debug.print(
        \\
        \\+- Response ----------------------------------------
        \\| status:       {d} {s}
        \\| ok:           {}
        \\| content_type: {s}
        \\| headers:
        \\
    , .{ status_int, status_text, ok, resp.content_type });

    for (resp.headers) |h| {
        std.debug.print("|   {s}: {s}\n", .{ h[0], h[1] });
    }
    for (resp.cookies) |ck| {
        std.debug.print("|   set-cookie: {s}\n", .{ck[1]});
    }

    std.debug.print("| body:         {?s}\n+----------------------------------------------------\n", .{resp.body});

    return resp;
}

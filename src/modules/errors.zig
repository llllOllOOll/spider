//! spider.errorHandler(.{ ... }): a ready-made `onError` that answers each
//! kind of caller the way it can use the error:
//!
//!   - fetch()/JSON callers (c.wantsJson()):  { "<json_key>": message, "request_id": rid }
//!   - htmx requests: the status is kept, nothing is swapped (HX-Reswap:
//!     none) and an HX-Trigger event (`toast_event`) carries
//!     { message, type: "warning" | "error" } for the page to show;
//!   - full-page navigation: the `forbidden_view` for 403 (when set),
//!     otherwise a plain-text message.
//!
//! The status comes from spider.statusForError(). 5xx is logged at err level
//! with request id, method, path, user and org; 4xx is left to the request
//! logger. An app keeps full control by passing its own function to
//! `onError` instead (or wrapping this one).

const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const ErrorHandler = ctx_mod.ErrorHandler;
const statusForError = ctx_mod.statusForError;

pub const Messages = struct {
    forbidden: []const u8 = "You don't have permission to do this.",
    not_found: []const u8 = "Not found.",
    conflict: []const u8 = "This record already exists or is still in use.",
    unprocessable: []const u8 = "This operation isn't allowed.",
    busy: []const u8 = "The system is busy right now. Try again in a moment.",
    /// Used for 400 when the error carries no detail (c.setErrorDetail).
    bad_request: []const u8 = "Invalid data. Check it and try again.",
    /// 5xx; must contain one `{s}`, replaced by the request id.
    internal: []const u8 = "Unexpected error. Try again (ref. {s}).",
};

pub const Options = struct {
    /// error.Unauthorized redirects here for every kind of request
    /// (null: answered like any other error, 401).
    unauthorized_redirect: ?[]const u8 = null,
    /// Key of the message in JSON error bodies.
    json_key: []const u8 = "error",
    /// htmx event name raised through HX-Trigger.
    toast_event: []const u8 = "spider:toast",
    /// View rendered for a full-page 403, with `.user_name` (the auth name
    /// claim). null: plain text.
    forbidden_view: ?[]const u8 = null,
    /// error.TemplateNotFound answers 404 instead of 500.
    template_not_found_is_404: bool = false,
    messages: Messages = .{},
};

pub fn errorHandler(comptime opts: Options) ErrorHandler {
    return struct {
        fn handle(c: *Ctx, err: anyerror) anyerror!Response {
            if (opts.unauthorized_redirect) |to| {
                if (err == error.Unauthorized) return c.redirect(to);
            }

            const status: std.http.Status = if (opts.template_not_found_is_404 and err == error.TemplateNotFound)
                .not_found
            else
                statusForError(err);
            const code = @intFromEnum(status);
            if (code >= 500) {
                const user = c.params.get("_auth_sub") orelse "-";
                const org = c.activeOrgId() orelse "-";
                // warn under `zig test`: the test runner fails any test that logs at err.
                const log = if (@import("builtin").is_test) std.log.warn else std.log.err;
                log("rid={s} {s} {s} user={s} org={s}: {s}{s}{s}", .{ c.requestId(), c.getMethod(), c.getPath(), user, org, @errorName(err), if (c.errorDetail() != null) " — " else "", c.errorDetail() orelse "" });
            }

            const message = try userMessage(c, err, status);

            if (c.wantsJson()) {
                var out: std.Io.Writer.Allocating = .init(c.arena);
                var js: std.json.Stringify = .{ .writer = &out.writer };
                try js.beginObject();
                try js.objectField(opts.json_key);
                try js.write(message);
                try js.objectField("request_id");
                try js.write(c.requestId());
                try js.endObject();
                return Response{ .status = status, .body = out.written(), .content_type = "application/json" };
            }

            if (c.isHtmx()) {
                var out: std.Io.Writer.Allocating = .init(c.arena);
                var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .escape_unicode = true } };
                try js.beginObject();
                try js.objectField(opts.toast_event);
                try js.write(.{ .message = message, .type = if (code >= 500) "error" else "warning" });
                try js.endObject();
                const hdrs = try c.arena.alloc([2][]const u8, 2);
                hdrs[0] = .{ "HX-Trigger", out.written() };
                hdrs[1] = .{ "HX-Reswap", "none" };
                return Response{ .status = status, .body = "", .content_type = "text/plain", .headers = hdrs };
            }

            if (opts.forbidden_view) |view| {
                if (err == error.Forbidden) {
                    return c.view(view, .{ .user_name = c.params.get("_auth_name") orelse "" }, .{ .status = .forbidden });
                }
            }
            return c.text(message, .{ .status = status });
        }

        fn userMessage(c: *Ctx, err: anyerror, status: std.http.Status) ![]const u8 {
            const m = opts.messages;
            return switch (@intFromEnum(status)) {
                403 => m.forbidden,
                404 => m.not_found,
                409 => m.conflict,
                422 => m.unprocessable,
                503 => m.busy,
                400 => c.errorDetail() orelse m.bad_request,
                else => if (@intFromEnum(status) >= 500)
                    try std.fmt.allocPrint(c.arena, m.internal, .{c.requestId()})
                else
                    @errorName(err),
            };
        }
    }.handle;
}

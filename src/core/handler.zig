//! Turning handler functions into the router's `Handler`: typed extractors
//! (spider.Path / spider.Form) and plain `fn (*Ctx) !Response`. Shared by
//! Server (core/app.zig) and Group (routing/group.zig).

const std = @import("std");
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const Handler = @import("../routing/router.zig").Handler;

// Typed extractors (spider.Path/spider.Form, see core/extractors.zig) are
// recognized by duck-typing on a `spider_kind` decl rather than importing
// extractors.zig directly, so this file doesn't need to know that module
// exists.
pub fn isExtractor(comptime PT: type) bool {
    return switch (@typeInfo(PT)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(PT, "spider_kind"),
        else => false,
    };
}

// True when `handler`'s parameters require the extractor dispatch path
// (buildAutoWrapper) instead of the classic decoration path (buildWrapper):
// any recognized extractor param, or a *Ctx param anywhere but first.
// Handlers with only *Ctx (at index 0) or only loose decoration types keep
// going through buildWrapper, unchanged.
pub fn usesExtractors(comptime handler: anytype) bool {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    inline for (fn_info.param_types, 0..) |maybe_pt, i| {
        const PT = maybe_pt orelse continue;
        if (PT == *Ctx) {
            if (i != 0) return true;
        } else if (isExtractor(PT)) {
            return true;
        }
    }
    return false;
}

// Dispatches handlers using spider.Path(...)/spider.Form(...) params (mixed
// with *Ctx, in any order, no 4-param ceiling — unlike buildWrapper). Each
// extractor resolves itself from `ctx`; on failure the wrapper returns a
// fixed 400 response immediately, without calling the handler.
pub fn buildAutoWrapper(comptime handler: anytype) Handler {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";

    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            var args: std.meta.ArgsTuple(@TypeOf(handler)) = undefined;

            inline for (fn_info.param_types, 0..) |maybe_pt, i| {
                const PT = maybe_pt orelse @compileError("generic param not supported");

                if (PT == *Ctx) {
                    args[i] = ctx;
                } else if (comptime isExtractor(PT)) {
                    if (PT.spider_kind == .path) {
                        // Errors (not canned 400 responses) so they reach the
                        // app's onError like any other handler error; the
                        // default mapping (statusForError) still gives 400.
                        const raw = ctx.params.get(PT.param_name) orelse {
                            ctx.setErrorDetail("missing path param: " ++ PT.param_name);
                            return error.MissingPathParam;
                        };
                        if (comptime PT.Inner == []const u8) {
                            args[i] = .{ .value = raw };
                        } else {
                            const parsed = std.fmt.parseInt(PT.Inner, raw, 10) catch {
                                ctx.setErrorDetail("invalid path param: " ++ PT.param_name);
                                return error.InvalidPathParam;
                            };
                            args[i] = .{ .value = parsed };
                        }
                    } else if (PT.spider_kind == .form) {
                        const parsed = ctx.parseForm(PT.Inner) catch |err| {
                            ctx.setErrorDetail("invalid form body");
                            return err;
                        };
                        args[i] = .{ .value = parsed };
                    } else {
                        @compileError("unsupported spider extractor kind on " ++ @typeName(PT));
                    }
                } else {
                    @compileError(
                        "buildAutoWrapper only supports *Ctx and extractor params " ++
                            "(spider.Path(...), spider.Form(...)); handler parameter `" ++
                            @typeName(PT) ++ "` is neither. For loose-type decoration " ++
                            "parameters, use the classic fn(*Ctx, T) !Response signature instead.",
                    );
                }
            }

            return @call(.auto, handler, args);
        }
    };
    return W.call;
}

/// Handler for a Group route: a plain `fn (*Ctx) !Response`, or one taking
/// extractors. Decoration parameters (`fn (*Ctx, Dep)`) need the server's
/// decorations and are only supported on server-level routes.
pub fn forGroup(comptime handler: anytype) Handler {
    const H = @TypeOf(handler);
    if (H == Handler) return handler;
    if (comptime usesExtractors(handler)) return buildAutoWrapper(handler);
    const info = @typeInfo(H).@"fn";
    if (info.param_types.len == 1 and info.param_types[0] == *Ctx) return handler;
    @compileError("Group route handler must be fn (*spider.Ctx) !spider.Response or take spider.Path/spider.Form " ++
        "extractors; `" ++ @typeName(H) ++ "` has other parameters (server decorations work only on server-level routes)");
}

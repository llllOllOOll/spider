//! Adds an auth provider to src/main.zig: creates the provider, installs
//! its middleware and (with views) hands it to features/auth, whose
//! routes.zig registers login/callback/session/logout.
//!
//! Apps whose main.zig calls `server.mountFeatures(features)` get the
//! middleware right before it (features/auth is mounted with the others).
//! Older apps, which list routes in main.zig, get the middleware and
//! `.mountFeature(features.auth)` before their first route (or `.onError(`).

const std = @import("std");
const fs_utils = @import("fs_utils.zig");

fn removeLine(allocator: std.mem.Allocator, content: []const u8, marker: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, content, marker) orelse return try allocator.dupe(u8, content);
    const line_start = if (std.mem.lastIndexOfLinear(u8, content[0..pos], "\n")) |nl| nl + 1 else 0;
    const line_end = if (std.mem.indexOf(u8, content[pos..], "\n")) |nl| pos + nl + 1 else content.len;
    return try std.mem.concat(allocator, u8, &.{
        content[0..line_start],
        content[line_end..],
    });
}

fn uncommentLine(allocator: std.mem.Allocator, content: []const u8, marker: []const u8) ![]u8 {
    const replacement = marker["// ".len..];
    const pos = std.mem.indexOf(u8, content, marker) orelse return try allocator.dupe(u8, content);
    return try std.mem.concat(allocator, u8, &.{
        content[0..pos],
        replacement,
        content[pos + marker.len ..],
    });
}

/// Inserts `text` at the start of the line containing `marker`; false when
/// the marker isn't there.
fn insertBeforeLine(allocator: std.mem.Allocator, content: *[]u8, marker: []const u8, text: []const u8) !bool {
    const pos = std.mem.indexOf(u8, content.*, marker) orelse return false;
    const line_start = if (std.mem.lastIndexOfLinear(u8, content.*[0..pos], "\n")) |nl| nl + 1 else 0;
    const r = try std.mem.concat(allocator, u8, &.{ content.*[0..line_start], text, content.*[line_start..] });
    allocator.free(content.*);
    content.* = r;
    return true;
}

/// main.zig with the provider added. `provider_config` is either statements
/// declaring `<provider>_config` (keycloak) or struct-literal fields.
pub fn transform(
    allocator: std.mem.Allocator,
    existing: []const u8,
    provider: []const u8,
    provider_config: []const u8,
    api: bool,
) ![]u8 {
    var result = try allocator.dupe(u8, existing);
    errdefer allocator.free(result);

    // The no-db template silences allocator/io and keeps the db lines commented.
    inline for (.{ "_ = allocator;", "_ = io;" }) |marker| {
        const r = try removeLine(allocator, result, marker);
        allocator.free(result);
        result = r;
    }
    inline for (.{ "// const db = spider.pg;", "// try db.init(allocator, io, .{});", "// defer db.deinit();" }) |marker| {
        const r = try uncommentLine(allocator, result, marker);
        allocator.free(result);
        result = r;
    }

    // Provider, before the server.
    const Provider = try std.fmt.allocPrint(allocator, "{c}{s}", .{ std.ascii.toUpper(provider[0]), provider[1..] });
    defer allocator.free(Provider);
    const init_call = if (std.mem.startsWith(u8, provider_config, "    var "))
        try std.fmt.allocPrint(allocator, "{s}    var {s}_auth = try spider.{s}.{s}.init(allocator, io, {s}_config);\n", .{ provider_config, provider, provider, Provider, provider })
    else
        try std.fmt.allocPrint(allocator, "    var {s}_auth = try spider.{s}.{s}.init(allocator, io, .{{\n{s}\n    }});\n", .{ provider, provider, Provider, provider_config });
    defer allocator.free(init_call);
    const hand_over = if (api) "" else try std.fmt.allocPrint(allocator, "    features.auth.provider = &{s}_auth;\n", .{provider});
    defer if (!api) allocator.free(hand_over);
    const provider_block = try std.fmt.allocPrint(allocator, "{s}    defer {s}_auth.deinit();\n{s}\n", .{ init_call, provider, hand_over });
    defer allocator.free(provider_block);
    _ = try insertBeforeLine(allocator, &result, "var server = spider.app(", provider_block);

    // Middleware (+ the auth feature's routes in older apps).
    const use_line = try std.fmt.allocPrint(allocator, "        .use({s}_auth.middleware())\n", .{provider});
    defer allocator.free(use_line);
    if (try insertBeforeLine(allocator, &result, ".mountFeatures(features)", use_line)) return result;

    const legacy = try std.fmt.allocPrint(allocator, "{s}{s}", .{ use_line, if (api) "" else "        .mountFeature(features.auth)\n" });
    defer allocator.free(legacy);
    if (!try insertBeforeLine(allocator, &result, ".get(\"/\", home.controller.index, .{})", legacy))
        _ = try insertBeforeLine(allocator, &result, ".onError(", legacy);
    return result;
}

pub fn updateMainZig(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    provider: []const u8,
    provider_config: []const u8,
    api: bool,
) !void {
    const main_path = "src/main.zig";

    const existing = root_dir.readFileAlloc(io, main_path, allocator, .limited(64 * 1024)) catch {
        std.debug.print("warning: src/main.zig not found, skipping auth update\n", .{});
        return;
    };
    defer allocator.free(existing);

    const result = try transform(allocator, existing, provider, provider_config, api);
    defer allocator.free(result);
    try fs_utils.writeFile(io, root_dir, main_path, result);
}

const t = std.testing;
const kc_config =
    \\    var keycloak_config = spider.keycloak.KeycloakConfig.fromEnv();
    \\    keycloak_config.after_callback_path = "/auth/session";
    \\
;

test "transform: mountFeatures app gets provider, hand-over and middleware" {
    const src =
        \\    var server = spider.app(.{});
        \\    defer server.deinit();
        \\
        \\    server
        \\        .use(spider.logger)
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{}))
    ;
    const out = try transform(t.allocator, src, "keycloak", kc_config, false);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\    var keycloak_config = spider.keycloak.KeycloakConfig.fromEnv();
        \\    keycloak_config.after_callback_path = "/auth/session";
        \\    var keycloak_auth = try spider.keycloak.Keycloak.init(allocator, io, keycloak_config);
        \\    defer keycloak_auth.deinit();
        \\    features.auth.provider = &keycloak_auth;
        \\
        \\    var server = spider.app(.{});
        \\    defer server.deinit();
        \\
        \\    server
        \\        .use(spider.logger)
        \\        .use(keycloak_auth.middleware())
        \\        .mountFeatures(features)
        \\        .onError(spider.errorHandler(.{}))
    , out);
}

test "transform: older main.zig gets middleware and mountFeature(features.auth)" {
    const src =
        \\    var server = spider.app(.{});
        \\    server
        \\        .get("/", home.controller.index, .{})
        \\        .onError(errorHandler)
    ;
    const out = try transform(t.allocator, src, "keycloak", kc_config, false);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out,
        \\        .use(keycloak_auth.middleware())
        \\        .mountFeature(features.auth)
        \\        .get("/", home.controller.index, .{})
    ) != null);
}

test "transform: API mode has no hand-over and no auth routes" {
    const src =
        \\    var server = spider.app(.{});
        \\    server
        \\        .use(spider.logger)
        \\        .mountFeatures(features)
    ;
    const out = try transform(t.allocator, src, "keycloak", kc_config, true);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "features.auth") == null);
    try t.expect(std.mem.indexOf(u8, out, "        .use(keycloak_auth.middleware())\n        .mountFeatures(features)") != null);
}

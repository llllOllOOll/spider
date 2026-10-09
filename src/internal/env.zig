//! Environment variables, with the project's `.env` files loaded on first
//! use (`spider.env`). Order: `.env`, then `.env.<SPIDER_ENV>` (`development`
//! when SPIDER_ENV is not set), then `.env.local`. A value in `.env` does not
//! replace a variable that is already set; the other two files do.
const std = @import("std");
const builtin = @import("builtin");

var auto_loaded = false;

fn ensureLoaded() void {
    if (!auto_loaded) {
        auto_loaded = true;
        loadFile(std.heap.page_allocator, ".env", false) catch {};
        const spider_env = getInternal("SPIDER_ENV") orelse "development";
        var env_buf: [64]u8 = undefined;
        const env_file = std.fmt.bufPrint(&env_buf, ".env.{s}", .{spider_env}) catch return;
        loadFile(std.heap.page_allocator, env_file, true) catch {};
        loadFile(std.heap.page_allocator, ".env.local", true) catch {};
    }
}

fn getInternal(key: []const u8) ?[]const u8 {
    const getenv = struct {
        extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;
    const key_z = std.heap.page_allocator.dupeSentinel(u8, key, 0) catch return null;
    defer std.heap.page_allocator.free(key_z);
    const val = getenv(key_z.ptr) orelse return null;
    return std.heap.page_allocator.dupe(u8, std.mem.sliceTo(val, 0)) catch null;
}

fn setEnvVarNative(name: [*:0]const u8, value: [*:0]const u8, overwrite: bool) void {
    if (builtin.os.tag == .windows) {
        const _putenv_s = struct {
            extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
        }._putenv_s;
        _ = _putenv_s(name, value);
    } else if (builtin.link_libc) {
        const setenv = struct {
            extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        }.setenv;
        _ = setenv(name, value, @intFromBool(overwrite));
    }
    // Without libc, runtime .env loading is unavailable.
}

/// The value of the variable `key`, or null when it is not set. The first
/// call loads the `.env` files of the working directory (see the top of this
/// file).
///
/// The result is a copy that is never freed (page allocator): read a
/// setting once at startup rather than on every request.
///
/// ```zig
/// if (spider.env.get("JWT_SECRET")) |secret| { ... }
/// ```
pub fn get(key: []const u8) ?[]const u8 {
    ensureLoaded();
    const getenv = struct {
        extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;
    const key_z = std.heap.page_allocator.dupeSentinel(u8, key, 0) catch return null;
    defer std.heap.page_allocator.free(key_z);
    const val = getenv(key_z.ptr) orelse return null;
    return std.heap.page_allocator.dupe(u8, std.mem.sliceTo(val, 0)) catch null;
}

/// The value of the variable `key`, or `default` (returned as given, not
/// copied) when it is not set. A variable set to an empty string is set.
///
/// ```zig
/// const realm = spider.env.getOr("KEYCLOAK_REALM", "");
/// ```
pub fn getOr(key: []const u8, default: []const u8) []const u8 {
    ensureLoaded();
    return get(key) orelse default;
}

/// The variable `key` as a base-10 integer of type `T`. Gives `default`
/// when the variable is not set, is not a number or does not fit in `T`.
pub fn getInt(comptime T: type, key: []const u8, default: T) T {
    const val = get(key) orelse return default;
    return std.fmt.parseInt(T, val, 10) catch default;
}

/// The variable `key` as a boolean: "true", "1" and "yes" are true;
/// "false", "0" and "no" are false (lower case only). Gives `default` when
/// the variable is not set or holds anything else.
pub fn getBool(key: []const u8, default: bool) bool {
    const val = get(key) orelse return default;
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "1")) return true;
    if (std.mem.eql(u8, val, "yes")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    if (std.mem.eql(u8, val, "0")) return false;
    if (std.mem.eql(u8, val, "no")) return false;
    return default;
}

// internal: reads one KEY=VALUE file into the process environment, keeping
// variables that are already set; a missing file is not an error.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {
    try loadFile(allocator, path, false);
}

// internal: the older name of `load`.
pub const loadEnv = load;

// internal: loads .env, .env.<SPIDER_ENV> and .env.local; listen() and pg.init() call it.
pub fn autoLoad(allocator: std.mem.Allocator) void {
    loadFile(allocator, ".env", false) catch {};

    const spider_env = get("SPIDER_ENV") orelse "development";
    var env_buf: [64]u8 = undefined;
    const env_file = std.fmt.bufPrint(&env_buf, ".env.{s}", .{spider_env}) catch return;
    loadFile(allocator, env_file, true) catch {};

    loadFile(allocator, ".env.local", true) catch {};
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, overwrite: bool) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_index| {
            const key = std.mem.trim(u8, trimmed[0..eq_index], " \t");
            const raw_value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r");
            const value = stripQuotes(raw_value);

            if (key.len == 0) continue;

            const key_z = try allocator.dupeSentinel(u8, key, 0);
            defer allocator.free(key_z);
            const value_z = try allocator.dupeSentinel(u8, value, 0);
            defer allocator.free(value_z);

            setEnvVarNative(key_z.ptr, value_z.ptr, overwrite);
        }
    }
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

// internal: listen() calls it to warn when .gitignore does not mention .env.
pub fn checkGitignore() void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        ".gitignore",
        std.heap.page_allocator,
        .limited(64 * 1024),
    ) catch return;
    defer std.heap.page_allocator.free(content);

    if (std.mem.indexOf(u8, content, ".env") == null) {
        std.log.warn(
            "[spider] WARNING: .env not found in .gitignore" ++
                " — secrets may be exposed to version control",
            .{},
        );
    }
}

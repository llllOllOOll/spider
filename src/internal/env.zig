//! Environment variables, with the project's `.env` files loaded on first
//! use (`spider.env`). A variable the process already has (set by the shell,
//! the container, a CI job) always wins: the files only fill in what is
//! missing. Among the files, `.env.local` wins over `.env.<SPIDER_ENV>`
//! (`development` when SPIDER_ENV is not set), which wins over `.env`.
//!
//! A file has one `NAME=value` per line. Blank lines and lines that start
//! with `#` are skipped, spaces around the name and the value are dropped,
//! and one pair of quotes around the value (`"..."` or `'...'`) is removed.
//! There is no `export` prefix, no escape and no `$NAME` expansion, and a
//! `#` after a value is part of the value. A file over 64 KiB is not
//! loaded, and a warning says so.
const std = @import("std");
const builtin = @import("builtin");

var auto_loaded = false;

/// The largest `.env` file loaded.
const max_file_bytes = 64 * 1024;

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
    return lookup(key);
}

/// The names this module set from a file. A later file may replace those,
/// and only those: a name that is set and is not here was the process's
/// own. Filled while the app starts, before requests are served.
var from_files: std.StringHashMapUnmanaged(void) = .empty;

/// Sets `key` from a file. `replaces_files`: this file wins over the files
/// loaded before it (`.env.<env>` and `.env.local` over `.env`). No file
/// replaces a variable the process already had.
fn setFromFile(key: [:0]const u8, value: [:0]const u8, replaces_files: bool) void {
    const getenv = struct {
        extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;
    const ours = from_files.contains(key);
    if (getenv(key.ptr) != null and !(replaces_files and ours)) return;
    setEnvVarNative(key.ptr, value.ptr, true);
    if (!ours) {
        const kept = std.heap.page_allocator.dupe(u8, key) catch return;
        from_files.put(std.heap.page_allocator, kept, {}) catch std.heap.page_allocator.free(kept);
    }
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
/// The result is the process's own copy of the value, valid while the
/// process runs: nothing is allocated, so it can be read on every request.
///
/// ```zig
/// if (spider.env.get("JWT_SECRET")) |secret| { ... }
/// ```
pub fn get(key: []const u8) ?[]const u8 {
    ensureLoaded();
    return lookup(key);
}

/// The process's value of `key`, as the C library holds it. No copy: it
/// used to be one page allocation per call, never freed.
fn lookup(key: []const u8) ?[]const u8 {
    const getenv = struct {
        extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;
    var stack: [256]u8 = undefined;
    if (key.len < stack.len) {
        @memcpy(stack[0..key.len], key);
        stack[key.len] = 0;
        return std.mem.sliceTo(getenv(@ptrCast(&stack)) orelse return null, 0);
    }
    const key_z = std.heap.page_allocator.dupeSentinel(u8, key, 0) catch return null;
    defer std.heap.page_allocator.free(key_z);
    return std.mem.sliceTo(getenv(key_z.ptr) orelse return null, 0);
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

/// The variable `key` as a boolean: "true", "1", "yes" and "on" are true;
/// "false", "0", "no" and "off" are false, in any letter case. Gives
/// `default` when the variable is not set or holds anything else.
pub fn getBool(key: []const u8, default: bool) bool {
    const val = get(key) orelse return default;
    for ([_][]const u8{ "true", "1", "yes", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(val, word)) return true;
    }
    for ([_][]const u8{ "false", "0", "no", "off" }) |word| {
        if (std.ascii.eqlIgnoreCase(val, word)) return false;
    }
    return default;
}

// internal: reads one KEY=VALUE file into the process environment, keeping
// variables that are already set; a missing file is not an error.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {
    try loadFile(allocator, path, false);
}

// internal: the older name of `load`.
pub const loadEnv = load;

// internal: loads .env, .env.<SPIDER_ENV> and .env.local; the server's
// init() (spider.app) and pg.init() call it.
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
        // The reader refuses a file that reaches its limit: one more byte
        // than the largest file loaded.
        .limited(max_file_bytes + 1),
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        // Said out loud: the callers go on without the file, and an app
        // that starts without its settings is hard to explain otherwise.
        error.StreamTooLong => {
            std.log.warn("[spider] {s} is over {d} KiB and was NOT loaded: none of its variables is set", .{ path, max_file_bytes / 1024 });
            return error.EnvFileTooLarge;
        },
        else => {
            std.log.warn("[spider] {s} could not be read ({s}) and was NOT loaded", .{ path, @errorName(err) });
            return err;
        },
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

            setFromFile(key_z, value_z, overwrite);
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

/// Whether a `.gitignore` with this content keeps `.env` out of the
/// repository: a line that is `.env`, `/.env`, `.env*` or `*.env`, and no
/// later line that takes it back (`!.env`). A line that only contains the
/// text, such as `.env.example`, does not count.
fn gitignoreCovers(content: []const u8) bool {
    var covered = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const negated = line[0] == '!';
        if (negated) line = line[1..];
        if (line.len > 0 and line[0] == '/') line = line[1..];
        const matches = std.mem.eql(u8, line, ".env") or std.mem.eql(u8, line, ".env*") or std.mem.eql(u8, line, "*.env");
        if (matches) covered = !negated;
    }
    return covered;
}

// internal: the server's init() (spider.app) calls it to warn when
// .gitignore does not ignore .env.
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

    if (!gitignoreCovers(content)) {
        std.log.warn(
            "[spider] WARNING: .gitignore does not ignore .env" ++
                " — secrets may be exposed to version control",
            .{},
        );
    }
}

test "env files: a later file replaces an earlier file's value, never a variable of the process" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "base.env", .data = 
        \\SPIDER_ENVTEST_FILE=from_base
        \\SPIDER_ENVTEST_REAL=from_base
        \\SPIDER_ENVTEST_ONLY_BASE=from_base
        \\
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "local.env", .data = 
        \\SPIDER_ENVTEST_FILE=from_local
        \\SPIDER_ENVTEST_REAL=from_local
        \\SPIDER_ENVTEST_ONLY_LOCAL=from_local
        \\
    });
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/base.env", .{tmp.sub_path});
    defer a.free(base);
    const local = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/local.env", .{tmp.sub_path});
    defer a.free(local);

    // What a container, a shell or a CI job sets before the app starts.
    setEnvVarNative("SPIDER_ENVTEST_REAL", "from_process", true);

    // Twice, as the server does (first use, then listen()).
    for (0..2) |_| {
        try loadFile(a, base, false); // the way `.env` is loaded
        try loadFile(a, local, true); // the way `.env.<env>` and `.env.local` are
    }

    try std.testing.expectEqualStrings("from_process", getInternal("SPIDER_ENVTEST_REAL").?);
    try std.testing.expectEqualStrings("from_local", getInternal("SPIDER_ENVTEST_FILE").?);
    try std.testing.expectEqualStrings("from_base", getInternal("SPIDER_ENVTEST_ONLY_BASE").?);
    try std.testing.expectEqualStrings("from_local", getInternal("SPIDER_ENVTEST_ONLY_LOCAL").?);
}

test "get: the value itself, not a new copy on every call" {
    if (!builtin.link_libc) return error.SkipZigTest;
    setEnvVarNative("SPIDER_ENVTEST_GET", "value", true);
    const first = get("SPIDER_ENVTEST_GET").?;
    const second = get("SPIDER_ENVTEST_GET").?;
    try std.testing.expectEqualStrings("value", first);
    // A handler that reads a setting on every request must not grow the
    // process by one copy each time.
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expect(get("SPIDER_ENVTEST_NOT_SET") == null);
    // A name longer than any real one still works.
    const long: [600]u8 = @splat('N');
    try std.testing.expect(get(&long) == null);
}

test "getBool: any letter case" {
    if (!builtin.link_libc) return error.SkipZigTest;
    for ([_][]const u8{ "true", "TRUE", "True", "1", "yes", "Yes", "on", "ON" }) |text| {
        var buf: [16:0]u8 = @splat(0);
        @memcpy(buf[0..text.len], text);
        setEnvVarNative("SPIDER_ENVTEST_BOOL", &buf, true);
        try std.testing.expect(getBool("SPIDER_ENVTEST_BOOL", false));
    }
    for ([_][]const u8{ "false", "FALSE", "False", "0", "no", "NO", "off", "Off" }) |text| {
        var buf: [16:0]u8 = @splat(0);
        @memcpy(buf[0..text.len], text);
        setEnvVarNative("SPIDER_ENVTEST_BOOL", &buf, true);
        try std.testing.expect(!getBool("SPIDER_ENVTEST_BOOL", true));
    }
    setEnvVarNative("SPIDER_ENVTEST_BOOL", "maybe", true);
    try std.testing.expect(getBool("SPIDER_ENVTEST_BOOL", true));
    try std.testing.expect(!getBool("SPIDER_ENVTEST_BOOL", false));
}

test "gitignoreCovers: a line that ignores .env itself, not one that only mentions it" {
    try std.testing.expect(gitignoreCovers(".zig-cache/\n.env\n"));
    try std.testing.expect(gitignoreCovers("/.env\r\n"));
    try std.testing.expect(gitignoreCovers("  .env*  \n"));
    try std.testing.expect(gitignoreCovers("*.env\n"));
    try std.testing.expect(gitignoreCovers(".env   # secrets\n") == false); // git has no trailing comments
    // These leave .env in the repository.
    try std.testing.expect(!gitignoreCovers(".env.example\n"));
    try std.testing.expect(!gitignoreCovers(".env.local\n.env.production\n"));
    try std.testing.expect(!gitignoreCovers("# .env\n"));
    try std.testing.expect(!gitignoreCovers(".env\n!.env\n"));
    try std.testing.expect(!gitignoreCovers(""));
}

test "loadFile: a file over the size limit is an error (and a warning), not silence" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try a.alloc(u8, max_file_bytes + 1);
    defer a.free(big);
    @memset(big, '#');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.env", .data = big });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/big.env", .{tmp.sub_path});
    defer a.free(path);
    try std.testing.expectError(error.EnvFileTooLarge, loadFile(a, path, false));
    // A file that is not there is not an error.
    try loadFile(a, ".zig-cache/tmp/no-such-file.env", false);
}

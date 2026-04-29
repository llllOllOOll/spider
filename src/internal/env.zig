const std = @import("std");
const c = @import("c_env");

pub fn get(key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const val = c.getenv(@as([*c]const u8, @ptrCast(&buf))) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(val)));
}

pub fn getOr(key: []const u8, default: []const u8) []const u8 {
    return get(key) orelse default;
}

pub fn getInt(comptime T: type, key: []const u8, default: T) T {
    const val = get(key) orelse return default;
    return std.fmt.parseInt(T, val, 10) catch default;
}

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

pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {
    try loadFile(allocator, path, false);
}

pub const loadEnv = load;

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

            const key_z = try allocator.dupeZ(u8, key);
            defer allocator.free(key_z);
            const value_z = try allocator.dupeZ(u8, value);
            defer allocator.free(value_z);

            _ = c.setenv(key_z.ptr, value_z.ptr, if (overwrite) @as(c_int, 1) else @as(c_int, 0));
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

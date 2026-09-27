//! Icon sets as Tailwind classes: `spider icons [add|remove <set>]`, and the
//! downloads behind `spider install`.
//!
//! A set is a folder of SVGs under bin/icons/<set>/ (git-ignored, like the
//! rest of bin/) plus a generated Tailwind plugin, bin/icons/<set>.mjs, that
//! turns each SVG into a class — `hero-home` — masked with currentColor.
//! src/styles.css loads one `@plugin "../bin/icons/<set>.mjs";` per active
//! set, and that line is the only record of which sets an app uses.
//! Tailwind only emits the classes the templates use.

const std = @import("std");
const downloader = @import("downloader.zig");
const fs_utils = @import("fs_utils.zig");

pub const Variant = struct {
    /// Folder inside the package tarball.
    dir: []const u8,
    /// Appended to the icon name: "home" + "-solid" -> hero-home-solid.
    suffix: []const u8,
};

pub const Set = struct {
    name: []const u8,
    /// CSS class prefix.
    prefix: []const u8,
    version: []const u8,
    /// npm tarball (registry.npmjs.org), pinned.
    url: []const u8,
    variants: []const Variant,
    example: []const u8,
};

pub const sets = [_]Set{
    .{
        .name = "heroicons",
        .prefix = "hero",
        .version = "2.2.0",
        .url = "https://registry.npmjs.org/heroicons/-/heroicons-2.2.0.tgz",
        .variants = &.{
            .{ .dir = "package/24/outline/", .suffix = "" },
            .{ .dir = "package/24/solid/", .suffix = "-solid" },
            .{ .dir = "package/20/solid/", .suffix = "-mini" },
            .{ .dir = "package/16/solid/", .suffix = "-micro" },
        },
        .example = "hero-home, hero-home-solid, hero-home-mini, hero-home-micro",
    },
    .{
        .name = "lucide",
        .prefix = "lucide",
        .version = "1.48.0",
        .url = "https://registry.npmjs.org/lucide-static/-/lucide-static-1.48.0.tgz",
        .variants = &.{.{ .dir = "package/icons/", .suffix = "" }},
        .example = "lucide-house, lucide-bell",
    },
    .{
        .name = "tabler",
        .prefix = "tabler",
        .version = "3.48.0",
        .url = "https://registry.npmjs.org/@tabler/icons/-/icons-3.48.0.tgz",
        .variants = &.{
            .{ .dir = "package/icons/outline/", .suffix = "" },
            .{ .dir = "package/icons/filled/", .suffix = "-filled" },
        },
        .example = "tabler-home, tabler-home-filled",
    },
};

pub const default_set = "heroicons";

pub fn find(name: []const u8) ?Set {
    for (sets) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

const plugin_tmpl = @embedFile("templates/icons_plugin.mjs.template");

const plugin_path_head = "@plugin \"../bin/icons/";

fn pluginLine(allocator: std.mem.Allocator, set: Set) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}.mjs\";", .{ plugin_path_head, set.name });
}

/// Names of the sets src/styles.css loads, in order.
pub fn activeSets(allocator: std.mem.Allocator, styles_css: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, styles_css, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, plugin_path_head)) continue;
        const rest = line[plugin_path_head.len..];
        const end = std.mem.indexOf(u8, rest, ".mjs\"") orelse continue;
        try out.append(allocator, rest[0..end]);
    }
    return out.toOwnedSlice(allocator);
}

/// styles.css with the set's @plugin line added (after the last icon set,
/// or at the end), or null when it's already there.
pub fn withSet(allocator: std.mem.Allocator, styles_css: []const u8, set: Set) !?[]u8 {
    const line = try pluginLine(allocator, set);
    defer allocator.free(line);
    if (std.mem.indexOf(u8, styles_css, line) != null) return null;

    var insert_at: ?usize = null;
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, styles_css, '\n');
    while (it.next()) |raw| {
        const next_pos = pos + raw.len + 1;
        if (std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r"), plugin_path_head)) insert_at = @min(next_pos, styles_css.len);
        pos = next_pos;
    }
    if (insert_at) |at| {
        const nl: []const u8 = if (at > 0 and styles_css[at - 1] != '\n') "\n" else "";
        return try std.mem.concat(allocator, u8, &.{ styles_css[0..at], nl, line, "\n", styles_css[at..] });
    }
    const sep: []const u8 = if (styles_css.len > 0 and styles_css[styles_css.len - 1] != '\n') "\n" else "";
    return try std.mem.concat(allocator, u8, &.{ styles_css, sep, line, "\n" });
}

/// styles.css without the set's @plugin line, or null when it isn't there.
pub fn withoutSet(allocator: std.mem.Allocator, styles_css: []const u8, set: Set) !?[]u8 {
    const line = try pluginLine(allocator, set);
    defer allocator.free(line);
    const at = std.mem.indexOf(u8, styles_css, line) orelse return null;
    var start = at;
    while (start > 0 and styles_css[start - 1] != '\n') start -= 1;
    var end = at + line.len;
    while (end < styles_css.len and styles_css[end] != '\n') end += 1;
    if (end < styles_css.len) end += 1;
    return try std.mem.concat(allocator, u8, &.{ styles_css[0..start], styles_css[end..] });
}

/// File name under bin/icons/<set>/ for a tarball entry, or null when the
/// entry isn't an icon of the set ("package/24/solid/home.svg" -> "home-solid.svg").
pub fn destName(buf: []u8, set: Set, entry: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, entry, ".svg")) return null;
    for (set.variants) |v| {
        if (!std.mem.startsWith(u8, entry, v.dir)) continue;
        const base = entry[v.dir.len .. entry.len - ".svg".len];
        if (base.len == 0 or std.mem.indexOfScalar(u8, base, '/') != null) return null;
        for (base) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
        return std.fmt.bufPrint(buf, "{s}{s}.svg", .{ base, v.suffix }) catch null;
    }
    return null;
}

/// Extracts the set's icons from its .tgz into `dest` (bin/icons/<set>).
fn extract(io: std.Io, allocator: std.mem.Allocator, tgz: []const u8, set: Set, dest: std.Io.Dir) !usize {
    var in: std.Io.Reader = .fixed(tgz);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, window);
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tar: std.tar.Iterator = .init(&gz.reader, .{ .file_name_buffer = &file_name_buf, .link_name_buffer = &link_name_buf });

    var count: usize = 0;
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    while (try tar.next()) |entry| {
        if (entry.kind != .file) continue;
        var name_buf: [256]u8 = undefined;
        const name = destName(&name_buf, set, entry.name) orelse continue;
        content.clearRetainingCapacity();
        try tar.streamRemaining(entry, &content.writer);
        try fs_utils.writeFile(io, dest, name, content.written());
        count += 1;
    }
    return count;
}

/// Makes bin/icons/<set>/ and bin/icons/<set>.mjs current. The tarball is
/// cached in `cache_dir` (the same cache as spider install's other assets).
pub fn install(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir, set: Set, cache_dir: ?std.Io.Dir) !void {
    const version_file = try std.fmt.allocPrint(allocator, "bin/icons/{s}/.version", .{set.name});
    defer allocator.free(version_file);
    const plugin_file = try std.fmt.allocPrint(allocator, "bin/icons/{s}.mjs", .{set.name});
    defer allocator.free(plugin_file);

    const current = project_dir.readFileAlloc(io, version_file, allocator, .limited(64)) catch null;
    defer if (current) |cur| allocator.free(cur);
    const up_to_date = if (current) |cur| std.mem.eql(u8, std.mem.trim(u8, cur, " \n"), set.version) else false;

    if (!up_to_date) {
        const cache_name = try std.fmt.allocPrint(allocator, "icons-{s}-{s}.tgz", .{ set.name, set.version });
        defer allocator.free(cache_name);
        const cached: ?[]u8 = if (cache_dir) |cd| cd.readFileAlloc(io, cache_name, allocator, .limited(64 * 1024 * 1024)) catch null else null;
        const tgz = cached orelse blk: {
            std.debug.print("  downloading: icons {s} {s}\n", .{ set.name, set.version });
            const body = try downloader.fetch(io, allocator, set.url);
            if (cache_dir) |cd| fs_utils.writeFile(io, cd, cache_name, body) catch {};
            break :blk body;
        };
        defer allocator.free(tgz);
        if (cached != null) std.debug.print("  from cache: icons {s} {s}\n", .{ set.name, set.version });

        const set_dir_path = try std.fmt.allocPrint(allocator, "bin/icons/{s}", .{set.name});
        defer allocator.free(set_dir_path);
        project_dir.deleteTree(io, set_dir_path) catch {};
        try project_dir.createDirPath(io, set_dir_path);
        var set_dir = try project_dir.openDir(io, set_dir_path, .{});
        defer set_dir.close(io);
        const n = try extract(io, allocator, tgz, set, set_dir);
        if (n == 0) return error.NoIconsInPackage;
        try fs_utils.writeFile(io, project_dir, version_file, set.version);
        std.debug.print("  icons {s}: {d} icons in bin/icons/{s}/\n", .{ set.name, n, set.name });
    }

    // The plugin is rewritten every time: cheap, and follows CLI updates.
    const plugin = try renderPlugin(allocator, set);
    defer allocator.free(plugin);
    try fs_utils.writeFile(io, project_dir, plugin_file, plugin);
}

fn renderPlugin(allocator: std.mem.Allocator, set: Set) ![]u8 {
    const a = try std.mem.replaceOwned(u8, allocator, plugin_tmpl, "{{set}}", set.name);
    defer allocator.free(a);
    return std.mem.replaceOwned(u8, allocator, a, "{{prefix}}", set.prefix);
}

/// Lines of .html files under `root` that use `prefix`- classes
/// ("src/features/x/views/a.html:12"), for `spider icons remove`.
fn findUsages(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir, root_name: []const u8, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = root.openDir(io, root_name, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    const needle = try std.fmt.allocPrint(allocator, "{s}-", .{prefix});
    defer allocator.free(needle);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".html")) continue;
        const text = dir.readFileAlloc(io, entry.path, allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer allocator.free(text);
        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            line_no += 1;
            if (usesPrefix(line, needle)) try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}:{d}", .{ root_name, entry.path, line_no }));
        }
    }
}

/// `needle` ("hero-") starts a class token in `line` (after a quote or space).
pub fn usesPrefix(line: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, needle)) |i| {
        if (i == 0 or line[i - 1] == '"' or line[i - 1] == '\'' or line[i - 1] == ' ') return true;
        from = i + 1;
    }
    return false;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const root = fs_utils.findProjectRoot(io) catch {
        std.debug.print("error: not inside a Spider app (no build.zig.zon here or above)\n", .{});
        return 2;
    };
    const styles_path = "src/styles.css";
    const styles = root.readFileAlloc(io, styles_path, allocator, .limited(1024 * 1024)) catch {
        say("error: {s} not found (spider icons works in a Spider app with views)\n", .{styles_path});
        return 2;
    };
    defer allocator.free(styles);

    if (args.len == 0) {
        const active = try activeSets(allocator, styles);
        say("Icon sets in this app (src/styles.css):\n", .{});
        if (active.len == 0) say("  (none)\n", .{});
        for (active) |name| {
            if (find(name)) |s| say("  {s: <10} {s}-*   e.g. {s}\n", .{ s.name, s.prefix, s.example }) else say("  {s}  (unknown to this CLI)\n", .{name});
        }
        say("\nAvailable: ", .{});
        for (sets, 0..) |s, i| say("{s}{s}", .{ if (i > 0) ", " else "", s.name });
        say("\nAdd or remove one: spider icons add <set> / spider icons remove <set>\n", .{});
        return 0;
    }

    if (args.len != 2 or !(std.mem.eql(u8, args[0], "add") or std.mem.eql(u8, args[0], "remove"))) {
        say("usage: spider icons [add|remove <set>]   (see `spider icons --help`)\n", .{});
        return 2;
    }
    const set = find(args[1]) orelse {
        say("error: unknown icon set '{s}'. Available: ", .{args[1]});
        for (sets, 0..) |s, i| say("{s}{s}", .{ if (i > 0) ", " else "", s.name });
        say("\n", .{});
        return 2;
    };

    if (std.mem.eql(u8, args[0], "add")) {
        if (try withSet(allocator, styles, set)) |updated| {
            defer allocator.free(updated);
            try fs_utils.writeFile(io, root, styles_path, updated);
            say("  update  {s} (@plugin for {s})\n", .{ styles_path, set.name });
        } else say("  {s} is already in {s}\n", .{ set.name, styles_path });
        const cache_path = @import("install.zig").getCacheDir(allocator) catch null;
        defer if (cache_path) |cp| allocator.free(cp);
        var cache_dir: ?std.Io.Dir = null;
        if (cache_path) |cp| {
            std.Io.Dir.cwd().createDirPath(io, cp) catch {};
            cache_dir = std.Io.Dir.openDirAbsolute(io, cp, .{}) catch null;
        }
        defer if (cache_dir) |cd| cd.close(io);
        try install(io, allocator, root, set, cache_dir);
        say("\nUse them as classes: {s}   (size with size-4, size-5, ...; color follows text-*)\n", .{set.example});
        return 0;
    }

    // remove
    if (try withoutSet(allocator, styles, set)) |updated| {
        defer allocator.free(updated);
        try fs_utils.writeFile(io, root, styles_path, updated);
        say("  update  {s} (removed @plugin for {s})\n", .{ styles_path, set.name });
    } else say("  {s} was not in {s}\n", .{ set.name, styles_path });
    const set_dir = try std.fmt.allocPrint(allocator, "bin/icons/{s}", .{set.name});
    defer allocator.free(set_dir);
    root.deleteTree(io, set_dir) catch {};
    const plugin_file = try std.fmt.allocPrint(allocator, "bin/icons/{s}.mjs", .{set.name});
    defer allocator.free(plugin_file);
    root.deleteFile(io, plugin_file) catch {};

    var usages: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (usages.items) |u| allocator.free(u);
        usages.deinit(allocator);
    }
    try findUsages(io, allocator, root, "src", set.prefix, &usages);
    if (usages.items.len == 0) {
        say("\nNo {s}-* classes left in src/.\n", .{set.prefix});
        return 0;
    }
    say("\n{d} line(s) in src/ still use {s}-* icons (they'll render empty); replace them:\n", .{ usages.items.len, set.prefix });
    for (usages.items[0..@min(usages.items.len, 50)]) |u| say("  {s}\n", .{u});
    if (usages.items.len > 50) say("  ... and {d} more\n", .{usages.items.len - 50});
    return 0;
}

const t = std.testing;

test "activeSets / withSet / withoutSet round-trip on styles.css" {
    const a = t.allocator;
    const styles =
        \\@import "tailwindcss";
        \\@import "./ui.css";
        \\
        \\/* Icon sets */
        \\@plugin "../bin/icons/heroicons.mjs";
        \\
    ;
    const active = try activeSets(a, styles);
    defer a.free(active);
    try t.expectEqual(@as(usize, 1), active.len);
    try t.expectEqualStrings("heroicons", active[0]);

    try t.expect((try withSet(a, styles, find("heroicons").?)) == null);
    const two = (try withSet(a, styles, find("lucide").?)).?;
    defer a.free(two);
    try t.expect(std.mem.indexOf(u8, two, "@plugin \"../bin/icons/heroicons.mjs\";\n@plugin \"../bin/icons/lucide.mjs\";\n") != null);

    const back = (try withoutSet(a, two, find("lucide").?)).?;
    defer a.free(back);
    try t.expectEqualStrings(styles, back);
    try t.expect((try withoutSet(a, styles, find("tabler").?)) == null);

    const none = (try withoutSet(a, styles, find("heroicons").?)).?;
    defer a.free(none);
    const empty = try activeSets(a, none);
    defer a.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
    const appended = (try withSet(a, "@import \"tailwindcss\";", find("tabler").?)).?;
    defer a.free(appended);
    try t.expectEqualStrings("@import \"tailwindcss\";\n@plugin \"../bin/icons/tabler.mjs\";\n", appended);
}

test "destName: variant folders map to suffixed names; anything else is skipped" {
    var buf: [256]u8 = undefined;
    const hero = find("heroicons").?;
    try t.expectEqualStrings("home.svg", destName(&buf, hero, "package/24/outline/home.svg").?);
    try t.expectEqualStrings("home-solid.svg", destName(&buf, hero, "package/24/solid/home.svg").?);
    try t.expectEqualStrings("home-mini.svg", destName(&buf, hero, "package/20/solid/home.svg").?);
    try t.expectEqualStrings("home-micro.svg", destName(&buf, hero, "package/16/solid/home.svg").?);
    try t.expect(destName(&buf, hero, "package/README.md") == null);
    try t.expect(destName(&buf, hero, "package/24/outline/../../x.svg") == null);
    try t.expect(destName(&buf, hero, "package/24/outline/sub/x.svg") == null);
    try t.expectEqualStrings("home-filled.svg", destName(&buf, find("tabler").?, "package/icons/filled/home.svg").?);
}

test "usesPrefix: only at the start of a class token" {
    try t.expect(usesPrefix("<span class=\"hero-home size-5\">", "hero-"));
    try t.expect(usesPrefix("<span class=\"size-5 hero-home\">", "hero-"));
    try t.expect(!usesPrefix("<span class=\"superhero-x\">", "hero-"));
    try t.expect(!usesPrefix("hero section", "hero-"));
}

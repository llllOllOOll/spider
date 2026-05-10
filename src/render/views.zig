const std = @import("std");

pub const TemplateEntry = struct {
    name: []const u8,
    path: []const u8,
};

pub const ViewsIndex = struct {
    entries: []TemplateEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ViewsIndex) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.allocator.free(self.entries);
    }

    pub fn get(self: *const ViewsIndex, name: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const normalized = normalizeName(name, &buf);
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, normalized)) {
                return entry.path;
            }
        }
        return null;
    }
};

// "auth/login" -> "auth_login", "layout" -> "layout"
pub fn normalizeName(name: []const u8, buf: []u8) []const u8 {
    var j: usize = 0;
    for (name) |c| {
        if (j >= buf.len) break;
        buf[j] = if (c == '/' or c == '-') '_' else c;
        j += 1;
    }
    return buf[0..j];
}

pub fn buildIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
) !ViewsIndex {
    var entries: std.ArrayList(TemplateEntry) = .empty;

    // Maps normalized name -> path of the first file that claimed that name.
    // Used to detect two templates in different folders that normalize to the
    // same name (e.g. features/users/views/index.html and views/users/index.html
    // both -> users_index). Keys are owned by `entries`, not the map.
    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer seen.deinit(allocator);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root_dir, .{ .iterate = true }) catch {
        std.debug.print(
            "[spider] WARNING: views_dir \"{s}\" not found.\n" ++
                "[spider]          Templates will not load in runtime mode.\n" ++
                "[spider]          Check your spider.config.zig -> views_dir setting.\n",
            .{root_dir},
        );
        return ViewsIndex{ .entries = &.{}, .allocator = allocator };
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var template_count: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".html") and
            !std.mem.endsWith(u8, entry.path, ".md")) continue;

        var name_buf: [256]u8 = undefined;
        const name = generateFieldName(entry.path, &name_buf) catch continue;
        if (name.len == 0) continue;

        const owned_name = try allocator.dupe(u8, name);
        const full_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root_dir, entry.path },
        );

        const gop = try seen.getOrPut(allocator, owned_name);
        if (gop.found_existing) {
            std.debug.print(
                "[spider] WARNING: template name conflict: \"{s}\"\n" ++
                    "[spider]          first:   {s}\n" ++
                    "[spider]          ignored: {s}\n" ++
                    "[spider]          Rename one of the files so c.view() lookups are unambiguous.\n",
                .{ owned_name, gop.value_ptr.*, full_path },
            );
            allocator.free(owned_name);
            allocator.free(full_path);
            continue;
        }
        gop.value_ptr.* = full_path;

        try entries.append(allocator, .{
            .name = owned_name,
            .path = full_path,
        });
        template_count += 1;
    }

    if (template_count == 0) {
        std.debug.print(
            "[spider] WARNING: No templates found in \"{s}\".\n" ++
                "[spider]          Make sure your .html/.md files are inside views_dir.\n" ++
                "[spider]          Check your spider.config.zig -> views_dir setting.\n",
            .{root_dir},
        );
    } else {
        std.debug.print(
            "[spider] runtime templates: {d} loaded from \"{s}\"\n",
            .{ template_count, root_dir },
        );
    }

    return ViewsIndex{
        .entries = try entries.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn generateFieldName(path: []const u8, buffer: []u8) ![]const u8 {
    const no_ext = if (std.mem.endsWith(u8, path, ".html"))
        path[0 .. path.len - 5]
    else if (std.mem.endsWith(u8, path, ".md"))
        path[0 .. path.len - 3]
    else
        path;

    if (std.mem.indexOf(u8, no_ext, "views/")) |idx| {
        const before = no_ext[0..idx];
        const after = no_ext[idx + "views/".len ..];

        const dir = std.fs.path.basename(before);
        const file = std.fs.path.basename(after);

        if (dir.len == 0) {
            var j: usize = 0;
            for (after) |c| {
                if (j >= buffer.len) break;
                buffer[j] = if (c == '/' or c == '-') '_' else c;
                j += 1;
            }
            return buffer[0..j];
        }

        if (std.mem.eql(u8, dir, file)) {
            return try std.fmt.bufPrint(buffer, "{s}", .{file});
        }
        return try std.fmt.bufPrint(buffer, "{s}_{s}", .{ dir, file });
    } else if (std.mem.indexOf(u8, no_ext, "templates/")) |idx| {
        const after = no_ext[idx + "templates/".len ..];

        var j: usize = 0;
        for (after) |c| {
            if (j >= buffer.len) break;
            buffer[j] = if (c == '/' or c == '-') '_' else c;
            j += 1;
        }
        return buffer[0..j];
    }

    var j: usize = 0;
    for (no_ext) |c| {
        if (j >= buffer.len) break;
        buffer[j] = if (c == '/' or c == '-') '_' else c;
        j += 1;
    }
    return buffer[0..j];
}

const testing = std.testing;

test "normalizeName replaces slashes with underscores" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("auth_login", normalizeName("auth/login", &buf));
}

test "normalizeName replaces dashes with underscores" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("site_nav", normalizeName("site-nav", &buf));
}

test "normalizeName leaves simple names untouched" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("layout", normalizeName("layout", &buf));
}

test "normalizeName truncates at buffer length" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("auth", normalizeName("auth/login", &buf));
}

// Cases below mirror the normalization table in README.md ("Template name
// normalization"). If you change generateFieldName, update both.
test "generateFieldName: views/ at root collapses dir into name" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bills_index", try generateFieldName("views/bills/index.html", &buf));
}

test "generateFieldName: nested feature views become dir_file" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("auth_login", try generateFieldName("features/auth/views/login.html", &buf));
}

test "generateFieldName: shared/templates/layout keeps bare name" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("layout", try generateFieldName("shared/templates/layout.html", &buf));
}

test "generateFieldName: shared/templates preserves PascalCase" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Card", try generateFieldName("shared/templates/Card.html", &buf));
}

test "generateFieldName: shared/templates replaces dashes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("site_nav", try generateFieldName("shared/templates/site-nav.html", &buf));
}

test "generateFieldName: .md extension handled like .html" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("docs_api", try generateFieldName("views/docs/api.md", &buf));
}

// The conflict scenario documented in buildIndex: two paths in different
// folders both normalize to "users_index". This is the case the new warning
// in buildIndex is meant to catch.
test "generateFieldName: views/users/index and features/users/views/index collide" {
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    const a = try generateFieldName("views/users/index.html", &a_buf);
    const b = try generateFieldName("features/users/views/index.html", &b_buf);
    try testing.expectEqualStrings("users_index", a);
    try testing.expectEqualStrings("users_index", b);
}

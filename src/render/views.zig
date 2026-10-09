//! Internal: the index of template files on disk (name -> path), built by
//! walking the views directory. The server builds it when templates are
//! read from disk; `Ctx.view()` looks names up in it.

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

// TODO: Name conflict -- two templates in different folders can normalize to the
// same name (e.g. features/users/views/index.html and views/users/index.html
// both -> users_index). For now the dev is responsible for avoiding conflicts.
// Future fix: detect conflicts in buildIndex() and return an error with a clear
// message indicating which files conflict.
pub fn buildIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
) !ViewsIndex {
    var entries: std.ArrayList(TemplateEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        entries.deinit(allocator);
    }

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
        var alias_buf: [256]u8 = undefined;
        const names = generateFieldName(entry.path, &name_buf, &alias_buf) catch continue;
        if (names.primary.len == 0) continue;

        const full_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root_dir, entry.path },
        );

        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, names.primary),
            .path = full_path,
        });
        template_count += 1;

        if (names.alias) |alias| {
            // Legacy name kept alongside the PascalCase-stripped one for
            // backward compatibility (see spider-render skill, "Components
            // Folder" patch) — mirrors generate_templates.zig's embed mode.
            const alias_path = try allocator.dupe(u8, full_path);
            try entries.append(allocator, .{
                .name = try allocator.dupe(u8, alias),
                .path = alias_path,
            });
        }
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

const FieldNames = struct {
    primary: []const u8,
    // Legacy dir-prefixed name, only set when it differs from primary
    // (i.e. the PascalCase rule actually dropped a directory prefix).
    alias: ?[]const u8 = null,
};

fn generateFieldName(path: []const u8, buffer: []u8, alias_buffer: []u8) !FieldNames {
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
            return .{ .primary = buffer[0..j] };
        }

        if (std.mem.eql(u8, dir, file)) {
            return .{ .primary = try std.fmt.bufPrint(buffer, "{s}", .{file}) };
        }
        if (file.len > 0 and file[0] >= 'A' and file[0] <= 'Z') {
            return .{ .primary = try std.fmt.bufPrint(buffer, "{s}", .{file}) };
        }
        return .{ .primary = try std.fmt.bufPrint(buffer, "{s}_{s}", .{ dir, file }) };
    } else if (std.mem.indexOf(u8, no_ext, "templates/")) |idx| {
        const after = no_ext[idx + "templates/".len ..];

        // PascalCase basename (e.g. components/EntrarFragment.html) is a
        // component: keep the bare name, same convention as the views/
        // branch above, mirrored from generate_templates.zig's embed mode.
        const base = std.fs.path.basename(after);
        if (base.len > 0 and base[0] >= 'A' and base[0] <= 'Z') {
            const primary = try std.fmt.bufPrint(buffer, "{s}", .{base});

            var j: usize = 0;
            for (after) |c| {
                if (j >= alias_buffer.len) break;
                alias_buffer[j] = if (c == '/' or c == '-') '_' else c;
                j += 1;
            }
            const legacy = alias_buffer[0..j];
            if (std.mem.eql(u8, legacy, primary)) {
                return .{ .primary = primary };
            }
            return .{ .primary = primary, .alias = legacy };
        }

        var j: usize = 0;
        for (after) |c| {
            if (j >= buffer.len) break;
            buffer[j] = if (c == '/' or c == '-') '_' else c;
            j += 1;
        }
        return .{ .primary = buffer[0..j] };
    }

    var j: usize = 0;
    for (no_ext) |c| {
        if (j >= buffer.len) break;
        buffer[j] = if (c == '/' or c == '-') '_' else c;
        j += 1;
    }
    return .{ .primary = buffer[0..j] };
}

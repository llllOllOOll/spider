//! UI kits: `spider ui [use <kit>]`.
//!
//! Generated templates use ui-* classes (ui-btn, ui-input, ui-card, ...)
//! defined in src/ui.css, never a kit's own classes. A kit is one version of
//! that file: daisyUI (@apply btn ...) or plain Tailwind. Switching kits
//! rewrites src/ui.css only; its first line records the kit
//! ("/* spider-ui: daisyui").

const std = @import("std");
const fs_utils = @import("fs_utils.zig");

pub const Kit = struct {
    name: []const u8,
    css: []const u8,
    about: []const u8,
};

pub const kits = [_]Kit{
    .{ .name = "daisyui", .css = @embedFile("templates/ui_daisyui.css.template"), .about = "daisyUI 5 components and themes (bin/daisyui.mjs)" },
    .{ .name = "tailwind", .css = @embedFile("templates/ui_tailwind.css.template"), .about = "plain Tailwind, no component library" },
};

pub const default_kit = "daisyui";

pub fn find(name: []const u8) ?Kit {
    for (kits) |k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

const marker = "/* spider-ui: ";

/// Kit named on src/ui.css's first line, or null.
pub fn detect(ui_css: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ui_css, marker)) return null;
    const rest = ui_css[marker.len..];
    const end = std.mem.indexOfAny(u8, rest, " \n*") orelse return null;
    return if (end == 0) null else rest[0..end];
}

const import_line = "@import \"./ui.css\";";
const daisy_plugin_line = "@plugin \"../bin/daisyui.mjs\";";

/// styles.css importing ui.css, without the daisyUI @plugin line an app
/// generated before UI kits had there (ui.css loads it when the kit is
/// daisyUI). Null when nothing changes.
pub fn stylesForKits(allocator: std.mem.Allocator, styles_css: []const u8) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    const has_import = std.mem.indexOf(u8, styles_css, import_line) != null;
    var it = std.mem.splitScalar(u8, styles_css, '\n');
    var first = true;
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), daisy_plugin_line)) {
            changed = true;
            continue;
        }
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, line);
        if (!has_import and std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "@import \"tailwindcss\";")) {
            try out.appendSlice(allocator, "\n" ++ import_line);
            changed = true;
        }
    }
    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// A daisyUI component class (btn, btn-primary, card-body, ...): the same
/// list `spider check` uses.
pub const isDaisyClass = @import("spider_testing").conventions.isKitClass;

/// daisyUI classes used directly in a line of a template's class
/// attributes (class="..." and Alpine :class="... '...' ...").
pub fn daisyClassesIn(line: []const u8, out: *[8][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "class=\"")) |at| {
        const start = at + "class=\"".len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse line.len;
        var tok = std.mem.tokenizeAny(u8, line[start..end], " '?:");
        while (tok.next()) |c| {
            if (isDaisyClass(c) and n < out.len) {
                out[n] = c;
                n += 1;
            }
        }
        i = end;
    }
    return n;
}

fn findDaisyUsages(io: std.Io, allocator: std.mem.Allocator, root: std.Io.Dir, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".html")) continue;
        const text = dir.readFileAlloc(io, entry.path, allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer allocator.free(text);
        var line_no: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            line_no += 1;
            var found: [8][]const u8 = undefined;
            const n = daisyClassesIn(line, &found);
            if (n == 0) continue;
            var list: std.ArrayListUnmanaged(u8) = .empty;
            defer list.deinit(allocator);
            for (found[0..n], 0..) |c, k| {
                if (k > 0) try list.appendSlice(allocator, " ");
                try list.appendSlice(allocator, c);
            }
            try out.append(allocator, try std.fmt.allocPrint(allocator, "src/{s}:{d}  {s}", .{ entry.path, line_no, list.items }));
        }
    }
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const root = fs_utils.findProjectRoot(io) catch {
        std.debug.print("error: not inside a Spider app (no build.zig.zon here or above)\n", .{});
        return 2;
    };
    const ui_path = "src/ui.css";
    const current = root.readFileAlloc(io, ui_path, allocator, .limited(1024 * 1024)) catch null;
    defer if (current) |c| allocator.free(c);
    const current_kit: ?[]const u8 = if (current) |c| detect(c) else null;

    if (args.len == 0) {
        if (current == null) {
            say("No src/ui.css: this app was generated before UI kits and uses daisyUI classes\ndirectly in its templates. `spider ui use daisyui` adds the kit layer.\n", .{});
        } else if (current_kit) |k| {
            say("UI kit: {s}   (src/ui.css)\n", .{k});
        } else say("src/ui.css has no \"/* spider-ui: <kit>\" first line: custom kit.\n", .{});
        say("\nKits:\n", .{});
        for (kits) |k| say("  {s: <9} {s}\n", .{ k.name, k.about });
        say("\nSwitch: spider ui use <kit>\n", .{});
        return 0;
    }

    var force = false;
    var positional: [2][]const u8 = undefined;
    var np: usize = 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (np < positional.len) {
            positional[np] = a;
            np += 1;
        } else np += 1;
    }
    if (np != 2 or !std.mem.eql(u8, positional[0], "use")) {
        say("usage: spider ui [use <kit> [--force]]   (see `spider ui --help`)\n", .{});
        return 2;
    }
    const kit = find(positional[1]) orelse {
        say("error: unknown UI kit '{s}'. Kits: ", .{positional[1]});
        for (kits, 0..) |k, i| say("{s}{s}", .{ if (i > 0) ", " else "", k.name });
        say("\n", .{});
        return 2;
    };

    if (current) |c| {
        if (std.mem.eql(u8, c, kit.css)) {
            say("Already using {s}.\n", .{kit.name});
            return 0;
        }
        const pristine = if (current_kit) |ck| if (find(ck)) |k| std.mem.eql(u8, c, k.css) else false else false;
        if (!pristine and !force) {
            say("error: src/ui.css has changes of yours (it isn't the stock \"{s}\" kit); switching\nreplaces the whole file. Copy what you want to keep, then run again with --force.\n", .{current_kit orelse "custom"});
            return 2;
        }
    }

    try fs_utils.writeFile(io, root, ui_path, kit.css);
    say("  {s}  {s} ({s})\n", .{ if (current == null) "create" else "update", ui_path, kit.name });
    if (root.readFileAlloc(io, "src/styles.css", allocator, .limited(1024 * 1024))) |styles| {
        defer allocator.free(styles);
        if (try stylesForKits(allocator, styles)) |updated| {
            defer allocator.free(updated);
            try fs_utils.writeFile(io, root, "src/styles.css", updated);
            say("  update  src/styles.css (imports ui.css)\n", .{});
        }
    } else |_| {}

    if (std.mem.eql(u8, kit.name, "daisyui")) {
        root.access(io, "bin/daisyui.mjs", .{}) catch say("\nRun `spider install` to download daisyUI.\n", .{});
        return 0;
    }

    var usages: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (usages.items) |u| allocator.free(u);
        usages.deinit(allocator);
    }
    try findDaisyUsages(io, allocator, root, &usages);
    if (usages.items.len == 0) {
        say("\nNo daisyUI classes left in src/ templates.\n", .{});
        return 0;
    }
    say("\n{d} line(s) in src/ still use daisyUI classes directly (unstyled now). Replace them with\nui-* classes (see src/ui.css) or utilities:\n", .{usages.items.len});
    for (usages.items[0..@min(usages.items.len, 50)]) |u| say("  {s}\n", .{u});
    if (usages.items.len > 50) say("  ... and {d} more\n", .{usages.items.len - 50});
    return 0;
}

const t = std.testing;

test "detect: the kit on ui.css's first line" {
    try t.expectEqualStrings("daisyui", detect(find("daisyui").?.css).?);
    try t.expectEqualStrings("tailwind", detect(find("tailwind").?.css).?);
    try t.expect(detect("@layer components {}") == null);
}

test "isDaisyClass: daisyUI components, not ui-* or look-alike utilities" {
    for ([_][]const u8{ "btn", "btn-primary", "card-body", "input-bordered", "select-bordered", "form-control", "btm-nav", "label-text", "menu" }) |c| try t.expect(isDaisyClass(c));
    for ([_][]const u8{ "ui-btn", "ui-card", "select-none", "table", "collapse", "hero-home", "bg-base-200", "text-error", "flex", "badger" }) |c| try t.expect(!isDaisyClass(c));
}

test "daisyClassesIn: class and :class attributes" {
    var out: [8][]const u8 = undefined;
    try t.expectEqual(@as(usize, 2), daisyClassesIn("<a class=\"btn btn-ghost flex\">", &out));
    try t.expectEqualStrings("btn-ghost", out[1]);
    try t.expectEqual(@as(usize, 2), daisyClassesIn("<div :class=\"ok ? 'alert alert-success' : 'x'\">", &out));
    try t.expectEqual(@as(usize, 0), daisyClassesIn("<a class=\"ui-btn ui-btn-ghost hero-home\">", &out));
}

test "stylesForKits: an older app's styles.css gets the ui.css import; the daisyUI plugin moves to ui.css" {
    const a = t.allocator;
    const old = "@import \"tailwindcss\";\n@plugin \"../bin/daisyui.mjs\";\n";
    const updated = (try stylesForKits(a, old)).?;
    defer a.free(updated);
    try t.expectEqualStrings("@import \"tailwindcss\";\n@import \"./ui.css\";\n", updated);
    try t.expect((try stylesForKits(a, updated)) == null);
}

//! A Spider app's conventions, checked — so code that "looks like it works"
//! but routes, styles or protects things the wrong way fails with a file,
//! a line and the fix, instead of relying on everyone (or every coding
//! agent) having read the docs.
//!
//! Used by `spider check` and, in generated apps, by a test in src/main.zig
//! (`spider.testing.expectConventions()`), so `zig build test` enforces it.
//!
//! Errors:
//!   route-outside-routes   a route registered outside src/features/<f>/routes.zig
//!   kit-class              a UI kit class (btn, card, ...) in a template instead of ui-*
//!   icon-set               an icon class from a set src/styles.css doesn't load
//!   feature-not-registered a feature folder missing from src/features/mod.zig
//!   route-access           with auth, a route that declares no access (roles / org_roles /
//!                          public / authenticated / policy, itself or through its group's defaults())
//! Warnings:
//!   inline-style           style="..." in a template (display:none for Alpine is fine)
//!   inline-svg             <svg> pasted in a template instead of an icon class
//!   routes-test            a feature with routes.zig but no routes_test.zig

const std = @import("std");

pub const Severity = enum { err, warn };

pub const Issue = struct {
    severity: Severity,
    /// Relative to the project root.
    path: []const u8,
    line: usize,
    rule: []const u8,
    message: []const u8,
    fix: []const u8,
};

pub const Report = struct {
    arena: std.mem.Allocator,
    issues: std.ArrayListUnmanaged(Issue) = .empty,

    pub fn add(r: *Report, severity: Severity, path: []const u8, line: usize, rule: []const u8, comptime msg_fmt: []const u8, msg_args: anytype, fix: []const u8) !void {
        try r.issues.append(r.arena, .{
            .severity = severity,
            .path = try r.arena.dupe(u8, path),
            .line = line,
            .rule = rule,
            .message = try std.fmt.allocPrint(r.arena, msg_fmt, msg_args),
            .fix = fix,
        });
    }

    pub fn count(r: Report, severity: Severity) usize {
        var n: usize = 0;
        for (r.issues.items) |i| {
            if (i.severity == severity) n += 1;
        }
        return n;
    }

    /// "src/x.html:12: error [kit-class]: ...\n    fix: ...", errors first.
    pub fn write(r: Report, w: *std.Io.Writer) !void {
        for ([_]Severity{ .err, .warn }) |sev| {
            for (r.issues.items) |i| {
                if (i.severity != sev) continue;
                try w.print("{s}:{d}: {s} [{s}]: {s}\n    fix: {s}\n", .{ i.path, i.line, if (sev == .err) "error" else "warning", i.rule, i.message, i.fix });
            }
        }
        try w.print("{d} error(s), {d} warning(s)\n", .{ r.count(.err), r.count(.warn) });
    }
};

// ── Checks over the project tree ────────────────────────────────────────

pub fn check(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir, report: *Report) !void {
    const main_src = readOrEmpty(io, arena, root, "src/main.zig");
    const styles = readOrEmpty(io, arena, root, "src/styles.css");
    const has_ui_layer = if (root.access(io, "src/ui.css", .{})) |_| true else |_| false;
    const has_auth = std.mem.indexOf(u8, main_src, "_auth.middleware()") != null or
        std.mem.indexOf(u8, main_src, "markAuthMiddleware") != null;

    var src = root.openDir(io, "src", .{ .iterate = true }) catch return;
    defer src.close(io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(arena, "src/{s}", .{entry.path});
        const text = src.readFileAlloc(io, entry.path, arena, .limited(8 * 1024 * 1024)) catch continue;
        if (std.mem.endsWith(u8, path, ".zig")) {
            if (std.mem.endsWith(u8, path, "embedded_templates.zig")) continue;
            if (std.mem.endsWith(u8, path, "/routes.zig")) {
                if (has_auth) try checkRouteAccess(report, path, text);
            } else if (!std.mem.endsWith(u8, path, "_test.zig")) {
                try checkRoutesOutside(report, path, text);
            }
        } else if (std.mem.endsWith(u8, path, ".html")) {
            try checkTemplate(report, path, text, styles, has_ui_layer);
        }
    }
    try checkFeatures(io, arena, root, report);
}

fn readOrEmpty(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir, path: []const u8) []const u8 {
    return root.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch "";
}

fn checkFeatures(io: std.Io, arena: std.mem.Allocator, root: std.Io.Dir, report: *Report) !void {
    const registry = readOrEmpty(io, arena, root, "src/features/mod.zig");
    var features = root.openDir(io, "src/features", .{ .iterate = true }) catch return;
    defer features.close(io);
    var it = features.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var dir = features.openDir(io, entry.name, .{}) catch continue;
        defer dir.close(io);
        const has = struct {
            fn f(i: std.Io, d: std.Io.Dir, name: []const u8) bool {
                d.access(i, name, .{}) catch return false;
                return true;
            }
        }.f;
        if (has(io, dir, "mod.zig")) {
            const import = try std.fmt.allocPrint(arena, "\"{s}/mod.zig\"", .{entry.name});
            if (std.mem.indexOf(u8, registry, import) == null) {
                const path = try std.fmt.allocPrint(arena, "src/features/{s}/mod.zig", .{entry.name});
                try report.add(.err, path, 1, "feature-not-registered", "feature '{s}' isn't in src/features/mod.zig: its routes aren't mounted and its tests don't run", .{entry.name}, "add `pub const <name> = @import(\"<name>/mod.zig\");` to src/features/mod.zig");
            }
        }
        if (has(io, dir, "routes.zig") and !has(io, dir, "routes_test.zig")) {
            const path = try std.fmt.allocPrint(arena, "src/features/{s}/routes.zig", .{entry.name});
            try report.add(.warn, path, 1, "routes-test", "feature '{s}' has no routes_test.zig pinning its method/path/access table", .{entry.name}, "add routes_test.zig with spider.testing.expectRoutes(routes.build(), &.{ ... }) and import it from mod.zig's test block");
        }
    }
}

// ── Per-file rules (pure: text in, issues out) ─────────────────────────

const route_methods = [_][]const u8{ ".get(", ".post(", ".put(", ".delete(", ".patch(", ".head(", ".sse(", ".sseWith(", ".ws(" };

fn lineOf(text: []const u8, index: usize) usize {
    return std.mem.count(u8, text[0..index], "\n") + 1;
}

fn isComment(text: []const u8, index: usize) bool {
    var start = index;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return std.mem.startsWith(u8, std.mem.trimStart(u8, text[start..index], " \t"), "//");
}

/// `.get("/path", ...)` & co. outside routes.zig. c.params.get("id") and
/// friends don't start their string with '/', so they don't match.
pub fn checkRoutesOutside(report: *Report, path: []const u8, text: []const u8) !void {
    for (route_methods) |m| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, m)) |at| {
            from = at + m.len;
            const rest = std.mem.trimStart(u8, text[from..], " \t\r\n");
            if (!std.mem.startsWith(u8, rest, "\"/")) continue;
            if (isComment(text, at)) continue;
            try report.add(.err, path, lineOf(text, at), "route-outside-routes", "route registered here, outside a feature's routes.zig", .{}, "move it to src/features/<feature>/routes.zig (a spider.Group returned by a pub fn): mountFeatures mounts it, and its access is declared next to it");
        }
    }
}

fn hasAccessKey(text: []const u8) bool {
    for ([_][]const u8{ ".roles", ".org_roles", ".public", ".authenticated", ".policy" }) |k| {
        if (std.mem.indexOf(u8, text, k) != null) return true;
    }
    return false;
}

/// Whether a route or defaults() call declares access: in the call itself,
/// or through a constant it passes (`const admin = .{ .roles = ... };` in the
/// same file). A config the file can't resolve (a constant from another
/// file) counts as declared: this check stays free of false alarms, and
/// `spider routes --check` checks the running app exactly.
fn declaresAccess(file: []const u8, call: []const u8) bool {
    if (hasAccessKey(call)) return true;
    // The last argument: the config.
    const inner = std.mem.trim(u8, call, "() \t\r\n");
    const last_comma = std.mem.lastIndexOfScalar(u8, inner, ',');
    const arg = std.mem.trim(u8, if (last_comma) |c| inner[c + 1 ..] else inner, " \t\r\n");
    if (arg.len == 0 or arg[0] == '.') return false; // a literal .{...} without access keys
    for (arg) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return true; // other_file.config
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, file, from, "const ")) |at| {
        from = at + 6;
        const rest = file[from..];
        if (!std.mem.startsWith(u8, rest, arg)) continue;
        const after = std.mem.trimStart(u8, rest[arg.len..], " \t");
        if (!std.mem.startsWith(u8, after, "=")) continue;
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        return hasAccessKey(rest[0..end]);
    }
    return true; // not found here: an import or a parameter
}

/// The text of the call starting at `open` (the '('), up to its matching ')'.
fn callText(text: []const u8, open: usize) []const u8 {
    var depth: usize = 0;
    var i = open;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (ch == '\\') i += 1 else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return text[open .. i + 1];
            },
            else => {},
        }
    }
    return text[open..];
}

/// With auth, every route in a routes.zig must say who may call it.
pub fn checkRouteAccess(report: *Report, path: []const u8, text: []const u8) !void {
    // Each Group.init(...) starts a group; its defaults() applies to the
    // routes after it, up to the next group.
    var groups: std.ArrayListUnmanaged(usize) = .empty;
    defer groups.deinit(report.arena);
    try groups.append(report.arena, 0);
    var g_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, g_from, "Group.init(")) |at| {
        try groups.append(report.arena, at);
        g_from = at + 1;
    }
    try groups.append(report.arena, text.len);

    for (groups.items[0 .. groups.items.len - 1], groups.items[1..]) |start, end| {
        const segment = text[start..end];
        var group_default = false;
        var d_from: usize = 0;
        while (std.mem.indexOfPos(u8, segment, d_from, ".defaults(")) |d| {
            d_from = d + 1;
            if (isComment(segment, d)) continue;
            group_default = declaresAccess(text, callText(segment, d + ".defaults".len));
            break;
        }
        for (route_methods) |m| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, segment, from, m)) |at| {
                from = at + m.len;
                const rest = std.mem.trimStart(u8, segment[from..], " \t\r\n");
                if (!std.mem.startsWith(u8, rest, "\"")) continue;
                if (isComment(segment, at)) continue;
                const call = callText(segment, at + m.len - 1);
                const plain_sse = std.mem.eql(u8, m, ".sse(") or std.mem.eql(u8, m, ".ws(");
                if (!plain_sse and (group_default or declaresAccess(text, call))) continue;
                const fix = if (plain_sse)
                    "use .sseWith(path, handler, .{ ... }) with .authenticated / .roles / .org_roles / .policy"
                else
                    "add .roles / .org_roles / .authenticated (any logged-in user) / .policy or .public to its config, or a defaults(...) to its group";
                try report.add(.err, path, lineOf(text, start + at), "route-access", "route declares no access; with auth, any logged-in user may call it", .{}, fix);
            }
        }
    }
}

// Class tokens of `class="..."` / `:class="..."` attributes on a line.
const ClassIter = struct {
    line: []const u8,
    pos: usize = 0,
    toks: ?std.mem.TokenIterator(u8, .any) = null,

    fn next(it: *ClassIter) ?[]const u8 {
        while (true) {
            if (it.toks) |*toks| {
                if (toks.next()) |tok| return tok;
                it.toks = null;
            }
            const at = std.mem.indexOfPos(u8, it.line, it.pos, "class=\"") orelse return null;
            const start = at + "class=\"".len;
            const end = std.mem.indexOfScalarPos(u8, it.line, start, '"') orelse it.line.len;
            it.pos = end;
            it.toks = std.mem.tokenizeAny(u8, it.line[start..end], " '?:{}()!=&|,");
        }
    }
};

/// A component class of the daisyUI kit (btn, btn-primary, card-body, ...)
/// — templates use ui-* classes instead. Tailwind utilities sharing a word
/// (select-none, table, collapse) aren't.
pub fn isKitClass(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "ui-")) return false;
    const bases = [_][]const u8{
        "btn",         "card",     "badge",    "menu",      "alert",    "toast",   "navbar",       "drawer",
        "modal",       "dropdown", "tabs",     "stat",      "stats",    "avatar",  "indicator",    "join",
        "fieldset",    "loading",  "progress", "radio",     "checkbox", "toggle",  "rating",       "steps",
        "swap",        "tooltip",  "kbd",      "dock",      "skeleton", "input",   "textarea",     "file-input",
        "breadcrumbs", "timeline", "carousel", "countdown", "label",    "btm-nav", "form-control",
    };
    for (bases) |b| {
        if (std.mem.eql(u8, token, b)) return true;
        if (token.len > b.len and std.mem.startsWith(u8, token, b) and token[b.len] == '-') return true;
    }
    if (std.mem.eql(u8, token, "select")) return true;
    if (std.mem.startsWith(u8, token, "select-")) {
        const rest = token["select-".len..];
        for ([_][]const u8{ "none", "text", "all", "auto" }) |u| {
            if (std.mem.eql(u8, rest, u)) return false;
        }
        return true;
    }
    return false;
}

const icon_sets = [_]struct { prefix: []const u8, set: []const u8 }{
    .{ .prefix = "hero-", .set = "heroicons" },
    .{ .prefix = "lucide-", .set = "lucide" },
    .{ .prefix = "tabler-", .set = "tabler" },
};

fn setActive(styles: []const u8, set: []const u8) bool {
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "../bin/icons/{s}.mjs", .{set}) catch return false;
    return std.mem.indexOf(u8, styles, line) != null;
}

pub fn checkTemplate(report: *Report, path: []const u8, text: []const u8, styles: []const u8, has_ui_layer: bool) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        var classes: ClassIter = .{ .line = line };
        while (classes.next()) |tok| {
            if (has_ui_layer and isKitClass(tok)) {
                try report.add(.err, path, line_no, "kit-class", "`{s}` is a UI kit class; only src/ui.css may use the kit's classes", .{tok}, "use the ui-* class (ui-btn, ui-input, ui-card, ...) or Tailwind utilities; need a new style? add a ui-* class to src/ui.css");
            }
            if (has_ui_layer and std.mem.eql(u8, tok, "ti")) {
                try report.add(.err, path, line_no, "icon-set", "`ti` is the Tabler webfont, which this app doesn't load", .{}, "use an icon class, e.g. hero-home (spider icons)");
            }
            for (icon_sets) |s| {
                if (!std.mem.startsWith(u8, tok, s.prefix) or tok.len == s.prefix.len) continue;
                // daisyUI's hero component, not an icon.
                if (std.mem.eql(u8, tok, "hero-content") or std.mem.eql(u8, tok, "hero-overlay")) continue;
                if (!setActive(styles, s.set)) {
                    try report.add(.err, path, line_no, "icon-set", "`{s}` is from icon set {s}, which src/styles.css doesn't load: it renders empty", .{ tok, s.set }, "use an icon of an active set (`spider icons`), or `spider icons add <set>`");
                }
            }
        }
        if (std.mem.indexOf(u8, line, " style=\"")) |at| {
            const start = at + " style=\"".len;
            const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse line.len;
            const value = std.mem.trim(u8, line[start..end], " ;");
            if (!std.mem.eql(u8, value, "display:none") and !std.mem.eql(u8, value, "display: none")) {
                try report.add(.warn, path, line_no, "inline-style", "inline style=\"{s}\"", .{value}, "use Tailwind utilities or a ui-* class in src/ui.css");
            }
        }
        if (std.mem.indexOf(u8, line, "<svg") != null) {
            try report.add(.warn, path, line_no, "inline-svg", "SVG markup pasted in the template", .{}, "use an icon class (<span class=\"hero-NAME size-5\"></span>); for charts/illustrations, ignore");
        }
    }
}

const t = std.testing;

fn testReport(arena: *std.heap.ArenaAllocator) Report {
    return .{ .arena = arena.allocator() };
}

test "checkRoutesOutside: route registrations, not param/query lookups or comments" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r = testReport(&arena);
    try checkRoutesOutside(&r, "src/main.zig",
        \\    server
        \\        .get("/", home.index, .{})
        \\        .mountFeatures(features);
        \\    const id = c.params.get("id");
        \\    // .post("/old", x, .{}) — commented out
    );
    try t.expectEqual(@as(usize, 1), r.issues.items.len);
    try t.expectEqual(@as(usize, 2), r.issues.items[0].line);
}

test "checkRouteAccess: declared, inherited from defaults(), missing, and plain sse()" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r = testReport(&arena);
    try checkRouteAccess(&r, "src/features/posts/routes.zig",
        \\pub fn build() spider.Group {
        \\    var g = spider.Group.init("/posts");
        \\    _ = g
        \\        .defaults(.{ .roles = &.{"editor"} })
        \\        .get("", controller.index, .{});
        \\    return g;
        \\}
        \\pub fn open() spider.Group {
        \\    var g = spider.Group.init("/open");
        \\    _ = g
        \\        .get("/a", controller.a, .{ .public = true })
        \\        .get("/b", controller.b, .{ .quiet_log = true })
        \\        .sse("/events", controller.events)
        \\        .sseWith("/live", controller.live, .{ .authenticated = true })
        \\        .post("/:id/edit", controller.edit, .{ .policy = spider.policy("post_owner", isOwner) });
        \\    return g;
        \\}
    );
    try t.expectEqual(@as(usize, 2), r.issues.items.len);
    try t.expectEqual(@as(usize, 12), r.issues.items[0].line); // .get("/b") — order: .get before .sse
    try t.expectEqual(@as(usize, 13), r.issues.items[1].line);
}

test "checkRouteAccess: a commented defaults() doesn't count; configs in constants do" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r = testReport(&arena);
    try checkRouteAccess(&r, "src/features/posts/routes.zig",
        \\const sa = .{ .org_roles = &.{"super-admin"} };
        \\const quiet = .{ .quiet_log = true };
        \\pub fn build() spider.Group {
        \\    var g = spider.Group.init("/posts");
        \\    _ = g
        \\        // .defaults(.{ .roles = &.{"posts_admin"} })
        \\        .get("", controller.index, .{})
        \\        .get("/a", controller.a, sa)
        \\        .get("/b", controller.b, quiet)
        \\        .get("/c", controller.c, shared.admin_only);
        \\    return g;
        \\}
        \\pub fn admin() spider.Group {
        \\    var g = spider.Group.init("/admin");
        \\    _ = g.defaults(sa).get("/x", controller.x, .{});
        \\    return g;
        \\}
    );
    try t.expectEqual(@as(usize, 2), r.issues.items.len); // "" (commented defaults) and /b (quiet only)
    try t.expectEqual(@as(usize, 7), r.issues.items[0].line);
    try t.expectEqual(@as(usize, 9), r.issues.items[1].line);
}

test "checkTemplate: kit classes, inactive icon sets, inline style and svg" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r = testReport(&arena);
    const styles = "@plugin \"../bin/icons/heroicons.mjs\";";
    try checkTemplate(&r, "src/x.html",
        \\<button class="ui-btn ui-btn-primary"><span class="hero-home size-5"></span></button>
        \\<button class="btn btn-primary">x</button>
        \\<span class="lucide-house"></span>
        \\<div :class="ok ? 'alert alert-success' : 'ui-alert'" style="display:none"></div>
        \\<div style="color: red"><svg viewBox="0 0 1 1"></svg></div>
        \\<div class="select-none table hero-content"></div>
    , styles, true);
    var counts = std.StringHashMap(usize).init(arena.allocator());
    for (r.issues.items) |i| {
        const gop = try counts.getOrPut(i.rule);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    try t.expectEqual(@as(usize, 4), counts.get("kit-class").?); // btn, btn-primary, alert, alert-success
    try t.expectEqual(@as(usize, 1), counts.get("icon-set").?); // lucide-house
    try t.expectEqual(@as(usize, 1), counts.get("inline-style").?);
    try t.expectEqual(@as(usize, 1), counts.get("inline-svg").?);
    try t.expectEqual(@as(usize, 7), r.issues.items.len);

    // An app from before the UI kit layer: kit classes are its way of styling.
    var r2 = testReport(&arena);
    try checkTemplate(&r2, "src/x.html", "<a class=\"btn\">x</a>", styles, false);
    try t.expectEqual(@as(usize, 0), r2.issues.items.len);
}

test "isKitClass" {
    for ([_][]const u8{ "btn", "btn-primary", "card-body", "input-bordered", "select-bordered", "form-control", "btm-nav", "label-text", "menu" }) |c| try t.expect(isKitClass(c));
    for ([_][]const u8{ "ui-btn", "ui-card", "select-none", "table", "collapse", "hero-home", "bg-base-200", "text-error", "flex", "badger" }) |c| try t.expect(!isKitClass(c));
}

test "check: a whole tree (feature not registered, missing routes_test, auth)" {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "src/main.zig", "server.use(keycloak_auth.middleware()).mountFeatures(features);\n" },
        .{ "src/styles.css", "@import \"./ui.css\";\n@plugin \"../bin/icons/heroicons.mjs\";\n" },
        .{ "src/ui.css", "/* spider-ui: daisyui */\n" },
        .{ "src/features/mod.zig", "pub const posts = @import(\"posts/mod.zig\");\n" },
        .{ "src/features/posts/mod.zig", "" },
        .{ "src/features/posts/routes.zig", "var g = spider.Group.init(\"/posts\");\n_ = g.get(\"\", c.index, .{});\n" },
        .{ "src/features/posts/views/index.html", "<a class=\"ui-btn\"><span class=\"hero-home\"></span></a>\n" },
        .{ "src/features/tags/mod.zig", "" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var r = testReport(&arena);
    try check(io, arena.allocator(), tmp.dir, &r);
    var rules: [8][]const u8 = undefined;
    for (r.issues.items, 0..) |i, k| rules[k] = i.rule;
    try t.expectEqual(@as(usize, 3), r.issues.items.len);
    try t.expectEqual(@as(usize, 2), r.count(.err)); // tags not registered; posts route without access
    try t.expectEqual(@as(usize, 1), r.count(.warn)); // posts has no routes_test.zig
}

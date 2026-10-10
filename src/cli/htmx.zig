//! Which htmx a project uses, 2 or 4, and what differs between them in
//! what the CLI writes and downloads. A project says which one by the
//! script its layouts load: `/js/htmx.min.js` is htmx 2, `/js/htmx4.min.js`
//! is htmx 4. Nothing else records it.
const std = @import("std");

pub const Version = enum {
    two,
    four,

    /// "2" or "4", as given to `spider new --htmx=`.
    pub fn parse(text: []const u8) ?Version {
        if (std.mem.eql(u8, text, "2")) return .two;
        if (std.mem.eql(u8, text, "4")) return .four;
        return null;
    }
};

/// What the generated layouts carry for htmx 2: the line every template of
/// the CLI is written with.
pub const script_two = "<script src=\"/js/htmx.min.js\"></script>";
pub const script_four = "<script src=\"/js/htmx4.min.js\"></script>";

/// The file names in `public/js/`, which is also how a project is read.
pub const file_two = "htmx.min.js";
pub const file_four = "htmx4.min.js";
/// htmx 4's extension for Server-Sent Events (`hx-sse:connect`): fetched
/// when a template loads it.
pub const file_four_sse = "htmx4-sse.min.js";

/// A layout template of the CLI, for a project on `version`.
pub fn layout(allocator: std.mem.Allocator, template: []const u8, version: Version) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, template, script_two, if (version == .four) script_four else script_two);
}

// The one attribute of the generated views that the two versions spell
// differently: "remove the form once its request went well". htmx 4 names
// the event after:request and hands the request over as `ctx`.
const after_request_two = "hx-on::after-request=\"if(event.detail.successful) ";
const after_request_four = "hx-on::after:request=\"if(event.detail.ctx.response.status < 400) ";

/// A view template of the CLI, for a project on `version`.
pub fn view(allocator: std.mem.Allocator, template: []const u8, version: Version) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, template, after_request_two, if (version == .four) after_request_four else after_request_two);
}

/// The version the layouts of a project load: htmx 4 when one of them
/// names its file, htmx 2 otherwise (every project made before the choice
/// existed).
pub fn ofLayouts(layouts: []const []const u8) Version {
    for (layouts) |text| {
        if (std.mem.indexOf(u8, text, "/js/" ++ file_four) != null) return .four;
    }
    return .two;
}

/// Whether some layout loads htmx 4's SSE extension.
pub fn wantsSse(layouts: []const []const u8) bool {
    for (layouts) |text| {
        if (std.mem.indexOf(u8, text, "/js/" ++ file_four_sse) != null) return true;
    }
    return false;
}

/// The layouts of the project in `project_dir`: every .html file of
/// src/shared/templates. The caller frees each text and the list.
pub fn readLayouts(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |text| allocator.free(text);
        out.deinit(allocator);
    }
    var dir = project_dir.openDir(io, "src/shared/templates", .{ .iterate = true }) catch return out.toOwnedSlice(allocator);
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
        const text = dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024)) catch continue;
        try out.append(allocator, text);
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeLayouts(allocator: std.mem.Allocator, layouts: [][]const u8) void {
    for (layouts) |text| allocator.free(text);
    allocator.free(layouts);
}

/// The version of the project in `project_dir`.
pub fn ofProject(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) Version {
    const layouts = readLayouts(io, allocator, project_dir) catch return .two;
    defer freeLayouts(allocator, layouts);
    return ofLayouts(layouts);
}

const layout_tmpl = @embedFile("templates/layout.html.template");
const app_layout_tmpl = @embedFile("templates/app_layout.html.template");
const form_tmpl = @embedFile("templates/feature/_form.html.template");

test "Version.parse" {
    try std.testing.expectEqual(@as(?Version, .two), Version.parse("2"));
    try std.testing.expectEqual(@as(?Version, .four), Version.parse("4"));
    try std.testing.expectEqual(@as(?Version, null), Version.parse("3"));
    try std.testing.expectEqual(@as(?Version, null), Version.parse(""));
}

test "the layouts load the htmx the project was made with, and say which one it is" {
    const a = std.testing.allocator;
    for ([_][]const u8{ layout_tmpl, app_layout_tmpl }) |template| {
        // The templates are written for htmx 2: this is what `layout` looks for.
        try std.testing.expect(std.mem.indexOf(u8, template, script_two) != null);

        const two = try layout(a, template, .two);
        defer a.free(two);
        try std.testing.expectEqualStrings(template, two);
        try std.testing.expectEqual(Version.two, ofLayouts(&.{two}));

        const four = try layout(a, template, .four);
        defer a.free(four);
        try std.testing.expect(std.mem.indexOf(u8, four, script_four) != null);
        try std.testing.expect(std.mem.indexOf(u8, four, script_two) == null);
        try std.testing.expectEqual(Version.four, ofLayouts(&.{ two, four }));
    }
    try std.testing.expectEqual(Version.two, ofLayouts(&.{}));
    try std.testing.expect(!wantsSse(&.{script_four}));
    try std.testing.expect(wantsSse(&.{"<script src=\"/js/htmx4-sse.min.js\"></script>"}));
}

test "the generated form removes itself after a good request, in the words of each version" {
    const a = std.testing.allocator;
    try std.testing.expect(std.mem.indexOf(u8, form_tmpl, after_request_two) != null);

    const four = try view(a, form_tmpl, .four);
    defer a.free(four);
    try std.testing.expect(std.mem.indexOf(u8, four, "hx-on::after:request=\"if(event.detail.ctx.response.status < 400) this.closest('.ui-card').remove()\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, four, "after-request") == null);

    const two = try view(a, form_tmpl, .two);
    defer a.free(two);
    try std.testing.expectEqualStrings(form_tmpl, two);
}

test "ofProject: read from the layouts on disk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(Version.two, ofProject(io, a, tmp.dir)); // not even a templates folder

    try tmp.dir.createDirPath(io, "src/shared/templates");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/shared/templates/layout.html", .data = "<head>" ++ script_two ++ "</head>" });
    try std.testing.expectEqual(Version.two, ofProject(io, a, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "src/shared/templates/app.html", .data = "<head>" ++ script_four ++ "</head>" });
    try std.testing.expectEqual(Version.four, ofProject(io, a, tmp.dir));
}

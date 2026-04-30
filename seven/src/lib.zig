const std = @import("std");

pub const TemplateLoader = struct {
    ptr: *anyopaque,
    getFn: *const fn (*anyopaque, []const u8) ?[]const u8,

    pub fn get(self: TemplateLoader, name: []const u8) ?[]const u8 {
        return self.getFn(self.ptr, name);
    }
};

const root = @import("root");
const has_templates = @hasDecl(root, "spider_templates");

const AutoLoader = struct {
    fn get(_: *anyopaque, name: []const u8) ?[]const u8 {
        if (!has_templates) return null;
        const Templates = root.spider_templates;
        var buf: [256]u8 = undefined;
        var j: usize = 0;
        for (name) |c| {
            buf[j] = if (c == '/' or c == '-') '_' else c;
            j += 1;
        }
        const normalized = buf[0..j];
        inline for (std.meta.fields(Templates)) |field| {
            if (std.mem.eql(u8, field.name, normalized)) {
                const instance: Templates = .{};
                return @field(instance, field.name);
            }
        }
        return null;
    }

    fn loader() TemplateLoader {
        return .{ .ptr = undefined, .getFn = AutoLoader.get };
    }
};

fn getLoader() ?TemplateLoader {
    if (!has_templates) return null;
    return AutoLoader.loader();
}

fn extractExtendsName(content: []const u8) ?[]const u8 {
    const marker = "{% extends \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return null;
    const name_start = start + marker.len;
    const name_end = std.mem.indexOf(u8, content[name_start..], "\"") orelse return null;
    return content[name_start .. name_start + name_end];
}

fn viewRuntime(name: []const u8, is_htmx: bool) void {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const allocator = std.heap.page_allocator;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "src/views/{s}.html", .{name}) catch {
        std.debug.print("[ERROR] path too long\n", .{});
        return;
    };

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch {
        std.debug.print("[ERROR] TemplateNotFound: '{s}'\n", .{name});
        return;
    };
    defer allocator.free(content);

    if (extractExtendsName(content)) |layout_name| {
        std.debug.print("[runtime] '{s}' extends '{s}'\n", .{ name, layout_name });

        var layout_path_buf: [512]u8 = undefined;
        const layout_path = std.fmt.bufPrint(&layout_path_buf, "src/views/{s}.html", .{layout_name}) catch return;

        const layout_content = std.Io.Dir.cwd().readFileAlloc(io, layout_path, allocator, .limited(512 * 1024)) catch {
            std.debug.print("[ERROR] LayoutNotFound: '{s}'\n", .{layout_name});
            return;
        };
        defer allocator.free(layout_content);

        if (is_htmx) {
            std.debug.print("[HTMX] returning content block only\n", .{});
            std.debug.print("--- content ({d} bytes) ---\n{s}\n---\n", .{ content.len, content });
        } else {
            std.debug.print("[full page] layout({d}b) + view({d}b)\n", .{ layout_content.len, content.len });
            std.debug.print("--- layout ---\n{s}\n--- view ---\n{s}\n---\n", .{ layout_content, content });
        }
    } else {
        std.debug.print("[runtime] '{s}' — no layout\n", .{name});
        std.debug.print("--- content ({d} bytes) ---\n{s}\n---\n", .{ content.len, content });
    }
}

pub const Mode = enum { embed, runtime };

fn captureEmbed(name: []const u8, is_htmx: bool) ?[]const u8 {
    if (!has_templates) return null;
    const loader = AutoLoader.loader();
    const view_content = loader.get(name) orelse return null;

    if (extractExtendsName(view_content)) |layout_name| {
        const layout_content = loader.get(layout_name) orelse return null;
        if (is_htmx) return view_content;
        const buf = std.heap.page_allocator.alloc(u8, layout_content.len + view_content.len) catch return null;
        @memcpy(buf[0..layout_content.len], layout_content);
        @memcpy(buf[layout_content.len..], view_content);
        return buf;
    } else {
        return view_content;
    }
}

fn captureRuntime(name: []const u8, is_htmx: bool) ?[]const u8 {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const alloc = std.heap.page_allocator;

    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "src/views/{s}.html", .{name}) catch return null;

    const view_content = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(512 * 1024)) catch return null;

    if (extractExtendsName(view_content)) |layout_name| {
        var lpb: [512]u8 = undefined;
        const lpath = std.fmt.bufPrint(&lpb, "src/views/{s}.html", .{layout_name}) catch {
            alloc.free(view_content);
            return null;
        };
        const layout_content = std.Io.Dir.cwd().readFileAlloc(io, lpath, alloc, .limited(512 * 1024)) catch {
            alloc.free(view_content);
            return null;
        };

        if (is_htmx) {
            alloc.free(layout_content);
            return view_content;
        } else {
            defer alloc.free(layout_content);
            defer alloc.free(view_content);
            const buf = alloc.alloc(u8, layout_content.len + view_content.len) catch return null;
            @memcpy(buf[0..layout_content.len], layout_content);
            @memcpy(buf[layout_content.len..], view_content);
            return buf;
        }
    } else {
        return view_content;
    }
}

pub fn viewCapture(name: []const u8, is_htmx: bool, mode: Mode) ?[]const u8 {
    return switch (mode) {
        .embed => captureEmbed(name, is_htmx),
        .runtime => captureRuntime(name, is_htmx),
    };
}

pub fn view(name: []const u8, data: anytype, is_htmx: bool) void {
    _ = data;

    if (!has_templates) {
        viewRuntime(name, is_htmx);
        return;
    }

    const loader = getLoader() orelse {
        std.debug.print("[runtime mode] would read '{s}' from disk\n", .{name});
        return;
    };

    const view_content = loader.get(name) orelse {
        std.debug.print("[ERROR] TemplateNotFound: '{s}'\n", .{name});
        return;
    };

    if (extractExtendsName(view_content)) |layout_name| {
        std.debug.print("[embed] '{s}' extends '{s}'\n", .{ name, layout_name });

        const layout_content = loader.get(layout_name) orelse {
            std.debug.print("[ERROR] LayoutNotFound: '{s}'\n", .{layout_name});
            return;
        };

        if (is_htmx) {
            std.debug.print("[HTMX] returning content block only\n", .{});
            std.debug.print("--- content ({d} bytes) ---\n{s}\n---\n", .{ view_content.len, view_content });
        } else {
            std.debug.print("[full page] layout({d}b) + view({d}b)\n", .{ layout_content.len, view_content.len });
            std.debug.print("--- layout ---\n{s}\n--- view ---\n{s}\n---\n", .{ layout_content, view_content });
        }
    } else {
        std.debug.print("[embed] '{s}' — no layout\n", .{name});
        std.debug.print("--- content ({d} bytes) ---\n{s}\n---\n", .{ view_content.len, view_content });
    }
}

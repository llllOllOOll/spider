//! The template type: `Template` parses a template source once and renders it
//! with data. `Ctx.view()` is built on it; apps use it directly to render a
//! template outside a request (a test of a view, the body of an e-mail).

const std = @import("std");
const ast = @import("ast.zig");
const ctx_mod = @import("context.zig");
const parser_mod = @import("parser.zig");
const renderer_mod = @import("renderer.zig");
const embedded = @import("embedded.zig");

const Node = ast.Node;
const freeNode = ast.freeNode;
const Context = ctx_mod.Context;
// internal: the value type of `Template.Global`.
pub const Value = ctx_mod.Value;
const structToContext = ctx_mod.structToContext;
const dupeValue = ctx_mod.dupeValue;
const Parser = parser_mod.Parser;
const renderNode = renderer_mod.renderNode;
const RenderState = renderer_mod.RenderState;

fn isRootTemplate(template_str: []const u8) bool {
    return std.mem.indexOf(u8, template_str, "<html") != null;
}

/// A parsed template. `init` parses the source, `render` and
/// `renderFragment` produce the HTML, `deinit` frees the parsed tree.
///
/// ```zig
/// var tmpl = try spider.Template.init(alc, "Hello { name }!");
/// defer tmpl.deinit();
/// const html = try tmpl.render(.{ .name = "World" }, alc);
/// defer alc.free(html);
/// ```
///
/// `{ expr }` is HTML-escaped, except a `spider.RawHtml` value.
pub const Template = struct {
    /// The parsed template, owned by the template. Read-only for apps.
    nodes: []Node,
    /// The allocator given to `init`; `deinit` frees with it.
    allocator: std.mem.Allocator,
    /// Component and layout sources by name. Set it after `init` to give the
    /// template the components it uses; the map then stays yours and `deinit`
    /// does not free it (the first render adds the template's inline
    /// components to it, allocated with that render's allocator). Left null,
    /// the first render creates it from the components defined inline in the
    /// template and `deinit` frees it.
    components: ?std.StringHashMapUnmanaged([]const u8) = null,
    /// The components the parser found defined inside the template, until the
    /// first render moves them into `components`.
    inline_components: ?std.StringHashMapUnmanaged([]const u8) = null,
    /// The name given by `extends "name"` at the very start of the source,
    /// or null. `render` looks it up among the components.
    layout: ?[]const u8 = null,
    /// True when the source contains `<html`. Nothing in Spider reads it.
    is_root: bool = false,
    // Set when collectInline() creates `components` itself (no caller-supplied
    // map existed yet), so deinit() knows it must free that map. When a caller
    // (e.g. Ctx.view()) supplies `components` up front, ownership stays with
    // the caller and this flag remains false.
    /// Read-only: true when `deinit` frees `components`.
    owns_components: bool = false,
    /// Read-only components shared by every render (Ctx.view() passes the
    /// embedded templates here). Looked up after `components`, so inline
    /// components still take precedence; never modified or freed.
    base_components: ?*const embedded.Map = null,
    /// Names every render of this template can use besides its data
    /// (Ctx.view() passes `current_user` here). A name the data has too
    /// keeps the data's value. Not copied or freed here.
    globals: []const Global = &.{},

    /// One entry of `globals`: a name and its value.
    pub const Global = struct { name: []const u8, value: Value };

    // Not generic: render() is instantiated once per data type.
    fn addGlobals(self: *const Template, ctx: *Context, alc: std.mem.Allocator) !void {
        for (self.globals) |global| {
            if (ctx.get(global.name) != null) continue;
            try ctx.set(alc, global.name, try dupeValue(alc, global.value));
        }
    }

    /// Parses `template_str`. The parsed tree is allocated with `alc` and
    /// holds copies: the source can be freed after this returns. Fails with
    /// the parser's error on a malformed template (`error.UnclosedInterpolation`,
    /// `error.UnclosedBrace`, `error.UnclosedParen`, `error.ExpectedBrace`,
    /// `error.ExpectedCapture`, `error.UnclosedCapture`) or `error.OutOfMemory`.
    pub fn init(alc: std.mem.Allocator, template_str: []const u8) !Template {
        var parser = Parser.init(alc, template_str);
        const result = try parser.parse();

        const is_root = isRootTemplate(template_str);

        return Template{
            .nodes = result.nodes,
            .allocator = alc,
            .layout = result.layout,
            .is_root = is_root,
            .inline_components = result.inline_components,
        };
    }

    /// Frees the parsed tree, and `components` when the template created the
    /// map itself. Strings returned by `render` are not freed here.
    pub fn deinit(self: *Template) void {
        for (self.nodes) |node| freeNode(node, self.allocator);
        self.allocator.free(self.nodes);
        if (self.layout) |l| self.allocator.free(l);
        if (self.inline_components) |*ic| {
            var iter = ic.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            ic.deinit(self.allocator);
        }
        if (self.owns_components) {
            if (self.components) |*comps| {
                var iter = comps.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                comps.deinit(self.allocator);
            }
        }
    }

    // internal: component source by name: `components` first, then `base_components`.
    pub fn findComponent(self: *const Template, name: []const u8) ?[]const u8 {
        if (self.components) |comps| {
            if (comps.get(name)) |src| return src;
        }
        if (self.base_components) |base| return base.get(name);
        return null;
    }

    // internal: `render` and `renderFragment` call it first. Collects inline
    // components: merges `inline_components` from the parser
    // into the main `components` map (phase 1), then registers any
    // `<Name>...</Name>` root-level definition nodes whose name is not yet
    // registered (phase 2). Idempotent — safe to call multiple times.
    pub fn collectInline(self: *Template, alc: std.mem.Allocator) !void {
        // Phase 1: Merge inline_components from parser into the main components map.
        if (self.inline_components) |inline_comps| {
            if (self.components) |*comps| {
                var iter = inline_comps.iterator();
                while (iter.next()) |entry| {
                    if (self.findComponent(entry.key_ptr.*) != null) {
                        std.debug.print("[spider] warning: inline component \"{s}\" shadows file component\n", .{entry.key_ptr.*});
                    }
                    try comps.put(alc, try alc.dupe(u8, entry.key_ptr.*), try alc.dupe(u8, entry.value_ptr.*));
                }
            } else {
                if (self.base_components) |base| {
                    var iter = inline_comps.iterator();
                    while (iter.next()) |entry| {
                        if (base.get(entry.key_ptr.*) != null) {
                            std.debug.print("[spider] warning: inline component \"{s}\" shadows file component\n", .{entry.key_ptr.*});
                        }
                    }
                }
                self.components = self.inline_components;
                self.owns_components = true;
            }
            self.inline_components = null;
        }

        // Phase 2: Collect inline component definitions from root-level nodes.
        {
            const original_nodes = self.nodes;
            var filtered = std.ArrayList(Node).empty;
            errdefer filtered.deinit(self.allocator);

            for (original_nodes) |node| {
                if (node == .component and !node.component.self_closing and node.component.slot_content != null) {
                    const name = node.component.name;
                    const already_registered = self.findComponent(name) != null;
                    if (!already_registered) {
                        // This is an inline component definition — register it.
                        const key = try self.allocator.dupe(u8, name);
                        const val = try self.allocator.dupe(u8, node.component.slot_content.?);
                        if (self.components) |*comps| {
                            try comps.put(self.allocator, key, val);
                        } else {
                            var new_comps = std.StringHashMapUnmanaged([]const u8){};
                            try new_comps.put(self.allocator, key, val);
                            self.components = new_comps;
                            self.owns_components = true;
                        }
                        freeNode(node, self.allocator);
                        continue; // Skip — definition, not rendered in place.
                    }
                }
                // Keep this node for rendering.
                try filtered.append(self.allocator, node);
            }

            self.nodes = try filtered.toOwnedSlice(self.allocator);
            self.allocator.free(original_nodes);
        }
    }

    /// Renders the template with `context`, a struct whose fields are the names
    /// the template reads (`.{}` for none). Returns the HTML, allocated with
    /// `alc` and owned by the caller.
    ///
    /// With `extends "name"`, the result is that layout with this template in
    /// its slot. A layout that is not among the components is ignored: the
    /// template renders alone.
    ///
    /// Fails with `error.ComponentDepthExceeded` when components nest deeper
    /// than `spider.template_max_component_depth`, with a parser error from a
    /// malformed component or layout, or `error.OutOfMemory`.
    pub fn render(self: *Template, context: anytype, alc: std.mem.Allocator) ![]const u8 {
        try self.collectInline(alc);

        var ctx = try structToContext(alc, context);
        defer ctx.deinit(alc);
        try self.addGlobals(&ctx, alc);

        var state = RenderState.init(self.components, self.base_components);
        defer state.deinit(alc);

        if (self.layout) |layout_name| {
            if (self.findComponent(layout_name)) |layout_template| {
                var slot_bufs = std.StringHashMapUnmanaged(std.ArrayList(u8)){};
                defer {
                    var iter = slot_bufs.iterator();
                    while (iter.next()) |entry| {
                        entry.value_ptr.*.deinit(alc);
                        alc.free(entry.key_ptr.*);
                    }
                    slot_bufs.deinit(alc);
                }

                var cur_buf = std.ArrayList(u8).empty;
                var cur_key: []const u8 = "slot";

                for (self.nodes) |node| {
                    if (node == .interpolation) {
                        const expr = node.interpolation;
                        if (std.mem.startsWith(u8, expr, "slot_")) {
                            const key = try alc.dupe(u8, cur_key);
                            try slot_bufs.put(alc, key, cur_buf);
                            cur_key = expr;
                            cur_buf = std.ArrayList(u8).empty;
                            continue;
                        }
                    }
                    try renderNode(node, &ctx, alc, &cur_buf, &state);
                }
                {
                    const key = try alc.dupe(u8, cur_key);
                    try slot_bufs.put(alc, key, cur_buf);
                }

                var layout_ctx = try ctx.clone(alc);
                defer layout_ctx.deinit(alc);

                var iter = slot_bufs.iterator();
                while (iter.next()) |entry| {
                    try layout_ctx.set(alc, entry.key_ptr.*, Value{ .html = try alc.dupe(u8, entry.value_ptr.*.items) });
                }

                var layout_parser = Parser.init(alc, layout_template);
                const layout_result = try layout_parser.parse();
                defer {
                    for (layout_result.nodes) |n| freeNode(n, alc);
                    alc.free(layout_result.nodes);
                }

                var layout_result_bytes: std.ArrayList(u8) = .empty;
                defer layout_result_bytes.deinit(alc);

                for (layout_result.nodes) |n| {
                    try renderNode(n, &layout_ctx, alc, &layout_result_bytes, &state);
                }

                return layout_result_bytes.toOwnedSlice(alc);
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(alc);

        for (self.nodes) |node| {
            try renderNode(node, &ctx, alc, &result, &state);
        }

        return result.toOwnedSlice(alc);
    }

    /// Renders only a single named component (inline or file) from this
    /// template, skipping layout and root-level nodes entirely. `context` is
    /// the data, as in `render`. The HTML is allocated with `alc` and owned by
    /// the caller. Returns `error.ComponentNotFound` if the component name is
    /// not registered; otherwise fails like `render`.
    pub fn renderFragment(self: *Template, component_name: []const u8, context: anytype, alc: std.mem.Allocator) ![]const u8 {
        try self.collectInline(alc);

        const comp_template = self.findComponent(component_name) orelse return error.ComponentNotFound;

        var comp_parser = Parser.init(alc, comp_template);
        const comp_nodes = try comp_parser.parse();
        defer {
            for (comp_nodes.nodes) |n| freeNode(n, alc);
            alc.free(comp_nodes.nodes);
        }

        var comp_ctx = try structToContext(alc, context);
        defer comp_ctx.deinit(alc);
        try self.addGlobals(&comp_ctx, alc);

        var state = RenderState.init(self.components, self.base_components);
        defer state.deinit(alc);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(alc);

        for (comp_nodes.nodes) |n| {
            try renderNode(n, &comp_ctx, alc, &result, &state);
        }

        return result.toOwnedSlice(alc);
    }
};

test {
    _ = @import("template_test.zig");
}

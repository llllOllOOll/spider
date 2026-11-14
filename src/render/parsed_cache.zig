//! Internal: the app's embedded templates, parsed once.
//!
//! In a build that embeds its templates, every source is a constant in the
//! binary: its address never changes. `build` parses each one when the
//! server starts (pages, layouts, components, the inline components a page
//! defines and the content between a component's tags), and from then on a
//! render looks the parsed nodes up by the source's address instead of
//! parsing it again on every request. After `build` the cache is only read:
//! no lock. A template that fails to parse stops `build`, so a syntax error
//! stops the server at startup instead of answering 500 to one request.
//!
//! Everything here lives as long as the process. Templates read from disk
//! (Debug builds) never come here: an edit must show on the next request.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const embedded = @import("embedded.zig");

const Node = ast.Node;
const Parser = parser_mod.Parser;

/// A template as a page renders it: the root-level inline component
/// definitions already taken out of `nodes` and into `inline_components`
/// (what Template.collectInline does on a first render).
pub const Page = struct {
    nodes: []Node,
    layout: ?[]const u8,
    inline_components: std.StringHashMapUnmanaged([]const u8),
};

const Key = struct { ptr: usize, len: usize };

fn keyOf(src: []const u8) Key {
    return .{ .ptr = @intFromPtr(src.ptr), .len = src.len };
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
/// Source -> nodes as parsed: components, layouts, slot content.
var raw_nodes: std.AutoHashMapUnmanaged(Key, []Node) = .{};
/// Source -> the page form of it.
var pages: std.AutoHashMapUnmanaged(Key, Page) = .{};
var ready = std.atomic.Value(bool).init(false);

/// The nodes of `src` as the parser gives them, or null (not built, or not
/// an embedded source).
pub fn raw(src: []const u8) ?[]Node {
    if (!ready.load(.acquire)) return null;
    return raw_nodes.get(keyOf(src));
}

/// The page form of `src`, or null.
pub fn page(src: []const u8) ?*const Page {
    if (!ready.load(.acquire)) return null;
    return pages.getPtr(keyOf(src));
}

/// True once `build` has run.
pub fn isReady() bool {
    return ready.load(.acquire);
}

/// Parses every template of `map` once. Call it before the server takes
/// requests, from one thread; later calls do nothing. Returns how many
/// sources were parsed. Fails with the parser's error on the first
/// template that does not parse (the parser logs which one, and where).
pub fn build(map: *const embedded.Map) !usize {
    if (ready.load(.acquire)) return raw_nodes.count();
    const alc = arena_state.allocator();
    const keys = map.keys();
    const values = map.values();
    for (keys, values) |name, src| {
        if (std.mem.startsWith(u8, src, "-- doc")) continue; // Markdown, not a template
        try addPage(alc, map, name, src);
    }
    ready.store(true, .release);
    return raw_nodes.count();
}

fn addPage(alc: std.mem.Allocator, map: *const embedded.Map, name: []const u8, src: []const u8) !void {
    const gop = try pages.getOrPut(alc, keyOf(src));
    if (gop.found_existing) return;
    var parser = Parser.init(alc, src);
    parser.name = name;
    const parsed = parser.parse() catch |err| {
        _ = pages.remove(keyOf(src));
        return err;
    };
    var inline_components = parsed.inline_components;

    // What collectInline's second phase does: a root-level `<Name>...</Name>`
    // with content, under a name nothing registers yet, defines an inline
    // component and is not rendered in place.
    var kept: std.ArrayList(Node) = .empty;
    for (parsed.nodes) |node| {
        if (node == .component and !node.component.self_closing and node.component.slot_content != null) {
            const cname = node.component.name;
            if (!inline_components.contains(cname) and map.get(cname) == null) {
                try inline_components.put(alc, cname, node.component.slot_content.?);
                continue;
            }
        }
        try kept.append(alc, node);
    }
    gop.value_ptr.* = .{
        .nodes = try kept.toOwnedSlice(alc),
        .layout = parsed.layout,
        .inline_components = inline_components,
    };

    // The same source as a component or a layout, its inline components,
    // and every component's slot content.
    try addRaw(alc, name, src);
    var it = inline_components.iterator();
    while (it.next()) |e| try addRaw(alc, e.key_ptr.*, e.value_ptr.*);
    try addSlots(alc, name, gop.value_ptr.nodes);
}

fn addRaw(alc: std.mem.Allocator, name: []const u8, src: []const u8) !void {
    const gop = try raw_nodes.getOrPut(alc, keyOf(src));
    if (gop.found_existing) return;
    var parser = Parser.init(alc, src);
    parser.name = name;
    const parsed = parser.parse() catch |err| {
        _ = raw_nodes.remove(keyOf(src));
        return err;
    };
    gop.value_ptr.* = parsed.nodes;
    try addSlots(alc, name, parsed.nodes);
}

/// The content between a component's tags is parsed when the component is
/// rendered: cache it too, wherever it sits (inside if/for bodies as well).
fn addSlots(alc: std.mem.Allocator, name: []const u8, nodes: []const Node) anyerror!void {
    for (nodes) |node| switch (node) {
        .component => |c| if (c.slot_content) |sc| try addRaw(alc, name, sc),
        .if_node => |n| {
            try addSlots(alc, name, n.then_body);
            if (n.else_body) |eb| try addSlots(alc, name, eb);
        },
        .for_node => |n| try addSlots(alc, name, n.body),
        else => {},
    };
}

// internal (tests): forget everything, so a test can build again.
pub fn resetForTest() void {
    ready.store(false, .release);
    raw_nodes = .{};
    pages = .{};
    _ = arena_state.reset(.free_all);
}

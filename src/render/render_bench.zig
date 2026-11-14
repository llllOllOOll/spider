//! Internal: the template engine's benchmark (`zig build bench-render
//! -Doptimize=ReleaseFast`). Renders a catalog page the way `c.view` does
//! with embedded templates (parsed once, components from the embedded map):
//! a layout, a page with loops and conditions, and a card component with
//! declared props and a nested loop, 24 times per page. Prints renders per
//! second, the time spent converting the data alone, the allocations per
//! render, and a hash of the HTML, so a change to the engine can be measured
//! and shown to render the same bytes.

const std = @import("std");
const embedded = @import("embedded.zig");
const parsed_cache = @import("parsed_cache.zig");
const Template = @import("template.zig").Template;
const structToContext = @import("context.zig").structToContext;

const star_path = "M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.539 1.118l-2.8-2.034a1 1 0 00-1.176 0l-2.8 2.034c-.783.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.363-1.118l-2.8-2.034c-.784-.57-.381-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z";

const Templates = struct {
    layout: []const u8 =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><title>Catalog</title></head>
        \\<body>
        \\<header><nav><a href="/">Catalog</a><a href="/items">Items</a><span>Cart (3)</span></nav></header>
        \\<main>{ slot }</main>
        \\<footer><ul><li><a href="/items">All items</a></li><li><a href="#">Contact</a></li><li><a href="#">Shipping</a></li><li><a href="#">Returns</a></li><li><a href="#">About</a></li><li><a href="#">Privacy</a></li></ul><p>(c) 2026 Catalog.</p></footer>
        \\</body>
        \\</html>
    ,
    shop_index: []const u8 =
        \\extends "layout"
        \\<div class="head"><h1>All items</h1><p>{ total } items</p></div>
        \\<div class="chips"><span>Sort:</span>
        \\for (sort_chips) |chip| { <a href="{ chip.url }" class="{ chip.class }">{ chip.label }</a> }
        \\</div>
        \\<div class="chips"><span>Category:</span>
        \\for (cat_chips) |chip| { <a href="{ chip.url }" class="{ chip.class }">{ chip.label }</a> }
        \\</div>
        \\if (total == 0) {
        \\<p>Nothing found.</p>
        \\} else {
        \\<div class="grid">
        \\for (items) |item| { <ItemCard /> }
        \\</div>
        \\<nav aria-label="Pagination">
        \\if (prev_url != null) { <a href="{ prev_url }">Previous</a> } else { <span>Previous</span> }
        \\for (pages) |pl| {
        \\if (pl.current) { <span aria-current="page">{ pl.number }</span> } else { <a href="{ pl.url }">{ pl.number }</a> }
        \\}
        \\if (next_url != null) { <a href="{ next_url }">Next</a> } else { <span>Next</span> }
        \\</nav>
        \\}
    ,
    item_card: []const u8 = "-- props: item!\n" ++
        \\<a href="/items/{ item.id }" class="card">
        \\<div class="initials">{ item.initials }</div>
        \\<p class="category">{ item.category }</p>
        \\<h3>{ item.name }</h3>
        \\<div class="rating"><div class="stars">for (item.stars) |s| { <svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="{ s.class }"><path d="
    ++ star_path ++
        \\"></path></svg> }</div>
        \\<span>{ item.rating } ({ item.review_count })</span></div>
        \\<p class="price">{ item.price }</p>
        \\</a>
    ,
};

const map = embedded.buildMap(Templates);

const Star = struct { class: []const u8 };
const Item = struct {
    id: u32,
    initials: []const u8,
    category: []const u8,
    name: []const u8,
    stars: []const Star,
    rating: []const u8,
    review_count: u32,
    price: []const u8,
};
const Chip = struct { url: []const u8, label: []const u8, class: []const u8 };
const PageLink = struct { number: usize, url: []const u8, current: bool };
const Data = struct {
    total: usize,
    sort_chips: []const Chip,
    cat_chips: []const Chip,
    items: []const Item,
    prev_url: ?[]const u8,
    pages: []const PageLink,
    next_url: ?[]const u8,
};

const stars_table = blk: {
    var t: [6][5]Star = undefined;
    for (0..6) |filled| {
        for (0..5) |i| t[filled][i] = .{ .class = if (i < filled) "star on" else "star off" };
    }
    break :blk t;
};

fn makeData(alc: std.mem.Allocator) !Data {
    const items = try alc.alloc(Item, 24);
    for (items, 0..) |*it, i| it.* = .{
        .id = @intCast(49 + i),
        .initials = "LT",
        .category = "Audio & Video",
        .name = try std.fmt.allocPrint(alc, "Lumen Turntable <Max> {d}", .{i}),
        .stars = &stars_table[i % 6],
        .rating = try std.fmt.allocPrint(alc, "{d}.{d}", .{ 3 + i % 2, i % 10 }),
        .review_count = @intCast(i * 7 % 40),
        .price = try std.fmt.allocPrint(alc, "${d}.{d:0>2}", .{ 100 + i * 37, i * 13 % 100 }),
    };
    const labels = [_][]const u8{ "Default", "Name", "Price: Low to high", "Price: High to low", "Rating" };
    const sort_chips = try alc.alloc(Chip, labels.len);
    for (sort_chips, labels, 0..) |*c, l, i| c.* = .{
        .url = try std.fmt.allocPrint(alc, "/items?sort={d}&category=audio", .{i}),
        .label = l,
        .class = if (i == 2) "chip active" else "chip",
    };
    const cat_chips = try alc.alloc(Chip, 8);
    for (cat_chips, 0..) |*c, i| c.* = .{
        .url = try std.fmt.allocPrint(alc, "/items?sort=price&category=c{d}", .{i}),
        .label = try std.fmt.allocPrint(alc, "Category {d}", .{i}),
        .class = "chip",
    };
    const pages = try alc.alloc(PageLink, 21);
    for (pages, 1..) |*p, n| p.* = .{
        .number = n,
        .url = try std.fmt.allocPrint(alc, "/items?page={d}&sort=price", .{n}),
        .current = n == 3,
    };
    return .{
        .total = 500,
        .sort_chips = sort_chips,
        .cat_chips = cat_chips,
        .items = items,
        .prev_url = "/items?page=2&sort=price",
        .pages = pages,
        .next_url = "/items?page=4&sort=price",
    };
}

/// Counts allocations made through it (alloc and remap/resize that grow).
const Counting = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(mem, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(mem, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
    }
};

/// One render, as `c.view` does it with embedded templates.
fn renderOnce(alc: std.mem.Allocator, data: Data) ![]const u8 {
    const content = map.get("shop_index").?;
    var tmpl = Template.fromCache(alc, parsed_cache.page(content).?, "shop/index");
    tmpl.base_components = &map;
    return tmpl.render(data, alc);
}

/// Runs the benchmark, `seconds` per measure, and prints the results.
pub fn run(io: std.Io, seconds: u64) !void {
    _ = try parsed_cache.build(&map);

    var setup = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer setup.deinit();
    const data = try makeData(setup.allocator());

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // The output and its allocations, once.
    var counting: Counting = .{ .child = arena.allocator() };
    const html = try renderOnce(counting.allocator(), data);
    const hash = std.hash.Wyhash.hash(0, html);
    const allocs = counting.count;
    const bytes = html.len;
    _ = arena.reset(.retain_capacity);

    counting = .{ .child = arena.allocator() };
    var conv = try structToContext(counting.allocator(), data);
    conv.deinit(counting.allocator());
    const conv_allocs = counting.count;
    _ = arena.reset(.retain_capacity);

    const full = try timeLoop(io, seconds, &arena, data, renderOnce);
    const convert = try timeLoop(io, seconds, &arena, data, convertOnce);

    std.debug.print(
        \\render_bench: catalog page, 24 cards, single thread
        \\  output     {d} bytes, hash {x:0>16}
        \\  render     {d:.0} renders/s ({d:.2} us each), {d} allocations each
        \\  convert    {d:.0}/s ({d:.2} us each, {d:.0}% of a render), {d} allocations each
        \\
    , .{
        bytes,                 hash,
        full,                  1_000_000.0 / full,
        allocs,                convert,
        1_000_000.0 / convert, 100.0 * full / convert,
        conv_allocs,
    });
}

fn convertOnce(alc: std.mem.Allocator, data: Data) ![]const u8 {
    var c = try structToContext(alc, data);
    c.deinit(alc);
    return "";
}

/// Calls `f` for about `seconds`, resetting the arena between calls, as a
/// request does. Returns calls per second.
fn timeLoop(io: std.Io, seconds: u64, arena: *std.heap.ArenaAllocator, data: Data, comptime f: fn (std.mem.Allocator, Data) anyerror![]const u8) !f64 {
    // Warm up.
    for (0..200) |_| {
        _ = try f(arena.allocator(), data);
        _ = arena.reset(.retain_capacity);
    }
    const start = std.Io.Timestamp.now(io, .awake);
    const budget_ns: i96 = @intCast(seconds * std.time.ns_per_s);
    var n: usize = 0;
    var elapsed: i96 = 0;
    while (elapsed < budget_ns) {
        for (0..100) |_| {
            std.mem.doNotOptimizeAway(try f(arena.allocator(), data));
            _ = arena.reset(.retain_capacity);
        }
        n += 100;
        elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    }
    return @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s);
}

//! Elroy parity: every template in src/render/elroy/fixtures.zig is
//! rendered by the interpreter (`spider.Template`) and by the function
//! Elroy generated for it (src/elroy_fixture_gen.zig), with the same data;
//! the HTML must be the same, byte for byte. A template marked
//! `compiles = false` must get no function.

const std = @import("std");
const spider = @import("spider");
const fixtures = @import("src/render/elroy/fixtures.zig");
const gen = @import("elroy_fixtures");

const RawHtml = spider.RawHtml;
const t = std.testing;

const Author = struct { name: []const u8, born: u16 };
const Book = struct { title: []const u8, year: u32, author: Author = .{ .name = "Clarke", .born = 1969 } };
const Shelf = struct { name: []const u8, books: []const Book };

const the_book: Book = .{ .title = "Piranesi", .year = 2020 };
const books = [_]Book{
    .{ .title = "Piranesi", .year = 2020 },
    .{ .title = "Jonathan <Strange> & \"Mr\" Norrell", .year = 2004, .author = .{ .name = "S. Clarke", .born = 1969 } },
};

const Data = struct {
    title: []const u8 = "Piranesi",
    year: u32 = 2020,
    price: f64 = 12.5,
    ratio: f32 = 0.25,
    done: bool = true,
    off: bool = false,
    big: i64 = -1234567890123,
    quote: []const u8 = "say \"hi\" & 'bye'",
    html_text: []const u8 = "<b>bold</b>",
    raw: RawHtml = .{ .html = "<em>x</em>" },
    raw_opt: ?RawHtml = RawHtml{ .html = "<i>y</i>" },
    raw_null: ?RawHtml = null,
    note: ?[]const u8 = "a note",
    none: ?[]const u8 = null,
    opt_n: ?u32 = 7,
    opt_b: ?bool = false,
    opt_null_n: ?i32 = null,
    kind: enum { a, b } = .a,
    ids: []const u32 = &.{ 1, 2 },
    book: Book = the_book,
    ptr: *const Book = &the_book,
    empty: []const u8 = "",
    fstr: []const u8 = "false",
    false_text: []const u8 = "false",
    zero: u32 = 0,
    books: []const Book = &books,
    names: []const []const u8 = &.{ "ana", "bia", "cid" },
    with_len: struct { len: u32 = 42 } = .{},
    shelves: []const Shelf = &.{
        .{ .name = "fiction", .books = &books },
        .{ .name = "empty", .books = &.{} },
    },
    arr: [2]Book = books,
    raws: []const RawHtml = &.{ .{ .html = "<b>1</b>" }, .{ .html = "<b>2</b>" } },
    uni: []const u8 = "çãé 日本",
};

fn compiledName(name: []const u8) bool {
    for (gen.compiled) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

test "Elroy: each fixture renders the same HTML as the interpreter" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    const data: Data = .{};

    inline for (fixtures.cases) |c| {
        try t.expectEqual(c.compiles, compiledName(c.name));
        if (c.compiles) {
            var tmpl = try spider.Template.initNamed(alc, c.src, c.name);
            const want = try tmpl.render(data, alc);

            var aw: std.Io.Writer.Allocating = .init(alc);
            try @field(gen, c.name)(&aw.writer, data);
            const got = aw.written();
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("\nElroy parity, template \"{s}\":\n  interpreter: {s}\n  elroy:       {s}\n", .{ c.name, want, got });
                return error.ElroyParity;
            }
        }
    }
}

test "Elroy: anonymous struct data with comptime fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alc = arena.allocator();
    // What handlers pass: literals become comptime fields.
    const data = .{ .title = "Shelf", .year = 1999, .done = true, .books = &books };
    var tmpl = try spider.Template.init(alc, fixtures.cases[1].src);
    const want = try tmpl.render(data, alc);
    var aw: std.Io.Writer.Allocating = .init(alc);
    try gen.scalars(&aw.writer, data);
    try t.expectEqualStrings(want, aw.written());
}

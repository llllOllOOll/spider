const spider = @import("spider");
const model = @import("model.zig");

/// The shelf: every book as a card.
pub fn index(c: *spider.Ctx) !spider.Response {
    return c.view("books/index", .{ .title = "Shelf", .books = model.all() }, .{});
}

/// One book. `/books/banana` (not a u32) and `/books/99` (no such book)
/// are both 404s: the first one before this runs (spider.Path), the second
/// one here. spider.errorHandler renders the not_found view for them.
pub fn show(id: spider.Path(u32, "id"), c: *spider.Ctx) !spider.Response {
    const book = model.find(id.value) orelse return error.NotFound;
    return c.view("books/show", .{ .title = book.title, .book = book }, .{});
}

pub fn about(c: *spider.Ctx) !spider.Response {
    return c.view("books/about", .{ .title = "About" }, .{});
}

/// Plain text: the simplest endpoint.
pub fn health(c: *spider.Ctx) !spider.Response {
    return c.text("ok", .{});
}

/// The same data as the pages, as JSON.
pub fn apiBooks(c: *spider.Ctx) !spider.Response {
    return c.json(model.all(), .{});
}

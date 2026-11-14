//! The shelf: a plain struct and a fixed list. A real app would read these
//! from a database (spider.pg / spider.sqlite); nothing here is Spider's.

pub const Book = struct {
    id: u32,
    title: []const u8,
    author: []const u8,
    year: u32,
    finished: bool,
};

const shelf = [_]Book{
    .{ .id = 1, .title = "The Left Hand of Darkness", .author = "Ursula K. Le Guin", .year = 1969, .finished = true },
    .{ .id = 2, .title = "Piranesi", .author = "Susanna Clarke", .year = 2020, .finished = true },
    .{ .id = 3, .title = "The Peregrine", .author = "J. A. Baker", .year = 1967, .finished = false },
    .{ .id = 4, .title = "Station Eleven", .author = "Emily St. John Mandel", .year = 2014, .finished = false },
};

/// Every book on the shelf.
pub fn all() []const Book {
    return &shelf;
}

/// The book with this id, or null.
pub fn find(id: u32) ?Book {
    for (shelf) |book| {
        if (book.id == id) return book;
    }
    return null;
}

test "find: a known id and an unknown one" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Piranesi", find(2).?.title);
    try std.testing.expect(find(99) == null);
    try std.testing.expectEqual(@as(usize, 4), all().len);
}

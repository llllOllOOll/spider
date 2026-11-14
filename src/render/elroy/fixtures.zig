//! Internal: the templates the Elroy parity test compiles at build time
//! (src/elroy_fixture_gen.zig) and renders both ways with the data in
//! elroy_parity_test.zig. `compiles = false`: Elroy must leave the
//! template to the interpreter.

pub const Case = struct { name: []const u8, src: []const u8, compiles: bool = true };

pub const cases = [_]Case{
    .{ .name = "text_only", .src = "<p>Hello, \"world\" \\ {{ not a tag }}</p>\n" },
    .{ .name = "scalars", .src = "<p>{ title } { year } { price } { ratio } { done } { off } { big }</p>" },
    .{ .name = "escape", .src = "<p title=\"{ quote }\">{ html_text }</p>" },
    .{ .name = "raw_html", .src = "<div>{ raw }{ raw_opt }{ raw_null }</div>" },
    .{ .name = "optionals", .src = "<p>[{ note }][{ none }][{ opt_n }][{ opt_b }][{ opt_null_n }]</p>" },
    .{ .name = "missing_and_unsupported", .src = "<p>[{ nope }][{ kind }][{ ids }][{ book.nope }][{ book.title.x }]</p>" },
    .{ .name = "nested", .src = "<p>{ book.title } by { book.author.name } ({ book.author.born })</p>" },
    .{ .name = "pointer_struct", .src = "<p>{ ptr.title } { ptr.year }</p>" },
    .{ .name = "default", .src = "<p>{ title ?? \"x\" }|{ empty ?? \"d1\" }|{ nope ?? \"d2\" }|{ off ?? \"d3\" }|{ done ?? \"d4\" }|{ none ?? \"d5\" }|{ year ?? \"d6\" }|{ book ?? \"d7\" }|{ fstr ?? \"d8\" }</p>" },
    .{ .name = "len", .src = "<p>{ books.len } { title.len } { empty.len } { raw.len } { nope.len } { book.len } { with_len.len }</p>" },
    .{ .name = "index", .src = "<p>{ books[0].title }|{ books[1].year }|{ books[9].title }|{ names[1] }|{ names[5] }</p>" },
    .{ .name = "loop_structs", .src = "<ul>\nfor (books) |b| {\n<li>{ b.title } ({ b.year })</li>\n}\n</ul>" },
    .{ .name = "loop_strings", .src = "for (names) |n| { <i>{ n }</i> }" },
    .{ .name = "loop_index", .src = "for (names) |n| { { loop.index }:{ n }; }" },
    .{ .name = "loop_nested", .src = "for (shelves) |s| { <h2>{ s.name }</h2>for (s.books) |b| { <p>{ loop.index } { b.title } { s.name }</p> } }" },
    .{ .name = "loop_unused_capture", .src = "for (books) |b| { <hr> }" },
    .{ .name = "loop_over_missing", .src = "for (nope) |x| { <p>{ x }</p> }for (title) |c| { <p>{ c }</p> }" },
    .{ .name = "loop_shadow", .src = "for (books) |title| { { title.title } }{ title }" },
    .{ .name = "loop_array", .src = "for (arr) |b| { { b.title }; }" },
    .{ .name = "loop_raw", .src = "for (raws) |r| { [{ r }] }" },
    .{ .name = "if_truth", .src = "if (done) { A }if (off) { B } else { C }if (title) { D }if (empty) { E }if (book) { F }if (books) { G }if (nope) { H }if (false_text) { I }if (year) { J }if (zero) { K }if (note) { L }if (none) { M }" },
    .{ .name = "if_compare", .src = "if (title == \"Piranesi\") { A }if (year == 2020) { B }if (year != 2021) { C }if (done == true) { D }if (off == \"false\") { E }if (books.len == 2) { F }if (nope == \"\") { G }" },
    .{ .name = "if_numeric", .src = "if (year > 2000) { A }if (year < 2000) { B }if (year >= 2020) { C }if (year <= 2019) { D }if (books.len > 1) { E }if (title > 1) { F }if (price > 1) { G }" },
    .{ .name = "if_null", .src = "if (note == null) { A }if (none == null) { B }if (nope == null) { C }if (title != null) { D }if (raw_null == null) { E }" },
    .{ .name = "if_logic", .src = "if (done and title) { A }if (off or done) { B }if (!off) { C }if (!done and title) { D }if (off or nope or empty) { E } else { F }if (year > 2000 and books.len == 2) { G }" },
    .{ .name = "if_quirks", .src = "if (title == \"a or b\") { A }if ( title ) { B }if (!title) { C } else { D }" },
    .{ .name = "if_loop", .src = "for (books) |b| { if (b.year > 2015) { new:{ b.title } } else { old:{ b.title } }if (loop.index == 0) { first } }" },
    .{ .name = "props_header_page", .src = "-- props: title\n<h1>{ title }</h1>" },
    .{ .name = "unicode", .src = "<p>{ uni } — ✓ ação</p>" },
    // Left to the interpreter (for now).
    .{ .name = "has_layout", .src = "extends \"layout\"\n<p>{ title }</p>", .compiles = false },
    .{ .name = "has_component", .src = "<Card title=\"{ title }\" />", .compiles = false },
    .{ .name = "has_slot", .src = "<main>{ slot }</main>", .compiles = false },
    .{ .name = "has_current_user", .src = "if (current_user) { hi }", .compiles = false },
    .{ .name = "has_call_in_condition", .src = "if (len(books) > 1) { x }", .compiles = false },
    .{ .name = "has_expression", .src = "<p>{ \"lit\" }</p>", .compiles = false },
};

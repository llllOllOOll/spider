//! Building the headers of a file download.
//!
//! `Ctx.download` uses this; it is separate so the rules about file
//! names can be read and tested on their own.
//!
//! A file name usually comes from user data (the title of a report, the
//! name of an uploaded file), and it ends up inside a response header.
//! Whatever it holds, the header this module builds is one line of
//! printable ASCII:
//! - only the last part of a path is kept (`../../etc/passwd` is
//!   `passwd`), without leading dots;
//! - control characters, line breaks, double quotes and the characters
//!   that hide a file's real extension (right-to-left overrides) are
//!   removed; `< > : | ? *` become `_`;
//! - the name is cut to `max_filename_len` bytes, keeping its extension;
//! - a name with nothing left is `download`.
//!
//! The header carries the name twice, as RFC 6266 recommends: an ASCII
//! version every client understands (`filename="..."`, accents dropped)
//! and, when the name is not plain ASCII, the real one percent-encoded
//! (`filename*=UTF-8''...`), which current browsers prefer.

const std = @import("std");

/// Content types for the files apps usually hand out.
pub const content_types = struct {
    pub const xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    pub const csv = "text/csv; charset=utf-8";
    pub const pdf = "application/pdf";
    /// For anything else: the browser saves it without trying to open it.
    pub const binary = "application/octet-stream";
};

pub const Disposition = enum {
    /// The browser saves the file.
    attachment,
    /// The browser shows the file when it can (a PDF, an image).
    @"inline",
};

/// Longest file name sent, in bytes.
pub const max_filename_len = 120;
/// The name used when nothing of the given one can be kept.
pub const default_filename = "download";
/// An extension longer than this is not treated as one when cutting.
const max_extension_len = 12;

/// True for a content type that is safe to send: one line of printable
/// ASCII with a type, a slash and a subtype.
pub fn isValidContentType(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x20 or c > 0x7e) return false;
    }
    const media = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, value, ';')) |semicolon| value[0..semicolon] else value, " ");
    const slash = std.mem.indexOfScalar(u8, media, '/') orelse return false;
    return slash > 0 and slash + 1 < media.len;
}

/// The value of a `Content-Disposition` header for `filename`, which
/// may be anything. The caller frees the result.
pub fn contentDisposition(allocator: std.mem.Allocator, filename: []const u8, disposition: Disposition) error{OutOfMemory}![]u8 {
    // 1. The name, cleaned: valid UTF-8, no path, nothing dangerous.
    const clean_buffer = try allocator.alloc(u8, @max(filename.len, default_filename.len));
    defer allocator.free(clean_buffer);
    var name = sanitize(clean_buffer, filename);
    if (name.len == 0) {
        @memcpy(clean_buffer[0..default_filename.len], default_filename);
        name = clean_buffer[0..default_filename.len];
    }

    // 2. The ASCII version: accents dropped, anything else as "_".
    const ascii_buffer = try allocator.alloc(u8, name.len * 2 + default_filename.len);
    defer allocator.free(ascii_buffer);
    const ascii = asciiFallback(ascii_buffer, name);

    // 3. The header.
    const needs_encoded = !std.mem.eql(u8, ascii, name);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 64 + ascii.len + (if (needs_encoded) name.len * 3 else 0));
    out.appendSliceAssumeCapacity(@tagName(disposition));
    out.appendSliceAssumeCapacity("; filename=\"");
    out.appendSliceAssumeCapacity(ascii);
    out.appendAssumeCapacity('"');
    if (needs_encoded) {
        out.appendSliceAssumeCapacity("; filename*=UTF-8''");
        for (name) |c| {
            if (isAttrChar(c)) {
                out.appendAssumeCapacity(c);
            } else {
                out.appendAssumeCapacity('%');
                out.appendAssumeCapacity("0123456789ABCDEF"[c >> 4]);
                out.appendAssumeCapacity("0123456789ABCDEF"[c & 0xf]);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Writes the usable part of `filename` into `buffer` (at least as long
/// as `filename`) and returns it; empty when nothing is usable.
fn sanitize(buffer: []u8, filename: []const u8) []u8 {
    if (!std.unicode.utf8ValidateSlice(filename)) return buffer[0..0];
    // Only the last part of a path, whichever way its slashes lean.
    const base = if (std.mem.lastIndexOfAny(u8, filename, "/\\")) |separator| filename[separator + 1 ..] else filename;

    var len: usize = 0;
    var it = (std.unicode.Utf8View.initUnchecked(base)).iterator();
    while (it.nextCodepointSlice()) |encoded| {
        const code_point = std.unicode.utf8Decode(encoded) catch unreachable;
        switch (code_point) {
            // Control characters, line and paragraph separators.
            0x00...0x1f, 0x7f...0x9f, 0x2028, 0x2029 => {},
            // Invisible direction marks: they can make "exe.pdf" read as "fdp.exe".
            0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069, 0xfeff => {},
            '"' => {},
            '<', '>', ':', '|', '?', '*' => {
                buffer[len] = '_';
                len += 1;
            },
            else => {
                @memcpy(buffer[len..][0..encoded.len], encoded);
                len += encoded.len;
            },
        }
    }
    // No dots or spaces at the edges: no hidden files, nothing Windows drops.
    const trimmed = std.mem.trim(u8, buffer[0..len], " .");
    if (trimmed.len == 0) return buffer[0..0];
    std.mem.copyForwards(u8, buffer[0..trimmed.len], trimmed);
    var name = buffer[0..trimmed.len];

    if (name.len > max_filename_len) {
        const extension = extensionOf(name);
        var stem_len = max_filename_len - extension.len;
        // Do not cut a character in half.
        while (stem_len > 0 and name[stem_len] & 0xc0 == 0x80) stem_len -= 1;
        std.mem.copyForwards(u8, name[stem_len..][0..extension.len], extension);
        name = name[0 .. stem_len + extension.len];
    }
    return name;
}

/// `.xlsx` for `report.xlsx`; empty when there is no short extension.
fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or name.len - dot > max_extension_len) return "";
    return name[dot..];
}

/// What Latin-1 letters with accents (U+00C0 to U+00FF) become.
const latin1_ascii = [64][]const u8{
    "A", "A", "A", "A", "A", "A", "AE", "C", "E", "E", "E", "E", "I", "I", "I",  "I",
    "D", "N", "O", "O", "O", "O", "O",  "_", "O", "U", "U", "U", "U", "Y", "Th", "ss",
    "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i",  "i",
    "d", "n", "o", "o", "o", "o", "o",  "_", "o", "u", "u", "u", "u", "y", "th", "y",
};

/// Writes an ASCII-only version of `name` into `buffer` (twice as long
/// as `name` plus the default name) and returns it.
fn asciiFallback(buffer: []u8, name: []const u8) []u8 {
    var len: usize = 0;
    var it = (std.unicode.Utf8View.initUnchecked(name)).iterator();
    while (it.nextCodepoint()) |code_point| {
        const replacement: []const u8 = switch (code_point) {
            0x20...0x7e => &.{@intCast(code_point)},
            0xc0...0xff => latin1_ascii[code_point - 0xc0],
            else => "_",
        };
        @memcpy(buffer[len..][0..replacement.len], replacement);
        len += replacement.len;
    }
    const ascii = buffer[0..len];
    // "_.pdf" tells nobody anything: keep the extension, name it "download".
    const extension = extensionOf(ascii);
    for (ascii[0 .. ascii.len - extension.len]) |c| {
        if (std.ascii.isAlphanumeric(c)) return ascii;
    }
    std.mem.copyBackwards(u8, buffer[default_filename.len..][0..extension.len], extension);
    @memcpy(buffer[0..default_filename.len], default_filename);
    return buffer[0 .. default_filename.len + extension.len];
}

/// The characters RFC 5987 lets through unencoded.
fn isAttrChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$&+-.^_`|~", c) != null;
}

const testing = std.testing;

fn expectDisposition(expected: []const u8, filename: []const u8) !void {
    const got = try contentDisposition(testing.allocator, filename, .attachment);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    // Whatever the name, the header value is one line of printable ASCII.
    for (got) |c| try testing.expect(c >= 0x20 and c < 0x7f);
}

test "a plain name is used as it is" {
    try expectDisposition("attachment; filename=\"relatorio.xlsx\"", "relatorio.xlsx");
    try expectDisposition("attachment; filename=\"Votos 2026 (final) - v2.csv\"", "Votos 2026 (final) - v2.csv");
}

test "accents and emoji: an ASCII name for old clients, the real one encoded" {
    try expectDisposition("attachment; filename=\"Relatorio de acao.xlsx\"; filename*=UTF-8''Relat%C3%B3rio%20de%20a%C3%A7%C3%A3o.xlsx", "Relatório de ação.xlsx");
    try expectDisposition("attachment; filename=\"votos _.csv\"; filename*=UTF-8''votos%20%F0%9F%8E%89.csv", "votos 🎉.csv");
    try expectDisposition("attachment; filename=\"download.pdf\"; filename*=UTF-8''%F0%9F%8E%89.pdf", "🎉.pdf");
    try expectDisposition("attachment; filename=\"Munchen Strasse AEIOU.txt\"; filename*=UTF-8''M%C3%BCnchen%20Stra%C3%9Fe%20%C3%80%C3%89%C3%8E%C3%95%C3%9C.txt", "München Straße ÀÉÎÕÜ.txt");
}

test "quotes, line breaks and control characters cannot reach the header" {
    try expectDisposition("attachment; filename=\"he said hi.txt\"", "he said \"hi\".txt");
    try expectDisposition("attachment; filename=\"aSet-Cookie_ x=1.txt\"", "a\r\nSet-Cookie: x=1.txt");
    try expectDisposition("attachment; filename=\"ab.txt\"", "a\x00\x01\x1f\x7fb.txt");
    try expectDisposition("attachment; filename=\"a_b_c_d_e_f.txt\"", "a<b>c|d?e*f.txt");
    // A right-to-left override would show "abcexe.pdf" as something else.
    try expectDisposition("attachment; filename=\"abcfdp.exe\"", "abc\u{202E}fdp.exe");
}

test "paths are reduced to their last part" {
    try expectDisposition("attachment; filename=\"passwd\"", "../../etc/passwd");
    try expectDisposition("attachment; filename=\"boot.ini\"", "..\\..\\boot.ini");
    try expectDisposition("attachment; filename=\"planilha.xlsx\"", "C:\\Users\\fulano\\planilha.xlsx");
    try expectDisposition("attachment; filename=\"htaccess\"", ".htaccess");
    try expectDisposition("attachment; filename=\"nome\"", " . nome . ");
}

test "nothing usable left: the default name" {
    for ([_][]const u8{ "", "..", ".", "/", "dir/", "\\", "   ", "\x00\x01", "\"\"", "\xff\xfe.txt", "...." }) |name| {
        try expectDisposition("attachment; filename=\"download\"", name);
    }
}

test "a long name is cut, keeping its extension" {
    const long: [300]u8 = @splat('a');
    const got = try contentDisposition(testing.allocator, &long ++ ".xlsx", .attachment);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "attachment; filename=\"aaaa"));
    try testing.expect(std.mem.endsWith(u8, got, "aaaa.xlsx\""));
    try testing.expectEqual("attachment; filename=\"\"".len + max_filename_len, got.len);

    // Cut between characters, never inside one.
    var accents: [400]u8 = undefined;
    for (0..200) |i| accents[i * 2 ..][0..2].* = "é".*;
    const encoded = try contentDisposition(testing.allocator, &accents ++ ".csv", .attachment);
    defer testing.allocator.free(encoded);
    try testing.expect(std.mem.endsWith(u8, encoded, "%C3%A9.csv"));
    try testing.expect(std.mem.indexOf(u8, encoded, "%C3.") == null);
    try testing.expect(encoded.len < 600);
}

test "inline shows the file in the browser instead of saving it" {
    const got = try contentDisposition(testing.allocator, "ata.pdf", .@"inline");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("inline; filename=\"ata.pdf\"", got);
}

test "content types: one line, printable, type/subtype" {
    for ([_][]const u8{ content_types.xlsx, content_types.csv, content_types.pdf, content_types.binary, "image/png", "text/plain; charset=utf-8" }) |good| {
        try testing.expect(isValidContentType(good));
    }
    for ([_][]const u8{ "", "plain", "text/html\r\nX-Injected: 1", "text/html\n", "a\x00/b", "text/h\xc3\xa9", "/", "text/" }) |bad| {
        try testing.expect(!isValidContentType(bad));
    }
}

test "running out of memory leaks nothing" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const got = try contentDisposition(gpa, "Relatório \"final\" 🎉.xlsx", .attachment);
            gpa.free(got);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

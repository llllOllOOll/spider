//! `multipart/form-data` parsing: the text fields and the uploaded files of
//! a form. Handlers call `c.parseMultipart()`; `parse` and `extractBoundary`
//! are for a body that did not come through a request.

const std = @import("std");

/// One uploaded file of a multipart body.
///
/// ```zig
/// const mp = try c.parseMultipart();
/// const files = mp.getFile("avatar") orelse return error.BadRequest;
/// const first = files[0];
/// ```
pub const UploadedFile = struct {
    /// The file name the client sent, as it sent it. It is not checked: never
    /// use it as a path.
    filename: []const u8,
    /// The `Content-Type` of the part, as the client sent it;
    /// `application/octet-stream` when the part had none.
    content_type: []const u8,
    /// The bytes of the file. Not copied: a slice of the body given to `parse`,
    /// valid as long as that body is.
    data: []const u8,
    /// Length of `data` in bytes.
    size: usize,
};

/// The parsed parts of a multipart body: what `c.parseMultipart()` and `parse`
/// return. Read it with `getValue` and `getFile`.
pub const MultipartData = struct {
    /// The text fields by name. When a name comes more than once, the last one stays.
    value: std.StringHashMap([]const u8),
    /// The uploaded files by field name; one field can carry several.
    file: std.StringHashMapUnmanaged(std.ArrayList(UploadedFile)),
    /// The allocator given to `parse`; `deinit` frees with it.
    allocator: std.mem.Allocator,

    /// The text field `name`, or null when the form has none.
    pub fn getValue(self: *const MultipartData, name: []const u8) ?[]const u8 {
        return self.value.get(name);
    }

    /// The files uploaded in the field `name`, in the order they came, or null
    /// when the field has no file part.
    pub fn getFile(self: *const MultipartData, name: []const u8) ?[]UploadedFile {
        const entry = self.file.get(name) orelse return null;
        return entry.items;
    }

    /// Frees the names, the field values and the file metadata. Not needed when
    /// the data came from `c.parseMultipart()`: the request arena frees it.
    pub fn deinit(self: *MultipartData) void {
        {
            var it = self.value.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.value.deinit();
        }
        {
            var it = self.file.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |*fh| {
                    self.allocator.free(fh.filename);
                    self.allocator.free(fh.content_type);
                }
                entry.value_ptr.deinit(self.allocator);
            }
            self.file.deinit(self.allocator);
        }
    }
};

fn extractFieldValue(input: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and (input[i] == ' ' or input[i] == ';' or input[i] == '\t')) {
            i += 1;
        }
        if (i + field.len > input.len) return null;
        if (std.mem.eql(u8, input[i..][0..field.len], field)) {
            i += field.len;
            if (i < input.len and input[i] == '=') {
                i += 1;
                if (i < input.len and input[i] == '"') {
                    i += 1;
                    const start = i;
                    while (i < input.len and input[i] != '"') {
                        if (input[i] == '\\' and i + 1 < input.len) i += 1;
                        i += 1;
                    }
                    return input[start..i];
                } else {
                    const start = i;
                    while (i < input.len and input[i] != ' ' and input[i] != ';' and input[i] != '\r' and input[i] != '\n') {
                        i += 1;
                    }
                    return input[start..i];
                }
            }
        }
        while (i < input.len and input[i] != ' ' and input[i] != ';') {
            i += 1;
        }
    }
    return null;
}

/// The boundary of a `Content-Type: multipart/form-data; boundary=...` header
/// value, without its quotes. Null when the type is not `multipart/form-data`
/// (in lower case), when there is no `boundary=`, when nothing or more than
/// 70 bytes follow it, or when an opening quote is never closed. A slice of
/// `content_type`.
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const mp_prefix = "multipart/form-data";
    const directive_start = std.mem.indexOf(u8, content_type, mp_prefix) orelse return null;
    const directive = content_type[directive_start + mp_prefix.len ..];
    const boundary_marker = "boundary=";
    const marker_pos = std.mem.indexOf(u8, directive, boundary_marker) orelse return null;
    const raw = directive[marker_pos + boundary_marker.len ..];
    if (raw.len == 0) return null;
    if (raw.len > 70) return null;
    if (raw[0] == '"') {
        if (raw.len < 2) return null;
        const end = std.mem.indexOfScalar(u8, raw[1..], '"') orelse return null;
        return raw[1 .. 1 + end];
    }
    var end: usize = 0;
    while (end < raw.len and raw[end] != ' ' and raw[end] != ';' and raw[end] != '\r' and raw[end] != '\n') {
        end += 1;
    }
    return raw[0..end];
}

/// Parses a multipart `body` whose parts are separated by `boundary` (as
/// `extractBoundary` gives it). Names and field values are copied with
/// `allocator`; file contents are not (see `UploadedFile.data`), so `body`
/// must outlive the result. Free with `deinit`.
///
/// Fails with `error.InvalidMultipartEncoding` when the body does not follow
/// the format, `error.MissingFieldName` for a part without a `name`, and
/// `error.BoundaryTooLong` for a boundary over 254 bytes.
///
/// ```zig
/// var mp = try spider.multipart.parse(allocator, body, boundary);
/// defer mp.deinit();
/// const info = mp.getValue("info");
/// ```
pub fn parse(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) !MultipartData {
    var value_map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = value_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        value_map.deinit();
    }

    var file_map: std.StringHashMapUnmanaged(std.ArrayList(UploadedFile)) = .empty;
    errdefer {
        var it = file_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |*fh| {
                allocator.free(fh.filename);
                allocator.free(fh.content_type);
            }
            entry.value_ptr.deinit(allocator);
        }
        file_map.deinit(allocator);
    }

    var delim_buf: [256]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return error.BoundaryTooLong;
    delim_buf[0] = '-';
    delim_buf[1] = '-';
    @memcpy(delim_buf[2 .. 2 + boundary.len], boundary);
    const delim = delim_buf[0 .. 2 + boundary.len];

    var parts = std.mem.splitSequence(u8, body, delim);

    const first = parts.next() orelse {
        return MultipartData{
            .value = value_map,
            .file = file_map,
            .allocator = allocator,
        };
    };
    if (first.len != 0) return error.InvalidMultipartEncoding;

    while (parts.next()) |part| {
        if (part.len >= 2 and part[0] == '-' and part[1] == '-') break;
        if (part.len < 2 or part[0] != '\r' or part[1] != '\n') return error.InvalidMultipartEncoding;
        const part_content = part[2..];

        var pos: usize = 0;
        var field_name: ?[]const u8 = null;
        var file_name: ?[]const u8 = null;
        var content_type: []const u8 = "application/octet-stream";

        while (pos < part_content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, part_content, pos, '\n') orelse break;
            const line = part_content[pos..line_end];
            pos = line_end + 1;
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
            const header_line = if (line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            if (std.ascii.startsWithIgnoreCase(header_line, "content-disposition:")) {
                const cd_value = std.mem.trimStart(u8, header_line["content-disposition:".len..], " \t");
                field_name = extractFieldValue(cd_value, "name");
                file_name = extractFieldValue(cd_value, "filename");
            } else if (std.ascii.startsWithIgnoreCase(header_line, "content-type:")) {
                content_type = std.mem.trim(u8, header_line["content-type:".len..], " \t");
            }
        }

        const data = part_content[pos..];
        const trimmed_data = if (data.len >= 2 and data[data.len - 2] == '\r' and data[data.len - 1] == '\n')
            data[0 .. data.len - 2]
        else
            data;

        const name = field_name orelse return error.MissingFieldName;
        if (file_name) |fn_| {
            const fh = UploadedFile{
                .filename = try allocator.dupe(u8, fn_),
                .content_type = try allocator.dupe(u8, content_type),
                .data = trimmed_data,
                .size = trimmed_data.len,
            };
            const gop = try file_map.getOrPut(allocator, name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, name);
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(allocator, fh);
        } else {
            const new_key = try allocator.dupe(u8, name);
            const new_val = try allocator.dupe(u8, trimmed_data);
            const gop = try value_map.getOrPut(new_key);
            if (gop.found_existing) {
                allocator.free(gop.key_ptr.*);
                allocator.free(gop.value_ptr.*);
            }
            gop.key_ptr.* = new_key;
            gop.value_ptr.* = new_val;
        }
    }

    return MultipartData{
        .value = value_map,
        .file = file_map,
        .allocator = allocator,
    };
}

test "parse: single text field" {
    const alloc = std.testing.allocator;
    const body = "---boundary\r\n" ++
        "Content-Disposition: form-data; name=\"description\"\r\n" ++
        "\r\n" ++
        "the-desc\r\n" ++
        "---boundary--\r\n";
    var mp = try parse(alloc, body, "-boundary");
    defer mp.deinit();

    try std.testing.expectEqualStrings("the-desc", mp.getValue("description").?);
    try std.testing.expectEqual(@as(?[]const u8, null), mp.getValue("nonexistent"));
    try std.testing.expect(mp.getFile("description") == null);
}

test "parse: single field with filename" {
    const alloc = std.testing.allocator;
    const body = "---90x\r\n" ++
        "Content-Disposition: form-data; filename=\"file1.zig\"; name=file\r\n" ++
        "\r\n" ++
        "some binary data\r\n" ++
        "---90x--\r\n";
    var mp = try parse(alloc, body, "-90x");
    defer mp.deinit();

    const files = mp.getFile("file") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("file1.zig", files[0].filename);
    try std.testing.expectEqualStrings("application/octet-stream", files[0].content_type);
    try std.testing.expectEqualStrings("some binary data", files[0].data);
}

test "parse: multiple fields" {
    const alloc = std.testing.allocator;
    const body = "------99900AB\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "Value - 1\r\n" ++
        "------99900AB\r\n" ++
        "Content-Disposition: form-data; filename=another.zip; name=field2\r\n" ++
        "\r\n" ++
        "Value - 2\r\n" ++
        "------99900AB--\r\n";
    var mp = try parse(alloc, body, "----99900AB");
    defer mp.deinit();

    try std.testing.expectEqualStrings("Value - 1", mp.getValue("field1").?);
    const files = mp.getFile("field2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("another.zip", files[0].filename);
    try std.testing.expectEqualStrings("Value - 2", files[0].data);
}

test "parse: multiple files same name" {
    const alloc = std.testing.allocator;
    const body = "--bound\r\n" ++
        "Content-Disposition: form-data; name=\"gallery\"; filename=\"img1.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "png data 1\r\n" ++
        "--bound\r\n" ++
        "Content-Disposition: form-data; name=\"gallery\"; filename=\"img2.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "png data 2\r\n" ++
        "--bound--\r\n";
    var mp = try parse(alloc, body, "bound");
    defer mp.deinit();

    const files = mp.getFile("gallery") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("img1.png", files[0].filename);
    try std.testing.expectEqualStrings("img2.png", files[1].filename);
    try std.testing.expectEqualStrings("png data 1", files[0].data);
    try std.testing.expectEqualStrings("png data 2", files[1].data);
}

test "parse: mix of text and file fields" {
    const alloc = std.testing.allocator;
    const body = "--mix\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Hello World\r\n" ++
        "--mix\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"pic.jpg\"\r\n" ++
        "Content-Type: image/jpeg\r\n" ++
        "\r\n" ++
        "\xff\xd8\xff\xe0\r\n" ++
        "--mix--\r\n";
    var mp = try parse(alloc, body, "mix");
    defer mp.deinit();

    try std.testing.expectEqualStrings("Hello World", mp.getValue("title").?);
    const files = mp.getFile("avatar") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("pic.jpg", files[0].filename);
    try std.testing.expectEqualStrings("image/jpeg", files[0].content_type);
    try std.testing.expectEqualStrings("\xff\xd8\xff\xe0", files[0].data);
}

test "parse: empty body" {
    const alloc = std.testing.allocator;
    var mp = try parse(alloc, "", "boundary");
    defer mp.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), mp.getValue("anything"));
    try std.testing.expect(mp.getFile("anything") == null);
}

test "parse: empty value returns empty MultiformData" {
    const alloc = std.testing.allocator;
    var mp = try parse(alloc, "", "blah");
    defer mp.deinit();
    try std.testing.expectEqual(@as(usize, 0), mp.value.count());
}

test "parse: quoted boundary" {
    const alloc = std.testing.allocator;
    const boundary = "-90x";
    const body = "---90x\r\n" ++
        "Content-Disposition: form-data; name=\"description\"\r\n" ++
        "\r\n" ++
        "the-desc\r\n" ++
        "---90x--\r\n";
    var mp = try parse(alloc, body, boundary);
    defer mp.deinit();

    const field = mp.getValue("description") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("the-desc", field);
}

test "parse: quoted name in Content-Disposition" {
    const alloc = std.testing.allocator;
    const body = "---90x\r\n" ++
        "Content-Disposition: form-data; name=\"field name\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "---90x--\r\n";
    var mp = try parse(alloc, body, "-90x");
    defer mp.deinit();

    try std.testing.expectEqualStrings("value", mp.getValue("field name").?);
}

test "parse: unquoted name" {
    const alloc = std.testing.allocator;
    const body = "--bound\r\n" ++
        "Content-Disposition: form-data; name=unquoted\r\n" ++
        "\r\n" ++
        "val\r\n" ++
        "--bound--\r\n";
    var mp = try parse(alloc, body, "bound");
    defer mp.deinit();
    try std.testing.expectEqualStrings("val", mp.getValue("unquoted").?);
}

test "parse: multiple text values same key" {
    const alloc = std.testing.allocator;
    const body = "--b\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n" ++
        "\r\n" ++
        "zig\r\n" ++
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"tags\"\r\n" ++
        "\r\n" ++
        "rust\r\n" ++
        "--b--\r\n";
    var mp = try parse(alloc, body, "b");
    defer mp.deinit();

    const v = mp.getValue("tags") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("rust", v);
}

test "parse: no Content-Disposition header" {
    const alloc = std.testing.allocator;
    const body = "--b\r\n" ++
        "\r\n" ++
        "data\r\n" ++
        "--b--\r\n";
    const result = parse(alloc, body, "b");
    try std.testing.expectError(error.MissingFieldName, result);
}

test "extractBoundary: simple" {
    const ct = "multipart/form-data; boundary=----WebKitFormBoundaryxyz";
    const b = extractBoundary(ct) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("----WebKitFormBoundaryxyz", b);
}

test "extractBoundary: quoted" {
    const ct = "multipart/form-data; boundary=\"-90x\"";
    const b = extractBoundary(ct) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("-90x", b);
}

test "extractBoundary: no boundary" {
    const ct = "multipart/form-data";
    try std.testing.expectEqual(@as(?[]const u8, null), extractBoundary(ct));
}

test "extractBoundary: not multipart" {
    const ct = "application/x-www-form-urlencoded";
    try std.testing.expectEqual(@as(?[]const u8, null), extractBoundary(ct));
}

test "extractBoundary: with extra params" {
    const ct = "multipart/form-data; charset=utf-8; boundary=abc123";
    const b = extractBoundary(ct) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("abc123", b);
}

test "extractFieldValue: quoted" {
    const input = "form-data; name=\"field1\"";
    const v = extractFieldValue(input, "name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("field1", v);
}

test "extractFieldValue: unquoted" {
    const input = "form-data; name=field1";
    const v = extractFieldValue(input, "name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("field1", v);
}

test "extractFieldValue: with filename" {
    const input = "form-data; name=\"file\"; filename=\"test.txt\"";
    const n = extractFieldValue(input, "name") orelse return error.TestFailed;
    const f = extractFieldValue(input, "filename") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("file", n);
    try std.testing.expectEqualStrings("test.txt", f);
}

test "extractFieldValue: filename before name" {
    const input = "form-data; filename=\"f.txt\"; name=\"field\"";
    const n = extractFieldValue(input, "name") orelse return error.TestFailed;
    const f = extractFieldValue(input, "filename") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("field", n);
    try std.testing.expectEqualStrings("f.txt", f);
}

test "extractFieldValue: not found" {
    const input = "form-data; name=\"field1\"";
    try std.testing.expectEqual(@as(?[]const u8, null), extractFieldValue(input, "filename"));
}

test "parse deinit without leak" {
    const alloc = std.testing.allocator;
    const body = "--b\r\n" ++
        "Content-Disposition: form-data; name=\"title\"\r\n" ++
        "\r\n" ++
        "Hello\r\n" ++
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"img.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "data\r\n" ++
        "--b--\r\n";
    var mp = try parse(alloc, body, "b");
    mp.deinit();
}

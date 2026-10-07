//! A streaming XML reader, just enough for the parts of a workbook.
//!
//! It is a pull parser: `Parser.next` returns one event at a time
//! (an element starting, an element ending, a piece of text) and reads
//! from its source only as needed, so a part of any size is parsed in a
//! small, bounded buffer. Text is handed over in pieces; a start tag
//! must fit the buffer, which is capped by `Limits.max_tag_len`.
//!
//! What it does on purpose:
//! - element names lose their namespace prefix (`x:row` is `row`:
//!   some programs write the main namespace with a prefix);
//! - the five predefined entities and numeric character references are
//!   decoded; any other entity is an error — nothing is ever expanded;
//! - a `<!DOCTYPE` is always an error, so there is no way to declare an
//!   entity or point at an external one;
//! - text and attribute values must be valid UTF-8 and may not hold
//!   the control characters XML forbids;
//! - nesting depth, attributes per element, name length, attribute
//!   value length and tag length are limited.
//!
//! It does not check namespaces, and it accepts a few documents a
//! validating parser would not (a stray `]]>` in text, for instance).

const std = @import("std");

pub const Error = error{
    /// Not well-formed XML, an encoding other than UTF-8, a document
    /// type declaration or an undefined entity.
    InvalidXml,
    /// One of `Limits` was exceeded.
    LimitExceeded,
    OutOfMemory,
    /// The source failed; it knows why.
    ReadFailed,
};

/// Where the bytes come from. `readFn` fills `dest` (never empty) and
/// returns how many bytes it wrote; 0 is the end.
pub const Source = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, dest: []u8) Source.Error!usize,

    pub const Error = error{ReadFailed};
};

pub const Limits = struct {
    /// Elements open at the same time.
    max_depth: u16 = 64,
    /// Attributes on one element.
    max_attributes: u16 = 64,
    /// Bytes in an element or attribute name.
    max_name_len: u32 = 256,
    /// Bytes in an attribute value, once decoded.
    max_value_len: u32 = 64 * 1024,
    /// Bytes in one start tag, a comment or a processing instruction.
    max_tag_len: u32 = 256 * 1024,
};

pub const Attribute = struct {
    /// As written, prefix included (`r:id`, `xml:space`).
    name: []const u8,
    /// Decoded.
    value: []const u8,
};

/// Slices in an event, and those returned by the attribute functions,
/// are valid until the next call to `next` or `skip`.
pub const Event = union(enum) {
    /// An element starts; its name without prefix. A self-closing
    /// element gives a `start` and then an `end`.
    start: []const u8,
    end: []const u8,
    /// A piece of character data, decoded. Long text comes in several
    /// pieces; whitespace between elements is reported too.
    text: []const u8,
    eof,
};

const initial_buffer_len = 16 * 1024;
/// Text is handed over once this much is buffered, or sooner when a
/// tag begins.
const text_piece_len = 8 * 1024;

pub const Parser = struct {
    gpa: std.mem.Allocator,
    source: Source,
    limits: Limits,
    /// Unread input is `buffer[start..end]`.
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,
    /// Bytes of input that came before `buffer[0]`.
    dropped: u64 = 0,
    source_done: bool = false,
    /// Resumable scan position for the end of the current markup.
    scan: usize = 0,
    scan_quote: u8 = 0,
    /// Full names of the open elements, back to back, and where each ends.
    names: std.ArrayList(u8) = .empty,
    name_ends: std.ArrayList(u32) = .empty,
    attribute_list: std.ArrayList(Attribute) = .empty,
    attribute_data: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// The name of the element that just ended, kept for its event.
    closed_name: std.ArrayList(u8) = .empty,
    began: bool = false,
    seen_root: bool = false,
    pending_end: bool = false,
    in_cdata: bool = false,
    last_was_cr: bool = false,

    pub fn init(gpa: std.mem.Allocator, source: Source, limits: Limits) Error!Parser {
        return .{
            .gpa = gpa,
            .source = source,
            .limits = limits,
            .buffer = try gpa.alloc(u8, initial_buffer_len),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.gpa.free(self.buffer);
        self.names.deinit(self.gpa);
        self.name_ends.deinit(self.gpa);
        self.attribute_list.deinit(self.gpa);
        self.attribute_data.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.closed_name.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many bytes of the document were consumed so far: where a
    /// problem was found, give or take the current token.
    pub fn offset(self: *const Parser) u64 {
        return self.dropped + self.start;
    }

    /// Number of elements currently open.
    pub fn depth(self: *const Parser) usize {
        return self.name_ends.items.len;
    }

    /// The attributes of the element that just started.
    pub fn attributes(self: *const Parser) []const Attribute {
        return self.attribute_list.items;
    }

    /// The value of the attribute with exactly this name.
    pub fn attribute(self: *const Parser, name: []const u8) ?[]const u8 {
        for (self.attribute_list.items) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    /// The value of the attribute with this name once its prefix is
    /// dropped (`id` finds `r:id`, whatever the prefix is called).
    /// Namespace declarations are not attributes for this purpose.
    pub fn attributeLocal(self: *const Parser, local_name: []const u8) ?[]const u8 {
        for (self.attribute_list.items) |a| {
            if (std.mem.startsWith(u8, a.name, "xmlns")) continue;
            if (std.mem.eql(u8, localName(a.name), local_name)) return a.value;
        }
        return null;
    }

    /// Call right after a `start` event: consumes everything up to and
    /// including the matching `end`.
    pub fn skip(self: *Parser) Error!void {
        const target = self.depth() - 1;
        while (true) {
            switch (try self.next()) {
                .end => if (self.depth() == target) return,
                .eof => return error.InvalidXml,
                else => {},
            }
        }
    }

    pub fn next(self: *Parser) Error!Event {
        if (self.pending_end) {
            self.pending_end = false;
            return try self.closeElement();
        }
        while (true) {
            if (self.in_cdata) {
                if (try self.cdataPiece()) |piece| return .{ .text = piece };
                continue;
            }
            if (self.start == self.end and !try self.fill()) {
                if (self.depth() != 0 or !self.seen_root) return error.InvalidXml;
                return .eof;
            }
            if (!self.began) {
                // A byte order mark may come first.
                while (self.end - self.start < 3 and try self.fill()) {}
                if (std.mem.startsWith(u8, self.buffer[self.start..self.end], "\xef\xbb\xbf")) self.start += 3;
                self.began = true;
                continue;
            }
            if (self.buffer[self.start] == '<') {
                if (try self.markup()) |event| return event;
            } else {
                if (try self.textPiece()) |piece| return .{ .text = piece };
            }
        }
    }

    /// Reads more input after the unread bytes, making room first.
    /// Returns false at the end of the source.
    fn fill(self: *Parser) Error!bool {
        if (self.source_done) return false;
        if (self.start > 0) {
            const unread = self.end - self.start;
            std.mem.copyForwards(u8, self.buffer[0..unread], self.buffer[self.start..self.end]);
            self.dropped += self.start;
            self.scan -|= self.start;
            self.start = 0;
            self.end = unread;
        }
        if (self.end == self.buffer.len) {
            // One token fills the buffer: grow, up to the tag limit.
            const cap = @max(@as(usize, self.limits.max_tag_len), initial_buffer_len);
            if (self.buffer.len >= cap) return error.LimitExceeded;
            self.buffer = try self.gpa.realloc(self.buffer, @min(self.buffer.len * 2, cap));
        }
        const n = try self.source.readFn(self.source.ptr, self.buffer[self.end..]);
        if (n == 0) {
            self.source_done = true;
            return false;
        }
        self.end += n;
        return true;
    }

    /// Makes at least `n` unread bytes available, or fails at the end.
    fn need(self: *Parser, n: usize) Error!void {
        while (self.end - self.start < n) {
            if (!try self.fill()) return error.InvalidXml;
        }
    }

    /// Finds `pattern` at or after `from` (relative to `start`), reading
    /// more input as needed, and returns its position relative to
    /// `start`. The search resumes where it stopped.
    fn find(self: *Parser, pattern: []const u8, from: usize) Error!usize {
        self.scan = self.start + from;
        while (true) {
            if (std.mem.indexOfPos(u8, self.buffer[0..self.end], self.scan, pattern)) |at| return at - self.start;
            self.scan = @max(self.scan, self.end -| (pattern.len - 1));
            if (!try self.fill()) return error.InvalidXml;
        }
    }

    /// Handles what starts with `<`. Null for what produces no event.
    fn markup(self: *Parser) Error!?Event {
        try self.need(2);
        switch (self.buffer[self.start + 1]) {
            '?' => {
                const close = try self.find("?>", 2);
                const body = self.buffer[self.start + 2 .. self.start + close];
                if (std.mem.startsWith(u8, body, "xml") and (body.len == 3 or isSpace(body[3]))) try checkEncoding(body);
                self.start += close + 2;
                return null;
            },
            '!' => {
                try self.need(4);
                if (std.mem.eql(u8, self.buffer[self.start..][0..4], "<!--")) {
                    const close = try self.find("-->", 4);
                    self.start += close + 3;
                    return null;
                }
                try self.need(9);
                if (std.mem.eql(u8, self.buffer[self.start..][0..9], "<![CDATA[") and self.depth() > 0) {
                    self.start += 9;
                    self.in_cdata = true;
                    return null;
                }
                // <!DOCTYPE, <!ENTITY and anything else: never accepted.
                return error.InvalidXml;
            },
            '/' => {
                const close = try self.find(">", 2);
                const name = std.mem.trimEnd(u8, self.buffer[self.start + 2 .. self.start + close], " \t\r\n");
                if (self.depth() == 0 or !std.mem.eql(u8, name, self.topName())) return error.InvalidXml;
                self.start += close + 1;
                return try self.closeElement();
            },
            else => return try self.startTag(),
        }
    }

    fn startTag(self: *Parser) Error!Event {
        // The end of the tag is the first `>` outside quotes.
        self.scan = self.start + 1;
        self.scan_quote = 0;
        const close = find_close: while (true) {
            while (self.scan < self.end) : (self.scan += 1) {
                const c = self.buffer[self.scan];
                if (self.scan_quote != 0) {
                    if (c == self.scan_quote) self.scan_quote = 0;
                } else if (c == '"' or c == '\'') {
                    self.scan_quote = c;
                } else if (c == '>') break :find_close self.scan;
            }
            if (!try self.fill()) return error.InvalidXml;
        };

        var tag = self.buffer[self.start + 1 .. close];
        const self_closing = tag.len > 0 and tag[tag.len - 1] == '/';
        if (self_closing) tag = tag[0 .. tag.len - 1];

        const name_len = nameLength(tag);
        if (name_len == 0) return error.InvalidXml;
        if (name_len > self.limits.max_name_len) return error.LimitExceeded;
        const name = tag[0..name_len];

        if (self.depth() == 0 and self.seen_root) return error.InvalidXml;
        if (self.depth() >= self.limits.max_depth) return error.LimitExceeded;

        try self.parseAttributes(tag[name_len..]);

        self.seen_root = true;
        try self.names.appendSlice(self.gpa, name);
        try self.name_ends.append(self.gpa, @intCast(self.names.items.len));
        self.start = close + 1;
        self.pending_end = self_closing;
        return .{ .start = localName(self.topName()) };
    }

    fn parseAttributes(self: *Parser, text_after_name: []const u8) Error!void {
        self.attribute_list.clearRetainingCapacity();
        self.attribute_data.clearRetainingCapacity();
        // A decoded value is never longer than its source, so the
        // slices taken below stay valid.
        try self.attribute_data.ensureTotalCapacity(self.gpa, text_after_name.len);

        var rest = text_after_name;
        while (true) {
            const trimmed = std.mem.trimStart(u8, rest, " \t\r\n");
            if (trimmed.len == 0) return;
            if (trimmed.len == rest.len) return error.InvalidXml; // no space before the attribute
            rest = trimmed;

            const name_len = nameLength(rest);
            if (name_len == 0) return error.InvalidXml;
            if (name_len > self.limits.max_name_len) return error.LimitExceeded;
            const name = rest[0..name_len];
            rest = std.mem.trimStart(u8, rest[name_len..], " \t\r\n");
            if (rest.len == 0 or rest[0] != '=') return error.InvalidXml;
            rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
            if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return error.InvalidXml;
            const quote = rest[0];
            const value_len = std.mem.indexOfScalar(u8, rest[1..], quote) orelse return error.InvalidXml;
            const raw = rest[1..][0..value_len];
            rest = rest[value_len + 2 ..];

            if (self.attribute_list.items.len >= self.limits.max_attributes) return error.LimitExceeded;
            for (self.attribute_list.items) |earlier| {
                if (std.mem.eql(u8, earlier.name, name)) return error.InvalidXml;
            }
            const value_start = self.attribute_data.items.len;
            var i: usize = 0;
            while (i < raw.len) {
                const c = raw[i];
                switch (c) {
                    '<' => return error.InvalidXml,
                    '&' => i += try decodeReference(raw[i..], &self.attribute_data),
                    // Literal whitespace in an attribute value is a space.
                    '\t', '\n', '\r' => {
                        self.attribute_data.appendAssumeCapacity(' ');
                        i += 1;
                    },
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => return error.InvalidXml,
                    else => {
                        self.attribute_data.appendAssumeCapacity(c);
                        i += 1;
                    },
                }
            }
            const value = self.attribute_data.items[value_start..];
            if (value.len > self.limits.max_value_len) return error.LimitExceeded;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidXml;
            try self.attribute_list.append(self.gpa, .{ .name = name, .value = value });
        }
    }

    fn topName(self: *const Parser) []const u8 {
        const ends = self.name_ends.items;
        const from: usize = if (ends.len > 1) ends[ends.len - 2] else 0;
        return self.names.items[from..ends[ends.len - 1]];
    }

    /// Pops the innermost element and returns its `end` event.
    fn closeElement(self: *Parser) Error!Event {
        const name = self.topName();
        self.closed_name.clearRetainingCapacity();
        try self.closed_name.appendSlice(self.gpa, localName(name));
        _ = self.name_ends.pop();
        self.names.shrinkRetainingCapacity(self.names.items.len - name.len);
        self.attribute_list.clearRetainingCapacity();
        return .{ .end = self.closed_name.items };
    }

    /// Decodes character data up to the next `<`, or as much as is
    /// buffered. Null when there is nothing to report.
    fn textPiece(self: *Parser) Error!?[]const u8 {
        var piece_end: usize = undefined;
        var complete: bool = undefined;
        while (true) {
            const unread = self.buffer[self.start..self.end];
            if (std.mem.indexOfScalar(u8, unread, '<')) |at| {
                piece_end = at;
                complete = true;
                break;
            }
            if (unread.len < text_piece_len and try self.fill()) continue;
            piece_end = unread.len;
            complete = self.source_done;
            break;
        }
        if (!complete) {
            // Do not cut a reference or a UTF-8 sequence in half.
            const unread = self.buffer[self.start..][0..piece_end];
            if (std.mem.lastIndexOfScalar(u8, unread, '&')) |amp| {
                if (std.mem.indexOfScalarPos(u8, unread, amp, ';') == null) {
                    if (unread.len - amp > max_reference_len) return error.InvalidXml;
                    piece_end = amp;
                }
            }
            piece_end -= incompleteUtf8Tail(self.buffer[self.start..][0..piece_end]);
            if (piece_end == 0) {
                if (!try self.fill()) return error.InvalidXml;
                return null;
            }
        }

        const raw = self.buffer[self.start..][0..piece_end];
        self.text.clearRetainingCapacity();
        try self.text.ensureTotalCapacity(self.gpa, raw.len);
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            switch (c) {
                '&' => {
                    i += try decodeReference(raw[i..], &self.text);
                    self.last_was_cr = false;
                    continue;
                },
                // Line ends are reported as a single line feed.
                '\r' => self.text.appendAssumeCapacity('\n'),
                '\n' => if (!self.last_was_cr) self.text.appendAssumeCapacity('\n'),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => return error.InvalidXml,
                else => self.text.appendAssumeCapacity(c),
            }
            self.last_was_cr = c == '\r';
            i += 1;
        }
        self.start += piece_end;
        const decoded = self.text.items;
        if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidXml;
        if (self.depth() == 0) {
            // Only whitespace may surround the root element.
            if (std.mem.trim(u8, decoded, " \t\r\n").len != 0) return error.InvalidXml;
            return null;
        }
        return if (decoded.len == 0) null else decoded;
    }

    /// The next piece of a CDATA section: its content is taken as it is.
    fn cdataPiece(self: *Parser) Error!?[]const u8 {
        var piece_end: usize = undefined;
        var closes: bool = undefined;
        while (true) {
            const unread = self.buffer[self.start..self.end];
            if (std.mem.indexOf(u8, unread, "]]>")) |at| {
                piece_end = at;
                closes = true;
                break;
            }
            if (unread.len < text_piece_len) {
                if (try self.fill()) continue;
                return error.InvalidXml; // the section never closes
            }
            // Keep back what could be the start of "]]>".
            piece_end = unread.len - 2;
            piece_end -= incompleteUtf8Tail(unread[0..piece_end]);
            closes = false;
            break;
        }
        const raw = self.buffer[self.start..][0..piece_end];
        for (raw) |c| switch (c) {
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => return error.InvalidXml,
            else => {},
        };
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidXml;
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, raw);
        self.start += piece_end;
        if (closes) {
            self.start += 3;
            self.in_cdata = false;
        }
        return if (self.text.items.len == 0) null else self.text.items;
    }
};

/// Longest reference accepted, `&` and `;` included (`&#x10FFFF;`).
const max_reference_len = 12;

/// Decodes the reference at the start of `text` (which begins with
/// `&`) into `out`, which has room for it, and returns how many bytes
/// of `text` it took.
fn decodeReference(text: []const u8, out: *std.ArrayList(u8)) Error!usize {
    const semicolon = std.mem.indexOfScalar(u8, text[0..@min(text.len, max_reference_len)], ';') orelse return error.InvalidXml;
    const name = text[1..semicolon];
    const code_point: u21 = if (std.mem.eql(u8, name, "amp"))
        '&'
    else if (std.mem.eql(u8, name, "lt"))
        '<'
    else if (std.mem.eql(u8, name, "gt"))
        '>'
    else if (std.mem.eql(u8, name, "quot"))
        '"'
    else if (std.mem.eql(u8, name, "apos"))
        '\''
    else if (name.len >= 2 and name[0] == '#') number: {
        const hex = name[1] == 'x';
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0) return error.InvalidXml;
        for (digits) |d| {
            if (!(if (hex) std.ascii.isHex(d) else std.ascii.isDigit(d))) return error.InvalidXml;
        }
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return error.InvalidXml;
        // What XML 1.0 allows as a character.
        const allowed = value == 0x9 or value == 0xA or value == 0xD or
            (value >= 0x20 and value <= 0xD7FF) or (value >= 0xE000 and value <= 0xFFFD) or
            (value >= 0x10000 and value <= 0x10FFFF);
        if (!allowed) return error.InvalidXml;
        break :number @intCast(value);
    } else return error.InvalidXml; // an entity nobody may define here

    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code_point, &encoded) catch return error.InvalidXml;
    // `&#9;` is the shortest reference (4 bytes) and needs 1; `&amp;`
    // needs 1 for 5; a 4-byte character needs at least `&#x10000;`.
    out.appendSliceAssumeCapacity(encoded[0..len]);
    return semicolon + 1;
}

/// How many bytes at the end of `text` start a UTF-8 sequence that
/// `text` does not finish.
fn incompleteUtf8Tail(text: []const u8) usize {
    var back: usize = 1;
    while (back <= @min(text.len, 4)) : (back += 1) {
        const c = text[text.len - back];
        if (c & 0xc0 == 0x80) continue; // continuation byte: keep looking for the lead
        const needed: usize = if (c < 0x80) 1 else if (c & 0xe0 == 0xc0) 2 else if (c & 0xf0 == 0xe0) 3 else if (c & 0xf8 == 0xf0) 4 else 1;
        return if (needed > back) back else 0;
    }
    return 0;
}

/// Length of the XML name at the start of `text`; 0 if there is none.
fn nameLength(text: []const u8) usize {
    if (text.len == 0) return 0;
    const first = text[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_' or first == ':' or first >= 0x80)) return 0;
    for (text, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == ':' or c == '-' or c == '.' or c >= 0x80;
        if (!ok) return i;
    }
    return text.len;
}

fn localName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| name[colon + 1 ..] else name;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The XML declaration may only name UTF-8.
fn checkEncoding(declaration: []const u8) Error!void {
    const at = std.mem.indexOf(u8, declaration, "encoding") orelse return;
    const rest = std.mem.trimStart(u8, declaration[at + "encoding".len ..], " \t\r\n=");
    if (rest.len < 2 or (rest[0] != '"' and rest[0] != '\'')) return error.InvalidXml;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return error.InvalidXml;
    if (!std.ascii.eqlIgnoreCase(rest[1..close], "utf-8")) return error.InvalidXml;
}

const testing = std.testing;

/// Feeds a slice to the parser a few bytes at a time.
const SliceSource = struct {
    bytes: []const u8,
    chunk: usize,

    fn source(self: *SliceSource) Source {
        return .{ .ptr = self, .readFn = read };
    }

    fn read(ptr: *anyopaque, dest: []u8) Source.Error!usize {
        const self: *SliceSource = @ptrCast(@alignCast(ptr));
        const n = @min(@min(dest.len, self.chunk), self.bytes.len);
        @memcpy(dest[0..n], self.bytes[0..n]);
        self.bytes = self.bytes[n..];
        return n;
    }
};

/// Parses `xml` and writes one line per event: `<name a=v`, `>name`,
/// `"text`. Adjacent text events are joined, so the result does not
/// depend on how the input was cut.
fn trace(gpa: std.mem.Allocator, xml: []const u8, chunk: usize, limits: Limits) ![]u8 {
    var src: SliceSource = .{ .bytes = xml, .chunk = chunk };
    var parser = try Parser.init(gpa, src.source(), limits);
    defer parser.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var in_text = false;
    while (true) {
        const event = try parser.next();
        if (event != .text and in_text) {
            w.writeByte('\n') catch return error.OutOfMemory;
            in_text = false;
        }
        switch (event) {
            .start => |name| {
                w.print("<{s}", .{name}) catch return error.OutOfMemory;
                for (parser.attributes()) |attribute| w.print(" {s}={s}", .{ attribute.name, attribute.value }) catch return error.OutOfMemory;
                w.writeByte('\n') catch return error.OutOfMemory;
            },
            .end => |name| w.print(">{s}\n", .{name}) catch return error.OutOfMemory,
            .text => |text| {
                if (!in_text) w.writeByte('"') catch return error.OutOfMemory;
                in_text = true;
                w.writeAll(text) catch return error.OutOfMemory;
            },
            .eof => break,
        }
    }
    return out.toOwnedSlice();
}

fn expectTrace(expected: []const u8, xml: []const u8) !void {
    // The same events whatever the size of the pieces the input comes in.
    for ([_]usize{ 1, 2, 3, 5, 17, 4096 }) |chunk| {
        const got = try trace(testing.allocator, xml, chunk, .{});
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }
}

fn expectFailure(expected: Error, xml: []const u8, limits: Limits) !void {
    for ([_]usize{ 1, 4096 }) |chunk| {
        try testing.expectError(expected, trace(testing.allocator, xml, chunk, limits));
    }
}

test "elements, attributes, text and self-closing tags" {
    try expectTrace(
        \\<worksheet
        \\<sheetData
        \\<row r=1 spans=1:3
        \\<c r=A1 t=s
        \\<v
        \\"0
        \\>v
        \\>c
        \\<c r=B1 s=2
        \\>c
        \\>row
        \\>sheetData
        \\>worksheet
        \\
    , "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
        "<worksheet><sheetData><row r=\"1\" spans='1:3'><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" s=\"2\"/></row></sheetData></worksheet>\n");
}

test "namespace prefixes are dropped from element names; attributes keep theirs" {
    try expectTrace(
        \\<worksheet xmlns:x=http://schemas.openxmlformats.org/spreadsheetml/2006/main xmlns:r=rel
        \\<sheetData
        \\<c r=A1
        \\<v
        \\"1
        \\>v
        \\>c
        \\>sheetData
        \\<hyperlink ref=A1 r:id=rId1
        \\>hyperlink
        \\>worksheet
        \\
    , "<x:worksheet xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"rel\">" ++
        "<x:sheetData><x:c r=\"A1\"><x:v>1</x:v></x:c></x:sheetData><x:hyperlink ref=\"A1\" r:id=\"rId1\" /></x:worksheet>");

    var src: SliceSource = .{ .bytes = "<a xmlns:r='x' r:id='rId7' id='plain' sheetId=\"3\"><b d3p1:id=\"other\"/></a>", .chunk = 4096 };
    var parser = try Parser.init(testing.allocator, src.source(), .{});
    defer parser.deinit();
    _ = try parser.next();
    // By exact name, or by local name whatever the prefix.
    try testing.expectEqualStrings("plain", parser.attribute("id").?);
    try testing.expectEqualStrings("rId7", parser.attribute("r:id").?);
    try testing.expectEqualStrings("3", parser.attribute("sheetId").?);
    try testing.expect(parser.attribute("missing") == null);
    _ = try parser.next();
    try testing.expectEqualStrings("other", parser.attributeLocal("id").?);
}

test "entities, character references, CDATA, comments and whitespace" {
    try expectTrace(
        \\<r
        \\<t xml:space=preserve a=x & "y" <z> 'q'
        \\"  a < b && c > d "quoted" 'single' é € 😀 
        \\>t
        \\<t
        \\"raw <b> & stuff ]] > kept
        \\>t
        \\<t
        \\"line 1
        \\line 2 tab
        \\>t
        \\>r
        \\
    , "<r><t xml:space=\"preserve\" a=\"x &amp; &quot;y&quot; &lt;z&gt; &apos;q&apos;\">  a &lt; b &amp;&amp; c &gt; d &quot;quoted&quot; &apos;single&apos; &#233; &#x20AC; &#x1F600; </t>" ++
        "<!-- a comment with <tags> & -- inside --><t><![CDATA[raw <b> & stuff ]] > kept]]></t><?pi ignored?><t>line 1\nline 2 tab</t></r>");
}

test "a long text arrives in pieces and adds up" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 300_000);
    defer gpa.free(long);
    for (long, 0..) |*c, i| c.* = "é&amp;x "[i % 9];
    const xml = try std.mem.concat(gpa, u8, &.{ "<t>", long[0 .. long.len - long.len % 9], "</t>" });
    defer gpa.free(xml);

    var src: SliceSource = .{ .bytes = xml, .chunk = 1000 };
    var parser = try Parser.init(gpa, src.source(), .{});
    defer parser.deinit();
    try testing.expectEqualStrings("t", (try parser.next()).start);
    var total: usize = 0;
    var pieces: usize = 0;
    while (true) {
        switch (try parser.next()) {
            .text => |text| {
                try testing.expect(std.unicode.utf8ValidateSlice(text));
                total += text.len;
                pieces += 1;
            },
            .end => break,
            else => return error.TestUnexpectedResult,
        }
    }
    // "é&amp;x " is nine bytes in, five bytes out ("é&x ").
    try testing.expectEqual(long.len / 9 * 5, total);
    try testing.expect(pieces > 1);
    try testing.expect(parser.buffer.len < 200_000);
}

test "skip leaves a whole element behind" {
    var src: SliceSource = .{ .bytes = "<a><skip x='1'><deep><deeper/>text</deep></skip><keep/><empty/></a>", .chunk = 3 };
    var parser = try Parser.init(testing.allocator, src.source(), .{});
    defer parser.deinit();
    try testing.expectEqualStrings("a", (try parser.next()).start);
    try testing.expectEqualStrings("skip", (try parser.next()).start);
    try parser.skip();
    try testing.expectEqualStrings("keep", (try parser.next()).start);
    try parser.skip();
    try testing.expectEqualStrings("empty", (try parser.next()).start);
    try testing.expectEqualStrings("empty", (try parser.next()).end);
    try testing.expectEqualStrings("a", (try parser.next()).end);
    try testing.expect(try parser.next() == .eof);
    try testing.expect(try parser.next() == .eof);
}

test "a document type declaration is always refused, and no entity is ever expanded" {
    try expectFailure(error.InvalidXml, "<!DOCTYPE lolz [<!ENTITY lol \"lol\"><!ENTITY lol2 \"&lol;&lol;&lol;&lol;\">]><r>&lol2;</r>", .{});
    try expectFailure(error.InvalidXml, "<?xml version=\"1.0\"?>\n<!DOCTYPE r SYSTEM \"file:///etc/passwd\"><r/>", .{});
    try expectFailure(error.InvalidXml, "<!doctype r><r/>", .{});
    try expectFailure(error.InvalidXml, "<r>&undefined;</r>", .{});
    try expectFailure(error.InvalidXml, "<r a=\"&xxe;\"/>", .{});
    try expectFailure(error.InvalidXml, "<r>&#0;</r>", .{});
    try expectFailure(error.InvalidXml, "<r>&#xD800;</r>", .{});
    try expectFailure(error.InvalidXml, "<r>&#x110000;</r>", .{});
    try expectFailure(error.InvalidXml, "<r>&#99999999999999999999;</r>", .{});
    try expectFailure(error.InvalidXml, "<r>&amp</r>", .{});
}

test "malformed documents" {
    const bad = [_][]const u8{
        "",
        "   ",
        "text only",
        "<r>",
        "<r></s>",
        "<r><a></r></a>",
        "</r>",
        "<r/><r/>",
        "<r/>trailing",
        "<r a=1/>",
        "<r a=\"1\" a=\"2\"/>",
        "<r a=\"1/>",
        "<r a=\"<\"/>",
        "<r a/>",
        "<1r/>",
        "< r/>",
        "<r><!-- never closed </r>",
        "<r><![CDATA[never closed</r>",
        "<r><?pi never closed</r>",
        "<r>\x01</r>",
        "<r a=\"\x02\"/>",
        "<r>caf\xe9</r>",
        "<r a=\"\xff\"/>",
        "<r>\xed\xa0\x80</r>",
        "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r/>",
        "<r><![UNKNOWN[x]]></r>",
    };
    for (bad) |xml| try expectFailure(error.InvalidXml, xml, .{});
    // A byte order mark and surrounding whitespace are fine.
    try expectTrace("<r\n>r\n", "\xef\xbb\xbf<?xml version='1.0' encoding='utf-8'?>\n\n<r/>\n\n");
}

test "limits: depth, attributes, name, value and tag size" {
    try expectFailure(error.LimitExceeded, "<a><b><c><d/></c></b></a>", .{ .max_depth = 3 });
    try expectFailure(error.LimitExceeded, "<r a='1' b='2' c='3'/>", .{ .max_attributes = 2 });
    try expectFailure(error.LimitExceeded, "<abcdefghijk/>", .{ .max_name_len = 10 });
    try expectFailure(error.LimitExceeded, "<r abcdefghijk='1'/>", .{ .max_name_len = 10 });
    try expectFailure(error.LimitExceeded, "<r a='12345678901'/>", .{ .max_value_len = 10 });
    const got = try trace(testing.allocator, "<a><b><c/></b></a><!-- end -->", 4096, .{ .max_depth = 3, .max_attributes = 0, .max_name_len = 1 });
    testing.allocator.free(got);

    // A tag that never ends cannot make the buffer grow without bound.
    const gpa = testing.allocator;
    const huge = try gpa.alloc(u8, 400_000);
    defer gpa.free(huge);
    @memset(huge, 'a');
    @memcpy(huge[0..6], "<r a='");
    try expectFailure(error.LimitExceeded, huge, .{});
    var names: std.Io.Writer.Allocating = .init(gpa);
    defer names.deinit();
    for (0..100) |_| try names.writer.writeAll("<a>");
    try expectFailure(error.LimitExceeded, names.written(), .{});
}

test "running out of memory at any point leaks nothing" {
    const Run = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const got = try trace(gpa, "<a x='1' y='&amp;'><b>text &lt; more</b><![CDATA[c]]><c/></a>", 7, .{});
            gpa.free(got);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "corrupted documents fail cleanly: one byte changed at a time" {
    const good = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"ns\" xmlns:r=\"rel\"><sheetData>" ++
        "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\"><f>SUM(A1:A2)</f><v>3.5</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t xml:space=\"preserve\"> a &amp; b &#233; </t></is></c></row>" ++
        "</sheetData><!-- c --><mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells></worksheet>";
    const copy = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(copy);
    var failures: usize = 0;
    for (0..copy.len) |i| {
        for ([_]u8{ '<', '>', '&', '"', 0x00, 0xff, '/' }) |replacement| {
            const saved = copy[i];
            copy[i] = replacement;
            defer copy[i] = saved;
            if (trace(testing.allocator, copy, 5, .{})) |got| {
                testing.allocator.free(got);
            } else |err| {
                try testing.expect(err == error.InvalidXml or err == error.LimitExceeded);
                failures += 1;
            }
        }
    }
    try testing.expect(failures > copy.len);
}

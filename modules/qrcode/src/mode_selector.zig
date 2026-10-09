//! Internal: mode detection and data-segment encoding (ISO/IEC 18004:2015
//! 7.3-7.4).
//!
//! Scope: Numeric, Alphanumeric, and Byte modes only — Kanji is out of
//! scope for this project (see project scope notes), so detectMode()
//! never returns it and there is no encodeKanji.
//!
//! Only encodes the mode indicator + character count indicator + packed
//! character data for one segment. Terminator and padding to fill the
//! symbol's data capacity are ISO 7.4.9/7.4.10 concerns, handled by
//! codewords.zig once the target version/ECC (and therefore capacity)
//! are known.

const std = @import("std");
const tables = @import("tables.zig");
const bitbuf = @import("bit_buffer.zig");

/// ISO 7.4.4 Table 5 — alphanumeric character set, in value order
/// (alphanumeric_chars[i] has value i). 45 symbols total: the 45
/// modulus used to pack two characters into 11 bits falls directly out
/// of this set's size, which is a useful internal consistency check.
pub const alphanumeric_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

comptime {
    std.debug.assert(alphanumeric_chars.len == 45);
}

pub fn alphanumericValue(c: u8) ?u6 {
    if (std.mem.indexOfScalar(u8, alphanumeric_chars, c)) |idx| return @intCast(idx);
    return null;
}

pub fn isNumeric(text: []const u8) bool {
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn isAlphanumeric(text: []const u8) bool {
    for (text) |c| {
        if (alphanumericValue(c) == null) return false;
    }
    return true;
}

/// Picks the most compact of the three in-scope modes that can
/// losslessly represent `text`. Falls through numeric -> alphanumeric
/// -> byte, matching the nesting of the three character sets (every
/// numeric string is also valid alphanumeric input, but not vice
/// versa; byte mode accepts anything).
pub fn detectMode(text: []const u8) tables.ModeIndicator {
    if (isNumeric(text)) return .numeric;
    if (isAlphanumeric(text)) return .alphanumeric;
    return .byte;
}

/// Appends one complete data segment — mode indicator, character count
/// indicator, and packed character data — for `text` under `mode` at
/// `version`. Does not append a terminator or padding.
///
/// `mode` is a parameter rather than always calling detectMode()
/// internally so callers can force byte mode for a numeric/alphanumeric
/// string if a future caller ever mixes modes; single-segment callers
/// should just pass detectMode(text).
pub fn encode(writer: *bitbuf.BitWriter, text: []const u8, mode: tables.ModeIndicator, version: u8) void {
    writer.appendBits(@intFromEnum(mode), 4);
    writer.appendBits(@intCast(text.len), tables.countIndicatorBits(mode, version));

    switch (mode) {
        .numeric => encodeNumeric(writer, text),
        .alphanumeric => encodeAlphanumeric(writer, text),
        .byte => encodeByte(writer, text),
    }
}

/// ISO 7.4.3: groups of 3 digits -> 10 bits, using the group's decimal
/// value directly. A final group of 2 digits uses 7 bits; a final
/// group of 1 digit uses 4 bits (both still just the group's decimal
/// value — 0-99 fits 7 bits, 0-9 fits 4 bits).
fn encodeNumeric(writer: *bitbuf.BitWriter, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const group_len = @min(3, text.len - i);
        var value: u32 = 0;
        for (text[i .. i + group_len]) |c| value = value * 10 + (c - '0');

        const bit_width: u6 = switch (group_len) {
            1 => 4,
            2 => 7,
            3 => 10,
            else => unreachable,
        };
        writer.appendBits(value, bit_width);
        i += group_len;
    }
}

/// ISO 7.4.4: pairs of characters -> value1*45 + value2, packed in 11
/// bits. A final unpaired character is packed in 6 bits as its raw
/// value (0-44 fits 6 bits).
fn encodeAlphanumeric(writer: *bitbuf.BitWriter, text: []const u8) void {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 2) {
        const a = alphanumericValue(text[i]).?;
        const b = alphanumericValue(text[i + 1]).?;
        writer.appendBits(@as(u32, a) * 45 + b, 11);
    }
    if (i < text.len) {
        writer.appendBits(alphanumericValue(text[i]).?, 6);
    }
}

/// ISO 7.4.5: each byte encoded as-is, 8 bits.
fn encodeByte(writer: *bitbuf.BitWriter, text: []const u8) void {
    for (text) |b| writer.appendBits(b, 8);
}

test "detectMode picks the tightest applicable mode" {
    try std.testing.expectEqual(tables.ModeIndicator.numeric, detectMode("12345"));
    try std.testing.expectEqual(tables.ModeIndicator.alphanumeric, detectMode("HELLO WORLD"));
    try std.testing.expectEqual(tables.ModeIndicator.alphanumeric, detectMode("12:34"));
    try std.testing.expectEqual(tables.ModeIndicator.byte, detectMode("hello"));
    try std.testing.expectEqual(tables.ModeIndicator.byte, detectMode("HELLO, world!"));
}

test "encode numeric '123' matches a hand-verified bit-packed fixture" {
    // mode(0001) + count(10 bits, version<=9)=0000000011 + value 123
    // packed as a single 3-digit group in 10 bits (0001111011).
    // Computed and cross-checked with a Python reference before being
    // committed here, not just hand-traced.
    var buf: [3]u8 = undefined;
    var w = bitbuf.BitWriter.init(&buf);
    encode(&w, "123", .numeric, 1);

    try std.testing.expectEqual(@as(usize, 24), w.bitLen());
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x0C, 0x7B }, w.writtenBytes());
}

test "encode alphanumeric 'AB' matches a hand-verified bit-packed fixture" {
    // mode(0010) + count(9 bits, version<=9)=000000010 + pair (A,B) =
    // (10*45+11) packed in 11 bits.
    var buf: [3]u8 = undefined;
    var w = bitbuf.BitWriter.init(&buf);
    encode(&w, "AB", .alphanumeric, 1);

    try std.testing.expectEqual(@as(usize, 24), w.bitLen());
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x11, 0xCD }, w.writtenBytes());
}

test "encode alphanumeric HELLO WORLD reproduces the first 10 bytes of the reed_solomon.zig HELLO WORLD fixture" {
    // Same version-1-M "HELLO WORLD" example validated end-to-end in
    // reed_solomon.zig: the full 16-byte data codeword sequence there
    // is [32,91,11,120,209,114,220,77,67,64, 236,17,236,17,236,17].
    // The first 10 bytes are exactly what mode_selector alone should
    // produce (mode + count + packed characters, unpadded); the last 6
    // are the 0xEC/0x11 terminator+pad bytes codewords.zig adds next.
    var buf: [10]u8 = undefined;
    var w = bitbuf.BitWriter.init(&buf);
    encode(&w, "HELLO WORLD", .alphanumeric, 1);

    try std.testing.expectEqual(@as(usize, 74), w.bitLen());
    try std.testing.expectEqualSlices(
        u8,
        &.{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64 },
        w.writtenBytes(),
    );
}

test "encode byte mode packs each byte as-is" {
    var buf: [8]u8 = undefined;
    var w = bitbuf.BitWriter.init(&buf);
    encode(&w, "hi!", .byte, 1);

    // mode(0100) + count(8 bits, version<=9)=00000011 + 'h'(0x68) + 'i'(0x69) + '!'(0x21).
    // Computed with a Python reference, not hand-traced — a first hand
    // attempt at this exact fixture got two of the five bytes wrong.
    try std.testing.expectEqual(@as(usize, 4 + 8 + 24), w.bitLen());
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x36, 0x86, 0x92, 0x10 }, w.writtenBytes());
}

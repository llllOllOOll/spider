//! Internal: sequential bit-level output buffer, packed
//! most-significant-bit first within each byte — the bit ordering ISO/IEC
//! 18004:2015 uses throughout 7.4 (mode indicator, character count
//! indicator, encoded data, terminator, padding all concatenate into one
//! MSB-first stream before being sliced into 8-bit codewords per 7.4.10).
//!
//! Capacity is caller-provided (QR data capacity is always known ahead
//! of time from tables.zig, given a version/ECC pair — see ISO Table 7),
//! so this type never allocates.

const std = @import("std");

pub const BitWriter = struct {
    bytes: []u8,
    bit_len: usize = 0,

    /// `bytes` is zeroed and used as backing storage; caller retains
    /// ownership and must size it to fit the maximum bits that will be
    /// appended (byteLen() will never exceed bytes.len).
    pub fn init(bytes: []u8) BitWriter {
        @memset(bytes, 0);
        return .{ .bytes = bytes };
    }

    /// Appends the low `num_bits` bits of `value`, most-significant bit
    /// first (e.g. appendBits(0b101, 3) appends 1, then 0, then 1).
    pub fn appendBits(self: *BitWriter, value: u32, num_bits: u6) void {
        std.debug.assert(num_bits <= 32);
        std.debug.assert(self.bit_len + num_bits <= self.bytes.len * 8);

        var i: u6 = num_bits;
        while (i > 0) {
            i -= 1;
            const shift: u5 = @intCast(i);
            self.appendBit(@truncate((value >> shift) & 1));
        }
    }

    pub fn appendBit(self: *BitWriter, bit: u1) void {
        std.debug.assert(self.bit_len < self.bytes.len * 8);

        const byte_index = self.bit_len / 8;
        const bit_index_in_byte: u3 = @intCast(7 - (self.bit_len % 8));
        if (bit == 1) {
            self.bytes[byte_index] |= (@as(u8, 1) << bit_index_in_byte);
        }
        self.bit_len += 1;
    }

    pub fn bitLen(self: BitWriter) usize {
        return self.bit_len;
    }

    /// Number of bytes touched so far, rounding up a partial final byte
    /// (its unwritten low bits read as 0, per ISO 7.4.9's terminator/
    /// padding rule — the backing buffer starts zeroed, so this is
    /// automatic).
    pub fn byteLen(self: BitWriter) usize {
        return (self.bit_len + 7) / 8;
    }

    pub fn writtenBytes(self: BitWriter) []const u8 {
        return self.bytes[0..self.byteLen()];
    }
};

test "appendBit packs most-significant bit first" {
    var buf: [1]u8 = undefined;
    var w = BitWriter.init(&buf);
    w.appendBit(1);
    w.appendBit(0);
    w.appendBit(1);
    w.appendBit(1);
    try std.testing.expectEqual(@as(usize, 4), w.bitLen());
    try std.testing.expectEqual(@as(u8, 0b1011_0000), buf[0]);
}

test "appendBits matches manual byte packing across a byte boundary" {
    // ISO 7.4.1: a numeric-mode segment starts with a 4-bit mode
    // indicator (0001) followed by a count indicator whose width comes
    // from Table 3 — 10 bits for numeric mode at version <= 9.
    // Encoding mode=numeric, count=5 by hand:
    //   0001 0000000101  (14 bits)
    // packed MSB-first into bytes:
    //   byte0 = 00010000 = 0x10
    //   byte1 = 000101(00) = 0x14  (low 2 bits unwritten, read as 0)
    var buf: [2]u8 = undefined;
    var w = BitWriter.init(&buf);
    w.appendBits(0b0001, 4); // mode indicator: numeric
    w.appendBits(5, 10); // count indicator: 5 characters

    try std.testing.expectEqual(@as(usize, 14), w.bitLen());
    try std.testing.expectEqual(@as(usize, 2), w.byteLen());
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x14 }, w.writtenBytes());
}

test "byteLen rounds up a partial final byte, unwritten bits read as 0" {
    var buf: [2]u8 = undefined;
    var w = BitWriter.init(&buf);
    w.appendBits(0b101, 3);
    try std.testing.expectEqual(@as(usize, 1), w.byteLen());
    try std.testing.expectEqual(@as(u8, 0b1010_0000), w.writtenBytes()[0]);
}

test "init zeroes backing storage regardless of prior contents" {
    var buf: [1]u8 = .{0xFF};
    var w = BitWriter.init(&buf);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    w.appendBit(1);
    try std.testing.expectEqual(@as(u8, 0b1000_0000), buf[0]);
}

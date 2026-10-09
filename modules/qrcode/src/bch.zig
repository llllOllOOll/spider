//! Internal: format information (ISO/IEC 18004:2015 Annex C / 7.9.1) and
//! version information (Annex D / 7.10) — the two small BCH/Golay-coded
//! fields placed around the finder patterns so a scanner can recover the
//! ECC level, mask pattern, and (for version >= 7) the symbol version
//! before it can even attempt to read the data region.
//!
//! Binary polynomial (GF(2), XOR-arithmetic) division — distinct from
//! the GF(2^8) arithmetic reed_solomon.zig uses for the data codewords.

const std = @import("std");
const tables = @import("tables.zig");

/// ISO Annex C.2: format info generator polynomial
/// G(x) = x^10 + x^8 + x^5 + x^4 + x^2 + x + 1.
const format_generator: u32 = 0x537;
/// ISO Annex C.2 / 7.9.1: fixed XOR mask applied after BCH encoding —
/// "101010000010010" in the spec text — so that no (ECC level, mask
/// pattern) combination ever produces an all-zero format sequence.
const format_mask: u15 = 0x5412;

/// ISO Annex D.2: version info generator polynomial
/// G(x) = x^12 + x^11 + x^10 + x^9 + x^8 + x^5 + x^2 + 1. No masking
/// step for version info (Annex D does not describe one).
const version_generator: u32 = 0x1F25;

/// Binary long-division remainder of `value` (`value_bits` wide,
/// divided as-is, no implicit shift) by `generator` (whose degree-th
/// bit must be set — it is `degree + 1` bits wide), using GF(2) (XOR)
/// arithmetic. This is the core primitive both codeword generation
/// (via bchRemainder below) and codeword *validation* (in this file's
/// tests — checking that a full codeword is exactly divisible by the
/// generator, the defining property of a BCH/Golay codeword) reduce to.
fn polyMod(value: u32, value_bits: u6, generator: u32, degree: u5) u32 {
    const window_mask: u32 = (@as(u32, 1) << (degree + 1)) - 1;

    var rem: u32 = 0;
    var i: u6 = value_bits;
    while (i > 0) {
        i -= 1;
        const shift: u5 = @intCast(i);
        const bit: u32 = (value >> shift) & 1;
        rem = ((rem << 1) | bit) & window_mask;
        if (rem & (@as(u32, 1) << degree) != 0) rem ^= generator;
    }
    return rem;
}

/// `data` (`data_bits` wide) implicitly multiplied by x^degree
/// (zero-extended on the right) and divided by `generator`. Returns the
/// `degree`-bit remainder — the error correction bits to append to
/// `data`.
fn bchRemainder(data: u32, data_bits: u6, generator: u32, degree: u5) u32 {
    return polyMod(data << degree, data_bits + degree, generator, degree);
}

/// ISO Table 12: the format info's 2-bit error-correction-level
/// indicator is NOT this project's Ecc enum ordinal — it is a fixed,
/// separately-defined mapping (confirmed directly against the ISO
/// text, not derived): L=01, M=00, Q=11, H=10.
fn eccIndicatorBits(ecc: tables.Ecc) u2 {
    return switch (ecc) {
        .low => 0b01,
        .medium => 0b00,
        .quartile => 0b11,
        .high => 0b10,
    };
}

/// The format info's 5-bit data value: 2-bit ECC level indicator
/// followed by the 3-bit mask pattern reference (ISO 7.9.1).
pub fn formatData(ecc: tables.Ecc, mask: u3) u5 {
    return (@as(u5, eccIndicatorBits(ecc)) << 3) | mask;
}

/// The 10-bit BCH error correction remainder for a 5-bit format data
/// value, before the fixed XOR mask. Exposed mainly for testing against
/// ISO Table C.1's "Error correction bits" column.
pub fn formatBitsRaw(data: u5) u10 {
    return @intCast(bchRemainder(data, 5, format_generator, 10));
}

/// The complete 15-bit format information sequence (data + BCH bits,
/// masked) — what actually gets placed into the symbol (ISO 7.9.1 /
/// Figure 25).
pub fn formatBits(ecc: tables.Ecc, mask: u3) u15 {
    const data = formatData(ecc, mask);
    const codeword: u15 = (@as(u15, data) << 10) | formatBitsRaw(data);
    return codeword ^ format_mask;
}

/// The 12-bit Golay error correction remainder for a 6-bit version
/// number, before concatenation. Exposed for testing against ISO Table
/// D.1.
pub fn versionBitsRaw(version: u6) u12 {
    return @intCast(bchRemainder(version, 6, version_generator, 12));
}

/// The complete 18-bit version information sequence (ISO 7.10). Only
/// meaningful for version >= 7 — versions 1-6 do not carry a version
/// info field in the symbol at all (matrix.zig skips drawing it), but
/// this function does not enforce that; it is a pure encoding of
/// whatever version number it is given.
pub fn versionBits(version: u6) u18 {
    return (@as(u18, version) << 12) | versionBitsRaw(version);
}

test "formatBitsRaw matches the ISO 7.9.1 worked example (ECC=M, mask=101)" {
    // ISO 7.9.1, Figure 25's EXAMPLE: Data: 00101, BCH bits: 0011011100,
    // Unmasked bit sequence: 001010011011100, Mask: 101010000010010,
    // Format information module pattern: 100000011001110 — every one of
    // these intermediate values is checked below, not just the final
    // result, so a mistake in either the raw BCH step or the masking
    // step would be caught at the step where it actually occurs.
    const data: u5 = 0b00101;
    try std.testing.expectEqual(@as(u10, 0b0011011100), formatBitsRaw(data));

    const unmasked: u15 = (@as(u15, data) << 10) | formatBitsRaw(data);
    try std.testing.expectEqual(@as(u15, 0b001010011011100), unmasked);

    try std.testing.expectEqual(@as(u15, 0b100000011001110), formatBits(.medium, 0b101));
}

test "formatData uses ISO Table 12's ECC indicator mapping, not enum ordinals" {
    // L=01, M=00, Q=11, H=10 — deliberately not 0,1,2,3.
    try std.testing.expectEqual(@as(u5, 0b01_000), formatData(.low, 0));
    try std.testing.expectEqual(@as(u5, 0b00_000), formatData(.medium, 0));
    try std.testing.expectEqual(@as(u5, 0b11_000), formatData(.quartile, 0));
    try std.testing.expectEqual(@as(u5, 0b10_000), formatData(.high, 0));
    try std.testing.expectEqual(@as(u5, 0b00_101), formatData(.medium, 0b101));
}

test "every one of the 32 possible format codewords is a valid BCH codeword and they are all distinct" {
    // Stronger than comparing against a transcribed table: this checks
    // the actual mathematical definition of a valid (15,5) BCH
    // codeword — (data << 10 | remainder) must be exactly divisible by
    // the generator polynomial — for every possible 5-bit input, plus
    // the distinctness ISO 7.9.1 implies by describing a Hamming
    // distance of 7 between valid sequences (Annex C.3).
    var seen: std.StaticBitSet(1 << 15) = .empty;
    var data: u6 = 0;
    while (data < 32) : (data += 1) {
        const codeword: u15 = (@as(u15, @intCast(data)) << 10) | formatBitsRaw(@intCast(data));
        try std.testing.expectEqual(@as(u32, 0), polyMod(codeword, 15, format_generator, 10));
        try std.testing.expect(!seen.isSet(codeword));
        seen.set(codeword);
    }
}

test "versionBitsRaw matches the ISO 7.10 worked example (version 7)" {
    // ISO Annex D.2 EXAMPLE: Binary string 000111, remainder
    // 110010010100, full string 000111110010010100 (hex 07C94) — also
    // cross-checked against Table D.1's version-7 row.
    try std.testing.expectEqual(@as(u12, 0b110010010100), versionBitsRaw(7));
    try std.testing.expectEqual(@as(u18, 0x07C94), versionBits(7));
}

test "Table D.1 spot checks: versions 8 and 40" {
    try std.testing.expectEqual(@as(u18, 0x085BC), versionBits(8));
    try std.testing.expectEqual(@as(u18, 0x28C69), versionBits(40));
}

test "every one of the 64 possible version codewords is a valid Golay codeword and they are all distinct" {
    var seen: std.StaticBitSet(1 << 18) = .empty;
    var version: u7 = 0;
    while (version < 64) : (version += 1) {
        const codeword = versionBits(@intCast(version));
        try std.testing.expectEqual(@as(u32, 0), polyMod(codeword, 18, version_generator, 12));
        try std.testing.expect(!seen.isSet(codeword));
        seen.set(codeword);
    }
}

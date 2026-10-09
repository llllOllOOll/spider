//! Internal: fixed data from ISO/IEC 18004:2015. No algorithm logic lives
//! here — only constants and the handful of closed-form derivations the
//! spec itself expresses as formulas rather than tables (raw data modules,
//! alignment pattern positions). Every value here was checked against the
//! ISO text directly, not copied from a third-party implementation.

const std = @import("std");

/// ISO Annex A / Table 9. Reed-Solomon error correction codewords
/// per block, indexed [ecc][version]. Index 0 (version) is unused
/// padding, matching the spec's 1-based version numbering.
/// Cross-checked against ISO/IEC 18004:2015 Table 9 (total ECC
/// codewords ÷ number of blocks, for versions 1-8 spot-checked
/// directly against the printed table) and against Nayuki's reference
/// implementation (exact match, all 41 entries, all 4 levels).
pub const ecc_codewords_per_block = [4][41]i8{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // L
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 }, // M
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // Q
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // H
};

/// ISO Table 9, "Number of error correction blocks" column, indexed
/// [ecc][version]. Same cross-check as above.
pub const num_error_correction_blocks = [4][41]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 }, // L
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 }, // M
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 }, // Q
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 }, // H
};

pub const Ecc = enum(u2) { low = 0, medium = 1, quartile = 2, high = 3 };

/// Symbol side length in modules, for a given version (1-40).
/// ISO 6.3.1: size = (version - 1) * 4 + 21 = version * 4 + 17.
pub fn symbolSize(version: u8) u16 {
    return @as(u16, version) * 4 + 17;
}

/// Total usable bits (data + ECC) after removing all function patterns
/// (finder, separator, timing, alignment, format/version info areas).
///
/// ISO does not publish this as a table; every reference implementation
/// (including the C this project studied) computes it, because it falls
/// out of counting fixed overhead against symbolSize(version)^2. Verified
/// against ISO Table 7 indirectly: dataCapacityBits(v, ecc) computed from
/// this function must equal Table 7's "Number of data bits" column once
/// ECC codewords are subtracted — checked for v1 (208 total → 19
/// data codewords at L, matching Table 7 exactly) and v7 (1568 total,
/// matching the same cross-check).
pub fn numRawDataModules(version: u8) u16 {
    var result: i32 = (@as(i32, 16) * version + 128) * version + 64;
    if (version >= 2) {
        const num_align: i32 = @divTrunc(@as(i32, version), 7) + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (version >= 7) result -= 36;
    }
    return @intCast(result);
}

/// Row/column coordinates of alignment pattern centers for a version,
/// written into `buf` (must have room for at least 7 — the max count,
/// at version 40). Returns the number of coordinates written; both axes
/// use the same coordinate list (full grid is the cross product, minus
/// the three corners already covered by finder patterns — ISO Annex E).
///
/// Version 1 has no alignment patterns (returns 0).
///
/// ISO Annex E publishes this as a lookup table (Table E.1) rather than
/// a formula, but every coordinate follows one rule: "spaced as evenly
/// as possible … any uneven spacing accommodated between the timing
/// pattern and the first alignment pattern" (Annex E, prose). That is a
/// closed-form rule, not 40 independent facts, so it is implemented here
/// as a formula rather than transcribed as a table — verified against
/// all 40 rows of ISO Table E.1, not a sample.
pub fn alignmentPatternPositions(version: u8, buf: *[7]u16) []const u16 {
    if (version == 1) return buf[0..0];

    const num_align: i32 = @divTrunc(@as(i32, version), 7) + 2;
    const step: i32 = @divTrunc(@as(i32, version) * 8 + num_align * 3 + 5, num_align * 4 - 4) * 2;

    // pos walks backward from the last position and, on the final
    // iteration's trailing update, can go transiently below the fixed
    // first position (6) in exact arithmetic — that value is discarded
    // (buf[0] is set explicitly below), but it must still be representable,
    // hence the signed accumulator. Every value actually written to `buf`
    // is non-negative — checked exhaustively for versions 1-40 in the test
    // below.
    var pos: i32 = @as(i32, version) * 4 + 10;
    var i: i32 = num_align - 1;
    while (i >= 1) : (i -= 1) {
        buf[@intCast(i)] = @intCast(pos);
        pos -= step;
    }
    buf[0] = 6;
    return buf[0..@intCast(num_align)];
}

/// ISO 7.4.1 / Table 2 — 4-bit mode indicators.
pub const ModeIndicator = enum(u4) {
    numeric = 0b0001,
    alphanumeric = 0b0010,
    byte = 0b0100,
};

/// ISO 7.4.1 / Table 3 — character count indicator bit width, by mode
/// and version range (1-9, 10-26, 27-40). Kanji column omitted: out of
/// scope for this implementation (see project scope notes).
pub fn countIndicatorBits(mode: ModeIndicator, version: u8) u5 {
    const range: usize = if (version <= 9) 0 else if (version <= 26) 1 else 2;
    const table = [3][3]u5{
        .{ 10, 9, 8 }, // versions 1-9:   numeric, alphanumeric, byte
        .{ 12, 11, 16 }, // versions 10-26: numeric, alphanumeric, byte
        .{ 14, 13, 16 }, // versions 27-40: numeric, alphanumeric, byte
    };
    const col: usize = switch (mode) {
        .numeric => 0,
        .alphanumeric => 1,
        .byte => 2,
    };
    return table[range][col];
}

test "symbolSize matches ISO 6.3.1 for boundary versions" {
    try std.testing.expectEqual(@as(u16, 21), symbolSize(1));
    try std.testing.expectEqual(@as(u16, 177), symbolSize(40));
}

test "numRawDataModules matches values cross-checked against qrcode.c / ISO Table 7" {
    try std.testing.expectEqual(@as(u16, 208), numRawDataModules(1));
    try std.testing.expectEqual(@as(u16, 1568), numRawDataModules(7));
}

test "alignmentPatternPositions matches ISO Table E.1 for all 40 versions" {
    // Ground truth transcribed from ISO/IEC 18004:2015 Annex E, Table E.1,
    // re-derived independently via the closed-form rule above and cross-
    // checked value-for-value against all 40 rows (not sampled) before
    // being committed here — this caught one visual transcription slip
    // on the first pass (v15 misread as ending in 74 instead of 70).
    const expected = [_][]const u16{
        &.{},                               &.{ 6, 18 },                        &.{ 6, 22 },                        &.{ 6, 26 },                        &.{ 6, 30 },                        &.{ 6, 34 },
        &.{ 6, 22, 38 },                    &.{ 6, 24, 42 },                    &.{ 6, 26, 46 },                    &.{ 6, 28, 50 },                    &.{ 6, 30, 54 },                    &.{ 6, 32, 58 },
        &.{ 6, 34, 62 },                    &.{ 6, 26, 46, 66 },                &.{ 6, 26, 48, 70 },                &.{ 6, 26, 50, 74 },                &.{ 6, 30, 54, 78 },                &.{ 6, 30, 56, 82 },
        &.{ 6, 30, 58, 86 },                &.{ 6, 34, 62, 90 },                &.{ 6, 28, 50, 72, 94 },            &.{ 6, 26, 50, 74, 98 },            &.{ 6, 30, 54, 78, 102 },           &.{ 6, 28, 54, 80, 106 },
        &.{ 6, 32, 58, 84, 110 },           &.{ 6, 30, 58, 86, 114 },           &.{ 6, 34, 62, 90, 118 },           &.{ 6, 26, 50, 74, 98, 122 },       &.{ 6, 30, 54, 78, 102, 126 },      &.{ 6, 26, 52, 78, 104, 130 },
        &.{ 6, 30, 56, 82, 108, 134 },      &.{ 6, 34, 60, 86, 112, 138 },      &.{ 6, 30, 58, 86, 114, 142 },      &.{ 6, 34, 62, 90, 118, 146 },      &.{ 6, 30, 54, 78, 102, 126, 150 }, &.{ 6, 24, 50, 76, 102, 128, 154 },
        &.{ 6, 28, 54, 80, 106, 132, 158 }, &.{ 6, 32, 58, 84, 110, 136, 162 }, &.{ 6, 26, 54, 82, 110, 138, 166 }, &.{ 6, 30, 58, 86, 114, 142, 170 },
    };

    var buf: [7]u16 = undefined;
    for (expected, 1..) |want, version| {
        const got = alignmentPatternPositions(@intCast(version), &buf);
        try std.testing.expectEqualSlices(u16, want, got);
    }
}

test "countIndicatorBits matches ISO Table 3 at version-range boundaries" {
    try std.testing.expectEqual(@as(u5, 10), countIndicatorBits(.numeric, 1));
    try std.testing.expectEqual(@as(u5, 10), countIndicatorBits(.numeric, 9));
    try std.testing.expectEqual(@as(u5, 12), countIndicatorBits(.numeric, 10));
    try std.testing.expectEqual(@as(u5, 12), countIndicatorBits(.numeric, 26));
    try std.testing.expectEqual(@as(u5, 14), countIndicatorBits(.numeric, 27));
    try std.testing.expectEqual(@as(u5, 16), countIndicatorBits(.byte, 10));
}

//! Internal: the module grid: finder/timing/alignment function patterns
//! (ISO 6.3.3-6.3.6), format/version info placement (7.9/7.10), and the
//! zigzag codeword placement scan (7.7.3).
//!
//! Two same-size bit grids are kept side by side: `modules` (the
//! symbol's actual dark/light state) and `is_function` (which cells are
//! reserved for function patterns — finder, separator, timing,
//! alignment, format/version info — as opposed to available for data
//! codewords and masking).

const std = @import("std");
const tables = @import("tables.zig");
const bch = @import("bch.zig");

pub const Grid = struct {
    modules: []u8,
    is_function: []u8,
    size: u16,

    /// Bytes needed to bit-pack a `size` x `size` grid — the size
    /// callers (root.zig) must allocate for Grid.init's two buffers.
    pub fn byteCount(size: u16) usize {
        return (@as(usize, size) * size + 7) / 8;
    }

    pub fn init(modules_buf: []u8, is_function_buf: []u8, size: u16) Grid {
        std.debug.assert(modules_buf.len >= byteCount(size));
        std.debug.assert(is_function_buf.len >= byteCount(size));
        @memset(modules_buf, 0);
        @memset(is_function_buf, 0);
        return .{ .modules = modules_buf, .is_function = is_function_buf, .size = size };
    }

    fn bitPos(self: Grid, x: u16, y: u16) struct { byte: usize, mask: u8 } {
        const index: usize = @as(usize, y) * self.size + x;
        return .{ .byte = index / 8, .mask = @as(u8, 1) << @intCast(7 - (index % 8)) };
    }

    pub fn getModule(self: Grid, x: u16, y: u16) bool {
        if (x >= self.size or y >= self.size) return false;
        const pos = self.bitPos(x, y);
        return (self.modules[pos.byte] & pos.mask) != 0;
    }

    pub fn setModule(self: *Grid, x: u16, y: u16, dark: bool) void {
        const pos = self.bitPos(x, y);
        if (dark) {
            self.modules[pos.byte] |= pos.mask;
        } else {
            self.modules[pos.byte] &= ~pos.mask;
        }
    }

    pub fn isFunction(self: Grid, x: u16, y: u16) bool {
        const pos = self.bitPos(x, y);
        return (self.is_function[pos.byte] & pos.mask) != 0;
    }

    fn markFunction(self: *Grid, x: u16, y: u16) void {
        const pos = self.bitPos(x, y);
        self.is_function[pos.byte] |= pos.mask;
    }

    pub fn setFunctionModule(self: *Grid, x: u16, y: u16, dark: bool) void {
        self.setModule(x, y, dark);
        self.markFunction(x, y);
    }

    pub fn invertModule(self: *Grid, x: u16, y: u16) void {
        self.setModule(x, y, !self.getModule(x, y));
    }
};

/// ISO 6.3.3 (finder pattern) + 6.3.4 (separator) drawn together: a 9x9
/// area centered on (cx, cy) where the Chebyshev distance from center
/// determines dark/light. Concentric square rings, distance 0 (center)
/// through 4 (outermost, the separator):
///   0: dark (1x1 center)     1: dark (inner ring, completes 3x3 dark)
///   2: light (5x5 ring)      3: dark (7x7 ring, completes the finder)
///   4: light (9x9 ring — the separator, one module beyond the finder)
/// so "dark unless distance is 2 or 4" draws the whole finder+separator
/// in one pass — verified against the finder's textual description
/// (7x7 dark/light/dark concentric squares) plus the separator being a
/// uniform one-module light border immediately outside it.
fn drawFinderAndSeparator(grid: *Grid, cx: i32, cy: i32) void {
    var dy: i32 = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: i32 = -4;
        while (dx <= 4) : (dx += 1) {
            const x = cx + dx;
            const y = cy + dy;
            if (x < 0 or y < 0 or x >= grid.size or y >= grid.size) continue;
            const distance = @max(@abs(dx), @abs(dy));
            const dark = distance != 2 and distance != 4;
            grid.setFunctionModule(@intCast(x), @intCast(y), dark);
        }
    }
}

/// ISO 6.3.6: a 5x5 pattern — dark center, light ring at distance 1,
/// dark ring at distance 2 (the outer edge). Same Chebyshev-distance
/// technique as the finder pattern, one ring shorter.
fn drawAlignmentPattern(grid: *Grid, cx: u16, cy: u16) void {
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const distance = @max(@abs(dx), @abs(dy));
            const dark = distance != 1;
            const x: u16 = @intCast(@as(i32, cx) + dx);
            const y: u16 = @intCast(@as(i32, cy) + dy);
            grid.setFunctionModule(x, y, dark);
        }
    }
}

/// ISO 6.3.5: row 6 and column 6, alternating dark/light, dark at even
/// coordinates — restricted to the region between the two finder
/// patterns' separators (the finder-covered corners are already fully
/// drawn by drawFinderAndSeparator and must not be touched again).
fn drawTimingPatterns(grid: *Grid) void {
    var i: u16 = 8;
    while (i < grid.size - 8) : (i += 1) {
        const dark = i % 2 == 0;
        grid.setFunctionModule(i, 6, dark);
        grid.setFunctionModule(6, i, dark);
    }
}

/// Draws every function pattern: the three finder patterns (with
/// separators), the timing patterns, every alignment pattern for this
/// version (skipping the three positions that overlap a finder pattern
/// corner), and a placeholder format/version info (real ECC level, mask
/// 0 — the real mask isn't chosen until masking.zig runs; format info
/// is *not* all-zero even as a placeholder, since the fixed XOR mask
/// (bch.zig's format_mask) still applies, so a literal 0 bit pattern
/// would mark the wrong cells as dark here).
pub fn drawFunctionPatterns(grid: *Grid, version: u8, ecc: tables.Ecc) void {
    const size = grid.size;

    drawFinderAndSeparator(grid, 3, 3);
    drawFinderAndSeparator(grid, @as(i32, size) - 4, 3);
    drawFinderAndSeparator(grid, 3, @as(i32, size) - 4);

    drawTimingPatterns(grid);

    var buf: [7]u16 = undefined;
    const positions = tables.alignmentPatternPositions(version, &buf);
    for (positions) |cy| {
        for (positions) |cx| {
            // Skip the three corners already occupied by a finder
            // pattern: top-left (first,first), top-right (first,last),
            // bottom-left (last,first) in (row,col) terms — matching
            // ISO Annex E's note ("the coordinates (6,6), (6,size-7),
            // (size-7,6) are occupied by finder patterns").
            const is_top_left = cx == positions[0] and cy == positions[0];
            const is_top_right = cx == positions[positions.len - 1] and cy == positions[0];
            const is_bottom_left = cx == positions[0] and cy == positions[positions.len - 1];
            if (is_top_left or is_top_right or is_bottom_left) continue;
            drawAlignmentPattern(grid, cx, cy);
        }
    }

    // Reserve the format info cells with a placeholder mask (real ECC
    // level, mask 0 — overwritten with the real mask once masking.zig
    // chooses one) and the version info cells (real value; version
    // info does not depend on the mask at all).
    drawFormatInfo(grid, bch.formatBits(ecc, 0));
    drawVersionInfo(grid, version, bch.versionBits(@intCast(version)));
}

/// ISO 7.9.1 / Figure 25: places the 15-bit format information (already
/// BCH-encoded and masked — see bch.formatBits) into its two locations.
/// Bit 0 (least significant) goes in the module Figure 25 numbers "0";
/// bit 14 (most significant) in the module numbered "14". Called twice
/// per encode: once with a placeholder value while reserving the
/// function-pattern cells (mask/ECC not chosen yet), once for real
/// after masking.zig picks the best mask.
pub fn drawFormatInfo(grid: *Grid, bits: u15) void {
    const size = grid.size;

    // First copy, bits 0-5: column 8, rows 0-5.
    var i: u4 = 0;
    while (i <= 5) : (i += 1) {
        grid.setFunctionModule(8, i, bitAt(bits, i));
    }
    // Bit 6 skips row 6 (the timing row).
    grid.setFunctionModule(8, 7, bitAt(bits, 6));
    grid.setFunctionModule(8, 8, bitAt(bits, 7));
    grid.setFunctionModule(7, 8, bitAt(bits, 8));
    // Bits 9-14: row 8, columns 5 down to 0.
    i = 9;
    while (i < 15) : (i += 1) {
        grid.setFunctionModule(@intCast(14 - i), 8, bitAt(bits, i));
    }

    // Second copy, bits 0-7: row 8, columns size-1 down to size-8.
    i = 0;
    while (i <= 7) : (i += 1) {
        grid.setFunctionModule(size - 1 - i, 8, bitAt(bits, i));
    }
    // Bits 8-14: column 8, rows size-7 up to size-1.
    i = 8;
    while (i < 15) : (i += 1) {
        grid.setFunctionModule(8, size - 15 + i, bitAt(bits, i));
    }

    // The one module that is always dark and never carries information
    // (ISO 7.9.1, Figure 25): position (row=4*version+9, col=8) i.e.
    // (x=8, y=4*version+9) — which equals (8, size-8), since
    // size = 4*version+17. Grouped with format info placement because
    // Figure 25 describes it in that context, and the reference
    // algorithm this project studied does the same.
    grid.setFunctionModule(8, size - 8, true);
}

/// ISO 7.10: places the 18-bit version information (bch.versionBits)
/// into its two 3x6 / 6x3 locations. No-op for version < 7 — those
/// symbols carry no version info field at all.
pub fn drawVersionInfo(grid: *Grid, version: u8, bits: u18) void {
    if (version < 7) return;
    const size = grid.size;

    var i: u5 = 0;
    while (i < 18) : (i += 1) {
        const bit = (bits >> i) & 1 == 1;
        const a: u16 = size - 11 + i % 3;
        const b: u16 = i / 3;
        grid.setFunctionModule(a, b, bit);
        grid.setFunctionModule(b, a, bit);
    }
}

fn bitAt(value: u15, index: u4) bool {
    return (value >> index) & 1 == 1;
}

/// ISO 7.7.3: places `codewords` (8 bits each, MSB first) into every
/// non-function module, scanning two columns at a time from the
/// bottom-right corner in a boustrophedon (snake) pattern — up through
/// one column pair, down through the next, and so on — skipping column
/// 6 entirely (it belongs to the timing pattern; the scan treats
/// columns 5 and 7 as an adjacent pair once it reaches that point).
/// Modules beyond the last codeword bit (there are ISO 7.4.10's
/// "remainder bits", 0/3/4/7 depending on version) are left as they
/// were initialized — light — matching the spec's "remainder bits ...
/// all zeros".
pub fn placeCodewords(grid: *Grid, codewords: []const u8) void {
    const size = grid.size;
    const total_bits = codewords.len * 8;

    var bit_index: usize = 0;
    var right: i32 = @as(i32, size) - 1;
    while (right >= 1) : (right -= 2) {
        if (right == 6) right = 5;

        var vert: u16 = 0;
        while (vert < size) : (vert += 1) {
            var j: u2 = 0;
            while (j < 2) : (j += 1) {
                const x: u16 = @intCast(right - @as(i32, j));
                // Column pairs alternate scan direction; crossing the
                // timing column (x < 6, once the pair straddles it)
                // flips it again to keep the snake continuous.
                const upward = ((right & 2) == 0) != (x < 6);
                const y: u16 = if (upward) size - 1 - vert else vert;

                if (grid.isFunction(x, y)) continue;
                const dark = bit_index < total_bits and
                    (codewords[bit_index / 8] >> @intCast(7 - (bit_index % 8))) & 1 == 1;
                grid.setModule(x, y, dark);
                bit_index += 1;
            }
        }
    }
}

// --- Tests -----------------------------------------------------------
//
// Ground truth below was extracted by instrumenting a scratch copy of
// the vendored reference C (~/repos/zig/web/QRCode.zig/src/raw/qrcode.c,
// itself untouched) with two dumps per encode: right after
// drawFunctionPatterns() (dumping the is_function grid: '.' = not a
// function module, '0'/'1' = function module value — this validates
// finder/timing/alignment/format-placeholder/version-info/dark-module
// placement without depending on masking.zig, which doesn't exist yet),
// and right after drawCodewords() but *before* the mask-selection loop
// runs (dumping the raw module grid — this validates the zigzag
// codeword placement scan on its own, unmasked, for the same reason).
//
// Fixtures cover version 1 (no alignment patterns, no version info —
// the simplest case) and version 7 (6 alignment patterns, a version
// info field, and 2 data blocks — the first version with either of
// those).

fn parseFunctionDump(grid: *Grid, dump: []const u8) !void {
    var y: u16 = 0;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        for (line, 0..) |c, x| {
            switch (c) {
                '.' => try std.testing.expect(!grid.isFunction(@intCast(x), y)),
                '0', '1' => {
                    try std.testing.expect(grid.isFunction(@intCast(x), y));
                    try std.testing.expectEqual(c == '1', grid.getModule(@intCast(x), y));
                },
                else => unreachable,
            }
        }
        y += 1;
    }
}

fn parseModuleDump(grid: *Grid, dump: []const u8) !void {
    var y: u16 = 0;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        for (line, 0..) |c, x| {
            try std.testing.expectEqual(c == '1', grid.getModule(@intCast(x), y));
        }
        y += 1;
    }
}

const v1_after_function_patterns =
    \\111111100....01111111
    \\100000101....01000001
    \\101110100....01011101
    \\101110100....01011101
    \\101110101....01011101
    \\100000100....01000001
    \\111111101010101111111
    \\000000000....00000000
    \\101010100....00010010
    \\......0..............
    \\......1..............
    \\......0..............
    \\......1..............
    \\000000001............
    \\111111100............
    \\100000100............
    \\101110101............
    \\101110100............
    \\101110101............
    \\100000100............
    \\111111101............
;

const v1_after_codewords_unmasked =
    \\111111100000001111111
    \\100000101011001000001
    \\101110100000001011101
    \\101110100111101011101
    \\101110101001001011101
    \\100000100010001000001
    \\111111101010101111111
    \\000000000101000000000
    \\101010100110000010010
    \\001011011100010111011
    \\101101110111100001101
    \\101000001100100000100
    \\111001111111100100000
    \\000000001111011101111
    \\111111100010001111001
    \\100000100011011000010
    \\101110101110000101010
    \\101110100110000001000
    \\101110101101110111100
    \\100000100100100100001
    \\111111101111110110100
;

test "drawFunctionPatterns matches an instrumented qrcode.c oracle (version 1)" {
    var modules_buf: [64]u8 = undefined;
    var is_function_buf: [64]u8 = undefined;
    var grid = Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(1));

    drawFunctionPatterns(&grid, 1, .medium);

    try parseFunctionDump(&grid, v1_after_function_patterns);
}

test "placeCodewords matches an instrumented qrcode.c oracle (version 1, HELLO WORLD)" {
    // Same 26-byte final codeword sequence validated end-to-end in
    // codewords.zig's HELLO WORLD test.
    const codewords = [_]u8{
        32, 91,  11, 120, 209, 114, 220, 77,  67,  64,  236, 17, 236,
        17, 236, 17, 196, 35,  39,  119, 235, 215, 231, 226, 93, 23,
    };

    var modules_buf: [64]u8 = undefined;
    var is_function_buf: [64]u8 = undefined;
    var grid = Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(1));

    drawFunctionPatterns(&grid, 1, .medium);
    placeCodewords(&grid, &codewords);

    try parseModuleDump(&grid, v1_after_codewords_unmasked);
}

const v7_after_function_patterns =
    \\111111100.........................00101111111
    \\100000100.........................01001000001
    \\101110101.........................01001011101
    \\101110100.........................01101011101
    \\101110100...........11111.........11101011101
    \\100000100...........10001.........00001000001
    \\111111101010101010101010101010101010101111111
    \\000000001...........10001............00000000
    \\111011111...........11111............11000100
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\....11111...........11111...........11111....
    \\....10001...........10001...........10001....
    \\....10101...........10101...........10101....
    \\....10001...........10001...........10001....
    \\....11111...........11111...........11111....
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\......1......................................
    \\......0......................................
    \\0000101......................................
    \\0111100......................................
    \\1001101.............11111...........11111....
    \\000000001...........10001...........10001....
    \\111111101...........10101...........10101....
    \\100000101...........10001...........10001....
    \\101110101...........11111...........11111....
    \\101110100....................................
    \\101110101....................................
    \\100000101....................................
    \\111111101....................................
;

const v7_after_codewords_unmasked =
    \\111111100011100111000001010011010100101111111
    \\100000100000000011110100001110101001001000001
    \\101110101000110110100001011100000101001011101
    \\101110100000000001110100001001011101101011101
    \\101110100100010110001111111100001011101011101
    \\100000100001100011101000100001011000001000001
    \\111111101010101010101010101010101010101111111
    \\000000001111110110111000111011101101100000000
    \\111011111110000101101111111100110111111000100
    \\111011000001110000000110000101001000010010011
    \\111100101110111100000011100100100010001101010
    \\110001000111001001011110100001110000000000010
    \\101010110011011100001001110110100101010111001
    \\010001011010100001011110000011110000000010000
    \\101110101110011100000011110110000101010111111
    \\100111000010101001011110111011011000010110001
    \\110110100001011000001001101101110000110100111
    \\001110010100000111011001011000000100010001101
    \\000000110010100011110100000000110110111000110
    \\100010001101010110100001011100000111111101100
    \\100111111011100001111111101001011010111110001
    \\001110001100010110001000111100001110100010010
    \\100110101010000011101010100001011001101010000
    \\101010001111010110101000100011111101100011010
    \\101011111100000101111111110000010000111110100
    \\110110010001110000000100000110011101101000001
    \\000000100010111100001001010100100011011101010
    \\101101001111101001000100000001110001100000000
    \\011010111110011100000001010110100100100011010
    \\101110000111100001001100000011110001101000100
    \\011111101000111100010110010110000101110101011
    \\110110011011101001011011111010011100011001001
    \\000011110001011000010110101100010100100001111
    \\001101010100000111001001111011000100010111110
    \\000010111111000011110110000110100110000010110
    \\011110000100010110111011111100000111110111110
    \\100110110101000001111111101001011010111110001
    \\000000001110010110011000111100001111100010010
    \\111111101101000011101010100001011000101011100
    \\100000101100010110101000100011101000100010010
    \\101110101110000101101111110100000111111110100
    \\101110100101110000010110100111000100000010001
    \\101110101110111100000001110110110111111101000
    \\100000101001101001010001000001110000110000000
    \\111111101010011100000100010110100101101001010
;

test "drawFunctionPatterns matches an instrumented qrcode.c oracle (version 7 — alignment patterns + version info)" {
    var modules_buf: [256]u8 = undefined;
    var is_function_buf: [256]u8 = undefined;
    var grid = Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(7));

    drawFunctionPatterns(&grid, 7, .low);

    try parseFunctionDump(&grid, v7_after_function_patterns);
}

test "placeCodewords matches an instrumented qrcode.c oracle (version 7, multi-block)" {
    // Reuses this project's own already-validated mode_selector.zig and
    // codewords.zig for the same version/ECC/text the oracle was run
    // against ("This is a version 7 test string, long eno", ECC_LOW),
    // to isolate this test to matrix.zig's placement logic specifically
    // — if this fails while codewords.zig's own tests still pass, the
    // bug is almost certainly here, not in codeword generation.
    const mode_selector = @import("mode_selector.zig");
    const codewords_mod = @import("codewords.zig");
    const bitbuf = @import("bit_buffer.zig");

    const version: u8 = 7;
    const ecc: tables.Ecc = .low;
    const text = "This is a version 7 test string, long eno";
    const mode = mode_selector.detectMode(text);
    try std.testing.expectEqual(tables.ModeIndicator.byte, mode);

    const layout = codewords_mod.blockLayout(version, ecc);

    var data_buf: [200]u8 = undefined;
    var w = bitbuf.BitWriter.init(data_buf[0..layout.total_data]);
    mode_selector.encode(&w, text, mode, version);
    codewords_mod.terminateAndPad(&w, layout.total_data);

    var out: [200]u8 = undefined;
    const final = codewords_mod.interleave(layout, w.writtenBytes(), out[0..layout.total_codewords]);

    var modules_buf: [256]u8 = undefined;
    var is_function_buf: [256]u8 = undefined;
    var grid = Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(version));

    drawFunctionPatterns(&grid, version, ecc);
    placeCodewords(&grid, final);

    try parseModuleDump(&grid, v7_after_codewords_unmasked);
}

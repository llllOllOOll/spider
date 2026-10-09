//! Internal: data masking (ISO/IEC 18004:2015 7.8): the 8 mask patterns
//! (Table 10), the 4 penalty rules used to score a masked symbol (Table
//! 11), and picking the mask with the lowest score.

const std = @import("std");
const matrix = @import("matrix.zig");
const bch = @import("bch.zig");
const tables = @import("tables.zig");

/// ISO Table 10. `i` = row, `j` = column — matches the spec's own
/// variable names, confirmed directly against the printed table rather
/// than taken from a reference implementation's variable order.
pub fn maskCondition(mask: u3, i: u16, j: u16) bool {
    return switch (mask) {
        0 => (i + j) % 2 == 0,
        1 => i % 2 == 0,
        2 => j % 3 == 0,
        3 => (i + j) % 3 == 0,
        4 => (i / 2 + j / 3) % 2 == 0,
        5 => (i * j) % 2 + (i * j) % 3 == 0,
        6 => ((i * j) % 2 + (i * j) % 3) % 2 == 0,
        7 => ((i + j) % 2 + (i * j) % 3) % 2 == 0,
    };
}

/// ISO 7.8.1: XORs every non-function module with the mask condition.
/// Applying the same mask twice is a no-op (XOR is its own inverse),
/// which is how masking.zig evaluates a candidate mask non-destructively
/// during selection: apply, score, apply again to undo.
pub fn applyMask(grid: *matrix.Grid, mask: u3) void {
    var y: u16 = 0;
    while (y < grid.size) : (y += 1) {
        var x: u16 = 0;
        while (x < grid.size) : (x += 1) {
            if (grid.isFunction(x, y)) continue;
            if (maskCondition(mask, y, x)) grid.invertModule(x, y);
        }
    }
}

/// ISO Table 11 penalty weights.
const n1_base: u32 = 3;
const n2: u32 = 3;
const n3: u32 = 40;
const n4: u32 = 10;

/// Rule 1: 5+ adjacent same-color modules in a row or column.
/// NOTE 1's worked example (a 7-module run scores 5, not 3+4) means the
/// penalty is a single charge per run — N1 for reaching 5, +1 per
/// module beyond that — not cumulative over sliding sub-windows.
fn runPenalty(grid: *matrix.Grid, size: u16, comptime rowMajor: bool) u32 {
    var total: u32 = 0;
    var a: u16 = 0;
    while (a < size) : (a += 1) {
        var run_len: u32 = 1;
        var prev = if (rowMajor) grid.getModule(0, a) else grid.getModule(a, 0);
        var b: u16 = 1;
        while (b < size) : (b += 1) {
            const cur = if (rowMajor) grid.getModule(b, a) else grid.getModule(a, b);
            if (cur == prev) {
                run_len += 1;
            } else {
                if (run_len >= 5) total += n1_base + (run_len - 5);
                run_len = 1;
                prev = cur;
            }
        }
        if (run_len >= 5) total += n1_base + (run_len - 5);
    }
    return total;
}

/// Rule 2: every 2x2 window (overlapping, not tiled — ISO Table 11
/// NOTE 2's worked example counts a 3x3 dark block as 4 overlapping 2x2
/// blocks, 12 points) of uniform color scores N2.
fn blockPenalty(grid: *matrix.Grid, size: u16) u32 {
    var total: u32 = 0;
    var y: u16 = 0;
    while (y + 1 < size) : (y += 1) {
        var x: u16 = 0;
        while (x + 1 < size) : (x += 1) {
            const a = grid.getModule(x, y);
            if (grid.getModule(x + 1, y) == a and
                grid.getModule(x, y + 1) == a and
                grid.getModule(x + 1, y + 1) == a)
            {
                total += n2;
            }
        }
    }
    return total;
}

/// Rule 3: the finder-pattern-like ratio 1:1:3:1:1 (dark:light:dark:
/// dark:dark:light:dark — i.e. 10111 as a run-length pattern), when
/// immediately preceded or followed by a 4-module-wide light run,
/// scores N3. Checked as an 11-bit sliding window per row and per
/// column: 00001011101 (light-then-pattern) or 10111010000
/// (pattern-then-light) — the two ways a 4-wide light run can sit next
/// to the 7-module dark:light:dark:dark:dark:light:dark shape.
fn finderLikePenalty(grid: *matrix.Grid, size: u16, comptime rowMajor: bool) u32 {
    const pattern_a: u16 = 0b0000_1011101; // light x4, then the ratio pattern
    const pattern_b: u16 = 0b1011101_0000; // the ratio pattern, then light x4
    var total: u32 = 0;

    var a: u16 = 0;
    while (a < size) : (a += 1) {
        var window: u16 = 0;
        var b: u16 = 0;
        while (b < size) : (b += 1) {
            const dark = if (rowMajor) grid.getModule(b, a) else grid.getModule(a, b);
            window = ((window << 1) | @as(u16, @intFromBool(dark))) & 0x7FF;
            if (b >= 10 and (window == pattern_a or window == pattern_b)) total += n3;
        }
    }
    return total;
}

/// Rule 4: proportion of dark modules, penalized in 5%-deviation steps
/// away from the 45%-55% band centered on 50%.
fn darkProportionPenalty(grid: *matrix.Grid, size: u16) u32 {
    var dark: u32 = 0;
    var y: u16 = 0;
    while (y < size) : (y += 1) {
        var x: u16 = 0;
        while (x < size) : (x += 1) {
            if (grid.getModule(x, y)) dark += 1;
        }
    }
    const total: u32 = @as(u32, size) * size;

    var k: u32 = 0;
    while (dark * 20 < (9 -| k) * total or dark * 20 > (11 + k) * total) : (k += 1) {}
    return n4 * k;
}

pub fn penaltyScore(grid: *matrix.Grid) u32 {
    const size = grid.size;
    return runPenalty(grid, size, true) +
        runPenalty(grid, size, false) +
        blockPenalty(grid, size) +
        finderLikePenalty(grid, size, true) +
        finderLikePenalty(grid, size, false) +
        darkProportionPenalty(grid, size);
}

/// Tries all 8 masks (drawing the real format info for each candidate
/// so the format-info cells are correctly included in scoring — they
/// are function modules and never masked themselves, but their
/// bit-value contributes to the dark/light patterns rule 1-4 look at),
/// picks the one with the lowest penalty score, and leaves the grid
/// with that mask applied and the real (non-placeholder) format info
/// drawn. Returns the chosen mask.
pub fn selectAndApplyBestMask(grid: *matrix.Grid, ecc: tables.Ecc) u3 {
    var best_mask: u3 = 0;
    var best_penalty: u32 = std.math.maxInt(u32);

    var mask: u3 = 0;
    while (true) {
        matrix.drawFormatInfo(grid, bch.formatBits(ecc, mask));
        applyMask(grid, mask);
        const penalty = penaltyScore(grid);
        if (penalty < best_penalty) {
            best_penalty = penalty;
            best_mask = mask;
        }
        applyMask(grid, mask); // undo (XOR is its own inverse)

        if (mask == 7) break;
        mask += 1;
    }

    matrix.drawFormatInfo(grid, bch.formatBits(ecc, best_mask));
    applyMask(grid, best_mask);
    return best_mask;
}

// --- Tests -----------------------------------------------------------
//
// Ground truth extracted the same way as matrix.zig's: instrumenting a
// scratch copy of the vendored reference C (untouched original at
// ~/repos/zig/web/QRCode.zig/src/raw/qrcode.c) with two fprintf calls
// inside its mask-selection loop (one per candidate mask, dumping the
// penalty score; one after the loop, dumping the chosen mask), plus the
// final masked module grid via its normal public getModule API. Same
// two fixtures as matrix.zig: version 1 "HELLO WORLD" (ECC M) and
// version 7 "This is a version 7 test string, long eno" (ECC L).

const mode_selector = @import("mode_selector.zig");
const codewords_mod = @import("codewords.zig");
const bitbuf = @import("bit_buffer.zig");

fn buildGrid(grid: *matrix.Grid, version: u8, ecc: tables.Ecc, text: []const u8) []const u8 {
    const mode = mode_selector.detectMode(text);
    const layout = codewords_mod.blockLayout(version, ecc);

    const S = struct {
        var data_buf: [200]u8 = undefined;
        var out_buf: [200]u8 = undefined;
    };

    var w = bitbuf.BitWriter.init(S.data_buf[0..layout.total_data]);
    mode_selector.encode(&w, text, mode, version);
    codewords_mod.terminateAndPad(&w, layout.total_data);

    const final = codewords_mod.interleave(layout, w.writtenBytes(), S.out_buf[0..layout.total_codewords]);

    matrix.drawFunctionPatterns(grid, version, ecc);
    matrix.placeCodewords(grid, final);
    return final;
}

fn parseModuleDump(grid: *matrix.Grid, dump: []const u8) !void {
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

test "penaltyScore matches an instrumented qrcode.c oracle for all 8 masks (version 1, HELLO WORLD)" {
    const expected_scores = [8]u32{ 311, 406, 442, 463, 367, 528, 395, 445 };

    var modules_buf: [64]u8 = undefined;
    var is_function_buf: [64]u8 = undefined;
    var grid = matrix.Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(1));
    _ = buildGrid(&grid, 1, .medium, "HELLO WORLD");

    var mask: u3 = 0;
    while (true) {
        matrix.drawFormatInfo(&grid, bch.formatBits(.medium, mask));
        applyMask(&grid, mask);
        try std.testing.expectEqual(expected_scores[mask], penaltyScore(&grid));
        applyMask(&grid, mask);

        if (mask == 7) break;
        mask += 1;
    }
}

test "penaltyScore matches an instrumented qrcode.c oracle for all 8 masks (version 7, multi-block)" {
    const expected_scores = [8]u32{ 1385, 1770, 1014, 1244, 1159, 1672, 1580, 1453 };

    var modules_buf: [256]u8 = undefined;
    var is_function_buf: [256]u8 = undefined;
    var grid = matrix.Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(7));
    _ = buildGrid(&grid, 7, .low, "This is a version 7 test string, long eno");

    var mask: u3 = 0;
    while (true) {
        matrix.drawFormatInfo(&grid, bch.formatBits(.low, mask));
        applyMask(&grid, mask);
        try std.testing.expectEqual(expected_scores[mask], penaltyScore(&grid));
        applyMask(&grid, mask);

        if (mask == 7) break;
        mask += 1;
    }
}

const v1_final_masked =
    \\111111100010101111111
    \\100000101110001000001
    \\101110100010101011101
    \\101110100010101011101
    \\101110101011101011101
    \\100000100111001000001
    \\111111101010101111111
    \\000000000000000000000
    \\101010100100100010010
    \\011110001001000010001
    \\000111111101001011000
    \\111101011001110101110
    \\010011110101001110101
    \\000000001010001000101
    \\111111100000100101100
    \\100000100110001101000
    \\101110101100101111111
    \\101110100011010100010
    \\101110101111011101001
    \\100000100001110001011
    \\111111101101011100001
;

test "selectAndApplyBestMask matches an instrumented qrcode.c oracle end to end (version 1, HELLO WORLD)" {
    var modules_buf: [64]u8 = undefined;
    var is_function_buf: [64]u8 = undefined;
    var grid = matrix.Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(1));
    _ = buildGrid(&grid, 1, .medium, "HELLO WORLD");

    const chosen = selectAndApplyBestMask(&grid, .medium);
    try std.testing.expectEqual(@as(u3, 0), chosen);
    try parseModuleDump(&grid, v1_final_masked);
}

const v7_final_masked =
    \\111111100111000011100101110111110000101111111
    \\100000101100100111010000101010001101001000001
    \\101110100100010010000101111000100001001011101
    \\101110101100100101010000101101111001101011101
    \\101110100000110010101111111000101111101011101
    \\100000101101000111001000100101111100001000001
    \\111111101010101010101010101010101010101111111
    \\000000000011010010011000111111001001000000000
    \\111110111010100001001111111000010011010101010
    \\011111000101010100100010100001101100110110111
    \\011000101010011000100111000000000110101001110
    \\010101000011101101111010000101010100100100110
    \\001110110111111000101101010010000001110011101
    \\110101011110000101111010100111010100100110100
    \\001010101010111000100111010010100001110011011
    \\000011000110001101111010011111111100110010101
    \\010010100101111100101101001001010100010000011
    \\101010010000100011111101111100100000110101001
    \\100100110110000111010000100100010010011100010
    \\000110001001110010000101111000100011011001000
    \\000011111111000101011111101101111110111110101
    \\101010001000110010101000111000101010100010110
    \\000010101110100111001010100101111101101010100
    \\001110001011110010001000100111011001100011110
    \\001111111000100001011111110100110100111110000
    \\010010010101010100100000100010111001001100101
    \\100100100110011000101101110000000111111001110
    \\001001001011001101100000100101010101000100100
    \\111110111010111000100101110010000000000111110
    \\001010000011000101101000100111010101001100000
    \\111011101100011000110010110010100001010001111
    \\010010011111001101111111011110111000111101101
    \\100111110101111100110010001000110000000101011
    \\101001010000100011101101011111100000110011010
    \\000010111011100111010010100010000010100110010
    \\011110000000110010011111011000100011010011010
    \\100110110001100101011111101101111110111110101
    \\000000001010110010111000111000101011100010110
    \\111111101001100111001010100101111100101011000
    \\100000100000110010001000100111001100100010110
    \\101110101010100001001111110000100011111110000
    \\101110101001010100110010000011100000100110101
    \\101110101010011000100101010010010011011001100
    \\100000101101001101110101100101010100010100100
    \\111111101110111000100000110010000001001101110
;

test "selectAndApplyBestMask matches an instrumented qrcode.c oracle end to end (version 7, multi-block)" {
    var modules_buf: [256]u8 = undefined;
    var is_function_buf: [256]u8 = undefined;
    var grid = matrix.Grid.init(&modules_buf, &is_function_buf, tables.symbolSize(7));
    _ = buildGrid(&grid, 7, .low, "This is a version 7 test string, long eno");

    const chosen = selectAndApplyBestMask(&grid, .low);
    try std.testing.expectEqual(@as(u3, 2), chosen);
    try parseModuleDump(&grid, v7_final_masked);
}

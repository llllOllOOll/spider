//! Internal: assembles the final codeword sequence for a symbol: capacity /
//! block-size bookkeeping (ISO Table 9 derived from tables.zig), terminator
//! + padding (ISO 7.4.9/7.4.10), per-block Reed-Solomon error correction
//! (reed_solomon.zig), and interleaving into the single sequence that gets
//! placed into the matrix (ISO 7.6).

const std = @import("std");
const tables = @import("tables.zig");
const bitbuf = @import("bit_buffer.zig");
const rs = @import("reed_solomon.zig");

/// Every version/ECC combination that has more than one block splits
/// data codewords into two group sizes at most (ISO 7.5.2 / Table 9):
/// `num_short_blocks` blocks of `short_data_len` data codewords, and
/// `num_long_blocks` blocks of `short_data_len + 1`. Every block —
/// short or long — carries the same number of ECC codewords, `ecc_len`.
pub const BlockLayout = struct {
    num_blocks: u8,
    num_short_blocks: u8,
    num_long_blocks: u8,
    short_data_len: u16,
    ecc_len: u8,
    total_data: u16,
    total_codewords: u16,
};

/// Maximum number of blocks across every version/ECC combination is 81
/// (version 40, level H) — used to size fixed on-stack bookkeeping
/// arrays in interleave() below.
const max_blocks = 128;
/// Largest ecc_codewords_per_block value in tables.zig is 30.
const max_ecc_len = 30;

pub fn blockLayout(version: u8, ecc: tables.Ecc) BlockLayout {
    const ei = @intFromEnum(ecc);
    const num_blocks = tables.num_error_correction_blocks[ei][version];
    const ecc_len: u8 = @intCast(tables.ecc_codewords_per_block[ei][version]);
    const total_codewords: u16 = tables.numRawDataModules(version) / 8;
    const total_ecc: u16 = @as(u16, ecc_len) * num_blocks;
    const total_data: u16 = total_codewords - total_ecc;

    const short_data_len = total_data / num_blocks;
    const num_long_blocks: u8 = @intCast(total_data % num_blocks);
    const num_short_blocks = num_blocks - num_long_blocks;

    return .{
        .num_blocks = num_blocks,
        .num_short_blocks = num_short_blocks,
        .num_long_blocks = num_long_blocks,
        .short_data_len = short_data_len,
        .ecc_len = ecc_len,
        .total_data = total_data,
        .total_codewords = total_codewords,
    };
}

/// Appends the terminator (ISO 7.4.9: up to 4 zero bits, fewer if the
/// remaining capacity is smaller), pads to the next byte boundary with
/// zero bits, then fills the rest of `total_data_bytes` with the
/// alternating pad codewords 0xEC, 0x11 (ISO 7.4.10).
pub fn terminateAndPad(writer: *bitbuf.BitWriter, total_data_bytes: usize) void {
    const capacity_bits = total_data_bytes * 8;
    const remaining = capacity_bits - writer.bitLen();
    const terminator_len: u6 = @intCast(@min(4, remaining));
    writer.appendBits(0, terminator_len);

    const rem8 = writer.bitLen() % 8;
    if (rem8 != 0) writer.appendBits(0, @intCast(8 - rem8));

    var pad_byte: u8 = 0xEC;
    while (writer.byteLen() < total_data_bytes) {
        writer.appendBits(pad_byte, 8);
        pad_byte = if (pad_byte == 0xEC) 0x11 else 0xEC;
    }
}

/// Splits `data` (exactly `layout.total_data` bytes) into blocks per
/// `layout`, computes each block's Reed-Solomon ECC codewords, and
/// writes the interleaved final codeword sequence (ISO 7.6: data
/// codewords round-robined across blocks in index order — short blocks
/// drop out once exhausted — followed by ECC codewords round-robined
/// the same way) into `out`. `out` must have room for at least
/// `layout.total_codewords` bytes. Returns the written prefix of `out`.
pub fn interleave(layout: BlockLayout, data: []const u8, out: []u8) []const u8 {
    std.debug.assert(data.len == layout.total_data);
    std.debug.assert(out.len >= layout.total_codewords);
    std.debug.assert(layout.num_blocks <= max_blocks);
    std.debug.assert(layout.ecc_len <= max_ecc_len);

    var block_starts: [max_blocks]usize = undefined;
    var block_lens: [max_blocks]u16 = undefined;
    var block_ecc: [max_blocks][max_ecc_len]u8 = undefined;

    var gen: [max_ecc_len]u8 = undefined;
    const gen_slice = gen[0..layout.ecc_len];
    rs.generatorPolynomial(layout.ecc_len, gen_slice);

    var offset: usize = 0;
    var b: usize = 0;
    while (b < layout.num_blocks) : (b += 1) {
        const len: u16 = if (b < layout.num_short_blocks) layout.short_data_len else layout.short_data_len + 1;
        block_starts[b] = offset;
        block_lens[b] = len;
        rs.computeRemainder(data[offset .. offset + len], gen_slice, block_ecc[b][0..layout.ecc_len]);
        offset += len;
    }
    std.debug.assert(offset == layout.total_data);

    var out_pos: usize = 0;
    const max_data_len = layout.short_data_len + 1;

    var i: u16 = 0;
    while (i < max_data_len) : (i += 1) {
        b = 0;
        while (b < layout.num_blocks) : (b += 1) {
            if (i < block_lens[b]) {
                out[out_pos] = data[block_starts[b] + i];
                out_pos += 1;
            }
        }
    }

    i = 0;
    while (i < layout.ecc_len) : (i += 1) {
        b = 0;
        while (b < layout.num_blocks) : (b += 1) {
            out[out_pos] = block_ecc[b][i];
            out_pos += 1;
        }
    }

    std.debug.assert(out_pos == layout.total_codewords);
    return out[0..out_pos];
}

test "blockLayout matches the HELLO WORLD version-1M fixture dimensions" {
    const layout = blockLayout(1, .medium);
    try std.testing.expectEqual(@as(u8, 1), layout.num_blocks);
    try std.testing.expectEqual(@as(u8, 10), layout.ecc_len);
    try std.testing.expectEqual(@as(u16, 16), layout.total_data);
    try std.testing.expectEqual(@as(u16, 26), layout.total_codewords);
}

test "blockLayout short/long block split is internally consistent for every version and ECC level" {
    // Exhaustive property check across all 160 version x ECC-level
    // combinations, rather than a hand-verified spot check of one
    // table cell: the split must always partition total_data exactly,
    // and total codewords must always be data + (ecc_len * num_blocks).
    var version: u8 = 1;
    while (version <= 40) : (version += 1) {
        for ([_]tables.Ecc{ .low, .medium, .quartile, .high }) |ecc| {
            const layout = blockLayout(version, ecc);

            try std.testing.expectEqual(
                layout.num_blocks,
                layout.num_short_blocks + layout.num_long_blocks,
            );

            const reconstructed_data: u32 =
                @as(u32, layout.num_short_blocks) * layout.short_data_len +
                @as(u32, layout.num_long_blocks) * (layout.short_data_len + 1);
            try std.testing.expectEqual(@as(u32, layout.total_data), reconstructed_data);

            const reconstructed_total: u32 = @as(u32, layout.total_data) +
                @as(u32, layout.ecc_len) * layout.num_blocks;
            try std.testing.expectEqual(@as(u32, layout.total_codewords), reconstructed_total);
        }
    }
}

test "full pipeline: HELLO WORLD version-1M reproduces the complete 26-byte fixture" {
    const mode_selector = @import("mode_selector.zig");

    const version: u8 = 1;
    const layout = blockLayout(version, .medium);

    var data_buf: [16]u8 = undefined;
    var w = bitbuf.BitWriter.init(&data_buf);
    mode_selector.encode(&w, "HELLO WORLD", .alphanumeric, version);
    terminateAndPad(&w, layout.total_data);

    // Same 16 bytes reed_solomon.zig and mode_selector.zig each already
    // validated independently — confirms terminateAndPad is a no-op on
    // top of what mode_selector already wrote for this exact input
    // (74 data bits + 4 terminator + 2 alignment = 80 bits = 10 bytes,
    // then 6 pad codewords to reach the 16-byte data capacity).
    try std.testing.expectEqualSlices(
        u8,
        &.{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 },
        w.writtenBytes(),
    );

    var out: [26]u8 = undefined;
    const final = interleave(layout, w.writtenBytes(), &out);

    const expected_final = [_]u8{
        32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236,
        17, 236, 17, // data codewords (single block, so unchanged by interleaving)
        196, 35, 39, 119, 235, 215, 231, 226, 93, 23, // ECC codewords, validated in reed_solomon.zig
    };
    try std.testing.expectEqualSlices(u8, &expected_final, final);
}

test "full pipeline: version-5 quartile (4 blocks, 2 short + 2 long) matches an instrumented qrcode.c oracle" {
    // The HELLO WORLD fixture above is version 1, a single block — it
    // never exercises interleave()'s round-robin across multiple blocks
    // of different lengths (short blocks dropping out once exhausted).
    // This fixture closes that gap.
    //
    // Ground truth was extracted by instrumenting a scratch copy of the
    // vendored reference C (~/repos/zig/web/QRCode.zig/src/raw/qrcode.c,
    // itself untouched — only a throwaway copy in scratchpad was edited)
    // with two printf calls: one dumping `codewords.data` right before
    // performErrorCorrection() (the padded data codewords), one right
    // after (the final interleaved sequence), for:
    //   version=5, ecc=ECC_QUARTILE, text="The quick brown fox jumps 123!"
    // which the reference auto-detected as byte mode (matches this
    // project's detectMode() for the same input — it contains lowercase
    // letters, which are outside both the numeric and alphanumeric
    // character sets).
    //
    // Version 5 needs 7 "remainder bits" per ISO 7.4.10 (most versions
    // need 0; a handful need 3, 4, or 7) — the reference's output buffer
    // is 135 bytes because of this, but the 135th byte is entirely that
    // remainder-bit padding, not a real codeword (it printed as 0, and
    // remainder bits are placement-time zero-fill that belongs to
    // matrix.zig, not to the codeword sequence itself). Only the first
    // 134 bytes — matching this module's own total_codewords — are used
    // as the fixture.
    const mode_selector = @import("mode_selector.zig");

    const version: u8 = 5;
    const ecc: tables.Ecc = .quartile;
    const text = "The quick brown fox jumps 123!";
    const mode = mode_selector.detectMode(text);
    try std.testing.expectEqual(tables.ModeIndicator.byte, mode);

    const layout = blockLayout(version, ecc);
    try std.testing.expectEqual(@as(u8, 4), layout.num_blocks);
    try std.testing.expectEqual(@as(u8, 2), layout.num_short_blocks);
    try std.testing.expectEqual(@as(u8, 2), layout.num_long_blocks);
    try std.testing.expectEqual(@as(u16, 15), layout.short_data_len);
    try std.testing.expectEqual(@as(u8, 18), layout.ecc_len);
    try std.testing.expectEqual(@as(u16, 62), layout.total_data);
    try std.testing.expectEqual(@as(u16, 134), layout.total_codewords);

    var data_buf: [62]u8 = undefined;
    var w = bitbuf.BitWriter.init(&data_buf);
    mode_selector.encode(&w, text, mode, version);
    terminateAndPad(&w, layout.total_data);

    const expected_padded_data = [_]u8{
        65,  229, 70,  134, 82,  7,   23,  86,  150, 54,  178, 6,   39,
        38,  247, 118, 226, 6,   102, 247, 130, 6,   167, 86,  215, 7,
        50,  3,   19,  35,  50,  16,  236, 17,  236, 17,  236, 17,  236,
        17,  236, 17,  236, 17,  236, 17,  236, 17,  236, 17,  236, 17,
        236, 17,  236, 17,  236, 17,  236, 17,  236, 17,
    };
    try std.testing.expectEqualSlices(u8, &expected_padded_data, w.writtenBytes());

    var out: [134]u8 = undefined;
    const final = interleave(layout, w.writtenBytes(), &out);

    const expected_final = [_]u8{
        65,  118, 50, 236, 229, 226, 16,  17, 70,  6,   236, 236, 134,
        102, 17,  17, 82,  247, 236, 236, 7,  130, 17,  17,  23,  6,
        236, 236, 86, 167, 17,  17,  150, 86, 236, 236, 54,  215, 17,
        17,  178, 7,  236, 236, 6,   50,  17, 17,  39,  3,   236, 236,
        38,  19,  17,  17,  247, 35,  236, 236, 17,  17, // end of interleaved data codewords
        116, 152, 88,  253, 169, 181, 41,  208, 117, 36,
        148, 208, 177, 76,  45,  222, 1,   143, 54,  148,
        1,   103, 106, 37,  11,  22,  156, 141, 8,   210,
        144, 130, 212, 36,  10,  227, 167, 35,  112, 48,
        243, 75,  244, 182, 217, 161, 207, 241, 52,  144,
        19,  103, 119, 181, 58,  253, 30,  161, 203, 37,
        77,  253, 245, 13,  226,
        233, 166, 171, 35, 179, 183, 16, // end of interleaved ECC codewords
    };
    try std.testing.expectEqualSlices(u8, &expected_final, final);
}

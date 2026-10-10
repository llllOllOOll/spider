//! Public API — a 100% Zig, from-spec (ISO/IEC 18004:2015) QR Code
//! encoder. No vendored C, no ported code: every module here was
//! written from the spec text and cross-validated against it (and, for
//! the geometrically fiddly parts, against an instrumented reference
//! oracle) — see each submodule's doc comment for what was verified
//! and how.
//!
//! Scope: QR Code versions 1-40, all 4 error correction levels
//! (L/M/Q/H), Numeric/Alphanumeric/Byte modes. Kanji mode and Micro QR
//! are out of scope (see project scope notes).

const std = @import("std");

// internal: ISO constants; reexported for the tests.
pub const tables = @import("tables.zig");
// internal: the bit writer; reexported for the tests.
pub const bit_buffer = @import("bit_buffer.zig");
// internal: GF(2^8) arithmetic; reexported for the tests.
pub const galois_field = @import("galois_field.zig");
// internal: error correction codewords; reexported for the tests.
pub const reed_solomon = @import("reed_solomon.zig");
// internal: mode detection and segment encoding; reexported for the tests.
pub const mode_selector = @import("mode_selector.zig");
// internal: codeword assembly; reexported for the tests.
pub const codewords = @import("codewords.zig");
// internal: format and version information; reexported for the tests.
pub const bch = @import("bch.zig");
// internal: the module grid; reexported for the tests.
pub const matrix = @import("matrix.zig");
// internal: mask patterns and scoring; reexported for the tests.
pub const masking = @import("masking.zig");

/// The error correction level: how much of a damaged or covered symbol a
/// scanner can still recover. `.low` (about 7%), `.medium` (15%),
/// `.quartile` (25%), `.high` (30%). A higher level leaves less room for
/// data in the same version.
pub const Ecc = tables.Ecc;

/// An encoded QR Code: a square of `size` x `size` modules, read with
/// `getModule`. Drawing it (SVG, PNG, table cells) is up to the app.
///
/// ```zig
/// var qr = try spider.qrcode.QR.encode(allocator, "HELLO WORLD", 1, .medium);
/// defer qr.deinit();
/// // qr.size == 21; qr.getModule(x, y) is true for a dark module
/// ```
///
/// `encode` takes the version; `encodeAuto` picks the smallest one the
/// text fits in.
pub const QR = struct {
    /// The allocator given to `encode`; `deinit` frees with it.
    allocator: std.mem.Allocator,
    /// The version asked for, 1 to 40.
    version: u8,
    /// The error correction level asked for.
    ecc: Ecc,
    /// The mask pattern (0 to 7) the encoder chose.
    mask: u3,
    /// Modules per side: `version * 4 + 17` (21 for version 1, 177 for version 40).
    size: u16,
    /// The modules, one bit each, row by row, most significant bit first.
    /// Read them with `getModule`.
    modules: []u8,

    /// Encodes `text` as a QR Code of the given `version` (1-40) and
    /// error correction level. Picks the tightest applicable mode
    /// (numeric/alphanumeric/byte) automatically, one mode for the whole
    /// text; in byte mode the bytes are stored as given.
    ///
    /// The result owns its modules, allocated with `allocator`: free it
    /// with `deinit`. Returns `error.DataTooLarge` if `text` does not fit
    /// the data capacity of that version and level, `error.InvalidVersion`
    /// for a `version` outside 1-40, or `error.OutOfMemory`.
    pub fn encode(allocator: std.mem.Allocator, text: []const u8, version: u8, ecc: Ecc) !QR {
        if (version < 1 or version > 40) return error.InvalidVersion;

        const mode = mode_selector.detectMode(text);
        const layout = codewords.blockLayout(version, ecc);

        // Sized generously enough that mode_selector.encode can never
        // overrun the buffer (which would trip BitWriter's internal
        // safety assert) even for input that turns out too large for
        // this version/ECC — checked properly below, before padding.
        const max_possible_bits = 4 + 16 + @as(usize, text.len) * 8;
        const data_cap = @max((max_possible_bits + 7) / 8, layout.total_data);

        const data_buf = try allocator.alloc(u8, data_cap);
        defer allocator.free(data_buf);

        var w = bit_buffer.BitWriter.init(data_buf);
        mode_selector.encode(&w, text, mode, version);

        if (w.bitLen() > @as(usize, layout.total_data) * 8) return error.DataTooLarge;

        codewords.terminateAndPad(&w, layout.total_data);

        const final_buf = try allocator.alloc(u8, layout.total_codewords);
        defer allocator.free(final_buf);
        const final = codewords.interleave(layout, w.writtenBytes(), final_buf);

        const size = tables.symbolSize(version);
        const modules = try allocator.alloc(u8, matrix.Grid.byteCount(size));
        errdefer allocator.free(modules);

        const is_function_buf = try allocator.alloc(u8, matrix.Grid.byteCount(size));
        defer allocator.free(is_function_buf);

        var grid = matrix.Grid.init(modules, is_function_buf, size);
        matrix.drawFunctionPatterns(&grid, version, ecc);
        matrix.placeCodewords(&grid, final);
        const mask = masking.selectAndApplyBestMask(&grid, ecc);

        return QR{
            .allocator = allocator,
            .version = version,
            .ecc = ecc,
            .mask = mask,
            .size = size,
            .modules = modules,
        };
    }

    /// `encode` with the smallest version (1 to 40) that holds `text` at
    /// this error correction level. `error.DataTooLarge` when not even
    /// version 40 does.
    ///
    /// ```zig
    /// var qr = try spider.qrcode.QR.encodeAuto(c.arena, link, .medium);
    /// ```
    pub fn encodeAuto(allocator: std.mem.Allocator, text: []const u8, ecc: Ecc) !QR {
        var version: u8 = 1;
        while (version <= 40) : (version += 1) {
            return encode(allocator, text, version, ecc) catch |err| switch (err) {
                error.DataTooLarge => continue,
                else => return err,
            };
        }
        return error.DataTooLarge;
    }

    /// Frees the modules.
    pub fn deinit(self: QR) void {
        self.allocator.free(self.modules);
    }

    /// True if the module at (x, y) is dark. Out-of-range coordinates
    /// return false (matches matrix.Grid.getModule's convention).
    pub fn getModule(self: QR, x: u16, y: u16) bool {
        if (x >= self.size or y >= self.size) return false;
        const index: usize = @as(usize, y) * self.size + x;
        const bit_mask: u8 = @as(u8, 1) << @intCast(7 - (index % 8));
        return (self.modules[index / 8] & bit_mask) != 0;
    }
};

test "QR.encode HELLO WORLD (version 1, ECC M) matches the oracle-validated fixture end to end" {
    var qr = try QR.encode(std.testing.allocator, "HELLO WORLD", 1, .medium);
    defer qr.deinit();

    try std.testing.expectEqual(@as(u8, 1), qr.version);
    try std.testing.expectEqual(@as(u16, 21), qr.size);
    try std.testing.expectEqual(@as(u3, 0), qr.mask); // cross-checked in masking.zig's oracle test

    // Same final masked grid masking.zig's own test validated against
    // qrcode.c, exercised here through the public API instead of the
    // internal Grid type.
    const expected =
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
    var y: u16 = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        for (line, 0..) |c, x| {
            try std.testing.expectEqual(c == '1', qr.getModule(@intCast(x), y));
        }
        y += 1;
    }
}

test "QR.encode returns error.DataTooLarge instead of overflowing, unlike the reference C" {
    // Version 1-L's capacity is 17 bytes of byte-mode data (ISO Table
    // 7); this text is far longer than that at any mode.
    const too_long = "this string is definitely too long to fit in a version 1 QR code no matter the mode";
    try std.testing.expectError(
        error.DataTooLarge,
        QR.encode(std.testing.allocator, too_long, 1, .low),
    );
}

test "QR.encode frees everything it allocates (no leaks under std.testing.allocator)" {
    var qr = try QR.encode(std.testing.allocator, "12345", 2, .quartile);
    defer qr.deinit();
    try std.testing.expectEqual(@as(u8, 2), qr.version);
}

test {
    std.testing.refAllDecls(@This());
}

test "QR.encode: a version that does not exist is an error, not a stop" {
    try std.testing.expectError(error.InvalidVersion, QR.encode(std.testing.allocator, "HELLO", 0, .medium));
    try std.testing.expectError(error.InvalidVersion, QR.encode(std.testing.allocator, "HELLO", 41, .medium));
}

test "QR.encodeAuto: the smallest version the text fits in" {
    const a = std.testing.allocator;
    var small = try QR.encodeAuto(a, "HELLO WORLD", .medium);
    defer small.deinit();
    try std.testing.expectEqual(@as(u8, 1), small.version);
    try std.testing.expectEqual(@as(u16, 21), small.size);

    // A link with a token: too long for the first versions.
    const link = "https://app.example.com/access/visits/4f3c2b1a-9d8e-7f6a-5b4c-3d2e1f0a9b8c?t=0123456789abcdef0123456789abcdef";
    var bigger = try QR.encodeAuto(a, link, .medium);
    defer bigger.deinit();
    try std.testing.expect(bigger.version > 1);
    // The version before it does not hold the text.
    try std.testing.expectError(error.DataTooLarge, QR.encode(a, link, bigger.version - 1, .medium));

    // More than any version holds.
    const huge = try a.alloc(u8, 3000);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.DataTooLarge, QR.encodeAuto(a, huge, .high));
}

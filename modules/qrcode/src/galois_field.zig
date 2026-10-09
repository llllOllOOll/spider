//! Internal: GF(2^8) arithmetic for QR Code's Reed-Solomon error
//! correction.
//!
//! ISO/IEC 18004:2015 Annex A: "α is the primitive element 2 under
//! GF(2^8)". The field is defined by reduction polynomial
//! x^8 + x^4 + x^3 + x^2 + 1 (0x11D) — this is the standard QR/CCITT
//! field, not something this project chose; it is fixed by the spec.
//!
//! Multiplication is done via discrete-log / antilog tables (built at
//! comptime) rather than the bit-doubling "Russian peasant" loop some
//! reference C code uses — same field, different but equivalent
//! technique, chosen because it also gives pow()/log() for free, which
//! is exactly the α^exponent notation ISO Annex A publishes its
//! generator polynomials in (useful directly in reed_solomon.zig's
//! tests against that table).

const std = @import("std");

const reduction_poly: u16 = 0x11D;

/// exp_table[i] = α^i, for i in 0..=509. The table is built to double
/// length (510 instead of the field's 255 non-zero elements) so that
/// multiply() can look up exp[log(a) + log(b)] directly without a
/// modulo — log(a) + log(b) never exceeds 254 + 254 = 508.
const exp_table: [510]u8 = blk: {
    var table: [510]u8 = undefined;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        table[i] = @intCast(x);
        table[i + 255] = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= reduction_poly;
    }
    break :blk table;
};

/// log_table[x] = i such that α^i = x, for x in 1..=255.
/// log_table[0] is unused (0 has no discrete log) and left as 0.
const log_table: [256]u8 = blk: {
    var table: [256]u8 = @splat(0);
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        table[exp_table[i]] = @intCast(i);
    }
    break :blk table;
};

/// α^exponent, for any exponent in 0..=255 (255 wraps to α^255 = α^0 = 1,
/// covered because exp_table's second half duplicates the first).
pub fn pow(exponent: u8) u8 {
    return exp_table[exponent];
}

/// Discrete log base α of a non-zero field element. Asserts x != 0 —
/// 0 has no logarithm in this field.
pub fn log(x: u8) u8 {
    std.debug.assert(x != 0);
    return log_table[x];
}

/// Field multiplication. 0 annihilates (0 * x = x * 0 = 0 for all x,
/// same as ordinary arithmetic) since 0 has no discrete log to add.
pub fn multiply(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    const sum: usize = @as(usize, log_table[a]) + @as(usize, log_table[b]);
    return exp_table[sum];
}

test "pow(0) is the multiplicative identity" {
    try std.testing.expectEqual(@as(u8, 1), pow(0));
}

test "pow(1) is the primitive element 2" {
    try std.testing.expectEqual(@as(u8, 2), pow(1));
}

test "pow(8) is 0x1D — the defining reduction fact for poly 0x11D" {
    // α^7 = 128 (0x80). Doubling once more overflows 8 bits:
    // 0x100 XOR 0x11D = 0x01D. This single value is what pins the
    // whole table to the QR-specific field, as opposed to any other
    // GF(2^8) — if this is wrong, everything downstream (Reed-Solomon,
    // BCH) silently uses the wrong field.
    try std.testing.expectEqual(@as(u8, 0x1D), pow(8));
}

test "log is the inverse of pow across the whole non-zero field" {
    var x: usize = 1;
    while (x < 256) : (x += 1) {
        const e = log(@intCast(x));
        try std.testing.expectEqual(@as(u8, @intCast(x)), pow(e));
    }
}

test "multiply(2, 128) matches pow(8) via the log/exp path" {
    // Cross-check: 2 = pow(1), 128 = pow(7), so multiply should route
    // through log(2)=1, log(128)=7, sum=8, pow(8) — same value the
    // dedicated pow(8) test above checks directly, computed a different
    // way.
    try std.testing.expectEqual(pow(8), multiply(2, 128));
}

test "multiply by zero annihilates" {
    try std.testing.expectEqual(@as(u8, 0), multiply(0, 200));
    try std.testing.expectEqual(@as(u8, 0), multiply(200, 0));
    try std.testing.expectEqual(@as(u8, 0), multiply(0, 0));
}

test "multiply by one is the identity" {
    var x: usize = 0;
    while (x < 256) : (x += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(x)), multiply(1, @intCast(x)));
    }
}

test "multiply is commutative across the whole field" {
    var a: usize = 0;
    while (a < 256) : (a += 1) {
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            try std.testing.expectEqual(
                multiply(@intCast(a), @intCast(b)),
                multiply(@intCast(b), @intCast(a)),
            );
        }
    }
}

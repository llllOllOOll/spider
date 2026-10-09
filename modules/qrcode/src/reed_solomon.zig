//! Internal: Reed-Solomon error correction codeword generation over
//! GF(2^8).
//!
//! ISO/IEC 18004:2015 Annex A: the generator polynomial for `degree`
//! error correction codewords is the product of the first-degree
//! polynomials (x - α^0)(x - α^1)...(x - α^(degree-1)); the error
//! correction codewords are the coefficients of the remainder when the
//! data codeword polynomial (data bytes as coefficients, descending
//! power order) is divided by that generator polynomial.

const std = @import("std");
const gf = @import("galois_field.zig");

/// Writes the `degree` lower coefficients of the generator polynomial
/// into `coeffs` (length must equal `degree`), in descending power
/// order: coeffs[0] is the coefficient of x^(degree-1), coeffs[degree-1]
/// is the constant term. The leading x^degree term is implicit (the
/// polynomial is monic) and not stored.
pub fn generatorPolynomial(degree: u8, coeffs: []u8) void {
    std.debug.assert(coeffs.len == degree);
    @memset(coeffs, 0);
    coeffs[degree - 1] = 1; // running product starts at the polynomial "1"

    var root: u8 = 1; // alpha^0
    var i: u8 = 0;
    while (i < degree) : (i += 1) {
        // Multiply the running product by (x - root). Subtraction is
        // XOR in GF(2), so this is (x + root): each coefficient absorbs
        // root times itself, plus the next-higher coefficient shifting
        // down (standard in-place polynomial multiply by a binomial).
        var j: u8 = 0;
        while (j < degree) : (j += 1) {
            coeffs[j] = gf.multiply(coeffs[j], root);
            if (j + 1 < degree) coeffs[j] ^= coeffs[j + 1];
        }
        root = gf.multiply(root, 2); // next root: alpha^(i+1), alpha = 2
    }
}

/// Computes the `degree`-byte remainder of dividing the polynomial
/// formed by `data` (as coefficients, most-significant/highest-power
/// byte first) by the generator polynomial `generator_coeffs` (as
/// produced by generatorPolynomial). This remainder *is* the block's
/// error correction codewords (ISO 7.5.2).
pub fn computeRemainder(data: []const u8, generator_coeffs: []const u8, remainder: []u8) void {
    const degree = generator_coeffs.len;
    std.debug.assert(remainder.len == degree);
    @memset(remainder, 0);

    for (data) |data_byte| {
        const factor = data_byte ^ remainder[0];

        var j: usize = 0;
        while (j + 1 < degree) : (j += 1) {
            remainder[j] = remainder[j + 1];
        }
        remainder[degree - 1] = 0;

        j = 0;
        while (j < degree) : (j += 1) {
            remainder[j] ^= gf.multiply(generator_coeffs[j], factor);
        }
    }
}

test "generatorPolynomial degree 2 matches ISO Annex A Table A.1 (x2 + a25x + a)" {
    var coeffs: [2]u8 = undefined;
    generatorPolynomial(2, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{ gf.pow(25), gf.pow(1) }, &coeffs);
}

test "generatorPolynomial degree 5 matches ISO Annex A Table A.1" {
    // x5 + a113x4 + a164x3 + a166x2 + a119x + a10
    var coeffs: [5]u8 = undefined;
    generatorPolynomial(5, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{
        gf.pow(113), gf.pow(164), gf.pow(166), gf.pow(119), gf.pow(10),
    }, &coeffs);
}

test "generatorPolynomial degree 6 matches ISO Annex A Table A.1 (bare x4 term = a0)" {
    // x6 + a166x5 + x4 + a134x3 + a5x2 + a176x + a15
    // "x4" with no explicit exponent means coefficient alpha^0 = 1.
    var coeffs: [6]u8 = undefined;
    generatorPolynomial(6, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{
        gf.pow(166), gf.pow(0), gf.pow(134), gf.pow(5), gf.pow(176), gf.pow(15),
    }, &coeffs);
}

test "generatorPolynomial degree 7 matches ISO Annex A Table A.1" {
    // x7 + a87x6 + a229x5 + a146x4 + a149x3 + a238x2 + a102x + a21
    var coeffs: [7]u8 = undefined;
    generatorPolynomial(7, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{
        gf.pow(87), gf.pow(229), gf.pow(146), gf.pow(149), gf.pow(238), gf.pow(102), gf.pow(21),
    }, &coeffs);
}

test "generatorPolynomial degree 8 matches ISO Annex A Table A.1" {
    // x8 + a175x7 + a238x6 + a208x5 + a249x4 + a215x3 + a252x2 + a196x + a28
    var coeffs: [8]u8 = undefined;
    generatorPolynomial(8, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{
        gf.pow(175), gf.pow(238), gf.pow(208), gf.pow(249),
        gf.pow(215), gf.pow(252), gf.pow(196), gf.pow(28),
    }, &coeffs);
}

test "generatorPolynomial degree 10 matches ISO Annex A Table A.1" {
    // x10 + a251x9 + a67x8 + a46x7 + a61x6 + a118x5 + a70x4 + a64x3 + a94x2 + a32x + a45
    var coeffs: [10]u8 = undefined;
    generatorPolynomial(10, &coeffs);
    try std.testing.expectEqualSlices(u8, &.{
        gf.pow(251), gf.pow(67), gf.pow(46), gf.pow(61), gf.pow(118),
        gf.pow(70),  gf.pow(64), gf.pow(94), gf.pow(32), gf.pow(45),
    }, &coeffs);
}

test "computeRemainder reproduces the ISO/Thonky HELLO WORLD version-1M fixture" {
    // Data codewords for the well-known "HELLO WORLD" version-1, ECC
    // level M worked example (thonky.com QR tutorial, cross-validated
    // earlier against the ISO padding rule — the trailing 236,17,236,17
    // repeat is exactly the 0xEC/0x11 pad-byte alternation ISO 7.4.10
    // specifies). Version 1-M needs 10 ECC codewords per block (ISO
    // Table 9 / tables.ecc_codewords_per_block[.medium][1] == 10).
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 };
    const expected_ecc = [_]u8{ 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 };

    var gen: [10]u8 = undefined;
    generatorPolynomial(10, &gen);

    var remainder: [10]u8 = undefined;
    computeRemainder(&data, &gen, &remainder);

    try std.testing.expectEqualSlices(u8, &expected_ecc, &remainder);
}

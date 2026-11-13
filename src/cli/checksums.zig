//! The SHA-256 of every file `spider install` downloads, by its URL.
//!
//! A download is checked against this table before it is written anywhere
//! (project, cache) and before anything is made executable: a file whose
//! hash differs, or a URL that is not in the table, is refused.
//!
//! Updating a version (install.zig, icons.zig) means updating its lines
//! here. Take each hash from two sources, never only from the download:
//!
//!   * Tailwind, daisyUI (GitHub releases): the asset's `digest` in
//!     `gh api repos/<owner>/<repo>/releases/tags/v<version>`, and for
//!     Tailwind also the release's `sha256sums.txt`;
//!   * jsDelivr and unpkg files (npm packages): the file's `hash` (base64
//!     SHA-256) in https://data.jsdelivr.com/v1/packages/npm/<pkg>@<ver>?structure=flat;
//!   * npm tarballs (icons): `dist.integrity` (SHA-512) in
//!     https://registry.npmjs.org/<pkg>/<ver>, compared with the download,
//!     then `sha256sum` of that same file.
//!
//! The test "every URL spider install can download has a checksum"
//! (install.zig) fails when a URL is added without its line.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// URL -> SHA-256 (lowercase hex).
const table = std.StaticStringMap([]const u8).initComptime(.{
    // Tailwind CSS 4.3.0, standalone CLI (tailwindlabs/tailwindcss).
    .{ "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-linux-x64", "73f0e5459054e5cfaa8ab6f3b940f3fbe0f13cc7fd83bc24e7c655033c203400" },
    .{ "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-linux-arm64", "8f48dcb72be3b351c10563c5329b4638ba8516820dc3b3a1609625a166e87cbd" },
    .{ "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-macos-arm64", "56b4bbc62dbdc4614a78930d9c6986423a2ec63e4e640144a59a5d95c914322e" },
    .{ "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-macos-x64", "2ba252f770817091e6d0d12a84e0dd531bcc29aad1bfd9d976a3aff1a071b67a" },
    .{ "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-windows-x64.exe", "e4303d06a337899d426583508f55c143ce89a585f90ed080f482d02fd83093c1" },
    // daisyUI 5.5.23 (saadeghi/daisyui releases).
    .{ "https://github.com/saadeghi/daisyui/releases/download/v5.5.23/daisyui.mjs", "c41cd218e07899f85005ba6da07d59ac38028c6999a6a76cbb2fe3edb6ac1e3f" },
    .{ "https://github.com/saadeghi/daisyui/releases/download/v5.5.23/daisyui-theme.mjs", "72efb4cbf0d1f205988b2f09d917c174a233784ca5c9cc70db729e2712548bb6" },
    // Alpine.js 3.14.8.
    .{ "https://cdn.jsdelivr.net/npm/alpinejs@3.14.8/dist/cdn.min.js", "b600e363d99d95444db54acbfb2deffec9ae792aa99a09229bcda078e5b55643" },
    // htmx 2.0.11, htmx 4.0.0 and its SSE extension.
    .{ "https://unpkg.com/htmx.org@2.0.11/dist/htmx.min.js", "d6fdc75f204e6bdefa99b69bf1e6d4ac69b8a364f77929f45c13476b4000f717" },
    .{ "https://unpkg.com/htmx.org@4.0.0/dist/htmx.min.js", "e484d9171a9db30a39c8f16e3d709d4137f3211c659f8e6125816635033d593f" },
    .{ "https://unpkg.com/htmx.org@4.0.0/dist/ext/hx-sse.min.js", "8a834680c4000a9034d79228872372a92e140c810a075cb6d4a76690dfc13085" },
    // Tabler icons webfont 3.31.0.
    .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.31.0/dist/tabler-icons.min.css", "d63a2fcaa449a9a70499e612e5ee8a14fb4073f11872edcc68e7d477cd9b8b07" },
    .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.31.0/dist/fonts/tabler-icons.woff2", "fe36b79a78fef8d71906ae82c63367c6b72f83ba8b53ef2c495e30aba67e59b2" },
    // Icon sets (npm tarballs, icons.zig).
    .{ "https://registry.npmjs.org/heroicons/-/heroicons-2.2.0.tgz", "6c3e9d04b8495c9512a91b0b08804f2c3614a8e5d7df39bbfe02b6450fb7c640" },
    .{ "https://registry.npmjs.org/lucide-static/-/lucide-static-1.48.0.tgz", "3c2ecda3d25f6a9692d83f8036d9a526f7da584a51af74cd16eda4498c5c33d8" },
    .{ "https://registry.npmjs.org/@tabler/icons/-/icons-3.48.0.tgz", "28447dcf6f0bb2b8d92c59a1b3d30900a180de2e97d7db4d267e6320dc68f449" },
});

pub const Error = error{
    /// The file's SHA-256 is not the one in the table.
    ChecksumMismatch,
    /// The URL is not in the table: nothing to check it against.
    ChecksumUnknown,
};

/// The expected SHA-256 (lowercase hex) of `url`, or null.
pub fn expected(url: []const u8) ?[]const u8 {
    return table.get(url);
}

/// `body` is what `url` should serve. Says why on stderr when it is not.
pub fn verify(url: []const u8, body: []const u8) Error!void {
    return verifyHex(expected(url), url, body);
}

/// `verify` against a given hash; null means the URL is unknown.
pub fn verifyHex(expected_hex: ?[]const u8, url: []const u8, body: []const u8) Error!void {
    const want = expected_hex orelse {
        std.debug.print("error: no SHA-256 known for {s}; refusing to use it (src/cli/checksums.zig)\n", .{url});
        return error.ChecksumUnknown;
    };
    const got = hexOf(body);
    if (!std.ascii.eqlIgnoreCase(want, &got)) {
        std.debug.print(
            "error: SHA-256 mismatch for {s}\n  expected {s}\n  got      {s}\n",
            .{ url, want, &got },
        );
        return error.ChecksumMismatch;
    }
}

/// SHA-256 of `body` as lowercase hex.
pub fn hexOf(body: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// SHA-256("abc"), FIPS 180-2 test vector.
const abc_hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

test "hexOf: the FIPS 180-2 vector" {
    try std.testing.expectEqualStrings(abc_hex, &hexOf("abc"));
}

test "verifyHex: the right hash passes, any other body is refused" {
    try verifyHex(abc_hex, "https://example.test/a", "abc");
    try verifyHex("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD", "https://example.test/a", "abc");
    try std.testing.expectError(error.ChecksumMismatch, verifyHex(abc_hex, "https://example.test/a", "abd"));
    try std.testing.expectError(error.ChecksumMismatch, verifyHex(abc_hex, "https://example.test/a", ""));
}

test "verify: a URL that is not in the table is refused" {
    try std.testing.expectError(error.ChecksumUnknown, verify("https://example.test/not-pinned.js", "abc"));
}

test "every hash in the table is 64 lowercase hex digits" {
    for (table.values()) |hex| {
        try std.testing.expectEqual(@as(usize, 64), hex.len);
        for (hex) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
}

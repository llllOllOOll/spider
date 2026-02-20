const std = @import("std");

pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &hash, .{});

    const hex = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, &hex);
}

var token_counter: u64 = 0;

pub fn generateToken(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    var rand = std.Random.DefaultPrng.init(token_counter);
    token_counter += 1;
    rand.random().bytes(&bytes);

    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

const std = @import("std");

pub fn capitalize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return allocator.dupe(u8, name);
    const result = try allocator.alloc(u8, name.len);
    result[0] = std.ascii.toUpper(name[0]);
    for (name[1..], 1..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

pub fn pluralize(name: []const u8, buf: []u8) []const u8 {
    if (std.mem.endsWith(u8, name, "s")) {
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 's';
    return buf[0 .. name.len + 1];
}

pub fn renderTemplate(allocator: std.mem.Allocator, tmpl: []const u8, feature: []const u8, plural: []const u8) ![]u8 {
    const Feature = try capitalize(allocator, feature);
    defer allocator.free(Feature);

    const step1 = try std.mem.replaceOwned(u8, allocator, tmpl, "{{feature}}", feature);
    defer allocator.free(step1);

    const step2 = try std.mem.replaceOwned(u8, allocator, step1, "{{Feature}}", Feature);
    defer allocator.free(step2);

    return try std.mem.replaceOwned(u8, allocator, step2, "{{plural}}", plural);
}

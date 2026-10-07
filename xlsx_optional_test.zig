//! Probe for the opt-in xlsx module (see the `test` step in build.zig).
//!
//! It touches nothing but `spider.xlsx`. In the default build that
//! must not compile — the module is not there — and build.zig expects
//! exactly that error. With `-Dxlsx=true` it runs as a normal test.

const std = @import("std");
const spider = @import("spider");

test "spider.xlsx is the xlsx module" {
    const wb = try spider.xlsx.Workbook.init(std.testing.allocator);
    defer wb.deinit();
    const sheet = try wb.addSheet("Probe");
    try sheet.set(0, 0, .{ .text = "ok" });
    const bytes = try wb.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "PK\x03\x04"));
}

//! Where listen() listens.
const std = @import("std");
const env = @import("../internal/env.zig");
const dev_reload = @import("../modules/dev_reload.zig");
const test_port = @import("../testing/port.zig");

pub const Address = struct { host: []const u8, port: u16 };

/// In order: a test (spider.testing.start: its port, on 127.0.0.1),
/// `spider dev --port`, the port given to `listen(.{ .port = ... })`, the
/// PORT variable (the environment or .env: how a container or a host tells
/// an app where to listen), then the app's config.
///
/// PORT comes after an explicit `.port`, so an app that passes its own
/// port keeps it whatever its environment holds.
pub fn resolve(host: []const u8, option_port: ?u16, config_port: u16) Address {
    if (test_port.take()) |under_test| return .{ .host = "127.0.0.1", .port = under_test };
    return .{ .host = host, .port = choose(dev_reload.portOverride(), option_port, env.get("PORT"), config_port) };
}

pub fn choose(dev: ?u16, option_port: ?u16, port_var: ?[]const u8, config_port: u16) u16 {
    if (dev) |port| return port;
    if (option_port) |port| return port;
    if (port_var) |text| {
        if (dev_reload.parsePort(text)) |port| return port;
    }
    return config_port;
}

test "choose: spider dev, listen's own port, PORT, then the config" {
    try std.testing.expectEqual(@as(u16, 4000), choose(4000, 5000, "8080", 3000));
    try std.testing.expectEqual(@as(u16, 5000), choose(null, 5000, "8080", 3000));
    try std.testing.expectEqual(@as(u16, 8080), choose(null, null, "8080", 3000));
    try std.testing.expectEqual(@as(u16, 8080), choose(null, null, " 8080\n", 3000));
    try std.testing.expectEqual(@as(u16, 3000), choose(null, null, null, 3000));
    try std.testing.expectEqual(@as(u16, 3000), choose(null, null, "not a port", 3000));
    try std.testing.expectEqual(@as(u16, 3000), choose(null, null, "0", 3000));
}

test "resolve: a test's port wins, on the loopback address, once" {
    test_port.set(4321);
    const under_test = resolve("0.0.0.0", 3000, 3000);
    try std.testing.expectEqualStrings("127.0.0.1", under_test.host);
    try std.testing.expectEqual(@as(u16, 4321), under_test.port);
    try std.testing.expectEqualStrings("0.0.0.0", resolve("0.0.0.0", 3000, 3000).host);
}

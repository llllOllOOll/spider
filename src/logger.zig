const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

pub const Logger = struct {
    level: Level,

    const Self = @This();

    pub fn init(level: Level) Self {
        return .{ .level = level };
    }

    fn shouldLog(self: Self, level: Level) bool {
        const order = [_]Level{ .debug, .info, .warn, .err };
        const current = std.mem.indexOfScalar(Level, &order, self.level).?;
        const msg = std.mem.indexOfScalar(Level, &order, level).?;
        return msg >= current;
    }

    fn writeLog(self: Self, level: Level, msg: []const u8, data: anytype) void {
        if (!self.shouldLog(level)) return;

        const level_str = switch (level) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "err",
        };

        std.debug.print("{{\"level\":\"{s}\",\"msg\":\"{s}\",\"data\":", .{ level_str, msg });
        std.debug.print("{any}}}\n", .{data});
    }

    pub fn debug(self: Self, msg: []const u8, data: anytype) void {
        self.writeLog(.debug, msg, data);
    }

    pub fn info(self: Self, msg: []const u8, data: anytype) void {
        self.writeLog(.info, msg, data);
    }

    pub fn warn(self: Self, msg: []const u8, data: anytype) void {
        self.writeLog(.warn, msg, data);
    }

    pub fn err(self: Self, msg: []const u8, data: anytype) void {
        self.writeLog(.err, msg, data);
    }
};

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

    const Color = struct {
        reset: []const u8 = "\x1b[0m",
        green: []const u8 = "\x1b[32m",
        yellow: []const u8 = "\x1b[33m",
        red: []const u8 = "\x1b[31m",
        cyan: []const u8 = "\x1b[36m",
    };

    const color = Color{};

    pub fn init(level: Level) Self {
        return .{ .level = level };
    }

    fn shouldLog(self: Self, level: Level) bool {
        const order = [_]Level{ .debug, .info, .warn, .err };
        const current = std.mem.indexOfScalar(Level, &order, self.level).?;
        const msg = std.mem.indexOfScalar(Level, &order, level).?;
        return msg >= current;
    }

    fn getStatusColor(status: u16) []const u8 {
        if (status >= 200 and status < 300) return color.green;
        if (status >= 400 and status < 500) return color.yellow;
        if (status >= 500) return color.red;
        return color.reset;
    }

    pub fn request(self: Self, status: u16, latency_ns: u64, method: []const u8, path: []const u8) void {
        if (!self.shouldLog(.info)) return;

        const status_color = getStatusColor(status);
        const reset = color.reset;
        const cyan = color.cyan;

        var latency_buf: [32]u8 = undefined;
        const latency_str = blk: {
            if (latency_ns < 1000) {
                break :blk std.fmt.bufPrint(&latency_buf, "{}ns", .{latency_ns}) catch "0ns";
            } else if (latency_ns < 1000000) {
                break :blk std.fmt.bufPrint(&latency_buf, "{}.{:0>3}µs", .{ latency_ns / 1000, latency_ns % 1000 }) catch "0µs";
            } else {
                break :blk std.fmt.bufPrint(&latency_buf, "{}.{:0>3}ms", .{ latency_ns / 1000000, (latency_ns / 1000) % 1000 }) catch "0ms";
            }
        };

        std.debug.print("[{s}[SPIDER]{s}] | {s}{d}{s} | {s} | {s}{s}{s} \"{s}{s}{s}\"\n", .{
            reset,        cyan,
            status_color, status,
            reset,        latency_str,
            reset,        method,
            reset,        reset,
            path,         reset,
        });
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

        const T = @TypeOf(data);
        if (T == @TypeOf(.{})) {
            std.debug.print("{{}}", .{});
        } else {
            std.debug.print(".", .{});
            const fields = std.meta.fields(T);
            var first = true;
            inline for (fields) |field| {
                const value = @field(data, field.name);
                const comma = if (first) "" else ",";
                first = false;
                const V = @TypeOf(value);
                const type_info = @typeInfo(V);
                if (V == []const u8 or V == [:0]const u8) {
                    std.debug.print("{s}.{s} = \"{s}\"", .{ comma, field.name, value });
                } else if (V == u16) {
                    std.debug.print("{s}.{s} = {d}", .{ comma, field.name, value });
                } else if (type_info == .pointer) {
                    std.debug.print("{s}.{s} = \"{s}\"", .{ comma, field.name, value });
                } else {
                    std.debug.print("{s}.{s} = {any}", .{ comma, field.name, value });
                }
            }
        }
        std.debug.print("}}\n", .{});
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

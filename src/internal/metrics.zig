const std = @import("std");

var global_io: std.Io = undefined;

pub const Metrics = struct {
    total_requests: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),
    bytes_in: std.atomic.Value(u64),
    bytes_out: std.atomic.Value(u64),
    slow_requests: std.atomic.Value(u64),
    ws_clients: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .total_requests = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
            .bytes_in = std.atomic.Value(u64).init(0),
            .bytes_out = std.atomic.Value(u64).init(0),
            .slow_requests = std.atomic.Value(u64).init(0),
            .ws_clients = std.atomic.Value(u64).init(0),
        };
    }

    pub fn incrementRequest(self: *Metrics) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
    }

    pub fn incrementError(self: *Metrics) void {
        _ = self.total_errors.fetchAdd(1, .monotonic);
    }

    pub fn addBytesIn(self: *Metrics, n: u64) void {
        _ = self.bytes_in.fetchAdd(n, .monotonic);
    }

    pub fn addBytesOut(self: *Metrics, n: u64) void {
        _ = self.bytes_out.fetchAdd(n, .monotonic);
    }

    pub fn incrementSlowRequest(self: *Metrics) void {
        _ = self.slow_requests.fetchAdd(1, .monotonic);
    }

    pub fn setWsClients(self: *Metrics, count: usize) void {
        self.ws_clients.store(count, .release);
    }

    pub fn get(self: *Metrics) MetricsSnapshot {
        const now = std.Io.Clock.now(.awake, global_io);
        const uptime_ns = server_start_time.durationTo(now);
        return .{
            .uptime = @intCast(uptime_ns.toSeconds()),
            .total_requests = self.total_requests.load(.acquire),
            .bytes_in = self.bytes_in.load(.acquire),
            .bytes_out = self.bytes_out.load(.acquire),
            .errors = self.total_errors.load(.acquire),
            .slow_requests = self.slow_requests.load(.acquire),
            .ws_clients = self.ws_clients.load(.acquire),
        };
    }
};

pub const MetricsSnapshot = struct {
    uptime: i64,
    total_requests: u64,
    bytes_in: u64,
    bytes_out: u64,
    errors: u64,
    slow_requests: u64,
    ws_clients: u64,
};

pub var global_metrics: Metrics = undefined;
var server_start_time: std.Io.Timestamp = undefined;

pub fn initMetrics(io: std.Io) void {
    global_io = io;
    global_metrics = Metrics.init();
    server_start_time = std.Io.Clock.now(.awake, io);
}

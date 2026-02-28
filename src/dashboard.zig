const std = @import("std");
const web = @import("web.zig");
const metrics = @import("metrics.zig");

const dashboard_html = @embedFile("dashboard.html");

pub fn metricsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const snapshot = metrics.global_metrics.get();
    return try web.Response.json(allocator, snapshot);
}

pub fn dashboardHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, dashboard_html);
}

pub fn dashboardPanelHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const snapshot = metrics.global_metrics.get();

    const html = try std.fmt.allocPrint(allocator,
        \\<div class="grid">
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">UPTIME</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">REQUESTS</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">ERRORS</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">SLOW REQ</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">WS CLIENTS</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">BYTES IN</div>
        \\  </div>
        \\  <div class="card">
        \\    <div class="value">{d}</div>
        \\    <div class="label">BYTES OUT</div>
        \\  </div>
        \\</div>
    , .{
        snapshot.uptime,
        snapshot.total_requests,
        snapshot.errors,
        snapshot.slow_requests,
        snapshot.ws_clients,
        snapshot.bytes_in,
        snapshot.bytes_out,
    });

    return try web.Response.html(allocator, html);
}

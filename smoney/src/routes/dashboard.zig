const std = @import("std");
const spider = @import("spider");
const db = @import("../db/conn.zig");
const tx_repo = @import("../db/transactions.zig");

const dashboard_tmpl = @embedFile("../templates/dashboard.html");

var global_pool: *db.Pool = undefined;
var global_user_id: u64 = 1;

pub fn init(pool: *db.Pool, user_id: u64) void {
    global_pool = pool;
    global_user_id = user_id;
}

const month_names = [_][]const u8{
    "Janeiro", "Fevereiro", "Março",   "Abril",   "Maio",     "Junho",
    "Julho",   "Agosto",    "Setembro", "Outubro", "Novembro", "Dezembro",
};

fn formatCurrency(allocator: std.mem.Allocator, amount: f64) ![]u8 {
    const int_part = @floor(amount);
    const cents: u8 = @intFromFloat(@round((amount - int_part) * 100));

    const int_str = try std.fmt.allocPrint(allocator, "{d:.0}", .{int_part});
    defer allocator.free(int_str);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = int_str.len;
    var count: usize = 0;
    while (i > 0) {
        i -= 1;
        try result.append(allocator, int_str[i]);
        count += 1;
        if (count == 3 and i > 0) {
            try result.append(allocator, '.');
            count = 0;
        }
    }

    var reversed = std.ArrayList(u8).empty;
    errdefer reversed.deinit(allocator);
    i = result.items.len;
    while (i > 0) {
        i -= 1;
        try reversed.append(allocator, result.items[i]);
    }

    return try std.fmt.allocPrint(allocator, "R$ {s},{d:0>2}", .{ reversed.items, @as(u8, cents) });
}

const MonthRow = struct {
    label: []const u8,
    amount_str: []const u8,
    variance_str: []const u8,
    variance_class: []const u8,
};

const DashboardData = struct {
    total_str: []const u8,
    total_months: []const u8,
    avg_str: []const u8,
    biggest_str: []const u8,
    biggest_month: []const u8,
    lowest_str: []const u8,
    lowest_month: []const u8,
    summaries: []const MonthRow,
};

pub fn dashboardHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    var repo = tx_repo.TransactionRepository.init(allocator, global_pool);
    const summaries = try repo.getMonthlySummary(global_user_id);
    defer allocator.free(summaries);

    var total: f64 = 0;
    var biggest: f64 = 0;
    var lowest: f64 = std.math.inf(f64);
    var biggest_idx: usize = 0;
    var lowest_idx: usize = 0;
    for (summaries, 0..) |s, i| {
        total += s.total;
        if (s.total > biggest) {
            biggest = s.total;
            biggest_idx = i;
        }
        if (s.total < lowest) {
            lowest = s.total;
            lowest_idx = i;
        }
    }
    const avg = if (summaries.len > 0)
        total / @as(f64, @floatFromInt(summaries.len))
    else
        0;

    var rows = try allocator.alloc(MonthRow, summaries.len);
    for (summaries, 0..) |s, i| {
        const label = try std.fmt.allocPrint(
            allocator,
            "{s}/{d}",
            .{ month_names[s.month - 1], s.year },
        );
        const amount_str = try formatCurrency(allocator, s.total);

        var variance_str: []u8 = try allocator.dupe(u8, "");
        var variance_class: []const u8 = "";
        if (i > 0) {
            const prev = summaries[i - 1].total;
            const diff = s.total - prev;
            const pct = if (prev > 0) (diff / prev) * 100.0 else 0;
            const pct_abs = @abs(pct);
            const pct_int: i64 = @intFromFloat(@floor(pct_abs));
            const pct_frac: u32 = @intFromFloat(@round((pct_abs - @floor(pct_abs)) * 10));
            if (diff > 0) {
                allocator.free(variance_str);
                variance_str = try std.fmt.allocPrint(allocator, "+{d}.{d}%", .{ pct_int, pct_frac });
                variance_class = "variance-up";
            } else if (diff < 0) {
                allocator.free(variance_str);
                variance_str = try std.fmt.allocPrint(allocator, "-{d}.{d}%", .{ pct_int, pct_frac });
                variance_class = "variance-down";
            }
        }

        rows[i] = .{
            .label = label,
            .amount_str = amount_str,
            .variance_str = variance_str,
            .variance_class = variance_class,
        };
    }

    const data = DashboardData{
        .total_str = try formatCurrency(allocator, total),
        .total_months = try std.fmt.allocPrint(allocator, "{d}", .{summaries.len}),
        .avg_str = try formatCurrency(allocator, avg),
        .biggest_str = try formatCurrency(allocator, biggest),
        .biggest_month = month_names[summaries[biggest_idx].month - 1],
        .lowest_str = try formatCurrency(allocator, lowest),
        .lowest_month = month_names[summaries[lowest_idx].month - 1],
        .summaries = rows,
    };

    const html = try spider.template.render(dashboard_tmpl, data, allocator);
    return spider.Response.html(allocator, html);
}

pub const dashboardDataHandler = dashboardHandler;

const std = @import("std");
const spider = @import("spider");
const db = @import("../db/conn.zig");
const tx_repo = @import("../db/transactions.zig");

const dashboard_tmpl = @embedFile("../templates/dashboard.html");
const details_tmpl = @embedFile("../templates/details.html");

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
    defer result.deinit(allocator);

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

    var reversed = try allocator.alloc(u8, result.items.len);
    defer allocator.free(reversed);
    for (result.items, 0..) |char, j| {
        reversed[result.items.len - 1 - j] = char;
    }

    return try std.fmt.allocPrint(allocator, "R$ {s},{d:0>2}", .{ reversed, cents });
}

const MonthRow = struct {
    label: []const u8,
    period_range: []const u8,
    amount_str: []const u8,
    variance_str: []const u8,
    variance_class: []const u8,
    month_id: []const u8,
    year_id: []const u8,
};

const DashboardData = struct {
    avg_str: []const u8,
    biggest_str: []const u8,
    summaries: []const MonthRow,
};

const TxRow = struct {
    date: []const u8,
    title: []const u8,
    amount_str: []const u8,
};

pub fn dashboardHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    var repo = tx_repo.TransactionRepository.init(allocator, global_pool);
    const summaries = try repo.getMonthlySummary(global_user_id);
    defer allocator.free(summaries);

    var max_total: f64 = 0;
    var total: f64 = 0;
    for (summaries) |s| {
        total += s.total;
        if (s.total > max_total) max_total = s.total;
    }

    var rows = try allocator.alloc(MonthRow, summaries.len);
    for (summaries, 0..) |s, i| {
        const prev_m = if (s.month == 1) @as(u8, 12) else s.month - 1;
        const prev_y = if (s.month == 1) s.year - 1 else s.year;

        const diff = if (i > 0) s.total - summaries[i - 1].total else 0;
        const pct = if (i > 0 and summaries[i - 1].total > 0)
            (diff / summaries[i - 1].total) * 100
        else
            0;

        const variance_str = if (i > 0)
            try std.fmt.allocPrint(allocator, "{s}{d:.1}%", .{
                if (diff > 0) @as([]const u8, "+") else @as([]const u8, ""),
                pct,
            })
        else
            try allocator.dupe(u8, "");

        rows[i] = .{
            .label = try std.fmt.allocPrint(allocator, "{s} {d}", .{ month_names[s.month - 1], s.year }),
            .period_range = try std.fmt.allocPrint(allocator, "20/{d:0>2}/{d} a 19/{d:0>2}/{d}", .{ prev_m, prev_y, s.month, s.year }),
            .amount_str = try formatCurrency(allocator, s.total),
            .variance_str = variance_str,
            .variance_class = if (i == 0) "" else if (diff > 0) "variance-up" else "variance-down",
            .month_id = try std.fmt.allocPrint(allocator, "{d}", .{s.month}),
            .year_id = try std.fmt.allocPrint(allocator, "{d}", .{s.year}),
        };
    }

    const data = DashboardData{
        .avg_str = try formatCurrency(allocator, if (summaries.len > 0) total / @as(f64, @floatFromInt(summaries.len)) else 0),
        .biggest_str = try formatCurrency(allocator, max_total),
        .summaries = rows,
    };

    const html = try spider.template.render(dashboard_tmpl, data, allocator);
    return spider.Response.html(allocator, html);
}

pub const dashboardDataHandler = dashboardHandler;

pub fn detailsHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    const month_str = (try req.queryParam("m", allocator)) orelse "1";
    const year_str = (try req.queryParam("y", allocator)) orelse "2026";

    const month = std.fmt.parseInt(u8, month_str, 10) catch 1;
    const year = std.fmt.parseInt(i32, year_str, 10) catch 2026;

    var repo = tx_repo.TransactionRepository.init(allocator, global_pool);
    const txns = try repo.getByMonth(global_user_id, month, year);
    defer allocator.free(txns);

    var rows = try allocator.alloc(TxRow, txns.len);
    for (txns, 0..) |tx, i| {
        rows[i] = .{
            .date = tx.date,
            .title = tx.title,
            .amount_str = try formatCurrency(allocator, tx.amount),
        };
    }
    const DetailData = struct {
        transactions: []const TxRow,
    };
    const html = try spider.template.render(details_tmpl, DetailData{ .transactions = rows }, allocator);
    return spider.Response.html(allocator, html);
}

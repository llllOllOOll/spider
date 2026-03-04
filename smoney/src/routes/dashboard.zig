const std = @import("std");
const spider = @import("spider");
const db = @import("../db/conn.zig");
const tx_repo = @import("../db/transactions.zig");

const dashboard_tmpl = @embedFile("../templates/dashboard.html");
const details_tmpl = @embedFile("../templates/details.html");

const month_names = [_][]const u8{
    "Janeiro", "Fevereiro", "Março",   "Abril",   "Maio",     "Junho",
    "Julho",   "Agosto",    "Setembro", "Outubro", "Novembro", "Dezembro",
};

fn formatCurrency(amount: f64, buf: []u8) []u8 {
    const int_part = @floor(amount);
    const cents: u8 = @intFromFloat(@round((amount - int_part) * 100));

    const int_part_u64: u64 = @intFromFloat(int_part);

    @memcpy(buf[0..3], "R$ ");
    var pos: usize = 3;

    var temp = [_]u8{0} ** 16;
    var len: usize = 0;
    var n = int_part_u64;
    while (true) {
        temp[len] = '0' + @as(u8, @intCast(n % 10));
        len += 1;
        n /= 10;
        if (n == 0) break;
    }

    var dot_count: usize = 0;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        buf[pos] = temp[i];
        pos += 1;
        dot_count += 1;
        if (dot_count == 3 and i > 0) {
            buf[pos] = '.';
            pos += 1;
            dot_count = 0;
        }
    }

    buf[pos] = ',';
    pos += 1;
    buf[pos] = '0' + (cents / 10);
    pos += 1;
    buf[pos] = '0' + (cents % 10);
    pos += 1;

    return buf[0..pos];
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

pub const DashboardHandler = struct {
    pool: *db.Pool,
    user_id: u64,

    pub fn renderDashboard(self: *DashboardHandler, alloc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        _ = req;
        var repo = tx_repo.TransactionRepository.init(alloc, self.pool);
        const summaries = try repo.getMonthlySummary(self.user_id);
        defer alloc.free(summaries);

        var max_total: f64 = 0;
        var total: f64 = 0;
        for (summaries) |s| {
            total += s.total;
            if (s.total > max_total) max_total = s.total;
        }

        var rows = try alloc.alloc(MonthRow, summaries.len);
        for (summaries, 0..) |s, i| {
            const prev_m = if (s.month == 1) @as(u8, 12) else s.month - 1;
            const prev_y = if (s.month == 1) s.year - 1 else s.year;

            const diff = if (i > 0) s.total - summaries[i - 1].total else 0;
            const pct = if (i > 0 and summaries[i - 1].total > 0)
                (diff / summaries[i - 1].total) * 100
            else
                0;

            const variance_str = if (i > 0)
                try std.fmt.allocPrint(alloc, "{s}{d:.1}%", .{
                    if (diff > 0) @as([]const u8, "+") else @as([]const u8, ""),
                    pct,
                })
            else
                try alloc.dupe(u8, "");

            rows[i] = .{
                .label = try std.fmt.allocPrint(alloc, "{s} {d}", .{ month_names[s.month - 1], s.year }),
                .period_range = try std.fmt.allocPrint(alloc, "20/{d:0>2}/{d} a 19/{d:0>2}/{d}", .{ prev_m, prev_y, s.month, s.year }),
                .amount_str = try formatCurrencyToAlloc(alloc, s.total),
                .variance_str = variance_str,
                .variance_class = if (i == 0) "" else if (diff > 0) "variance-up" else "variance-down",
                .month_id = try std.fmt.allocPrint(alloc, "{d}", .{s.month}),
                .year_id = try std.fmt.allocPrint(alloc, "{d}", .{s.year}),
            };
        }

        const avg = if (summaries.len > 0) total / @as(f64, @floatFromInt(summaries.len)) else 0;
        const data = DashboardData{
            .avg_str = try formatCurrencyToAlloc(alloc, avg),
            .biggest_str = try formatCurrencyToAlloc(alloc, max_total),
            .summaries = rows,
        };

        const html = try spider.template.render(dashboard_tmpl, data, alloc);
        return spider.Response.html(alloc, html);
    }

    pub fn renderDashboardData(self: *DashboardHandler, alloc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        return self.renderDashboard(alloc, req);
    }

    pub fn renderDetails(self: *DashboardHandler, alloc: std.mem.Allocator, req: *spider.Request) !spider.Response {
        const month_str = (try req.queryParam("m", alloc)) orelse "1";
        const year_str = (try req.queryParam("y", alloc)) orelse "2026";

        const month = std.fmt.parseInt(u8, month_str, 10) catch 1;
        const year = std.fmt.parseInt(i32, year_str, 10) catch 2026;

        var repo = tx_repo.TransactionRepository.init(alloc, self.pool);
        const txns = try repo.getByMonth(self.user_id, month, year);
        defer alloc.free(txns);

        var rows = try alloc.alloc(TxRow, txns.len);
        for (txns, 0..) |tx, i| {
            rows[i] = .{
                .date = tx.date,
                .title = tx.title,
                .amount_str = try formatCurrencyToAlloc(alloc, tx.amount),
            };
        }
        const DetailData = struct {
            transactions: []const TxRow,
        };
        const html = try spider.template.render(details_tmpl, DetailData{ .transactions = rows }, alloc);
        return spider.Response.html(alloc, html);
    }
};

fn formatCurrencyToAlloc(alloc: std.mem.Allocator, amount: f64) ![]u8 {
    var buf: [32]u8 = undefined;
    const formatted = formatCurrency(amount, &buf);
    return try alloc.dupe(u8, formatted);
}

pub fn createDashboardHandler(pool: *db.Pool, user_id: u64) DashboardHandler {
    return .{ .pool = pool, .user_id = user_id };
}

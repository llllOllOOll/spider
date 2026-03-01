const std = @import("std");
const db_tx = @import("../db/transactions.zig");
const Io = std.Io;

pub const EXCLUDE_TERMS = [_][]const u8{
    "pagamento recebido",
    "saldo em rotativo",
    "crédito de rotativo",
    "encerramento de dívida",
    "juros de dívida",
    "iof de rotativo",
    "juros de rotativo",
    "estorno",
    "iof",
};

fn getCompetencia(year: i32, month: u8, day: u8) struct { year: i32, month: u8 } {
    if (day >= 20) {
        var m = month + 1;
        var y = year;
        if (m > 12) {
            m = 1;
            y += 1;
        }
        return .{ .year = y, .month = m };
    }
    return .{ .year = year, .month = month };
}

fn isExpense(title: []const u8, amount: f64) bool {
    if (amount <= 0) return false;
    var buf: [256]u8 = undefined;
    const len = @min(title.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..len], title[0..len]);
    for (EXCLUDE_TERMS) |term| {
        if (std.mem.indexOf(u8, lower, term) != null) return false;
    }
    return true;
}

pub fn parseCSV(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    user_id: u64,
) ![]db_tx.CreateTransactionInput {
    const limit: Io.Limit = Io.Limit.limited(10 * 1024 * 1024);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    defer allocator.free(content);

    var results = std.ArrayList(db_tx.CreateTransactionInput).empty;
    errdefer results.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');

    // skip header
    _ = lines.next();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;

        // parse: date,title,amount
        // title may contain commas — last field is always amount
        var parts = std.mem.splitScalar(u8, trimmed, ',');

        const date_str = parts.next() orelse continue;
        if (date_str.len != 10) continue; // must be YYYY-MM-DD

        // collect all remaining parts
        // last part = amount, everything in between = title
        var title_parts = std.ArrayList(u8).empty;
        defer title_parts.deinit(allocator);

        var last: []const u8 = "";
        while (parts.next()) |part| {
            if (last.len > 0) {
                try title_parts.appendSlice(allocator, last);
                try title_parts.append(allocator, ',');
            }
            last = part;
        }

        // last = amount_str, title_parts = title (may have trailing comma)
        const amount_str = std.mem.trim(u8, last, " \r");
        const amount = std.fmt.parseFloat(f64, amount_str) catch continue;

        // remove trailing comma from title if present
        var title_raw = title_parts.items;
        if (title_raw.len > 0 and title_raw[title_raw.len - 1] == ',') {
            title_raw = title_raw[0 .. title_raw.len - 1];
        }
        const title = std.mem.trim(u8, title_raw, " \r");

        if (!isExpense(title, amount)) continue;

        // parse date components: YYYY-MM-DD
        const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch continue;
        const month = std.fmt.parseInt(u8, date_str[5..7], 10) catch continue;
        const day = std.fmt.parseInt(u8, date_str[8..10], 10) catch continue;

        const comp = getCompetencia(year, month, day);

        try results.append(allocator, .{
            .user_id = user_id,
            .date = try allocator.dupe(u8, date_str),
            .title = try allocator.dupe(u8, title),
            .amount = amount,
            .competencia_year = comp.year,
            .competencia_month = comp.month,
            .is_expense = true,
        });
    }

    return try results.toOwnedSlice(allocator);
}

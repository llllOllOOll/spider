const std = @import("std");
const spider = @import("spider");
const db = @import("../db/conn.zig");
const tx_repo = @import("../db/transactions.zig");

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

    // Add thousand separators
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

    // Reverse
    var reversed = std.ArrayList(u8).empty;
    errdefer reversed.deinit(allocator);
    i = result.items.len;
    while (i > 0) {
        i -= 1;
        try reversed.append(allocator, result.items[i]);
    }

    const result_str = try std.fmt.allocPrint(allocator, "R$ {s},{d:0>2}", .{ reversed.items, @as(u8, cents) });
    return result_str;
}

pub fn dashboardHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    _ = req;

    var repo = tx_repo.TransactionRepository.init(allocator, global_pool);

    const summaries = try repo.getMonthlySummary(global_user_id);
    defer allocator.free(summaries);

    // Calculate metrics
    var total: f64 = 0;
    var biggest_month: f64 = 0;
    var lowest_month: f64 = std.math.inf(f64);
    var biggest_idx: usize = 0;
    var lowest_idx: usize = 0;
    for (summaries, 0..) |s, i| {
        total += s.total;
        if (s.total > biggest_month) {
            biggest_month = s.total;
            biggest_idx = i;
        }
        if (s.total < lowest_month) {
            lowest_month = s.total;
            lowest_idx = i;
        }
    }
    const avg = if (summaries.len > 0) total / @as(f64, @floatFromInt(summaries.len)) else 0;

    const total_str = try formatCurrency(allocator, total);
    defer allocator.free(total_str);

    const avg_str = try formatCurrency(allocator, avg);
    defer allocator.free(avg_str);

    const biggest_str = try formatCurrency(allocator, biggest_month);
    defer allocator.free(biggest_str);

    const lowest_str = try formatCurrency(allocator, lowest_month);
    defer allocator.free(lowest_str);

    const biggest_name = month_names[summaries[biggest_idx].month - 1];
    const lowest_name = month_names[summaries[lowest_idx].month - 1];

    // Build HTML for each month with variance
    var rows_html = std.ArrayList(u8).empty;
    errdefer rows_html.deinit(allocator);

    for (summaries) |s| {
        const month_name = month_names[s.month - 1];
        const amount_str = try formatCurrency(allocator, s.total);
        defer allocator.free(amount_str);

        try rows_html.appendSlice(allocator,
            \\<tr>
            \\  <td class="month-cell">
            \\    <span class="month-name"> 
        );
        try rows_html.appendSlice(allocator, month_name);
        try rows_html.appendSlice(allocator, "/");
        try rows_html.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{s.year}));
        try rows_html.appendSlice(allocator,
            \\</span>
            \\  </td>
            \\  <td class="amount-cell">
            \\    <span class="amount">
        );
        try rows_html.appendSlice(allocator, amount_str);
        try rows_html.appendSlice(allocator,
            \\</span>
            \\  </td>
            \\</tr>
        );
    }

    const html = try std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html lang="pt-BR">
        \\<head>
        \\  <meta charset="UTF-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>Smoney - Dashboard</title>
        \\  <link rel="preconnect" href="https://fonts.googleapis.com">
        \\  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
        \\  <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\  <style>
        \\    :root {{
        \\      --bg-primary: #0f0f13;
        \\      --bg-secondary: #1a1a21;
        \\      --bg-card: #23232b;
        \\      --bg-card-hover: #2a2a35;
        \\      --text-primary: #ffffff;
        \\      --text-secondary: #9ca3af;
        \\      --text-muted: #6b7280;
        \\      --accent: #6366f1;
        \\      --accent-hover: #818cf8;
        \\      --success: #10b981;
        \\      --danger: #ef4444;
        \\      --border: #2d2d3a;
        \\      --gradient-card: linear-gradient(135deg, #23232b 0%, #1a1a21 100%);
        \\    }}
        \\    .nav {{
        \\      background: var(--bg-secondary);
        \\      border-bottom: 1px solid var(--border);
        \\      padding: 16px 32px;
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      position: sticky;
        \\      top: 0;
        \\      z-index: 100;
        \\    }}
        \\    .nav-brand {{
        \\      font-size: 24px;
        \\      font-weight: 700;
        \\      background: linear-gradient(135deg, #6366f1, #a855f7);
        \\      -webkit-background-clip: text;
        \\      -webkit-text-fill-color: transparent;
        \\      letter-spacing: -0.5px;
        \\    }}
        \\    .nav-status {{
        \\      font-size: 12px;
        \\      color: var(--text-muted);
        \\      display: flex;
        \\      align-items: center;
        \\      gap: 8px;
        \\    }}
        \\    .status-dot {{
        \\      width: 8px;
        \\      height: 8px;
        \\      border-radius: 50%;
        \\      background: var(--success);
        \\      animation: pulse 2s infinite;
        \\    }}
        \\    @keyframes pulse {{
        \\      0%, 100% {{ opacity: 1; }}
        \\      50% {{ opacity: 0.5; }}
        \\    }}
        \\    .container {{
        \\      max-width: 1200px;
        \\      margin: 0 auto;
        \\      padding: 32px;
        \\    }}
        \\    .metrics-grid {{
        \\      display: grid;
        \\      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
        \\      gap: 20px;
        \\      margin-bottom: 32px;
        \\    }}
        \\    .metric-card {{
        \\      background: var(--gradient-card);
        \\      border: 1px solid var(--border);
        \\      border-radius: 16px;
        \\      padding: 24px;
        \\      transition: transform 0.2s, box-shadow 0.2s;
        \\    }}
        \\    .metric-card:hover {{
        \\      transform: translateY(-2px);
        \\      box-shadow: 0 8px 32px rgba(0,0,0,0.3);
        \\    }}
        \\    .metric-card.highlight {{
        \\      background: linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%);
        \\      border-color: transparent;
        \\    }}
        \\    .metric-label {{
        \\      font-size: 13px;
        \\      font-weight: 500;
        \\      color: var(--text-secondary);
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.5px;
        \\      margin-bottom: 8px;
        \\    }}
        \\    .metric-value {{
        \\      font-size: 28px;
        \\      font-weight: 700;
        \\      letter-spacing: -0.5px;
        \\    }}
        \\    .metric-sub {{
        \\      font-size: 13px;
        \\      color: var(--text-muted);
        \\      margin-top: 4px;
        \\    }}
        \\    .section-title {{
        \\      font-size: 18px;
        \\      font-weight: 600;
        \\      margin-bottom: 16px;
        \\      color: var(--text-primary);
        \\    }}
        \\    .table-card {{
        \\      background: var(--bg-card);
        \\      border: 1px solid var(--border);
        \\      border-radius: 16px;
        \\      overflow: hidden;
        \\    }}
        \\    table {{
        \\      width: 100%%;
        \\      border-collapse: collapse;
        \\    }}
        \\    th {{
        \\      text-align: left;
        \\      padding: 16px 24px;
        \\      font-size: 12px;
        \\      font-weight: 600;
        \\      color: var(--text-muted);
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.5px;
        \\      background: var(--bg-secondary);
        \\      border-bottom: 1px solid var(--border);
        \\    }}
        \\    th:last-child {{
        \\      text-align: right;
        \\    }}
        \\    td {{
        \\      padding: 16px 24px;
        \\      border-bottom: 1px solid var(--border);
        \\    }}
        \\    td:last-child {{
        \\      text-align: right;
        \\    }}
        \\    tr:last-child td {{
        \\      border-bottom: none;
        \\    }}
        \\    tr:hover td {{
        \\      background: var(--bg-card-hover);
        \\    }}
        \\    .month-cell {{
        \\      display: flex;
        \\      flex-direction: column;
        \\      gap: 4px;
        \\    }}
        \\    .month-name {{
        \\      font-weight: 600;
        \\    }}
        \\    .variance-up, .variance-down, .variance-same {{
        \\      font-size: 12px;
        \\      font-weight: 500;
        \\    }}
        \\    .variance-up {{ color: var(--danger); }}
        \\    .variance-down {{ color: var(--success); }}
        \\    .variance-same {{ color: var(--text-muted); }}
        \\    .amount {{
        \\      font-weight: 600;
        \\      font-variant-numeric: tabular-nums;
        \\    }}
        \\    .loading {{
        \\      opacity: 0.5;
        \\    }}
        \\    @media (max-width: 768px) {{
        \\      .container {{ padding: 16px; }}
        \\      .metrics-grid {{ grid-template-columns: 1fr; }}
        \\      .nav {{ padding: 12px 16px; }}
        \\    }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <nav class="nav">
        \\    <div class="nav-brand">Smoney</div>
        \\    <div class="nav-status">
        \\      <span class="status-dot"></span>
        \\      <span>Atualizado agora</span>
        \\    </div>
        \\  </nav>
        \\  <div class="container">
        \\    <div class="metrics-grid" hx-get="/dashboard/data" hx-trigger="every 30s" hx-swap="innerHTML">
        \\      <div class="metric-card highlight">
        \\        <div class="metric-label">Total do Período</div>
        \\        <div class="metric-value">{s}</div>
        \\        <div class="metric-sub">{d} meses</div>
        \\      </div>
        \\      <div class="metric-card">
        \\        <div class="metric-label">Média Mensal</div>
        \\        <div class="metric-value">{s}</div>
        \\        <div class="metric-sub">por mês</div>
        \\      </div>
        \\      <div class="metric-card">
        \\        <div class="metric-label">Maior Gasto</div>
        \\        <div class="metric-value">{s}</div>
        \\        <div class="metric-sub">{s}</div>
        \\      </div>
        \\      <div class="metric-card">
        \\        <div class="metric-label">Menor Gasto</div>
        \\        <div class="metric-value">{s}</div>
        \\        <div class="metric-sub">{s}</div>
        \\      </div>
        \\    </div>
        \\    <h2 class="section-title">Resumo Mensal</h2>
        \\    <div class="table-card">
        \\      <table>
        \\        <thead>
        \\          <tr>
        \\            <th>Mês</th>
        \\            <th style="text-align: right;">Valor</th>
        \\          </tr>
        \\        </thead>
        \\        <tbody>
        \\          {s}
        \\        </tbody>
        \\      </table>
        \\    </div>
        \\  </div>
        \\</body>
        \\</html>
    , .{ total_str, summaries.len, avg_str, biggest_str, biggest_name, lowest_str, lowest_name, rows_html.items });

    return spider.Response.html(allocator, html);
}

pub fn dashboardDataHandler(allocator: std.mem.Allocator, req: *spider.Request) !spider.Response {
    _ = req;

    var repo = tx_repo.TransactionRepository.init(allocator, global_pool);

    const summaries = try repo.getMonthlySummary(global_user_id);
    defer allocator.free(summaries);

    // Calculate metrics
    var total: f64 = 0;
    var biggest_month: f64 = 0;
    var lowest_month: f64 = std.math.inf(f64);
    var biggest_idx: usize = 0;
    var lowest_idx: usize = 0;
    for (summaries, 0..) |s, i| {
        total += s.total;
        if (s.total > biggest_month) {
            biggest_month = s.total;
            biggest_idx = i;
        }
        if (s.total < lowest_month) {
            lowest_month = s.total;
            lowest_idx = i;
        }
    }
    const avg = if (summaries.len > 0) total / @as(f64, @floatFromInt(summaries.len)) else 0;

    const total_str = try formatCurrency(allocator, total);
    defer allocator.free(total_str);

    const avg_str = try formatCurrency(allocator, avg);
    defer allocator.free(avg_str);

    const biggest_str = try formatCurrency(allocator, biggest_month);
    defer allocator.free(biggest_str);

    const lowest_str = try formatCurrency(allocator, lowest_month);
    defer allocator.free(lowest_str);

    const biggest_name = month_names[summaries[biggest_idx].month - 1];
    const lowest_name = month_names[summaries[lowest_idx].month - 1];

    // Build HTML for each month with variance
    var rows_html = std.ArrayList(u8).empty;
    errdefer rows_html.deinit(allocator);

    for (summaries, 0..) |s, i| {
        const month_name = month_names[s.month - 1];
        const amount_str = try formatCurrency(allocator, s.total);
        defer allocator.free(amount_str);

        var variance_html: ?[]u8 = null;
        var variance_class: []const u8 = "";
        if (i > 0) {
            const prev = summaries[i - 1].total;
            const diff = s.total - prev;
            const pct = if (prev > 0) (diff / prev) * 100 else 0;
            if (diff > 0) {
                const pct_val = @abs(pct);
                const pct_int: i32 = @intFromFloat(@floor(pct_val));
                const pct_frac: u32 = @intFromFloat(@round((pct_val - @floor(pct_val)) * 10));
                variance_html = try std.fmt.allocPrint(allocator, "+{d}.{d}%%", .{ pct_int, pct_frac });
                variance_class = "variance-up";
            } else if (diff < 0) {
                const pct_val = @abs(pct);
                const pct_int: i32 = @intFromFloat(@floor(pct_val));
                const pct_frac: u32 = @intFromFloat(@round((pct_val - @floor(pct_val)) * 10));
                variance_html = try std.fmt.allocPrint(allocator, "-{d}.{d}%%", .{ pct_int, pct_frac });
                variance_class = "variance-down";
            } else {
                variance_html = try std.fmt.allocPrint(allocator, "0.0%%", .{});
                variance_class = "variance-same";
            }
        }
        defer if (variance_html) |v| allocator.free(v);

        try rows_html.appendSlice(allocator,
            \\<tr>
            \\  <td class="month-cell">
            \\    <span class="month-name"> 
        );
        try rows_html.appendSlice(allocator, month_name);
        try rows_html.appendSlice(allocator, "/");
        try rows_html.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{s.year}));
        try rows_html.appendSlice(allocator,
            \\</span>
            \\    <span class="
        );
        try rows_html.appendSlice(allocator, variance_class);
        try rows_html.appendSlice(allocator, "\">");
        try rows_html.appendSlice(allocator, if (variance_html) |v| v else "");
        try rows_html.appendSlice(allocator,
            \\</span>
            \\  </td>
            \\  <td class="amount-cell">
            \\    <span class="amount">
        );
        try rows_html.appendSlice(allocator, amount_str);
        try rows_html.appendSlice(allocator,
            \\</span>
            \\  </td>
            \\</tr>
        );
    }

    const html = try std.fmt.allocPrint(allocator,
        \\<div class="metrics-grid">
        \\  <div class="metric-card highlight">
        \\    <div class="metric-label">Total do Período</div>
        \\    <div class="metric-value">{s}</div>
        \\    <div class="metric-sub">{d} meses</div>
        \\  </div>
        \\  <div class="metric-card">
        \\    <div class="metric-label">Média Mensal</div>
        \\    <div class="metric-value">{s}</div>
        \\    <div class="metric-sub">por mês</div>
        \\  </div>
        \\  <div class="metric-card">
        \\    <div class="metric-label">Maior Gasto</div>
        \\    <div class="metric-value">{s}</div>
        \\    <div class="metric-sub">{s}</div>
        \\  </div>
        \\  <div class="metric-card">
        \\    <div class="metric-label">Menor Gasto</div>
        \\    <div class="metric-value">{s}</div>
        \\    <div class="metric-sub">{s}</div>
        \\  </div>
        \\</div>
        \\<h2 class="section-title">Resumo Mensal</h2>
        \\<div class="table-card">
        \\  <table>
        \\    <thead>
        \\      <tr>
        \\        <th>Mês</th>
        \\        <th style="text-align: right;">Valor</th>
        \\      </tr>
        \\    </thead>
        \\    <tbody>
        \\      {s}
        \\    </tbody>
        \\  </table>
        \\</div>
    , .{ total_str, summaries.len, avg_str, biggest_str, biggest_name, lowest_str, lowest_name, rows_html.items });

    return spider.Response.html(allocator, html);
}

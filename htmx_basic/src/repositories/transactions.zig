const std = @import("std");
const spider_pg = @import("spider_pg");

pub const Transaction = struct {
    id: u64,
    user_id: u64,
    date: []const u8,
    title: []const u8,
    amount: f64,
    competencia_year: i32,
    competencia_month: u8,
    is_expense: bool,
};

pub const CreateTransactionInput = struct {
    user_id: u64,
    date: []const u8,
    title: []const u8,
    amount: f64,
    competencia_year: i32,
    competencia_month: u8,
    is_expense: bool,
};

pub const MonthlySummary = struct {
    year: i32,
    month: u8,
    total: f64,
    count: i32,
};

pub const TransactionRepository = struct {
    allocator: std.mem.Allocator,
    pool: *spider_pg.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *spider_pg.Pool) TransactionRepository {
        return .{ .allocator = allocator, .pool = pool };
    }

    // ─── Create ───────────────────────────────────────────

    pub fn create(self: TransactionRepository, input: CreateTransactionInput) !Transaction {
        const sql =
            \\INSERT INTO transactions
            \\  (user_id, date, title, amount, competencia_year, competencia_month, is_expense)
            \\VALUES ($1, $2, $3, $4, $5, $6, $7)
            \\ON CONFLICT (user_id, date, title, amount) DO NOTHING
            \\RETURNING id
        ;
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const user_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.user_id});
        defer self.allocator.free(user_id_str);
        const amount_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{input.amount});
        defer self.allocator.free(amount_str);
        const year_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.competencia_year});
        defer self.allocator.free(year_str);
        const month_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.competencia_month});
        defer self.allocator.free(month_str);
        const expense_str = if (input.is_expense) "true" else "false";

        var result = try spider_pg.queryParams(conn, sql, &.{
            user_id_str, input.date, input.title,
            amount_str,  year_str,   month_str,
            expense_str,
        }, self.allocator);
        defer result.deinit();

        return Transaction{
            .id = if (result.rows() > 0) try std.fmt.parseInt(u64, result.getValue(0, 0), 10) else 0,
            .user_id = input.user_id,
            .date = try self.allocator.dupe(u8, input.date),
            .title = try self.allocator.dupe(u8, input.title),
            .amount = input.amount,
            .competencia_year = input.competencia_year,
            .competencia_month = input.competencia_month,
            .is_expense = input.is_expense,
        };
    }

    pub fn findByCompetencia(self: TransactionRepository, user_id: u64, year: i32, month: u8) ![]Transaction {
        const sql =
            \\SELECT id, user_id, date, title, amount, competencia_year, competencia_month, is_expense
            \\FROM transactions 
            \\WHERE user_id = $1 AND competencia_year = $2 AND competencia_month = $3
            \\ORDER BY date DESC
        ;
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const user_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{user_id});
        defer self.allocator.free(user_id_str);
        const year_str = try std.fmt.allocPrint(self.allocator, "{d}", .{year});
        defer self.allocator.free(year_str);
        const month_str = try std.fmt.allocPrint(self.allocator, "{d}", .{month});
        defer self.allocator.free(month_str);

        var result = try spider_pg.queryParams(conn, sql, &.{ user_id_str, year_str, month_str }, self.allocator);
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]Transaction{};

        var txns = try self.allocator.alloc(Transaction, count);
        errdefer self.allocator.free(txns);

        for (0..count) |i| {
            txns[i] = try self.rowToTransaction(&result, i);
        }
        return txns;
    }

    // ─── Read ─────────────────────────────────────────────

    pub fn findById(self: TransactionRepository, id: u64) !?Transaction {
        const sql = "SELECT id, user_id, date, title, amount, competencia_year, competencia_month, is_expense FROM transactions WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return null;
        return try self.rowToTransaction(&result, 0);
    }

    pub fn findByUser(self: TransactionRepository, user_id: u64) ![]Transaction {
        const sql =
            \\SELECT id, user_id, date, title, amount, competencia_year, competencia_month, is_expense
            \\FROM transactions WHERE user_id = $1 ORDER BY date
        ;
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const user_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{user_id});
        defer self.allocator.free(user_id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{user_id_str}, self.allocator);
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]Transaction{};

        var txns = try self.allocator.alloc(Transaction, count);
        errdefer self.allocator.free(txns);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            txns[i] = try self.rowToTransaction(&result, i);
        }
        return txns;
    }

    pub fn getByMonth(self: TransactionRepository, user_id: u64, month: u8, year: i32) ![]Transaction {
        const sql =
            \\SELECT id, user_id, date, title, amount::text,
            \\       competencia_year, competencia_month, is_expense
            \\FROM transactions
            \\WHERE user_id = $1 AND competencia_month = $2 AND competencia_year = $3
            \\ORDER BY date ASC
        ;
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const u_str = try std.fmt.allocPrint(self.allocator, "{d}", .{user_id});
        const m_str = try std.fmt.allocPrint(self.allocator, "{d}", .{month});
        const y_str = try std.fmt.allocPrint(self.allocator, "{d}", .{year});
        defer {
            self.allocator.free(u_str);
            self.allocator.free(m_str);
            self.allocator.free(y_str);
        }

        var result = try spider_pg.queryParams(conn, sql, &.{ u_str, m_str, y_str }, self.allocator);
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]Transaction{};

        var txs = try self.allocator.alloc(Transaction, count);
        errdefer self.allocator.free(txs);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            txs[i] = try self.rowToTransaction(&result, i);
        }
        return txs;
    }

    pub fn getMonthlySummary(self: TransactionRepository, user_id: u64) ![]MonthlySummary {
        const sql =
            \\SELECT competencia_year, competencia_month,
            \\       SUM(amount)::text, COUNT(*)::text
            \\FROM transactions
            \\WHERE user_id = $1 AND is_expense = true
            \\GROUP BY competencia_year, competencia_month
            \\ORDER BY competencia_year, competencia_month
        ;
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const user_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{user_id});
        defer self.allocator.free(user_id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{user_id_str}, self.allocator);
        defer result.deinit();

        const count = result.rows();
        if (count == 0) return &[_]MonthlySummary{};

        var summaries = try self.allocator.alloc(MonthlySummary, count);
        errdefer self.allocator.free(summaries);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            summaries[i] = .{
                .year = try std.fmt.parseInt(i32, result.getValue(i, 0), 10),
                .month = try std.fmt.parseInt(u8, result.getValue(i, 1), 10),
                .total = try std.fmt.parseFloat(f64, result.getValue(i, 2)),
                .count = try std.fmt.parseInt(i32, result.getValue(i, 3), 10),
            };
        }
        return summaries;
    }

    // ─── Delete ───────────────────────────────────────────

    pub fn delete(self: TransactionRepository, id: u64) !bool {
        const sql = "DELETE FROM transactions WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        return true;
    }

    pub fn deleteByUser(self: TransactionRepository, user_id: u64) !void {
        const sql = "DELETE FROM transactions WHERE user_id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const user_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{user_id});
        defer self.allocator.free(user_id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{user_id_str}, self.allocator);
        defer result.deinit();
    }

    // ─── Helpers ──────────────────────────────────────────

    // Altere a assinatura para aceitar o ponteiro mutável do Result
    fn rowToTransaction(self: TransactionRepository, result: *spider_pg.Result, i: usize) !Transaction {
        return Transaction{
            .id = try std.fmt.parseInt(u64, result.getValue(i, 0), 10),
            .user_id = try std.fmt.parseInt(u64, result.getValue(i, 1), 10),
            .date = try self.allocator.dupe(u8, result.getValue(i, 2)),
            .title = try self.allocator.dupe(u8, result.getValue(i, 3)),
            .amount = try std.fmt.parseFloat(f64, result.getValue(i, 4)),
            .competencia_year = try std.fmt.parseInt(i32, result.getValue(i, 5), 10),
            .competencia_month = try std.fmt.parseInt(u8, result.getValue(i, 6), 10),
            .is_expense = std.mem.eql(u8, result.getValue(i, 7), "true"),
        };
    }
};

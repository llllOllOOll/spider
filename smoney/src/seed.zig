const std = @import("std");
const db_tx = @import("db/transactions.zig");
const parser = @import("finance/parser.zig");

const CSV_DIR = "data/";

const csv_files = [_][]const u8{
    CSV_DIR ++ "Nubank_2025-07-27.csv",
    CSV_DIR ++ "Nubank_2025-08-27.csv",
    CSV_DIR ++ "Nubank_2025-09-27.csv",
    CSV_DIR ++ "Nubank_2025-10-27.csv",
    CSV_DIR ++ "Nubank_2025-11-27.csv",
    CSV_DIR ++ "Nubank_2025-12-27.csv",
    CSV_DIR ++ "Nubank_2026-01-27.csv",
    CSV_DIR ++ "Nubank_2026-02-27.csv",
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, pool: anytype, user_id: u64) !void {
    var repo = db_tx.TransactionRepository.init(allocator, pool);

    // Check if already seeded
    const existing = try repo.getMonthlySummary(user_id);
    defer allocator.free(existing);
    if (existing.len > 0) {
        std.log.info("Seed: already has data, skipping", .{});
        return;
    }

    std.log.info("Seed: importing CSVs...", .{});
    for (csv_files) |csv_path| {
        const parsed = parser.parseCSV(io, allocator, csv_path, user_id) catch |err| {
            std.log.warn("Seed: skipping {s} — {}", .{ csv_path, err });
            continue;
        };
        defer allocator.free(parsed);

        var inserted: usize = 0;
        for (parsed) |tx| {
            _ = repo.create(tx) catch continue;
            inserted += 1;
        }
        std.log.info("Seed: {s} — {d} transactions", .{ csv_path, inserted });
    }
    std.log.info("Seed: done", .{});
}

const std = @import("std");
const spider_pg = @import("spider_pg");

pub fn run(pool: *spider_pg.Pool) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    var products_result = try spider_pg.query(conn, "CREATE TABLE IF NOT EXISTS products (" ++
        "id BIGSERIAL PRIMARY KEY," ++
        "name TEXT NOT NULL," ++
        "price NUMERIC(10,2) NOT NULL" ++
        ")");
    products_result.deinit();

    var db_result = try spider_pg.query(conn, "SELECT current_database()");
    defer db_result.deinit();

    const db_name = db_result.getValue(0, 0);
    std.log.info("Migrations applied to database: {s}", .{db_name});
}

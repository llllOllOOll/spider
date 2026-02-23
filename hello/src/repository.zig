const std = @import("std");
const spider_pg = @import("spider_pg");

pub const Product = struct {
    id: u64,
    name: []const u8,
    price: []const u8,
};

pub const CreateProductInput = struct {
    name: []const u8,
    price: []const u8,
};

pub const ProductRepository = struct {
    allocator: std.mem.Allocator,
    pool: *spider_pg.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *spider_pg.Pool) ProductRepository {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn createTable(self: ProductRepository) !void {
        const sql = "CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, price VARCHAR(255) NOT NULL)";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);
        _ = try spider_pg.query(conn, sql);
    }

    pub fn list(self: ProductRepository) ![]Product {
        const sql = "SELECT id, name, price FROM products ORDER BY id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.query(conn, sql);
        defer result.deinit();

        const row_count = result.rows();
        if (row_count == 0) return &[_]Product{};

        var products = try self.allocator.alloc(Product, row_count);
        errdefer self.allocator.free(products);

        var i: usize = 0;
        while (i < row_count) : (i += 1) {
            const id = try std.fmt.parseInt(u64, result.getValue(i, 0), 10);
            const name = try self.allocator.dupe(u8, result.getValue(i, 1));
            const price = try self.allocator.dupe(u8, result.getValue(i, 2));

            products[i] = .{
                .id = id,
                .name = name,
                .price = price,
            };
        }

        return products;
    }

    pub fn getByName(self: ProductRepository, name: []const u8) !?Product {
        const sql = "SELECT id, name, price FROM products WHERE name = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.queryParams(conn, sql, &.{name}, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return null;

        const id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10);
        const found_name = try self.allocator.dupe(u8, result.getValue(0, 1));
        const price = try self.allocator.dupe(u8, result.getValue(0, 2));

        return .{
            .id = id,
            .name = found_name,
            .price = price,
        };
    }

    pub fn create(self: ProductRepository, input: CreateProductInput) !Product {
        const sql = "INSERT INTO products (name, price) VALUES ($1, $2) RETURNING id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result = try spider_pg.queryParams(conn, sql, &.{ input.name, input.price }, self.allocator);
        defer result.deinit();

        const id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10);

        return .{
            .id = id,
            .name = input.name,
            .price = input.price,
        };
    }
};

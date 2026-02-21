const std = @import("std");
const spider_pg = @import("spider_pg");

pub const Product = struct {
    id: u64,
    name: []const u8,
    price: f64,
    quantity: u32,
};

pub const CreateProductInput = struct {
    name: []const u8,
    price: f64,
    quantity: u32,
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
        const sql = "CREATE TABLE IF NOT EXISTS products (id SERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, price DECIMAL(10,2) NOT NULL, quantity INTEGER NOT NULL DEFAULT 0)";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);
        _ = try spider_pg.query(conn, sql);
    }

    pub fn list(self: ProductRepository) ![]Product {
        const sql = "SELECT id, name, price, quantity FROM products ORDER BY id";
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
            const price = try std.fmt.parseFloat(f64, result.getValue(i, 2));
            const quantity = try std.fmt.parseInt(u32, result.getValue(i, 3), 10);

            products[i] = .{
                .id = id,
                .name = name,
                .price = price,
                .quantity = quantity,
            };
        }

        return products;
    }

    pub fn getById(self: ProductRepository, id: u64) !?Product {
        const sql = "SELECT id, name, price, quantity FROM products WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return null;

        const row_id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10);
        const name = try self.allocator.dupe(u8, result.getValue(0, 1));
        const price = try std.fmt.parseFloat(f64, result.getValue(0, 2));
        const quantity = try std.fmt.parseInt(u32, result.getValue(0, 3), 10);

        return .{
            .id = row_id,
            .name = name,
            .price = price,
            .quantity = quantity,
        };
    }

    pub fn create(self: ProductRepository, input: CreateProductInput) !Product {
        const sql = "INSERT INTO products (name, price, quantity) VALUES ($1, $2, $3) RETURNING id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const price_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.price});
        defer self.allocator.free(price_str);
        const quantity_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.quantity});
        defer self.allocator.free(quantity_str);

        var result = try spider_pg.queryParams(conn, sql, &.{ input.name, price_str, quantity_str }, self.allocator);
        defer result.deinit();

        const id = try std.fmt.parseInt(u64, result.getValue(0, 0), 10);

        return .{
            .id = id,
            .name = input.name,
            .price = input.price,
            .quantity = input.quantity,
        };
    }

    pub fn update(self: ProductRepository, id: u64, input: CreateProductInput) !Product {
        const sql = "UPDATE products SET name = $1, price = $2, quantity = $3 WHERE id = $4 RETURNING id";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);
        const price_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.price});
        defer self.allocator.free(price_str);
        const quantity_str = try std.fmt.allocPrint(self.allocator, "{d}", .{input.quantity});
        defer self.allocator.free(quantity_str);

        var result = try spider_pg.queryParams(conn, sql, &.{ input.name, price_str, quantity_str, id_str }, self.allocator);
        defer result.deinit();

        if (result.rows() == 0) return error.NotFound;

        return .{
            .id = id,
            .name = input.name,
            .price = input.price,
            .quantity = input.quantity,
        };
    }

    pub fn delete(self: ProductRepository, id: u64) !void {
        const sql = "DELETE FROM products WHERE id = $1";
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
        defer self.allocator.free(id_str);

        var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
        defer result.deinit();

        if (result.affectedRows() == 0) return error.NotFound;
    }
};

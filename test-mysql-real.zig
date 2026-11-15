// Real test of the MySQL driver over a TCP connection
const std = @import("std");
const mysql = @import("./src/drivers/mysql/mysql.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("=== REAL MYSQL TEST ===", .{});

    // Threaded Io instance
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // MySQL driver
    std.log.info("Initializing the MySQL driver...", .{});

    try mysql.init(allocator, io, .{
        .host = "localhost",
        .port = 3306,
        .database = "spider_db",
        .user = "spider",
        .password = "spider_password",
        .pool_size = 3,
    });
    defer mysql.deinit();

    std.log.info("✅ MySQL driver initialized", .{});

    // Basic queries
    var query_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer query_arena.deinit();

    const Todo = struct {
        id: i32,
        title: []const u8,
        completed: bool,
    };

    // Test 1: plain query
    std.log.info("Test 1: SELECT query...", .{});
    const todos = mysql.query(Todo, query_arena.allocator(), "SELECT * FROM todos", .{}) catch |err| {
        std.log.info("❌ Query failed (expected): {}", .{err});
        return;
    };

    std.log.info("✅ Query ran", .{});
    std.log.info("Returned {} todos", .{todos.len});

    for (todos) |todo| {
        std.log.info("Todo: id={}, title='{s}', completed={}", .{ todo.id, todo.title, todo.completed });
    }

    // Test 2: query with parameters
    std.log.info("Test 2: query with parameters...", .{});
    const User = struct {
        id: i32,
        name: []const u8,
        email: []const u8,
    };

    const user = mysql.queryOne(User, query_arena.allocator(), "SELECT * FROM users WHERE id = ?", .{1}) catch |err| {
        std.log.info("❌ Query with parameters failed (expected): {}", .{err});
        return;
    };

    if (user) |u| {
        std.log.info("✅ User found: id={}, name='{s}', email='{s}'", .{ u.id, u.name, u.email });
    } else {
        std.log.info("❌ User not found", .{});
    }

    std.log.info("=== TEST DONE ===", .{});
}

// Simple MySQL test script
const std = @import("std");
const mysql = @import("./src/drivers/mysql/mysql.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("Testing MySQL driver setup", .{});

    // Create threaded Io instance
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // Initialize MySQL connection
    try mysql.init(allocator, io, .{
        .host = "localhost",
        .port = 3306,
        .database = "spider_db",
        .user = "spider",
        .password = "spider_password",
        .pool_size = 5,
    });
    defer mysql.deinit();

    std.log.info("MySQL driver initialized successfully", .{});

    // Test simple query
    var query_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer query_arena.deinit();

    const Todo = struct {
        id: i32,
        title: []const u8,
        completed: bool,
    };

    // Test query (this will fail until full implementation)
    const todos = mysql.query(Todo, query_arena.allocator(), "SELECT * FROM todos", .{}) catch |err| {
        std.log.info("Query failed as expected (not implemented): {}", .{err});
        return;
    };

    std.log.info("Retrieved {} todos", .{todos.len});
    for (todos) |todo| {
        std.log.info("Todo: id={}, title='{s}', completed={}", .{ todo.id, todo.title, todo.completed });
    }
}

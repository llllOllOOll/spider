// Teste real do driver MySQL com conexão TCP
const std = @import("std");
const mysql = @import("./src/drivers/mysql/mysql.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.log.info("=== TESTE REAL MYSQL ===", .{});

    // Criar threaded Io instance
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    // Inicializar driver MySQL
    std.log.info("Inicializando driver MySQL...", .{});

    try mysql.init(allocator, io, .{
        .host = "localhost",
        .port = 3306,
        .database = "spider_db",
        .user = "spider",
        .password = "spider_password",
        .pool_size = 3,
    });
    defer mysql.deinit();

    std.log.info("✅ Driver MySQL inicializado com sucesso", .{});

    // Testar consultas básicas
    var query_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer query_arena.deinit();

    const Todo = struct {
        id: i32,
        title: []const u8,
        completed: bool,
    };

    // Teste 1: Consulta simples
    std.log.info("Teste 1: Consulta SELECT...", .{});
    const todos = mysql.query(Todo, query_arena.allocator(), "SELECT * FROM todos", .{}) catch |err| {
        std.log.info("❌ Consulta falhou (esperado): {}", .{err});
        return;
    };

    std.log.info("✅ Consulta executada com sucesso", .{});
    std.log.info("Retornados {} todos", .{todos.len});

    for (todos) |todo| {
        std.log.info("Todo: id={}, title='{s}', completed={}", .{ todo.id, todo.title, todo.completed });
    }

    // Teste 2: Consulta com parâmetros
    std.log.info("Teste 2: Consulta com parâmetros...", .{});
    const User = struct {
        id: i32,
        name: []const u8,
        email: []const u8,
    };

    const user = mysql.queryOne(User, query_arena.allocator(), "SELECT * FROM users WHERE id = ?", .{1}) catch |err| {
        std.log.info("❌ Consulta com parâmetros falhou (esperado): {}", .{err});
        return;
    };

    if (user) |u| {
        std.log.info("✅ Usuário encontrado: id={}, name='{s}', email='{s}'", .{ u.id, u.name, u.email });
    } else {
        std.log.info("❌ Usuário não encontrado", .{});
    }

    std.log.info("=== TESTE CONCLUÍDO ===", .{});
}

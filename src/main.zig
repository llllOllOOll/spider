const std = @import("std");
const spider = @import("spider");
const Response = spider.Response;

var request_count: u64 = 0;

fn rootHandler(c: *spider.Ctx) !Response {
    request_count += 1;
    return c.json(.{ .message = "Hello from Spider!", .status = "OK", .requests = request_count }, .{});
}

fn healthHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .status = "healthy", .requests_served = request_count }, .{});
}

fn echoHandler(c: *spider.Ctx) !Response {
    return c.text("Echo response: Simple and fast!", .{});
}

fn userHandler(c: *spider.Ctx) !Response {
    const path = c.getPath();
    const user_id = if (std.mem.startsWith(u8, path, "/users/"))
        path["/users/".len..]
    else
        "unknown";
    return c.json(.{ .user_id = user_id, .name = "John Doe", .email = "john@example.com" }, .{});
}

fn htmlHandler(c: *spider.Ctx) !Response {
    return c.render("Hello {{ name }}!", .{ .name = "Spider" }, .{});
}

fn arenaHandler(c: *spider.Ctx) !Response {
    const msg = try std.fmt.allocPrint(c.arena, "Request arena working! Thread: {d}", .{std.Thread.getCurrentId()});
    return c.json(.{ .message = msg }, .{});
}

fn createdHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .id = 1, .created = true }, .{ .status = .created });
}

fn headersHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .ok = true }, .{
        .headers = &.{
            .{ "X-Powered-By", "Spider" },
            .{ "X-Version", "0.3.0" },
        },
    });
}

fn queryHandler(c: *spider.Ctx) !Response {
    const name = c.query("name") orelse "World";
    return c.json(.{ .hello = name }, .{});
}

fn headerHandler(c: *spider.Ctx) !Response {
    const ua = c.header("User-Agent") orelse "unknown";
    return c.json(.{ .user_agent = ua }, .{});
}

fn redirectHandler(c: *spider.Ctx) !Response {
    return c.redirect("/");
}

fn echoBodyHandler(c: *spider.Ctx) !Response {
    const raw = c.getBody() orelse return c.text("no body", .{});
    return c.text(raw, .{});
}

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

fn createUserHandler(c: *spider.Ctx) !Response {
    const user = try c.bodyJson(CreateUser);
    return c.json(.{
        .created = true,
        .name = user.name,
        .email = user.email,
    }, .{ .status = .created });
}

fn loggerMiddleware(c: *spider.Ctx, next: spider.NextFn) !Response {
    std.debug.print("[{s}] {s}\n", .{ c.getMethod(), c.getPath() });
    const res = try next(c);
    std.debug.print("  -> {d}\n", .{@intFromEnum(res.status)});
    return res;
}

fn authMiddleware(c: *spider.Ctx, next: spider.NextFn) !Response {
    const token = c.header("Authorization") orelse
        return c.text("Unauthorized", .{ .status = .unauthorized });
    _ = token;
    return next(c);
}

fn dashHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .page = "dashboard" }, .{});
}

fn usersListHandler(c: *spider.Ctx) !Response {
    return c.json(.{ .page = "users" }, .{});
}

fn cookieHandler(c: *spider.Ctx) !Response {
    const session = c.cookie("session");
    return c.json(.{
        .existing_session = session orelse "none",
    }, try c.withCookie("session", "abc123", .{ .max_age = 3600, .secure = false }));
}

fn htmxHandler(c: *spider.Ctx) !Response {
    if (c.isHtmx()) {
        return c.html("<div>Partial response for HTMX</div>", .{});
    }
    return c.html("<html><body><div>Full page</div></body></html>", .{});
}

fn slowMiddleware(c: *spider.Ctx, next: spider.NextFn) !spider.Response {
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {}
    return next(c);
}

fn slowHandler(c: *spider.Ctx) !spider.Response {
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {}
    return c.json(.{ .ok = true }, .{});
}

fn slowRoutes(s: *spider.Server, prefix: []const u8, middlewares: []const spider.MiddlewareFn) void {
    s.addRoute(.GET, std.fmt.allocPrint(s.allocator, "{s}/", .{prefix}) catch "/slow/", middlewares, slowHandler);
}

fn apiMiddleware(c: *spider.Ctx, next: spider.NextFn) !Response {
    std.debug.print("[API] {s}\n", .{c.getPath()});
    return next(c);
}

const PgDriver = spider.PgDriver;

const Todo = struct {
    id: i32, // SQLite usa INTEGER (equivale a i32)
    title: []const u8,
    completed: bool, // SQLite usa 0/1 para boolean
    created_at: []const u8, // SQLite armazena como TEXT
    updated_at: []const u8, // SQLite armazena como TEXT
};

fn sqliteTestHandler(c: *spider.Ctx) !Response {
    // Teste básico do SQLite
    try c.db().exec("CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY, name TEXT)");

    const result = try c.db().query(
        struct { id: i32, name: []const u8 },
        "SELECT id, name FROM test",
        .{},
    );

    return c.json(.{ .driver = "SQLite", .items = result, .count = result.len }, .{});
}

fn todosHandler(c: *spider.Ctx) !Response {
    const todos = try c.db().query(
        Todo,
        "SELECT id, title, completed, created_at, updated_at FROM todos LIMIT 5",
        .{},
    );
    return c.json(.{ .todos = todos, .count = todos.len }, .{});
}

fn globalErrorHandler(c: *spider.Ctx, err: anyerror) !Response {
    std.log.err("caught: {s}", .{@errorName(err)});
    return c.json(.{
        .error_name = @errorName(err),
        .path = c.getPath(),
    }, .{ .status = .internal_server_error });
}

fn brokenHandler(c: *spider.Ctx) !Response {
    _ = c;
    return error.SomethingWentWrong;
}

fn dashboardRoutes(s: *spider.Server, prefix: []const u8, middlewares: []const spider.MiddlewareFn) void {
    s.addRoute(.GET, std.fmt.allocPrint(s.allocator, "{s}/", .{prefix}) catch "/dashboard/", middlewares, dashHandler);
    s.addRoute(.GET, std.fmt.allocPrint(s.allocator, "{s}/users", .{prefix}) catch "/dashboard/users", middlewares, usersListHandler);
}

pub fn main() void {
    // Initialize SQLite connection (usaremos SQLite para teste)
    spider.sqlite.init(std.heap.page_allocator, .{
        .filename = "test.db",
    }) catch {
        std.debug.print("Failed to initialize SQLite\n", .{});
        return;
    };
    defer spider.sqlite.deinit();

    // Initialize PostgreSQL connection
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    spider.pg.init(std.heap.page_allocator, io, .{
        .host = "localhost",
        .port = 5434,
        .user = "spider",
        .password = "spider",
        .database = "spiderdb",
    }) catch {
        std.debug.print("Failed to initialize PostgreSQL\n", .{});
        return;
    };
    defer spider.pg.deinit();

    var server = spider.app();
    defer server.deinit();
    server
        .use(loggerMiddleware)
        .useAt("/api/*", apiMiddleware)
        .onError(globalErrorHandler)
        // Usar SQLite para teste
        .db(blk: {
            var driver = spider.SqliteDriver{};
            break :blk driver.database();
        })
        .get("/", rootHandler)
        .get("/broken", brokenHandler)
        .get("/api/users", usersListHandler)
        .get("/health", healthHandler)
        .get("/echo", echoHandler)
        .get("/users/:id", userHandler)
        .get("/html", htmlHandler)
        .get("/arena", arenaHandler)
        .get("/created", createdHandler)
        .get("/headers", headersHandler)
        .get("/query", queryHandler)
        .get("/useragent", headerHandler)
        .get("/redirect", redirectHandler)
        .get("/cookie", cookieHandler)
        .get("/htmx", htmxHandler)
        .get("/todos", todosHandler)
        .get("/sqlite-test", sqliteTestHandler)
        .post("/echo-body", echoBodyHandler)
        .post("/users", createUserHandler)
        .group("/dashboard", &.{authMiddleware}, dashboardRoutes)
        .group("/slow", &.{slowMiddleware}, slowRoutes)
        .listen(3000) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}

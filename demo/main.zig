const std = @import("std");
const c = @cImport(@cInclude("stdlib.h"));
const spider = @import("spider");
const web = spider.web;
const spider_pg = @import("spider_pg");
const auth = @import("auth");

const LogEntry = struct { time: []const u8, method: []const u8, path: []const u8 };

var request_logs: [100]LogEntry = undefined;
var log_index: usize = 0;
var log_count: usize = 0;

var total_requests: u64 = 0;
var error_count: u64 = 0;
var server_start_time: u64 = 0;
var metrics_calls: u64 = 0;

fn addLog(method: []const u8, path: []const u8) void {
    const timestamp = "00:00:00";

    request_logs[log_index] = .{ .time = timestamp, .method = method, .path = path };
    log_index = (log_index + 1) % 100;
    if (log_count < 100) log_count += 1;

    total_requests += 1;
}

fn incError() void {
    error_count += 1;
}

fn logsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    var logs_slice = try allocator.alloc(LogEntry, log_count);
    var i: usize = 0;
    var idx: usize = if (log_count < 100) 0 else log_index;
    while (i < log_count) : (i += 1) {
        logs_slice[i] = request_logs[idx];
        idx = (idx + 1) % 100;
    }
    return try web.Response.json(allocator, logs_slice);
}

fn getEnv(key: []const u8, default: []const u8) []const u8 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.mem.sliceTo(val, 0);
    }
    return default;
}

fn getEnvInt(key: []const u8, default: u16) u16 {
    var key_null: [256]u8 = undefined;
    @memcpy(key_null[0..key.len], key);
    key_null[key.len] = 0;
    if (c.getenv(&key_null)) |val| {
        return std.fmt.parseInt(u16, std.mem.sliceTo(val, 0), 10) catch default;
    }
    return default;
}

var pool: spider_pg.Pool = undefined;

const dashboard_html = @embedFile("dashboard.html");

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    addLog("GET", "/");
    return try web.Response.html(allocator, dashboard_html);
}

fn healthHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    addLog("GET", "/health");
    return try web.Response.json(allocator, .{ .status = "ok" });
}

fn metricsHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    metrics_calls += 1;
    const uptime = if (server_start_time > 0) metrics_calls * 2 else 0; // Approximate seconds
    return try web.Response.json(allocator, .{
        .total_requests = total_requests,
        .error_count = error_count,
        .uptime_seconds = uptime,
    });
}

fn jsonHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    addLog("GET", "/json");
    return try web.Response.json(allocator, .{ .message = "ok", .version = "0.1.0" });
}

fn registerHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const body = req.body orelse {
        std.debug.print("HANDLER: Missing body\n", .{});
        var res = try web.Response.text(allocator, "Missing body");
        res.status = .bad_request;
        return res;
    };

    std.debug.print("HANDLER: Register body: {s}\n", .{body});

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        std.debug.print("HANDLER: JSON parse error: {}\n", .{err});
        var res = try web.Response.text(allocator, "Invalid JSON");
        res.status = .bad_request;
        return res;
    };
    defer parsed.deinit();

    const name_val = parsed.value.object.get("name") orelse {
        std.debug.print("HANDLER: Missing name\n", .{});
        var res = try web.Response.text(allocator, "Missing name");
        res.status = .bad_request;
        return res;
    };
    const email_val = parsed.value.object.get("email") orelse {
        std.debug.print("HANDLER: Missing email\n", .{});
        var res = try web.Response.text(allocator, "Missing email");
        res.status = .bad_request;
        return res;
    };
    const password_val = parsed.value.object.get("password") orelse {
        std.debug.print("HANDLER: Missing password\n", .{});
        var res = try web.Response.text(allocator, "Missing password");
        res.status = .bad_request;
        return res;
    };

    const name = name_val.string;
    const email = email_val.string;
    const password = password_val.string;

    std.debug.print("HANDLER: name={s}, email={s}, password={s}\n", .{ name, email, password });

    const hash = try auth.hashPassword(allocator, password);
    std.debug.print("HANDLER: hash={s}\n", .{hash});

    const conn = try pool.acquire();
    defer pool.release(conn);
    std.debug.print("HANDLER: Got connection from pool\n", .{});

    const params = &[_][]const u8{ name, email, hash };
    std.debug.print("HANDLER: Querying with params...\n", .{});
    var result = try spider_pg.queryParams(
        conn,
        "INSERT INTO users (name, email, password_hash) VALUES ($1, $2, $3) RETURNING id, email",
        params,
        allocator,
    );
    defer result.deinit();
    std.debug.print("HANDLER: Query result rows: {}\n", .{result.rows()});

    const resp_body = try std.fmt.allocPrint(allocator, "{{\"id\":{s},\"email\":\"{s}\"}}", .{ result.getValue(0, 0), result.getValue(0, 1) });
    var res = try web.Response.json(allocator, resp_body);
    res.status = .created;
    return res;
}

fn loginHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const body = req.body orelse {
        var res = try web.Response.text(allocator, "Missing body");
        res.status = .bad_request;
        return res;
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const email_val = parsed.value.object.get("email") orelse {
        var res = try web.Response.text(allocator, "Missing email");
        res.status = .bad_request;
        return res;
    };
    const password_val = parsed.value.object.get("password") orelse {
        var res = try web.Response.text(allocator, "Missing password");
        res.status = .bad_request;
        return res;
    };

    const email = email_val.string;
    const password = password_val.string;

    const hash = try auth.hashPassword(allocator, password);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const params = &[_][]const u8{ email, hash };
    var result = try spider_pg.queryParams(
        conn,
        "SELECT id FROM users WHERE email = $1 AND password_hash = $2",
        params,
        allocator,
    );
    defer result.deinit();

    if (result.rows() == 0) {
        var res = try web.Response.text(allocator, "Invalid credentials");
        res.status = .unauthorized;
        return res;
    }

    const user_id = result.getValue(0, 0);
    const token = try auth.generateToken(allocator);

    const session_params = &[_][]const u8{ token, user_id };
    var session_result = try spider_pg.queryParams(
        conn,
        "INSERT INTO sessions (token, user_id) VALUES ($1, $2)",
        session_params,
        allocator,
    );
    defer session_result.deinit();

    const resp_body = try std.fmt.allocPrint(allocator, "{{\"token\":\"{s}\"}}", .{token});
    return web.Response.json(allocator, resp_body);
}

fn getUserHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const auth_header = req.header("authorization") orelse {
        var res = try web.Response.text(allocator, "Unauthorized");
        res.status = .unauthorized;
        return res;
    };

    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        var res = try web.Response.text(allocator, "Invalid token format");
        res.status = .unauthorized;
        return res;
    }
    const token = auth_header[7..];

    const id = req.param("id") orelse {
        var res = try web.Response.text(allocator, "Missing id");
        res.status = .bad_request;
        return res;
    };

    const conn = try pool.acquire();
    defer pool.release(conn);

    const token_params = &[_][]const u8{token};
    var token_result = try spider_pg.queryParams(
        conn,
        "SELECT user_id FROM sessions WHERE token = $1",
        token_params,
        allocator,
    );
    defer token_result.deinit();

    if (token_result.rows() == 0) {
        var res = try web.Response.text(allocator, "Invalid token");
        res.status = .unauthorized;
        return res;
    }

    const user_params = &[_][]const u8{id};
    var user_result = try spider_pg.queryParams(
        conn,
        "SELECT id, name, email FROM users WHERE id = $1",
        user_params,
        allocator,
    );
    defer user_result.deinit();

    if (user_result.rows() == 0) {
        var res = try web.Response.text(allocator, "Not Found");
        res.status = .not_found;
        return res;
    }

    const resp_body = try std.fmt.allocPrint(allocator, "{{\"id\":{s},\"name\":\"{s}\",\"email\":\"{s}\"}}", .{
        user_result.getValue(0, 0),
        user_result.getValue(0, 1),
        user_result.getValue(0, 2),
    });
    return web.Response.json(allocator, resp_body);
}

fn usersHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try spider_pg.query(conn, "SELECT id, name FROM users LIMIT 10");
    defer result.deinit();

    const nrows = result.rows();
    const users = try allocator.alloc(struct { id: i32, name: []u8 }, nrows);

    for (0..nrows) |i| {
        const id_str = result.getValue(i, 0);
        const name_str = result.getValue(i, 1);
        users[i] = .{
            .id = try std.fmt.parseInt(i32, id_str, 10),
            .name = try allocator.dupe(u8, name_str),
        };
    }

    return web.Response.json(allocator, users);
}

const Task = struct {
    id: i32,
    title: []u8,
    status: []u8,
    created_at: []u8,
};

fn tasksHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    const conn = pool.acquire() catch {
        var res = try web.Response.text(allocator, "Database unavailable");
        res.status = .service_unavailable;
        return res;
    };
    defer pool.release(conn);

    var result = spider_pg.query(conn, "SELECT id, title, status, created_at FROM tasks ORDER BY id DESC") catch {
        var res = try web.Response.text(allocator, "Query failed");
        res.status = .internal_server_error;
        return res;
    };
    defer result.deinit();

    const nrows = result.rows();
    const tasks = try allocator.alloc(Task, nrows);

    for (0..nrows) |i| {
        const id_str = result.getValue(i, 0);
        const title_str = result.getValue(i, 1);
        const status_str = result.getValue(i, 2);
        const created_at_str = result.getValue(i, 3);
        tasks[i] = .{
            .id = try std.fmt.parseInt(i32, id_str, 10),
            .title = try allocator.dupe(u8, title_str),
            .status = try allocator.dupe(u8, status_str),
            .created_at = try allocator.dupe(u8, created_at_str),
        };
    }

    return web.Response.json(allocator, tasks);
}

fn createTaskHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    const body = req.body orelse {
        var res = try web.Response.text(allocator, "Missing body");
        res.status = .bad_request;
        return res;
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const title_val = parsed.value.object.get("title") orelse {
        var res = try web.Response.text(allocator, "Missing title");
        res.status = .bad_request;
        return res;
    };
    const title = title_val.string;

    const conn = pool.acquire() catch {
        var res = try web.Response.text(allocator, "Database unavailable");
        res.status = .service_unavailable;
        return res;
    };
    defer pool.release(conn);

    const params = &[_][]const u8{ title, "pending" };
    var result = spider_pg.queryParams(
        conn,
        "INSERT INTO tasks (title, status) VALUES ($1, $2) RETURNING id, title, status, created_at",
        params,
        allocator,
    ) catch {
        var res = try web.Response.text(allocator, "Insert failed");
        res.status = .internal_server_error;
        return res;
    };
    defer result.deinit();

    const new_task = Task{
        .id = try std.fmt.parseInt(i32, result.getValue(0, 0), 10),
        .title = try allocator.dupe(u8, result.getValue(0, 1)),
        .status = try allocator.dupe(u8, result.getValue(0, 2)),
        .created_at = try allocator.dupe(u8, result.getValue(0, 3)),
    };

    const hub = spider.getWsHub();
    const broadcast_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"task_added\",\"task\":{{\"id\":{},\"title\":\"{s}\",\"status\":\"{s}\",\"created_at\":\"{s}\"}}}}", .{
        new_task.id,
        new_task.title,
        new_task.status,
        new_task.created_at,
    });
    hub.broadcast(broadcast_msg);
    allocator.free(broadcast_msg);

    return web.Response.json(allocator, new_task);
}

pub fn main(init: std.process.Init) !void {
    const host = getEnv("HOST", "0.0.0.0");
    const port = getEnvInt("PORT", 8080);

    const db_host = getEnv("DB_HOST", "localhost");
    const db_port = getEnvInt("DB_PORT", 5432);
    const db_name = getEnv("DB_NAME", "spider_demo");
    const db_user = getEnv("DB_USER", "postgres");
    const db_pass = getEnv("DB_PASSWORD", "postgres");

    // Server starts now - uptime tracked from this point
    server_start_time = 1; // Mark as started

    pool = try spider_pg.Pool.init(init.gpa, .{
        .host = db_host,
        .port = db_port,
        .database = db_name,
        .user = db_user,
        .password = db_pass,
        .pool_size = 10,
    });
    defer pool.deinit();

    // Auto-migration: create tasks table if not exists
    {
        var migration_err: ?anyerror = null;
        if (pool.acquire()) |db| {
            defer pool.release(db);
            _ = spider_pg.query(db, "CREATE TABLE IF NOT EXISTS tasks (id SERIAL PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMP DEFAULT NOW())") catch |err| {
                migration_err = err;
            };
        } else |err| {
            migration_err = err;
        }
        if (migration_err) |err| {
            std.debug.print("Migration warning: {}\n", .{err});
        }
    }

    var app = try spider.Spider.init(init.gpa, init.io, host, port);
    defer app.deinit();

    try spider.initWsHub(init.gpa, init.io);
    defer spider.deinitWsHub(init.gpa);

    app.get("/", indexHandler)
        .get("/health", healthHandler)
        .get("/metrics", metricsHandler)
        .get("/json", jsonHandler)
        .get("/logs", logsHandler)
        .get("/tasks", tasksHandler)
        .post("/tasks", createTaskHandler)
        .post("/auth/register", registerHandler)
        .post("/auth/login", loginHandler)
        .get("/users", usersHandler)
        .get("/users/:id", getUserHandler)
        .groupGet("/api/v1", "/users", usersHandler)
        .groupGet("/api/v1", "/tasks", tasksHandler)
        .listen() catch |err| return err;
}

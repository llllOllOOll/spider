const std = @import("std");
const spider = @import("spider");
const web = spider.web;
const spider_pg = @import("spider_pg");
const auth = @import("auth");

var pool: spider_pg.Pool = undefined;

const dashboard_html = @embedFile("dashboard.html");

fn indexHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.html(allocator, dashboard_html);
}

fn healthHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
    return try web.Response.json(allocator, .{ .status = "ok" });
}

fn jsonHandler(allocator: std.mem.Allocator, req: *web.Request) !web.Response {
    _ = req;
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

pub fn main(init: std.process.Init) !void {
    pool = try spider_pg.Pool.init(init.gpa, .{
        .host = "localhost",
        .database = "spider_demo",
        .user = "postgres",
        .password = "postgres",
        .pool_size = 10,
    });
    defer pool.deinit();

    var app = try spider.Spider.init(init.gpa, init.io, 8080);
    defer app.deinit();

    app.get("/", indexHandler)
        .get("/health", healthHandler)
        .get("/json", jsonHandler)
        .post("/auth/register", registerHandler)
        .post("/auth/login", loginHandler)
        .get("/users", usersHandler)
        .get("/users/:id", getUserHandler)
        .listen() catch |err| return err;
}

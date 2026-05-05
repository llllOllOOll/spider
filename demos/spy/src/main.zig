const std = @import("std");

const spider = @import("spider");
const db = spider.pg;

// World struct for database queries
const World = struct { id: i32, randomnumber: i32 };

// Seed state - thread-safe via thread ID
const S = struct {
    var prng: ?std.Random.DefaultPrng = null;
};

// Helper to generate random id 1-10000 using crypto-random seed
fn randomId() i32 {
    if (S.prng == null) {
        var seed: u64 = undefined;
        const buf = std.mem.asBytes(&seed);
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        S.prng = std.Random.DefaultPrng.init(seed);
    }
    const n: u32 = S.prng.?.random().int(u32);
    const val: u32 = (n % 10000) + 1;
    return @intCast(val);
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    db.init(arena, io, .{
        .host = spider.env.getOr("PG_HOST", "localhost"),
        .port = spider.env.getInt(u16, "PG_PORT", 5434),
        .user = spider.env.getOr("PG_USER", "spider"),
        .password = spider.env.getOr("PG_PASSWORD", "spider"),
        .database = spider.env.getOr("PG_DB", "spiderdb"),
    }) catch |err| {
        std.log.err("PG init failed: {}, DB routes will not work", .{err});
    };
    defer db.deinit();

    var server = spider.app();
    defer server.deinit();

    server
        .get("/plaintext", plaintextHandler)
        .get("/json", jsonHandler)
        .get("/db", dbHandler)
        .get("/queries", queriesHandler)
        .get("/queries-optimized", queriesOptimizedHandler)
        .listen(3000) catch {};
}

// 1. Plaintext route
fn plaintextHandler(c: *spider.Ctx) !spider.Response {
    return c.text("Hello, World!", .{});
}

// 2. JSON route
fn jsonHandler(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .message = "Hello, World!" }, .{});
}

// 3. DB route - single query
fn dbHandler(c: *spider.Ctx) !spider.Response {
    const id = randomId();
    const rows = try spider.pg.query(
        World,
        c.arena,
        "SELECT id, randomnumber FROM world WHERE id = $1",
        .{id},
    );
    if (rows.len == 0) {
        return c.json(.{ .id = id, .randomnumber = 0 }, .{});
    }
    return c.json(rows[0], .{});
}

// 4. Queries route - N queries sequentially
fn queriesHandler(c: *spider.Ctx) !spider.Response {
    // Parse query parameter using Spider's built-in method
    const queries_param = c.query("queries") orelse "1";
    const n_raw = std.fmt.parseInt(u32, queries_param, 10) catch 1;

    // manual min/max: clamp between 1 and 20
    var n: u32 = n_raw;
    if (n < 1) n = 1;
    if (n > 20) n = 20;

    // Allocate results array
    const results = try c.arena.alloc(World, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const id = randomId();
        const rows = try spider.pg.query(
            World,
            c.arena,
            "SELECT id, randomnumber FROM world WHERE id = $1",
            .{id},
        );
        if (rows.len > 0) {
            results[i] = rows[0];
        } else {
            results[i] = .{ .id = id, .randomnumber = 0 };
        }
    }

    return c.json(results[0..n], .{});
}

// 5. Queries optimized route - uses ANY() pattern for batch queries
fn queriesOptimizedHandler(c: *spider.Ctx) !spider.Response {
    // Parse query parameter using Spider's built-in method
    const queries_param = c.query("queries") orelse "1";
    const n_raw = std.fmt.parseInt(u32, queries_param, 10) catch 1;

    // manual min/max: clamp between 1 and 20
    var n: u32 = n_raw;
    if (n < 1) n = 1;
    if (n > 20) n = 20;

    // Generate array of random IDs
    const ids = try c.arena.alloc(i32, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        ids[i] = randomId();
    }

    // std.debug.print("Generated {d} IDs: {any}\n", .{ n, ids });

    // Single query using ANY() pattern with array() helper
    const rows = try spider.pg.query(
        World,
        c.arena,
        "SELECT id, randomnumber FROM world WHERE id = ANY($1)",
        .{spider.pg.array(i32, ids)},
    );

    // Map results back to original ID order
    const results = try c.arena.alloc(World, n);
    var id_map = std.AutoHashMap(i32, World).init(c.arena);

    for (rows) |row| {
        try id_map.put(row.id, row);
    }

    for (ids, 0..) |id, idx| {
        results[idx] = id_map.get(id) orelse .{ .id = id, .randomnumber = 0 };
    }

    return c.json(results[0..n], .{});
}

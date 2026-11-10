//! mssql-demo: runs a batch against SQL Server and prints every result set.
//!
//!   MSSQL_PASSWORD=... zig build run -- "SELECT @@VERSION"
//!
//! Environment: MSSQL_HOST (127.0.0.1), MSSQL_PORT (1433), MSSQL_USER (sa),
//! MSSQL_PASSWORD, MSSQL_DB (master), MSSQL_ENCRYPT (on|off).

const std = @import("std");
const mssql = @import("mssql");

const demo_sql =
    \\SELECT CAST(1 AS bit) AS b, CAST(200 AS tinyint) AS ti, CAST(-32000 AS smallint) AS si,
    \\       2147483647 AS i, CAST(-9007199254740993 AS bigint) AS bi,
    \\       CAST(1.5 AS real) AS r, CAST(3.14159265358979 AS float) AS f,
    \\       CAST(-12345.6789 AS decimal(18,4)) AS dec, CAST(42.4242 AS money) AS m,
    \\       N'ação ✓ 😀' AS nv, CAST('café' AS varchar(10)) AS v, CAST(NULL AS int) AS nul,
    \\       CAST('2024-02-29' AS date) AS d, CAST('13:45:30.1234567' AS time(7)) AS t,
    \\       CAST('2024-02-29 13:45:30.123' AS datetime) AS dt,
    \\       CAST('2024-02-29 13:45:30.1234567' AS datetime2(7)) AS dt2,
    \\       CAST('2024-02-29 13:45:30.12 -03:00' AS datetimeoffset(2)) AS dto,
    \\       CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS g,
    \\       CAST(0xDEADBEEF AS varbinary(8)) AS vb, REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) AS big;
    \\SELECT name, database_id, create_date FROM sys.databases ORDER BY database_id;
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    const password = env.get("MSSQL_PASSWORD") orelse {
        std.debug.print("set MSSQL_PASSWORD\n", .{});
        return error.MissingPassword;
    };
    const encrypt: mssql.Encrypt = if (std.mem.eql(u8, env.get("MSSQL_ENCRYPT") orelse "on", "off")) .off else .on;

    const conn = try mssql.Conn.connect(gpa, io, .{
        .host = env.get("MSSQL_HOST") orelse "127.0.0.1",
        .port = try std.fmt.parseInt(u16, env.get("MSSQL_PORT") orelse "1433", 10),
        .user = env.get("MSSQL_USER") orelse "sa",
        .password = password,
        .database = env.get("MSSQL_DB") orelse "master",
        .trust_server_certificate = std.mem.eql(u8, env.get("MSSQL_TRUST_SERVER_CERTIFICATE") orelse "false", "true"),
        .encrypt = encrypt,
    });
    defer conn.close();

    const sql = if (args.len > 1) args[1] else demo_sql;
    var rows = conn.query(sql) catch |e| return report(conn, e);
    defer rows.deinit();

    var set: usize = 0;
    while (rows.columns.len > 0) {
        set += 1;
        try out.print("-- result set {d}\n", .{set});
        for (rows.columns, 0..) |c, i| try out.print("{s}{s} {s}", .{ if (i > 0) " | " else "", c.name, c.typeName() });
        try out.writeAll("\n");
        var n: usize = 0;
        while (rows.next() catch |e| return report(conn, e)) |row| : (n += 1) {
            for (row, 0..) |v, i| {
                if (i > 0) try out.writeAll(" | ");
                if (v == .string and v.string.len > 60) {
                    try out.print("{s}... ({d} bytes)", .{ v.string[0..40], v.string.len });
                } else try out.print("{f}", .{v});
            }
            try out.writeAll("\n");
        }
        try out.print("({d} rows)\n", .{n});
        if (!(rows.nextResult() catch |e| return report(conn, e))) break;
    }
    try out.print("rows affected: {d}\n", .{rows.rows_affected});
}

fn report(conn: *mssql.Conn, e: anyerror) anyerror {
    if (conn.last_error) |m| std.debug.print("SQL Server error {d} (class {d}): {s}\n", .{ m.number, m.class, m.message });
    return e;
}

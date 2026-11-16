//! mssql: a native Microsoft SQL Server client for Zig, speaking TDS 7.4.
//!
//! ```zig
//! const conn = try mssql.Conn.connect(gpa, io, .{ .user = "sa", .password = "..." });
//! defer conn.close();
//! var rows = try conn.query("SELECT name, database_id FROM sys.databases");
//! defer rows.deinit();
//! while (try rows.next()) |row| std.debug.print("{f} {f}\n", .{ row[0], row[1] });
//! ```

const conn = @import("conn.zig");
const value = @import("value.zig");

pub const Conn = conn.Conn;
pub const Pool = @import("pool.zig").Pool;
pub const CaBundle = conn.CaBundle;
pub const Rows = conn.Rows;
pub const Options = conn.Options;
pub const Encrypt = conn.Encrypt;
pub const Column = conn.Column;
pub const ServerMessage = conn.ServerMessage;
pub const Param = conn.Param;
pub const Value = value.Value;
pub const Decimal = value.Decimal;
pub const Date = value.Date;
pub const Time = value.Time;
pub const DateTime = value.DateTime;
pub const DateTimeOffset = value.DateTimeOffset;

test {
    _ = conn;
    _ = @import("pool.zig");
    _ = value;
}

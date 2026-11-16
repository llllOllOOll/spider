# mssql

A native Microsoft SQL Server client for Zig 0.17, speaking TDS 7.4 (SQL Server
2012 and later, Azure SQL). No C library and no ODBC: TLS comes from Zig's
standard library. Spider apps use it through `spider.mssql`
(`modules/mssql/src/mssql.zig`); this package is the driver alone.

```zig
const mssql = @import("mssql");

const conn = try mssql.Conn.connect(gpa, io, .{
    .host = "db.example.com",
    .user = "app",
    .password = password,
    .database = "sales",
});
defer conn.close();

var rows = try conn.queryArgs("SELECT id, name FROM dbo.customers WHERE name LIKE @p1", .{"Ana%"});
defer rows.deinit();
while (try rows.next()) |row| std.debug.print("{f} {f}\n", .{ row[0], row[1] });
```

## What it does

- PRELOGIN, TLS tunneled in PRELOGIN packets as TDS 7.x requires, LOGIN7 with
  SQL authentication. The certificate is verified against the system's roots
  and the host name unless `trust_server_certificate` is set (needed for a
  self-signed certificate, as in the Docker image). `encrypt = .off` for
  servers without TLS.
- SQL batches; parameters `@p1`, `@p2`... through an RPC to `sp_executesql`
  (integers, floats, bools, strings, enums, null, bytes).
- Replies streamed row by row: several result sets, rows affected, server
  errors (`error.ServerError`, with `conn.last_error`), transactions tracked
  from ENVCHANGE (`inTransaction()`).
- Types: bit, tinyint to bigint, real, float, decimal/numeric (as an i128 and
  a scale), money, smallmoney, char/varchar/text (UTF-8 collations, the rest
  decoded as Windows-1252), nchar/nvarchar/ntext, binary/varbinary/image,
  (max) types, uniqueidentifier, date, time, datetime, smalldatetime,
  datetime2, datetimeoffset, xml.
- `Pool`: a fixed set of connections for many threads; a connection that
  broke is opened again, one given back inside a transaction is rolled back.

## Not yet

Windows/Kerberos and Entra ID logins, TDS 8.0 (`Encrypt=strict`), Azure
redirection (ENVCHANGE routing), query cancel (ATTENTION) and timeouts, bulk
copy, sql_variant and CLR types, code pages other than 1252 for non-Unicode
columns, MARS.

## Tests

`zig build test` runs the unit tests. The tests against a server live in the
Spider module: `zig build test-mssql` from the repository root (see AGENTS.md).
`zig build demo -- "SELECT ..."` prints the result sets of a query, connecting
with the `MSSQL_*` variables.

PRELOGIN, LOGIN7 and the TLS shim are adapted from basalt (MIT): see
THIRD_PARTY_LICENSES.md.

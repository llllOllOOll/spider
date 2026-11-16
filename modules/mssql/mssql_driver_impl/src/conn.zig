//! A connection to SQL Server over TDS 7.4: PRELOGIN, tunneled TLS, LOGIN7 with
//! SQL authentication, SQL batches, and a streaming reader of their replies.
//!
//! PRELOGIN, LOGIN7 and SQL_BATCH framing follow basalt
//! (github.com/leonardomb1/basalt, MIT, Copyright (c) 2026 Leonardo Machado
//! Baptista) and MS-TDS; the rest is written for this library.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const TlsShim = @import("tls_shim.zig").TlsShim;
const tls_buf_len = @import("tls_shim.zig").buf_len;

const log = std.log.scoped(.mssql);

const PacketType = enum(u8) {
    sql_batch = 0x01,
    rpc = 0x03,
    reply = 0x04,
    login7 = 0x10,
    prelogin = 0x12,
};
const status_eom: u8 = 0x01;

/// The largest value this driver accepts (SQL Server's own limit for (max) types).
const max_lob: usize = (1 << 31) - 1;

pub const Encrypt = enum {
    /// TLS for the whole session (PRELOGIN ENCRYPT_ON).
    on,
    /// No TLS at all. Refused by servers that force encryption.
    off,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1433,
    user: []const u8,
    password: []const u8,
    /// Initial database; empty means the login's default.
    database: []const u8 = "",
    app_name: []const u8 = "mssql-zig",
    /// The client machine's name, as `HOST_NAME()` reports it.
    workstation: []const u8 = "zig",
    encrypt: Encrypt = .on,
    /// true: the server's certificate is not checked at all (the
    /// `TrustServerCertificate=yes` of Microsoft's drivers), which a SQL
    /// Server with its own self-signed certificate needs. false: the
    /// certificate must chain to a root of `ca` (or of the system, read for
    /// this connection when `ca` is null) and name `certificate_host`.
    trust_server_certificate: bool = false,
    /// Trusted roots shared by many connections (a pool loads them once).
    ca: ?*CaBundle = null,
    /// The name the certificate must carry; null: `host`. Set it when
    /// connecting by IP address to a server whose certificate names its host.
    certificate_host: ?[]const u8 = null,
    packet_size: u16 = 4096,
    /// SET XACT_ABORT ON for the session: a run-time error rolls back the
    /// whole transaction and ends the batch, instead of failing only its
    /// statement.
    xact_abort: bool = false,
};

/// The system's trusted root certificates, loaded once and shared by the
/// connections that verify the server (`Options.ca`).
pub const CaBundle = struct {
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: Io.RwLock = .init,

    /// Reads the system's roots (the same files curl and browsers read).
    pub fn load(self: *CaBundle, gpa: Allocator, io: Io) !void {
        try self.bundle.rescan(gpa, io, Io.Clock.real.now(io));
    }

    pub fn deinit(self: *CaBundle, gpa: Allocator) void {
        self.bundle.deinit(gpa);
    }
};

/// An ERROR or INFO message from the server.
pub const ServerMessage = struct {
    number: i32,
    state: u8,
    class: u8,
    message: []const u8,
    server: []const u8,
    procedure: []const u8,
    line: u32,
};

pub const TypeInfo = struct {
    id: u8,
    /// Declared length in bytes (0xFFFF for (max) types).
    len: u32 = 0,
    precision: u8 = 0,
    scale: u8 = 0,
    collation: [5]u8 = @splat(0),
    /// Values arrive as Partially Length-Prefixed chunks: (max) types and XML.
    plp: bool = false,
};

pub const Column = struct {
    name: []const u8,
    type: TypeInfo,
    nullable: bool,

    /// The SQL type name, for display.
    pub fn typeName(c: Column) []const u8 {
        return switch (c.type.id) {
            0x30 => "tinyint",
            0x32, 0x68 => "bit",
            0x34 => "smallint",
            0x38 => "int",
            0x7F => "bigint",
            0x26 => switch (c.type.len) {
                1 => "tinyint",
                2 => "smallint",
                4 => "int",
                else => "bigint",
            },
            0x3B => "real",
            0x3E => "float",
            0x6D => if (c.type.len == 4) "real" else "float",
            0x3C, 0x7A, 0x6E => if (c.type.len == 4) "smallmoney" else "money",
            0x3A, 0x3D, 0x6F => if (c.type.len == 4) "smalldatetime" else "datetime",
            0x6A, 0x37 => "decimal",
            0x6C, 0x3F => "numeric",
            0x24 => "uniqueidentifier",
            0x28 => "date",
            0x29 => "time",
            0x2A => "datetime2",
            0x2B => "datetimeoffset",
            0xA7 => "varchar",
            0xAF => "char",
            0xE7 => "nvarchar",
            0xEF => "nchar",
            0xA5 => "varbinary",
            0xAD => "binary",
            0x23 => "text",
            0x63 => "ntext",
            0x22 => "image",
            0xF1 => "xml",
            else => "?",
        };
    }
};

pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    sock_reader: Io.net.Stream.Reader,
    sock_writer: Io.net.Stream.Writer,
    shim: TlsShim,
    tls: ?std.crypto.tls.Client,
    packet_size: usize,
    packet_id: u8 = 1,
    /// Transaction descriptor from ENVCHANGE, echoed in every request's headers.
    txn_desc: [8]u8 = @splat(0),
    /// The first ERROR of the last request, valid until the next one.
    last_error: ?ServerMessage = null,
    err_arena: std.heap.ArenaAllocator,
    /// True while a `Rows` still has unread reply bytes.
    busy: bool = false,
    /// The connection is out of step with the server (a read or write
    /// failed, or a reply was abandoned mid-message): close it.
    broken: bool = false,
    /// The database's collation (ENVCHANGE 7), sent with string parameters.
    collation: [5]u8 = default_collation,

    sock_rbuf: [tls_buf_len]u8,
    sock_wbuf: [tls_buf_len]u8,
    tls_rbuf: [tls_buf_len]u8,
    tls_wbuf: [tls_buf_len]u8,

    pub fn connect(gpa: Allocator, io: Io, opts: Options) !*Conn {
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);

        const stream = if (Io.net.IpAddress.parse(opts.host, opts.port)) |addr|
            try addr.connect(io, .{ .mode = .stream })
        else |_|
            try (try Io.net.HostName.init(opts.host)).connect(io, opts.port, .{ .mode = .stream });
        errdefer stream.close(io);

        self.gpa = gpa;
        self.io = io;
        self.stream = stream;
        self.tls = null;
        self.packet_size = 4096;
        self.packet_id = 1;
        self.txn_desc = @splat(0);
        self.last_error = null;
        self.err_arena = .init(gpa);
        self.busy = false;
        self.broken = false;
        self.collation = default_collation;
        errdefer self.err_arena.deinit();
        self.sock_reader = .init(stream, io, &self.sock_rbuf);
        self.sock_writer = .init(stream, io, &self.sock_wbuf);

        try self.prelogin(opts.encrypt);
        if (opts.encrypt == .on) try self.startTls(opts);
        try self.login(opts);
        // What ODBC, OLE DB, JDBC and .NET set on every session (see basalt):
        // without them (max) values arrive cut and filtered indexes refuse writes.
        _ = try self.exec("SET TEXTSIZE 2147483647; SET ANSI_WARNINGS ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; " ++
            "SET ANSI_NULL_DFLT_ON ON; SET QUOTED_IDENTIFIER ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ARITHABORT ON; " ++
            "SET NUMERIC_ROUNDABORT OFF; SET IMPLICIT_TRANSACTIONS OFF");
        if (opts.xact_abort) _ = try self.exec("SET XACT_ABORT ON");
        return self;
    }

    /// A transaction is open on this session (BEGIN TRANSACTION without its
    /// COMMIT or ROLLBACK yet), as the server last reported it.
    pub fn inTransaction(self: *const Conn) bool {
        return !std.mem.allEqual(u8, &self.txn_desc, 0);
    }

    pub fn close(self: *Conn) void {
        if (self.tls) |*t| {
            t.end() catch {};
            self.flush() catch {};
        }
        self.stream.close(self.io);
        self.err_arena.deinit();
        self.gpa.destroy(self);
    }

    /// Runs a batch that returns no rows; returns the rows affected (the sum of
    /// every statement's count). A server error returns `error.ServerError`,
    /// with the message in `last_error`.
    pub fn exec(self: *Conn, sql: []const u8) !u64 {
        return self.execParams(sql, &.{});
    }

    /// Sends a batch and positions on its first result set. Only one `Rows` may
    /// be open per connection; `deinit` it before the next request.
    pub fn query(self: *Conn, sql: []const u8) !Rows {
        return self.queryParams(sql, &.{});
    }

    /// `query` with parameters `@p1`, `@p2`... taken from a tuple:
    /// `conn.queryArgs("SELECT * FROM t WHERE id = @p1 AND nome = @p2", .{ 42, "Ana" })`.
    /// Integers, floats, bools, strings, null and optionals convert; pass a
    /// `Param` for anything else (`.{ .bytes = ... }`).
    pub fn queryArgs(self: *Conn, sql: []const u8, args: anytype) !Rows {
        const ps = toParams(args);
        return self.queryParams(sql, &ps);
    }

    /// `exec` with parameters, as in `queryArgs`.
    pub fn execArgs(self: *Conn, sql: []const u8, args: anytype) !u64 {
        const ps = toParams(args);
        return self.execParams(sql, &ps);
    }

    pub fn execParams(self: *Conn, sql: []const u8, params: []const Param) !u64 {
        var rows = try self.queryParams(sql, params);
        defer rows.deinit();
        while (try rows.nextResult()) {}
        return rows.rows_affected;
    }

    /// With no parameters, a plain SQL batch; otherwise an RPC call to
    /// `sp_executesql`, so values never mix with the SQL text.
    pub fn queryParams(self: *Conn, sql: []const u8, params: []const Param) !Rows {
        if (self.busy) return error.ConnectionBusy;
        if (self.broken) return error.ConnectionBroken;
        return self.startReply(sql, params) catch |err| {
            if (err != error.ServerError) self.broken = true;
            return err;
        };
    }

    fn startReply(self: *Conn, sql: []const u8, params: []const Param) !Rows {
        if (params.len == 0) try self.sendBatch(sql) else try self.sendRpc(sql, params);
        var rows: Rows = .{
            .conn = self,
            .r = .{ .in = self.in() },
            .meta_arena = .init(self.gpa),
            .row_arena = .init(self.gpa),
        };
        self.busy = true;
        errdefer rows.deinit();
        _ = try rows.nextResult();
        return rows;
    }

    // -- Packets ------------------------------------------------------------

    fn in(self: *Conn) *Io.Reader {
        return if (self.tls) |*t| &t.reader else &self.sock_reader.interface;
    }

    fn out(self: *Conn) *Io.Writer {
        return if (self.tls) |*t| &t.writer else &self.sock_writer.interface;
    }

    fn flush(self: *Conn) !void {
        if (self.tls) |*t| {
            try t.writer.flush();
            try self.shim.writer.flush();
        }
        try self.sock_writer.interface.flush();
    }

    /// Splits a message into packets of the negotiated size, EOM on the last.
    fn sendMessage(self: *Conn, ptype: PacketType, payload: []const u8) !void {
        const w = self.out();
        const max = self.packet_size - 8;
        var off: usize = 0;
        while (true) {
            const chunk = @min(payload.len - off, max);
            const last = off + chunk == payload.len;
            var header: [8]u8 = .{ @backingInt(ptype), if (last) status_eom else 0, 0, 0, 0, 0, self.packet_id, 0 };
            std.mem.writeInt(u16, header[2..4], @intCast(chunk + 8), .big);
            self.packet_id +%= 1;
            try w.writeAll(&header);
            try w.writeAll(payload[off..][0..chunk]);
            off += chunk;
            if (last) break;
        }
        try self.flush();
    }

    fn resetErrors(self: *Conn) void {
        self.last_error = null;
        _ = self.err_arena.reset(.retain_capacity);
    }

    // -- Login --------------------------------------------------------------

    /// PRELOGIN: VERSION and ENCRYPTION. The server's ENCRYPTION answer decides.
    fn prelogin(self: *Conn, encrypt: Encrypt) !void {
        const want: u8 = if (encrypt == .on) 0x01 else 0x02; // ENCRYPT_ON / ENCRYPT_NOT_SUP
        const payload = [_]u8{
            0x00, 0x00, 0x0B, 0x00, 0x06, // VERSION at 11, 6 bytes
            0x01, 0x00, 0x11, 0x00, 0x01, // ENCRYPTION at 17, 1 byte
            0xFF,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // client version (unused by the server)
            want,
        };
        try self.sendMessage(.prelogin, &payload);

        var r: MsgReader = .{ .in = self.in() };
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        while (!(try r.atEnd())) {
            if (n == buf.len) return error.Protocol;
            buf[n] = try r.byte();
            n += 1;
        }
        const p = buf[0..n];
        var i: usize = 0;
        while (i + 5 <= p.len and p[i] != 0xFF) : (i += 5) {
            if (p[i] != 0x01) continue;
            const off = std.mem.readInt(u16, p[i + 1 ..][0..2], .big);
            if (off >= p.len) return error.Protocol;
            const on = p[off] == 0x01 or p[off] == 0x03;
            if (encrypt == .on and !on) return error.TlsRefusedByServer;
            if (encrypt == .off and on) return error.EncryptionRequired;
            return;
        }
        return error.Protocol;
    }

    fn startTls(self: *Conn, opts: Options) !void {
        self.shim.init(&self.sock_reader.interface, &self.sock_writer.interface);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);

        var own: CaBundle = .{};
        defer own.deinit(self.gpa);
        const ca: ?*CaBundle = if (opts.trust_server_certificate) null else opts.ca orelse blk: {
            try own.load(self.gpa, self.io);
            break :blk &own;
        };
        self.tls = std.crypto.tls.Client.init(&self.shim.reader, &self.shim.writer, .{
            .host = if (ca == null) .no_verification else .{ .explicit = opts.certificate_host orelse opts.host },
            .ca = if (ca) |c| .{ .bundle = .{ .gpa = self.gpa, .io = self.io, .lock = &c.lock, .bundle = &c.bundle } } else .no_verification,
            .read_buffer = &self.tls_rbuf,
            .write_buffer = &self.tls_wbuf,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(self.io),
            // TDS frames its own messages; the server may drop the socket without close_notify.
            .allow_truncation_attacks = true,
        }) catch |err| {
            if (ca != null) switch (err) {
                error.TlsCertificateNotVerified, error.CertificateHostMismatch, error.CertificateIssuerMismatch, error.CertificateSignatureInvalid => log.err(
                    "the server's TLS certificate was not accepted ({t}): a self-signed one needs trust_server_certificate",
                    .{err},
                ),
                else => {},
            };
            return err;
        };
        self.shim.handshaking = false;
    }

    fn login(self: *Conn, opts: Options) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const payload = try buildLogin7(arena.allocator(), opts);
        try self.sendMessage(.login7, payload);

        self.resetErrors();
        var resp: Rows = .{
            .conn = self,
            .r = .{ .in = self.in() },
            .meta_arena = .init(self.gpa),
            .row_arena = .init(self.gpa),
        };
        defer resp.meta_arena.deinit();
        defer resp.row_arena.deinit();
        while (try resp.step() != .end) {}
        if (!resp.login_ack) {
            if (self.last_error) |e| log.err("login refused: {d}: {s}", .{ e.number, e.message });
            return error.LoginFailed;
        }
        self.packet_size = resp.packet_size orelse self.packet_size;
    }

    fn sendRpc(self: *Conn, sql: []const u8, params: []const Param) !void {
        self.resetErrors();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        try self.sendMessage(.rpc, try buildRpc(arena.allocator(), self.txn_desc, self.collation, sql, params));
    }

    fn sendBatch(self: *Conn, sql: []const u8) !void {
        self.resetErrors();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = try value.utf8ToUtf16(a, sql);
        // ALL_HEADERS with one transaction descriptor header (MS-TDS 2.2.5.3).
        var payload = try a.alloc(u8, 22 + text.len);
        @memcpy(payload[0..22], &[22]u8{ 22, 0, 0, 0, 18, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 });
        @memcpy(payload[10..18], &self.txn_desc);
        @memcpy(payload[22..], text);
        try self.sendMessage(.sql_batch, payload);
    }
};

/// Latin1_General_CI_AS, until the server names its own.
const default_collation = [5]u8{ 0x09, 0x04, 0xD0, 0x00, 0x34 };

/// A query parameter. Strings go as nvarchar(max), bytes as varbinary(max).
pub const Param = union(enum) {
    null,
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    bytes: []const u8,

    fn sqlType(p: Param) []const u8 {
        return switch (p) {
            .null, .string => "nvarchar(max)",
            .int => "bigint",
            .float => "float",
            .boolean => "bit",
            .bytes => "varbinary(max)",
        };
    }
};

pub fn toParams(args: anytype) [std.meta.fieldNames(@TypeOf(args)).len]Param {
    const names = comptime std.meta.fieldNames(@TypeOf(args));
    var ps: [names.len]Param = undefined;
    inline for (names, 0..) |name, i| ps[i] = toParam(@field(args, name));
    return ps;
}

fn toParam(v: anytype) Param {
    const T = @TypeOf(v);
    if (T == Param) return v;
    return switch (@typeInfo(T)) {
        .null => .null,
        .optional => if (v) |x| toParam(x) else .null,
        .int, .comptime_int => .{ .int = @intCast(v) },
        .float, .comptime_float => .{ .float = v },
        .bool => .{ .boolean = v },
        .@"enum" => .{ .string = @tagName(v) },
        .pointer => .{ .string = v },
        else => @compileError("unsupported parameter type " ++ @typeName(T)),
    };
}

/// RPC to sp_executesql (MS-TDS 2.2.6.6): the statement, the declaration of its
/// parameters, then each value as `@p1`, `@p2`...
fn buildRpc(a: Allocator, txn_desc: [8]u8, collation: [5]u8, sql: []const u8, params: []const Param) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, &[22]u8{ 22, 0, 0, 0, 18, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 });
    @memcpy(b.items[10..18], &txn_desc);
    try b.appendSlice(a, &.{ 0xFF, 0xFF, 10, 0, 0, 0 }); // ProcID 10 = sp_executesql, no flags

    var decl: std.ArrayList(u8) = .empty;
    for (params, 1..) |p, i| try decl.print(a, "{s}@p{d} {s}", .{ if (i > 1) ", " else "", i, p.sqlType() });

    try putParam(&b, a, "", .{ .string = sql }, collation);
    try putParam(&b, a, "", .{ .string = decl.items }, collation);
    for (params, 1..) |p, i| {
        var name_buf: [16]u8 = undefined;
        try putParam(&b, a, try std.fmt.bufPrint(&name_buf, "@p{d}", .{i}), p, collation);
    }
    return b.items;
}

fn putParam(b: *std.ArrayList(u8), a: Allocator, name: []const u8, p: Param, collation: [5]u8) !void {
    try b.append(a, @intCast(name.len));
    try b.appendSlice(a, try value.utf8ToUtf16(a, name));
    try b.append(a, 0); // status: input
    switch (p) {
        .int => |v| {
            try b.appendSlice(a, &.{ 0x26, 8, 8 });
            try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(i64, v)));
        },
        .float => |v| {
            try b.appendSlice(a, &.{ 0x6D, 8, 8 });
            try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v))));
        },
        .boolean => |v| try b.appendSlice(a, &.{ 0x68, 1, 1, @intFromBool(v) }),
        .null, .string => {
            try b.appendSlice(a, &.{ 0xE7, 0xFF, 0xFF });
            try b.appendSlice(a, &collation);
            try putPlp(b, a, if (p == .string) try value.utf8ToUtf16(a, p.string) else null);
        },
        .bytes => |v| {
            try b.appendSlice(a, &.{ 0xA5, 0xFF, 0xFF });
            try putPlp(b, a, v);
        },
    }
}

fn putPlp(b: *std.ArrayList(u8), a: Allocator, data: ?[]const u8) !void {
    const d = data orelse return b.appendSlice(a, &@as([8]u8, @splat(0xFF)));
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, d.len)));
    if (d.len > 0) {
        try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(d.len))));
        try b.appendSlice(a, d);
    }
    try b.appendSlice(a, &.{ 0, 0, 0, 0 });
}

/// LOGIN7 (MS-TDS 2.2.6.4): 94 fixed bytes, then the variable fields they point at.
fn buildLogin7(a: Allocator, opts: Options) ![]u8 {
    var fixed: [94]u8 = @splat(0);
    std.mem.writeInt(u32, fixed[4..8], 0x74000004, .little); // TDS 7.4
    std.mem.writeInt(u32, fixed[8..12], opts.packet_size, .little);
    std.mem.writeInt(u32, fixed[12..16], 0x01000000, .little); // client program version
    fixed[25] = 0x01; // fLanguage: a failed language change is fatal
    std.mem.writeInt(u32, fixed[32..36], 0x0409, .little); // client LCID

    var vd: std.ArrayList(u8) = .empty;
    const Field = struct { pos: usize, text: []const u8, secret: bool = false };
    const fields = [_]Field{
        .{ .pos = 36, .text = opts.workstation },
        .{ .pos = 40, .text = opts.user },
        .{ .pos = 44, .text = opts.password, .secret = true },
        .{ .pos = 48, .text = opts.app_name },
        .{ .pos = 52, .text = opts.host },
        .{ .pos = 56, .text = "" }, // extension
        .{ .pos = 60, .text = "mssql-zig" }, // client interface name
        .{ .pos = 64, .text = "" }, // language
        .{ .pos = 68, .text = opts.database },
        .{ .pos = 78, .text = "" }, // SSPI
        .{ .pos = 82, .text = "" }, // attach DB file
        .{ .pos = 86, .text = "" }, // change password
    };
    for (fields) |f| {
        const start = vd.items.len;
        const utf16 = try value.utf8ToUtf16(a, f.text);
        try vd.appendSlice(a, utf16);
        if (f.secret) for (vd.items[start..]) |*b| {
            b.* = ((b.* << 4) | (b.* >> 4)) ^ 0xA5;
        };
        std.mem.writeInt(u16, fixed[f.pos..][0..2], @intCast(94 + start), .little);
        std.mem.writeInt(u16, fixed[f.pos + 2 ..][0..2], @intCast(utf16.len / 2), .little);
    }
    const total = 94 + vd.items.len;
    if (total > std.math.maxInt(u16)) return error.LoginTooLong;
    std.mem.writeInt(u32, fixed[0..4], @intCast(total), .little);
    const msg = try a.alloc(u8, total);
    @memcpy(msg[0..94], &fixed);
    @memcpy(msg[94..], vd.items);
    return msg;
}

/// The payload of one TDS message, read as a stream across its packets.
const MsgReader = struct {
    in: *Io.Reader,
    /// Bytes left in the current packet.
    left: usize = 0,
    /// The current packet is the message's last (EOM).
    last: bool = false,
    started: bool = false,

    fn nextPacket(self: *MsgReader) !void {
        const h = try self.in.takeArray(8);
        const len = std.mem.readInt(u16, h[2..4], .big);
        if (len < 8) return error.Protocol;
        self.left = len - 8;
        self.last = h[1] & status_eom != 0;
        self.started = true;
    }

    fn fill(self: *MsgReader) !void {
        while (self.left == 0) {
            if (self.started and self.last) return error.Protocol;
            try self.nextPacket();
        }
    }

    fn atEnd(self: *MsgReader) !bool {
        while (self.left == 0) {
            if (self.started and self.last) return true;
            try self.nextPacket();
        }
        return false;
    }

    fn byte(self: *MsgReader) !u8 {
        try self.fill();
        self.left -= 1;
        return self.in.takeByte();
    }

    fn read(self: *MsgReader, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            try self.fill();
            const n = @min(dest.len - off, self.left);
            try self.in.readSliceAll(dest[off..][0..n]);
            self.left -= n;
            off += n;
        }
    }

    fn int(self: *MsgReader, comptime T: type) !T {
        var b: [@sizeOf(T)]u8 = undefined;
        try self.read(&b);
        return std.mem.readInt(T, &b, .little);
    }

    fn skip(self: *MsgReader, len: usize) !void {
        var rest = len;
        while (rest > 0) {
            try self.fill();
            const n = @min(rest, self.left);
            try self.in.discardAll(n);
            self.left -= n;
            rest -= n;
        }
    }

    fn alloc(self: *MsgReader, a: Allocator, len: usize) ![]u8 {
        const b = try a.alloc(u8, len);
        try self.read(b);
        return b;
    }

    /// B_VARCHAR / US_VARCHAR: a character count, then UTF-16LE.
    fn text(self: *MsgReader, a: Allocator, comptime Len: type) ![]const u8 {
        const n = try self.int(Len);
        const raw = try self.alloc(a, @as(usize, n) * 2);
        return value.utf16ToUtf8(a, raw);
    }
};

/// The reply to a request: result sets, row by row, read off the socket as
/// they are asked for. Values returned by `next` live until its next call;
/// `columns` until the next result set.
pub const Rows = struct {
    conn: *Conn,
    r: MsgReader,
    meta_arena: std.heap.ArenaAllocator,
    row_arena: std.heap.ArenaAllocator,
    columns: []Column = &.{},
    values: []Value = &.{},
    /// Rows affected, summed over every DONE that carried a count.
    rows_affected: u64 = 0,
    /// The current result set has been read to its end.
    set_done: bool = true,
    /// The whole reply has been read.
    finished: bool = false,
    failed: bool = false,
    login_ack: bool = false,
    packet_size: ?usize = null,

    const Event = enum { metadata, row, done, end };

    pub fn deinit(self: *Rows) void {
        while (!self.finished) _ = self.step() catch break;
        if (!self.finished) {
            // The stream is out of step with the server; nothing after this can be trusted.
            log.warn("reply abandoned mid-message; the connection is unusable", .{});
            self.conn.broken = true;
        }
        self.conn.busy = false;
        self.meta_arena.deinit();
        self.row_arena.deinit();
    }

    /// The next row of the current result set, or null at its end.
    pub fn next(self: *Rows) !?[]const Value {
        while (!self.set_done) {
            switch (try self.step()) {
                .row => return self.values,
                .metadata => {},
                .done => {
                    if (self.failed) return error.ServerError;
                    if (self.columns.len > 0) self.set_done = true;
                },
                .end => {},
            }
        }
        if (self.finished and self.failed) return error.ServerError;
        return null;
    }

    /// Skips what is left of the current result set and moves to the next one.
    /// False when the reply has no more; `error.ServerError` if a statement failed.
    pub fn nextResult(self: *Rows) !bool {
        while (!self.finished) {
            switch (try self.step()) {
                .metadata => {
                    self.set_done = false;
                    return true;
                },
                .row, .done, .end => {},
            }
        }
        if (self.failed) return error.ServerError;
        return false;
    }

    /// Reads tokens up to the next event, or the end of the reply.
    fn step(self: *Rows) !Event {
        while (true) if (try self.token()) |e| return e;
    }

    /// Reads one token; null for those that are not an event (messages, ENVCHANGE...).
    fn token(self: *Rows) !?Event {
        if (try self.r.atEnd()) {
            self.finished = true;
            self.set_done = true;
            return .end;
        }
        const r = &self.r;
        const id = try r.byte();
        switch (id) {
            0x81 => {
                try self.readColMetadata();
                return .metadata;
            },
            0xD1, 0xD2 => {
                try self.readRow(id == 0xD2);
                return .row;
            },
            0xFD, 0xFE, 0xFF => { // DONE, DONEPROC, DONEINPROC
                const status = try r.int(u16);
                _ = try r.int(u16);
                const count = try r.int(u64);
                if (status & 0x10 != 0) self.rows_affected += count;
                if (status & 0x02 != 0) self.failed = true;
                return .done;
            },
            0xAA, 0xAB => { // ERROR, INFO
                const len = try r.int(u16);
                _ = len;
                const a = self.conn.err_arena.allocator();
                const m: ServerMessage = .{
                    .number = try r.int(i32),
                    .state = try r.byte(),
                    .class = try r.byte(),
                    .message = try r.text(a, u16),
                    .server = try r.text(a, u8),
                    .procedure = try r.text(a, u8),
                    .line = try r.int(u32),
                };
                if (id == 0xAA) {
                    self.failed = true;
                    if (self.conn.last_error == null) self.conn.last_error = m;
                } else log.debug("server: {s}", .{m.message});
            },
            0xE3 => try self.readEnvChange(),
            0xAD => { // LOGINACK
                self.login_ack = true;
                try r.skip(try r.int(u16));
            },
            0xA9, 0xA4, 0xA5, 0xED => try r.skip(try r.int(u16)), // ORDER, TABNAME, COLINFO, SSPI
            0x79 => _ = try r.int(i32), // RETURNSTATUS
            0xAE => { // FEATUREEXTACK
                while (try r.byte() != 0xFF) try r.skip(try r.int(u32));
            },
            else => {
                log.err("unsupported token 0x{X:0>2}", .{id});
                return error.UnsupportedToken;
            },
        }
        return null;
    }

    fn readEnvChange(self: *Rows) !void {
        const len = try self.r.int(u16);
        var buf: [512]u8 = undefined;
        if (len > buf.len or len < 1) return self.r.skip(len);
        const b = buf[0..len];
        try self.r.read(b);
        switch (b[0]) {
            4 => { // packet size, as decimal text in UTF-16
                if (b.len < 2) return;
                const n = b[1];
                if (b.len < 2 + @as(usize, n) * 2) return;
                var size: usize = 0;
                for (0..n) |i| size = size * 10 + (b[2 + i * 2] -% '0');
                if (size >= 512 and size <= 32767) self.packet_size = size;
                if (self.packet_size) |s| self.conn.packet_size = s;
            },
            8 => if (b.len >= 10 and b[1] == 8) @memcpy(&self.conn.txn_desc, b[2..10]), // begin transaction
            9, 10 => self.conn.txn_desc = @splat(0), // commit, rollback
            7 => if (b.len >= 7 and b[1] == 5) @memcpy(&self.conn.collation, b[2..7]), // SQL collation
            else => {},
        }
    }

    fn readColMetadata(self: *Rows) !void {
        _ = self.meta_arena.reset(.retain_capacity);
        const a = self.meta_arena.allocator();
        const r = &self.r;
        const count = try r.int(u16);
        if (count == 0xFFFF) {
            self.columns = &.{};
            self.values = &.{};
            return;
        }
        const cols = try a.alloc(Column, count);
        for (cols) |*c| {
            _ = try r.int(u32); // user type
            const flags = try r.int(u16);
            const t = try readTypeInfo(r);
            if (t.id == 0x23 or t.id == 0x63 or t.id == 0x22) { // TEXT, NTEXT, IMAGE: table name
                const parts = try r.byte();
                for (0..parts) |_| try r.skip(@as(usize, try r.int(u16)) * 2);
            }
            c.* = .{ .name = try r.text(a, u8), .type = t, .nullable = flags & 0x0001 != 0 };
        }
        self.columns = cols;
        self.values = try a.alloc(Value, count);
    }

    fn readRow(self: *Rows, nbc: bool) !void {
        _ = self.row_arena.reset(.retain_capacity);
        const a = self.row_arena.allocator();
        var bitmap: [128]u8 = @splat(0); // 1024 columns, SQL Server's limit for a non-wide table
        const nbytes = (self.columns.len + 7) / 8;
        if (nbc) {
            if (nbytes > bitmap.len) return error.Unsupported;
            try self.r.read(bitmap[0..nbytes]);
        }
        for (self.columns, self.values, 0..) |c, *v, i| {
            v.* = if (nbc and bitmap[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0)
                .null
            else
                try readValue(&self.r, a, c.type);
        }
    }
};

fn readTypeInfo(r: *MsgReader) !TypeInfo {
    var t: TypeInfo = .{ .id = try r.byte() };
    switch (t.id) {
        // Fixed-length types.
        0x1F => t.len = 0,
        0x30, 0x32 => t.len = 1,
        0x34 => t.len = 2,
        0x38, 0x3B, 0x3A, 0x7A => t.len = 4,
        0x7F, 0x3E, 0x3D, 0x3C => t.len = 8,
        // One length byte.
        0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x24 => t.len = try r.byte(),
        0x6A, 0x6C, 0x37, 0x3F => {
            t.len = try r.byte();
            t.precision = try r.byte();
            t.scale = try r.byte();
        },
        0x28 => t.len = 3,
        0x29, 0x2A, 0x2B => t.scale = try r.byte(),
        // Two length bytes, with a collation for text.
        0xA7, 0xAF, 0xE7, 0xEF => {
            t.len = try r.int(u16);
            try r.read(&t.collation);
            t.plp = t.len == 0xFFFF;
        },
        0xA5, 0xAD => {
            t.len = try r.int(u16);
            t.plp = t.len == 0xFFFF;
        },
        // Legacy LOBs.
        0x23, 0x63 => {
            t.len = try r.int(u32);
            try r.read(&t.collation);
        },
        0x22 => t.len = try r.int(u32),
        0xF1 => { // XML: an optional schema collection
            if (try r.byte() != 0) {
                try r.skip(@as(usize, try r.byte()) * 2);
                try r.skip(@as(usize, try r.byte()) * 2);
                try r.skip(@as(usize, try r.int(u16)) * 2);
            }
            t.plp = true;
        },
        else => {
            log.err("unsupported column type 0x{X:0>2}", .{t.id});
            return error.UnsupportedType;
        },
    }
    return t;
}

fn readValue(r: *MsgReader, a: Allocator, t: TypeInfo) !Value {
    switch (t.id) {
        0x1F => return .null,
        // Fixed-length: the bytes follow with no prefix.
        0x30, 0x32, 0x34, 0x38, 0x7F, 0x3B, 0x3E, 0x3A, 0x3D, 0x3C, 0x7A => {
            var buf: [8]u8 = undefined;
            const b = buf[0..t.len];
            try r.read(b);
            return decodeFixed(t, b);
        },
        // A one-byte length; zero is NULL.
        0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x24, 0x6A, 0x6C, 0x37, 0x3F, 0x28, 0x29, 0x2A, 0x2B => {
            const n = try r.byte();
            if (n == 0) return .null;
            var buf: [255]u8 = undefined;
            const b = buf[0..n];
            try r.read(b);
            return decodeFixed(t, b);
        },
        0xA7, 0xAF, 0xE7, 0xEF, 0xA5, 0xAD, 0xF1 => {
            const b = if (t.plp)
                (try readPlp(r, a)) orelse return .null
            else blk: {
                const n = try r.int(u16);
                if (n == 0xFFFF) return .null;
                break :blk try r.alloc(a, n);
            };
            return decodeVar(a, t, b);
        },
        0x23, 0x63, 0x22 => { // TEXT, NTEXT, IMAGE: text pointer, timestamp, then the data
            const ptr_len = try r.byte();
            if (ptr_len == 0) return .null;
            try r.skip(@as(usize, ptr_len) + 8);
            const n = try r.int(u32);
            if (n > max_lob) return error.Protocol;
            return decodeVar(a, t, try r.alloc(a, n));
        },
        else => return error.UnsupportedType,
    }
}

fn decodeFixed(t: TypeInfo, b: []const u8) !Value {
    return switch (t.id) {
        0x30, 0x34, 0x38, 0x7F, 0x26 => value.decodeInt(b),
        0x32, 0x68 => .{ .boolean = b.len > 0 and b[0] != 0 },
        0x3B, 0x3E, 0x6D => value.decodeFloat(b),
        0x3C, 0x7A, 0x6E => value.decodeMoney(b),
        0x3A, 0x3D, 0x6F => value.decodeDateTime(b),
        0x6A, 0x6C, 0x37, 0x3F => value.decodeDecimal(b, t.scale),
        0x24 => value.decodeGuid(b),
        0x28 => value.decodeDate(b),
        0x29 => value.decodeTime(b, t.scale),
        0x2A => value.decodeDateTime2(b, t.scale),
        0x2B => value.decodeDateTimeOffset(b, t.scale),
        else => error.UnsupportedType,
    };
}

fn decodeVar(a: Allocator, t: TypeInfo, b: []u8) !Value {
    return switch (t.id) {
        0xE7, 0xEF, 0x63, 0xF1 => .{ .string = try value.utf16ToUtf8(a, b) },
        0xA7, 0xAF, 0x23 => .{ .string = try value.ansiToUtf8(a, t.collation, b) },
        else => .{ .bytes = b },
    };
}

/// PLP (MS-TDS 2.2.5.2.3): a u64 total (all ones = NULL), then u32-length chunks up to a zero.
fn readPlp(r: *MsgReader, a: Allocator) !?[]u8 {
    const total = try r.int(u64);
    if (total == 0xFFFF_FFFF_FFFF_FFFF) return null;
    const unknown = total == 0xFFFF_FFFF_FFFF_FFFE;
    if (!unknown and total > max_lob) return error.Protocol;
    var list: std.ArrayList(u8) = .empty;
    if (!unknown) try list.ensureTotalCapacity(a, @min(total, 1 << 20));
    while (true) {
        const n = try r.int(u32);
        if (n == 0) break;
        if (list.items.len + n > max_lob) return error.Protocol;
        try r.read(try list.addManyAsSlice(a, n));
    }
    return list.items;
}

test "login7 layout" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try buildLogin7(arena.allocator(), .{ .user = "sa", .password = "ab" });
    try std.testing.expectEqual(m.len, std.mem.readInt(u32, m[0..4], .little));
    // The user name sits where its offset says, as UTF-16.
    const ib = std.mem.readInt(u16, m[40..42], .little);
    try std.testing.expectEqualSlices(u8, "s\x00a\x00", m[ib..][0..4]);
    // The password is obfuscated: 'a' (0x61) -> nibbles swapped (0x16) ^ 0xA5 = 0xB3.
    const pw = std.mem.readInt(u16, m[44..46], .little);
    try std.testing.expectEqual(@as(u8, 0xB3), m[pw]);
}

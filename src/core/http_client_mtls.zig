//! HTTP client with mTLS (client-certificate) support, via shell-out to `curl`.
//!
//! `std.http.Client` (and therefore `pacman`/`spider.http_client`, which
//! wraps it directly) has no way to present a client certificate during the
//! TLS handshake — confirmed by reading `std.crypto.tls.Client.Options`,
//! whose only certificate-related fields are for verifying the *server*
//! (`.host`, `.ca`). There is no client-side certificate/signing hook. This
//! is a known stdlib gap (see ziglang/zig's open mTLS-for-clients issue), not
//! a Spider limitation — so this module deliberately bypasses `std.http.Client`
//! entirely and shells out to `curl`, which has supported `--cert`/`--key`
//! (including PKCS#12) for years. Needed for integrations that require
//! mTLS with an ICP-Brasil certificate (e.g. Sicoob's Open Finance API).
const std = @import("std");
const Io = std.Io;

/// A client certificate, in one of the two formats real-world mTLS
/// deployments show up in. ICP-Brasil certificates are normally issued as
/// PKCS#12 (.pfx/.p12); `.pkcs12` accepts that directly (curl decrypts it
/// itself), so callers don't need an extra manual conversion step to PEM.
pub const MtlsCert = union(enum) {
    pem: struct {
        /// PEM-encoded client certificate.
        cert: []const u8,
        /// PEM-encoded private key, unencrypted.
        key: []const u8,
    },
    pkcs12: struct {
        /// Raw PKCS#12 (.pfx/.p12) bytes.
        data: []const u8,
        password: []const u8,
    },
};

pub const MtlsRequest = struct {
    method: std.http.Method = .GET,
    headers: []const [2][]const u8 = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
};

pub const MtlsResponse = struct {
    status: std.http.Status,
    body: []const u8,

    pub fn deinit(self: *MtlsResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }

    pub fn json(self: MtlsResponse, comptime T: type, allocator: std.mem.Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{ .ignore_unknown_fields = true });
    }
};

/// Makes one HTTP request over an mTLS connection.
///
/// Deliberately does not take an `io: std.Io` parameter — every step here
/// (writing temp files, spawning curl) is a blocking-style OS operation, and
/// `fcm.zig`'s `signJwt` (orbitx) already hit `error.WouldBlock` in
/// production when this category of op ran on a request handler's `io`
/// (zio backend). Since the entire HTTP exchange here happens inside the
/// `curl` subprocess — there's no separate "do the HTTP call on the
/// caller's io" step like fcm.zig has — the whole function just owns a
/// dedicated `Io.Threaded` internally, the same fix fcm.zig applies to only
/// its subprocess portion.
pub fn request(
    gpa: std.mem.Allocator,
    url: []const u8,
    cert: MtlsCert,
    opts: MtlsRequest,
) !MtlsResponse {
    var threaded: Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Every allocation below except the final response body is scratch —
    // argv strings, temp-file paths, curl's captured stdout/stderr — needed
    // only for the duration of this call. Putting them all on one arena
    // (freed in a single `deinit()`) instead of pairing each `allocPrint`
    // with its own `gpa.free` removes an entire class of "forgot to free on
    // this error-return path" bugs; only `body` is copied into the caller's
    // `gpa` right before returning.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nonce = Io.Clock.now(.real, io).nanoseconds;

    const out_path = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-out-{d}.bin", .{nonce});
    defer Io.Dir.deleteFileAbsolute(io, out_path) catch {};

    var body_path: ?[]const u8 = null;
    defer if (body_path) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};
    if (opts.body) |body| {
        const path = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-body-{d}.bin", .{nonce});
        body_path = path;
        try writeTempFile(io, path, body);
    }

    // Paths deleted via `defer` immediately after being computed (before any
    // write that could fail) — same ordering fcm.zig's signJwt uses, so a
    // secret temp file is never left behind even on an early error return.
    var cert_path: ?[]const u8 = null;
    defer if (cert_path) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};
    var key_path: ?[]const u8 = null;
    defer if (key_path) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};
    var config_path: ?[]const u8 = null;
    defer if (config_path) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};

    const cert_files: CertFiles = switch (cert) {
        .pem => |pem| blk: {
            const cp = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-cert-{d}.pem", .{nonce});
            cert_path = cp;
            try writeTempFile(io, cp, pem.cert);

            const kp = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-key-{d}.pem", .{nonce});
            key_path = kp;
            try writeTempFile(io, kp, pem.key);

            break :blk .{ .pem = .{ .cert_path = cp, .key_path = kp } };
        },
        .pkcs12 => |p12| blk: {
            const cp = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-cert-{d}.p12", .{nonce});
            cert_path = cp;
            try writeTempFile(io, cp, p12.data);

            // The PKCS#12 password goes in a curl config file (`-K`), not
            // argv directly — argv is visible to any local process via
            // /proc/<pid>/cmdline (ps), a config file on disk is no worse
            // than the cert file itself (same temp-file-then-delete
            // handling), and it's what curl's own docs recommend for
            // secrets that shouldn't show up in `ps`.
            const cfg = try buildP12Config(arena, cp, p12.password);
            const cfgp = try std.fmt.allocPrint(arena, "/tmp/spider-mtls-config-{d}", .{nonce});
            config_path = cfgp;
            try writeTempFile(io, cfgp, cfg);

            break :blk .{ .pkcs12 = .{ .config_path = cfgp } };
        },
    };

    const argv = try buildArgv(arena, .{
        .out_path = out_path,
        .body_path = body_path,
        .cert_files = cert_files,
        .opts = opts,
        .url = url,
    });

    const result = std.process.run(arena, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(opts.timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        // `std.process.run` kills the child (its own `defer child.kill(io)`)
        // before returning this, on every error path including timeout —
        // no zombie process risk here.
        error.Timeout => return error.MtlsTimeout,
        else => return err,
    };

    // curl only exits non-zero on a transport/TLS failure (bad cert, refused
    // connection, DNS failure, etc). An HTTP-level error (4xx/5xx) is a
    // normal exit 0 with the status code available via -w — that split is
    // deliberate: it mirrors how `pacman.Response` treats HTTP error status
    // codes as data, not as a Zig error.
    if (!result.term.success()) {
        std.debug.print("[http_client_mtls] curl failed: {s}\n", .{result.stderr});
        return error.MtlsTransportFailed;
    }

    const status_code = parseStatusCode(result.stdout) catch {
        std.debug.print("[http_client_mtls] unparseable curl status output: {s}\n", .{result.stdout});
        return error.MtlsTransportFailed;
    };

    const body_in_arena = try Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(64 * 1024 * 1024));
    const body = try gpa.dupe(u8, body_in_arena);

    return .{ .status = @enumFromInt(status_code), .body = body };
}

fn writeTempFile(io: Io, path: []const u8, data: []const u8) !void {
    var file = try Io.Dir.createFileAbsolute(io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn formatMaxTime(gpa: std.mem.Allocator, timeout_ms: u32) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{d}.{d:0>3}", .{ timeout_ms / 1000, timeout_ms % 1000 });
}

/// Already-written cert/key (or PKCS#12 config) paths on disk — the output
/// of the `switch (cert)` temp-file-writing step in `request()`, and the
/// input `buildArgv` needs. Splitting this out of `MtlsCert` (which carries
/// raw secret bytes, not paths) is what makes `buildArgv` a pure,
/// disk-free, directly-testable function.
const CertFiles = union(enum) {
    pem: struct { cert_path: []const u8, key_path: []const u8 },
    pkcs12: struct { config_path: []const u8 },
};

const BuildArgvOptions = struct {
    out_path: []const u8,
    body_path: ?[]const u8,
    cert_files: CertFiles,
    opts: MtlsRequest,
    url: []const u8,
};

fn buildArgv(arena: std.mem.Allocator, o: BuildArgvOptions) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.appendSlice(arena, &.{
        "curl",
        "-sS",
        "-o", o.out_path,
        "-w", "%{http_code}",
        "-X", @tagName(o.opts.method),
    });

    const max_time = try formatMaxTime(arena, o.opts.timeout_ms);
    try argv.appendSlice(arena, &.{ "--max-time", max_time });

    for (o.opts.headers) |h| {
        const header_line = try std.fmt.allocPrint(arena, "{s}: {s}", .{ h[0], h[1] });
        try argv.appendSlice(arena, &.{ "-H", header_line });
    }

    if (o.body_path) |p| {
        const data_arg = try std.fmt.allocPrint(arena, "@{s}", .{p});
        try argv.appendSlice(arena, &.{ "--data-binary", data_arg });
    }

    switch (o.cert_files) {
        .pem => |p| try argv.appendSlice(arena, &.{ "--cert", p.cert_path, "--key", p.key_path }),
        .pkcs12 => |p| try argv.appendSlice(arena, &.{ "-K", p.config_path }),
    }

    try argv.append(arena, o.url);

    return argv.toOwnedSlice(arena);
}

/// Parses curl's `-w '%{http_code}'` stdout into a status code. Pulled out
/// of `request()` so the parsing itself — trimming, digit validation, the
/// `u10` range — is testable without spawning curl.
fn parseStatusCode(curl_stdout: []const u8) !u10 {
    const trimmed = std.mem.trim(u8, curl_stdout, " \t\r\n");
    return std.fmt.parseInt(u10, trimmed, 10);
}

/// Builds a curl config file (consumed via `-K`) that sets `cert-type`,
/// `cert` and `pass` for a PKCS#12 client certificate — keeping the
/// password out of argv/ps. Quoting follows curl's own config-file format
/// (see `man curl`, `-K, --config`): values enclosed in double quotes, with
/// `\` and `"` escaped — sufficient for arbitrary path/password content
/// since those are the only two characters the format treats specially.
fn buildP12Config(gpa: std.mem.Allocator, cert_path: []const u8, password: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "cert-type = \"P12\"\ncert = ");
    try appendQuotedConfigValue(&out, gpa, cert_path);
    try out.appendSlice(gpa, "\npass = ");
    try appendQuotedConfigValue(&out, gpa, password);
    try out.append(gpa, '\n');

    return out.toOwnedSlice(gpa);
}

fn appendQuotedConfigValue(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try out.append(gpa, '"');
    for (value) |c| {
        if (c == '\\' or c == '"') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

test "formatMaxTime formats milliseconds as fractional seconds" {
    const gpa = std.testing.allocator;

    const a = try formatMaxTime(gpa, 30_000);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("30.000", a);

    const b = try formatMaxTime(gpa, 1_500);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("1.500", b);

    const c = try formatMaxTime(gpa, 250);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("0.250", c);
}

test "buildP12Config escapes backslash and double-quote in the password" {
    const gpa = std.testing.allocator;

    const cfg = try buildP12Config(gpa, "/tmp/cert.p12", "a\"b\\c");
    defer gpa.free(cfg);

    try std.testing.expectEqualStrings(
        "cert-type = \"P12\"\ncert = \"/tmp/cert.p12\"\npass = \"a\\\"b\\\\c\"\n",
        cfg,
    );
}

test "MtlsResponse.json parses the body" {
    const gpa = std.testing.allocator;

    var res: MtlsResponse = .{ .status = .ok, .body = try gpa.dupe(u8, "{\"ok\":true}") };
    defer res.deinit(gpa);

    const parsed = try res.json(struct { ok: bool = false }, gpa);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
}

fn expectArgvContainsSequence(argv: []const []const u8, sequence: []const []const u8) !void {
    if (sequence.len == 0 or sequence.len > argv.len) return error.SequenceNotFound;

    var start: usize = 0;
    outer: while (start + sequence.len <= argv.len) : (start += 1) {
        for (sequence, 0..) |want, j| {
            if (!std.mem.eql(u8, argv[start + j], want)) continue :outer;
        }
        return;
    }

    std.debug.print("argv {any} does not contain sequence {any}\n", .{ argv, sequence });
    return error.SequenceNotFound;
}

test "buildArgv: PEM cert produces --cert/--key, method, timeout and url" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, .{
        .out_path = "/tmp/out.bin",
        .body_path = null,
        .cert_files = .{ .pem = .{ .cert_path = "/tmp/c.pem", .key_path = "/tmp/k.pem" } },
        .opts = .{ .method = .POST, .timeout_ms = 5_000 },
        .url = "https://example.com/pay",
    });

    try std.testing.expectEqualStrings("curl", argv[0]);
    try expectArgvContainsSequence(argv, &.{ "-X", "POST" });
    try expectArgvContainsSequence(argv, &.{ "--max-time", "5.000" });
    try expectArgvContainsSequence(argv, &.{ "--cert", "/tmp/c.pem", "--key", "/tmp/k.pem" });
    try std.testing.expectEqualStrings("https://example.com/pay", argv[argv.len - 1]);
    // No -K/data-binary should appear for a bodyless PEM request.
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "-K"));
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--data-binary"));
}

test "buildArgv: PKCS12 cert produces -K, not --cert/--key" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, .{
        .out_path = "/tmp/out.bin",
        .body_path = null,
        .cert_files = .{ .pkcs12 = .{ .config_path = "/tmp/cfg" } },
        .opts = .{},
        .url = "https://example.com",
    });

    try expectArgvContainsSequence(argv, &.{ "-K", "/tmp/cfg" });
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--cert"));
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--key"));
}

test "buildArgv: headers and body-path both show up correctly" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, .{
        .out_path = "/tmp/out.bin",
        .body_path = "/tmp/body.bin",
        .cert_files = .{ .pem = .{ .cert_path = "/tmp/c.pem", .key_path = "/tmp/k.pem" } },
        .opts = .{
            .method = .POST,
            .headers = &.{ .{ "Authorization", "Bearer xyz" }, .{ "Content-Type", "application/json" } },
        },
        .url = "https://example.com",
    });

    try expectArgvContainsSequence(argv, &.{ "-H", "Authorization: Bearer xyz" });
    try expectArgvContainsSequence(argv, &.{ "-H", "Content-Type: application/json" });
    try expectArgvContainsSequence(argv, &.{ "--data-binary", "@/tmp/body.bin" });
}

test "parseStatusCode parses a trimmed three-digit code" {
    try std.testing.expectEqual(@as(u10, 200), try parseStatusCode("200"));
    try std.testing.expectEqual(@as(u10, 404), try parseStatusCode(" 404 \n"));
    try std.testing.expectEqual(@as(u10, 500), try parseStatusCode("500\n"));
}

test "parseStatusCode rejects non-numeric curl output" {
    try std.testing.expectError(error.InvalidCharacter, parseStatusCode("curl: (7) Failed to connect"));
    try std.testing.expectError(error.InvalidCharacter, parseStatusCode(""));
}

test "request: connection refused maps to MtlsTransportFailed and leaves no temp files, requires curl" {
    const gpa = std.testing.allocator;

    // Port 1 is a reserved/unassigned port — nothing should ever be
    // listening on it locally, so this fails fast and deterministically
    // without needing a real server or valid certs (the TLS handshake
    // never starts; curl fails at TCP connect).
    const result = request(gpa, "https://127.0.0.1:1/", .{
        .pem = .{ .cert = "not-a-real-cert", .key = "not-a-real-key" },
    }, .{ .timeout_ms = 2_000 });

    if (result) |res_val| {
        var res = res_val;
        res.deinit(gpa);
        return error.UnexpectedSuccess;
    } else |err| switch (err) {
        // curl isn't guaranteed to be on PATH in every environment this
        // test suite runs in; skip rather than fail in that case; this is
        // still a real dependency of the feature (see the module's top
        // doc-comment), just not one this test can enforce.
        error.FileNotFound => return error.SkipZigTest,
        error.MtlsTransportFailed => {},
        else => return err,
    }

    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var dir = try Io.Dir.cwd().openDir(io, "/tmp", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "spider-mtls-")) {
            std.debug.print("leftover temp file: {s}\n", .{entry.name});
            return error.LeftoverTempFile;
        }
    }
}

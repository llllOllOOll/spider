//! Modules: packages that plug into an app through one declared contract,
//! checked before they can run (RFC 0001, `docs/rfcs/0001-modules.md`).
//!
//! A module declares a manifest with `spider.module(.{ ... })` and may
//! expose `check`, `boot`, `shutdown`, `jobs` and `routes`. The app mounts
//! modules with `server.mountModules(.{ a, b })`, which checks, at compile
//! time, every manifest, every signature and the dependencies between
//! modules, and computes the order they start in. Before `listen()` accepts
//! a connection, Spider runs every module's checks (declared environment
//! variables, migrations applied and unchanged, the module's own `check`)
//! and refuses to start, listing every problem, when one fails.
//!
//! The rules live in functions that return the problem as text (or null),
//! so they are unit-tested here; `module` and `mountModules` turn a problem
//! into a compile error.

const std = @import("std");
const Io = std.Io;
const semver = @import("../internal/semver.zig");
const spider_version = @import("../version.zig").version;
const migration = @import("migration.zig");
const env = @import("../internal/env.zig");

const Migration = migration.Migration;

/// The environment variables a module reads: `required` ones must be set
/// (and not empty) for the module to start; `optional` ones are listed for
/// the reader and the surface lock.
pub const Env = struct {
    /// Must be set and not empty, or `listen()` refuses to start.
    required: []const []const u8 = &.{},
    /// Read when present.
    optional: []const []const u8 = &.{},
};

/// What a module declares about itself. Built by `spider.module`; read
/// from `M.spider_module.manifest`.
pub const Manifest = struct {
    /// `[a-z][a-z0-9_]*`, at most 64 bytes, unique in the app.
    name: []const u8,
    /// The module's own version (semver).
    version: []const u8,
    /// The Spider versions it supports, as a range: `">=0.11.0 <0.13.0"`.
    spider: []const u8,
    /// The modules it needs, by name; they start before it.
    requires: []const []const u8 = &.{},
    /// Its database migrations, in the order they run.
    migrations: []const Migration = &.{},
    /// The environment variables it reads.
    env: Env = .{},
};

const manifest_fields = [_][]const u8{ "name", "version", "spider", "requires", "migrations", "env" };

/// Declares a module. Put it in the module's root file as
/// `pub const spider_module = spider.module(.{ ... });`: it checks the
/// manifest at compile time (name, version, the Spider range against
/// `spider.version`, requires, migrations, env) and fails the build with a
/// message naming the module when something is wrong.
///
/// ```zig
/// pub const spider_module = spider.module(.{
///     .name = "notify",
///     .version = "0.2.0",
///     .spider = ">=0.11.0 <0.13.0",
///     .migrations = &.{.{ .name = "0001_init", .sql = @embedFile("sql/0001_init.sql") }},
///     .env = .{ .optional = .{"VAPID_PUBLIC_KEY"} },
/// });
///
/// pub fn check(c: *spider.Check) !void {
///     if (c.env("VAPID_PUBLIC_KEY") != null and c.env("VAPID_PRIVATE_KEY") == null)
///         c.fail("VAPID_PRIVATE_KEY is empty while VAPID_PUBLIC_KEY is set", .{});
/// }
/// ```
pub fn module(comptime spec: anytype) type {
    const m = comptime toManifest(spec);
    if (comptime manifestProblem(m, spider_version)) |problem|
        @compileError(std.fmt.comptimePrint("spider.module(\"{s}\"): {s}", .{ m.name, problem }));
    return struct {
        /// The checked manifest.
        pub const manifest: Manifest = m;
    };
}

fn toManifest(comptime spec: anytype) Manifest {
    const S = @TypeOf(spec);
    for (@typeInfo(S).@"struct".field_names) |f| {
        for (manifest_fields) |known| {
            if (std.mem.eql(u8, f, known)) break;
        } else @compileError("spider.module: unknown field ." ++ f ++ " (the fields are .name, .version, .spider, .requires, .migrations, .env)");
    }
    inline for (.{ "name", "version", "spider" }) |f| {
        if (!@hasField(S, f)) @compileError("spider.module: ." ++ f ++ " is required");
    }
    var m: Manifest = .{ .name = spec.name, .version = spec.version, .spider = spec.spider };
    if (@hasField(S, "requires")) m.requires = strings(spec.requires);
    if (@hasField(S, "migrations")) m.migrations = migrationsOf(spec.migrations);
    if (@hasField(S, "env")) {
        const E = @TypeOf(spec.env);
        for (@typeInfo(E).@"struct".field_names) |f| {
            if (!std.mem.eql(u8, f, "required") and !std.mem.eql(u8, f, "optional"))
                @compileError("spider.module: unknown field .env." ++ f ++ " (the fields are .required and .optional)");
        }
        if (@hasField(E, "required")) m.env.required = strings(spec.env.required);
        if (@hasField(E, "optional")) m.env.optional = strings(spec.env.optional);
    }
    return m;
}

/// A tuple or a slice of strings, as a slice that outlives the call.
fn strings(comptime list: anytype) []const []const u8 {
    const T = @TypeOf(list);
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        var out: [list.len][]const u8 = undefined;
        for (&out, 0..) |*o, i| o.* = list[i];
        const final = out;
        return &final;
    }
    return list;
}

fn migrationsOf(comptime list: anytype) []const Migration {
    const T = @TypeOf(list);
    if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        var out: [list.len]Migration = undefined;
        for (&out, 0..) |*o, i| o.* = .{ .name = list[i].name, .sql = list[i].sql };
        const final = out;
        return &final;
    }
    return list;
}

fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

// internal: what is wrong with a manifest for this Spider version, or null.
// Compile time only (the text is built with comptimePrint).
pub fn manifestProblem(comptime m: Manifest, comptime current: std.SemanticVersion) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const fmt = std.fmt.comptimePrint;
    if (!validModuleName(m.name)) return fmt(".name \"{s}\" must match [a-z][a-z0-9_]* (at most 64 bytes)", .{m.name});
    _ = std.SemanticVersion.parse(m.version) catch return fmt(".version \"{s}\" is not semver (major.minor.patch)", .{m.version});
    const range = semver.parseRange(m.spider) catch |err| return fmt(".spider \"{s}\" is not a version range ({s}); write e.g. \">=0.11.0 <0.13.0\"", .{ m.spider, @errorName(err) });
    if (!range.contains(current)) return fmt("supports Spider {s}, but this is Spider {f}", .{ m.spider, current });
    for (m.requires, 0..) |r, i| {
        if (!validModuleName(r)) return fmt(".requires \"{s}\" is not a module name", .{r});
        if (std.mem.eql(u8, r, m.name)) return ".requires names the module itself";
        for (m.requires[0..i]) |prev| if (std.mem.eql(u8, prev, r)) return fmt(".requires names \"{s}\" twice", .{r});
    }
    for (m.migrations, 0..) |mig, i| {
        if (migration.nameProblem(mig.name)) |p| return fmt("migration \"{s}\" {s}", .{ mig.name, p });
        if (i > 0 and !std.mem.lessThan(u8, m.migrations[i - 1].name, mig.name))
            return fmt("migration \"{s}\" comes after \"{s}\": list migrations in the order they run, without repeats", .{ mig.name, m.migrations[i - 1].name });
        if (mig.sql.len == 0) return fmt("migration \"{s}\" has no SQL", .{mig.name});
    }
    const all_env = m.env.required ++ m.env.optional;
    for (all_env, 0..) |e, i| {
        if (!validEnvName(e)) return fmt(".env \"{s}\" must match [A-Z][A-Z0-9_]*", .{e});
        for (all_env[0..i]) |prev| if (std.mem.eql(u8, prev, e)) return fmt(".env names \"{s}\" twice", .{e});
    }
    return null;
}

// internal: what is wrong with a set of manifests mounted together
// (a repeated name, a missing or circular dependency), or null.
pub fn planProblem(comptime ms: []const Manifest) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const fmt = std.fmt.comptimePrint;
    for (ms, 0..) |m, i| {
        for (ms[0..i]) |prev| if (std.mem.eql(u8, prev.name, m.name))
            return fmt("module \"{s}\" is mounted twice", .{m.name});
    }
    for (ms) |m| {
        for (m.requires) |r| {
            for (ms) |other| {
                if (std.mem.eql(u8, other.name, r)) break;
            } else return fmt("module \"{s}\" requires \"{s}\", which is not mounted: add it to the same mountModules call", .{ m.name, r });
        }
    }
    _ = order(ms) catch {
        var names: []const u8 = "";
        for (ms) |m| names = names ++ " " ++ m.name;
        return fmt("the modules' requires form a cycle (among:{s})", .{names});
    };
    return null;
}

// internal: the order modules start in: each after the modules it
// requires; ties keep the mount order. error.Cycle when requires loop.
pub fn order(comptime ms: []const Manifest) error{Cycle}![ms.len]usize {
    @setEvalBranchQuota(100_000);
    var out: [ms.len]usize = undefined;
    var placed: [ms.len]bool = @splat(false);
    var n: usize = 0;
    while (n < ms.len) {
        var progressed = false;
        for (ms, 0..) |m, i| {
            if (placed[i]) continue;
            const ready = for (m.requires) |r| {
                const dep = for (ms, 0..) |other, j| {
                    if (std.mem.eql(u8, other.name, r)) break j;
                } else continue; // missing: planProblem reports it
                if (!placed[dep]) break false;
            } else true;
            if (!ready) continue;
            placed[i] = true;
            out[n] = i;
            n += 1;
            progressed = true;
            break;
        }
        if (!progressed) return error.Cycle;
    }
    return out;
}

// internal: what is wrong with the declarations a module exposes to
// Spider (`check`, `boot`, `shutdown`, `routes`, `jobs`), or null. `Boot`,
// `Group` and `Job` come from the caller (core/app.zig) to keep this file
// free of the server.
pub fn declProblem(comptime M: type, comptime Boot: type, comptime Group: type, comptime Job: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const fmt = std.fmt.comptimePrint;
    if (@hasDecl(M, "boot") and !isFn(@TypeOf(M.boot), &.{Boot}, .error_union_void))
        return "boot must be `pub fn boot(b: spider.Boot) !void`";
    if (@hasDecl(M, "check") and !isFn(@TypeOf(M.check), &.{*Check}, .error_union_void))
        return "check must be `pub fn check(c: *spider.Check) !void`";
    if (@hasDecl(M, "shutdown") and !isFn(@TypeOf(M.shutdown), &.{Boot}, .void))
        return "shutdown must be `pub fn shutdown(b: spider.Boot) void`";
    if (@hasDecl(M, "routes")) {
        if (@TypeOf(M.routes) != type or @typeInfo(M.routes) != .@"struct")
            return "routes must be a struct of functions returning spider.Group";
        for (@typeInfo(M.routes).@"struct".decl_names) |fname| {
            const FT = @TypeOf(@field(M.routes, fname));
            if (@typeInfo(FT) != .@"fn") continue;
            const info = @typeInfo(FT).@"fn";
            if (info.return_type == Group and info.param_types.len != 0)
                return fmt("routes.{s} returns spider.Group but takes parameters: route builders take none", .{fname});
        }
    }
    if (@hasDecl(M, "jobs")) {
        const J = @TypeOf(M.jobs);
        if (@typeInfo(J) != .@"struct" or !@typeInfo(J).@"struct".is_tuple)
            return "jobs must be a tuple of spider.every(ms, fn)";
        for (@typeInfo(J).@"struct".field_types, 0..) |FT, i| {
            if (FT != Job) return fmt("jobs[{d}] is not a spider.every(ms, fn)", .{i});
        }
    }
    return null;
}

const Ret = enum { void, error_union_void };

fn isFn(comptime FT: type, comptime params: []const type, comptime ret: Ret) bool {
    if (@typeInfo(FT) != .@"fn") return false;
    const info = @typeInfo(FT).@"fn";
    if (info.param_types.len != params.len) return false;
    for (info.param_types, params) |p, want| if (p != want) return false;
    const R = info.return_type orelse return false;
    return switch (ret) {
        .void => R == void,
        .error_union_void => @typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void,
    };
}

// internal: the manifest of a mounted namespace, or a compile error that
// names it when it declares none.
pub fn manifestOf(comptime M: type) Manifest {
    if (!@hasDecl(M, "spider_module"))
        @compileError(@typeName(M) ++ " is not a module: it has no `pub const spider_module = spider.module(.{ ... })`");
    const S = M.spider_module;
    if (@TypeOf(S) != type or !@hasDecl(S, "manifest") or @TypeOf(S.manifest) != Manifest)
        @compileError(@typeName(M) ++ ".spider_module must be `spider.module(.{ ... })`");
    return S.manifest;
}

// ── checks before listen() ─────────────────────────────────────────────

/// One thing a module needs and does not have.
pub const Problem = struct {
    /// The module's name.
    module: []const u8,
    /// What is wrong, and what to do.
    message: []const u8,
};

/// The result of the checks every module runs before `listen()`.
pub const Report = struct {
    // internal: owns the messages.
    arena: std.mem.Allocator,
    /// Every problem found, in the order the modules start.
    problems: std.ArrayList(Problem) = .empty,
    /// How many modules were checked.
    checked: usize = 0,

    /// True when no module reported a problem.
    pub fn ok(self: *const Report) bool {
        return self.problems.items.len == 0;
    }

    // internal: records a problem; when there is no memory to format it,
    // the format string itself stands in for the message.
    pub fn add(self: *Report, module_name: []const u8, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch fmt;
        self.problems.append(self.arena, .{ .module = module_name, .message = message }) catch {};
    }

    /// Writes the report: one line per problem, under a summary line.
    pub fn write(self: *const Report, w: *Io.Writer) Io.Writer.Error!void {
        if (self.ok()) {
            try w.print("spider: {d} module(s) ready\n", .{self.checked});
            return;
        }
        var modules: usize = 0;
        for (self.problems.items, 0..) |p, i| {
            const seen = for (self.problems.items[0..i]) |prev| {
                if (std.mem.eql(u8, prev.module, p.module)) break true;
            } else false;
            if (!seen) modules += 1;
        }
        try w.print("spider: {d} module(s) not ready, refusing to start\n", .{modules});
        for (self.problems.items) |p| try w.print("  {s}: {s}\n", .{ p.module, p.message });
    }
};

/// Given to a module's `check(c)`, which runs before any module boots and
/// must not change anything. `fail` records a problem (the check goes on, so
/// the report lists every one); a `check` that returns an error counts as
/// one more.
pub const Check = struct {
    /// Lives until the report is written.
    arena: std.mem.Allocator,
    /// An Io for the check (a database query, a file).
    io: Io,
    /// The module being checked.
    module: []const u8,
    // internal: where problems go.
    _report: *Report,

    /// Records a problem: `c.fail("FCM_PRIVATE_KEY is empty", .{})`.
    pub fn fail(self: *Check, comptime fmt: []const u8, args: anytype) void {
        self._report.add(self.module, fmt, args);
    }

    /// The value of an environment variable (as `spider.env.get`), or null.
    pub fn env(_: *Check, name: []const u8) ?[]const u8 {
        return env_get(name);
    }
};

// Where checks read the environment: spider.env.get, swapped only by the
// tests of this file.
var env_get: *const fn ([]const u8) ?[]const u8 = env.get;

// internal: the type of a module's `check`.
pub const CheckFn = *const fn (*Check) anyerror!void;

// internal: what the server keeps of a mounted module.
pub const Entry = struct {
    manifest: Manifest,
    check: ?CheckFn = null,
};

// internal: reads which migrations are applied (spider.pg.migrations.status
// when the app is built with PostgreSQL), in the order of `steps`.
pub const StatusFn = *const fn (arena: std.mem.Allocator, steps: []const migration.Step) anyerror![]const migration.State;

// internal: runs the checks of every entry, in order, into `report`.
// Spider's own checks come first (required environment variables,
// migrations applied and unchanged); a module whose own checks failed does
// not run its `check`, which would only repeat the cause.
pub fn runChecks(report: *Report, io: Io, entries: []const Entry, status: ?StatusFn) void {
    const arena = report.arena;
    for (entries) |e| {
        report.checked += 1;
        const before = report.problems.items.len;
        const name = e.manifest.name;
        for (e.manifest.env.required) |var_name| {
            const value = env_get(var_name) orelse "";
            if (std.mem.trim(u8, value, " \t\r\n").len == 0) report.add(name, "{s} is required but not set", .{var_name});
        }
        if (e.manifest.migrations.len > 0) {
            const steps = stepsOf(arena, &.{e}) catch {
                report.add(name, "out of memory while listing its migrations", .{});
                continue;
            };
            checkMigrations(report, name, steps, status);
        }
        if (report.problems.items.len != before) continue;
        const f = e.check orelse continue;
        var c: Check = .{ .arena = arena, .io = io, .module = name, ._report = report };
        f(&c) catch |err| report.add(name, "check() failed: error.{s}", .{@errorName(err)});
    }
}

// internal: records in `report`, under `owner`, every one of `steps` that
// is not applied or changed after it was applied (the modules' and the
// app's migrations alike); `status` is null when the app is built without
// PostgreSQL.
pub fn checkMigrations(report: *Report, owner: []const u8, steps: []const migration.Step, status: ?StatusFn) void {
    if (steps.len == 0) return;
    const read = status orelse {
        report.add(owner, "ships database migrations, but the app is built without PostgreSQL (build Spider with -Dpg=true)", .{});
        return;
    };
    const states = read(report.arena, steps) catch |err| {
        if (err == error.DatabaseNotInitialized)
            report.add(owner, "ships database migrations, but the database is not open: call spider.pg.init(...) before listen()", .{})
        else
            report.add(owner, "could not read schema_migrations: error.{s}", .{@errorName(err)});
        return;
    };
    for (steps, states) |s, st| {
        const k = migration.key(report.arena, s.module, s.name) catch s.name;
        switch (st) {
            .applied => {},
            .pending => report.add(owner, "migration {s} is not applied (run `spider migrate`)", .{k}),
            .changed => report.add(owner, "migration {s} changed after it was applied (its checksum differs): add a new migration instead of editing an applied one", .{k}),
        }
    }
}

// internal: the migrations of `entries`, in start order, as steps for
// spider.pg.migrations.
pub fn stepsOf(arena: std.mem.Allocator, entries: []const Entry) ![]migration.Step {
    var out: std.ArrayList(migration.Step) = .empty;
    for (entries) |e| for (e.manifest.migrations) |mig| {
        try out.append(arena, .{ .module = e.manifest.name, .name = mig.name, .sql = migration.upSection(mig.sql) });
    };
    return out.items;
}

// internal: the app's own migrations as steps (no module: their keys are
// their bare names).
pub fn appStepsOf(arena: std.mem.Allocator, list: []const Migration) ![]migration.Step {
    const out = try arena.alloc(migration.Step, list.len);
    for (list, out) |mig, *o| o.* = .{ .module = "", .name = mig.name, .sql = migration.upSection(mig.sql) };
    return out;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn ver(comptime s: []const u8) std.SemanticVersion {
    return std.SemanticVersion.parse(s) catch unreachable;
}

const good: Manifest = .{ .name = "notify", .version = "0.2.0", .spider = ">=0.10.0 <0.13.0" };

fn withName(comptime n: []const u8) Manifest {
    var m = good;
    m.name = n;
    return m;
}

test "manifestProblem: a good manifest passes" {
    comptime std.debug.assert(manifestProblem(good, ver("0.10.1")) == null);
}

test "manifestProblem: the Spider version must be in the range" {
    const p = comptime manifestProblem(good, ver("0.13.0")).?;
    try testing.expectEqualStrings("supports Spider >=0.10.0 <0.13.0, but this is Spider 0.13.0", p);
}

test "manifestProblem: names, versions and ranges" {
    try testing.expect(comptime manifestProblem(withName("Notify"), ver("0.10.1")) != null);
    try testing.expect(comptime manifestProblem(withName("9x"), ver("0.10.1")) != null);
    comptime var m = good;
    m.version = "1.0";
    try testing.expect(comptime manifestProblem(m, ver("0.10.1")) != null);
    m = good;
    m.spider = "^0.10.0";
    try testing.expect(std.mem.indexOf(u8, comptime manifestProblem(m, ver("0.10.1")).?, "not a version range") != null);
}

test "manifestProblem: requires" {
    comptime var m = good;
    m.requires = &.{"notify"};
    try testing.expectEqualStrings(".requires names the module itself", comptime manifestProblem(m, ver("0.10.1")).?);
    m.requires = &.{ "audit", "audit" };
    try testing.expect(comptime manifestProblem(m, ver("0.10.1")) != null);
}

test "manifestProblem: migrations in order, with SQL" {
    comptime var m = good;
    m.migrations = &.{ .{ .name = "0002_b", .sql = "x" }, .{ .name = "0001_a", .sql = "x" } };
    try testing.expect(std.mem.indexOf(u8, comptime manifestProblem(m, ver("0.10.1")).?, "comes after") != null);
    m.migrations = &.{.{ .name = "1_a", .sql = "x" }};
    try testing.expect(std.mem.indexOf(u8, comptime manifestProblem(m, ver("0.10.1")).?, "fewer than four digits") != null);
    m.migrations = &.{.{ .name = "0001_a", .sql = "" }};
    try testing.expect(std.mem.indexOf(u8, comptime manifestProblem(m, ver("0.10.1")).?, "no SQL") != null);
}

test "manifestProblem: env names" {
    comptime var m = good;
    m.env = .{ .required = &.{"api_key"} };
    try testing.expect(comptime manifestProblem(m, ver("0.10.1")) != null);
    m.env = .{ .required = &.{"API_KEY"}, .optional = &.{"API_KEY"} };
    try testing.expect(std.mem.indexOf(u8, comptime manifestProblem(m, ver("0.10.1")).?, "twice") != null);
}

fn requiring(comptime n: []const u8, comptime reqs: []const []const u8) Manifest {
    var m = withName(n);
    m.requires = reqs;
    return m;
}

test "order: required modules first, mount order otherwise" {
    const ms = comptime [_]Manifest{ requiring("app_notices", &.{"notify"}), withName("audit"), withName("notify") };
    const o = comptime order(&ms) catch unreachable;
    // audit (index 1) and notify (2) have no requires: mount order;
    // app_notices (0) after notify.
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &o);
}

test "planProblem: repeated, missing and circular" {
    const twice = comptime [_]Manifest{ withName("a"), withName("a") };
    try testing.expectEqualStrings("module \"a\" is mounted twice", comptime planProblem(&twice).?);
    const missing = comptime [_]Manifest{requiring("a", &.{"b"})};
    try testing.expect(std.mem.indexOf(u8, comptime planProblem(&missing).?, "requires \"b\", which is not mounted") != null);
    const cycle = comptime [_]Manifest{ requiring("a", &.{"b"}), requiring("b", &.{"a"}) };
    try testing.expect(std.mem.indexOf(u8, comptime planProblem(&cycle).?, "cycle") != null);
    const fine = comptime [_]Manifest{ requiring("a", &.{"b"}), withName("b") };
    comptime std.debug.assert(planProblem(&fine) == null);
}

const TBoot = struct { allocator: std.mem.Allocator };
const TGroup = struct { x: u8 = 0 };
const TJob = struct { every_ms: u64 };

test "declProblem: exact signatures, nothing ignored" {
    const Good = struct {
        pub fn boot(_: TBoot) !void {}
        pub fn check(_: *Check) !void {}
        pub fn shutdown(_: TBoot) void {}
        pub const routes = struct {
            pub fn build() TGroup {
                return .{};
            }
            pub fn helper(_: u8) u8 {
                return 0;
            }
        };
        pub const jobs = .{TJob{ .every_ms = 1 }};
    };
    comptime std.debug.assert(declProblem(Good, TBoot, TGroup, TJob) == null);

    const BadBoot = struct {
        pub fn boot() void {}
    };
    try testing.expectEqualStrings("boot must be `pub fn boot(b: spider.Boot) !void`", comptime declProblem(BadBoot, TBoot, TGroup, TJob).?);
    const BadCheck = struct {
        pub fn check(_: *Check) void {}
    };
    try testing.expect(comptime declProblem(BadCheck, TBoot, TGroup, TJob) != null);
    const BadShutdown = struct {
        pub fn shutdown(_: TBoot) !void {}
    };
    try testing.expect(comptime declProblem(BadShutdown, TBoot, TGroup, TJob) != null);
    const BadRoute = struct {
        pub const routes = struct {
            pub fn build(_: u8) TGroup {
                return .{};
            }
        };
    };
    try testing.expectEqualStrings("routes.build returns spider.Group but takes parameters: route builders take none", comptime declProblem(BadRoute, TBoot, TGroup, TJob).?);
    const BadJobs = struct {
        pub const jobs = .{@as(u8, 1)};
    };
    try testing.expect(comptime declProblem(BadJobs, TBoot, TGroup, TJob) != null);
}

test "module: builds the manifest from a literal" {
    const M = module(.{
        .name = "notify",
        .version = "0.2.0",
        .spider = ">=0.10.0 <1.0.0",
        .requires = .{"audit"},
        .migrations = .{.{ .name = "0001_init", .sql = "CREATE TABLE t (id int)" }},
        .env = .{ .required = .{"NOTIFY_KEY"}, .optional = .{"NOTIFY_OTHER"} },
    });
    try testing.expectEqualStrings("notify", M.manifest.name);
    try testing.expectEqualStrings("audit", M.manifest.requires[0]);
    try testing.expectEqualStrings("0001_init", M.manifest.migrations[0].name);
    try testing.expectEqualStrings("NOTIFY_KEY", M.manifest.env.required[0]);
    try testing.expectEqualStrings("NOTIFY_OTHER", M.manifest.env.optional[0]);
}

fn fakeEnv(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "SET_KEY")) return "x";
    if (std.mem.eql(u8, name, "BLANK_KEY")) return "  ";
    return null;
}

fn statusAllPending(arena: std.mem.Allocator, steps: []const migration.Step) anyerror![]const migration.State {
    const out = try arena.alloc(migration.State, steps.len);
    @memset(out, .pending);
    if (out.len > 1) out[1] = .changed;
    return out;
}

fn statusAllApplied(arena: std.mem.Allocator, steps: []const migration.Step) anyerror![]const migration.State {
    const out = try arena.alloc(migration.State, steps.len);
    @memset(out, .applied);
    return out;
}

var own_check_ran = false;

fn ownCheck(c: *Check) anyerror!void {
    own_check_ran = true;
    c.fail("own problem {d}", .{7});
    return error.Unreachable;
}

test "runChecks: env, migrations, the module's own check, every problem listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const saved = env_get;
    env_get = fakeEnv;
    defer env_get = saved;

    const with_env: Manifest = .{ .name = "a", .version = "1.0.0", .spider = "1.0.0", .env = .{ .required = &.{ "SET_KEY", "BLANK_KEY", "MISSING_KEY" } } };
    const with_migs: Manifest = .{ .name = "b", .version = "1.0.0", .spider = "1.0.0", .migrations = &.{ .{ .name = "0001_x", .sql = "s" }, .{ .name = "0002_y", .sql = "s" } } };
    const clean: Manifest = .{ .name = "c", .version = "1.0.0", .spider = "1.0.0" };

    var report: Report = .{ .arena = arena_state.allocator() };
    own_check_ran = false;
    runChecks(&report, undefined, &.{
        .{ .manifest = with_env, .check = ownCheck }, // own check skipped: env failed
        .{ .manifest = with_migs },
        .{ .manifest = clean, .check = ownCheck },
    }, statusAllPending);
    try testing.expect(!report.ok());
    try testing.expectEqual(@as(usize, 3), report.checked);

    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try report.write(&w);
    try testing.expectEqualStrings(
        \\spider: 3 module(s) not ready, refusing to start
        \\  a: BLANK_KEY is required but not set
        \\  a: MISSING_KEY is required but not set
        \\  b: migration b/0001_x is not applied (run `spider migrate`)
        \\  b: migration b/0002_y changed after it was applied (its checksum differs): add a new migration instead of editing an applied one
        \\  c: own problem 7
        \\  c: check() failed: error.Unreachable
        \\
    , w.buffered());
    try testing.expect(own_check_ran);
}

test "runChecks: migrations without PostgreSQL, and a ready set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const with_migs: Manifest = .{ .name = "b", .version = "1.0.0", .spider = "1.0.0", .migrations = &.{.{ .name = "0001_x", .sql = "s" }} };

    var no_pg: Report = .{ .arena = arena_state.allocator() };
    runChecks(&no_pg, undefined, &.{.{ .manifest = with_migs }}, null);
    try testing.expect(std.mem.indexOf(u8, no_pg.problems.items[0].message, "without PostgreSQL") != null);

    var ready: Report = .{ .arena = arena_state.allocator() };
    runChecks(&ready, undefined, &.{.{ .manifest = with_migs }}, statusAllApplied);
    try testing.expect(ready.ok());
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try ready.write(&w);
    try testing.expectEqualStrings("spider: 1 module(s) ready\n", w.buffered());
}

test "stepsOf: every migration, keyed by its module, in start order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a: Manifest = .{ .name = "a", .version = "1.0.0", .spider = "1.0.0", .migrations = &.{.{ .name = "0001_x", .sql = "x" }} };
    const b: Manifest = .{ .name = "b", .version = "1.0.0", .spider = "1.0.0", .migrations = &.{ .{ .name = "0001_y", .sql = "y" }, .{ .name = "0002_z", .sql = "z" } } };
    const steps = try stepsOf(arena_state.allocator(), &.{ .{ .manifest = a }, .{ .manifest = b } });
    try testing.expectEqual(@as(usize, 3), steps.len);
    try testing.expectEqualStrings("b", steps[2].module);
    try testing.expectEqualStrings("0002_z", steps[2].name);
}

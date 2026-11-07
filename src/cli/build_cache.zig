//! Internal: keeps a project's `.zig-cache` small. Zig never deletes an
//! output from its cache: every build whose inputs changed leaves a new
//! copy of each executable and test binary in `.zig-cache/o/<hash>/`, and
//! the old ones stay forever (an app's Debug binary is hundreds of MB: one
//! working day filled 25 GB). `prune` removes the old copies and keeps the
//! newest `keep` of each program. Only programs (executables and test
//! binaries) are ever removed: libraries and objects (compiler_rt, libc,
//! a C library) are small next to them, and different builds of them share
//! a name and nearly a size, so an old copy cannot be told from a current
//! one. A build that needs a removed old program compiles it again.
//!
//! Run on every build by the `spider-test-manifest` tool (`testManifest()`
//! in build.zig, which every Spider app calls), and by `spider clean`.
//! `SPIDER_KEEP_ZIG_CACHE` set turns the automatic run off.

const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    /// Copies of each file name to keep, newest first.
    keep: usize = 2,
    /// An output younger than this is never removed: another build (a
    /// `zig build test` next to `spider dev`) may be using it.
    min_age_ns: i96 = 2 * std.time.ns_per_min,
    /// Programs smaller than this are not counted: the app's executable and
    /// the test binaries are what fills the disk.
    min_artifact_bytes: u64 = 1024 * 1024,
    /// "Now", for the tests; the real clock when null.
    now: ?Io.Timestamp = null,
};

pub const Result = struct {
    removed: usize = 0,
    freed_bytes: u64 = 0,

    fn add(self: *Result, other: Result) void {
        self.removed += other.removed;
        self.freed_bytes += other.freed_bytes;
    }
};

const Artifact = struct {
    dir: []const u8,
    name: []const u8,
    size: u64,
    mtime: i96,
};

/// Many binaries share a name (every test binary is `test`): copies of one
/// binary are told apart from another by their size, which changes little
/// from one edit to the next (0.01% to 0.03% measured) and more from one
/// suite to another. Deleting the newest output of a step makes Zig fail
/// that step instead of compiling it again, so the margin is narrow: a
/// bigger edit only leaves an old copy behind until the next ones.
const same_binary_size_ratio: f64 = 0.005;

fn sameBinary(x: Artifact, y: Artifact) bool {
    if (!std.mem.eql(u8, x.name, y.name)) return false;
    const big: f64 = @floatFromInt(@max(x.size, y.size));
    const small: f64 = @floatFromInt(@min(x.size, y.size));
    return big - small <= big * same_binary_size_ratio;
}

/// An executable or a test binary: no extension and executable, or `.exe`.
/// Never an archive, object or shared library (`.a`, `.o`, `.so`...).
fn isProgram(name: []const u8, permissions: Io.File.Permissions) bool {
    if (std.mem.endsWith(u8, name, ".exe")) return true;
    if (std.mem.indexOfScalar(u8, name, '.') != null) return false;
    if (comptime !Io.File.Permissions.has_executable_bit) return false;
    return permissions.toMode() & 0o111 != 0;
}

/// Whether `cache_dir` is (also) Zig's global cache: it has the global
/// cache's own directories, `p` (packages) or `b` (build runners). CI points
/// ZIG_GLOBAL_CACHE_DIR at `.zig-cache`.
pub fn holdsGlobalCache(io: Io, cache_dir: Io.Dir) bool {
    for ([_][]const u8{ "p", "b" }) |name| {
        var d = cache_dir.openDir(io, name, .{}) catch continue;
        d.close(io);
        return true;
    }
    return false;
}

/// Prunes the cache at `cache_dir` (a `.zig-cache`) and the caches nested
/// in it (`spider dev` builds in `.zig-cache/dev`). Errors on single
/// entries are skipped: pruning never fails a build.
pub fn prune(io: Io, alc: std.mem.Allocator, cache_dir: Io.Dir, opts: Options) Result {
    var result = pruneOne(io, alc, cache_dir, opts);
    var it = cache_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (isCacheSubdir(entry.name)) continue;
        var nested = cache_dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer nested.close(io);
        var o = nested.openDir(io, "o", .{}) catch continue;
        o.close(io);
        result.add(pruneOne(io, alc, nested, opts));
    }
    return result;
}

fn isCacheSubdir(name: []const u8) bool {
    for ([_][]const u8{ "o", "h", "z", "c", "tmp" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn pruneOne(io: Io, alc: std.mem.Allocator, cache_dir: Io.Dir, opts: Options) Result {
    var arena_state = std.heap.ArenaAllocator.init(alc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now = (opts.now orelse Io.Clock.now(.real, io)).nanoseconds;
    var result: Result = .{};

    var o = cache_dir.openDir(io, "o", .{ .iterate = true }) catch return result;
    defer o.close(io);

    // Every big file of every output directory.
    var artifacts: std.ArrayList(Artifact) = .empty;
    var sizes: std.StringHashMapUnmanaged(u64) = .empty;
    var young: std.StringHashMapUnmanaged(void) = .empty;
    var it = o.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dir_name = a.dupe(u8, entry.name) catch return result;
        var d = o.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var total: u64 = 0;
        var files = d.iterate();
        while (files.next(io) catch null) |f| {
            if (f.kind != .file) continue;
            const st = d.statFile(io, f.name, .{}) catch continue;
            total += st.size;
            if (now - st.mtime.nanoseconds < opts.min_age_ns) young.put(a, dir_name, {}) catch {};
            if (st.size < opts.min_artifact_bytes) continue;
            if (!isProgram(f.name, st.permissions)) continue;
            artifacts.append(a, .{
                .dir = dir_name,
                .name = a.dupe(u8, f.name) catch continue,
                .size = st.size,
                .mtime = st.mtime.nanoseconds,
            }) catch continue;
        }
        sizes.put(a, dir_name, total) catch {};
    }

    // An output goes when `keep` newer copies of the same binary exist:
    // same name, size within same_binary_size_ratio. Only the newest output
    // of each build step is ever used again (Zig keeps one manifest per
    // step), and it must never go: when in doubt, it stays.
    var kept: std.StringHashMapUnmanaged(void) = .empty;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    for (artifacts.items) |art| {
        var newer: usize = 0;
        for (artifacts.items) |other| {
            if (other.mtime > art.mtime and sameBinary(art, other)) newer += 1;
        }
        if (newer >= opts.keep) candidates.put(a, art.dir, {}) catch {} else kept.put(a, art.dir, {}) catch {};
    }

    // A directory goes when it holds only old copies.
    var cit = candidates.keyIterator();
    while (cit.next()) |dir_name| {
        if (kept.contains(dir_name.*) or young.contains(dir_name.*)) continue;
        o.deleteTree(io, dir_name.*) catch continue;
        result.removed += 1;
        result.freed_bytes += sizes.get(dir_name.*) orelse 0;
    }

    dropDanglingManifests(io, a, cache_dir, o);

    // Leftovers of interrupted builds.
    var tmp = cache_dir.openDir(io, "tmp", .{ .iterate = true }) catch return result;
    defer tmp.close(io);
    var tit = tmp.iterate();
    while (tit.next(io) catch null) |entry| {
        const st = tmp.statFile(io, entry.name, .{}) catch continue;
        if (now - st.mtime.nanoseconds < opts.min_age_ns) continue;
        tmp.deleteTree(io, entry.name) catch continue;
        result.removed += 1;
        result.freed_bytes += st.size;
    }
    return result;
}

/// Zig's manifests (`h/`) list the files a cached step read, outputs of
/// other steps among them (`o/<hash>/test`, the binary a test run ran).
/// Zig fails such a step ("checking cache failed: FileNotFound") instead
/// of running it again when one of those files is gone, so a manifest that
/// names a removed output directory is removed too: the step is then not
/// cached, and runs.
fn dropDanglingManifests(io: Io, a: std.mem.Allocator, cache_dir: Io.Dir, o: Io.Dir) void {
    var h = cache_dir.openDir(io, "h", .{ .iterate = true }) catch return;
    defer h.close(io);
    var it = h.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const data = h.readFileAlloc(io, entry.name, a, .limited(16 * 1024 * 1024)) catch continue;
        defer a.free(data);
        if (namesMissingOutput(io, o, data)) h.deleteFile(io, entry.name) catch {};
    }
}

/// Whether `manifest` names `o/<32 hex digits>/...` of a directory that is
/// not in `o`.
fn namesMissingOutput(io: Io, o: Io.Dir, manifest: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, manifest, at, "o/")) |i| {
        at = i + 2;
        if (i > 0 and std.ascii.isAlphanumeric(manifest[i - 1])) continue;
        if (manifest.len < i + 2 + 32 + 1) continue;
        const name = manifest[i + 2 .. i + 2 + 32];
        if (manifest[i + 2 + 32] != '/') continue;
        const hex = for (name) |ch| {
            if (!std.ascii.isHex(ch)) break false;
        } else true;
        if (!hex) continue;
        var d = o.openDir(io, name, .{}) catch return true;
        d.close(io);
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "prune: a manifest naming a removed output goes with it; the others stay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    const old_dir = "0123456789abcdef0123456789abcdef";
    const new_dir = "fedcba9876543210fedcba9876543210";
    for ([_][]const u8{ "o/" ++ old_dir, "o/" ++ new_dir, "h" }) |p| try d.createDirPath(io, p);
    const big = "0123456789abcdef";
    try writeAged(io, d, "o/" ++ old_dir ++ "/test", big, 1000);
    try writeAged(io, d, "o/" ++ new_dir ++ "/test", big, 2000);
    try d.writeFile(io, .{ .sub_path = "h/runs_old", .data = "\x01\x02o/" ++ old_dir ++ "/test\x00" });
    try d.writeFile(io, .{ .sub_path = "h/runs_new", .data = "\x01\x02o/" ++ new_dir ++ "/test\x00" });
    try d.writeFile(io, .{ .sub_path = "h/sources", .data = "src/main.zig\x00foo/o/bar" });
    _ = prune(io, std.testing.allocator, d, .{ .keep = 1, .min_artifact_bytes = 10, .now = .fromNanoseconds(10_000 * std.time.ns_per_s) });
    try std.testing.expect(!exists(io, d, "o/" ++ old_dir));
    try std.testing.expect(!exists(io, d, "h/runs_old"));
    try std.testing.expect(exists(io, d, "h/runs_new"));
    try std.testing.expect(exists(io, d, "h/sources"));
}

/// Writes `data` at `path` with that modification time; a name with no
/// extension is made executable, as Zig leaves its programs.
fn writeAged(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, mtime_s: i96) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
    const f = try dir.openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    if (std.mem.indexOfScalar(u8, std.fs.path.basename(path), '.') == null)
        try f.setPermissions(io, .executable_file);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(mtime_s * std.time.ns_per_s) } });
}

fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch return false;
    return true;
}

test "prune: the newest copies of each binary stay, older ones and tmp leftovers go" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    const big = "0123456789abcdef"; // over min_artifact_bytes below
    // Three builds of `app` and two of `test`; a directory with only small files.
    for ([_][]const u8{ "o/a1", "o/a2", "o/a3", "o/t1", "o/t2", "o/small", "tmp", "dev/o/d1", "dev/o/d2" }) |p| try d.createDirPath(io, p);
    try writeAged(io, d, "o/a1/app", big, 1000);
    try writeAged(io, d, "o/a2/app", big, 2000);
    try writeAged(io, d, "o/a3/app", big, 3000);
    try writeAged(io, d, "o/t1/test", big, 1500);
    try writeAged(io, d, "o/t2/test", big, 2500);
    try writeAged(io, d, "o/small/x.zig", "x", 100);
    try writeAged(io, d, "tmp/old", "x", 100);
    try writeAged(io, d, "dev/o/d1/app", big, 1000);
    try writeAged(io, d, "dev/o/d2/app", big, 2000);

    const r = prune(io, std.testing.allocator, d, .{
        .keep = 1,
        .min_artifact_bytes = 10,
        .now = .fromNanoseconds(10_000 * std.time.ns_per_s),
    });
    try std.testing.expect(exists(io, d, "o/a3/app"));
    try std.testing.expect(!exists(io, d, "o/a2/app"));
    try std.testing.expect(!exists(io, d, "o/a1/app"));
    try std.testing.expect(exists(io, d, "o/t2/test"));
    try std.testing.expect(!exists(io, d, "o/t1/test"));
    try std.testing.expect(exists(io, d, "o/small/x.zig"));
    try std.testing.expect(!exists(io, d, "tmp/old"));
    try std.testing.expect(exists(io, d, "dev/o/d2/app"));
    try std.testing.expect(!exists(io, d, "dev/o/d1/app"));
    try std.testing.expectEqual(@as(usize, 5), r.removed);
    try std.testing.expect(r.freed_bytes >= 4 * big.len);
}

test "prune: test binaries of different suites are kept apart by size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    for ([_][]const u8{ "o/u1", "o/u2", "o/q1", "o/q2" }) |p| try d.createDirPath(io, p);
    const unit: [1000]u8 = @splat('u');
    const unit2: [1002]u8 = @splat('u'); // the same suite after an edit
    const qr: [300]u8 = @splat('q'); // another suite, also called `test`
    try writeAged(io, d, "o/u1/test", &unit, 1000);
    try writeAged(io, d, "o/u2/test", &unit2, 3000);
    try writeAged(io, d, "o/q1/test", &qr, 2000);
    try writeAged(io, d, "o/q2/test", &qr, 500);
    _ = prune(io, std.testing.allocator, d, .{ .keep = 1, .min_artifact_bytes = 10, .now = .fromNanoseconds(10_000 * std.time.ns_per_s) });
    // The newest of each suite stays, even though q1 is older than u2.
    try std.testing.expect(exists(io, d, "o/u2/test"));
    try std.testing.expect(exists(io, d, "o/q1/test"));
    try std.testing.expect(!exists(io, d, "o/u1/test"));
    try std.testing.expect(!exists(io, d, "o/q2/test"));
}

test "prune: when two suites are close in size, each keeps its newest output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    for ([_][]const u8{ "o/a1", "o/b1" }) |p| try d.createDirPath(io, p);
    const a1: [1000]u8 = @splat('a');
    const b1: [1010]u8 = @splat('b'); // 1% bigger: another binary
    try writeAged(io, d, "o/a1/test", &a1, 1000);
    try writeAged(io, d, "o/b1/test", &b1, 2000);
    _ = prune(io, std.testing.allocator, d, .{ .keep = 1, .min_artifact_bytes = 10, .now = .fromNanoseconds(10_000 * std.time.ns_per_s) });
    try std.testing.expect(exists(io, d, "o/a1/test"));
    try std.testing.expect(exists(io, d, "o/b1/test"));
}

test "prune: keep = 2 by default, and a recent output is never removed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    const big = "0123456789abcdef";
    for ([_][]const u8{ "o/a1", "o/a2", "o/a3" }) |p| try d.createDirPath(io, p);
    try writeAged(io, d, "o/a1/app", big, 9_990);
    try writeAged(io, d, "o/a2/app", big, 9_995);
    try writeAged(io, d, "o/a3/app", big, 9_999);
    // a1 is the third newest, but 10 seconds old: younger than two minutes.
    _ = prune(io, std.testing.allocator, d, .{ .min_artifact_bytes = 10, .now = .fromNanoseconds(10_000 * std.time.ns_per_s) });
    try std.testing.expect(exists(io, d, "o/a1/app"));
    // An hour later it goes; the two newest stay.
    _ = prune(io, std.testing.allocator, d, .{ .min_artifact_bytes = 10, .now = .fromNanoseconds(13_600 * std.time.ns_per_s) });
    try std.testing.expect(!exists(io, d, "o/a1/app"));
    try std.testing.expect(exists(io, d, "o/a2/app"));
    try std.testing.expect(exists(io, d, "o/a3/app"));
}

test "prune: a directory without o/ is left alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "notes");
    const r = prune(io, std.testing.allocator, tmp.dir, .{});
    try std.testing.expectEqual(@as(usize, 0), r.removed);
    try std.testing.expect(exists(io, tmp.dir, "notes"));
}

test "prune: libraries are never removed, even with newer copies of the same name and size" {
    // compiler_rt of two builds (another target or mode): the same name,
    // sizes 0.35% apart, each the current one of its build. CI keeps Zig's
    // global cache in .zig-cache; removing one failed the next build with
    // "failed to parse archive: FileNotFound".
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const d = tmp.dir;
    for ([_][]const u8{ "o/r1", "o/r2", "o/r3", "o/p1" }) |p| try d.createDirPath(io, p);
    const big = "0123456789abcdef";
    try writeAged(io, d, "o/r1/libcompiler_rt.a", big, 1000);
    try writeAged(io, d, "o/r2/libcompiler_rt.a", big, 2000);
    try writeAged(io, d, "o/r3/libcompiler_rt.a", big, 3000);
    // A file without an extension that is not executable is not a program.
    try d.writeFile(io, .{ .sub_path = "o/p1/data", .data = big });
    _ = prune(io, std.testing.allocator, d, .{ .keep = 1, .min_artifact_bytes = 10, .now = .fromNanoseconds(10_000 * std.time.ns_per_s) });
    for ([_][]const u8{ "o/r1/libcompiler_rt.a", "o/r2/libcompiler_rt.a", "o/r3/libcompiler_rt.a", "o/p1/data" }) |p|
        try std.testing.expect(exists(io, d, p));
}

test "holdsGlobalCache: a project cache does not; one with Zig's global p/ or b/ does" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "o", "h", "z", "tmp" }) |p| try tmp.dir.createDirPath(io, p);
    try std.testing.expect(!holdsGlobalCache(io, tmp.dir));
    try tmp.dir.createDirPath(io, "p");
    try std.testing.expect(holdsGlobalCache(io, tmp.dir));
}

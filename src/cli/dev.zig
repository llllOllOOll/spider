//! `spider dev`: build the app, run it, and replace it after every build
//! that succeeds.
//!
//! It supervises two child processes:
//!
//!   * the build: `zig build dev --watch` (incremental where Zig supports
//!     it). Zig watches the sources itself. The app's `dev` build step ends
//!     with `spider-dev-notify`, which writes where the new binary is to the
//!     file named by SPIDER_DEV_BUILT;
//!   * the app: a COPY of that binary. Never the binary itself — the
//!     incremental linker rewrites it in place, a running executable cannot
//!     be written to (`error: FileBusy`), and after that error the watch
//!     build stops rebuilding.
//!
//! A build that fails writes nothing, so the app that is running keeps
//! running; the compiler's errors go to the terminal.
//!
//! The app is started with SPIDER_DEV set. A Debug build of Spider then adds
//! a script to its HTML pages that reloads the browser when the process it
//! was talking to has been replaced (src/modules/dev_reload.zig).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const fs_utils = @import("fs_utils.zig");

/// The variable the build's notify tool reads (src/dev_notify_tool.zig).
pub const built_env = "SPIDER_DEV_BUILT";

/// Set for the app: turns on the browser reload in the server
/// (src/modules/dev_reload.zig; Debug builds only).
pub const app_env = "SPIDER_DEV";

/// Everything `spider dev` writes, inside the project's build cache.
const state_dir = ".zig-cache/spider-dev";
const built_file = state_dir ++ "/built";
const lock_file = state_dir ++ "/pid";

pub const Options = struct {
    /// The build command, run in the project root. Null: `zig build dev
    /// --watch`, plus `-fincremental` where Zig supports it.
    build_argv: ?[]const []const u8 = null,
    /// Set from outside (a signal, a test) to make the supervisor stop.
    stop: ?*std.atomic.Value(bool) = null,
    /// No progress lines (tests).
    quiet: bool = false,
    poll_ms: u32 = 30,
    /// How long a process gets to exit after being asked to, before it is
    /// killed.
    grace_ms: u32 = 2000,
};

pub const Summary = struct {
    /// How many times an app process was started.
    starts: u32 = 0,
};

/// Incremental compilation is only supported by Zig 0.17 on x86_64 Linux.
pub const incremental_supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;

const default_build_argv: []const []const u8 = if (incremental_supported)
    &.{ "zig", "build", "dev", "--watch", "-fincremental" }
else
    &.{ "zig", "build", "dev", "--watch" };

var signal_stop: std.atomic.Value(bool) = .init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    signal_stop.store(true, .release);
}

/// The command: supervises the project in the current directory until the
/// build exits or the user interrupts it.
pub fn run(io: Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) anyerror!void {
    if (builtin.os.tag == .windows) {
        std.debug.print("error: `spider dev` does not run on Windows yet\n", .{});
        return error.Unsupported;
    }
    const root = fs_utils.findProjectRoot(io) catch {
        std.debug.print("error: no build.zig.zon here or above: run `spider dev` inside a project\n", .{});
        return error.NotAProjectRoot;
    };

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);

    _ = try supervise(io, gpa, root, environ, .{ .stop = &signal_stop });
}

/// One child process and the task waiting for it to exit.
const Proc = struct {
    child: std.process.Child,
    pid: std.posix.pid_t,
    exited: std.atomic.Value(bool) = .init(false),
    term: std.process.Child.Term = .{ .unknown = 0 },
    waiter: Io.Future(void) = undefined,

    fn start(io: Io, gpa: std.mem.Allocator, options: std.process.SpawnOptions) !*Proc {
        const proc = try gpa.create(Proc);
        errdefer gpa.destroy(proc);
        proc.* = .{ .child = try std.process.spawn(io, options), .pid = undefined };
        proc.pid = proc.child.id.?;
        proc.waiter = io.concurrent(waitFor, .{ io, proc }) catch |err| {
            proc.child.kill(io);
            return err;
        };
        return proc;
    }

    fn waitFor(io: Io, proc: *Proc) void {
        proc.term = proc.child.wait(io) catch .{ .unknown = 0 };
        proc.exited.store(true, .release);
    }

    fn hasExited(proc: *const Proc) bool {
        return proc.exited.load(.acquire);
    }

    /// Asks the process to exit, kills it if it does not within `grace_ms`,
    /// and frees it. Returns once the process is gone.
    fn stop(proc: *Proc, io: Io, gpa: std.mem.Allocator, grace_ms: u32) void {
        if (!proc.hasExited()) {
            std.posix.kill(proc.pid, .TERM) catch {};
            var waited: u32 = 0;
            while (!proc.hasExited() and waited < grace_ms) : (waited += 10) {
                Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            }
            if (!proc.hasExited()) std.posix.kill(proc.pid, .KILL) catch {};
        }
        proc.waiter.await(io);
        gpa.destroy(proc);
    }
};

/// What a binary is, to tell a new build from the same one reported
/// again. A hash of the contents: the incremental linker rewrites the file
/// through a memory mapping, which changes neither its size nor its
/// modification time.
const BinaryStamp = struct {
    size: u64,
    hash: u64,

    fn of(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, path: []const u8) ?BinaryStamp {
        const file = dir.openFile(io, path, .{}) catch return null;
        defer file.close(io);
        const buf = gpa.alloc(u8, 1024 * 1024) catch return null;
        defer gpa.free(buf);
        var reader = file.reader(io, &.{});
        var hasher: std.hash.XxHash3 = .init(0);
        var size: u64 = 0;
        while (true) {
            const n = reader.interface.readSliceShort(buf) catch return null;
            if (n == 0) break;
            hasher.update(buf[0..n]);
            size += n;
        }
        return .{ .size = size, .hash = hasher.final() };
    }

    fn eql(a: BinaryStamp, b: ?BinaryStamp) bool {
        const other = b orelse return false;
        return a.size == other.size and a.hash == other.hash;
    }
};

/// What the notify tool wrote: the executable's path and, after it, a
/// stamp that changes on every build.
pub fn builtExecutable(content: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, content, '\n') orelse return null;
    const path = std.mem.trim(u8, content[0..end], " \r\t");
    return if (path.len == 0) null else path;
}

fn say(opts: Options, comptime fmt: []const u8, args: anytype) void {
    if (opts.quiet) return;
    std.debug.print("[spider dev] " ++ fmt ++ "\n", args);
}

fn stopRequested(opts: Options) bool {
    return if (opts.stop) |flag| flag.load(.acquire) else false;
}

fn currentPid() std.posix.pid_t {
    return if (builtin.os.tag == .linux) std.os.linux.getpid() else std.c.getpid();
}

/// Refuses to start when another `spider dev` is alive in this project:
/// two incremental builds on one cache crash each other.
fn takeLock(io: Io, gpa: std.mem.Allocator, root: Io.Dir, opts: Options) !void {
    if (root.readFileAlloc(io, lock_file, gpa, .limited(64))) |text| {
        defer gpa.free(text);
        const other = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \r\n\t"), 10) catch 0;
        if (other > 0 and other != currentPid()) {
            // Signal 0: nothing is sent, the call only says if the pid exists.
            if (std.posix.kill(other, @fromBackingInt(@intCast(0)))) |_| {
                if (!opts.quiet) std.debug.print("error: `spider dev` is already running in this project (pid {d})\n", .{other});
                return error.AlreadyRunning;
            } else |_| {}
        }
    } else |_| {}
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch unreachable;
    try fs_utils.writeFile(io, root, lock_file, text);
}

/// Runs the build and the app in `root` until the build exits or
/// `opts.stop` is set. Both processes are gone when it returns.
pub fn supervise(
    io: Io,
    gpa: std.mem.Allocator,
    root: Io.Dir,
    environ: *const std.process.Environ.Map,
    opts: Options,
) !Summary {
    try root.createDirPath(io, state_dir);
    try takeLock(io, gpa, root, opts);
    defer root.deleteFile(io, lock_file) catch {};

    // A notice left by an earlier run names a binary that may be gone.
    root.deleteFile(io, built_file) catch {};

    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..try root.realPath(io, &root_buf)];
    const built_path = try std.fs.path.join(gpa, &.{ root_path, built_file });
    defer gpa.free(built_path);

    var build_env = try environ.clone(gpa);
    defer build_env.deinit();
    try build_env.put(built_env, built_path);

    var app_environ = try environ.clone(gpa);
    defer app_environ.deinit();
    try app_environ.put(app_env, "1");

    const build_argv = opts.build_argv orelse default_build_argv;
    say(opts, "building ({s})", .{if (opts.build_argv == null and incremental_supported) "incremental" else "watch"});
    const build = Proc.start(io, gpa, .{
        .argv = build_argv,
        .cwd = .{ .dir = root },
        .environ_map = &build_env,
    }) catch |err| {
        std.debug.print("error: could not start `{s}`: {s}\n", .{ build_argv[0], @errorName(err) });
        return err;
    };
    defer build.stop(io, gpa, opts.grace_ms);

    var summary: Summary = .{};
    var app: ?*Proc = null;
    defer if (app) |proc| proc.stop(io, gpa, opts.grace_ms);
    var app_exit_reported = false;
    // The notice the running app was started from.
    var seen: []u8 = try gpa.dupe(u8, "");
    defer gpa.free(seen);
    // What the running app was copied from. The build can report the same
    // binary more than once (an editor's save is often two file events, so
    // two builds): that is not a new build.
    var running_from: ?BinaryStamp = null;
    // The copy the running app executes; deleted when the next one starts.
    var running_copy: ?[]u8 = null;
    defer if (running_copy) |path| {
        root.deleteFile(io, path) catch {};
        gpa.free(path);
    };

    while (!stopRequested(opts)) {
        if (build.hasExited()) {
            say(opts, "the build process ended ({f})", .{build.term});
            break;
        }

        const notice: ?[]u8 = root.readFileAlloc(io, built_file, gpa, .limited(Io.Dir.max_path_bytes + 64)) catch null;
        if (notice) |content| fresh: {
            if (std.mem.eql(u8, content, seen)) {
                gpa.free(content);
                break :fresh;
            }
            gpa.free(seen);
            seen = content;
            const exe = builtExecutable(content) orelse break :fresh;
            const stamp = BinaryStamp.of(io, gpa, root, exe) orelse {
                say(opts, "the build reported {s}, which is not there", .{exe});
                break :fresh;
            };
            if (app) |proc| {
                if (!proc.hasExited() and stamp.eql(running_from)) break :fresh;
            }

            if (app) |proc| {
                proc.stop(io, gpa, opts.grace_ms);
                app = null;
            }
            const copy = try std.fmt.allocPrint(gpa, "{s}/app-{d}", .{ state_dir, summary.starts + 1 });
            errdefer gpa.free(copy);
            root.copyFile(exe, root, copy, io, .{}) catch |err| {
                say(opts, "could not copy {s}: {s}", .{ exe, @errorName(err) });
                gpa.free(copy);
                break :fresh;
            };
            if (running_copy) |old| {
                root.deleteFile(io, old) catch {};
                gpa.free(old);
            }
            running_copy = copy;
            running_from = stamp;

            const copy_abs = try std.fs.path.join(gpa, &.{ root_path, copy });
            defer gpa.free(copy_abs);
            app = Proc.start(io, gpa, .{
                .argv = &.{copy_abs},
                .cwd = .{ .dir = root },
                .environ_map = &app_environ,
            }) catch |err| {
                say(opts, "could not start the app: {s}", .{@errorName(err)});
                break :fresh;
            };
            summary.starts += 1;
            app_exit_reported = false;
            say(opts, "app started (build {d})", .{summary.starts});
        }

        if (app) |proc| {
            if (proc.hasExited() and !app_exit_reported) {
                app_exit_reported = true;
                say(opts, "the app exited ({f}); waiting for the next build", .{proc.term});
            }
        }

        Io.sleep(io, .fromMilliseconds(opts.poll_ms), .awake) catch break;
    }

    return summary;
}

// ── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "builtExecutable: the first line of the notice" {
    try testing.expectEqualStrings("/p/.zig-cache/o/abc/app", builtExecutable("/p/.zig-cache/o/abc/app\n17\n").?);
    try testing.expectEqual(@as(?[]const u8, null), builtExecutable(""));
    try testing.expectEqual(@as(?[]const u8, null), builtExecutable("no newline yet"));
    try testing.expectEqual(@as(?[]const u8, null), builtExecutable("\n17\n"));
}

/// A project directory with a scripted "build": a shell script that plays
/// the notify tool's part, so the supervisor is tested without compiling
/// anything.
const Fixture = struct {
    tmp: testing.TmpDir,
    env: std.process.Environ.Map,
    stop: std.atomic.Value(bool) = .init(false),
    task: Io.Future(anyerror!Summary) = undefined,
    /// The supervisor task is running and nobody awaited it yet.
    running: bool = false,

    fn init(build_script: []const u8) !*Fixture {
        const io = testing.io;
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .tmp = testing.tmpDir(.{}), .env = try testing.environ.createMap(testing.allocator) };
        try fs_utils.writeFile(io, self.tmp.dir, "build.sh", build_script);
        return self;
    }

    fn start(self: *Fixture) !void {
        self.task = try testing.io.concurrent(superviseForTest, .{self});
        self.running = true;
    }

    fn superviseForTest(self: *Fixture) anyerror!Summary {
        return supervise(testing.io, testing.allocator, self.tmp.dir, &self.env, .{
            .build_argv = &.{ "sh", "build.sh" },
            .stop = &self.stop,
            .quiet = true,
            .poll_ms = 5,
            .grace_ms = 1000,
        });
    }

    /// Waits until `path` holds exactly `expected` (the scripted apps
    /// append a line when they start).
    fn expectFile(self: *Fixture, path: []const u8, expected: []const u8) !void {
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 10) {
            if (self.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(4096))) |text| {
                defer testing.allocator.free(text);
                if (std.mem.eql(u8, text, expected)) return;
            } else |_| {}
            Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
        }
        const got = self.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(4096)) catch try testing.allocator.dupe(u8, "<missing>");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(expected, got);
    }

    fn finish(self: *Fixture) !Summary {
        self.stop.store(true, .release);
        return self.join();
    }

    /// Waits for the supervisor to return by itself.
    fn join(self: *Fixture) !Summary {
        self.running = false;
        return self.task.await(testing.io);
    }

    fn deinit(self: *Fixture) void {
        // A test that failed halfway: stop the processes it left running.
        if (self.running) _ = self.finish() catch {};
        self.env.deinit();
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }
};

/// Shell for a scripted build: `app NAME` writes an executable that logs
/// NAME to runs.log and then stays up (a shell loop, so the process keeps
/// the path it was started from in its command line); `notify NAME` is what
/// the notify tool does.
const script_prelude =
    \\app() { printf '#!/bin/sh\necho %s >> runs.log\necho "dev=$SPIDER_DEV" > app-env\nwhile :; do sleep 0.05; done\n' "$1" > "bin-$1"; chmod +x "bin-$1"; }
    \\notify() { printf '%s\n%s\n' "$PWD/bin-$1" "$2" > "$SPIDER_DEV_BUILT.tmp"; mv "$SPIDER_DEV_BUILT.tmp" "$SPIDER_DEV_BUILT"; }
    \\
;

fn processesRunning(needle: []const u8) !usize {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pgrep", "-f", needle } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return std.mem.count(u8, result.stdout, "\n");
}

test "supervise: starts the app on a build notice and replaces it on the next one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\app two; notify two 2
        \\exec sleep 30
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "one\n");
    // The app is told it runs under `spider dev`.
    try fx.expectFile("app-env", "dev=1\n");
    // The app runs from a copy, not from the file the build wrote.
    try fx.tmp.dir.access(testing.io, state_dir ++ "/app-1", .{});

    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    try fx.expectFile("runs.log", "one\ntwo\n");

    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 2), summary.starts);

    // Nothing is left behind: no app, no build, no copies, no lock.
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try fx.tmp.dir.realPath(testing.io, &path_buf)];
    try testing.expectEqual(@as(usize, 0), try processesRunning(dir_path));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(testing.io, state_dir ++ "/app-1", .{}));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(testing.io, state_dir ++ "/app-2", .{}));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(testing.io, lock_file, .{}));
}

test "supervise: the same binary reported twice does not restart the app" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\notify one 2
        \\echo again > build-result
        \\exec sleep 30
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "one\n");
    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    try fx.expectFile("build-result", "again\n");
    Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};

    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 1), summary.starts);
    try fx.expectFile("runs.log", "one\n");
}

test "supervise: a new binary at the same path, with the same size, restarts the app" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // What an incremental build does: same file, same size, new contents.
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\app two; cat bin-two > bin-one; notify one 2
        \\exec sleep 30
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "one\n");
    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    try fx.expectFile("runs.log", "one\ntwo\n");

    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 2), summary.starts);
}

test "supervise: a build that fails leaves the running app alone" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // A failed build writes no notice: the second "build" only reports.
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\echo failed > build-result
        \\exec sleep 30
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "one\n");
    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    try fx.expectFile("build-result", "failed\n");
    Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try fx.tmp.dir.realPath(testing.io, &path_buf)];
    const app_copy = try std.fs.path.join(testing.allocator, &.{ dir_path, state_dir, "app-1" });
    defer testing.allocator.free(app_copy);
    try testing.expectEqual(@as(usize, 1), try processesRunning(app_copy));

    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 1), summary.starts);
    try fx.expectFile("runs.log", "one\n");
}

test "supervise: an app that exits by itself is started again by the next build" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(
        \\printf '#!/bin/sh\necho crashed >> runs.log\nexit 3\n' > bin-crash; chmod +x bin-crash
        \\
    ++ script_prelude ++
        \\notify crash 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\app two; notify two 2
        \\exec sleep 30
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "crashed\n");
    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    try fx.expectFile("runs.log", "crashed\ntwo\n");

    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 2), summary.starts);
}

test "supervise: returns when the build process ends" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\while [ ! -f go ]; do sleep 0.02; done
        \\exit 1
        \\
    );
    defer fx.deinit();
    try fx.start();

    try fx.expectFile("runs.log", "one\n");
    try fs_utils.writeFile(testing.io, fx.tmp.dir, "go", "");
    // Not stopped from outside: the supervisor notices the build is gone.
    const summary = try fx.join();
    try testing.expectEqual(@as(u32, 1), summary.starts);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try fx.tmp.dir.realPath(testing.io, &path_buf)];
    try testing.expectEqual(@as(usize, 0), try processesRunning(dir_path));
}

test "supervise: a second one in the same project is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\exec sleep 30
        \\
    );
    defer fx.deinit();

    // A live process that is not this one holds the lock.
    var holder = try std.process.spawn(testing.io, .{ .argv = &.{ "sleep", "30" } });
    defer holder.kill(testing.io);
    var buf: [32]u8 = undefined;
    try fx.tmp.dir.createDirPath(testing.io, state_dir);
    try fs_utils.writeFile(testing.io, fx.tmp.dir, lock_file, try std.fmt.bufPrint(&buf, "{d}\n", .{holder.id.?}));

    try testing.expectError(error.AlreadyRunning, Fixture.superviseForTest(fx));
    // The other one's lock is not removed.
    try fx.tmp.dir.access(testing.io, lock_file, .{});
}

test "supervise: a lock left by a dead process is taken over" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fx = try Fixture.init(script_prelude ++
        \\app one; notify one 1
        \\exec sleep 30
        \\
    );
    defer fx.deinit();

    var dead = try std.process.spawn(testing.io, .{ .argv = &.{"true"} });
    const dead_pid = dead.id.?;
    _ = try dead.wait(testing.io);
    var buf: [32]u8 = undefined;
    try fx.tmp.dir.createDirPath(testing.io, state_dir);
    try fs_utils.writeFile(testing.io, fx.tmp.dir, lock_file, try std.fmt.bufPrint(&buf, "{d}\n", .{dead_pid}));

    try fx.start();
    try fx.expectFile("runs.log", "one\n");
    const summary = try fx.finish();
    try testing.expectEqual(@as(u32, 1), summary.starts);
}

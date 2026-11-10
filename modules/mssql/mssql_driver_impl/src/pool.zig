//! A fixed set of connections shared by many threads: `acquire` hands one
//! out (waiting while all are in use), `release` gives it back. A connection
//! that broke, or that was given back with a transaction still open, is
//! closed or rolled back there, and a closed one is opened again by the next
//! `acquire`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const Options = conn_mod.Options;
const CaBundle = conn_mod.CaBundle;

const log = std.log.scoped(.mssql);

pub const Pool = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    /// Copies of the strings in `opts`, owned by the pool.
    strings: std.heap.ArenaAllocator,
    ca: CaBundle = .{},
    /// The idle connections are `idle[0..available]`; a null one was closed
    /// and is opened again when it is handed out.
    idle: []?*Conn,
    available: usize,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    /// Opens `size` connections with `opts` (its strings are copied). Fails
    /// with the first connection's error, after closing the others.
    pub fn init(gpa: Allocator, io: Io, opts: Options, size: usize) !*Pool {
        if (size == 0) return error.InvalidPoolSize;
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .strings = .init(gpa),
            .idle = try gpa.alloc(?*Conn, size),
            .available = 0,
        };
        errdefer self.strings.deinit();
        errdefer gpa.free(self.idle);

        const a = self.strings.allocator();
        self.opts.host = try a.dupe(u8, opts.host);
        self.opts.user = try a.dupe(u8, opts.user);
        self.opts.password = try a.dupe(u8, opts.password);
        self.opts.database = try a.dupe(u8, opts.database);
        self.opts.app_name = try a.dupe(u8, opts.app_name);
        self.opts.workstation = try a.dupe(u8, opts.workstation);
        if (opts.certificate_host) |h| self.opts.certificate_host = try a.dupe(u8, h);

        if (!opts.trust_server_certificate and opts.encrypt == .on and opts.ca == null) {
            try self.ca.load(gpa, io);
            self.opts.ca = &self.ca;
        }
        errdefer self.ca.deinit(gpa);

        errdefer for (self.idle[0..self.available]) |c| if (c) |x| x.close();
        for (self.idle) |*slot| {
            slot.* = try Conn.connect(gpa, io, self.opts);
            self.available += 1;
        }
        return self;
    }

    /// Closes every connection. None may be in use.
    pub fn deinit(self: *Pool) void {
        for (self.idle[0..self.available]) |c| if (c) |x| x.close();
        const gpa = self.gpa;
        gpa.free(self.idle);
        self.ca.deinit(gpa);
        self.strings.deinit();
        gpa.destroy(self);
    }

    /// An idle connection, waiting for one when all are in use. A connection
    /// closed after it broke is opened again here; when that fails, its
    /// error is returned and the slot stays free for the next call.
    pub fn acquire(self: *Pool) !*Conn {
        try self.mutex.lock(self.io);
        while (self.available == 0) self.cond.waitUncancelable(self.io, &self.mutex);
        self.available -= 1;
        const slot = self.idle[self.available];
        self.mutex.unlock(self.io);

        if (slot) |c| return c;
        return Conn.connect(self.gpa, self.io, self.opts) catch |err| {
            self.put(null);
            return err;
        };
    }

    /// Gives `conn` back. A broken connection is closed; one with a
    /// transaction still open is rolled back first (and closed when even
    /// that fails), so the next user starts clean.
    pub fn release(self: *Pool, conn: *Conn) void {
        var keep: ?*Conn = conn;
        if (conn.broken or conn.busy) {
            keep = null;
        } else if (conn.inTransaction()) {
            _ = conn.exec("IF @@TRANCOUNT > 0 ROLLBACK") catch {
                keep = null;
            };
            if (keep != null and conn.inTransaction()) keep = null;
        }
        if (keep == null) {
            log.debug("closing a pooled connection (broken or stuck in a transaction)", .{});
            conn.close();
        }
        self.put(keep);
    }

    fn put(self: *Pool, conn: ?*Conn) void {
        self.mutex.lockUncancelable(self.io);
        self.idle[self.available] = conn;
        self.available += 1;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }
};

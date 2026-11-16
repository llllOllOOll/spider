//! TDS 7.x tunnels the TLS handshake inside PRELOGIN packets: every flight of
//! the handshake travels as the payload of TDS packets of its own. Once the
//! handshake is over, TLS records go down the socket bare, with whole TDS
//! packets riding inside the session.
//!
//! `TlsShim` sits between `std.crypto.tls.Client` and the socket: while
//! `handshaking`, it wraps outgoing bytes in PRELOGIN packets and strips the
//! packet headers from incoming ones; afterwards it passes bytes through.
//!
//! Adapted from basalt (github.com/leonardomb1/basalt, src/db/sqlserver/tds.zig,
//! MIT License, Copyright (c) 2026 Leonardo Machado Baptista) to Zig 0.17.

const std = @import("std");
const Io = std.Io;

const pkt_prelogin: u8 = 0x12;
const status_eom: u8 = 0x01;
/// Payload of one handshake packet; the server's default packet is 4096 bytes.
const max_payload: usize = 4096 - 8;

pub const buf_len = std.crypto.tls.Client.min_buffer_len;

pub const TlsShim = struct {
    inner_r: *Io.Reader,
    inner_w: *Io.Writer,
    handshaking: bool = true,
    /// Bytes left in the PRELOGIN packet being read, while handshaking.
    remaining: usize = 0,
    reader: Io.Reader,
    writer: Io.Writer,
    rbuf: [buf_len]u8 = undefined,
    wbuf: [buf_len]u8 = undefined,

    const reader_vtable = Io.Reader.VTable{ .stream = readStream };
    const writer_vtable = Io.Writer.VTable{ .drain = drain };

    /// Must be called once the shim sits at its final address.
    pub fn init(self: *TlsShim, inner_r: *Io.Reader, inner_w: *Io.Writer) void {
        self.* = .{ .inner_r = inner_r, .inner_w = inner_w, .reader = undefined, .writer = undefined };
        self.reader = .{ .vtable = &reader_vtable, .buffer = &self.rbuf, .seek = 0, .end = 0 };
        self.writer = .{ .vtable = &writer_vtable, .buffer = &self.wbuf };
    }

    fn readStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *TlsShim = @alignCast(@fieldParentPtr("reader", r));
        if (self.handshaking) {
            while (self.remaining == 0) {
                const hdr = self.inner_r.peek(8) catch |e| switch (e) {
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.ReadFailed,
                };
                const len: usize = std.mem.readInt(u16, hdr[2..4], .big);
                if (len < 8) return error.ReadFailed;
                self.inner_r.toss(8);
                self.remaining = len - 8;
            }
        }
        if (self.inner_r.buffered().len == 0) {
            _ = self.inner_r.peek(1) catch |e| switch (e) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };
        }
        const avail = self.inner_r.buffered();
        var cap = limit.minInt(avail.len);
        if (self.handshaking) cap = @min(cap, self.remaining);
        const n = try w.write(avail[0..cap]);
        self.inner_r.toss(n);
        if (self.handshaking) self.remaining -= n;
        return n;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *TlsShim = @alignCast(@fieldParentPtr("writer", w));
        _ = try self.put(w.buffered());
        w.end = 0;
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |d| total += try self.put(d);
        const last = data[data.len - 1];
        for (0..splat) |_| total += try self.put(last);
        if (self.handshaking) self.inner_w.flush() catch return error.WriteFailed;
        return total;
    }

    fn put(self: *TlsShim, bytes: []const u8) Io.Writer.Error!usize {
        if (bytes.len == 0) return 0;
        if (!self.handshaking) {
            self.inner_w.writeAll(bytes) catch return error.WriteFailed;
            return bytes.len;
        }
        var off: usize = 0;
        while (off < bytes.len) {
            const chunk = @min(bytes.len - off, max_payload);
            const last = off + chunk == bytes.len;
            var header: [8]u8 = .{ pkt_prelogin, if (last) status_eom else 0, 0, 0, 0, 0, 0, 0 };
            std.mem.writeInt(u16, header[2..4], @intCast(chunk + 8), .big);
            self.inner_w.writeAll(&header) catch return error.WriteFailed;
            self.inner_w.writeAll(bytes[off..][0..chunk]) catch return error.WriteFailed;
            off += chunk;
        }
        return bytes.len;
    }
};

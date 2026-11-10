//! SQL Server values as Zig sees them, and the decoders that turn the bytes of a
//! TDS cell into one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Date = struct { year: i32, month: u8, day: u8 };

/// Time of day; `nanos` is the fraction of the second.
pub const Time = struct { hour: u8, minute: u8, second: u8, nanos: u32 };

pub const DateTime = struct { date: Date, time: Time };

/// Local date and time, plus the offset from UTC it was written with.
pub const DateTimeOffset = struct { date: Date, time: Time, offset_minutes: i16 };

/// `value / 10^scale`. Holds every DECIMAL(38, s) and MONEY.
pub const Decimal = struct {
    value: i128,
    scale: u8,

    pub fn format(d: Decimal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const neg = d.value < 0;
        const mag: u128 = @abs(d.value);
        const pow = std.math.powi(u128, 10, d.scale) catch unreachable;
        if (neg) try w.writeByte('-');
        try w.print("{d}", .{mag / pow});
        if (d.scale > 0) {
            var buf: [40]u8 = undefined;
            const frac = std.fmt.bufPrint(&buf, "{d}", .{mag % pow}) catch unreachable;
            try w.writeByte('.');
            for (0..d.scale - frac.len) |_| try w.writeByte('0');
            try w.writeAll(frac);
        }
    }

    pub fn toFloat(d: Decimal) f64 {
        return @as(f64, @floatFromInt(d.value)) / std.math.pow(f64, 10, @floatFromInt(d.scale));
    }
};

/// One cell. Slices (`string`, `bytes`) live in the row's arena: they are valid
/// until the next call to `Rows.next`.
pub const Value = union(enum) {
    null,
    boolean: bool,
    int: i64,
    float: f64,
    decimal: Decimal,
    /// UTF-8, whatever the column's type or collation.
    string: []const u8,
    bytes: []const u8,
    /// In canonical order, the one `{8-4-4-4-12}` prints.
    guid: [16]u8,
    date: Date,
    time: Time,
    datetime: DateTime,
    datetimeoffset: DateTimeOffset,

    pub fn isNull(v: Value) bool {
        return v == .null;
    }

    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .null => try w.writeAll("NULL"),
            .boolean => |b| try w.writeAll(if (b) "1" else "0"),
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("{d}", .{f}),
            .decimal => |d| try d.format(w),
            .string => |s| try w.writeAll(s),
            .bytes => |b| {
                try w.writeAll("0x");
                for (b) |c| try w.print("{X:0>2}", .{c});
            },
            .guid => |g| {
                for (g, 0..) |c, i| {
                    if (i == 4 or i == 6 or i == 8 or i == 10) try w.writeByte('-');
                    try w.print("{X:0>2}", .{c});
                }
            },
            .date => |d| try writeDate(w, d),
            .time => |t| try writeTime(w, t),
            .datetime => |dt| {
                try writeDate(w, dt.date);
                try w.writeByte(' ');
                try writeTime(w, dt.time);
            },
            .datetimeoffset => |dt| {
                try writeDate(w, dt.date);
                try w.writeByte(' ');
                try writeTime(w, dt.time);
                const off = dt.offset_minutes;
                const a: u16 = @abs(off);
                try w.print(" {c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), a / 60, a % 60 });
            },
        }
    }
};

fn writeDate(w: *std.Io.Writer, d: Date) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(d.year)), d.month, d.day });
}

fn writeTime(w: *std.Io.Writer, t: Time) !void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanos != 0) {
        // 100 ns is SQL Server's finest unit; print up to 7 digits, trailing zeros cut.
        var frac: u32 = t.nanos / 100;
        var digits: u8 = 7;
        while (frac % 10 == 0) : (digits -= 1) frac /= 10;
        try w.writeByte('.');
        var buf: [7]u8 = undefined;
        var i: u8 = digits;
        while (i > 0) : (i -= 1) {
            buf[i - 1] = '0' + @as(u8, @intCast(frac % 10));
            frac /= 10;
        }
        try w.writeAll(buf[0..digits]);
    }
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

const days_0001_to_1970: i64 = 719_162;
const days_1900_to_1970: i64 = 25_567;
const ns_per_day: i128 = 86_400 * std.time.ns_per_s;

/// Days since 1970-01-01 to a civil date (proleptic Gregorian, H. Hinnant's algorithm).
pub fn civilFromDays(days: i64) Date {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

fn timeFromNanos(ns: u64) Time {
    const s = ns / std.time.ns_per_s;
    return .{
        .hour = @intCast(s / 3600),
        .minute = @intCast(s / 60 % 60),
        .second = @intCast(s % 60),
        .nanos = @intCast(ns % std.time.ns_per_s),
    };
}

/// Splits nanoseconds since 1970-01-01 into a date and a time of day.
fn splitNanos(total: i128) DateTime {
    const days = @divFloor(total, ns_per_day);
    const rem: u64 = @intCast(total - days * ns_per_day);
    return .{ .date = civilFromDays(@intCast(days)), .time = timeFromNanos(rem) };
}

// ---------------------------------------------------------------------------
// Cell decoders (MS-TDS 2.2.5.5). `b` is the value without its length prefix.
// ---------------------------------------------------------------------------

fn le(comptime T: type, b: []const u8) T {
    var buf: [@sizeOf(T)]u8 = @splat(0);
    @memcpy(buf[0..b.len], b);
    return std.mem.readInt(T, &buf, .little);
}

/// INTN and the fixed integers; a 1-byte integer is TINYINT, which is unsigned.
pub fn decodeInt(b: []const u8) error{Protocol}!Value {
    return .{ .int = switch (b.len) {
        1 => b[0],
        2 => std.mem.readInt(i16, b[0..2], .little),
        4 => std.mem.readInt(i32, b[0..4], .little),
        8 => std.mem.readInt(i64, b[0..8], .little),
        else => return error.Protocol,
    } };
}

pub fn decodeFloat(b: []const u8) error{Protocol}!Value {
    return .{ .float = switch (b.len) {
        4 => @as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little))),
        8 => @bitCast(std.mem.readInt(u64, b[0..8], .little)),
        else => return error.Protocol,
    } };
}

/// MONEY is a 64-bit count of ten-thousandths sent high half first; SMALLMONEY is 32-bit.
pub fn decodeMoney(b: []const u8) error{Protocol}!Value {
    const v: i64 = switch (b.len) {
        4 => std.mem.readInt(i32, b[0..4], .little),
        8 => (@as(i64, std.mem.readInt(i32, b[0..4], .little)) << 32) | std.mem.readInt(u32, b[4..8], .little),
        else => return error.Protocol,
    };
    return .{ .decimal = .{ .value = v, .scale = 4 } };
}

/// DATETIME: days since 1900-01-01 and 1/300 s ticks; SMALLDATETIME: days and minutes.
pub fn decodeDateTime(b: []const u8) error{Protocol}!Value {
    var days: i64 = undefined;
    var ns: i128 = undefined;
    switch (b.len) {
        4 => {
            days = std.mem.readInt(u16, b[0..2], .little);
            ns = @as(i128, std.mem.readInt(u16, b[2..4], .little)) * 60 * std.time.ns_per_s;
        },
        8 => {
            days = std.mem.readInt(i32, b[0..4], .little);
            const ticks: u64 = std.mem.readInt(u32, b[4..8], .little);
            // Rounded to the millisecond, as SQL Server shows it (.000, .003, .007).
            ns = @as(i128, (ticks * 10 + 1) / 3) * std.time.ns_per_ms;
        },
        else => return error.Protocol,
    }
    return .{ .datetime = splitNanos((days - days_1900_to_1970) * ns_per_day + ns) };
}

/// DECIMAL/NUMERIC: a sign byte (1 = positive), then the magnitude, little-endian.
pub fn decodeDecimal(b: []const u8, scale: u8) error{Protocol}!Value {
    if (b.len < 2 or b.len > 17) return error.Protocol;
    const mag = le(u128, b[1..]);
    if (mag > std.math.maxInt(i128)) return error.Protocol;
    const v: i128 = @intCast(mag);
    return .{ .decimal = .{ .value = if (b[0] == 1) v else -v, .scale = scale } };
}

/// uniqueidentifier: the first three groups arrive little-endian.
pub fn decodeGuid(b: []const u8) error{Protocol}!Value {
    if (b.len != 16) return error.Protocol;
    var g: [16]u8 = undefined;
    for (0..4) |i| g[i] = b[3 - i];
    g[4] = b[5];
    g[5] = b[4];
    g[6] = b[7];
    g[7] = b[6];
    @memcpy(g[8..], b[8..16]);
    return .{ .guid = g };
}

fn timeNanos(b: []const u8, scale: u8) error{Protocol}!u64 {
    if (b.len < 3 or b.len > 5 or scale > 7) return error.Protocol;
    const units = le(u64, b);
    const ns = units * (std.math.powi(u64, 10, 9 - scale) catch unreachable);
    if (ns >= 86_400 * std.time.ns_per_s) return error.Protocol;
    return ns;
}

fn dateDays(b: []const u8) i64 {
    return @as(i64, le(u32, b[0..3])) - days_0001_to_1970;
}

pub fn decodeDate(b: []const u8) error{Protocol}!Value {
    if (b.len != 3) return error.Protocol;
    return .{ .date = civilFromDays(dateDays(b)) };
}

pub fn decodeTime(b: []const u8, scale: u8) error{Protocol}!Value {
    return .{ .time = timeFromNanos(try timeNanos(b, scale)) };
}

pub fn decodeDateTime2(b: []const u8, scale: u8) error{Protocol}!Value {
    if (b.len < 6) return error.Protocol;
    const t = b.len - 3;
    const ns = try timeNanos(b[0..t], scale);
    return .{ .datetime = splitNanos(@as(i128, dateDays(b[t..])) * ns_per_day + ns) };
}

/// DATETIMEOFFSET carries UTC; shown, as SQL Server shows it, in its own offset.
pub fn decodeDateTimeOffset(b: []const u8, scale: u8) error{Protocol}!Value {
    if (b.len < 8) return error.Protocol;
    const t = b.len - 5;
    const ns = try timeNanos(b[0..t], scale);
    const off = std.mem.readInt(i16, b[t + 3 ..][0..2], .little);
    const local = @as(i128, dateDays(b[t .. t + 3])) * ns_per_day + ns + @as(i128, off) * 60 * std.time.ns_per_s;
    const dt = splitNanos(local);
    return .{ .datetimeoffset = .{ .date = dt.date, .time = dt.time, .offset_minutes = off } };
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// UTF-16LE (NCHAR, NVARCHAR, NTEXT, XML) to UTF-8; a lone surrogate becomes U+FFFD.
pub fn utf16ToUtf8(a: Allocator, b: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, b.len);
    var i: usize = 0;
    while (i + 1 < b.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, b[i..][0..2], .little);
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 3 < b.len) {
            const lo = std.mem.readInt(u16, b[i + 2 ..][0..2], .little);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else cp = 0xFFFD;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// UTF-8 to UTF-16LE, for SQL text and LOGIN7 fields.
pub fn utf8ToUtf16(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, s.len * 2);
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(cp))));
        } else {
            const v = cp - 0x10000;
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(0xD800 + (v >> 10)))));
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(0xDC00 + (v & 0x3FF)))));
        }
    }
    return out.toOwnedSlice(a);
}

/// The bytes 0x80-0x9F of Windows-1252; the rest of the upper half is Latin-1.
const cp1252_high = [32]u16{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

/// Non-Unicode text (CHAR, VARCHAR, TEXT) by its column's collation. A UTF-8
/// collation (fUTF8, bit 26) passes through; anything else is read as
/// Windows-1252, the code page of the Latin collations. MVP: other code pages
/// (Cyrillic, CJK...) are not mapped yet.
pub fn ansiToUtf8(a: Allocator, collation: [5]u8, b: []const u8) Allocator.Error![]u8 {
    const info = std.mem.readInt(u32, collation[0..4], .little);
    const utf8_collation = info & (1 << 26) != 0;
    if (utf8_collation or std.unicode.utf8ValidateSlice(b) and isAscii(b)) return a.dupe(u8, b);
    var out: std.ArrayList(u8) = try .initCapacity(a, b.len + b.len / 2);
    for (b) |c| {
        const cp: u21 = if (c < 0x80) c else if (c < 0xA0) cp1252_high[c - 0x80] else c;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn isAscii(b: []const u8) bool {
    for (b) |c| if (c >= 0x80) return false;
    return true;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFmt(expected: []const u8, v: Value) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try v.format(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "calendar" {
    try testing.expectEqual(Date{ .year = 1970, .month = 1, .day = 1 }, civilFromDays(0));
    try testing.expectEqual(Date{ .year = 1, .month = 1, .day = 1 }, civilFromDays(-days_0001_to_1970));
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, civilFromDays(19782));
}

test "decimal and money" {
    try expectFmt("-1.2345", try decodeDecimal(&.{ 0, 0x39, 0x30, 0x00, 0x00 }, 4));
    try expectFmt("1.5000", try decodeMoney(&.{ 0, 0, 0, 0, 0x98, 0x3A, 0, 0 }));
    try expectFmt("0.05", .{ .decimal = .{ .value = 5, .scale = 2 } });
}

test "guid order" {
    const v = try decodeGuid(&.{ 0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF });
    try expectFmt("00112233-4455-6677-8899-AABBCCDDEEFF", v);
}

test "text" {
    const a = testing.allocator;
    const s = try ansiToUtf8(a, @splat(0), "a\xe7\xe3o \x80");
    defer a.free(s);
    try testing.expectEqualStrings("ação €", s);
    const w = try utf8ToUtf16(a, "é😀");
    defer a.free(w);
    const back = try utf16ToUtf8(a, w);
    defer a.free(back);
    try testing.expectEqualStrings("é😀", back);
}

test "datetime" {
    // 2024-01-02 03:04:05.500 as DATETIME: 45291 days since 1900, 3h4m5.5s in ticks.
    var b: [8]u8 = undefined;
    std.mem.writeInt(i32, b[0..4], 45291, .little);
    std.mem.writeInt(u32, b[4..8], (3 * 3600 + 4 * 60 + 5) * 300 + 150, .little);
    try expectFmt("2024-01-02 03:04:05.5", try decodeDateTime(&b));
}

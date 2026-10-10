//! Dates. A spreadsheet stores a date as a number — days since the
//! start of 1900, with the time of day as the fraction — and shows it
//! as a date only because the cell has a date number format.
//!
//! This module always writes the 1900 date system (the default one;
//! the 1904 system only exists for files made by old Mac versions of
//! Excel). In that system day 1 is 1900-01-01, and day 60 is
//! 1900-02-29: a day that never existed, kept by Excel for
//! compatibility with Lotus 1-2-3. Every real date from 1900-03-01 on
//! is therefore one more than the true day count.

const std = @import("std");

/// What `Date.serial`, `DateTime.serial` and `DateTime.fromUnix` fail with.
pub const Error = error{
    /// Not a real calendar date or time, or outside 1900-01-01 ..
    /// 9999-12-31, the range a spreadsheet can show.
    InvalidDate,
};

/// A calendar date (proleptic Gregorian, no time zone).
pub const Date = struct {
    year: u16,
    /// 1 to 12.
    month: u8,
    /// 1 to 31.
    day: u8,

    /// The day number the 1900 date system gives this date.
    pub fn serial(date: Date) Error!u32 {
        if (date.year < 1900 or date.year > 9999) return error.InvalidDate;
        if (date.month < 1 or date.month > 12) return error.InvalidDate;
        if (date.day < 1 or date.day > daysInMonth(date.year, date.month)) return error.InvalidDate;
        // Days since 1899-12-31, so that 1900-01-01 is 1.
        const days = daysFromCivil(date.year, date.month, date.day) - daysFromCivil(1899, 12, 31);
        const true_count: u32 = @intCast(days);
        // Skip the phantom 1900-02-29 (serial 60).
        return if (true_count >= 60) true_count + 1 else true_count;
    }
};

/// A calendar date and a time of day (no time zone: the spreadsheet
/// shows exactly these fields).
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,

    /// Day number plus the fraction of the day.
    pub fn serial(dt: DateTime) Error!f64 {
        if (dt.hour > 23 or dt.minute > 59 or dt.second > 59 or dt.millisecond > 999) return error.InvalidDate;
        const day = try (Date{ .year = dt.year, .month = dt.month, .day = dt.day }).serial();
        const ms: u32 = ((@as(u32, dt.hour) * 60 + dt.minute) * 60 + dt.second) * 1000 + dt.millisecond;
        return @as(f64, @floatFromInt(day)) + @as(f64, @floatFromInt(ms)) / 86_400_000.0;
    }

    /// The UTC date and time of a Unix timestamp (seconds since
    /// 1970-01-01). Add the zone offset to `seconds` first to get local
    /// time.
    pub fn fromUnix(seconds: i64) Error!DateTime {
        const days = @divFloor(seconds, 86_400);
        const rest: u32 = @intCast(@mod(seconds, 86_400));
        // Rough bounds first, so the day arithmetic below cannot overflow.
        if (days < -26_000 or days > 3_000_000) return error.InvalidDate;
        const civil = civilFromDays(@intCast(days));
        if (civil.year < 1900 or civil.year > 9999) return error.InvalidDate;
        return .{
            .year = @intCast(civil.year),
            .month = civil.month,
            .day = civil.day,
            .hour = @intCast(rest / 3600),
            .minute = @intCast(rest % 3600 / 60),
            .second = @intCast(rest % 60),
        };
    }
};

/// Which day a serial number counts from. A workbook says which one
/// it uses; almost all use 1900.
pub const DateSystem = enum {
    /// Day 1 is 1900-01-01, and day 60 is the 1900-02-29 that never
    /// existed.
    excel_1900,
    /// Day 0 is 1904-01-01; no phantom day.
    excel_1904,
};

/// The time of day of a cell that holds no date.
pub const TimeOfDay = struct {
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,

    /// From the fraction of a day (0 up to 1), rounded to the millisecond.
    /// Anything from 1 on gives 23:59:59.999; a negative number, or one
    /// that is not a number, gives 00:00:00.
    pub fn fromFraction(fraction: f64) TimeOfDay {
        // Brought into the day before it becomes an integer: a negative
        // number, one far past 1 or not a number at all would otherwise be
        // a conversion the language does not define.
        const last: f64 = 86_399_999;
        const scaled = @round(fraction * 86_400_000.0);
        const ms: u32 = if (!(scaled > 0)) 0 else if (scaled >= last) 86_399_999 else @intFromFloat(scaled);
        return .{
            .hour = @intCast(ms / 3_600_000),
            .minute = @intCast(ms / 60_000 % 60),
            .second = @intCast(ms / 1000 % 60),
            .millisecond = @intCast(ms % 1000),
        };
    }
};

// internal: used inside the xlsx module; apps do not call it.
// The date and time a serial number stands for, or null when it is
// not a date a spreadsheet can show: not finite, negative, past
// 9999-12-31, or, in the 1900 system, below 1 (day 0, a time of day
// alone) or the phantom day 60. The time is rounded to the millisecond.
pub fn fromSerial(serial: f64, system: DateSystem) ?DateTime {
    if (!std.math.isFinite(serial) or serial < 0 or serial >= 2_958_466) return null;
    var day: u32 = @intFromFloat(@floor(serial));
    var ms: u32 = @intFromFloat(@round((serial - @floor(serial)) * 86_400_000.0));
    if (ms >= 86_400_000) {
        ms = 0;
        day += 1;
    }
    const days_from_epoch: i32 = switch (system) {
        .excel_1900 => days: {
            if (day == 0 or day == 60) return null;
            const true_count: i32 = @intCast(if (day > 60) day - 1 else day);
            break :days daysFromCivil(1899, 12, 31) + true_count;
        },
        .excel_1904 => daysFromCivil(1904, 1, 1) + @as(i32, @intCast(day)),
    };
    const civil = civilFromDays(days_from_epoch);
    if (civil.year > 9999) return null;
    return .{
        .year = @intCast(civil.year),
        .month = civil.month,
        .day = civil.day,
        .hour = @intCast(ms / 3_600_000),
        .minute = @intCast(ms / 60_000 % 60),
        .second = @intCast(ms / 1000 % 60),
        .millisecond = @intCast(ms % 1000),
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn daysInMonth(year: u32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

/// Days from 1970-01-01 to the given date (negative before it).
fn daysFromCivil(year: i32, month: u8, day: u8) i32 {
    const y: i32 = if (month <= 2) year - 1 else year;
    const era: i32 = @divFloor(y, 400);
    const year_of_era: i32 = y - era * 400;
    const m: i32 = month;
    const day_of_year: i32 = @divFloor(153 * (m + (if (m > 2) @as(i32, -3) else 9)) + 2, 5) + day - 1;
    const day_of_era: i32 = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

const Civil = struct { year: i32, month: u8, day: u8 };

/// The inverse of `daysFromCivil`.
fn civilFromDays(days: i32) Civil {
    const z: i32 = days + 719_468;
    const era: i32 = @divFloor(z, 146_097);
    const day_of_era: i32 = z - era * 146_097;
    const year_of_era: i32 = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year: i32 = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const mp: i32 = @divFloor(5 * day_of_year + 2, 153);
    const day: i32 = day_of_year - @divFloor(153 * mp + 2, 5) + 1;
    const month: i32 = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = year_of_era + era * 400 + @as(i32, if (month <= 2) 1 else 0);
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

const testing = std.testing;

fn expectSerial(expected: u32, year: u16, month: u8, day: u8) !void {
    try testing.expectEqual(expected, try (Date{ .year = year, .month = month, .day = day }).serial());
}

test "date serials around the 1900 leap-year bug" {
    try expectSerial(1, 1900, 1, 1);
    try expectSerial(31, 1900, 1, 31);
    try expectSerial(59, 1900, 2, 28);
    // 60 is the phantom 1900-02-29: no real date maps to it.
    try expectSerial(61, 1900, 3, 1);
    try expectSerial(367, 1901, 1, 1);
}

test "date serials Excel shows for known dates" {
    try expectSerial(25_569, 1970, 1, 1);
    try expectSerial(36_526, 2000, 1, 1);
    try expectSerial(36_585, 2000, 2, 29);
    try expectSerial(39_448, 2008, 1, 1);
    try expectSerial(45_292, 2024, 1, 1);
    try expectSerial(45_351, 2024, 2, 29);
    try expectSerial(46_302, 2026, 10, 7);
    try expectSerial(2_958_465, 9999, 12, 31);
}

test "dates a spreadsheet cannot hold are refused" {
    const bad = [_]Date{
        .{ .year = 1899, .month = 12, .day = 31 },
        .{ .year = 10_000, .month = 1, .day = 1 },
        .{ .year = 1900, .month = 2, .day = 29 },
        .{ .year = 2023, .month = 2, .day = 29 },
        .{ .year = 2024, .month = 13, .day = 1 },
        .{ .year = 2024, .month = 0, .day = 1 },
        .{ .year = 2024, .month = 4, .day = 31 },
        .{ .year = 2024, .month = 4, .day = 0 },
    };
    for (bad) |date| try testing.expectError(error.InvalidDate, date.serial());
}

test "date and time serials" {
    const noon: DateTime = .{ .year = 2024, .month = 1, .day = 1, .hour = 12 };
    try testing.expectEqual(@as(f64, 45_292.5), try noon.serial());
    const six: DateTime = .{ .year = 1900, .month = 1, .day = 1, .hour = 6 };
    try testing.expectEqual(@as(f64, 1.25), try six.serial());
    const precise: DateTime = .{ .year = 2026, .month = 10, .day = 7, .hour = 23, .minute = 59, .second = 59, .millisecond = 999 };
    try testing.expectApproxEqAbs(@as(f64, 46_302.999_999_988), try precise.serial(), 1e-9);

    try testing.expectError(error.InvalidDate, (DateTime{ .year = 2024, .month = 1, .day = 1, .hour = 24 }).serial());
    try testing.expectError(error.InvalidDate, (DateTime{ .year = 2024, .month = 1, .day = 1, .minute = 60 }).serial());
    try testing.expectError(error.InvalidDate, (DateTime{ .year = 2024, .month = 1, .day = 1, .second = 60 }).serial());
    try testing.expectError(error.InvalidDate, (DateTime{ .year = 2024, .month = 1, .day = 1, .millisecond = 1000 }).serial());
}

test "Unix timestamps" {
    const epoch = try DateTime.fromUnix(0);
    try testing.expectEqual(DateTime{ .year = 1970, .month = 1, .day = 1 }, epoch);
    try testing.expectEqual(@as(f64, 25_569), try epoch.serial());

    // 2026-10-07 13:01:01 UTC.
    try testing.expectEqual(
        DateTime{ .year = 2026, .month = 10, .day = 7, .hour = 13, .minute = 1, .second = 1 },
        try DateTime.fromUnix(1_791_378_061),
    );
    // Before 1970, including the last second of 1969.
    try testing.expectEqual(
        DateTime{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 },
        try DateTime.fromUnix(-1),
    );
    try testing.expectEqual(DateTime{ .year = 1900, .month = 1, .day = 1 }, try DateTime.fromUnix(-2_208_988_800));
    try testing.expectError(error.InvalidDate, DateTime.fromUnix(-2_208_988_801));
    try testing.expectError(error.InvalidDate, DateTime.fromUnix(std.math.maxInt(i64)));
    try testing.expectError(error.InvalidDate, DateTime.fromUnix(std.math.minInt(i64)));
}

test "serial numbers back to dates, in both systems" {
    const Check = struct {
        fn date(serial: f64, system: DateSystem) ?[3]u16 {
            const dt = fromSerial(serial, system) orelse return null;
            return .{ dt.year, dt.month, dt.day };
        }
    };
    try testing.expectEqual(@as(?[3]u16, .{ 1900, 1, 1 }), Check.date(1, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, .{ 1900, 2, 28 }), Check.date(59, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, null), Check.date(60, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, .{ 1900, 3, 1 }), Check.date(61, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, .{ 2026, 10, 7 }), Check.date(46_302, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, .{ 9999, 12, 31 }), Check.date(2_958_465, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, null), Check.date(2_958_466, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, null), Check.date(0, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, null), Check.date(-1, .excel_1900));
    try testing.expectEqual(@as(?[3]u16, null), Check.date(std.math.nan(f64), .excel_1900));
    try testing.expectEqual(@as(?[3]u16, .{ 1904, 1, 1 }), Check.date(0, .excel_1904));
    try testing.expectEqual(@as(?[3]u16, .{ 1904, 2, 29 }), Check.date(59, .excel_1904));
    try testing.expectEqual(@as(?[3]u16, .{ 2030, 10, 8 }), Check.date(46_302, .excel_1904));

    // Every date the writer can write reads back as itself.
    var serial: u32 = 1;
    while (serial < 2_958_465) : (serial += 997) {
        if (serial == 60) continue;
        const dt = fromSerial(@floatFromInt(serial), .excel_1900).?;
        try testing.expectEqual(serial, try (Date{ .year = dt.year, .month = dt.month, .day = dt.day }).serial());
    }
    // Less than half a millisecond before midnight rounds to the next day.
    const precise = fromSerial(46_302.999_999_999_9, .excel_1900).?;
    try testing.expectEqual(DateTime{ .year = 2026, .month = 10, .day = 8 }, precise);
    try testing.expectEqual(TimeOfDay{ .hour = 18, .minute = 0, .second = 0, .millisecond = 0 }, TimeOfDay.fromFraction(0.75));
    try testing.expectEqual(TimeOfDay{ .hour = 23, .minute = 59, .second = 59, .millisecond = 999 }, TimeOfDay.fromFraction(0.999_999_999));
}

test "TimeOfDay.fromFraction: any number gives a time of day, never a crash" {
    try std.testing.expectEqual(TimeOfDay{ .hour = 12, .minute = 0, .second = 0, .millisecond = 0 }, TimeOfDay.fromFraction(0.5));
    // Out of the day on either side: midnight, or the last millisecond.
    const midnight: TimeOfDay = .{ .hour = 0, .minute = 0, .second = 0, .millisecond = 0 };
    const last: TimeOfDay = .{ .hour = 23, .minute = 59, .second = 59, .millisecond = 999 };
    try std.testing.expectEqual(midnight, TimeOfDay.fromFraction(-0.25));
    try std.testing.expectEqual(midnight, TimeOfDay.fromFraction(-1e300));
    try std.testing.expectEqual(midnight, TimeOfDay.fromFraction(std.math.nan(f64)));
    try std.testing.expectEqual(last, TimeOfDay.fromFraction(1.0));
    try std.testing.expectEqual(last, TimeOfDay.fromFraction(1e300));
    try std.testing.expectEqual(last, TimeOfDay.fromFraction(std.math.inf(f64)));
}

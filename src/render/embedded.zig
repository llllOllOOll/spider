//! Embedded templates (the app's `spider_templates`, generated into
//! src/embedded_templates.zig) as one map built at compile time.
//!
//! Ctx.view() used to walk that struct with `inline for` inside the generic
//! view function: every `data` type got its own copy of a lookup over every
//! template, plus a per-request copy of every template into a components map.
//! Build size grew with (data types x templates), each request copied all
//! templates, and an edited .html invalidated every view instance under
//! incremental compilation. Now only this map depends on the template
//! contents, and each request reads it without copying.

const std = @import("std");

pub const Map = std.StaticStringMap([]const u8);

/// Longest template name view() accepts; longer names are not found.
pub const max_name_len = 256;

const component_prefix = "components_";

/// Every field of `T` by its name; `components_x` also as `x`. When a name
/// repeats, the later one wins (field order, alias right after its field),
/// which is what the per-request map this replaces did.
pub fn buildMap(comptime T: type) Map {
    comptime {
        const names = @typeInfo(T).@"struct".field_names;
        @setEvalBranchQuota(10_000 + 200 * names.len * names.len);
        const instance: T = .{};

        var alias_count: usize = 0;
        for (names) |name| {
            if (std.mem.startsWith(u8, name, component_prefix)) alias_count += 1;
        }

        const Entry = struct { []const u8, []const u8 };
        var entries: [names.len + alias_count]Entry = undefined;
        var len: usize = 0;
        for (names) |name| {
            const content: []const u8 = @field(instance, name);
            put(&entries, &len, name, content);
            if (std.mem.startsWith(u8, name, component_prefix)) {
                put(&entries, &len, name[component_prefix.len..], content);
            }
        }
        const final = entries[0..len].*;
        return .initComptime(final);
    }
}

fn put(entries: anytype, len: *usize, comptime key: []const u8, comptime value: []const u8) void {
    for (entries[0..len.*]) |*entry| {
        if (std.mem.eql(u8, entry[0], key)) {
            entry[1] = value;
            return;
        }
    }
    entries[len.*] = .{ key, value };
    len.* += 1;
}

/// "home/index" -> "home_index", "new-form" -> "new_form" (the generated
/// field names). Null when `name` is longer than `max_name_len`.
pub fn normalizeName(buf: *[max_name_len]u8, name: []const u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '/' or c == '-') '_' else c;
    return buf[0..name.len];
}

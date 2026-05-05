    const payload_json = try std.json.Stringify.valueAlloc(alloc, claims, .{});

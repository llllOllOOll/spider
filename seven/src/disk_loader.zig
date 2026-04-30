const std = @import("std");

pub const DiskLoader = struct {
    root_dir: []const u8,

    pub fn get(ptr: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *DiskLoader = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = name;
        // runtime — leria do disco
        // no POC só simular
        return null;
    }
};

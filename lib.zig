//! Spider Web Framework
//!
//! High-performance HTTP web framework written in Zig.
//!
//! Usage:
//!     const spider = @import("spider");

pub const Spider = @import("src/spider.zig").Spider;
pub const loadEnv = @import("src/spider.zig").loadEnv;
pub const env = @import("src/spider.zig").env;

//! Spider Web Server Package
//!
//! Usage:
//!     const spider = @import("spider");
//!     try spider.start(init);

pub const Server = @import("server.zig").Server;
pub const start = @import("server.zig").start;

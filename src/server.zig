//! Server module - re-exports from core/server.zig and core/pipeline.zig

pub const Server = @import("core/server.zig").Server;
pub const ConnectionContext = @import("core/server.zig").ConnectionContext;
pub const HandlerFn = @import("core/server.zig").HandlerFn;

pub const MAX_BODY_SIZE = @import("core/server.zig").MAX_BODY_SIZE;
pub const RETAIN_BYTES = @import("core/server.zig").RETAIN_BYTES;
pub const SLOW_REQUEST_THRESHOLD_NS = @import("core/server.zig").SLOW_REQUEST_THRESHOLD_NS;

pub const shutdown_flag = @import("core/server.zig").shutdown_flag;
pub const ws_counter = @import("core/server.zig").ws_counter;
pub const active_connections = @import("core/server.zig").active_connections;

pub const handleConnection = @import("core/pipeline.zig").handleConnection;
pub const indexHandler = @import("core/pipeline.zig").indexHandler;
pub const metricHandler = @import("core/pipeline.zig").metricHandler;
pub const healthHandler = @import("core/pipeline.zig").healthHandler;
pub const notFoundHandler = @import("core/pipeline.zig").notFoundHandler;
pub const payloadTooLargeHandler = @import("core/pipeline.zig").payloadTooLargeHandler;
pub const staticFileHandler = @import("core/pipeline.zig").staticFileHandler;

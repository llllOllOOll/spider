//! Internal: minimal spider core for the pg wrapper tests; exposes only what
//! pg.zig needs. Re-exports the real types (never copies) so this shim can't
//! drift from the framework again; a hand-copied Database here once gained a
//! field the real one doesn't have and broke `zig build test-pg`.
pub const env = @import("internal/env.zig");
pub const Database = @import("core/database.zig").Database;

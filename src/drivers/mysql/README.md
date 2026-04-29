# MySQL Driver for Spider Web Framework

This is a MySQL database driver implementation for the Spider web framework, following the same API pattern as the PostgreSQL driver.

## Status

🚧 **Work in Progress** - Basic structure implemented, query execution pending

## Features

- ✅ MySQL protocol implementation (based on Bun's MySQL driver)
- ✅ Connection pooling
- ✅ Type mapping (MySQL → Zig types)
- ✅ Same API as PostgreSQL driver (`c.db().query()`)
- 🔄 Query execution (in progress)
- 🔄 Result parsing (in progress)

## Structure

```
src/drivers/mysql/
├── mysql.zig          # Main driver entry point
├── protocol.zig       # MySQL protocol implementation
├── connection.zig     # Connection management
├── types.zig          # Type mapping
└── README.md          # This file
```

## Usage

Same API as PostgreSQL:

```zig
// Initialize MySQL driver
try mysql.init(allocator, io, .{
    .host = "localhost",
    .port = 3306,
    .database = "spider_db",
    .user = "spider",
    .password = "spider_password",
    .pool_size = 10,
});

defer mysql.deinit();

// Query with typed results
const Todo = struct {
    id: i32,
    title: []const u8,
    completed: bool,
};

const todos = try mysql.query(Todo, arena, "SELECT * FROM todos", .{});
```

## Testing

Use the provided Docker Compose setup:

```bash
# Start MySQL container
docker-compose -f docker-compose.mysql.yml up -d

# Run tests
zig test test-mysql.zig
```

## Implementation Details

### Protocol

Based on Bun's MySQL protocol implementation:
- Command types (COM_QUERY, COM_STMT_PREPARE, etc.)
- Packet serialization/deserialization
- Authentication flow
- Result set parsing

### Type Mapping

Supports mapping MySQL types to Zig types:
- `TINY` → `i8`/`u8`
- `INT` → `i32`/`u32`
- `VARCHAR` → `[]const u8`
- `BOOL` → `bool`
- `DECIMAL` → `f64`
- And more...

### Connection Pooling

Uses the same connection pooling pattern as PostgreSQL driver.

## Next Steps

1. Implement query execution and result parsing
2. Add prepared statement support
3. Implement transaction support
4. Add comprehensive tests
5. Performance optimization

## References

- [Bun MySQL Driver](https://github.com/oven-sh/bun/tree/main/src/sql/mysql)
- [MySQL Protocol Documentation](https://dev.mysql.com/doc/internals/en/client-server-protocol.html)
- [Spider PostgreSQL Driver](../pg/)
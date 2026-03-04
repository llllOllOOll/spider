# Spider Web Framework - Agent Guidelines

## Build Commands

```bash
# Build the project
zig build -Doptimize=ReleaseFast

# Build with debug optimization
zig build -Doptimize=Debug

# Run the application
zig build run

# Run with custom arguments
zig build run -- --arg1 value

# Run all tests
zig test .

# Run tests for a specific file
zig test src/web.zig

# Run a specific test by name (requires filtering via zig test --test-filter)
zig test src/template.zig --test-filter "basic variable"

# Run module tests only
zig test src/ --cache on

# Format code
zig fmt src/
zig fmt .
```

## Project Structure

```
spider/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── lib.zig                # Library entry (empty)
├── README.md              # Documentation
├── .gitignore
└── src/
    ├── spider.zig         # Main framework exports
    ├── web.zig            # Request/Response, HTTP types
    ├── router.zig         # Trie-based router
    ├── server.zig         # HTTP server
    ├── template.zig       # Template engine
    ├── websocket.zig       # WebSocket protocol
    ├── ws_hub.zig         # WebSocket hub
    ├── logger.zig         # Structured logging
    ├── metrics.zig        # Metrics collection
    ├── conn_pool.zig      # Connection pooling
    ├── buffer_pool.zig    # Buffer pooling
    ├── pg.zig             # PostgreSQL client
    └── static/            # Static files
```

## Code Style Guidelines

### Naming Conventions
- **Types**: PascalCase (e.g., `Spider`, `Request`, `Response`)
- **Functions/variables**: snake_case (e.g., `init()`, `getPath()`, `parseBody()`)
- **Constants**: snake_case with SCREAMING_SNAKE_CASE for compile-time (e.g., `max_body_size`)
- **Enums**: PascalCase variants (e.g., `.get`, `.post`, `.ok`)

### Imports
- Always use `@import("std")` first
- Then third-party imports
- Then local imports
- Use aliases for clarity: `const Route = router_mod;`

```zig
const std = @import("std");
const router_mod = @import("router.zig");
const template = @import("template.zig");

const Route = router_mod;
```

### Error Handling
- Use `try` for functions that return `!T`
- Use `catch` with specific error types when needed
- Propagate errors with `return error.ErrorName;`
- Never swallow errors silently (use `_ = result` only when intentional)

```zig
pub fn myFunction() !void {
    var item = try allocator.create(Item);
    // Use defer for cleanup
    defer allocator.destroy(item);
    
    if (condition) {
        return error.InvalidInput;
    }
}
```

### Memory Management
- Always pair `allocator.create()` with `defer allocator.destroy()`
- Always pair `try allocator.alloc()` with `defer allocator.free()`
- Use `arena.allocator()` for per-request allocations when possible

### Structs and Types
- Use anonymous structs for simple data: `.{ .field = value }`
- Use `std.StringHashMapUnmanaged` for hash maps (no allocator stored in struct)
- Make fields `pub` only when needed

### Testing
- Place tests at the bottom of source files
- Use `std.testing.expectEqual` and `std.testing.expectEqualStrings`
- Always defer cleanup in tests

```zig
test "my test" {
    var item = try MyType.init(std.testing.allocator);
    defer item.deinit();
    
    try std.testing.expectEqual(expected, item.value);
}
```

### HTTP/Framework Patterns

#### Handler Signature
```zig
pub const Handler = fn (allocator: std.mem.Allocator, req: *Request) !Response;
```

#### Creating Responses
```zig
// Text response
return try Response.text(allocator, "Hello World");

// JSON response  
return try Response.json(allocator, "{\"key\": \"value\"}");

// HTML response
return try Response.html(allocator, "<html>...</html>");

// Redirect
return try Response.redirect(allocator, "/new-location");
```

#### Route Registration
```zig
app.get("/", indexHandler)
    .post("/users", createUser)
    .put("/users/:id", updateUser)
    .delete("/users/:id", deleteUser);

// With middleware
app.use(authMiddleware)
   .get("/protected", protectedHandler);
```

### Performance Considerations
- Use `std.ArrayListUnmanaged` and `std.StringHashMapUnmanaged` for zero-allocator patterns
- Prefer stack allocation with `std.heap.FixedBufferAllocator` for small buffers
- Reuse buffers via buffer pools for high-frequency allocations
- Use `@memcpy` for bulk memory operations

### Code Formatting
- Run `zig fmt` before committing
- 4-space indentation (Zig standard)
- Maximum line length: 120 characters
- One blank line between top-level declarations

### Documentation
- Document public APIs with doc comments (`/// Description`)
- Keep README.md updated with new features
- Document breaking changes in commit messages

# AGENTS.md - Spider Hexagonal Demo

## Project Overview

This is a Zig web application demonstrating hexagonal architecture patterns with the Spider web framework. It provides a REST API for product management backed by PostgreSQL.

## Build Commands

### Build & Run
```bash
# Build the project
zig build

# Build with release optimization
zig build -Doptimize=ReleaseFast

# Run the application
zig build run

# Run with custom arguments
zig build run -- <args>
```

### Testing
```bash
# Run all tests
zig build test

# Run tests in parent project (spider framework)
cd .. && zig build test
```

### Formatting
```bash
# Format all Zig files
zig fmt .
```

### Dependencies
```bash
# Fetch dependencies
zig build fetch
```

### Docker
```bash
# Build and run with Docker
docker-compose up --build
```

## Code Style Guidelines

### General Principles
- Use Zig 0.16+ features and patterns
- Avoid comments unless absolutely necessary for clarity
- Keep functions focused and small
- Prefer explicit error handling over panics

### Imports
```zig
const std = @import("std");
const spider = @import("spider");
const spider_pg = @import("spider_pg");
const repository = @import("repository.zig");
```

- Standard library imports first (`std`)
- External dependencies second (`spider`, `spider_pg`)
- Local imports third (relative paths)
- Group imports by category with blank lines between groups

### Naming Conventions
- **Types**: PascalCase (`Product`, `ProductRepository`, `ProductService`)
- **Functions**: camelCase (`init`, `list`, `getById`)
- **Variables**: camelCase (`allocator`, `pool`, `config`)
- **Constants**: PascalCase or SCREAMING_SNAKE_CASE depending on scope
- **Files**: snake_case (`product.zig`, `repository.zig`)

### Types and Memory

#### Allocators
- Always pass `std.mem.Allocator` as first parameter to functions that need allocation
- Use function parameter ordering: `(allocator: std.mem.Allocator, ...)`
- Use `arena.allocator()` for request-scoped allocations when available

#### Structs
```zig
pub const Product = struct {
    id: u64,
    name: []const u8,
    price: f64,
    quantity: u32,
};
```

- Use `pub const` for public types
- Use anonymous structs (`.{}`) for initialization
- Use field access syntax (`.field`) for clarity

#### Slices
- Use `[]const u8` for strings (not `[N]u8` or `[*]u8`)
- Use `[]T` for dynamic slices
- Use `*T` for pointers to single items

### Error Handling

#### Returning Errors
```zig
pub fn create(self: *ProductService, input: CreateProductInput) !Product {
    if (input.name.len == 0) return error.InvalidName;
    if (input.price <= 0) return error.InvalidPrice;
    return try self.repo.create(input);
}
```

- Use custom error sets for domain-specific errors
- Use `try` for operations that can fail
- Return descriptive error codes

#### Handling Errors
```zig
// With error message
const result = service.create(input) catch |err| {
    var res = try Response.text(allocator, switch (err) {
        error.InvalidName => "Name cannot be empty",
        error.InvalidPrice => "Price must be greater than 0",
        else => "Error creating product",
    });
    res.status = .bad_request;
    return res;
};

// Ignoring known-safe errors
_ = try someFunction();
```

### HTTP Handlers

#### Handler Signature
```zig
pub fn handler(allocator: std.mem.Allocator, req: *Request) !Response {
    // Handler implementation
}
```

- Always return `!Response` (error union)
- Accept allocator first, then request
- Use `req.param("id")` to get path parameters
- Use `req.bindJson(allocator, Type)` to parse JSON body

#### Response Types
```zig
// JSON response
return try Response.json(allocator, someStruct);

// Text response
var res = try Response.text(allocator, "Error message");
res.status = .bad_request;
return res;
```

### Database Access

#### Pool Usage
```zig
const conn = try self.pool.acquire();
defer self.pool.release(conn);
const result = try spider_pg.query(conn, sql);
// Always defer release and result deinit
defer result.deinit();
```

- Always acquire connection from pool
- Always release in defer
- Always deinit result in defer

#### Query Parameters
```zig
// For parameterized queries
const id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{id});
defer self.allocator.free(id_str);
var result = try spider_pg.queryParams(conn, sql, &.{id_str}, self.allocator);
```

### Project Structure

```
hexagonal/
├── main.zig           # Application entry point
├── router.zig         # HTTP route definitions
├── controller.zig     # HTTP request/response handlers
├── repository.zig     # Data access layer
├── product.zig        # Domain models
├── usecase/
│   └── product.zig   # Business logic (ProductService)
├── build.zig          # Build configuration
└── build.zig.zon      # Package manifest
```

### Hexagonal Architecture Layers

1. **Controller** (`controller.zig`): Handles HTTP requests, parses input, returns responses
2. **Usecase** (`usecase/product.zig`): Contains business logic, validation
3. **Repository** (`repository.zig`): Data access, database operations

### Dependencies

- **spider**: Web framework (from parent project `..`)
- **spider_pg**: PostgreSQL driver (`../spider_pg`)
- **libpq**: System library for PostgreSQL (linked via `link_libc` and `linkSystemLibrary`)

### Environment Variables

- `DATABASE_URL`: PostgreSQL connection string
- `HOST`: Server host (default: "0.0.0.0")
- `PORT`: Server port (default: 8081)

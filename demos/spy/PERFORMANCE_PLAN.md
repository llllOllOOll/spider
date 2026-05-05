# Spider PostgreSQL Driver - Performance Improvement Plan

## Executive Summary

After comprehensive analysis of Spider's PostgreSQL driver at `/home/seven/repos/zig/web/spider/`, three critical performance deficiencies were identified that impact TechEmpower benchmark scores. This plan outlines fixes using Bun's implementation as reference.

### Current Performance (vs Bun):

| Route | Spider (Zig) | Bun (TypeScript) | Difference |
|-------|---------------|-------------------|------------|
| `/db` | 9,733 RPS | 21,886 RPS | ~2.2x slower |
| `/json` | **491,272 RPS** | 38,970 RPS | **12.6x faster** |
| `/queries=20` | 706 RPS | 2,382 RPS (realistic) | ~3.4x slower |

**Conclusion:** Zig itself is extremely fast (proven by `/json`), but the PostgreSQL driver has bottlenecks.

---

## Deficiency #1: No Batch Query Optimization (ANY/array pattern)

### Problem Analysis

**Location:** `src/drivers/pg/pg.zig` (public API), `pg_driver_impl/src/conn.zig`, `pg_driver_impl/src/stmt.zig`

**Current Behavior:**
- For N queries (e.g., `/queries=20`), Spider executes N separate `SELECT` statements
- Each query goes through extended protocol: Parse → Describe → Bind → Execute → Sync (5+ round-trips per query)

**Bun's Approach (from `/home/seven/repos/zig/web/spider/bench/bun/server.ts:62-65`):**
```typescript
const ids = Array.from({ length: n }, () => randomId());
const rows = await sql`
  SELECT id, randomnumber FROM world WHERE id = ANY(${sql.array(ids, "INT")})
`;
```
- Uses `ANY($1)` with a single PostgreSQL array parameter
- Converts 20 queries into **1 query** with array parameter
- Result: 17,076 RPS vs 2,382 RPS for separate queries

### Root Cause

1. **Public API doesn't expose array binding** - The driver supports arrays internally (`pg_driver_impl/src/types.zig:509-798`) but the public API in `src/drivers/pg/pg.zig` has no `sql.array()` equivalent.

2. **No documentation for ANY() pattern** - Users don't know how to optimize batch queries.

### Recommended Fix

#### Step 1: Add `array()` helper to public API
**File:** `src/drivers/pg/pg.zig` (near line 1-20)

```zig
pub fn array(values: anytype, comptime T: type) []const u8 {
    // Convert Zig array/slice to PostgreSQL array literal
    // e.g., [1, 2, 3] → "'{1,2,3}'::int[]"
    // Use types.encodeArray() from pg_driver_impl
}
```

#### Step 2: Document ANY() pattern
**File:** `src/drivers/pg/pg.zig` - Add doc comment:

```zig
/// For batch queries, use ANY() with array parameter:
/// const ids: []i32 = .{ 1, 2, 3 };
/// const rows = try pg.query(World, arena,
///     "SELECT id, randomnumber FROM world WHERE id = ANY($1)",
///     .{pg.array(ids, i32)});
```

#### Step 3: Update benchmark example
**File:** `/home/seven/repos/zig/web/spider/bench/spy/src/main.zig` (queriesHandler)

Change from N separate queries to single batch query using array.

### Expected Impact
- **`/queries=20`**: From ~700 RPS to ~15,000+ RPS (21x improvement)
- **Matches Bun's optimization** for TechEmpower benchmark

---

## Deficiency #2: Extended Query Protocol Overhead

### Problem Analysis

**Location:** `pg_driver_impl/src/conn.zig` lines 382-388 (TODO comment)

**Current Behavior (for exec with parameters):**
1. `Parse` → wait for `ParseComplete`
2. `Describe` → wait for `ParameterDescription` + `RowDescription`  
3. `Bind` → wait for `BindComplete`
4. `Execute` → wait for `DataRows` + `CommandComplete`
5. `Sync` → wait for `ReadyForQuery`

**The TODO acknowledges the problem:**
```zig
// TODO: there's some optimization opportunities here, since we know
// we aren't expecting any result. We don't have to ask PG to DESCRIBE
// the returned columns (there should be none). This is very significant
// as it would remove 1 back-and-forth. We could just:
//    Parse + Bind + Exec + Sync
// Instead of having to do:
//    Parse + Describe + Sync  ... read response ...  Bind + Exec + Sync
```

**Impact:** For `exec()` (INSERT/UPDATE/DELETE), the `Describe` step is unnecessary when we know there's no result rows. This adds one full round-trip to the server.

### Bun's Approach
- Bun's native SQL client likely skips `Describe` for statements that don't return rows
- Or uses simple query protocol for parameter-less queries

### Recommended Fix

**File:** `pg_driver_impl/src/conn.zig` `exec()` function (lines 356-414)

```zig
pub fn exec(self: *Conn, sql: []const u8, values: anytype) !?i64 {
    if (values.len == 0) {
        // Simple query protocol - no round-trip overhead
        const simple_query = proto.Query{ .sql = sql };
        try simple_query.write(buf);
        // Read CommandComplete + ReadyForQuery (1 round-trip)
        // ...
    } else {
        // For exec (no result expected), skip Describe:
        // Parse + Bind + Execute + Sync (no Describe)
        const stmt = try self.prepare(sql, null);  // Don't request Describe
        defer stmt.deinit();
        
        // Bind parameters
        try stmt.bind(values);
        
        // Execute (no result expected)
        const affected = try stmt.exec();
        
        // Sync
        // ...
        return affected;
    }
}
```

**Also fix in `queryOpts()` (lines 246-314):**
- Add parameter: `expect_result: bool = true`
- When `expect_result == false`, skip the `Describe` step

### Expected Impact
- **`/db` route**: ~25-30% faster exec operations
- **`exec()` calls**: From 5 round-trips to 4 round-trips per query

---

## Deficiency #3: O(n*m) Column Name Matching Per Row

### Problem Analysis

**Location:** 
- `pg_driver_impl/src/result.zig` lines 134-141 (`columnIndex()`)
- `src/drivers/pg/pg.zig` lines 155-176 (`mapRow()`)

**Current Behavior:**
```zig
// Called for EACH field in the target struct
pub fn columnIndex(self: *const Result, column_name: []const u8) ?usize {
    for (self.column_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, column_name)) {  // O(n) string comparison!
            return i;
        }
    }
    return null;
}
```

**In `mapRow()` (pg.zig lines 155-176):**
```zig
fn mapRow(comptime T: type, result: *pg_lib.Result, row: pg_lib.Row, allocator: std.mem.Allocator) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        var col_idx: ?usize = null;
        // ANOTHER O(n*m) loop! For EACH field, loop through ALL column names
        for (result.column_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, field.name)) {
                col_idx = i;
                break;
            }
        }
        // ...
    }
    return item;
}
```

**Complexity:** For a query with `m` columns and mapping to a struct with `n` fields:
- Current: **O(n * m)** string comparisons per row
- Example: 10 fields × 10 columns = 100 string comparisons per row

### Bun's Approach
- Bun likely uses **numeric column indices** (positional access)
- Or builds a **hash map** once: `column_name → index`

### Recommended Fix

#### Step 1: Precompute column index map after receiving RowDescription

**File:** `pg_driver_impl/src/result.zig` (lines 85-131)

Add to `State` struct:
```zig
pub const State = struct {
    column_names: [][]const u8,
    oids: []u32,
    name_to_index: std.StringHashMapUnmanaged(usize),  // ADD THIS
    // ...
};
```

After receiving `RowDescription`, build the map once:
```zig
pub fn from(self: *State, number_of_columns: u16, data: []const u8, allocator: ?Allocator) !void {
    // ... existing code ...
    
    // Build name-to-index map
    if (allocator) |a| {
        try self.name_to_index.clearAndFree(a);
        for (self.column_names[0..number_of_columns], 0..) |name, i| {
            try self.name_to_index.put(a, name, i);
        }
    }
}
```

#### Step 2: Fast lookup using hash map

```zig
pub fn columnIndex(self: *const Result, column_name: []const u8) ?usize {
    if (self._name_to_index.get(column_name)) |idx| {
        return idx;
    }
    return null;
}
```

#### Step 3: Use ordinal access by default

In `pg.zig` `mapRow()`:
```zig
fn mapRow(comptime T: type, result: *pg_lib.Result, row: pg_lib.Row, allocator: std.mem.Allocator) !T {
    var item: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        // Try ordinal access first (O(1))
        const col_idx = if (i < result.column_names.len) i else 
            // Fall back to name-based lookup
            result.columnIndex(field.name) orelse return error.ColumnNotFound;
        
        @field(item, field.name) = try row.get(field.type, col_idx, allocator);
    }
    return item;
}
```

### Expected Impact
- **For structs with many fields:** 2-10x faster mapping depending on dimensions
- **Example:** 20-field struct × 20-column query: From 400 string comparisons per row to ~20 (ordinal) + hash map fallback

---

## Implementation Priority for TechEmpower Benchmark

### Phase 1: High Impact (Do First)
1. **Deficiency #1** - Implement `array()` helper and ANY() pattern
   - Expected: 21x improvement for `/queries=20`
   - Files: `src/drivers/pg/pg.zig`, `bench/spy/src/main.zig`

2. **Deficiency #3** - Fix O(n*m) column matching
   - Expected: 2-10x faster struct mapping
   - Files: `pg_driver_impl/src/result.zig`, `src/drivers/pg/pg.zig`

### Phase 2: Medium Impact
3. **Deficiency #2** - Skip Describe for exec queries
   - Expected: 25-30% faster exec operations
   - Files: `pg_driver_impl/src/conn.zig`

### Phase 3: Low Impact (Nice to Have)
4. **Connection pool improvements** - Lock-free ring buffer
   - Expected: Better concurrency under high load
   - File: `pg_driver_impl/src/pool.zig`

5. **Increase default pool size** - From 10 to 16 (match Bun)
   - File: `pg_driver_impl/src/pool.zig` line 32

---

## Files to Modify (Summary)

| Deficiency | Primary Files | Secondary Files |
|------------|-----------------|-------------------|
| #1: Batch optimization | `src/drivers/pg/pg.zig` | `pg_driver_impl/src/types.zig`, `bench/spy/src/main.zig` |
| #2: Protocol overhead | `pg_driver_impl/src/conn.zig` | `pg_driver_impl/src/stmt.zig` |
| #3: Column matching | `pg_driver_impl/src/result.zig` | `src/drivers/pg/pg.zig` |
| Pool improvements | `pg_driver_impl/src/pool.zig` | - |

---

## Testing Strategy

After each fix:
1. **Unit tests**: Test `array()` helper with various types
2. **Integration tests**: Verify ANY() pattern works correctly
3. **Benchmark comparison**: Run `wrk` against `/db` and `/queries=20`
4. **Regression tests**: Ensure existing functionality still works

### Benchmark Targets (after fixes):
- `/db`: From 9,733 RPS → **15,000+ RPS** (approaching Bun's 21,886)
- `/queries=20`: From 706 RPS → **15,000+ RPS** (matching Bun's batch optimization)
- `/json`: Maintain **491,272 RPS** (already excellent)

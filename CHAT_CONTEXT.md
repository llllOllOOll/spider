# Spider Project Chat Context

## Project Location
`/home/seven/repos/zig/web/spider`

## Session: Feb 19, 2026 - Concurrency Experiments

### What We Did

1. **Analyzed current architecture**
   - Thread-per-connection with Io.Group + concurrent
   - Each connection uses a shared GPA (GeneralPurposeAllocator)
   - ArenaAllocator per connection, reset between requests

2. **Benchmarked baseline (Io.Group + concurrent)**
   ```
   100 connections: 616K RPS, 253μs latency
   400 connections: 502K RPS, 1.02ms latency
   ```

3. **Investigated httpz memory strategy**
   - Uses thread pool (32 threads) with bounded queue
   - Pre-allocated connection pool (64 connections)
   - Two arenas per connection: conn_arena (persistent) + req_arena (reset with retain)
   - Buffer pool for large requests (64KB × 16)

4. **Attempted Thread Pool Implementation**
   - Created `src/thread_pool.zig` with:
     - 8 worker threads
     - Ring buffer queue (1024 slots)
     - Per-worker arenas
   - Multiple failures:
     - First attempt: Segfault - workers not waking up
     - Second attempt: Used Io.Condition/Mutex - segfault on startup
     - Root cause: Dangling pointer (router on stack)
     - Fixed pointer: Still couldn't wake workers
   - **Conclusion**: Thread pool approach doesn't work without proper async integration

5. **Tested explicit IoUring**
   - Found that default `init.io` is Threaded (POSIX), NOT io_uring
   - Explicit IoUring init fails with NetworkDown error
   - The explicit io_uring requires running the event loop properly

### Key Findings

1. **Current Implementation Uses Threaded Io, NOT io_uring**
   - `std.process.Init.io` defaults to Threaded (POSIX syscalls)
   - io_uring requires explicit initialization and event loop

2. **GPA Contention is the Bottleneck**
   - All connections share the same GPA
   - Arena reset still touches GPA
   - No per-thread isolation

3. **Io.Group.concurrent Works**
   - Simple, functional concurrency model
   - 616K RPS at 100 connections
   - 502K RPS at 400 connections

### Current Benchmarks (ReleaseFast)

| Configuration | 100 conn RPS | 400 conn RPS |
|--------------|-------------|---------------|
| Io.Group + concurrent | 616,066 | 502,648 |

### Files Changed

- `src/server.zig` - Main server (currently Io.Group implementation)
- Branch: `feature/true-thread-pool` - Has thread pool attempts (doesn't work)
- Branch: `feature/httpz-inspired-thread-pool` - Has dual arena experiments

### Lessons Learned

1. Zig 0.16's std.Thread.Semaphore doesn't exist - use std.Io.Condition
2. Thread pools in Zig need careful synchronization (not just spinlocks)
3. The default Io is Threaded, not io_uring
4. io_uring requires proper async event loop setup

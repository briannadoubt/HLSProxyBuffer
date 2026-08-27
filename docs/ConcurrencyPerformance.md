# Concurrency and Performance

HLSProxyBuffer uses concurrency primitives according to the lifetime and shape of the protected work. This keeps the public architecture understandable while avoiding unnecessary actor hops in the request path.

## Design

- Public cache, catalog, scheduler, and playlist state remains actor-isolated. These components own asynchronous workflows and expose APIs where suspension is already expected.
- CPU-bound manifest parsing and rewriting runs in `@concurrent` async functions. A player actor can initiate this work without pinning the actor while a large manifest is processed.
- Disk-cache operations remain actor-isolated for deterministic LRU and byte-budget mutations, but the actor uses a dedicated serial executor. Blocking `FileManager` and mapped-file operations therefore do not occupy Swift's shared concurrency executor.
- Private per-request coordination uses `OSAllocatedUnfairLock` for short, non-suspending mutations. The lock is never held while awaiting a segment fetch. This is used only for the in-flight request map and first-delivery set, where an actor hop would cost more than the protected operation.

The package continues to support iOS 17, macOS 14, Mac Catalyst 17, tvOS 17, and visionOS 1. `Synchronization.Mutex` would require newer deployment targets, so it is not used for these compatibility-sensitive internals.

## Benchmarking

Run the release benchmark on an otherwise idle machine:

```sh
make benchmark
```

It reports operations per second for memory-cache hits, concurrent memory-cache hits, catalog lookups, cached segment requests, and concurrent cached segment requests. Compare repeated runs on the same hardware and toolchain; absolute values are intentionally not treated as API guarantees.

Performance-sensitive changes should also pass:

```sh
swift test --sanitize=thread --skip '.*PerformanceTests'
swift build -c release -Xswiftc -warnings-as-errors
```

Thread Sanitizer verifies the lock-backed request coordination, while the release build catches concurrency and availability warnings under the package's supported platform declarations.
The ordinary `swift test` gate runs the performance cases. They are excluded only
from the sanitizer process because XCTest's `measure` machinery crashes inside
XCTestCore when instrumented by Thread Sanitizer on Xcode 26.6; timing assertions
would not be meaningful under sanitizer instrumentation in any case.

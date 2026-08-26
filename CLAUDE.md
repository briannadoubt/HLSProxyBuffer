# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build and test
swift build
swift test

# Run a single test
swift test --filter <TestCaseName>

# CI script (runs host tests + iOS/tvOS simulator builds if available)
./Scripts/run-ci.sh

# Release build for profiling
swift build -c release

# Refresh dependencies after toolchain upgrades
swift package resolve
```

## Architecture Overview

HLSProxyBuffer is an LL-HLS-aware proxy that intercepts HLS streams, rewrites playlists to localhost URLs, and serves cached segments to AVPlayer for deterministic playback.

### Data Flow

```
Remote HLS → HLSManifestFetcher → HLSParser → HLSRewriter
           → SegmentPrefetchScheduler → HLSSegmentFetcher & Cache
           → LocalProxy (NWListener) → AVPlayer via ProxyPlayerKit
```

### Module Structure

- **HLSCore**: Pure logic - manifest parsing (`HLSParser`), URL rewriting (`HLSRewriter`), LRU segment cache (`HLSSegmentCache`), prefetch scheduling (`SegmentPrefetchScheduler`), adaptive bitrate control (`AdaptiveVariantController`), and throughput estimation
- **LocalProxy**: `NWListener`-based HTTP server with `ProxyRouter` dispatching to handlers (`PlaylistHandler`, `SegmentHandler`, `AuxiliaryAssetHandler`). Exposes `/debug/status` and `/metrics` endpoints
- **ProxyPlayerKit**: High-level orchestration via `ProxyHLSPlayer` (annotated with `@Observable` and `@MainActor`), SwiftUI views (`ProxyVideoView`), configuration structs, and diagnostics hooks

### Key Patterns

- Dependencies are injected (URL sessions, schedulers, routers) for testability
- `ProxyHLSPlayer` uses Swift's Observation framework - store in `@State` and access via `@Bindable`
- All types are `Sendable`-annotated; async paths use `async/await` throughout
- Namespace-based segment catalogs allow multiple renditions (audio/subtitles) alongside primary video

## Coding Conventions

- Swift 6 toolchain; 4-space indentation; prefer `struct`/`final` when ownership is clear
- Use `async/await`, `Sendable`, and `@MainActor` as seen in existing code
- Avoid force unwraps; use early `guard` exits
- Keep public APIs documented with Swift doc comments, especially in `ProxyPlayerKit`

## Testing

- Place tests under `Tests/<Module>Tests` mirroring source structure
- Use descriptive names (`testEnforcesByteRangeLength`, `testMetricsCaptured`)
- For async tests, combine expectations with `await fulfillment`; prefer stubbed URL protocols

## Documentation

When behavior changes (buffer policies, public APIs, proxy semantics), update files in `docs/` or `specs/`.

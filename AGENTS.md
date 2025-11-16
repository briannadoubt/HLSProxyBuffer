# Repository Guidelines

## Project Structure & Module Organization
- `Sources/HLSCore`: Core HLS parsing, rewriting, caching, and fetcher logic; keep types pure and deterministic.
- `Sources/LocalProxy`: Lightweight HTTP proxy server (NWListener) that serves rewritten playlists and cached segments to AVPlayer.
- `Sources/ProxyPlayerKit`: High-level API that wires buffering policies into UIKit/SwiftUI/AppKit players.
- `Tests/<Target>Tests`: XCTest suites mirroring each module; shared helpers live alongside the target (e.g., `Tests/HLSCoreTests/TestUtilities.swift`).
- `Scripts/run-ci.sh` and `Makefile`: CI harness and shortcuts; `ci.log`, `docs/`, and `specs/` capture reference runs and design notes—update them when behavior changes.

## Architecture Snapshot
- Playback path: Remote HLS → `HLSManifestFetcher` → `HLSParser` → `HLSRewriter` → segment prefetch scheduler → `HLSSegmentFetcher`/cache → `LocalProxy` HTTP server → AVPlayer consuming local URLs.
- Inject dependencies (URL sessions, schedulers, routers) for testability; avoid global state beyond caches and explicit configuration structs.

## Build, Test, and Development Commands
- `swift package resolve`: Refresh dependencies after toolchain upgrades.
- `swift test` or `make test`: Run SwiftPM unit/integration tests on the host.
- `make ci`: Executes host tests, then `Scripts/run-ci.sh` attempts iOS/tvOS simulator builds and smoke tests (skips gracefully if sims are missing).
- `swift build -c release`: Produce optimized artifacts for profiling or performance checks.

## Coding Style & Naming Conventions
- Swift 6 toolchain; 4-space indentation; prefer `struct`/`final` when ownership is clear.
- `UpperCamelCase` for types/protocols, `lowerCamelCase` for functions/properties, `SCREAMING_SNAKE_CASE` only for static constants modeling env/config keys.
- Favor `async/await`, `Sendable`, and `@MainActor` annotations as used across the code; avoid force unwraps and prefer early `guard` exits.
- Keep public APIs small and documented with Swift doc comments, especially in `ProxyPlayerKit`.

## Testing Guidelines
- Use XCTest; place new cases under `Tests/<Module>Tests` (e.g., `Tests/LocalProxyTests/ProxyServerTests.swift`) to mirror targets.
- Name tests descriptively (`testEnforcesByteRangeLength`, `testMetricsCaptured`); reuse shared fixtures/helpers instead of ad-hoc mocks.
- For async paths, combine expectations with `await fulfillment` to prevent flakiness; prefer stubbed URL protocols and deterministic data.
- While iterating, `swift test --filter <CaseName>` speeds feedback; ensure `make ci` passes before opening a PR.

## Commit & Pull Request Guidelines
- Commit subjects in present-tense imperative (“Add proxy metrics hook”); keep changes scoped and staged logically.
- When touching public APIs, playlists, or proxy behaviors, add notes to `docs/` or `specs/` and mention migration needs.
- PRs should include a short summary, tests executed, and any simulator/device requirements; attach screenshots only when UI is affected.

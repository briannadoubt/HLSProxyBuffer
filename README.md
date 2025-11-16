# HLSProxyBuffer

A modular Swift package for deterministic HLS playback. Remote manifests are fetched, rewritten, and served through a lightweight local proxy so AVPlayer consumes only localhost URLs. The repo is split into three modules:

- `Sources/HLSCore`: Manifest/segment parsing, rewrite policies, caching, and the prefetch scheduler.
- `Sources/LocalProxy`: NWListener-based HTTP server that exposes playlists, segment bytes, and diagnostics endpoints.
- `Sources/ProxyPlayerKit`: High-level ObservableObject + SwiftUI surfaces that wire the core/proxy stack into AVPlayer-driven apps.

## Getting Started

```sh
swift build
swift test
```

While iterating on simulator/device behavior, run the bundled CI script:

```sh
./Scripts/run-ci.sh
```

This script executes SwiftPM tests and, when Xcode simulators are available, attempts basic iOS/tvOS builds to ensure the package schemes still compile.

## Repo Layout

```
Sources/
  HLSCore/            # Parsing, rewrite, cache, scheduler
  LocalProxy/         # HTTP server + handlers
  ProxyPlayerKit/     # Player orchestration + SwiftUI wrappers
Tests/
  HLSCoreTests/
  LocalProxyTests/
  ProxyPlayerKitTests/
Scripts/run-ci.sh      # Host + simulator smoke tests
specs/                 # design docs + implementation tasks
```

Additional design docs live under `docs/` and `specs/`. The SwiftUI preview (`ProxyVideoView`) can be used as a quick manual demo inside Xcode; there is no standalone app target inside this package.

## Contributing

1. Keep modules decoupled—only `ProxyPlayerKit` should depend on `HLSCore` + `LocalProxy`.
2. Prefer `swift test --filter <Case>` while iterating; run `make test` or `./Scripts/run-ci.sh` before opening a PR.
3. Update `docs/` or `specs/` when behavior changes (buffer policies, public APIs, proxy semantics).
4. Ensure new features expose deterministic logging so they are observable via `/debug/status`.

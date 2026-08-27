# HLS Proxy Buffer Engine – Swift Package Specification

## Overview

This Swift package provides a deterministic, high‑performance HLS playback pipeline that replaces AVPlayer's default network buffering heuristics with a local proxy buffer. The package allows the application to fully control how HLS manifests are interpreted, how segments are buffered, rewritten, and served to AVPlayer, and how playback behavior is tuned for short‑form, precise, low‑latency, or quality‑locked video streaming.

The system preserves AVFoundation's decoding, rendering, HDR, AirPlay, captions, and PiP features while giving the developer CDN‑level control over the network layer.

---

## High‑Level Architecture

```
Remote HLS Stream
    ↓
HLSManifestFetcher
    ↓
HLSParser
    ↓
HLSRewriter (quality control, URL rewriting, buffering policy)
    ↓
Segment Prefetch Scheduler
    ↓
HLSSegmentFetcher + HLSSegmentCache
    ↓
Local HTTP Proxy Server (NWListener)
    ↓
AVPlayer(url: localProxyPlaylist)
```

The local proxy behaves like a high‑performance CDN in front of AVPlayer. All segment and playlist requests go through the proxy, which serves rewritten playlists and cached segments.

---

## Package Targets

### `HLSCore`

Core logic for parsing, fetching, rewriting, and caching HLS data.

### `LocalProxy`

Small HTTP server responsible for serving playlists and segment data to AVPlayer.

### `ProxyPlayerKit`

High‑level interface for SwiftUI / UIKit / AppKit to initialize playback session, manage buffering policies, and expose AVPlayer.

---

## Detailed Component Specifications

### 1. `HLSManifestFetcher`

Responsible for downloading the master playlist or media playlist.

**Responsibilities:**

* Fetch remote `.m3u8` over HTTPS.
* Expose raw UTF‑8 string.

**API:**

* `func fetchManifest(from url: URL) async throws -> String`

---

### 2. `HLSParser`

Converts raw playlist text into strongly typed objects.

**Outputs:**

* `HLSManifest`
* `VariantPlaylist`
* `MediaPlaylist`
* `[HLSSegment]`

**Parser capabilities:**

* Parse master, media, encryption, alternate-rendition, byte-range, and LL-HLS tags.
* Resolve relative URLs and `EXT-X-DEFINE` variables.
* Preserve playlist/segment metadata and unknown attributes across rewrites.
* Reject malformed headers, ranges, and dangling URI-bearing tags.

---

### 3. `HLSRewriter`

Controls how the manifest is altered before being served to AVPlayer.

**Capabilities:**

* Flatten to a single variant.
* Lock to a chosen quality profile.
* Rewrite URLs to local proxy form (e.g., `http://127.0.0.1:PORT/...`).
* Hide segments until buffered.
* Inject artificial bandwidth values.
* Preserve encryption transitions, maps, metadata, parts, hints, and delta state.

**Policies:**

* Quality lock policy.
* Strict buffering policy (N seconds ahead before play).
* Rewrite strategy for LL-HLS if used.

---

### 4. `HLSSegmentFetcher`

Fetches `.ts` or `.m4s` segments from the remote CDN.

**Responsibilities:**

* HTTPS download of video segments.
* Work with a scheduler to maintain required buffer depth.
* On-disk caching optional.

**API:**

* `func fetchSegment(from url: URL) async throws -> Data`

---

### 5. `HLSSegmentCache`

Stores fetched segments for serving through the proxy.

**Requirements:**

* Byte-bounded in-memory LRU cache.
* Optional byte-bounded, per-player disk cache with atomic writes.
* Actor isolation and URL/range-aware cache identities.

**API:**

* `func store(data: Data, forKey key: String)`
* `func fetch(key: String) -> Data?`

---

### 6. Segment Prefetch Scheduler

Runs ahead of playback, downloading segments before AVPlayer requests them.

**Goals:**

* Maintain target buffer (e.g., 4–10 seconds for short-form video).
* Prioritize upcoming segments.
* Handle multiple next videos (feed-style preloading).

**Scheduling policies:**

* Time-based buffer depth.
* Segment-count-based buffer.
* Skip or de-prioritize distant segments.

---

### 7. `LocalProxy` (HTTP Server)

Small, dependency-free (Network framework) HTTP server.

**Responsibilities:**

* Serve rewritten playlist to AVPlayer.
* Serve cached segment bytes.
* Log incoming requests for debugging.

**Request routes:**

* `GET|HEAD /playlist.m3u8` (returns rewritten master playlist)
* `GET|HEAD /variants/*` and `/renditions/*` (rewritten media playlists)
* `GET|HEAD /segments/{id}` (cached or single-flight origin data, including ranges)
* `GET|HEAD /assets/*` (registered keys, audio, subtitles, and metadata)

**Implementation:**

* Use `NWListener` and `NWConnection`.
* Incrementally parse size-bounded HTTP requests.
* Send persistent HTTP/1.1 responses with correct range and HEAD semantics.

---

### 8. `ProxyPlayerKit`

High-level manager that coordinates the entire pipeline.

**Responsibilities:**

* Boot the local proxy server.
* Fetch + parse + rewrite the manifest.
* Initiate prefetching.
* Expose an `AVPlayer` preconfigured with proxy playlist URL.

**API:**

* `@Observable @MainActor final class ProxyHLSPlayer`
* `var player: AVPlayer? { get }`
* `func load(url: URL, quality: QualityProfile) async`
* `func play()`
* `func pause()`

**SwiftUI Example:**

```
ProxyVideoView(url: remoteURL)
```

Uses `VideoPlayer` or custom player view.

---

## Cross-Platform Considerations

### Shared across iOS, macOS, tvOS, visionOS

* All Network framework components work.
* AVPlayer unified behavior.
* SwiftUI integration identical.

### macOS-specific

* Use `NSViewRepresentable` if a custom Metal view is desired.

### visionOS

* Works as a 2D layer or volumetric window.

---

## Performance Goals

* Keep proxy overhead small and measure it on target hardware; do not infer an
  absolute latency guarantee from host unit tests.
* Coalesce duplicate origin requests and prefetch concurrently within a bound.
* Avoid quality oscillation with locks, compatibility filtering, hysteresis,
  and minimum switch intervals.
* Bound memory and disk residency in bytes for short-form and live content.

---

## Future Extensions

* Offline download ownership and expiration policy.
* More content-steering strategies for multi-pathway masters.
* Device-specific performance baselines and long-duration soak tests.
* Additional CMAF/HDR/interstitial fixture coverage.

---

## Deliverables for MVP

* Manifest fetch → parse → rewrite pipeline.
* Working local proxy server.
* Segment prefetching + caching.
* AVPlayer playback using local playlist.
* SwiftUI wrapper for immediate app integration.

---

## Success Criteria

* AVPlayer always reads from local proxy.
* Quality does not oscillate unless policy allows.
* Buffering behavior is fully deterministic.
* Works identically across iOS/macOS/tvOS/visionOS.
* Able to preload entire short video before playback.

---

---

# Implementation Blueprint (Extended Specification)

## Package Structure

```
SwiftHLSProxy/
 ├─ Package.swift
 ├─ Sources/
 │   ├─ HLSCore/
 │   │   ├─ Manifest/
 │   │   │   ├─ HLSManifest.swift
 │   │   │   ├─ HLSManifestFetcher.swift
 │   │   │   ├─ HLSParser.swift
 │   │   │   ├─ HLSRewriter.swift
 │   │   ├─ Segments/
 │   │   │   ├─ HLSSegment.swift
 │   │   │   ├─ HLSSegmentFetcher.swift
 │   │   │   ├─ HLSSegmentCache.swift
 │   │   │   ├─ SegmentPrefetchScheduler.swift
 │   │   └─ Utilities/
 │   │       ├─ URLUtilities.swift
 │   │       ├─ Logging.swift
 │   │       ├─ Threading.swift
 │   │
 │   ├─ LocalProxy/
 │   │   ├─ ProxyServer.swift
 │   │   ├─ ProxyConnection.swift
 │   │   ├─ HTTPRequest.swift
 │   │   ├─ HTTPResponse.swift
 │   │   ├─ ProxyRouter.swift
 │   │   ├─ PlaylistHandler.swift
 │   │   ├─ SegmentHandler.swift
 │   │
 │   ├─ ProxyPlayerKit/
 │       ├─ ProxyHLSPlayer.swift
 │       ├─ ProxyURLBuilder.swift
 │       ├─ PlayerState.swift
 │       ├─ ProxyPlayerLogger.swift
 │       ├─ SwiftUI/ProxyVideoView.swift
 │
 └─ Tests/
     ├─ HLSCoreTests/
     ├─ LocalProxyTests/
     ├─ ProxyPlayerKitTests/
```

---

## Core Protocols

**HLSManifestSource**

```
protocol HLSManifestSource {
    func fetchManifest() async throws -> String
}
```

**SegmentSource**

```
protocol SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data
}
```

**Caching**

```
protocol Caching {
    func get(_ key: String) -> Data?
    func put(_ data: Data, for key: String)
}
```

---

## System Flow

### Startup

1. Start `ProxyServer`.
2. Fetch remote manifest.
3. Parse manifest.
4. Rewrite manifest.
5. Store rewritten playlist.
6. Start prefetch scheduler.
7. Initialize AVPlayer with proxy URL.

### Runtime

1. AVPlayer requests playlist → served locally.
2. AVPlayer requests segment → served from cache.
3. Cache miss triggers background fetch.
4. Prefetcher stays ahead.
5. Rewriter may update manifests dynamically.

### Shutdown

1. Stop server.
2. Clear caches.
3. Release AVPlayer.

---

## Task Breakdown

### Manifest Layer

* Implement manifest fetcher.
* Build HLS parser.
* Create manifest rewriter.
* Inject proxy URLs.
* Add unit tests.

### Segment Layer

* Implement segment fetcher.
* Implement thread-safe cache.
* Build prefetch scheduler.
* Add caching tests.

### Local Proxy

* Implement server using Network framework.
* Build HTTP parser.
* Build router and handlers.
* Handle playlist + segment routes.

### PlayerKit

* High-level controller for initializing playback.
* Expose AVPlayer via the Observation framework.
* Provide SwiftUI view wrapper.
* Provide buffer + quality reporting.

### Cross-Platform

* Validate NWListener on all Apple platforms.
* Ensure AVPlayer behavior consistent.

---

## Developer Tools (Debug)

Add `/debug/status` endpoint with JSON diagnostics:

```
{
  "buffered_segments": 12,
  "latency_ms": 2,
  "quality": "1080p",
  "prefetch_depth_seconds": 6.4,
  "active_requests": 3
}
```

---

## MVP Requirements

* Playlist rewriting.
* Proxy serving.
* Prefetching.
* Local segment caching.
* AVPlayer playback from proxy.
* SwiftUI view for integration.

---

## Finalization

This blueprint defines the required modules, APIs, file structure, runtime behavior, and development tasks necessary for building the custom HLS proxy buffer engine.

End of specification.

# Configuration presets

## Automatic feed policies

`FeedPlaybackPolicy` is the application-facing policy for the automatic feed
engine. It composes the lower-level player presets below with typed prefetch,
budget, concurrency, eviction, network, retry, looping, and low-power groups.
Start from a workload preset and replace only the groups your product has
measured reason to change:

```swift
let base = FeedPlaybackPolicy.preset(.shortFormFeed)
var budget = base.budget
budget.diskCacheBytes = 1_024 * 1_024 * 1_024

let policy = try base.applying(.init(budget: budget))
```

| Feed preset | Intended behavior |
| --- | --- |
| `shortFormFeed` | Two items ahead, one behind, shallow leading segments, focused-item looping, three pooled players |
| `pagedFeed` | Symmetric previous/next preparation for discrete page snaps |
| `continuousWindowedFeed` | A larger velocity-directed forward window with strict item/byte/task bounds |
| `longForm` | One focused item, deep segment buffering, persistent disk reuse |
| `live` | LL-HLS defaults, one predicted destination, small expiring memory state, no disk cache |
| `offlineFirst` | Large persistent disk reuse, connectivity waiting, and no expensive-network access by default |

Every preset passes `validate()`. `applying(_:)` replaces whole typed groups and
validates before returning; when applying several replacements, later non-`nil`
groups win. Invalid counts, budgets, cache/eviction combinations, buffer times,
concurrency, and low-power caps return `FeedPlaybackPolicy.ValidationError`
with stable issues.

Call `adaptedForLowPowerMode(true)` when the host enters low-power mode. It
reduces only speculative item/segment work and preparation/fetch/player
concurrency. The focused-item reservation, focused buffer target, network
access policy, retry semantics, and cache contents remain intact.

`makePlanningLimits()` feeds the pure planner. `makeProxyPlayerConfiguration()`
maps the same policy into the existing validated HLS player/network/retry/cache
types, so there is no second transport or cache configuration stack.

## Player-level presets

`ProxyPlayerConfiguration.preset(_:)` provides four internally validated
starting points. A preset is intentionally not an automatic tuner: copy it,
adjust the public policy values for the stream and device class, call
`validated()`, and use bounded production telemetry to evaluate the result.

```swift
var configuration = ProxyPlayerConfiguration.preset(.lowLatencyLive)
configuration.cachePolicy.memoryCapacityBytes = 24 * 1_024 * 1_024
configuration = try configuration.validated()

let player = ProxyHLSPlayer(configuration: configuration)
```

| Preset | Starting bias | Important defaults |
| --- | --- | --- |
| `lowBandwidth` | Conserve concurrency and avoid optimistic upgrades | 3 prefetched segments, 2 origin connections, 8 MiB memory cache, 90-second TTL, conservative ABR headroom |
| `highThroughput` | Sustain high-bitrate streams on capable networks | 20-second target buffer, 12 prefetched segments and connections, 128 MiB memory cache, faster ABR sampling |
| `lowLatencyLive` | Stay near the live edge with LL-HLS features coherent | 2-second target, part buffering, blocking reloads, delta updates, preload hints, short retry caps, no disk cache |
| `videoOnDemand` | Favor smooth long-form playback and reuse | 30-second hidden startup buffer, 12 prefetched segments, 64 MiB memory plus 2 GiB disk budget, no TTL |

The values are workload assumptions, not universal recommendations. Segment
duration, part duration, encoding ladder, CDN response time, device memory,
network cost, and audience geography can all move the right operating point.
Track segment latency and retry outcomes, cache hit/eviction ratios, buffer
depth, live-edge distance, and variant switch reasons before changing one
policy at a time.

## Validation

All policy structs remain mutable so applications can adapt a preset. Call
`validationIssues`, `validate()`, or `validated()` after mutation. Validation
catches non-finite or impossible buffer, cache, ABR, and LL-HLS combinations;
in particular, the runtime low-latency policy and playlist rewrite options must
be enabled together, and blocking reloads must agree on both sides.

Validation does not probe an origin, inspect a manifest, reserve memory, or
promise latency. It establishes local configuration consistency; production
telemetry and real-device playback establish fitness for a particular stream.

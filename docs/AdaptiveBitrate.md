# Adaptive Bitrate Switching

The proxy now monitors segment throughput and buffer health to dynamically switch
between master playlist variants without reinitialising the underlying `AVPlayer`.
This keeps playback resilient under fluctuating network conditions while still
honouring manual quality locks.

## Configuration

`ProxyPlayerConfiguration` gained an `abrPolicy` struct that controls how the
adaptive controller behaves. The defaults enable ABR in `.automatic` mode with
conservative thresholds:

| Field | Description |
| --- | --- |
| `isEnabled` | Global kill‑switch; set to `false` to keep the legacy "stick to the first variant" behaviour. |
| `estimatorWindow` | EWMA window (in samples) used by the throughput estimator. Larger windows smooth more but react slower. |
| `minimumBitrateRatio` | If measured throughput drops below `ratio * current bitrate` (with hysteresis) the controller recommends a downgrade. |
| `maximumBitrateRatio` | Throughput must exceed `ratio * candidate bitrate` (plus hysteresis) before upgrading. |
| `hysteresisPercent` | Cushion that keeps the controller from bouncing between adjacent variants. |
| `minimumSwitchInterval` | Cool‑down in seconds between switches (applies to both up and down decisions). |
| `failureDowngradeThreshold` | Number of consecutive segment fetch failures that immediately trigger a downgrade to the next lower variant. |

ABR is automatically bypassed when `qualityPolicy` is `.locked` or when
`abrPolicy.isEnabled` is `false`.

Automatic candidates are restricted to the selected variant's audio, subtitle,
closed-caption, and codec families. This prevents an apparently harmless
bitrate switch from changing language groups or decoder requirements. Variant
switches preserve cached media and align the new live playlist to the observed
playhead; a live rollback or discontinuity-sequence change clears stale cache
state.

Finalized VOD uses a separate immutable proxy playlist and segment namespace for
each compatible rendition. Small rendition manifests are resolved sequentially
before initial publication; segment bodies are still fetched on demand through
the shared bounded cache. Previously published playlists and segment URLs stay
valid for looping, rewinding, and pooled-player revisits.

For these VOD masters, controller decisions update AVFoundation's
[`preferredPeakBitRate`](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredpeakbitrate).
AVFoundation performs the actual decoder/rendition transition without replacing
the player item. The preference is not a hard network-byte cap or proof that a
particular rendition was displayed. Live playlists retain the existing proxy
controller path. Manual quality locks still publish only their selected variant.
Immutable VOD publication follows
[RFC 8216 section 6.2.1](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.2.1).

## Diagnostics

- `ProxyPlayerDiagnostics` exposes `onQualityChanged` for the controller's
  selected target; this is not a decoded-frame rendition measurement.
- `/debug/status` now includes `active_variant_name`, `variant_bitrate`,
  `throughput_bps`, and the last ABR decision reason.

These additions should make it easier to tune the policy for each deployment and
to verify that the controller behaves as expected under different network
conditions.

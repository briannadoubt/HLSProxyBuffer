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

## Diagnostics

- `ProxyPlayerDiagnostics` exposes `onQualityChanged` so apps can log or surface
  variant switches.
- `/debug/status` now includes `active_variant_name`, `variant_bitrate`,
  `throughput_bps`, and the last ABR decision reason.

These additions should make it easier to tune the policy for each deployment and
to verify that the controller behaves as expected under different network
conditions.

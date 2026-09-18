# Prefetch-depth configuration updates

`ProxyHLSPlayer.updateConfiguration` remains ordered. When the only changed
stored configuration value is `bufferPolicy.maxPrefetchSegments`, it updates
the existing scheduler directly. Its target duration and low-latency part budget
remain unchanged. Existing cache, retry, network sessions, telemetry handlers,
playlist refresher, and adaptation state stay connected without reapplication.

Initialization always applies the complete configuration. Any accompanying
change takes the complete application path. The check normalizes only the depth
and compares the entire configuration, so additional stored configuration fields
cannot silently bypass application. Repeating the current configuration retains
the existing no-op behavior after initialization.

This is a bounded feed-focus optimization, not a measured performance claim.
Device comparison and complete playback qualification are required before
claiming CPU, latency, energy, or memory improvements.

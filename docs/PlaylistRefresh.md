# Playlist Refresh Tuning

The live refresh controller keeps AVPlayer fed with new media sequences by polling the remote playlist while playback is active. Tune its cadence via `ProxyPlayerConfiguration.BufferPolicy`:

- `refreshInterval` – base polling interval in seconds. Default is 2 seconds (or use half the playlist target duration if the stream must be extremely responsive). Lower intervals fetch more frequently but increase CDN load.
- `maxRefreshBackoff` – how far the exponential backoff can stretch after repeated failures. Keep this bounded when serving low-latency streams; higher values reduce traffic during outages.

When the controller detects `#EXT-X-ENDLIST`, it automatically stops refreshing. Diagnostics surface current metrics through `/debug/status`:

```json
{
  "last_playlist_refresh": "2025-05-01T01:23:45.123Z",
  "playlist_refresh_failures": 0,
  "remote_media_sequence": 1724
}
```

Apps can also observe `ProxyPlayerDiagnostics.onPlaylistRefreshed` to record telemetry or react to manifest advances (e.g., scheduling UI updates).

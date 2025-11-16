# FairPlay / DRM Forwarding Strategy

FairPlay-protected streams can ride through the proxy by keeping the license exchange between AVFoundation and the key server untouched while mirroring the `EXT-X-KEY`, `EXT-X-SESSION-KEY`, and `EXT-X-MAP` metadata in rewritten manifests. Keys remain encrypted end-to-end; the proxy never decrypts them.

## Configuring the DRM Policy

`ProxyPlayerConfiguration` exposes a `drmPolicy` with two modes:

- **Passthrough** (default) keeps every key URI untouched so the player talks to the remote SKD/CKC endpoints directly.
- **Proxy** rewrites key URIs to `http://<proxy>/assets/keys/<hash>` where `<hash>` is a deterministic SHA-256 digest of the original URI. This keeps manifests deterministic without leaking the original SKD URL.

```swift
var configuration = ProxyPlayerConfiguration()
configuration.drmPolicy = .proxy
let player = ProxyHLSPlayer(configuration: configuration)
```

## Registering CKCs / Keys

When proxy mode is enabled, register CKCs with `ProxyHLSPlayer.registerAuxiliaryAsset(data:identifier:type:)` using the deterministic identifier helper so manifests and `/assets/keys/...` stay in sync:

```swift
let keyIdentifier = ProxyHLSPlayer.keyIdentifier(forKeyURI: skdURL)
await player.registerAuxiliaryAsset(
    data: ckcData,
    identifier: keyIdentifier,
    type: .keys
)
```

Registered keys are served with `Content-Type: application/octet-stream` and `Cache-Control: private, max-age=0, no-store`, ensuring plaintext CKCs never persist beyond the in-memory `AuxiliaryAssetStore`.

## Observability

- `/debug/status` now exposes a `keys` array showing `method`, `uri_hash`, and whether the key came from `EXT-X-SESSION-KEY` versus a segment-level tag. Only hashes are emitted—never plaintext URIs.
- `ProxyPlayerDiagnostics.onKeyMetadataChanged` fires with the same sanitized metadata so apps can log or alert without touching secrets.
- Existing `/metrics` and scheduler telemetry remain unchanged and never log CKC data.

License acquisition still flows through AVFoundation’s `AVAssetResourceLoaderDelegate`, so your FairPlay handler continues to fetch licenses exactly as it did before enabling the proxy.

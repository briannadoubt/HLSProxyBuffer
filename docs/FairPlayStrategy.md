# FairPlay / DRM Forwarding Strategy

FairPlay-protected streams can ride through the proxy by keeping the license exchange between AVFoundation and the key server untouched while mirroring the `EXT-X-KEY` metadata in the rewritten manifests.

1. **Key URI Passthrough** – `HLSRewriter` will preserve the original FairPlay key URI (or re-map it to `/assets/keys/<id>` if the application wants to cache CKC responses). Keys remain encrypted end-to-end; the proxy never decrypts them.
2. **Application-supplied CKC** – apps may call `ProxyHLSPlayer.registerAuxiliaryAsset` with `type: .keys` to serve cached CKCs via `/assets/keys/...`. This allows offline or low-latency key reuse without bypassing DRM requirements.
3. **License Acquisition** – FairPlay license requests continue to originate from AVFoundation; the proxy simply surfaces the SKD URI so the application’s `AVAssetResourceLoaderDelegate` can handle it.
4. **Telemetry** – use the `/metrics` endpoint plus the scheduler telemetry hook to monitor DRM-protected streams without logging sensitive key material.

This approach keeps the proxy transparent to FairPlay while still allowing deterministic networking, prefetching, and caching of encrypted segments.

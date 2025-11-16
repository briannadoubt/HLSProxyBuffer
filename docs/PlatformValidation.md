# Platform Validation – HLSProxyBuffer

This document captures compatibility expectations for the local proxy, NWListener, and AVPlayer stack across Apple platforms.

| Platform | NWListener | AVPlayer | Notes |
|----------|------------|----------|-------|
| iOS 15+  | ✅ – works out of the box on-device and Simulator. | ✅ – `ProxyVideoView` and `ProxyPlayerViewController` wrap the proxy-fed `AVPlayer`. | Allow local-network entitlement for on-device testing. |
| tvOS 15+ | ✅ – same Network framework surface as iOS. | ✅ – `ProxyPlayerViewController` handles Siri remote play/pause with `onPlayPauseCommand`. | Consider enabling `requiresLinearPlayback` for App Store builds. |
| macOS 12+| ✅ – validated via `swift test` (LocalProxy + AVPlayer integration test). | ✅ – `ProxyPlayerSampleView` uses `VideoPlayer`. | No extra entitlements needed. |
| visionOS 1.0+ | ✅ – Network framework available. | ✅ – `ProxyVideoView` automatically applies `.glassBackgroundEffect()` to blend into volumetric scenes. | Pair with a 2D layer; LL-HLS policies minimize latency in immersive spaces. |

To re-run the automated smoke tests on macOS:

```bash
./Scripts/run-ci.sh
```

For iOS/tvOS/visionOS verification, open the Swift Package in Xcode and run `ProxyPlayerSampleView` (SwiftUI preview) or the generated package scheme against the desired Simulator/device.

# Platform Validation – HLSProxyBuffer

This document captures compatibility expectations for the local proxy, NWListener, and AVPlayer stack across Apple platforms.

| Platform | NWListener | AVPlayer | Notes |
|----------|------------|----------|-------|
| iOS 17+  | ✅ – works out of the box on-device and Simulator. | ✅ – `ProxyVideoView` and `ProxyPlayerViewController` wrap the proxy-fed `AVPlayer`. | Observation-backed `ProxyHLSPlayer` requires iOS 17+; allow local-network entitlement for on-device testing. |
| tvOS 17+ | ✅ – same Network framework surface as iOS. | ✅ – `ProxyPlayerViewController` handles Siri remote play/pause with `onPlayPauseCommand`. | `@Bindable` wrappers rely on the tvOS 17 Observation runtime; consider enabling `requiresLinearPlayback` for App Store builds. |
| macOS 14+| ✅ – validated via `swift test` (LocalProxy + AVPlayer integration test). | ✅ – `ProxyPlayerSampleView` uses `VideoPlayer`. | macOS 14 brings the Observation module used across ProxyPlayerKit. |
| visionOS 1.0+ | ✅ – Network framework available. | ✅ – `ProxyVideoView` automatically applies `.glassBackgroundEffect()` to blend into volumetric scenes. | Observation + SwiftUI are available from visionOS 1.0; pair with a 2D layer so LL-HLS policies minimize latency in immersive spaces. |

The Observation framework (`@Observable`, `@State`, `@Bindable`) only ships on these OS releases, so ProxyPlayerKit now targets them exclusively. Keep `Package.swift` deployment targets and release notes in sync so downstream apps can plan their upgrades.

To re-run the automated smoke tests on macOS:

```bash
./Scripts/run-ci.sh
```

For iOS/tvOS/visionOS verification, open the Swift Package in Xcode and run `ProxyPlayerSampleView` (SwiftUI preview) or the generated package scheme against the desired Simulator/device.

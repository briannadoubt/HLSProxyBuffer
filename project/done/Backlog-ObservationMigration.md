# Backlog: Adopt Observation Macros in ProxyPlayerKit

## Overview
- **Motivation:** Modern SwiftUI favors the Observation framework (`@Observable`, `@State`, `@Bindable`) over `ObservableObject` / `@StateObject`. Today `ProxyVideoView` and `ProxyPlayerSampleView` rely on `@StateObject` wrappers (`Sources/ProxyPlayerKit/SwiftUI/ProxyVideoView.swift:9`, `Sources/ProxyPlayerKit/SwiftUI/ProxyPlayerSampleView.swift:7` and the README example). This prevents us from taking advantage of Swift 6 Observation features, complicates preview reuse, and makes it awkward to share a `ProxyHLSPlayer` instance across UIKit/SwiftUI surfaces.
- **Goal:** Replace every `@StateObject` consumer with simple `@State` storage that holds an `@Observable` `ProxyHLSPlayer`, eliminate `ObservableObject` conformance, and ensure the Observation graph updates player-driven UI without manual bridging.

## Proposed Approach
1. **Promote `ProxyHLSPlayer` to `@Observable`:**
   - Import `Observation` within `ProxyHLSPlayer.swift` and annotate the class (or introduce an `@Observable` wrapper type if we need to keep the existing initializer semantics).
   - Replace `@Published` with plain stored properties so the Observation macro synthesizes change tracking; audit access control to keep setters private.
   - Expose derived convenience accessors (i.e., `stateDescription`) via extensions marked `@ObservationIgnored` where we don't want them to invalidate views.
2. **Adopt `@State` / `@Bindable` in SwiftUI views:**
   - For default-owned players (`ProxyVideoView` default init, `ProxyPlayerSampleView`), instantiate the player inside `@State` so SwiftUI handles lifecycle but avoids the `StateObject` requirement.
   - Keep the injected-player initializer using `@State(initialValue:)` so existing consumers that pass their own `ProxyHLSPlayer` keep ownership.
   - Update README snippets and previews to reflect the new wrappers.
3. **Observation testing + migration helpers:**
   - Add unit coverage in `Tests/ProxyPlayerKitTests` that drives `ProxyHLSPlayer` mutations and verifies SwiftUI bindings update via a lightweight `@State` harness (can reuse SwiftUI previews or a test host view).
   - Document the migration in `docs/ProxyPlayerKit.md` (or `README.md`) so app integrations know they can drop `ObservableObject`-specific code and rely on the Observation macro.

## Work Items
- [ ] Annotate `ProxyHLSPlayer` with `@Observable`, remove `ObservableObject` & `@Published`, and gate properties with the right access levels.
- [ ] Update SwiftUI views (`ProxyVideoView`, `ProxyPlayerSampleView`, README sample) to use `@State` plus the Observation-aware player.
- [ ] Audit any UIKit / AppKit wrappers for `ProxyHLSPlayer` and ensure they interact with the Observation graph (e.g., `@Bindable` exposures if needed).
- [ ] Add focused tests or preview harnesses covering Observation updates and autoplay behavior to catch regressions.
- [ ] Refresh docs/specs to describe the dependency-free Observation model and note any API-breaking changes.

## Acceptance Criteria
- No `@StateObject` usages remain in the repo; SwiftUI entry points compile with `@State`.
- `ProxyHLSPlayer` change notifications flow through the Observation framework without Combine.
- README and docs match the new API story and guidance.
- Tests (unit + previews or SwiftUI harness) prove that status/metrics UI updates when the player state changes.

## Risks & Dependencies
- Observation macros require the minimum supported OS versions (iOS 17+/macOS 14+/tvOS 17+/visionOS 1.0). Confirm our deployment targets already meet that bar or gate the change via availability.
- Need to ensure `@MainActor` semantics are preserved when dropping `@Published`; Observation still needs to dispatch on the main actor to keep AVPlayer interactions safe.
- Any external apps relying on `ObservableObject` conformance (e.g., `@ObservedObject`) must migrate—call this out clearly in release notes.

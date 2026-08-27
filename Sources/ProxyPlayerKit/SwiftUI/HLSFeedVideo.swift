import Foundation
#if canImport(AVFoundation) && canImport(AVKit) && canImport(SwiftUI)
import AVFoundation
import AVKit
import SwiftUI

/// A playback surface backed by an engine-owned player lease.
///
/// The view never loads media or changes focus. It follows the lease selected
/// by ``HLSFeedEngine/update(_:)`` and automatically detaches when that lease
/// is recycled.
@MainActor
public struct HLSFeedVideo: View {
    private struct Subscription: Hashable {
        let engineID: ObjectIdentifier
        let itemID: FeedItemID
    }

    private let engine: HLSFeedEngine
    private let itemID: FeedItemID
    @State private var player: AVPlayer?

    public init(engine: HLSFeedEngine, itemID: FeedItemID) {
        self.engine = engine
        self.itemID = itemID
    }

    public var body: some View {
        VideoPlayer(player: player)
            .task(id: Subscription(engineID: ObjectIdentifier(engine), itemID: itemID)) {
                let updates = engine.updates()
                for await snapshot in updates {
                    guard !Task.isCancelled else { return }
                    let playback = snapshot.playback(for: itemID)
                    let nextPlayer = playback?.isImmediatelyPlayable == true
                        ? engine.platformPlayer(for: itemID)
                        : nil
                    if player !== nextPlayer { player = nextPlayer }
                }
            }
    }
}
#endif

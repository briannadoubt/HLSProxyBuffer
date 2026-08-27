import CoreGraphics
import ProxyPlayerKit
import SwiftUI

struct FeedDemoRootView: View {
    @State private var model = FeedDemoModel()

    var body: some View {
        FeedDemoShell(model: model)
            .task {
                await model.start()
            }
            .onDisappear {
                Task { await model.stop() }
            }
    }
}

private struct FeedDemoShell: View {
    let model: FeedDemoModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.04, blue: 0.075), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                FeedDemoHeader(
                    mode: model.selectedMode,
                    status: model.status,
                    isLowPowerModeEnabled: model.isLowPowerModeEnabled,
                    onLowPowerChange: { enabled in
                        Task { await model.setLowPowerModeEnabled(enabled) }
                    }
                )
                FeedDemoModeRail(
                    selectedMode: model.selectedMode,
                    onSelect: { mode in
                        Task { await model.select(mode) }
                    }
                )

                if let engine = model.engine {
                    FeedDemoViewport(
                        entries: model.entries,
                        engine: engine,
                        snapshot: model.engineSnapshot,
                        focusedItemID: model.focusedItemID,
                        layout: model.selectedMode.layout,
                        onGeometryChange: model.observe,
                        onFocusRequest: model.requestFocus
                    )
                } else {
                    FeedDemoLoadingView(status: model.status)
                }

                if model.selectedMode == .liveDVR, model.engine != nil {
                    FeedDemoLiveControls(
                        onSeek: { seconds in
                            Task { await model.seekBehindLiveEdge(seconds: seconds) }
                        },
                        onJumpToLive: {
                            Task { await model.jumpToLive() }
                        }
                    )
                }

                FeedDemoMetricsGrid(metrics: model.metrics)
            }
            .padding()
        }
        .tint(.mint)
    }
}

private struct FeedDemoHeader: View {
    let mode: FeedDemoMode
    let status: FeedDemoStatus
    let isLowPowerModeEnabled: Bool
    let onLowPowerChange: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AUTOMATIC HLS FEED", bundle: #bundle)
                    .font(.caption.weight(.black))
                    .tracking(1.8)
                    .foregroundStyle(.mint)
                Text(mode.title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            Spacer()
            FeedDemoStatusPill(status: status)
            Toggle(
                isOn: Binding(
                    get: { isLowPowerModeEnabled },
                    set: { value in onLowPowerChange(value) }
                )
            ) {
                Label {
                    Text("Low power", bundle: #bundle)
                } icon: {
                    Image(systemName: "leaf.fill")
                }
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("low-power-toggle")
        }
    }
}

private struct FeedDemoStatusPill: View {
    let status: FeedDemoStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            switch status {
            case .idle:
                Text("Idle", bundle: #bundle)
            case .starting:
                Text("Starting", bundle: #bundle)
            case .running:
                Text("Local fixtures", bundle: #bundle)
            case .failed:
                Text("Needs attention", bundle: #bundle)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.1), in: Capsule())
        .accessibilityIdentifier("fixture-origin-status")
    }

    private var statusColor: Color {
        switch status {
        case .idle: .secondary
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        }
    }
}

private struct FeedDemoModeRail: View {
    let selectedMode: FeedDemoMode
    let onSelect: (FeedDemoMode) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(FeedDemoMode.allCases) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .foregroundStyle(mode == selectedMode ? .black : .white)
                            .background(
                                mode == selectedMode ? Color.mint : Color.white.opacity(0.1),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mode-\(mode.rawValue)")
                    .accessibilityAddTraits(mode == selectedMode ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct FeedDemoLoadingView: View {
    let status: FeedDemoStatus

    var body: some View {
        VStack(spacing: 12) {
            if case .failed(let message) = status {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("The local demo could not start.", bundle: #bundle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Starting the local HLS fixture origin…", bundle: #bundle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("feed-loading-state")
    }
}

private struct FeedDemoViewport: View {
    let entries: [FeedDemoEntry]
    let engine: HLSFeedEngine
    let snapshot: HLSFeedEngineSnapshot
    let focusedItemID: FeedItemID?
    let layout: FeedDemoLayout
    let onGeometryChange: ([FeedItemID: CGRect], CGRect) -> Void
    let onFocusRequest: (FeedItemID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let viewport = CGRect(origin: .zero, size: proxy.size)
            Group {
                switch layout {
                case .paged:
                    FeedDemoPagedScroller(
                        entries: entries,
                        engine: engine,
                        snapshot: snapshot,
                        focusedItemID: focusedItemID,
                        viewportHeight: proxy.size.height,
                        onFocusRequest: onFocusRequest
                    )
                case .windowed:
                    FeedDemoWindowedScroller(
                        entries: entries,
                        engine: engine,
                        snapshot: snapshot,
                        focusedItemID: focusedItemID,
                        viewportHeight: proxy.size.height,
                        onFocusRequest: onFocusRequest
                    )
                }
            }
            .coordinateSpace(name: "HLSFeedViewport")
            .onPreferenceChange(FeedDemoFramePreferenceKey.self) { frames in
                onGeometryChange(frames, viewport)
            }
        }
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityIdentifier("automatic-feed-viewport")
    }
}

private struct FeedDemoPagedScroller: View {
    let entries: [FeedDemoEntry]
    let engine: HLSFeedEngine
    let snapshot: HLSFeedEngineSnapshot
    let focusedItemID: FeedItemID?
    let viewportHeight: CGFloat
    let onFocusRequest: (FeedItemID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    FeedDemoCard(
                        entry: entry,
                        engine: engine,
                        playback: snapshot.playback(for: entry.id),
                        isFocused: focusedItemID == entry.id,
                        onFocusRequest: onFocusRequest
                    )
                    .padding(10)
                    .frame(height: max(300, viewportHeight))
                    .feedDemoGeometry(itemID: entry.id)
                    .id(entry.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .background(.black.opacity(0.25))
    }
}

private struct FeedDemoWindowedScroller: View {
    let entries: [FeedDemoEntry]
    let engine: HLSFeedEngine
    let snapshot: HLSFeedEngineSnapshot
    let focusedItemID: FeedItemID?
    let viewportHeight: CGFloat
    let onFocusRequest: (FeedItemID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 14) {
                ForEach(entries) { entry in
                    FeedDemoCard(
                        entry: entry,
                        engine: engine,
                        playback: snapshot.playback(for: entry.id),
                        isFocused: focusedItemID == entry.id,
                        onFocusRequest: onFocusRequest
                    )
                    .frame(height: max(260, viewportHeight * 0.72))
                    .feedDemoGeometry(itemID: entry.id)
                    .id(entry.id)
                }
            }
            .padding(10)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .background(.black.opacity(0.25))
    }
}

private struct FeedDemoCard: View {
    let entry: FeedDemoEntry
    let engine: HLSFeedEngine
    let playback: HLSFeedPlayback?
    let isFocused: Bool
    let onFocusRequest: (FeedItemID) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: accentColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HLSFeedVideo(engine: engine, itemID: entry.id)
                .allowsHitTesting(false)

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )

            if playback == nil || playback?.phase == .loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    FeedDemoPhaseBadge(playback: playback)
                    Spacer()
                    if isFocused {
                        Label {
                            Text("Focused", bundle: #bundle)
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.mint)
                    }
                }
                Spacer()
                Text(entry.title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(18)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isFocused ? Color.mint : Color.white.opacity(0.12), lineWidth: isFocused ? 3 : 1)
        }
        .onTapGesture { onFocusRequest(entry.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.title))
        .accessibilityValue(Text(accessibilityPhase))
        .accessibilityIdentifier("feed-item-\(entry.id.rawValue)")
    }

    private var accessibilityPhase: LocalizedStringResource {
        if isFocused, playback?.hasStartedPlayback == true {
            return LocalizedStringResource("Focused and playing", bundle: #bundle)
        }
        if isFocused {
            return LocalizedStringResource("Focused and starting", bundle: #bundle)
        }
        return switch playback?.phase {
        case .warm: LocalizedStringResource("Ready for handoff", bundle: #bundle)
        case .loading: LocalizedStringResource("Loading", bundle: #bundle)
        case .failed: LocalizedStringResource("Playback failed", bundle: #bundle)
        case .focused: LocalizedStringResource("Focused and playing", bundle: #bundle)
        case nil: LocalizedStringResource("Outside the active playback window", bundle: #bundle)
        }
    }

    private var accentColors: [Color] {
        switch entry.accentIndex % 6 {
        case 0: [Color.purple.opacity(0.75), Color.indigo.opacity(0.35)]
        case 1: [Color.blue.opacity(0.75), Color.cyan.opacity(0.3)]
        case 2: [Color.orange.opacity(0.72), Color.pink.opacity(0.3)]
        case 3: [Color.red.opacity(0.68), Color.purple.opacity(0.32)]
        case 4: [Color.green.opacity(0.68), Color.teal.opacity(0.3)]
        default: [Color.mint.opacity(0.65), Color.indigo.opacity(0.35)]
        }
    }
}

private struct FeedDemoPhaseBadge: View {
    let playback: HLSFeedPlayback?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
            Text(title)
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var symbolName: String {
        switch playback?.phase {
        case .focused where playback?.hasStartedPlayback == true: "play.fill"
        case .focused: "hourglass"
        case .warm: "checkmark.circle.fill"
        case .loading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle.dotted"
        }
    }

    private var title: LocalizedStringResource {
        switch playback?.phase {
        case .focused where playback?.hasStartedPlayback == true:
            LocalizedStringResource("Playing", bundle: #bundle)
        case .focused:
            LocalizedStringResource("Starting", bundle: #bundle)
        case .warm: LocalizedStringResource("Warm", bundle: #bundle)
        case .loading: LocalizedStringResource("Preparing", bundle: #bundle)
        case .failed: LocalizedStringResource("Failed", bundle: #bundle)
        case nil: LocalizedStringResource("Queued", bundle: #bundle)
        }
    }
}

private struct FeedDemoLiveControls: View {
    let onSeek: (TimeInterval) -> Void
    let onJumpToLive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onSeek(2)
            } label: {
                Label {
                    Text("2s behind", bundle: #bundle)
                } icon: {
                    Image(systemName: "gobackward")
                }
            }
            .accessibilityIdentifier("live-seek-behind")
            Button {
                onJumpToLive()
            } label: {
                Label {
                    Text("Jump to live", bundle: #bundle)
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("live-jump-to-edge")
        }
    }
}

private struct FeedDemoMetricsGrid: View {
    let metrics: FeedDemoMetrics

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], spacing: 8) {
            FeedDemoMetricTile(
                title: LocalizedStringResource("First frame", bundle: #bundle),
                value: firstFrameValue,
                detail: LocalizedStringResource("count · p95", bundle: #bundle),
                symbolName: "play.rectangle.fill"
            )
            FeedDemoMetricTile(
                title: LocalizedStringResource("Stalls", bundle: #bundle),
                value: "\(metrics.stallCount) · \(metrics.stallSeconds.formatted(.number.precision(.fractionLength(2))))s",
                detail: LocalizedStringResource("count · duration", bundle: #bundle),
                symbolName: "pause.circle.fill"
            )
            FeedDemoMetricTile(
                title: LocalizedStringResource("Cache", bundle: #bundle),
                value: metrics.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—",
                detail: LocalizedStringResource("hit rate", bundle: #bundle),
                symbolName: "internaldrive.fill"
            )
            FeedDemoMetricTile(
                title: LocalizedStringResource("Budget", bundle: #bundle),
                value: budgetValue,
                detail: LocalizedStringResource("players · memory · disk", bundle: #bundle),
                symbolName: "gauge.with.dots.needle.67percent"
            )
            FeedDemoMetricTile(
                title: LocalizedStringResource("Cancellation", bundle: #bundle),
                value: "\(metrics.acknowledgedCancellationCount) · \(metrics.cancellationCount)",
                detail: LocalizedStringResource("acknowledged · total", bundle: #bundle),
                symbolName: "xmark.circle.fill"
            )
            FeedDemoMetricTile(
                title: LocalizedStringResource("Handoff", bundle: #bundle),
                value: "\(metrics.handoffSuccessCount) · \(metrics.handoffReadyCount)",
                detail: LocalizedStringResource("success · warm-ready", bundle: #bundle),
                symbolName: "arrow.left.arrow.right.circle.fill"
            )
        }
        .accessibilityIdentifier("feed-metrics-overlay")
    }

    private var firstFrameValue: String {
        let p95 = metrics.firstFrameP95.map {
            "\(($0 * 1_000).formatted(.number.precision(.fractionLength(0))))ms"
        } ?? "—"
        return "\(metrics.firstFrameCount) · \(p95)"
    }

    private var budgetValue: String {
        [
            "\(metrics.playerCount)/\(metrics.playerLimit)",
            byteCount(metrics.memoryBytes),
            byteCount(metrics.diskBytes),
        ].joined(separator: " · ")
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private struct FeedDemoMetricTile: View {
    let title: LocalizedStringResource
    let value: String
    let detail: LocalizedStringResource
    let symbolName: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbolName)
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FeedDemoFramePreferenceKey: PreferenceKey {
    static let defaultValue: [FeedItemID: CGRect] = [:]

    static func reduce(
        value: inout [FeedItemID: CGRect],
        nextValue: () -> [FeedItemID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private extension View {
    func feedDemoGeometry(itemID: FeedItemID) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FeedDemoFramePreferenceKey.self,
                    value: [itemID: proxy.frame(in: .named("HLSFeedViewport"))]
                )
            }
        }
    }
}
